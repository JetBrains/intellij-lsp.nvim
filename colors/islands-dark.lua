-- Entry point for `:colorscheme islands-dark`.
--
-- Neovim locates this file by name on the runtimepath, so the filename *is* the scheme name and
-- cannot change without renaming the scheme. The implementation lives in intellij-lsp.theme so that
-- `:colorscheme islands-dark` and `setup({ colorscheme = true })` share one code path.

require('intellij-lsp.theme').apply()
