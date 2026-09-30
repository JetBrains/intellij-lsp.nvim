--- Custom requests and commands that address the workspace rather than a symbol.
---
---   * `textDocument/compilationErrors` - compiler-level errors for one document, as a separate
---     pull with the same params and response as `textDocument/diagnostic`. Not gated by any
---     capability. The regular diagnostics are inspection results; this is what `javac` or the
---     Kotlin compiler would say, minus everything that needs a full build.
---   * `exportWorkspace` executeCommand - writes `workspace.json`, the server's view of the
---     imported model (modules, source roots, libraries, SDKs), into a directory. The single most
---     useful attachment to an import bug report.
---
--- `resolveLocation` (symbol name + file + line to a position) is left out until a use turns up.

local M = {}

local COMPILATION_ERRORS = 'textDocument/compilationErrors'
local EXPORT_WORKSPACE = 'exportWorkspace'

--- Namespace the compiler errors are shown in. Separate from the LSP diagnostics so a re-run
--- replaces only its own results and never the inspections.
M.NAMESPACE = vim.api.nvim_create_namespace('intellij-lsp.compilation')

--- The first intellij client attached to the buffer.
--- @param bufnr integer
--- @return vim.lsp.Client|nil
local function client_for(bufnr)
  return vim.lsp.get_clients({ bufnr = bufnr, name = 'intellij' })[1]
end

--- Converts a diagnostic report to `vim.Diagnostic`s for the buffer.
--- @param items table[] lsp.Diagnostic[]
--- @param bufnr integer
--- @param client vim.lsp.Client
--- @return vim.Diagnostic[]
function M._to_diagnostics(items, bufnr, client)
  -- Hand-rolled: Neovim's own LSP-to-vim.Diagnostic conversion is local to vim.lsp.diagnostic
  -- (`vim.lsp.diagnostic.from` goes the *other* way), so this mirrors it for the fields the server
  -- fills.
  local out = {}
  for _, d in ipairs(items) do
    local range = d.range
    out[#out + 1] = {
      bufnr = bufnr,
      lnum = range.start.line,
      col = vim.lsp.util._get_line_byte_from_position(bufnr, range.start, client.offset_encoding),
      end_lnum = range['end'].line,
      end_col = vim.lsp.util._get_line_byte_from_position(bufnr, range['end'], client.offset_encoding),
      severity = d.severity,
      message = d.message,
      source = d.source or 'intellij compiler',
      code = d.code,
    }
  end
  return out
end

--- Requests compiler errors for the current buffer and shows them.
---
--- Shown as diagnostics in their own namespace, so they render with the same signs and virtual
--- text as the inspections, and listed in the location list when there are any. An empty result
--- while the server is still indexing is not "no errors": the server answers an empty report
--- during indexing, so that case is said out loud.
--- @param bufnr integer|nil
function M.compilation_errors(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local client = client_for(bufnr)
  if not client then
    vim.notify('IntelliJ LSP: no server attached to this buffer.', vim.log.levels.WARN)
    return
  end

  client:request(COMPILATION_ERRORS, { textDocument = { uri = vim.uri_from_bufnr(bufnr) } }, function(err, result)
    if err then
      vim.notify('IntelliJ LSP: compilation errors failed: ' .. tostring(err.message or err), vim.log.levels.ERROR)
      return
    end
    if not vim.api.nvim_buf_is_valid(bufnr) then return end
    local items = type(result) == 'table' and result.items or {}
    local diagnostics = M._to_diagnostics(items, bufnr, client)
    vim.diagnostic.set(M.NAMESPACE, bufnr, diagnostics)
    if #diagnostics == 0 then
      local ready = require('intellij-lsp.progress').is_ready(client.id)
      vim.notify(ready and 'IntelliJ LSP: no compiler errors in this file'
        or 'IntelliJ LSP: no compiler errors reported; indexing is still running, so this may be incomplete',
        vim.log.levels.INFO)
      return
    end
    vim.diagnostic.setloclist({ namespace = M.NAMESPACE, title = 'IntelliJ compiler errors' })
  end, bufnr)
end

--- Writes the server's `workspace.json` for the client's project into `dir` (default: the root).
--- @param dir string|nil
function M.export_workspace(dir)
  local client = vim.lsp.get_clients({ name = 'intellij' })[1]
  if not client then
    vim.notify('IntelliJ LSP: no server running.', vim.log.levels.WARN)
    return
  end
  dir = dir and dir ~= '' and vim.fn.fnamemodify(vim.fn.expand(dir), ':p'):gsub('/+$', '') or client.config.root_dir
  -- A filesystem path, not a URI: the server opens it with java.nio. Sent as a plain request, as
  -- `client:exec_cmd` would refuse a command the server does not list (see templates.lua).
  client:request('workspace/executeCommand', { command = EXPORT_WORKSPACE, arguments = { dir } }, function(err)
    if err then
      vim.notify('IntelliJ LSP: export failed: ' .. tostring(err.message or err), vim.log.levels.ERROR)
    else
      vim.notify('IntelliJ LSP: wrote ' .. dir .. '/workspace.json', vim.log.levels.INFO)
    end
  end)
end

--- The user commands. Registered once from `setup()`.
function M.register_commands()
  vim.api.nvim_create_user_command('IntellijLspCompilationErrors', function()
    M.compilation_errors()
  end, {
    desc = 'Show compiler-level errors for this file in the location list',
  })
  vim.api.nvim_create_user_command('IntellijLspExportWorkspace', function(cmd)
    M.export_workspace(cmd.args)
  end, {
    nargs = '?',
    complete = 'dir',
    desc = "Write the server's workspace.json (imported modules, roots, libraries) to a directory",
  })
end

return M
