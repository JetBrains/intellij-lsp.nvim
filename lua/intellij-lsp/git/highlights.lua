--- Every highlight group the git views use.
---
--- Collected here, and registered from `setup()` rather than from the module that draws with them, for
--- one reason: the views are `require`d lazily by their commands, so groups defined at the top of
--- `logview.lua` did not exist until the log had been opened once. That is invisible while the plugin
--- draws its own buffers -- the module is loaded by then -- but it silently breaks a user who puts
--- `:highlight IntellijGitFileAdded ...` in their config, because the later `require` re-asserts the
--- link over their override.
---
--- Every group is a `default = true` link, so a user override always wins and a `:colorscheme` restyles
--- them for free instead of leaving stale colours behind. `hi clear` drops `default` links, hence the
--- `ColorScheme` re-assertion.
---
--- Link targets are chosen to exist. Two traps, both verified rather than assumed:
---
---   * `DiffAdded` and `DiffRemoved` are **not** default Neovim groups. Linking to them yields no
---     colour at all, which reads as the feature being unstyled.
---   * `DiffAdd` / `DiffDelete` *are* defined, but they set a full-line **background** for use inside
---     diff mode. On a rendered text list that paints whole rows rather than colouring a count.
---
--- `Added` / `Removed` / `Changed` are defined, foreground-only, and are what other plugins use for
--- exactly this purpose.

local M = {}

--- name -> link target
M.GROUPS = {
  -- Status panel
  IntellijGitHeader = 'Title',
  IntellijGitSection = 'Statement',
  IntellijGitStaged = 'DiffAdd',
  IntellijGitUnstaged = 'DiffChange',
  IntellijGitUntracked = 'Comment',
  IntellijGitConflict = 'DiffDelete',

  -- Log view
  IntellijGitLogHeader = 'Title',
  IntellijGitLogGraph = 'Comment',
  IntellijGitLogHash = 'Identifier',
  IntellijGitLogAuthor = 'Function',
  IntellijGitLogDate = 'Comment',
  IntellijGitLogHead = 'Statement',
  IntellijGitLogBranch = 'Type',
  IntellijGitLogTag = 'Constant',
  IntellijGitLogRemote = 'Comment',

  -- Affected-files list (shared by the log preview and the commit detail view).
  --
  -- Three columns coloured for three different reasons -- see `filelist.lua`. The status word carries
  -- the change type, the counts follow the universal green/red convention, and the path is neutral
  -- because it is an identifier rather than a change.
  IntellijGitFileAdded = 'Added',
  IntellijGitFileDeleted = 'Removed',
  IntellijGitFileModified = 'Changed',
  -- `Identifier` rather than `Special` or `Type`: those resolve to the same colour as `Changed` in the
  -- default scheme, so a renamed row was indistinguishable from a modified one. Under a scheme where
  -- `Identifier` is neutral the word "renamed" still disambiguates it, which is not true of a colour
  -- that actively collides.
  IntellijGitFileRenamed = 'Identifier',
  -- `Normal`, explicitly, rather than left unhighlighted. Unclaimed text is not neutral -- it inherits
  -- whatever syntax or Treesitter paints, which varies per row, so a path could come out red on a
  -- green row. Claiming it is the only way to make every path look the same.
  IntellijGitFilePath = 'Normal',
  -- The `← old/path` half of a rename: provenance, so dimmed against the current path.
  IntellijGitFileOrigin = 'Comment',
  IntellijGitFileSubject = 'Title',
  IntellijGitFileMeta = 'Comment',

  -- Commit detail
  IntellijGitCommitHeader = 'Title',
  IntellijGitCommitMeta = 'Comment',
  IntellijGitCommitSubject = 'Statement',
  IntellijGitCommitFile = 'Normal',
  IntellijGitCommitSection = 'Statement',

  -- Branch list
  IntellijGitBranchHeader = 'Title',
  IntellijGitBranchCurrent = 'Statement',
  IntellijGitBranchLocal = 'Type',
  IntellijGitBranchRemote = 'Comment',
  IntellijGitBranchMeta = 'Comment',
  IntellijGitBranchSection = 'Statement',

  -- Two-pane diff. `diff.lua` remaps the diff groups to these in one window only. Under a foreign
  -- scheme the targets are the groups that already carry the meaning: a deletion is DiffDelete, and
  -- the filler is DiffDelete because Neovim paints it with that group anyway.
  IntellijDiffDeleted = 'DiffDelete',
  IntellijDiffDeletedText = 'DiffText',
  IntellijDiffFiller = 'DiffDelete',
  IntellijDiffFold = 'Folded',
  IntellijDiffTitle = 'WinBar',
  IntellijDiffTitleMeta = 'WinBarNC',

  -- The unified diff in the status panel's preview. The same line tints as the two-pane diff.
  IntellijDiffInsertedLine = 'DiffAdd',
  IntellijDiffDeletedLine = 'IntellijDiffDeleted',
}

local function define()
  for name, link in pairs(M.GROUPS) do
    vim.api.nvim_set_hl(0, name, { link = link, default = true })
  end
end

--- Defines the groups and keeps them alive across `:colorscheme`.
---
--- Idempotent: plugin managers re-run specs, so `setup()` may run more than once.
function M.setup()
  define()
  vim.api.nvim_create_autocmd('ColorScheme', {
    group = vim.api.nvim_create_augroup('IntellijGitHighlights', { clear = true }),
    callback = define,
    desc = 'Re-assert IntelliJ git highlight groups',
  })
end

return M
