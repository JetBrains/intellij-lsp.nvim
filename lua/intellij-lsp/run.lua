--- Runs a JVM main class through the language server, with output in the shared bottom panel.
---
--- The server runs every program itself (bundle 271 and later). The client sends one DAP `launch`
--- naming the main class and its source file, and the server works out the rest: the module, its
--- build tool, the class path and the JDK. The tool builds before it runs (`mvn compile
--- dependency:build-classpath` and then `java`, Gradle's generated `ideRun` task, ...), and the
--- build's output arrives as DAP `output` events in the same stream as the program's.
---
--- Bundles up to 263 worked the other way round, through `intellij.java.resolveLaunch` and
--- `intellij.java.resolveBuildCommand`: the client resolved a class path, ran the build tool itself
--- and then started a plain `java`. 271 removed both commands; asking for them answers
--- "Unknown command".
---
--- `has_dap()` gates both this module's own commands and, through `client.lua`'s `runMainCodeLens`
--- init option, whether the server emits Run/Debug lenses at all: a lens that renders and then fails
--- on click is worse than no lens.

local M = {}

local output = require('intellij-lsp.output')

--- The DAP adapter type every launch here uses. The server's JVM adapter answers to
--- `intellij_gradle` and `intellij_bazel` as well, but the type picks nothing on the server: the
--- `tool` field of the launch does. One type keeps `owns()` a single comparison.
local ADAPTER_ID = 'intellij_jvm'
M.ADAPTER_ID = ADAPTER_ID
--- The launch configuration field naming the client that resolved the launch; see the adapter.
local CLIENT_FIELD = 'intellijClientId'

--- Whether nvim-dap is installed.
---
--- Checked with `pcall(require, ...)` rather than `package.loaded`, because the latter is false for a
--- plugin manager that has not lazy-loaded it yet even though `require` would succeed.
--- @return boolean
function M.has_dap()
  return (pcall(require, 'dap'))
end

--- Whether a nvim-dap session is one this plugin launched, rather than another adapter's.
---
--- nvim-dap's listeners are global: every session's events reach them, a Python one's included.
--- @param session dap.Session|nil
--- @return boolean
function M.owns(session)
  return session ~= nil and session.config ~= nil and session.config.type == ADAPTER_ID
end

--- Strips VS Code's codicon markup from a lens title.
---
--- `$(play) Run` and `$(debug) Debug` come from the server verbatim; Neovim has no codicon font and
--- renders the seven characters literally.
--- @param title string
--- @return string
function M._strip_codicons(title)
  return (title:gsub('%$%([%w%-]+%)%s*', ''))
end

--- Tells `test.lua` a launch never got a session, so a test run it reserved is freed. Only loaded
--- when something already loaded it: a plain run has no test run to free.
--- @param config table
--- @param reason string
local function launch_failed(config, reason)
  local test = package.loaded['intellij-lsp.test']
  if test then test._launch_failed(config, reason) end
end

--- @type integer|nil
local dap_registered_for = nil

--- Registers the DAP adapter and configuration provider once per nvim-dap installation.
---
--- Idempotent and safe to call from `setup()` on every `require('intellij-lsp').setup()`: a plugin
--- manager that re-runs specs would otherwise pile up duplicate adapters. Not scoped to a client id --
--- one adapter definition serves every project the plugin attaches to in this session.
local function ensure_dap_adapter()
  if not M.has_dap() then return end
  if dap_registered_for then return end
  dap_registered_for = true

  local dap = require('dap')

  -- One DAP server per session: `start_debug_server` starts it fresh, on a free localhost port, the
  -- moment nvim-dap asks to launch -- there is nothing to keep alive between launches.
  --
  -- On the server that resolved the launch, which `launch` names in the configuration: with two
  -- projects open, any other one would debug a classpath it never built. A re-run after a server
  -- restart (`dap.run_last()`) names a client that is gone; the server covering the launch's file
  -- takes over, or its working directory for a configuration that names one.
  dap.adapters[ADAPTER_ID] = function(callback, config)
    local client_module = require('intellij-lsp.client')
    local c = config[CLIENT_FIELD] and vim.lsp.get_client_by_id(config[CLIENT_FIELD])
    if not c and config.file then c = client_module.find_ancestor_client(config.file) end
    if not c and config.cwd then c = client_module.find_ancestor_client(config.cwd) end
    if not c then
      vim.notify('IntelliJ LSP: no server running for this launch, cannot start a debug session.', vim.log.levels.ERROR)
      launch_failed(config, 'no server running for it')
      return
    end

    c:request('workspace/executeCommand', {
      command = 'start_debug_server',
      arguments = { vim.uri_from_fname(c.config.root_dir) },
    }, function(err, port)
      if err or not port then
        local why = 'failed to start the debug server: ' .. tostring(err and (err.message or err))
        vim.notify('IntelliJ LSP: ' .. why, vim.log.levels.ERROR)
        vim.schedule(function() launch_failed(config, why) end)
        return
      end
      -- `id` is what nvim-dap sends as the DAP `initialize` request's `adapterID`; without it nvim-dap
      -- falls back to the literal string 'nvim-dap', which the server then rejects as an unknown
      -- adapter id.
      callback({
        type = 'server',
        host = '127.0.0.1',
        port = port,
        id = ADAPTER_ID,
        -- The client id is this plugin's routing, not a launch argument for the server.
        enrich_config = function(launch_config, on_config)
          local sent = vim.deepcopy(launch_config)
          sent[CLIENT_FIELD] = nil
          on_config(sent)
        end,
      })
    end)

    -- Unused but required by nvim-dap's adapter signature; the launch never needs to react to it.
    return config
  end
end

-- -------------------------------------------------------------------------------------------------
-- Launching
-- -------------------------------------------------------------------------------------------------

--- The server that owns a launch for `uri`: `opts.client` when given, else the one whose project
--- contains the file. Reports the problem and answers nil when there is none, or no nvim-dap.
--- @param uri string
--- @param opts { client: vim.lsp.Client|nil }|nil
--- @return vim.lsp.Client|nil
function M._launch_client(uri, opts)
  if not M.has_dap() then
    vim.notify('IntelliJ LSP: running requires nvim-dap (mfussenegger/nvim-dap).', vim.log.levels.ERROR)
    return nil
  end
  local c = opts and opts.client
    or require('intellij-lsp.client').find_ancestor_client(vim.uri_to_fname(uri))
  if not c then
    vim.notify('IntelliJ LSP: no server running for ' .. vim.uri_to_fname(uri) .. '.', vim.log.levels.ERROR)
    return nil
  end
  return c
end

--- Starts a DAP launch on `client` for a configuration with this module's fixed fields filled in.
---
--- `internalConsole` is load-bearing, not a preference: the server streams the program's output as
--- DAP `output` events either way, but nvim-dap answers any other console with a terminal of its
--- own and the panel would stay empty.
---
--- `noDebug = true` is what makes a launch a *run* rather than a *debug*: the server leaves out the
--- JDWP agent, and nothing waits for a debugger to attach.
--- @param client vim.lsp.Client
--- @param config table the launch fields: `name`, `mainClass`, `file`, `noDebug`, ...
function M._dap_run(client, config)
  ensure_dap_adapter()
  require('dap').run(vim.tbl_extend('force', config, {
    type = ADAPTER_ID,
    request = 'launch',
    console = 'internalConsole',
    [CLIENT_FIELD] = client.id,
  }))
end

--- Runs (or debugs) a main class through nvim-dap.
---
--- `tool` is the build tool the server named on the lens (`maven`, `gradle`, ...). Left nil, the
--- server uses the tool of the module, which is the same answer; the lens passes it anyway, so a
--- module whose tool changed since the lens was drawn fails with the server's own message.
---
--- A debug launch goes to the plain JVM (`tool = 'java'`) instead: the module's tool still builds
--- first, then `java` runs the program under the debugger. On 271.2085.0 a Gradle debug launch
--- through Gradle itself (its generated `ideRun` task) stops on breakpoints, but the server ends the
--- session as soon as the debugger disconnects and the program's own output never arrives. The plain
--- JVM is also how every launch ran up to bundle 263. The cost: a debug launch does not pick up JVM
--- arguments the build script sets on its run task.
--- @param main_class string fully qualified class name
--- @param uri string the class's source document: the server runs the module that owns it
--- @param no_debug boolean
--- @param opts { client: vim.lsp.Client|nil, tool: string|nil }|nil `client` is the server to launch
---   on, by default the one whose project contains `uri`
local function launch(main_class, uri, no_debug, opts)
  local c = M._launch_client(uri, opts)
  if not c then return end
  M._dap_run(c, {
    name = main_class,
    mainClass = main_class,
    file = vim.uri_to_fname(uri),
    tool = no_debug and opts and opts.tool or (not no_debug and 'java' or nil),
    noDebug = no_debug,
  })
end

M.launch = launch

-- -------------------------------------------------------------------------------------------------
-- Output panel
-- -------------------------------------------------------------------------------------------------

--- The program's output goes to the shared panel in `output.lua`, the same buffer the build tool's
--- import log is written to. See that module for why they share one.

--- Writes one DAP `output` event to the panel.
---
--- The build that precedes a launch streams through here too, so its lines get the highlight the
--- import log gives them (`[ERROR]` red, `BUILD SUCCESS` green). The server's own `console` lines --
--- `[Build]`, `[Run] app`, `Process finished with exit code 1` -- are dimmed: they frame the output
--- rather than belong to it.
--- @param body { category: string|nil, output: string }
function M._append_output(body)
  if body.category == 'console' then
    local text = vim.trim(body.output)
    if text ~= '' then output.append(text, 'Comment') end
    return
  end
  local hl = require('intellij-lsp.progress')._import_hl
  for _, line in ipairs(vim.split(body.output:gsub('\n$', ''), '\n', { plain = true })) do
    output.append(line, hl(nil, line) or (body.category == 'stderr' and 'WarningMsg' or nil))
  end
end

if M.has_dap() then
  require('dap').listeners.after.event_output['intellij-lsp.run'] = function(session, body)
    if not M.owns(session) or not body or not body.output then return end
    -- A test run's stdout is the runner's service messages; `test.lua` renders those itself.
    if require('intellij-lsp.test').owns(session) then return end
    M._append_output(body)
  end

  -- Opens on the first output of a session rather than at launch: with none yet there is nothing to
  -- show, and opening early would steal focus before the program has said anything.
  local opened_for = nil
  require('dap').listeners.before.event_output['intellij-lsp.run.panel'] = function(session)
    if not M.owns(session) or opened_for == session.id then return end
    opened_for = session.id
    vim.schedule(output.open)
  end
  require('dap').listeners.after.event_terminated['intellij-lsp.run'] = function(session)
    if M.owns(session) and opened_for == session.id then opened_for = nil end
  end
end

--- Registers the client-side handler for the server's Run/Debug code lens command.
---
--- `vim.lsp.commands` is the standard extension point `vim.lsp.codelens.run()` and `gra` both dispatch
--- through, so no bespoke keymap wiring is needed for the lens itself -- only for `<leader>rr` below,
--- which has no lens to click.
local function register_lens_command()
  vim.lsp.commands['intellij.jvm.runMain'] = function(command, ctx)
    local args = (command.arguments or {})[1] or {}
    if not args.mainClass then return end
    local uri = args.uri or vim.uri_from_bufnr(ctx and ctx.bufnr or 0)
    launch(args.mainClass, uri, args.noDebug ~= false, {
      client = ctx and ctx.client_id and vim.lsp.get_client_by_id(ctx.client_id) or nil,
      tool = args.tool,
    })
  end
end

--- The innermost class enclosing the cursor, fully qualified.
---
--- `documentSymbol`'s class nodes carry no package for Java -- only Kotlin's symbol tree does -- so a
--- `package` declaration read from the buffer is prepended by hand. Left unqualified, `mainClass`
--- still reaches the launched command line, and the failure moves from "wrong class" to a JVM
--- `Could not find or load main class` once the process is already up.
--- @param bufnr integer
--- @param classes table[] documentSymbol results already filtered to kind == Class
--- @param row integer 0-based cursor line
--- @return string|nil
function M._enclosing_class(bufnr, classes, row)
  local best, best_span = nil, math.huge
  for _, sym in ipairs(classes) do
    local range = sym.range
    if range.start.line <= row and row <= range['end'].line then
      local span = range['end'].line - range.start.line
      if span < best_span then
        best, best_span = sym, span
      end
    end
  end
  if not best then return nil end

  local name = best.name
  if vim.bo[bufnr].filetype == 'java' then
    -- Tracks whether the scan is still inside a `/* ... */` block comment, e.g. a license header:
    -- a line deep in one, such as " * Copyright ...", starts with neither `//` nor `/*`, so without
    -- this state the old line-by-line check broke out before ever reaching the real `package` line.
    local in_block_comment = false
    for _, line in ipairs(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)) do
      if in_block_comment then
        if line:find('%*/') then in_block_comment = false end
      else
        local pkg = line:match('^%s*package%s+([%w%.]+)%s*;')
        if pkg then return pkg .. '.' .. name end
        if line:match('^%s*/%*') and not line:find('%*/') then
          in_block_comment = true
        -- A `package` statement, if any, is the first non-comment, non-blank statement in the file.
        elseif line:match('%S') and not line:match('^%s*//') and not line:match('^%s*/%*.*%*/%s*$') then
          break
        end
      end
    end
  end
  return name
end

--- Flattens a `textDocument/documentSymbol` tree to its `Class` (kind 5) nodes.
--- @param symbols table[]
--- @return table[]
local function flatten_classes(symbols)
  local out = {}
  local function walk(list)
    for _, sym in ipairs(list or {}) do
      if sym.kind == 5 then out[#out + 1] = sym end
      walk(sym.children)
    end
  end
  walk(symbols)
  return out
end

--- Runs (or debugs) the main class enclosing the cursor.
--- @param no_debug boolean|nil defaults to true, i.e. run rather than debug
function M.run_at_cursor(no_debug)
  local bufnr = vim.api.nvim_get_current_buf()
  local c = vim.lsp.get_clients({ bufnr = bufnr, name = require('intellij-lsp.client').NAME })[1]
  if not c then
    vim.notify('IntelliJ LSP: no server attached to this buffer.', vim.log.levels.ERROR)
    return
  end

  c:request(
    'textDocument/documentSymbol',
    { textDocument = vim.lsp.util.make_text_document_params(bufnr) },
    function(err, symbols)
      if err or not symbols then
        vim.notify('IntelliJ LSP: could not resolve a class at the cursor.', vim.log.levels.ERROR)
        return
      end

      local row = vim.api.nvim_win_get_cursor(0)[1] - 1
      local class = M._enclosing_class(bufnr, flatten_classes(symbols), row)
      if not class then
        vim.notify('IntelliJ LSP: no class encloses the cursor.', vim.log.levels.ERROR)
        return
      end

      launch(class, vim.uri_from_bufnr(bufnr), no_debug == nil or no_debug, { client = c })
    end
  )
end

--- Stops the running launch, its build included: the build runs inside the launch on the server,
--- so terminating the session ends whichever of the two is running.
---
--- nvim-dap has one active session at a time, so terminating it is unambiguous; a second `<leader>rr`
--- while one is running starts a second session and nvim-dap itself asks which to terminate.
function M.stop()
  -- A test run still waiting on the server has no session yet; test.lua drops it instead.
  local test = package.loaded['intellij-lsp.test']
  if test and test.stop() then return end
  if not M.has_dap() then return end
  require('dap').terminate()
end

function M.setup()
  register_lens_command()
  ensure_dap_adapter()
  -- `q` closes the panel without stopping the program; this is the key that stops it.
  output.keymap('<C-c>', M.stop, 'IntelliJ: stop the build or the running program')

  vim.api.nvim_create_user_command('IntellijLspRun', function() M.run_at_cursor(true) end, {
    desc = 'IntelliJ: run the main class at the cursor',
  })
  vim.api.nvim_create_user_command('IntellijLspRunStop', M.stop, {
    desc = 'IntelliJ: stop the build or the running program',
  })
end

return M
