-- The plugin does nothing until `require('intellij-lsp').setup{}` runs: the server path is
-- user-supplied, so there is no useful default to auto-start from.
--
-- This file only registers the health check, which must be reachable as `intellij-lsp.health`
-- for `:checkhealth intellij-lsp` to find it.

if vim.g.loaded_intellij_lsp then return end
vim.g.loaded_intellij_lsp = true
