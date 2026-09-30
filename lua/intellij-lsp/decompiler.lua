--- Decompiled sources for `jar:` and `jrt:` URIs.
---
--- The server answers definitions inside libraries and the JDK with `jar:file:///...!/Foo.class` and
--- `jrt:/java.base/java/lang/String.class`. Neovim has no reader for either scheme, so following one
--- landed you in an empty buffer named after the URI -- the limitation references.lua works around by
--- marking those rows `valid = 0`.
---
--- The server already decompiles on request: `executeCommand` "decompile" takes the URI as its single
--- argument and answers `{code, language}`, or null when the file cannot be read (the server accepts
--- only these two schemes).
---
--- The URI is passed back exactly as the server sent it. A `jar:` URI carries a nested `file:///` and
--- a `!/` separator, and round-tripping that through `vim.uri_to_fname` mangles it into a relative
--- path under cwd -- the same phantom-buffer bug references.lua documents.

local M = {}

local COMMAND = 'decompile'
local SCHEMES = { jar = true, jrt = true }

--- Decompiled text per URI, so reopening a class does not re-request it.
--- @type table<string, string[]>
local cache = {}

--- Recovers the URI the server sent from the name Neovim gave the buffer.
---
--- Neovim only leaves a URI-shaped buffer name alone when it looks absolute after the scheme, which
--- `jrt:/java.base/...` does and `jar:file:///...` does not. The latter is treated as a relative path
--- and silently prefixed with the cwd, producing
--- `/current/dir/jar:file:///.../lib.jar!/Foo.class` -- the same phantom-path behaviour
--- references.lua documents on the quickfix side. Sending that to the server would fail its scheme
--- check, so the prefix is stripped back off.
--- @param name string buffer name
--- @return string|nil uri
local function uri_from_bufname(name)
  local at = name:find('jar:', 1, true)
  if at and at > 1 then return name:sub(at) end
  return name
end

--- @param uri string
--- @return boolean
local function is_decompilable(uri)
  return SCHEMES[uri:match('^(%a+):') or ''] == true
end

--- The client serving this URI's scheme, if one is running.
--- @return vim.lsp.Client|nil
local function find_client()
  return vim.lsp.get_clients({ name = require('intellij-lsp.client').NAME })[1]
end

--- @param bufnr integer
--- @param lines string[]
--- @param filetype string|nil
local function fill(bufnr, lines, filetype)
  if not vim.api.nvim_buf_is_valid(bufnr) then return end
  -- 'readonly' has to come off before the write, not just 'modifiable': this buffer is filled twice
  -- (placeholder, then the decompiled source), and the second pass would warn W10 otherwise.
  vim.bo[bufnr].readonly = false
  vim.bo[bufnr].modifiable = true
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  vim.bo[bufnr].modifiable = false
  vim.bo[bufnr].modified = false
  -- 'nofile' rather than 'nowrite': there is no path to write back to, and buftype also keeps
  -- Neovim from trying to reload the buffer from disk on :edit.
  vim.bo[bufnr].buftype = 'nofile'
  vim.bo[bufnr].swapfile = false
  vim.bo[bufnr].readonly = true
  if filetype then vim.bo[bufnr].filetype = filetype end
end

--- Loads decompiled source into `bufnr`.
--- @param bufnr integer
--- @param uri string
function M.load(bufnr, uri)
  local cached = cache[uri]
  if cached then
    fill(bufnr, cached.lines, cached.filetype)
    return
  end

  local client = find_client()
  if not client then
    fill(bufnr, { '// IntelliJ LSP: no server attached; cannot decompile', '// ' .. uri }, nil)
    return
  end

  -- Placeholder while the request is in flight: opening a class in a large jar is not instant, and
  -- an empty buffer is exactly the symptom this module exists to remove.
  fill(bufnr, { '// IntelliJ LSP: decompiling...', '// ' .. uri }, nil)

  client:exec_cmd({ command = COMMAND, arguments = { uri } }, { bufnr = bufnr }, function(err, result)
    vim.schedule(function()
      if err or not result or not result.code then
        fill(bufnr, {
          '// IntelliJ LSP: could not decompile this file',
          '// ' .. uri,
          err and ('// ' .. tostring(err.message or err)) or nil,
        }, nil)
        return
      end

      local entry = {
        lines = vim.split(result.code, '\n', { plain = true }),
        -- The server reports IntelliJ's own lowercased language id ("java", "kotlin"), which
        -- matches Neovim's filetype names for both languages this client serves.
        filetype = result.language,
      }
      cache[uri] = entry
      fill(bufnr, entry.lines, entry.filetype)
    end)
  end)
end

--- Registers the `BufReadCmd` that turns a jar:/jrt: buffer into decompiled source.
---
--- `BufReadCmd` replaces the read entirely, which is what stops Neovim from reporting the URI as an
--- unreadable file. The autocmd is global rather than per-buffer because the buffer does not exist
--- until the edit that triggers it.
---
--- The two patterns are not symmetrical, and neither is the obvious spelling. Vim matches an autocmd
--- pattern containing `:` against the full path only once it also contains a `/`, so plain `jar:*`
--- and `jrt:*` never fire. `jrt:/*` works because that URI keeps its own leading slash; `jar:` URIs
--- arrive cwd-prefixed (see uri_from_bufname) and so are matched with a leading `*/`.
function M.setup()
  vim.api.nvim_create_autocmd('BufReadCmd', {
    group = vim.api.nvim_create_augroup('IntellijLspDecompiler', { clear = true }),
    pattern = { '*/jar:*', 'jar:/*', 'jrt:/*' },
    desc = 'IntelliJ: decompile library and JDK sources',
    callback = function(args)
      local uri = uri_from_bufname(args.file)
      if not uri or not is_decompilable(uri) then return end
      M.load(args.buf, uri)
    end,
  })
end

--- Drops cached sources, so a restart against a rebuilt project re-decompiles.
function M.reset()
  cache = {}
end

M._is_decompilable = is_decompilable
M._uri_from_bufname = uri_from_bufname

return M
