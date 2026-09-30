--- Git integration: commands and keymaps.
---
--- Deliberately independent of the language server. Git works in any filetype and in any repository,
--- while the server attaches only to Java and Kotlin -- gating this on a running client would make
--- `:IntellijGitStatus` fail in a Markdown file for no reason the user can see. Nothing in this
--- subtree calls `vim.lsp`.

local M = {}

--- Registers the user commands.
---
--- Called from `setup()` when `git ~= false`. Idempotent: `nvim_create_user_command` overwrites by
--- name, and plugin managers re-run specs, so a second `setup()` must not error.
function M.setup()
  -- Eagerly, not from the view modules: those are required lazily by their commands, so groups defined
  -- there do not exist until a view has been opened once -- and the late `require` would then clobber a
  -- user's own `:highlight` override.
  require('intellij-lsp.git.highlights').setup()

  vim.api.nvim_create_user_command('IntellijGitStatus', function()
    require('intellij-lsp.git.panel').open()
  end, {
    desc = 'Show git status with a previewing change list',
  })

  vim.api.nvim_create_user_command('IntellijGitDiff', function(args)
    require('intellij-lsp.git.diff').open(args.args)
  end, {
    nargs = '?',
    desc = 'Diff the current file against the index, or against a given revision',
  })

  vim.api.nvim_create_user_command('IntellijGitLog', function(args)
    require('intellij-lsp.git.logview').open(args.args)
  end, {
    nargs = '?',
    desc = 'Browse the commit log, with filtering',
  })

  vim.api.nvim_create_user_command('IntellijGitBranches', function()
    require('intellij-lsp.git.branchview').open()
  end, {
    desc = 'List branches and switch between them',
  })
end

return M
