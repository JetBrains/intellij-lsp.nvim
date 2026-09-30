--- Runs a JVM main class through the language server, with output in the shared bottom panel.
---
--- Nothing here resolves a classpath or a JDK itself: `intellij.java.resolveLaunch` composes the
--- whole launch server-side in one round trip, and this module's only job is to call it, hand the
--- answer to nvim-dap, and render the DAP `output` events that follow.
---
--- The one thing the server deliberately does *not* do is compile. A launch is a plain `java` on
--- whatever is in the output directory, so before each one this module asks
--- `intellij.java.resolveBuildCommand` for the build tool's own compile invocation and runs it, with
--- its output in the same panel; see "Building before a launch" below.
---
--- `has_dap()` gates both this module's own commands and, through `client.lua`'s `runMainCodeLens`
--- init option, whether the server emits Run/Debug lenses at all: a lens that renders and then fails
--- on click is worse than no lens.

local M = {}

local output = require('intellij-lsp.output')

--- The DAP adapter type a plain `java` launch uses. `intellij_gradle` exists for a module a build
--- tool launches instead, which this module does not resolve; nvim-dap here only ever runs the JVM
--- adapter.
local ADAPTER_ID = 'intellij_jvm'

--- Whether nvim-dap is installed.
---
--- Checked with `pcall(require, ...)` rather than `package.loaded`, because the latter is false for a
--- plugin manager that has not lazy-loaded it yet even though `require` would succeed.
--- @return boolean
function M.has_dap()
  return (pcall(require, 'dap'))
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
  dap.adapters[ADAPTER_ID] = function(callback, config)
    local c = vim.lsp.get_clients({ name = require('intellij-lsp.client').NAME })[1]
    if not c then
      vim.notify('IntelliJ LSP: no server running, cannot start a debug session.', vim.log.levels.ERROR)
      return
    end

    c:request('workspace/executeCommand', {
      command = 'start_debug_server',
      arguments = { vim.uri_from_fname(c.config.root_dir) },
    }, function(err, port)
      if err or not port then
        vim.notify(
          'IntelliJ LSP: failed to start the debug server: ' .. tostring(err and (err.message or err)),
          vim.log.levels.ERROR
        )
        return
      end
      -- `id` is what nvim-dap sends as the DAP `initialize` request's `adapterID`; without it nvim-dap
      -- falls back to the literal string 'nvim-dap', which the server then rejects as an unknown
      -- adapter id.
      callback({ type = 'server', host = '127.0.0.1', port = port, id = ADAPTER_ID })
    end)

    -- Unused but required by nvim-dap's adapter signature; the launch never needs to react to it.
    return config
  end
end

--- Resolves the full launch (classpath, JDK, working directory, VM args) for `main_class`.
---
--- One `workspace/executeCommand` round trip: the server composes every fragment in a single read
--- action, so there is nothing left here to assemble or to forget a piece of (`resolveClasspath` /
--- `resolveJavaExecutable` / `resolveWorkingDirectory` used to be three separate commands and three
--- separate round trips; the server merged them for exactly that reason).
--- @param client vim.lsp.Client
--- @param uri string
--- @param cb fun(err: table|nil, paths: table|nil)
local function resolve_launch(client, uri, cb)
  client:request('workspace/executeCommand', {
    command = 'intellij.java.resolveLaunch',
    arguments = { { uri = uri } },
  }, function(err, result) cb(err, result) end)
end

-- -------------------------------------------------------------------------------------------------
-- Building before a launch
-- -------------------------------------------------------------------------------------------------

--- The server compiles nothing itself. `intellij.java.resolveBuildCommand` answers with the build
--- tool's own compile invocation for the module owning a document -- `./mvnw -pl :app -am compile`,
--- `gradlew :app:classes` -- and the client is expected to run it before a plain-JVM launch. Without
--- that, a fresh clone launches straight into `Could not find or load main class`, and an edited
--- class silently runs the previous build. The second is the one that costs an afternoon.
---
--- The price is a build-tool invocation on every launch, even with nothing changed: several seconds
--- of Maven before the first line of program output. There is no cheap way to know that nothing
--- changed (resources, generated sources, a dependency bump), so nothing here tries; the escape hatch
--- is `:IntellijLspRun!`, or `build_before_run = false` to make skipping the default.

--- Whether a build precedes each launch. Set from `setup()`.
local build_before_run = true

--- The build in flight, if any. One at a time: a second launch during a build is refused rather than
--- queued, because two builds would race for the same output directory.
--- @type { proc: vim.SystemObj, cancelled: boolean }|nil
local building = nil

--- The build to run for a `resolveBuildCommand` answer, or nil with the server's reason when there is
--- nothing to run.
---
--- A `supported` answer with an empty command also counts as nothing to run: a command that builds
--- nothing would report success while compiling nothing.
--- @param resolved table|nil
--- @return { command: string[], cwd: string|nil, tool: string|nil }|nil build
--- @return string|nil reason the server's user-visible explanation, when it gave one
function M._build_to_run(resolved)
  if type(resolved) ~= 'table' then return nil, nil end
  if resolved.supported == false then return nil, resolved.reason end
  if type(resolved.command) ~= 'table' or #resolved.command == 0 then return nil, nil end
  return { command = resolved.command, cwd = resolved.cwd, tool = resolved.tool }, nil
end

--- Same shape as the import log's separators in `progress.lua`, so a build's boundaries are findable
--- the same way in a buffer that also holds program output.
--- @param text string
--- @return string
local function separator(text)
  return '--- ' .. text .. ' ---'
end

--- A line-splitting sink for one of the build's streams.
---
--- Chunks arrive at arbitrary boundaries, and the highlight is decided per *line* (a `[ERROR]`
--- prefix, a `BUILD FAILURE` summary), so the trailing partial line is held back until the next
--- chunk completes it. `flush` writes whatever is left when the process exits.
--- @return fun(err: string|nil, data: string|nil) on_data
--- @return fun() flush
local function line_sink()
  local hl = require('intellij-lsp.progress')._import_hl
  local rest = ''
  local function on_data(_, data)
    if not data then return end
    local lines = vim.split(rest .. data, '\n', { plain = true })
    rest = table.remove(lines)
    for _, line in ipairs(lines) do output.append(line, hl(nil, line)) end
  end
  local function flush()
    if rest ~= '' then output.append(rest, hl(nil, rest)) end
    rest = ''
  end
  return on_data, flush
end

--- Runs a resolved build with its output streamed into the panel, then calls `cb(ok)`.
---
--- Exit 0 is `ok`. A non-zero exit, or a command that could not be spawned at all (no `mvn` on PATH),
--- is not, and opens the panel *with* focus: the next thing the user does is `<CR>` on the error. A
--- build stopped through `M.stop()` never calls back -- there is no launch to continue to.
--- @param build { command: string[], cwd: string|nil, tool: string|nil }
--- @param cb fun(ok: boolean)
function M._run_build(build, cb)
  local progress = require('intellij-lsp.progress')
  local label = build.tool or 'build tool'
  local started = vim.uv.now()
  output.append(separator(('%s: building: %s'):format(label, table.concat(build.command, ' '))), 'Title')
  output.open({ focus = false })

  local on_stdout, flush_stdout = line_sink()
  local on_stderr, flush_stderr = line_sink()

  -- `vim.system` raises rather than reporting a spawn failure through the callback.
  local spawned, proc = pcall(vim.system, build.command, {
    cwd = build.cwd,
    text = true,
    -- The stream callbacks run in libuv's fast context; `output.append` only queues and schedules,
    -- which is allowed there, but wrapping keeps that from being a rule this module has to remember.
    stdout = vim.schedule_wrap(on_stdout),
    stderr = vim.schedule_wrap(on_stderr),
  }, vim.schedule_wrap(function(result)
    flush_stdout()
    flush_stderr()
    local this = building
    building = nil
    local took = progress._elapsed(vim.uv.now() - started)
    if this and this.cancelled then
      output.append(separator(label .. ': build stopped'), 'DiagnosticWarn')
      return
    end
    if result.code == 0 then
      output.append(separator(('%s: build succeeded (%s)'):format(label, took)), 'DiagnosticOk')
      cb(true)
    else
      output.append(separator(('%s: build failed, exit %d (%s)'):format(label, result.code, took)), 'DiagnosticError')
      output.open()
      cb(false)
    end
  end))

  if not spawned then
    output.append(separator(label .. ': build failed to start: ' .. tostring(proc)), 'DiagnosticError')
    output.open()
    cb(false)
    return
  end
  building = { proc = proc, cancelled = false }
end

--- Compiles the module owning `uri`, then calls `cb(ok)`; `ok` means the launch may proceed.
---
--- Only a build that actually ran and failed stops a launch. A failed *lookup* -- a server error, or
--- a module no registered build tool can compile (a plain JPS project) -- launches whatever is on
--- disk and says so in the panel: a launch the user asked for is not
--- refused because the build could not even be determined.
--- @param client vim.lsp.Client
--- @param uri string
--- @param cb fun(ok: boolean)
function M._build(client, uri, cb)
  client:request('workspace/executeCommand', {
    command = 'intellij.java.resolveBuildCommand',
    arguments = { { uri = uri } },
  }, function(err, resolved)
    vim.schedule(function()
      if err then
        output.append(separator('build skipped: ' .. tostring(err.message or err)), 'DiagnosticWarn')
        return cb(true)
      end
      local build, reason = M._build_to_run(resolved)
      if not build then
        if reason then output.append(separator('build skipped: ' .. reason), 'DiagnosticWarn') end
        return cb(true)
      end
      M._run_build(build, cb)
    end)
  end)
end

-- -------------------------------------------------------------------------------------------------
-- Launching
-- -------------------------------------------------------------------------------------------------

--- Starts a launch through nvim-dap, after building the module unless told not to.
---
--- `noDebug = true` is what makes this a *run* rather than a *debug*: the adapter still starts the
--- same JDWP-suspended JVM (see README "A breakpoint set before launching is honoured"), and nvim-dap
--- simply tells the server not to wait on the debug protocol handshake for output to start flowing.
--- @param main_class string fully qualified class name
--- @param uri string the class's source document, so the server can resolve without a round trip
--- @param no_debug boolean
--- @param opts { build: boolean|nil }|nil `build = false` launches whatever is already compiled
local function launch(main_class, uri, no_debug, opts)
  if not M.has_dap() then
    vim.notify('IntelliJ LSP: running requires nvim-dap (mfussenegger/nvim-dap).', vim.log.levels.ERROR)
    return
  end

  local client_module = require('intellij-lsp.client')
  local c = vim.lsp.get_clients({ name = client_module.NAME })[1]
  if not c then
    vim.notify('IntelliJ LSP: no server running.', vim.log.levels.ERROR)
    return
  end

  if building then
    vim.notify('IntelliJ LSP: a build is already running; <C-c> in the output panel stops it.', vim.log.levels.WARN)
    return
  end

  ensure_dap_adapter()

  local function start()
    resolve_launch(c, uri, function(err, paths)
      vim.schedule(function()
        if err then
          vim.notify(
            'IntelliJ LSP: could not resolve the launch: ' .. tostring(err.message or err),
            vim.log.levels.ERROR
          )
          return
        end
        if not paths or not paths.javaExec then
          vim.notify('IntelliJ LSP: the server returned no launch (no project JDK?).', vim.log.levels.ERROR)
          return
        end

        require('dap').run({
          type = ADAPTER_ID,
          request = 'launch',
          name = main_class,
          mainClass = main_class,
          classPaths = paths.classpath or {},
          modulePaths = paths.modulePath or {},
          moduleName = paths.moduleName,
          moduleContentPaths = paths.moduleContentPaths or {},
          javaExec = paths.javaExec,
          vmArgs = paths.vmArgs or {},
          cwd = paths.workingDirectory,
          -- `internalConsole` is load-bearing, not a preference: only it makes the server spawn the
          -- process itself and forward output as DAP `output` events. `integratedTerminal` issues a
          -- `runInTerminal` request this client does not implement, and the panel would stay empty.
          console = 'internalConsole',
          noDebug = no_debug,
        })
      end)
    end)
  end

  if build_before_run and not (opts and opts.build == false) then
    M._build(c, uri, function(ok)
      if ok then start() end
    end)
  else
    start()
  end
end

M.launch = launch

-- -------------------------------------------------------------------------------------------------
-- Output panel
-- -------------------------------------------------------------------------------------------------

--- The program's output goes to the shared panel in `output.lua`, the same buffer the build tool's
--- import log is written to. See that module for why they share one.

if M.has_dap() then
  require('dap').listeners.after.event_output['intellij-lsp.run'] = function(_, body)
    if body and body.output then output.append(body.output) end
  end

  -- Opens on the first output of a session rather than at launch: with none yet there is nothing to
  -- show, and opening early would steal focus before the program has said anything.
  local opened_for = nil
  require('dap').listeners.before.event_output['intellij-lsp.run.panel'] = function(session)
    if opened_for == session.id then return end
    opened_for = session.id
    vim.schedule(output.open)
  end
  require('dap').listeners.after.event_terminated['intellij-lsp.run'] = function(session)
    if opened_for == session.id then opened_for = nil end
  end
end

--- Registers the client-side handler for the server's Run/Debug code lens command.
---
--- `vim.lsp.commands` is the standard extension point `vim.lsp.codelens.run()` and `gra` both dispatch
--- through, so no bespoke keymap wiring is needed for the lens itself -- only for `<leader>rr` below,
--- which has no lens to click.
local function register_lens_command()
  vim.lsp.commands['intellij.jvm.runMain'] = function(command)
    local args = (command.arguments or {})[1] or {}
    if not args.mainClass then return end
    local uri = args.uri or vim.uri_from_bufnr(0)
    launch(args.mainClass, uri, args.noDebug ~= false)
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
--- @param opts { build: boolean|nil }|nil see `launch`
function M.run_at_cursor(no_debug, opts)
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

      launch(class, vim.uri_from_bufnr(bufnr), no_debug == nil or no_debug, opts)
    end
  )
end

--- Stops the build in flight, or else the running launch.
---
--- A build and a program never overlap -- the launch starts only once the build has exited -- so
--- whichever exists is the one `<C-c>` means. The wrapper scripts (`mvnw`, `gradlew`) `exec` the JVM,
--- so the signal reaches the build tool itself and not a shell in front of it.
---
--- nvim-dap has one active session at a time, so terminating it is unambiguous; a second `<leader>rr`
--- while one is running starts a second session and nvim-dap itself asks which to terminate.
function M.stop()
  if building then
    building.cancelled = true
    building.proc:kill('sigterm')
    return
  end
  if not M.has_dap() then return end
  require('dap').terminate()
end

--- @param opts { build_before_run: boolean|nil }|nil
function M.setup(opts)
  if opts and opts.build_before_run ~= nil then build_before_run = opts.build_before_run end
  register_lens_command()
  ensure_dap_adapter()
  -- `q` closes the panel without stopping the program; this is the key that stops it.
  output.keymap('<C-c>', M.stop, 'IntelliJ: stop the build or the running program')

  vim.api.nvim_create_user_command('IntellijLspRun', function(cmd)
    M.run_at_cursor(true, { build = not cmd.bang })
  end, {
    bang = true,
    desc = 'IntelliJ: run the main class at the cursor (! skips the build)',
  })
  vim.api.nvim_create_user_command('IntellijLspRunStop', M.stop, {
    desc = 'IntelliJ: stop the build or the running program',
  })
end

return M
