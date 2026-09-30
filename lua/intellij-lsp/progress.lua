--- Import and indexing feedback.
---
--- Indexing progress is plain LSP `$/progress`, so `vim.lsp.status()` renders it with no work on
--- our side. What needs handling is the pair of custom notifications around it:
---
---   * `intellij/ready-for-test` - initial import finished *and* the index was flushed. Until this
---     arrives, navigation results may be incomplete.
---   * `intellij/importLog`      - Maven/Gradle/Bazel import output. Without surfacing this, a
---     failed import is indistinguishable from a hung server.
---
---   * `intellij/workspaceImportState`  - one summary per import cycle: the phase it ended in and
---                                        one status per workspace folder.
---   * `intellij/workspaceImportStatus` - which folders are blocked from importing, and why.
---
--- All are sent regardless of the `intellijExtensions` opt-in, so they are safe to consume.
---
--- The two workspace-import messages are what turn "nothing gets imported" from a silence into a
--- sentence. A folder whose build system could not be decided (`ambiguousBuildSystem`, two build
--- files side by side) is first asked about by the server itself, over `window/showMessageRequest`;
--- if that prompt is dismissed the folder stays blocked with `dismissed = true`, and the status
--- notification is the only trace. The handler here then offers the candidates once more, and a
--- pick is sent back as `intellij/reloadWorkspace` with that folder's `buildTools` entry set.
---
--- The import log is the build tool's own console output. Maven runs as a child process and every
--- stdout and stderr line is forwarded; Gradle's Tooling API output is wired the same way. Lines
--- arrive with a `type` of Info for stdout and Warning for stderr, and three marker events bracket
--- them: `started` and `failed` name the tool, `succeeded` closes the whole import. Streamed lines
--- carry no tool name, so with two importers running at once (a Maven root and a Gradle root in one
--- workspace) their output interleaves and cannot be separated here.
---
--- It all goes to the shared panel in `output.lua`, the one a running program writes to as well.
--- When the panel opens is `build_output`: on every import start, only on failure (the default),
--- or never. `:IntellijLspOutput` opens it by hand at any time.

local M = {}

local READY = 'intellij/ready-for-test'
local IMPORT_LOG = 'intellij/importLog'
local IMPORT_STATE = 'intellij/workspaceImportState'
local IMPORT_STATUS = 'intellij/workspaceImportStatus'
local RELOAD_WORKSPACE = 'intellij/reloadWorkspace'

--- Blocked-folder reasons, as the server spells them, in words.
M.BLOCKED_REASONS = {
  ambiguousBuildSystem = 'more than one build system found; choose one',
  unknownBuildTool = 'the configured build tool is not one the server knows',
  cannotResolveConfiguredPath = 'the configured project path does not exist',
  cannotResolveFolderPath = 'the workspace folder path does not exist',
  noProjectAtConfiguredPath = 'no project at the configured path',
  noBuildSystemFound = 'no build file found; set build_tool or projects',
  noProjectInRoot = 'no project in the workspace root',
}

--- @type table<integer, boolean>
local ready_by_client = {}

--- The last `workspaceImportState` per client, for `:checkhealth`.
--- @type table<integer, table>
local import_state_by_client = {}

--- The last `workspaceImportStatus` per client, for `:checkhealth`.
--- @type table<integer, table>
local import_status_by_client = {}

--- Folders already offered a build-tool pick, so a status that repeats itself asks only once.
--- @type table<string, true>
local offered_folders = {}

--- @type fun(client_id: integer)[]
local ready_listeners = {}

local output = require('intellij-lsp.output')

--- `'always'`, `'on_failure'` or `'never'`; see `M.configure`.
--- @type string
local build_output = 'on_failure'

--- Import bookkeeping for the separators: which tool the last `started` named, and when.
--- @type string|nil
local current_tool = nil
--- @type integer|nil
local started_at = nil

--- Whether the server has finished its initial import and index flush.
--- @param client_id integer
--- @return boolean
function M.is_ready(client_id)
  return ready_by_client[client_id] == true
end

--- Subscribes to the readiness notification.
---
--- Exists for the progress report in status.lua, which is otherwise driven entirely by
--- `$/progress`: readiness is the one transition that arrives outside that stream, and it is what
--- closes the running progress message.
--- @param fn fun(client_id: integer)
function M.on_ready(fn)
  table.insert(ready_listeners, fn)
end

--- @param opts { build_output: string|nil }
function M.configure(opts)
  if opts.build_output ~= nil then build_output = opts.build_output end
end

--- Opens the output panel. Kept as the target of `:IntellijLspLog` and `:IntellijLspOutput`.
function M.open_log()
  output.open()
end

--- LSP `MessageType` values, as the server serialises them.
local MSG_ERROR, MSG_WARNING = 1, 2

--- The highlight for one line of import output, or nil for plain text.
---
--- The notification type is the primary signal: stderr arrives as Warning, a terminal failure as
--- Error, and neither needs parsing. The patterns on top catch what the build tools put on stdout:
--- Maven's `[ERROR]`/`[WARNING]` prefixes and its `BUILD SUCCESS`/`BUILD FAILURE` summary, Gradle's
--- `FAILURE:` block and the Kotlin compiler's `e:`/`w:` lines. Anything unrecognised stays plain,
--- which is most of a healthy import.
--- @param msg_type integer|nil
--- @param message string
--- @return string|nil
function M._import_hl(msg_type, message)
  if msg_type == MSG_ERROR then return 'DiagnosticError' end
  if message:find('^%[ERROR%]') or message:find('^%[FATAL%]') or message:find('BUILD FAILURE', 1, true)
    or message:find('^FAILURE:') or message:find('^e: ') then
    return 'DiagnosticError'
  end
  if msg_type == MSG_WARNING or message:find('^%[WARNING%]') or message:find('^w: ') then
    return 'DiagnosticWarn'
  end
  if message:find('BUILD SUCCESS', 1, true) then return 'DiagnosticOk' end
  return nil
end

--- "1m 12s" style duration for the closing separator, from a `vim.uv.now()` millisecond start.
--- @param ms integer
--- @return string
function M._elapsed(ms)
  local s = math.floor(ms / 1000)
  if s < 60 then return s .. 's' end
  return ('%dm %02ds'):format(math.floor(s / 60), s % 60)
end

--- A separator line for the panel. The dashes make the import boundaries findable in a buffer that
--- also holds program output from before and after.
--- @param text string
--- @return string
local function separator(text)
  return '--- ' .. text .. ' ---'
end

--- The last import summary the server sent for this client, or nil before the first cycle ends.
--- @param client_id integer
--- @return table|nil
function M.import_state(client_id)
  return import_state_by_client[client_id]
end

--- The last blocked-folder status the server sent for this client, or nil.
--- @param client_id integer
--- @return table|nil
function M.import_status(client_id)
  return import_status_by_client[client_id]
end

--- Clears state for a client that has stopped, so a restart starts from a clean slate.
--- @param client_id integer
function M.reset(client_id)
  ready_by_client[client_id] = nil
  import_state_by_client[client_id] = nil
  import_status_by_client[client_id] = nil
  offered_folders = {}
end

--- A folder URI as the user would write it.
--- @param uri string|nil
--- @return string
function M.folder_name(uri)
  if type(uri) ~= 'string' then return '?' end
  local ok, fname = pcall(vim.uri_to_fname, uri)
  return ok and vim.fn.fnamemodify(fname, ':~') or uri
end
local folder_name = M.folder_name

--- One `vim.notify` line per folder that did not import, with the server's reason.
---
--- Success is not reported here: the `succeeded` import-log separator and the readiness
--- notification already say so, and a third line would be noise. A `BLOCKED` folder's `message`
--- is a reason id, translated through `BLOCKED_REASONS`; a `FAILED` one carries the importer's
--- own message.
--- @param state table
--- @return string[] lines that were notified, for tests
function M._report_import_state(state)
  local lines = {}
  for _, folder in ipairs(state.folders or {}) do
    if folder.status == 'FAILED' then
      lines[#lines + 1] = ('IntelliJ LSP: %s import of %s failed%s'):format(
        folder.tool or 'the', folder_name(folder.folderUri),
        folder.message and folder.message ~= '' and (': ' .. folder.message) or '')
    elseif folder.status == 'BLOCKED' then
      local reason = M.BLOCKED_REASONS[folder.message] or folder.message or 'blocked'
      lines[#lines + 1] = ('IntelliJ LSP: %s was not imported: %s'):format(folder_name(folder.folderUri), reason)
    end
  end
  if state.phase == 'FAILED' and #lines == 0 then
    lines[#lines + 1] = 'IntelliJ LSP: workspace import failed' .. (state.message and (': ' .. state.message) or '')
  elseif state.phase == 'CANCELLED' and #lines == 0 then
    lines[#lines + 1] = 'IntelliJ LSP: workspace import was cancelled'
  end
  local level = state.phase == 'FAILED' and vim.log.levels.ERROR or vim.log.levels.WARN
  for _, line in ipairs(lines) do vim.notify(line, level) end
  return lines
end

--- Sends the reload that resolves an ambiguous folder with the chosen build tool.
---
--- Same request `:IntellijLspReload` uses, with one `buildTools` entry pinned. The other options are
--- rebuilt from the user's configuration, so nothing else about the workspace changes.
--- @param client_id integer
--- @param folder_uri string
--- @param tool string
function M._reload_with_tool(client_id, folder_uri, tool)
  local client = vim.lsp.get_client_by_id(client_id)
  if not client then return end
  local cfg = require('intellij-lsp').config
  local options = require('intellij-lsp.client').init_options(client.config.root_dir, cfg)
  options.buildTools = options.buildTools or {}
  options.buildTools[folder_uri] = tool
  client:request(RELOAD_WORKSPACE, { initializationOptions = options }, function(err)
    if err then
      vim.notify('IntelliJ LSP: reload failed: ' .. tostring(err.message or err), vim.log.levels.ERROR)
    else
      vim.notify(('IntelliJ LSP: importing %s with %s'):format(folder_name(folder_uri), tool), vim.log.levels.INFO)
    end
  end)
end

--- Offers the candidates of an `ambiguousBuildSystem` folder whose server-side prompt was dismissed.
---
--- Only when `dismissed` is set: before that the server's own `window/showMessageRequest` is still
--- open, and a second picker for the same question would race it. Asked once per folder per
--- client lifetime, since the server repeats the status on every cycle.
--- @param status table
--- @param client_id integer
function M._offer_build_tool(status, client_id)
  for _, folder in ipairs(status.blockedFolders or {}) do
    local candidates = folder.candidates
    if folder.reason == 'ambiguousBuildSystem' and folder.dismissed and type(candidates) == 'table'
      and #candidates > 0 and not offered_folders[folder.folderUri] then
      offered_folders[folder.folderUri] = true
      vim.ui.select(candidates, {
        prompt = 'IntelliJ: which build tool imports ' .. folder_name(folder.folderUri) .. '?',
      }, function(choice)
        if choice then M._reload_with_tool(client_id, folder.folderUri, choice) end
      end)
    end
  end
end

--- LSP handlers for the custom notifications.
--- @return table<string, function>
function M.handlers()
  return {
    [READY] = function(_, _, ctx)
      ready_by_client[ctx.client_id] = true
      -- The last word after status.lua closes its running progress message, and the only signal at
      -- all under `progress = false`.
      vim.notify('IntelliJ LSP: indexing complete', vim.log.levels.INFO)
      -- pcall so a broken listener cannot swallow the notification for everyone else.
      for _, fn in ipairs(ready_listeners) do
        pcall(fn, ctx.client_id)
      end
    end,

    [IMPORT_STATE] = function(_, result, ctx)
      if type(result) ~= 'table' then return end
      import_state_by_client[ctx.client_id] = result
      M._report_import_state(result)
    end,

    [IMPORT_STATUS] = function(_, result, ctx)
      if type(result) ~= 'table' then return end
      import_status_by_client[ctx.client_id] = result
      M._offer_build_tool(result, ctx.client_id)
    end,

    [IMPORT_LOG] = function(_, result, _)
      if not result then return end
      local tool = result.tool or current_tool or 'Build'

      if result.started then
        current_tool, started_at = tool, vim.uv.now()
        -- The server's message already names the tool and the directory it imports.
        output.append(separator(result.message or (tool .. ': import started')), 'Title')
        if build_output == 'always' then output.open({ focus = false }) end
        return
      end

      -- The success event's message ("Workspace imported successfully") is what the separator below
      -- says already; every other message is a line of output, or the failure's explanation.
      if result.message and result.message ~= '' and not result.succeeded then
        output.append(result.message, M._import_hl(result.type, result.message))
      end

      local took = started_at and (' in ' .. M._elapsed(vim.uv.now() - started_at)) or ''
      if result.failed then
        output.append(separator(tool .. ': import failed' .. took), 'DiagnosticError')
        started_at = nil
        if build_output ~= 'never' then output.open({ focus = false }) end
        vim.notify(
          ('IntelliJ LSP: %s import failed. See :IntellijLspOutput'):format(tool),
          vim.log.levels.ERROR
        )
      elseif result.succeeded then
        output.append(separator(tool .. ': import succeeded' .. took), 'DiagnosticOk')
        started_at = nil
      end
    end,
  }
end

return M
