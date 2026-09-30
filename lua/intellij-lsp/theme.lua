--- The bundled "Islands Dark" colorscheme -- a port of IntelliJ's default dark editor scheme.
---
--- Two entry points, one code path:
---
---   :colorscheme islands-dark              -- via colors/islands-dark.lua, which calls apply()
---   setup({ colorscheme = true })          -- calls enable()
---
--- The colours live in theme/palette.lua and the group mapping in theme/groups.lua. This module owns
--- the side effects.

local groups = require('intellij-lsp.theme.groups')
local palette = require('intellij-lsp.theme.palette')

local M = {}

M.NAME = 'islands-dark'

--- Applies the Islands Dark highlight groups to the current session.
---
--- Order matters here. `hi clear` has to run before the new groups are set, and `syntax reset` only
--- when syntax is already enabled: run unconditionally it *turns syntax on* as a side effect, which
--- is not a colorscheme's decision to make.
---
--- `hi clear` notably does not clear Neovim's default `@lsp.type.*` links, which point at Treesitter
--- captures (`@lsp.type.class` -> `@type`). Those survive, which is why theme/groups.lua writes out
--- an explicit entry for every group IntelliJ leaves at the plain text colour instead of omitting
--- them.
function M.apply()
  if vim.fn.exists('syntax_on') == 1 then
    vim.cmd('syntax reset')
  end
  vim.cmd('hi clear')

  -- Islands Dark is dark-only. Setting this first stops a leftover `background=light` from making
  -- Neovim re-derive its own defaults over the top of these groups.
  vim.o.background = 'dark'
  vim.g.colors_name = M.NAME

  -- Every colour in the palette is a 24-bit hex literal. Without termguicolors the terminal
  -- quantizes them to the nearest of 256 palette entries and the result looks nothing like the IDE.
  -- Warned rather than forced: flipping a global terminal option on the user's behalf can break
  -- terminals that do not support truecolor.
  if not vim.o.termguicolors then
    vim.notify(
      'IntelliJ LSP: islands-dark needs `termguicolors`; set `vim.opt.termguicolors = true`.',
      vim.log.levels.WARN
    )
  end

  for name, opts in pairs(groups.build(palette)) do
    vim.api.nvim_set_hl(0, name, opts)
  end
end

--- Applies Islands Dark unless the user already chose a colorscheme.
---
--- Used by `setup({ colorscheme = true })`. The `colors_name` guard makes the option mean "be my
--- default" rather than "override whatever I picked": setup() usually runs from a plugin spec, which
--- may execute after the user's own `:colorscheme` line. An explicit `:colorscheme islands-dark`
--- always wins, since it goes straight to apply().
---
--- Goes through `:colorscheme` rather than calling apply() directly so that the ColorSchemePre and
--- ColorScheme autocmds fire; statusline and indent-guide plugins rely on them to restyle.
function M.enable()
  if vim.g.colors_name and vim.g.colors_name ~= M.NAME then return end
  vim.cmd.colorscheme(M.NAME)
end

return M
