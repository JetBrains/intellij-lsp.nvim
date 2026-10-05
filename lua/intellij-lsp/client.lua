--- LSP client configuration.

local launch = require('intellij-lsp.launch')
local progress = require('intellij-lsp.progress')
local versions = require('intellij-lsp.versions')

local M = {}

M.NAME = 'intellij'

M.FILETYPES = { 'java', 'kotlin' }

M.ROOT_MARKERS = {
  'pom.xml',
  'build.gradle',
  'build.gradle.kts',
  'settings.gradle',
  'settings.gradle.kts',
  'MODULE.bazel',
  '.git',
}

--- Build files that justify starting the server with no source file open.
---
--- Deliberately NOT `ROOT_MARKERS`: that list ends in `.git`, which is a fine last-resort fallback
--- once we already know we are looking at a Java or Kotlin buffer, but as an *activation* trigger it
--- would mean any checkout of any language starting a multi-minute IntelliJ import with nothing to
--- index.
---
--- Four more build-file names -- `BUILD`, `WORKSPACE`, `WORKSPACE.bazel`, `.bazelproject` -- are
--- left out on purpose, not by oversight. They suit a different and much cheaper question ("did a
--- file the build cares about change, so offer a reload"), which is reversible in a way that an
--- import is not. `BUILD` in
--- particular is a plain extensionless name that collides outside Bazel, and a Bazel repo modern
--- enough to be worth importing has `MODULE.bazel`. Opening any .java/.kt file still starts the
--- server there.
M.BUILD_FILE_MARKERS = {
  'pom.xml',
  'build.gradle',
  'build.gradle.kts',
  'settings.gradle',
  'settings.gradle.kts',
  'BUILD.bazel',
  'MODULE.bazel',
}

local GRADLE_SETTINGS = { 'settings.gradle', 'settings.gradle.kts' }
local GRADLE_BUILD = { 'build.gradle', 'build.gradle.kts' }

--- @param dir string
--- @param names string[]
--- @return boolean
local function has_any(dir, names)
  for _, name in ipairs(names) do
    if vim.uv.fs_stat(dir .. '/' .. name) then return true end
  end
  return false
end

--- Directories that `dir/pom.xml` aggregates, as a set of normalized absolute paths.
---
--- Reads `<module>` (Maven 3) and `<subproject>` (Maven 4) entries with a text match rather than an
--- XML parser, after stripping comments so a commented-out module does not count. Entries inside
--- `<profiles>` count too: a profile module is still part of the build the user would open. An entry
--- may name the module's pom file instead of its directory, which resolves to the same directory.
--- @param dir string
--- @return table<string, true>
local function pom_modules(dir)
  local modules = {}
  local fd = io.open(dir .. '/pom.xml', 'r')
  if not fd then return modules end
  local text = fd:read('*a'):gsub('<!%-%-.-%-%->', '')
  fd:close()
  for _, tag in ipairs({ 'module', 'subproject' }) do
    for entry in text:gmatch('<' .. tag .. '>%s*(.-)%s*</' .. tag .. '>') do
      local path = vim.fs.normalize(dir .. '/' .. entry)
      if path:match('%.xml$') then path = vim.fs.dirname(path) end
      modules[path] = true
    end
  end
  return modules
end

--- Widens a directory holding a build file to the root of the build it belongs to.
---
--- The nearest build file is often one module of a larger build, and imported on its own a module
--- cannot resolve its siblings: in antonarhipov/school-kernel, `kernel-cli` alone fails the Maven
--- import on `kernel-contract:1.0.0-SNAPSHOT`, which leaves no classpath and no completion.
---
---   * Gradle: the nearest `settings.gradle(.kts)` at or above `dir`, which is how Gradle itself
---     finds the build root. A `build.gradle` with no settings file above is its own build.
---   * Maven: climb while an ancestor's `pom.xml` lists the current root as a module. A `pom.xml`
---     nothing lists (an example project, a test fixture) stays a project of its own. `.mvn/` is not
---     used as a shortcut: it marks where Maven reads its config, not which modules form a build.
---   * Bazel's `MODULE.bazel` and the `.git` fallback are roots already.
--- @param dir string
--- @return string
function M.build_root(dir)
  dir = vim.fs.normalize(dir)
  if has_any(dir, GRADLE_SETTINGS) then return dir end

  if vim.uv.fs_stat(dir .. '/pom.xml') then
    local root = dir
    for parent in vim.fs.parents(dir) do
      if pom_modules(parent)[root] then root = parent end
    end
    return root
  end

  if has_any(dir, GRADLE_BUILD) then
    -- Stop below the home directory: a stray `~/settings.gradle` must not swallow every project.
    local settings = vim.fs.find(GRADLE_SETTINGS,
      { path = dir, upward = true, type = 'file', stop = vim.uv.os_homedir() })[1]
    return settings and vim.fs.dirname(settings) or dir
  end

  return dir
end

--- Root of the build that the buffer's file belongs to: the nearest project marker, widened by
--- `build_root` from a module to the build that aggregates it.
--- @param bufnr integer
--- @return string|nil
function M.find_root(bufnr)
  local name = vim.api.nvim_buf_get_name(bufnr)
  if name == '' then return nil end
  local start = vim.fs.dirname(name)
  local marker = vim.fs.find(M.ROOT_MARKERS, { path = start, upward = true })[1]
  return marker and M.build_root(vim.fs.dirname(marker)) or nil
end

--- Whether `dir` is `path` or contains it.
---
--- A plain `startswith` is wrong here: it makes `/work/app` look like an ancestor of
--- `/work/appstore/Foo.java`. The trailing separator is what rules the sibling out.
--- @param dir string
--- @param path string
--- @return boolean
local function contains(dir, path)
  if dir == path then return true end
  local prefix = dir:gsub('/+$', '') .. '/'
  return path:sub(1, #prefix) == prefix
end

M._contains = contains

--- Root to start the server for, based on build files alone, for use with no buffer open.
---
--- Walks upward from `cwd` only, so `nvim` run in `myproject/src/main/java` starts the server on
--- `myproject` rather than on a source directory. A marker in `cwd` itself is covered by the same
--- walk, since `vim.fs.find` inspects the starting directory first.
---
--- An earlier version also matched every build file one directory *down*, as `*/<name>`. That is
--- left out deliberately. A workspace folder in other editors is something the user chose to open;
--- in Neovim the working directory is incidental, and `cd ~/Code && nvim` -- a parent directory
--- holding a dozen checkouts -- is an everyday action. The downward rule matched the first
--- checkout's `pom.xml` and returned `~/Code` as the root, so the server indexed every project
--- under it as one, and then reported that no build system was found there. The `is_shared_dir`
--- guard in init.lua only catches a handful of such directories by name; upward-only removes the
--- whole class.
---
--- The cost: `nvim` in the parent of a single checkout, or in a monorepo whose build files sit only in
--- subdirectories, does not start the import until a source file is opened. Upward-only does not
--- mean module-only, though: the marker found is widened by `build_root`, so `nvim` inside a module
--- of a multi-module build still starts on the whole build.
--- @param cwd string
--- @return string|nil root_dir
function M.find_build_root(cwd)
  cwd = vim.fs.normalize(cwd)
  local marker = vim.fs.find(M.BUILD_FILE_MARKERS, { path = cwd, upward = true, type = 'file' })[1]
  return marker and M.build_root(vim.fs.dirname(marker)) or nil
end

--- An already-running client of ours whose root contains `path`.
---
--- This is what keeps the eager start and the per-buffer start from becoming two servers. Neovim's
--- own reuse check (`reuse_client_default` in runtime/lua/vim/lsp.lua) compares workspace folder URIs
--- for *string equality*, so a client eagerly started at `cwd` is not reused by a buffer whose
--- `find_root` walked up only as far as `cwd/app` -- `vim.lsp.start` would quietly create a second
--- client and pay for a second full import and index of the same project.
---
--- Attaching to the ancestor is also the right answer on the merits, not just the cheap one: it is
--- what VS Code does, where the workspace folder is the root no matter which module a file sits in,
--- and the running server is already mid-import with that root.
--- @param path string absolute file path
--- @return vim.lsp.Client|nil
function M.find_ancestor_client(path)
  if path == '' then return nil end
  path = vim.fs.normalize(path)

  local best --- @type vim.lsp.Client|nil
  local best_root = ''
  -- `_uninitialized`: plain `get_clients` hides a client until its `initialize` round trip is done,
  -- which for this server is seconds of JVM start. A file opened in that window would miss the
  -- eagerly started client and start a second server on its own module root. `buf_attach_client`
  -- accepts an uninitialized client and sends `didOpen` once it is ready.
  for _, c in ipairs(vim.lsp.get_clients({ name = M.NAME, _uninitialized = true })) do
    local root = c.config.root_dir and vim.fs.normalize(c.config.root_dir)
    if root and contains(root, path) then
      -- Deepest wins: with a nested pair of roots the tighter one is the better-scoped project.
      if not best or #root > #best_root then
        best, best_root = c, root
      end
    end
  end
  return best
end

--- Client capabilities.
---
--- `window.workDoneProgress` is load-bearing: the server checks this exact flag before creating any
--- server-initiated progress, and otherwise silently discards all import and indexing progress.
--- Neovim does not advertise it by default.
--- @return lsp.ClientCapabilities
---
--- `workspace.workspaceEdit.snippetEditSupport` is the other one. The server checks it before
--- converting a live template (`ModStartTemplate`) and, without it, drops every fix whose template
--- is mandatory. snippet_edit.lua is what honours the promise.
function M.capabilities()
  local caps = vim.lsp.protocol.make_client_capabilities()
  caps.window = caps.window or {}
  caps.window.workDoneProgress = true
  caps.workspace = caps.workspace or {}
  caps.workspace.workspaceEdit = caps.workspace.workspaceEdit or {}
  caps.workspace.workspaceEdit.snippetEditSupport = true
  return caps
end

--- Inlay hint options, answered over `workspace/configuration`.
---
--- This table is what makes inlay hints appear at all, and its absence is not a soft failure.
--- Before producing a single hint the server asks the client for its own configuration section
--- and enables only the options whose value came back boolean `true`. Neovim answers
--- `workspace/configuration` out of `client.settings`, which is empty by default, so the server
--- sees an empty option set.
---
--- The two languages then diverge, which is why this looked flaky rather than simply off: the
--- Java provider gates *every* one of its four hint kinds on that configuration and so emits
--- nothing at all when it is empty, while the Kotlin provider adds four of its six hint kinds
--- unconditionally and only gates parameter and call-chain hints.
---
--- Nesting depth is load-bearing. Neovim resolves a requested section by splitting it on `.` and
--- walking the table (`jetbrains` -> `java`), while the server flattens whatever it finds below
--- that point by re-joining the path with `.`. So the section must be nested and the option ids
--- below it must stay flat, exactly as written here; hoisting them to `['jetbrains.java.hints...']`
--- resolves to nothing.
local INLAY_HINT_SETTINGS = {
  jetbrains = {
    java = {
      ['hints.collapse complex types'] = true,
      ['hints.settings.method parameter'] = true,
      ['hints.types.local variable'] = true,
      ['settings.types.lambda parameter'] = true,
      ['hints.types.call chain'] = true,
    },
    kotlin = {
      ['hints.settings.types.property'] = true,
      ['hints.settings.types.variable'] = true,
      ['hints.type.function.return'] = true,
      ['hints.type.function.parameter'] = true,
      ['hints.settings.lambda.return'] = true,
      ['hints.lambda.receivers.parameters'] = true,
      ['hints.settings.value.ranges'] = true,
      ['hints.value.kotlin.time'] = true,
      ['hints.parameters'] = true,
      ['hints.parameters.compiled'] = true,
      -- Off: call-chain hints are noisy in a builder-heavy file.
      ['hints.call.chains'] = false,
      ['hints.parameters.excluded'] = false,
    },
  },
}

--- Workspace settings served over `workspace/configuration`.
---
--- `inlay_hint_settings` is merged over the defaults rather than replacing them, so turning a single
--- hint off does not silently drop the rest of the table.
--- @param cfg table
--- @return table
function M.settings(cfg)
  local overrides = (cfg or {}).inlay_hint_settings
  if not overrides then return vim.deepcopy(INLAY_HINT_SETTINGS) end
  return vim.tbl_deep_extend('force', vim.deepcopy(INLAY_HINT_SETTINGS), overrides)
end

--- Initialization options.
---
--- Every initialization option has a server-side default and unknown keys are ignored, so
--- this stays minimal. `buildTools` maps a workspace folder to an importer id: nil/"*" auto-detects,
--- "" skips import, and a concrete id ("maven", "gradle", "bazel", "jps") forces one.
---
--- `intellijExtensions` opts into the `intellij/`-prefixed protocol extensions. It is not merely
--- cosmetic: without it the server maps `ModCopyToClipboard` and `ModChooseAction` to null, and
--- the server propagates that null upwards, so the *entire* quick fix containing one is
--- dropped rather than degraded. Some `gra` actions therefore did nothing at all. Only set it
--- because extensions.lua implements both notifications.
---
--- `runMainCodeLens` asks the server to emit the Run/Debug code lenses above every main method. It
--- stays gated rather than always-on for the reason it was originally left unset: the lens command
--- `intellij_debugger.runMain` is *client-side*, and a lens that renders and then fails on click is
--- worse than no lens. Two things must hold before asking for them -- `run.lua` must have registered
--- the `vim.lsp.commands` handler, and nvim-dap must actually be installed, since it owns the DAP
--- session the handler starts. `run.has_dap()` is the second half of that check.
--- `lazyIntentions` asks the server to *list* fixes without performing them; the fix runs when
--- chosen, through the `applyModCommand` executeCommand that Neovim already dispatches from a code
--- action's `command`. Without it the server performs every candidate fix while answering
--- `textDocument/codeAction`, which is what makes `gra` slow on a line with many diagnostics.
--- Tied to `intellijExtensions`: a lazy client without the extensions gets no `ModChooseAction`
--- fallback, so a fix with variants would fail on pick instead of asking. Unknown to the current
--- bundle, which ignores it; the server at main honours it.
---
--- Note the `vim.NIL`: assigning a Lua nil would drop the key entirely and serialize `buildTools`
--- as `{}`. The server treats an absent key and an explicit null the same way (both auto-detect),
--- but sending the folder explicitly keeps the request self-describing.
--- @param root_dir string
--- @param cfg table user configuration
--- @return table
function M.init_options(root_dir, cfg)
  return {
    buildTools = { [vim.uri_from_fname(root_dir)] = cfg.build_tool or vim.NIL },
    defaultSdk = cfg.default_sdk,
    projects = cfg.projects or {},
    disableRocksDBWriteAheadLog = cfg.disable_rocksdb_wal or false,
    intellijExtensions = cfg.intellij_extensions ~= false,
    lazyIntentions = cfg.intellij_extensions ~= false,
    runMainCodeLens = cfg.run ~= false and require('intellij-lsp.run').has_dap(),
  }
end

--- Code lenses for the buffer, i.e. the ▶ Run / 🐞 Debug lines above every main method.
---
--- Same trap as inlay hints (see `setup_folding`'s neighbour below and the `inlay_hint.enable` call in
--- `on_attach`): Neovim implements `textDocument/codeLens` but does not request it until something
--- enables it, so the feature silently does nothing by default.
---
--- `enable` is a persistent per-buffer setting, not a one-shot fetch: the provider behind it owns the
--- autocmds that re-request on change, debounced by 200ms
--- (`runtime/lua/vim/lsp/codelens.lua`, `Provider:automatic_request`). So this deliberately does *not*
--- drive refreshes itself -- a hand-rolled `BufEnter`/`TextChanged` autocmd would only race that
--- debouncer and duplicate the round-trips. The older `vim.lsp.codelens.refresh({bufnr})` was exactly
--- such a one-shot, and is deprecated for removal in Neovim 0.13.
---
--- `enable` arrived with that reimplementation in 0.12, and this plugin supports 0.11+, so the older
--- one-shot is the fallback there rather than a hard error on a missing field. On 0.11 it needs the
--- autocmd the provider now owns, hence the two branches: same feature, whichever API exists.
---
--- pcall: both entry points validate the buffer, which can already be detached by the time a scheduled
--- attach runs (a server restart does this).
--- @param bufnr integer
function M.setup_codelens(bufnr)
  if vim.lsp.codelens.enable then
    pcall(vim.lsp.codelens.enable, true, { bufnr = bufnr })
    return
  end

  local group = vim.api.nvim_create_augroup('IntellijLspCodeLens' .. bufnr, { clear = true })
  vim.api.nvim_create_autocmd({ 'BufEnter', 'InsertLeave', 'TextChanged' }, {
    group = group,
    buffer = bufnr,
    desc = 'IntelliJ: refresh code lenses',
    callback = function()
      pcall(vim.lsp.codelens.refresh, { bufnr = bufnr })
    end,
  })
  -- The buffer that was already open when the server attached never sees BufEnter.
  pcall(vim.lsp.codelens.refresh, { bufnr = bufnr })
end

--- Folds driven by the server's `textDocument/foldingRange`.
---
--- `vim.lsp.foldexpr` ships with Neovim but nothing installs it; 'foldexpr' has to be set per window.
--- `foldtext` is worth setting alongside it because the server fills `collapsedText` from IntelliJ's
--- own fold placeholder, which is what makes a collapsed import block or method body read the way it
--- does in the IDE instead of showing a line count.
---
--- The fold level is the part that bites: with folds enabled and no start level every file opens
--- fully collapsed, which reads as a broken plugin rather than a feature. Both halves below are
--- needed, and neither substitutes for the other:
---
--- * 'foldlevelstart' is global and seeds 'foldlevel' only at the moment a window *starts* editing a
---   buffer. This function runs from `on_attach`, by which point that moment has already passed, so
---   it does nothing for the window in hand -- it is what keeps *subsequent* files unfolded. Its
---   default is -1 ("not set"), so it is raised only when the user has not chosen a value.
--- * 'foldlevel' is window-local and is what actually unfolds the buffer being attached to. Without
---   it the first file opened in a session comes up fully collapsed while later ones do not, which
---   presents as the plugin folding at random.
---
--- Neovim advertises `lineFoldingOnly`, so the server's character offsets are discarded and folds
--- are always whole lines.
--- @param cfg table
function M.setup_folding(cfg)
  if cfg.folding == false then return end

  local win = vim.api.nvim_get_current_win()
  vim.wo[win][0].foldmethod = 'expr'
  vim.wo[win][0].foldexpr = 'v:lua.vim.lsp.foldexpr()'
  vim.wo[win][0].foldtext = 'v:lua.vim.lsp.foldtext()'
  vim.wo[win][0].foldlevel = 99

  -- -1 is Neovim's default, i.e. "not set by the user".
  if vim.o.foldlevelstart == -1 then vim.o.foldlevelstart = 99 end
end

--- Makes multi-line snippet completions land at the indentation the server computed.
---
--- The Java provider marks every item `insertTextMode = asIs`: a postfix `.for` arrives as
--- `for (Pet ${1:pet} : owner.getPets()) {\n\t\t\t${0}\n\t\t\}`, already indented for the line it
--- replaces. Neovim ignores the mode, and `vim.snippet.expand` prepends the current line's
--- indentation to every line after the first, so the body and closing brace end up indented twice.
--- Taking that indentation off each continuation line here lets `vim.snippet` put it back exactly
--- once. A line that does not start with it is left as it is.
--- @param result lsp.CompletionList|lsp.CompletionItem[]|nil
--- @param bufnr integer
function M.rebase_as_is_indent(result, bufnr)
  if type(result) ~= 'table' or not vim.api.nvim_buf_is_valid(bufnr) then return end
  local items = result.items or result
  local default_mode = vim.tbl_get(result, 'itemDefaults', 'insertTextMode')
  for _, item in ipairs(items) do
    local edit = item.textEdit
    local mode = item.insertTextMode or default_mode
    if mode == 1 and item.insertTextFormat == 2 and edit and edit.newText:find('\n', 1, true) then
      local row = (edit.range or edit.replace).start.line
      local line = vim.api.nvim_buf_get_lines(bufnr, row, row + 1, false)[1] or ''
      local indent = line:match('^%s*')
      if indent ~= '' then
        edit.newText = edit.newText:gsub('\n' .. vim.pesc(indent), '\n')
      end
    end
  end
end

--- Strips VS Code's codicon markup (`$(play) Run`) from every lens title in a codeLens result.
--- @param result lsp.CodeLens[]|lsp.CodeLens|nil
function M.strip_lens_codicons(result)
  if type(result) ~= 'table' then return end
  local lenses = result.range and { result } or result
  for _, lens in ipairs(lenses) do
    if lens.command and lens.command.title then
      lens.command.title = require('intellij-lsp.run')._strip_codicons(lens.command.title)
    end
  end
end

--- Drops repeated `fromRanges` from a call hierarchy result.
---
--- For a method that overrides a chain of library methods (`OwnerRepository.findById` over Spring
--- Data's `CrudRepository.findById` and its relatives), the server reports the same call site once
--- per method in the chain, and Neovim lists one quickfix row per range.
--- @param result lsp.CallHierarchyIncomingCall[]|lsp.CallHierarchyOutgoingCall[]|nil
function M.dedupe_call_ranges(result)
  if type(result) ~= 'table' then return end
  for _, call in ipairs(result) do
    local seen, unique = {}, {}
    for _, r in ipairs(call.fromRanges or {}) do
      local key = table.concat({ r.start.line, r.start.character, r['end'].line, r['end'].character }, ':')
      if not seen[key] then
        seen[key] = true
        unique[#unique + 1] = r
      end
    end
    call.fromRanges = unique
  end
end

--- Responses rewritten before Neovim sees them, by method.
local RESPONSE_FIXES = {
  ['textDocument/completion'] = M.rebase_as_is_indent,
  ['textDocument/codeLens'] = M.strip_lens_codicons,
  ['codeLens/resolve'] = M.strip_lens_codicons,
  ['callHierarchy/incomingCalls'] = M.dedupe_call_ranges,
  ['callHierarchy/outgoingCalls'] = M.dedupe_call_ranges,
}

--- Wraps `request` on one client instance so the responses in `RESPONSE_FIXES` are rewritten before
--- their caller sees them. A handler-table entry is not enough: `vim.lsp.completion`, and on 0.12
--- `vim.lsp.codelens`, pass callbacks of their own, which `Client:request` calls instead. Same
--- technique as `versions.install`, which this stacks on top of.
--- @param client vim.lsp.Client
function M.install_response_fixes(client)
  local orig_request = client.request
  client.request = function(self, method, params, handler, bufnr, ...)
    local fix = RESPONSE_FIXES[method]
    -- A nil handler is resolved the way `Client:request` would, so behaviour is unchanged.
    local h = fix and (handler or (self.handlers and self.handlers[method]) or vim.lsp.handlers[method])
    if not h then
      return orig_request(self, method, params, handler, bufnr, ...)
    end
    return orig_request(self, method, params, function(err, result, ctx, ...)
      fix(result, ctx and ctx.bufnr or bufnr or 0)
      return h(err, result, ctx, ...)
    end, bufnr, ...)
  end
end

--- Makes the completion menu filter dotted candidates the way this server expects.
---
--- Neovim derives the typed prefix with `\k*$`, and `.` is not in `iskeyword`, so on
--- `import java.ut` the prefix is `ut`. The Java provider sets `filterText` to the *fully qualified*
--- `java.util` whenever the item's edit starts before the prefix, and the default matcher is a
--- plain `startswith`: `"java.util"` does not start with `"ut"`, so the item is dropped and the menu
--- comes up empty. Typing `java.` works only because an empty prefix matches everything. `fuzzy`
--- swaps in a subsequence matcher, which does match.
---
--- This does not disturb the server's ranking: the Java provider caps its response at 25 items and
--- so returns `isIncomplete = true` for short prefixes, and the built-in only fuzzy-*sorts* complete
--- results, keeping `sortText` order otherwise.
---
--- Set `completeopt = false` to keep your own value; otherwise the flags are appended to what you
--- already have, and an explicit string or table replaces it.
--- @param cfg table
function M.setup_completeopt(cfg)
  local opt = cfg.completeopt
  if opt == false then return end

  if type(opt) == 'table' or type(opt) == 'string' then
    vim.opt.completeopt = opt
    return
  end

  -- Append rather than assign: a user may rely on `preinsert` or `popup`.
  vim.opt.completeopt:append('menuone')
  vim.opt.completeopt:append('fuzzy')
  -- Without `noinsert` the menu writes the current entry into the buffer as you type, so typing
  -- `u` after `java.` turns the line into `java.timeu`. `<CR>` still accepts explicitly.
  vim.opt.completeopt:append('noinsert')
end

--- Requests completion while typing a word, not only after `.`.
---
--- The server advertises `.` as its sole trigger character, and Neovim's `autotrigger` fires a
--- request *only* on those characters. Two consequences, which together are the whole "the dot
--- works but nothing after it does" report:
---
--- * Typing `ut` in `import java.ut` sends no request. The menu that `.` opened is refetched as you
---   type only while it is still visible; once it closes — which it does as soon as one keystroke
---   filters everything out — nothing reopens it, because letters are not triggers.
--- * Completion on a bare identifier (a local variable, a method in scope) never triggers at all,
---   since nothing there follows a `.`.
---
--- An InsertCharPre handler of our own on the word characters fixes both: `completion_delay` ms
--- after the first letter of a word, `vim.lsp.completion.get()`. The server's trigger set is left
--- alone on purpose: the built-in's `enable` does not re-read trigger characters for a client it
--- already knows, so adding letters to it did nothing for the first buffer and gave every later
--- buffer a *second*, undelayed 25 ms request path on each letter, racing this one.
---
--- Never cancel a completion request that is already in flight. `vim.lsp.completion.get` cancels
--- whatever is pending before it asks again, so asking on every keystroke restarts the server's
--- work each time, and whenever the server's latency exceeds the time between two keystrokes the
--- menu cannot appear until typing stops — which on a large project is several seconds of nothing,
--- then a menu. Instead the in-flight request is left to land: the built-in filters the response
--- against the prefix *at response time*, so a reply computed for `fi` still shows the right subset
--- for `find`, and a bigger prefix only ever narrows an identifier list. If keystrokes arrived
--- meanwhile, one fresh request follows once the reply is in (a no-op when the menu is up with a
--- complete list; a refetch when the list was capped by the server's 25-item limit).
--- @param client vim.lsp.Client
--- @param bufnr integer
--- @param cfg table
function M.setup_word_triggers(client, bufnr, cfg)
  local provider = client.server_capabilities and client.server_capabilities.completionProvider
  if not provider then return end

  local delay = cfg.completion_delay or 100
  local timer
  -- A keystroke arrived while a request was pending; ask again when that one lands.
  local retrigger = false
  local group = vim.api.nvim_create_augroup('IntellijLspWordTrigger' .. bufnr, { clear = true })

  local function completion_in_flight()
    for _, r in pairs(client.requests) do
      if r.type == 'pending' and r.method == 'textDocument/completion' and r.bufnr == bufnr then
        return true
      end
    end
    return false
  end

  local function request()
    retrigger = false
    if vim.api.nvim_get_current_buf() ~= bufnr or vim.fn.mode():sub(1, 1) ~= 'i' then return end
    if completion_in_flight() then
      retrigger = true
      return
    end
    vim.lsp.completion.get()
  end

  vim.api.nvim_create_autocmd('InsertCharPre', {
    group = group,
    buffer = bufnr,
    desc = 'IntelliJ: keep the completion menu fed while typing a word',
    callback = function()
      if vim.fn.pumvisible() ~= 0 then return end
      if not vim.v.char:match('[%w_]') then return end
      -- A delay, not a debounce. Restarting the timer on every keystroke means anyone typing faster
      -- than `delay` sends nothing for the whole word and then waits the delay plus a full round
      -- trip; letting the first timer run sends one request with whatever prefix exists by then,
      -- and the reply opens the menu while the rest of the word is still being typed.
      if timer then return end
      timer = vim.defer_fn(function()
        timer = nil
        request()
      end, delay)
    end,
  })

  -- `complete` is fired for every reply, including the reply to a request cancelled by the built-in's
  -- own `.` trigger. The in-flight check keeps this from cancelling that newer request in turn.
  vim.api.nvim_create_autocmd('LspRequest', {
    group = group,
    buffer = bufnr,
    desc = 'IntelliJ: re-request completion once a stale reply is in',
    callback = function(ev)
      local r = ev.data.request
      if ev.data.client_id ~= client.id or r.method ~= 'textDocument/completion' then return end
      if r.type ~= 'complete' or not retrigger then return end
      -- After the reply's own handler has run, so `pumvisible()` reflects it.
      vim.schedule(request)
    end,
  })
end

--- Maps <CR> to accept the selected completion.
---
--- Vim reserves `<C-y>` for accepting and treats Enter as an ordinary character: it ends completion
--- and inserts a newline (`:h complete_CTRL-Y`). Note this is *not* a `noselect` problem — the
--- default `completeopt` is `menu,popup`, which contains no `noselect` to remove, and Neovim still
--- leaves no item preselected. So the option alone cannot fix Enter; only a mapping can.
---
--- `pumvisible()` is checked at expansion time, so Enter keeps opening a new line whenever no menu
--- is up. Buffer-local, so other filetypes keep whatever `<CR>` they had.
---
--- Set `enter_accepts_completion = false` to keep your own mapping.
--- @param bufnr integer
function M.setup_enter_mapping(bufnr)
  vim.keymap.set('i', '<CR>', function()
    if vim.fn.pumvisible() == 0 then return '<CR>' end
    -- With nothing selected, <C-y> would accept "the typed text" and swallow the newline; <C-n>
    -- first moves onto the first entry so there is something to accept.
    local selected = vim.fn.complete_info({ 'selected' }).selected
    return selected == -1 and '<C-n><C-y>' or '<C-y>'
  end, {
    buffer = bufnr,
    expr = true,
    desc = 'IntelliJ: accept completion, or newline when no menu is open',
  })
end

-- `window/showMessageRequest` is deliberately NOT overridden. It is how the server asks which build
-- system to use when a root contains more than one, and an unanswered request means nothing is
-- imported at all. Neovim's built-in handler already routes it through `vim.ui.select` and handles
-- the non-coroutine case correctly; an override here previously auto-answered with the first action
-- before the prompt could be shown, which left the server idle with no import.

--- Token the plugin binds to the server's "Initializing server" progress in `before_init`.
M.INIT_TOKEN = 'intellij-lsp-init'

--- How long after the init progress ends to wait for `initialize` to succeed before calling it
--- failed. The server ends that progress right before it writes the InitializeResult, so a healthy
--- start is initialised within the same second; a failed one never is.
M.INIT_GRACE_MS = 15000

--- Where the server writes its own log under a claimed cache directory.
--- @param system_path string
--- @return string
function M.server_log_path(system_path)
  return system_path .. '/system/log/intellij-server.log'
end

--- The last SEVERE entry in the server log, as a one-line reason for a failed start.
---
--- The server logs the failure before it answers `initialize` with an error, and the exception
--- text sits on the line *after* the SEVERE header, so that is the line worth showing. Only the
--- tail is read: the log grows for the life of every session sharing the directory.
--- @param lines string[] server log lines, oldest first
--- @return string|nil
function M._last_severe(lines)
  for i = #lines, 1, -1 do
    if lines[i]:find(' SEVERE ', 1, true) then
      for j = i + 1, math.min(#lines, i + 3) do
        local text = vim.trim(lines[j])
        if text ~= '' then return text end
      end
      -- Header only: "SEVERE - #category - text". Drop the level and the category.
      local text = lines[i]:gsub('^.-SEVERE%s*%-%s*', ''):gsub('^#%S+%s*%-%s*', '')
      return vim.trim(text)
    end
  end
  return nil
end

--- @param system_path string
--- @return string|nil
local function last_severe_from_log(system_path)
  local log = M.server_log_path(system_path)
  if vim.fn.filereadable(log) ~= 1 then return nil end
  local ok, lines = pcall(vim.fn.readfile, log)
  if not ok then return nil end
  local tail = {}
  for i = math.max(1, #lines - 400), #lines do tail[#tail + 1] = lines[i] end
  return M._last_severe(tail)
end

--- Stops a client whose `initialize` failed and says why.
---
--- Neovim itself cannot report this. Its `initialize` callback asserts on the error, but the
--- callback is schedule-wrapped, so the assert fires outside the RPC error guard: `on_error` never
--- runs, the client is neither stopped nor marked failed, and the server process stays alive waiting
--- for requests that never come. Left alone, the "Initializing server ..." line animates forever.
--- Stopping the client here is what runs `on_exit`, which closes that line and releases the cache
--- directory.
--- @param client vim.lsp.Client
local function fail_init(client)
  local system_path = client.config.system_path
  local reason = system_path and last_severe_from_log(system_path)
  local msg = 'IntelliJ LSP: the server failed to initialize'
  if reason then msg = msg .. ': ' .. reason end
  if system_path then msg = msg .. '\nServer log: ' .. M.server_log_path(system_path) end
  vim.notify(msg, vim.log.levels.ERROR)
  client:stop(true)
end

--- Watches every intellij client for an `initialize` that never completes.
---
--- Triggered by the `end` of `INIT_TOKEN` rather than by a timer from launch, because the init
--- progress covers the open-ended part -- "Opening project database" can legitimately take minutes
--- on a large project -- and a fixed timeout would either fire on a slow success or miss a fast
--- failure. Safe to call more than once; the augroup replaces itself.
function M.watch_init()
  local group = vim.api.nvim_create_augroup('IntellijLspInitWatch', { clear = true })
  vim.api.nvim_create_autocmd('LspProgress', {
    group = group,
    desc = 'IntelliJ: detect a failed initialize',
    callback = function(ev)
      local params = ev.data and ev.data.params
      if not params or params.token ~= M.INIT_TOKEN then return end
      if not params.value or params.value.kind ~= 'end' then return end
      local client_id = ev.data.client_id
      vim.defer_fn(function()
        local client = vim.lsp.get_client_by_id(client_id)
        if client and client.name == M.NAME and not client.initialized and not client:is_stopped() then
          fail_init(client)
        end
      end, M.INIT_GRACE_MS)
    end,
  })
end

--- Cache directories claimed by this Neovim, released on exit even when no `on_exit` gets to run.
--- @type table<string, true>
local claimed = {}

local function release_all_on_leave()
  vim.api.nvim_create_autocmd('VimLeavePre', {
    group = vim.api.nvim_create_augroup('IntellijLspCacheClaims', { clear = true }),
    callback = function()
      for path in pairs(claimed) do launch.release_system_path(path) end
    end,
  })
end

--- Full `vim.lsp.start` configuration.
--- @param root_dir string
--- @param cfg table
--- @return table
function M.config(root_dir, cfg)
  local handlers = progress.handlers()
  local commands = {}

  -- Only registered alongside the `intellijExtensions` init option: the flag promises the server
  -- these notifications will be answered, so the two must not drift apart. The client-side
  -- commands are the same names arriving on completion items instead of as notifications.
  if cfg.intellij_extensions ~= false then
    local extensions = require('intellij-lsp.extensions')
    handlers = vim.tbl_extend('error', handlers, extensions.handlers())
    commands = extensions.commands()
  end

  -- The server stamps its edits with a document version of its own making, which Neovim rejects as
  -- stale after the first edit to a buffer; `versions.lua` has the full story. Client-initiated
  -- requests are rewritten by the `request` wrapper installed in `on_init`. This is the other
  -- direction: the server asking the client to apply an edit, which no request wrapper can see.
  --
  -- The same handler also takes the snippet edits out before Neovim applies the rest, and expands
  -- them afterwards: `apply_workspace_edit` has no notion of `snippet` and would fail on the missing
  -- `newText`. See snippet_edit.lua for why the capability is advertised at all.
  handlers['workspace/applyEdit'] = function(err, params, ctx, cfg_)
    local snippets = {}
    if params then
      versions.fix_workspace_edit(ctx.client_id, params.edit)
      snippets = require('intellij-lsp.snippet_edit').extract(params.edit)
    end
    local result = vim.lsp.handlers['workspace/applyEdit'](err, params, ctx, cfg_)
    if #snippets > 0 then
      local client = vim.lsp.get_client_by_id(ctx.client_id)
      require('intellij-lsp.snippet_edit').apply_all(snippets, client and client.offset_encoding or 'utf-16')
    end
    return result
  end

  -- One cache directory per live instance of this project; see `launch.claim_system_path`.
  local system_path = launch.claim_system_path(root_dir)
  claimed[system_path] = true
  release_all_on_leave()
  M.watch_init()

  return {
    name = M.NAME,
    cmd = launch.build_cmd({
      server_path = cfg.server_path,
      root_dir = root_dir,
      accept_eula = cfg.accept_eula,
      system_path = system_path,
    }),
    cmd_env = launch.build_env(cfg.jvm_args),
    root_dir = root_dir,
    -- Not a `vim.lsp.start` field: kept on the config so `:checkhealth` and the init watchdog can
    -- find this instance's server log.
    system_path = system_path,
    workspace_folders = {
      { uri = vim.uri_from_fname(root_dir), name = vim.fs.basename(root_dir) },
    },
    capabilities = M.capabilities(),
    init_options = M.init_options(root_dir, cfg),
    settings = M.settings(cfg),
    handlers = handlers,
    commands = commands,

    before_init = function(params)
      -- Binds the "Initializing server" reporter; without a token that progress is dropped.
      params.workDoneToken = M.INIT_TOKEN
    end,

    on_init = function(client, result)
      -- The server reports its on-disk index location here; needed to clear caches later.
      local experimental = vim.tbl_get(result or {}, 'capabilities', 'experimental')
      if experimental and experimental.indexDir then
        client.config.index_dir = experimental.indexDir
      end

      -- Before any buffer attaches, so the first `didOpen` is already on the ledger.
      versions.install(client)
      -- The lens titles come from the server as `$(play) Run` and `$(debug) Debug`, VS Code's
      -- codicon markup, which Neovim renders literally. Stripped in the response rather than at
      -- display time, because `vim.lsp.codelens` owns the rendering and offers no hook into it.
      M.install_response_fixes(client)
    end,

    on_attach = function(client, bufnr)
      -- Built-in completion (0.11+); no external completion plugin required. With autotrigger the
      -- menu opens on the server's trigger characters ('.'), otherwise use <C-x><C-o>.
      if client:supports_method('textDocument/completion') then
        vim.lsp.completion.enable(true, client.id, bufnr, { autotrigger = cfg.autotrigger ~= false })
        M.setup_completeopt(cfg)
        if cfg.autotrigger ~= false and cfg.word_triggers ~= false then
          M.setup_word_triggers(client, bufnr, cfg)
        end
        if cfg.enter_accepts_completion ~= false then
          M.setup_enter_mapping(bufnr)
        end
      end

      -- Inlay hints are advertised by Neovim but never switched on, so they render nothing until
      -- something calls `enable`. The settings table above is the other half; without it the server
      -- answers its own configuration request with an empty option set and Java emits no hints.
      if cfg.inlay_hints ~= false and client:supports_method('textDocument/inlayHint') then
        vim.lsp.inlay_hint.enable(true, { bufnr = bufnr })
      end

      if client:supports_method('textDocument/foldingRange') then
        M.setup_folding(cfg)
      end

      -- Document highlight, signature help while typing, hierarchy and symbol keymaps, and
      -- format-on-save: standard LSP the server advertises and Neovim never asks for on its own.
      require('intellij-lsp.editor').on_attach(client, bufnr, cfg)

      -- A freshly created, still empty `.java`/`.kt` file gets IntelliJ's file template, the way a
      -- "New Class" does in the IDE. Needs the client, hence here and not on BufNewFile itself.
      if cfg.file_templates ~= false then
        require('intellij-lsp.templates').on_attach(client, bufnr, cfg)
      end

      -- Reference browsing shadows Neovim's built-in `grr`, which fills the quickfix list and leaves
      -- you there with no preview. Opt-out via `references = false`.
      --
      -- Buffer-local on purpose: the built-in `grr` is a global default, so a buffer-local map
      -- overrides it only on buffers this server serves and other filetypes keep whatever `grr`
      -- their own LSP set up. `require` sits inside the closure so a user who never presses `grr`
      -- never loads the module.
      if cfg.references ~= false and client:supports_method('textDocument/references') then
        vim.keymap.set('n', 'grr', function() require('intellij-lsp.references').run() end, {
          buffer = bufnr,
          desc = 'IntelliJ: references (preview follows the list)',
        })
      end

      if cfg.run ~= false and client:supports_method('textDocument/codeLens') then
        M.setup_codelens(bufnr)

        -- `<leader>` rather than a bare key: unlike `grr` there is no built-in mapping here to
        -- shadow, so this must not claim a two-letter sequence in the user's namespace.
        vim.keymap.set('n', '<leader>rr', function() require('intellij-lsp.run').run_at_cursor() end, {
          buffer = bufnr,
          desc = 'IntelliJ: run the main class at the cursor',
        })
        vim.keymap.set('n', '<leader>rl', function() vim.lsp.codelens.run() end, {
          buffer = bufnr,
          desc = 'IntelliJ: run the code lens on this line',
        })

        -- Nested under the `run` check rather than beside it: debugging is the same launch path with
        -- `noDebug` flipped, so with running disabled there is no adapter for these to drive. The
        -- breakpoint maps come along with the stepping maps because a breakpoint you cannot reach is
        -- worse than no keymap at all.
        if cfg.debug ~= false then
          require('intellij-lsp.debug').set_keymaps(bufnr)
        end
      end
    end,

    on_exit = function(code, _, client_id)
      progress.reset(client_id)
      versions.reset(client_id)
      -- Required inside the callback, not at the top of the file: a session that runs with
      -- `progress = false` should not pay to load the module.
      require('intellij-lsp.status').reset(client_id)
      -- The server has let go of its index lock, so another instance may take this directory.
      launch.release_system_path(system_path)
      claimed[system_path] = nil
      -- Exit code 7: the server's licensing check failed, so an expired build exits instead of
      -- starting.
      if code == 7 then
        vim.schedule(function()
          vim.notify(
            'IntelliJ LSP: the server build has expired. Build or download a newer bundle.',
            vim.log.levels.ERROR
          )
        end)
      end
    end,
  }
end

return M
