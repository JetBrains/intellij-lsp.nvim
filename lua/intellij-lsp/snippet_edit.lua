--- Snippet edits inside `workspace/applyEdit` (LSP 3.18 `SnippetTextEdit`).
---
--- IntelliJ fixes end in a live template more often than one would guess: "introduce variable"
--- puts the cursor on the name, "surround with try/catch" on the exception type, "create method"
--- inside the body. Over LSP that template is a `SnippetTextEdit`, and the server sends one only
--- if the client advertised `workspace.workspaceEdit.snippetEditSupport`. Neovim 0.12 does not,
--- and without it the server drops every fix whose template is not optional: silently in the eager
--- code-action path, and as a "This fix is not supported" error in the lazy one. Advertising the
--- capability is therefore what makes those fixes appear at all, and this module is what makes the
--- promise true.
---
--- The wire shape: a normal `TextEdit` whose
--- `newText` is replaced by `snippet = {kind = 'snippet', value = '...'}`, using the LSP snippet
--- grammar (`${1:name}`, `${2|a,b|}`, `$0`) that `vim.snippet` parses. It arrives inside a
--- `TextDocumentEdit` under `documentChanges`, as the only edit of its own `applyEdit`.
---
--- `vim.lsp.util.apply_workspace_edit` knows nothing of `snippet` and would fail on the missing
--- `newText`, so the snippet edits are taken out before the plain ones are applied, then expanded
--- with `vim.snippet.expand` at the range they replace.

local M = {}

--- Whether `edit` is a snippet edit rather than a plain text edit.
--- @param edit table
--- @return boolean
function M.is_snippet_edit(edit)
  return type(edit) == 'table' and type(edit.snippet) == 'table' and type(edit.snippet.value) == 'string'
end

--- Removes every snippet edit from `workspace_edit`, in place, and returns them with their URIs.
---
--- Only `documentChanges` can carry them; the server never puts a snippet in the legacy `changes`
--- map. A `TextDocumentEdit` left with no edits is kept: applying an empty edit list is harmless,
--- and the document's version check still runs.
--- @param workspace_edit table|nil
--- @return { uri: string, edit: table }[]
function M.extract(workspace_edit)
  local found = {}
  if not workspace_edit or type(workspace_edit.documentChanges) ~= 'table' then return found end
  for _, change in ipairs(workspace_edit.documentChanges) do
    if change.textDocument and type(change.edits) == 'table' then
      local kept = {}
      for _, edit in ipairs(change.edits) do
        if M.is_snippet_edit(edit) then
          found[#found + 1] = { uri = change.textDocument.uri, edit = edit }
        else
          kept[#kept + 1] = edit
        end
      end
      change.edits = kept
    end
  end
  return found
end

--- Expands one snippet edit: clears its range, moves the cursor there, expands the snippet.
---
--- `vim.snippet.expand` inserts at the cursor of the current window and switches to insert mode,
--- so the buffer has to be shown first. The range is replaced rather than deleted-then-typed: with
--- a multi-line template the server anchors the range at the start of its first line, and the
--- indentation the template carries is the one it wants.
--- @param uri string
--- @param edit table
--- @param offset_encoding string
function M.apply(uri, edit, offset_encoding)
  local bufnr = vim.uri_to_bufnr(uri)
  if not vim.api.nvim_buf_is_loaded(bufnr) then vim.fn.bufload(bufnr) end
  if vim.api.nvim_get_current_buf() ~= bufnr then
    vim.api.nvim_set_current_buf(bufnr)
  end

  local range = edit.range
  local start_line = range.start.line
  local end_line = range['end'].line
  local start_col = vim.lsp.util._get_line_byte_from_position(bufnr, range.start, offset_encoding)
  local end_col = vim.lsp.util._get_line_byte_from_position(bufnr, range['end'], offset_encoding)

  vim.api.nvim_buf_set_text(bufnr, start_line, start_col, end_line, end_col, {})
  vim.api.nvim_win_set_cursor(0, { start_line + 1, start_col })
  vim.snippet.expand(edit.snippet.value)
end

--- Applies every extracted snippet edit. There is one in practice; several are applied in order.
--- @param snippets { uri: string, edit: table }[]
--- @param offset_encoding string
function M.apply_all(snippets, offset_encoding)
  for _, s in ipairs(snippets) do
    local ok, err = pcall(M.apply, s.uri, s.edit, offset_encoding)
    if not ok then
      vim.notify('IntelliJ LSP: could not expand the template: ' .. tostring(err), vim.log.levels.ERROR)
    end
  end
end

return M
