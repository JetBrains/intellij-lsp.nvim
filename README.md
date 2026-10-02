# IntelliJ Language Server for Neovim (Java + Kotlin)

A Neovim client for the `intellij-server` bundle: indexing, navigation, diagnostics, completion,
quick fixes and refactorings, type and call hierarchy, formatting, file templates, run/debug and
git for Java and Kotlin from a single server. Requires Neovim 0.11+.

The plugin itself is Apache 2.0 licensed. The `intellij-server` bundle it downloads is a separate
JetBrains product with its own license (`EULA.txt` inside the bundle), which you accept with
`accept_eula = true`.

## Project status

⚠️ **This project is in pre-alpha.** ⚠️

Expect rough edges: features may be incomplete or broken, and configuration options, commands and
key mappings can change between releases without a deprecation period. Please report what breaks,
but do not depend on it for daily work yet.

At this stage we can't make promises about the roadmap or the pace of development, so features and
release timing may shift as the project evolves.

## Quick start

The only option you have to set is `accept_eula`. With nothing else configured the plugin downloads
the published `intellij-server` bundle for your platform on first start, detects Maven, Gradle,
Bazel or JPS projects, and analyzes your code with the JDK your project configures.

With lazy.nvim, save this as a new file `lua/plugins/intellij-lsp.lua` inside your Neovim config
directory (if your lazy.nvim setup imports the `plugins` directory), or add it as one more entry to
the plugin list you pass to `require('lazy').setup({ ... })` in your `init.lua`. Your config
directory is what `:echo stdpath('config')` prints: `~/.config/nvim` on macOS and Linux,
`~/AppData/Local/nvim` on Windows.

```lua
{
  'JetBrains/intellij-lsp.nvim',
  dependencies = { 'mfussenegger/nvim-dap' }, -- optional: run and debug
  opts = {
    accept_eula = true, -- read EULA.txt in the downloaded bundle first
  },
}
```

Do not lazy-load the plugin on `ft = { 'java', 'kotlin' }`. Running `nvim` inside a project
directory starts the import from the build file (`pom.xml`, `build.gradle`, ...) before any source
file is open, and that only works if the plugin is loaded at startup. Loading it costs a few
milliseconds; a project with no build file and no Java or Kotlin buffer starts no server.

Two options you may need early on. They go inside the same `opts` table of the spec above, so
replace that table with this one:

```lua
opts = {
  accept_eula = true,
  server_path = '~/intellij-server/bin/intellij-server', -- use your own bundle instead of downloading
  default_sdk = '/path/to/jdk-21',                       -- JDK for projects that do not configure their own
}
```

Then open a Java or Kotlin file and run `:checkhealth intellij-lsp`.

## Setup

Every option with its default. Copy this into your config and change what you need; an empty
`setup({})` also works and downloads the server bundle on first start.

Where it goes depends on your plugin manager. With lazy.nvim, do not call `setup()` yourself: put
the keys you want inside the `opts` table of the spec from the quick start, and lazy.nvim passes them
to `setup()`. With any other manager, or with no plugin manager, put this call in the `init.lua` of
your Neovim config directory (or a Lua file it requires) after the plugin is on your `runtimepath`.

```lua
require('intellij-lsp').setup({
  -- Server ------------------------------------------------------------------
  server_path = nil,              -- path to bin/intellij-server; nil downloads the published bundle
  server_download = true,         -- download and cache the bundle when server_path is unset
  accept_eula = false,            -- accept the bundle's EULA.txt (required for released bundles)
  jvm_args = nil,                 -- extra JVM options for the server process
  filetypes = { 'java', 'kotlin' }, -- filetypes that start the server

  -- Project -----------------------------------------------------------------
  build_tool = nil,               -- force an importer: "maven", "gradle", "bazel", "jps"; "" skips import
  default_sdk = nil,              -- JDK home used to analyze your code (not to run the server)
  projects = {},                  -- explicitly configured projects when auto-detection is not enough

  -- Completion --------------------------------------------------------------
  autotrigger = true,             -- open the completion menu on "."
  completeopt = nil,              -- add menuone,fuzzy,noinsert to 'completeopt'; false keeps yours
  word_triggers = true,           -- also request completion while typing identifiers
  completion_delay = 100,         -- ms after the first letter of a word before asking the server
  enter_accepts_completion = true, -- <CR> accepts the selected completion

  -- Editor ------------------------------------------------------------------
  references = true,              -- grr opens a live-previewing reference list
  inlay_hints = true,             -- parameter and type hints
  inlay_hint_settings = nil,      -- merged over the built-in hint defaults
  folding = true,                 -- fold with the server's folding ranges
  document_highlight = true,      -- highlight the identifier under the cursor after 'updatetime'
  signature_help = true,          -- parameter popup when typing ( or , inside a call
  keymaps = true,                 -- <leader> maps for type/call hierarchy and symbol search
  format_on_save = false,         -- run IntelliJ's formatter on every write (:IntellijLspFormat by hand)
  file_templates = true,          -- offer IntelliJ file templates for a new, empty .java/.kt file
  intellij_extensions = true,     -- opt into the intellij/ protocol extensions: lazy quick fixes, variants, conflicts
  decompiler = true,              -- open jar:/jrt: URIs as decompiled source
  rename_files = false,           -- register :IntellijLspRename {path}
  colorscheme = true,             -- apply the bundled islands-dark scheme unless you set your own (needs termguicolors)
  nowrap = false,                 -- set 'nowrap' like IntelliJ's default

  -- Messages ----------------------------------------------------------------
  progress = true,                -- import and indexing progress on one line in the message area
  build_output = 'on_failure',    -- open the output panel during import: 'always' | 'on_failure' | 'never'
  single_key_select = true,       -- answer numbered prompts with a bare digit

  -- Git, run, debug ---------------------------------------------------------
  git = true,                     -- :IntellijGitStatus, :IntellijGitDiff, :IntellijGitLog, :IntellijGitBranches
  run = true,                     -- run the main class at the cursor (needs nvim-dap)
  build_before_run = true,        -- compile with the build tool before each run or debug launch
  debug = true,                   -- breakpoints, stepping, debug panel (needs run and nvim-dap)
})
```

Then `:checkhealth intellij-lsp`.

## Shortcuts

All mappings are buffer-local: the editor mappings exist only in buffers this server serves, the
panel mappings only inside their panel. Everything else (`gd`, `K`, `gra`, `grn`, `]d`, ...) is
Neovim's built-in LSP behaviour.

### In a Java or Kotlin buffer

| Key | Action |
|---|---|
| `<CR>` (insert mode) | accept the selected completion; opens a line when no menu is visible |
| `grr` | browse references with a live preview |
| `<leader>ts` / `<leader>tu` | type hierarchy: subtypes / supertypes of the class at the cursor |
| `<leader>ci` / `<leader>co` | call hierarchy: incoming / outgoing calls of the method at the cursor |
| `<leader>ws` | search workspace symbols (classes, methods, fields) |
| `(` or `,` (insert mode) | opens the parameter popup for the call being typed |
| `gra` | IntelliJ's intentions and quick fixes; variants and live templates are handled in place |
| `<leader>rr` | run the main class at the cursor |
| `<leader>rl` | run the code lens on the current line (the Run / Debug lenses above a `main`) |
| `<leader>rd` | debug the class at the cursor |
| `<leader>b` | toggle a breakpoint on this line |
| `<leader>B` | breakpoint with a condition |
| `<leader>dc` | continue |
| `<leader>dn` / `<leader>di` / `<leader>do` | step over / into / out |
| `<leader>dq` | stop the debug session |
| `<leader>de` | evaluate the expression at the cursor (works on a visual selection too) |
| `<leader>dw` | watch the expression at the cursor |
| `<leader>dv` | open the debug panel (call stack, locals, watches) |

### Reference list (`grr`)

| Key | Action |
|---|---|
| `j` / `k` | step; the editor window previews that reference |
| `<CR>` | jump to the reference and close the list |
| `q` / `<Esc>` | close and return to where `grr` was pressed |

### Output panel (`:IntellijLspOutput`, runs, builds)

| Key | Action |
|---|---|
| `<CR>` | open the file a stack frame or compiler message refers to |
| `<C-c>` | stop the build, or the running program |
| `q` / `<Esc>` | close the panel; the program keeps running |

### Debug panel (`<leader>dv`)

| Key | Action |
|---|---|
| `j` / `k` | step the frame list; the editor previews each frame's source |
| `<CR>` | jump to the frame, or expand/collapse the variable under the cursor |
| `<Tab>`, `zo` / `zc` / `za` | expand or collapse the variable under the cursor |
| `c` / `n` / `i` / `o` | continue / step over / step into / step out |
| `e` | evaluate an expression (prompts) |
| `w` | add a watch (prompts) |
| `dd` | remove the watch under the cursor |
| `q` / `<Esc>` | close the panel |

### `:IntellijGitStatus`

| Key | Action |
|---|---|
| `j` / `k` | step; the editor shows that entry's diff |
| `<CR>` | open the file and close the list |
| `R` | refresh |
| `q` / `<Esc>` | close and return to where you were |

### `:IntellijGitDiff`

Neovim's own diff mode: `]c` / `[c` move between hunks and `do` takes the other side of a hunk.
The revision pane is read-only, so `dp` is intercepted and explains why.

### `:IntellijGitLog`

| Key | Action |
|---|---|
| `j` / `k` | step; the editor shows that commit's affected files |
| `<CR>` | open the commit detail view |
| `/` | filter by message text |
| `a` | filter by author |
| `f` | filter by path |
| `r` | set a revision range |
| `c` | clear all filters |
| `b` | switch branch |
| `+` | load more commits |
| `R` | refresh |
| `q` / `<Esc>` | close and return to where you were |

### Commit detail view (from the log)

| Key | Action |
|---|---|
| `j` / `k` | step the file list; both diff panes refresh to show that file |
| `<CR>` | open the same diff in its own tab (`q` closes the tab) |
| `o` | open the file as it is now, on disk |
| `q` / `<Esc>` | close and return to where you were |

### `:IntellijGitBranches`

| Key | Action |
|---|---|
| `<CR>` | check out the selected branch |
| `R` | refresh |
| `q` / `<Esc>` | close and return to where you were |
