--- Neovim client for the IntelliJ Language Server (Java + Kotlin).
---
--- Usage:
---
---   require('intellij-lsp').setup({
---     server_path = '/path/to/intellij-server/bin/intellij-server',
---   })

local client = require('intellij-lsp.client')
local progress = require('intellij-lsp.progress')

local M = {}

--- @class IntellijLspConfig
--- @field server_path string|nil   path to `bin/intellij-server`; unset downloads the published
---                                 bundle for this platform
--- @field server_download boolean|nil
---                                 download the bundle for this platform when server_path is
---                                 unset (default true); false makes server_path required
--- @field accept_eula boolean|nil  accept the bundle's EULA (required for released bundles)
--- @field build_tool string|nil    force an importer: "maven"|"gradle"|"bazel"|"jps"; "" skips import
--- @field default_sdk string|nil   JDK home used to analyze code (not to run the server)
--- @field projects table[]|nil     explicitly configured projects
--- @field disable_rocksdb_wal boolean|nil
--- @field jvm_args string[]|nil    extra JVM options for the server process
--- @field filetypes string[]|nil   defaults to { 'java', 'kotlin' }
--- @field autotrigger boolean|nil  open the completion menu on '.' (default true); set false to
---                                 require <C-x><C-o>, e.g. when using your own completion plugin
--- @field completeopt string[]|string|boolean|nil
---                                 by default 'menuone' and 'fuzzy' are added to 'completeopt', so
---                                 that dotted candidates ("java.util" while typing
---                                 "import java.ut") survive filtering; false keeps your value, a
---                                 table or string sets it
--- @field enter_accepts_completion boolean|nil
---                                 map <CR> to accept the selected completion instead of inserting
---                                 a newline (default true); Enter still opens a line when no
---                                 completion menu is visible
--- @field word_triggers boolean|nil also request completion while typing letters, digits and '_',
---                                 not only after the server's '.' (default true); this is what
---                                 keeps the menu alive as you type and what completes plain
---                                 identifiers such as locals in scope
--- @field completion_delay integer|nil
---                                 ms after the first letter of a word before completion is
---                                 requested; the reply opens the menu while you keep typing
---                                 (default 100)
--- @field references boolean|nil   `grr` opens a quickfix list that live-previews the selected
---                                 reference in the editor window (default true); false keeps
---                                 Neovim's built-in `grr`
--- @field inlay_hints boolean|nil  show parameter and type hints (default true); Neovim advertises
---                                 the capability but never enables it
--- @field inlay_hint_settings table|nil
---                                 merged over the built-in hint defaults; use it to
---                                 switch individual hints off
--- @field folding boolean|nil      fold with the server's `textDocument/foldingRange`, using
---                                 IntelliJ's own fold placeholders (default true)
--- @field document_highlight boolean|nil
---                                 highlight every occurrence of the identifier under the cursor
---                                 after 'updatetime' of stillness (default true)
--- @field signature_help boolean|nil
---                                 open the parameter popup when typing `(` or `,` inside a call
---                                 (default true); <C-S> in insert mode still works either way
--- @field keymaps boolean|nil      install the buffer-local <leader> maps for type and call
---                                 hierarchy and workspace symbol search (default true); the
---                                 `:IntellijLsp*` commands exist either way
--- @field format_on_save boolean|nil
---                                 format the whole buffer with IntelliJ's formatter before every
---                                 write (default false); `:IntellijLspFormat` does it by hand
--- @field file_templates boolean|table|nil
---                                 fill a new, empty `.java`/`.kt` file from an IntelliJ file
---                                 template, chosen from a picker (default true); a table
---                                 `{ java = { Name = text }, kotlin = ... }` adds to or replaces
---                                 the built-in templates, false turns the picker off
--- @field intellij_extensions boolean|nil
---                                 opt into the `intellij/` protocol extensions (default true);
---                                 without it the server drops quick fixes that copy to the
---                                 clipboard or ask you to choose a variant
--- @field decompiler boolean|nil   open `jar:`/`jrt:` URIs as decompiled source (default true)
--- @field rename_files boolean|nil register `:IntellijLspRename`, which updates references before
---                                 moving a file on disk (default false)
--- @field colorscheme boolean|nil  apply the bundled "islands-dark" scheme, a port of IntelliJ's
---                                 default dark editor scheme, unless you already chose one
---                                 (default true)
--- @field nowrap boolean|nil       set 'nowrap', so a long line scrolls right instead of wrapping,
---                                 like IntelliJ's default (default false)
--- @field progress boolean|nil     report import and indexing phase in the message area, on one
---                                 self-updating line (default true)
--- @field build_output string|nil  when the output panel opens with the build tool's import log:
---                                 'always' (on every import start), 'on_failure' (default) or
---                                 'never'; `:IntellijLspOutput` opens it by hand at any time
--- @field single_key_select boolean|nil
---                                 answer numbered prompts (`vim.ui.select`) with a bare digit
---                                 instead of a digit plus <CR> (default true); lists longer than
---                                 nine entries still use the built-in line prompt
--- @field git boolean|nil          register `:IntellijGitStatus` and `:IntellijGitDiff` (default
---                                 true); these drive the `git` CLI and work independently of the
---                                 language server, in any filetype
--- @field run boolean|nil          run a JVM main class with its output in a panel, via
---                                 `<leader>rr`, `:IntellijLspRun` and the server's Run/Debug code
---                                 lenses (default true); requires nvim-dap, and the code lenses are
---                                 requested from the server only when nvim-dap is installed
--- @field build_before_run boolean|nil
---                                 compile the module with its build tool (`mvn compile`, `gradle
---                                 classes`) before each run or debug launch (default true); false
---                                 launches whatever is already compiled, as `:IntellijLspRun!`
---                                 does for one launch

--- @type IntellijLspConfig
M.config = {}

local function expand(path)
  return path and vim.fn.expand(path) or nil
end

--- Starts (or reuses) a server for the given buffer.
---
--- The ancestor check is not an optimization. `vim.lsp.start` only reuses a client whose workspace
--- folder URIs match *exactly*, while eager activation roots the server at the working directory and
--- `find_root` walks up from the file -- so in a multi-module build the two disagree (`cwd` vs.
--- `cwd/app`) and `vim.lsp.start` would start a second server on the same project, importing and
--- indexing it twice.
--- @param bufnr integer
local function start_for_buffer(bufnr)
  if vim.b[bufnr].intellij_lsp_attached then return end

  -- Attach to a server that already covers this file, whatever root it was started with.
  local name = vim.api.nvim_buf_get_name(bufnr)
  local existing = name ~= '' and client.find_ancestor_client(name) or nil
  if existing then
    vim.b[bufnr].intellij_lsp_attached = true
    vim.lsp.buf_attach_client(bufnr, existing.id)
    return
  end

  local root_dir = client.find_root(bufnr)
  if not root_dir then return end

  vim.b[bufnr].intellij_lsp_attached = true
  vim.lsp.start(client.config(root_dir, M.config), { bufnr = bufnr })
end

--- Starts the server from a build file in the working directory, with no source file open.
---
--- A user who opens a project and starts by reading `pom.xml` or by browsing with `:Ex` gets the
--- import running immediately instead of waiting for the first .java file. The import is the long
--- pole on a cold index, so starting it a minute earlier is most of the benefit.
---
--- `attach = false` is the load-bearing part. There is no buffer to attach to at this point: with no
--- file argument the current buffer is an unnamed scratch, and attaching a server to it would have
--- Neovim send `textDocument/didOpen` for a document that does not exist. Neovim honours
--- `attach = false` by returning the client id and skipping the buffer entirely, which is exactly the
--- "warm the server, attach later" shape wanted here; the FileType path then attaches to this client
--- through `find_ancestor_client`.
--- Shared directories that must never be imported as a project.
---
--- `find_build_root` walks upward, so a stray `pom.xml` dropped directly into the home or temp
--- directory -- a leftover from a test, an unpacked archive -- would make the shared directory itself
--- the root: an import spanning every project inside it. Declining costs nothing, because opening a
--- source file still starts the server normally, with the file's own root.
---
--- Compared through `fs_realpath`, not `normalize`: on macOS `/tmp` is a symlink to `/private/tmp` and
--- `$TMPDIR` lives under `/var/folders`, so comparing unresolved paths lets a `cd /tmp` slip straight
--- past. `os_tmpdir` rather than `tempname`, which returns a private per-session subdirectory nobody
--- ever cds into.
--- @param dir string
--- @return boolean
local function is_shared_dir(dir)
  local function resolve(path)
    return path and vim.fs.normalize(vim.uv.fs_realpath(path) or path) or nil
  end

  local skip = {}
  for _, shared in ipairs({ '/', '/tmp', vim.uv.os_homedir(), vim.uv.os_tmpdir() }) do
    local resolved = resolve(shared)
    if resolved then skip[resolved] = true end
  end
  return skip[resolve(dir) or dir] == true
end

M._is_shared_dir = is_shared_dir

local function start_eagerly()
  -- Global rather than per-directory on purpose: a `:cd` into another project mid-session is not a
  -- request to import it. `:IntellijLspRestart` is the escape hatch.
  if vim.g.intellij_lsp_eager_started then return end

  -- A single file argument (`nvim Foo.java`) needs no help: FileType fires for it a moment later and
  -- resolves a root from the file itself, which is a better root than the working directory. Guarding
  -- here also keeps `nvim ~/notes.md` from importing whatever happens to sit in the home directory.
  if vim.fn.argc() > 0 then return end

  -- `nvim -` reads the buffer from stdin and has no project context at all.
  if vim.g.intellij_lsp_stdin_read then return end

  local cwd = vim.fs.normalize(vim.uv.cwd() or '')
  if cwd == '' or is_shared_dir(cwd) then return end

  local root_dir = client.find_build_root(cwd)
  if not root_dir then return end

  vim.g.intellij_lsp_eager_started = true
  vim.lsp.start(client.config(root_dir, M.config), { attach = false })
end

--- Stops every server started by this plugin.
--- @return string|nil index_dir reported by the stopped client, if any
local function stop_all()
  local index_dir
  for _, c in ipairs(vim.lsp.get_clients({ name = client.NAME })) do
    index_dir = index_dir or c.config.index_dir
    progress.reset(c.id)
    require('intellij-lsp.status').reset(c.id)
    c:stop()
  end
  -- Decompiled sources are keyed by URI and would otherwise survive a restart, serving stale output
  -- after a rebuild changed the class files. Guarded so a session with `decompiler = false` never
  -- loads the module.
  if package.loaded['intellij-lsp.decompiler'] then
    require('intellij-lsp.decompiler').reset()
  end
  return index_dir
end

--- Clears the attach guards so the next pass re-attaches.
---
--- Called only from the restart paths, right after `stop_all`, which is what makes clearing the eager
--- guard safe here: the client it was guarding is gone. Doing it in `attach_loaded_buffers` instead
--- would clear it on the `setup()` path too, where the eager start may legitimately have run already.
local function clear_attach_flags()
  vim.g.intellij_lsp_eager_started = nil
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(bufnr) then
      vim.b[bufnr].intellij_lsp_attached = nil
    end
  end
end

--- Re-attaches every loaded buffer whose filetype this plugin serves.
---
--- Redoes the eager start first, so the loop below finds its client via `find_ancestor_client` and
--- attaches to it rather than racing it with a second `vim.lsp.start` on a narrower root. On the
--- restart paths this is also what brings an eagerly-started server back at all: `stop_all` kills it
--- too, and in a session with no Java buffer open there would otherwise be nothing left to re-attach,
--- so `:IntellijLspRestart` would read as having broken the plugin.
local function attach_loaded_buffers()
  start_eagerly()

  local filetypes = M.config.filetypes or client.FILETYPES
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(bufnr) and vim.tbl_contains(filetypes, vim.bo[bufnr].filetype) then
      start_for_buffer(bufnr)
    end
  end
end

function M.restart()
  stop_all()
  clear_attach_flags()
  -- Give the old process time to release its lock on the index before restarting.
  vim.defer_fn(attach_loaded_buffers, 500)
end

--- Stops the server, deletes its index directory, and starts again.
---
--- Deletion happens while the server is down: RocksDB holds a lock on the index directory, so
--- clearing it under a live server would corrupt the index.
function M.clear_cache()
  local index_dir = stop_all()
  clear_attach_flags()

  if not index_dir then
    vim.notify(
      'IntelliJ LSP: no index directory reported; restarting without clearing.',
      vim.log.levels.WARN
    )
    vim.defer_fn(attach_loaded_buffers, 500)
    return
  end

  vim.defer_fn(function()
    local ok, err = pcall(vim.fn.delete, index_dir, 'rf')
    if ok then
      vim.notify('IntelliJ LSP: cleared ' .. index_dir, vim.log.levels.INFO)
    else
      vim.notify('IntelliJ LSP: failed to clear index: ' .. tostring(err), vim.log.levels.ERROR)
    end
    attach_loaded_buffers()
  end, 500)
end

--- Re-applies configuration without a restart.
---
--- The server re-reads `initializationOptions` from the request payload rather than reusing the ones
--- from `initialize`, so this is the supported way to change `build_tool`, `default_sdk` or the inlay
--- hint settings on a running server. Re-importing a Gradle project is not cheap, which is why this
--- is a command and not a `BufWritePost` hook on build files.
function M.reload()
  local clients = vim.lsp.get_clients({ name = client.NAME })
  if #clients == 0 then
    vim.notify('IntelliJ LSP: no server running.', vim.log.levels.WARN)
    return
  end

  for _, c in ipairs(clients) do
    local root = c.config.root_dir
    c:request('intellij/reloadWorkspace', {
      initializationOptions = client.init_options(root, M.config),
    }, function(err)
      if err then
        -- ServerCancelled is what a parked (unlicensed) server answers; :checkhealth explains it.
        vim.notify(
          'IntelliJ LSP: reload failed: ' .. tostring(err.message or err),
          vim.log.levels.ERROR
        )
      else
        vim.notify('IntelliJ LSP: workspace reloaded.', vim.log.levels.INFO)
      end
    end)
  end
end

--- Renames a file, updating references first.
---
--- Order matters and is not interchangeable: the server resolves the edit against the file still
--- being at its old path, so `workspace/willRenameFiles` has to be answered and applied *before* the
--- move. If applying the edit fails the move is abandoned, because a moved file with stale references
--- is worse than no rename at all.
--- @param new_path string
function M.rename_file(new_path)
  local c = vim.lsp.get_clients({ name = client.NAME })[1]
  if not c then
    vim.notify('IntelliJ LSP: no server running.', vim.log.levels.WARN)
    return
  end

  local old_path = vim.api.nvim_buf_get_name(0)
  if old_path == '' then
    vim.notify('IntelliJ LSP: current buffer has no file.', vim.log.levels.ERROR)
    return
  end
  new_path = vim.fn.fnamemodify(vim.fn.expand(new_path), ':p')

  c:request('workspace/willRenameFiles', {
    files = { { oldUri = vim.uri_from_fname(old_path), newUri = vim.uri_from_fname(new_path) } },
  }, function(err, result)
    vim.schedule(function()
      if err then
        vim.notify(
          'IntelliJ LSP: rename aborted, server error: ' .. tostring(err.message or err),
          vim.log.levels.ERROR
        )
        return
      end

      if result then
        local ok, apply_err = pcall(vim.lsp.util.apply_workspace_edit, result, c.offset_encoding)
        if not ok then
          vim.notify(
            'IntelliJ LSP: rename aborted, could not update references: ' .. tostring(apply_err),
            vim.log.levels.ERROR
          )
          return
        end
      end

      vim.fn.mkdir(vim.fs.dirname(new_path), 'p')
      local moved, move_err = pcall(vim.fn.rename, old_path, new_path)
      if not moved or move_err ~= 0 then
        vim.notify('IntelliJ LSP: references updated but the move failed.', vim.log.levels.ERROR)
        return
      end

      -- Reopen at the new path so the buffer is not left pointing at a file that no longer exists.
      vim.cmd.edit(vim.fn.fnameescape(new_path))
      vim.cmd('bwipeout! ' .. vim.fn.fnameescape(old_path))
      vim.notify('IntelliJ LSP: renamed to ' .. new_path, vim.log.levels.INFO)
    end)
  end)
end

--- The part of `setup()` that needs a server: autocmds, commands, and the first start.
--- Runs once `M.config.server_path` is known, either from the user or from a download.
local function finish_setup()
  -- On by default: the first import and index run for minutes with nothing else to show for them,
  -- and this reports into the message area rather than taking over any of the user's UI. The
  -- teardown matters because plugin managers re-run specs, so setup() may run again with the flag
  -- flipped off, and the handlers from the previous call would otherwise survive.
  local status = require('intellij-lsp.status')
  if M.config.progress then
    status.setup_autocmds()
  else
    status.teardown_autocmds()
  end

  -- Same re-`setup()` reasoning as above. This one touches a global Neovim entry point rather than
  -- our own autocmds, so it wraps the existing `vim.ui.select` instead of replacing it, and hands
  -- back anything it will not answer with a single key.
  local select = require('intellij-lsp.select')
  if M.config.single_key_select then
    select.setup()
  else
    select.teardown()
  end

  local group = vim.api.nvim_create_augroup('IntellijLsp', { clear = true })

  vim.api.nvim_create_autocmd('FileType', {
    group = group,
    pattern = M.config.filetypes,
    callback = function(args) start_for_buffer(args.buf) end,
  })

  -- StdinReadPost fires before VimEnter, so this flag is reliably set by the time the eager check
  -- runs. `nvim -` has no project context, and its buffer is unnamed, so there is nothing to root on.
  vim.api.nvim_create_autocmd('StdinReadPost', {
    group = group,
    desc = 'IntelliJ: remember that the buffer came from stdin',
    callback = function() vim.g.intellij_lsp_stdin_read = true end,
  })

  vim.api.nvim_create_user_command('IntellijLspRestart', M.restart, {
    desc = 'Restart the IntelliJ language server',
  })
  vim.api.nvim_create_user_command('IntellijLspClearCache', M.clear_cache, {
    desc = 'Clear the IntelliJ language server index and restart',
  })
  progress.configure({ build_output = M.config.build_output })
  vim.api.nvim_create_user_command('IntellijLspOutput', progress.open_log, {
    desc = 'Open the output panel: build tool import log and program output',
  })
  -- The panel's old name, from when it held only the import log.
  vim.api.nvim_create_user_command('IntellijLspLog', progress.open_log, {
    desc = 'Open the output panel (alias of :IntellijLspOutput)',
  })
  -- Registered even with `references = false`: it is then the only way to reach the feature, and it
  -- gives users who bind their own key something to call.
  vim.api.nvim_create_user_command('IntellijLspReferences', function()
    require('intellij-lsp.references').run()
  end, {
    desc = 'Browse references with a previewing quickfix list',
  })
  vim.api.nvim_create_user_command('IntellijLspReload', M.reload, {
    desc = 'Re-apply configuration on the running IntelliJ language server',
  })
  -- Hierarchies, formatting and symbol search: global commands over per-buffer features, so they
  -- exist whether or not a buffer is attached yet.
  require('intellij-lsp.editor').register_commands()
  -- Compiler errors and the workspace export.
  require('intellij-lsp.workspace').register_commands()
  -- New files: BufNewFile only flags the buffer; the template is requested from `on_attach`, once a
  -- client exists to ask.
  if M.config.file_templates ~= false then
    local templates = require('intellij-lsp.templates')
    templates.setup_autocmd(group, M.config.filetypes)
    vim.api.nvim_create_user_command('IntellijLspFileTemplate', templates.command, {
      desc = 'Fill this empty file from an IntelliJ file template',
    })
  end
  if M.config.rename_files then
    vim.api.nvim_create_user_command('IntellijLspRename', function(args)
      M.rename_file(args.args)
    end, {
      nargs = 1,
      complete = 'file',
      desc = 'Rename the current file, updating references first',
    })
  end

  -- Global rather than per-buffer: the BufReadCmd has to exist before the jar:/jrt: buffer does.
  if M.config.decompiler then
    require('intellij-lsp.decompiler').setup()
  end

  -- Unlike the git wiring above, this sits *after* the server_path check: running resolves the
  -- classpath, the JDK and the working directory through the language server, so with no server there
  -- is nothing the commands could do. It must still run before the first attach, because `on_attach`
  -- installs the code-lens refresh and the lens handler registered here is what a click dispatches to.
  if M.config.run then
    require('intellij-lsp.run').setup({ build_before_run = M.config.build_before_run })
  end

  -- After `run.setup`, and dependent on it: debugging launches through `run.launch` with `noDebug`
  -- flipped, so it needs the adapter and the lens command that call registers. Gated on `run` as well as
  -- `debug` for that reason -- `debug = true, run = false` would leave no adapter to launch through, so
  -- the breakpoint keymaps would set breakpoints nothing could ever hit.
  if M.config.run and M.config.debug then
    require('intellij-lsp.debug').setup()
  end

  -- Both halves are needed. A plugin manager that loads lazily or on VimEnter has already missed the
  -- event by the time setup() runs, so `vim_did_enter` is checked and the scan runs inline; an eagerly
  -- sourced config instead runs setup() before startup finishes, where the working directory and the
  -- argument list are settled only at VimEnter. `start_eagerly` is idempotent, so the two never both
  -- start a server.
  if vim.v.vim_did_enter == 1 then
    start_eagerly()
  else
    vim.api.nvim_create_autocmd('VimEnter', {
      group = group,
      once = true,
      desc = 'IntelliJ: start from a build file, with no source file open',
      callback = start_eagerly,
    })
  end

  -- setup() usually runs after the first buffer is already loaded.
  attach_loaded_buffers()
end

--- @param opts IntellijLspConfig
function M.setup(opts)
  opts = opts or {}
  M.config = vim.tbl_extend('force', {
    accept_eula = false,
    server_download = true,
    projects = {},
    disable_rocksdb_wal = false,
    filetypes = client.FILETYPES,
    autotrigger = true,
    references = true,
    inlay_hints = true,
    folding = true,
    document_highlight = true,
    signature_help = true,
    keymaps = true,
    format_on_save = false,
    file_templates = true,
    intellij_extensions = true,
    decompiler = true,
    rename_files = false,
    colorscheme = true,
    nowrap = false,
    progress = true,
    build_output = 'on_failure',
    single_key_select = true,
    git = true,
    run = true,
    build_before_run = true,
    debug = true,
  }, opts)
  M.config.server_path = expand(M.config.server_path)
  M.config.default_sdk = expand(M.config.default_sdk)

  -- Applied before the server_path check so that a misconfigured server still leaves you with the
  -- colours you asked for. On by default, but yields to a scheme already in effect: setup() usually
  -- runs from a plugin spec, which may execute after the user's own `:colorscheme` line.
  if M.config.colorscheme then
    require('intellij-lsp.theme').enable()
  end

  if M.config.nowrap then
    vim.opt.wrap = false
  end

  -- Registered before the server_path check, like the colorscheme above: git integration drives the
  -- `git` CLI and never touches vim.lsp, so a session with no server configured -- or one opened in a
  -- repository with no Java in it at all -- should still get these commands.
  if M.config.git then
    require('intellij-lsp.git').setup()
  end

  -- With no `server_path`, fetch the published bundle for this platform. `ensure` calls back
  -- synchronously when the bundle is cached, and from `vim.schedule` after a download.
  if M.config.server_path then
    finish_setup()
  elseif M.config.server_download ~= false then
    require('intellij-lsp.server_download').ensure(function(path, err)
      if not path then
        vim.notify('IntelliJ LSP: could not download the server: ' .. err, vim.log.levels.ERROR)
        return
      end
      M.config.server_path = path
      finish_setup()
    end)
  else
    vim.notify(
      'IntelliJ LSP: `server_path` is required (path to bin/intellij-server).',
      vim.log.levels.ERROR
    )
  end
end

return M
