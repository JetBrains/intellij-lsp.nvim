--- Decompiled sources for `jar:` and `jrt:` URIs.
---
--- The server answers definitions inside libraries and the JDK with `jar:file:///...!/Foo.class` and
--- `jrt:/java.base/java/lang/String.class`. Neovim has no reader for either scheme, so following one
--- landed you in an empty buffer named after the URI. The same BufReadCmd is what lets references.lua
--- list a library reference as a navigable, previewable row.
---
--- The server already decompiles on request: `executeCommand` "decompile" takes the URI as its single
--- argument and answers `{code, language}`, or null when the file cannot be read (the server accepts
--- only these two schemes).
---
--- The URI is passed back exactly as the server sent it. A `jar:` URI carries a nested `file:///` and
--- a `!/` separator, and round-tripping that through `vim.uri_to_fname` mangles it into a relative
--- path under cwd -- the same phantom-buffer bug references.lua documents.
---
--- The source is requested *synchronously*. `BufReadCmd` replaces a file read, and Neovim's LSP code
--- treats it as one: `vim.lsp.util.locations_to_items` bufloads a non-`file:` URI expressly so a
--- plugin's BufReadCmd can fill it, and reads the lines back on the next statement; the definition
--- handler then `nvim_win_set_cursor`s to the location's line. A placeholder filled while the real
--- request is in flight has two lines, so a JDK jump -- `String` resolves to line 173 of the
--- `src.zip` source, not to `0:0` of a class file -- failed with "Invalid cursor line: out of range"
--- and left you at line 1 once the source arrived. Blocking for the decompile is what makes the
--- cursor land; the cache means it happens once per class. The async placeholder path is kept only
--- for a request that outlives the timeout.

local M = {}

local COMMAND = 'decompile'
local SCHEMES = { jar = true, jrt = true }

--- How long a `BufReadCmd` waits for the server before falling back to the placeholder. Reading a
--- source from `src.zip` and decompiling a class file both measured well under 50 ms against a
--- warm server; the bound is for a stalled one, and `vim.wait` gives up early on `<C-c>`.
local SYNC_TIMEOUT_MS = 10000

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
  local client = find_client()
  -- Read by init.lua when `fill` sets the filetype: the buffer attaches to this client instead of
  -- being rooted like a project file.
  vim.b[bufnr].intellij_lsp_library_client = client and client.id or nil

  local cached = cache[uri]
  if cached then
    fill(bufnr, cached.lines, cached.filetype)
    return
  end

  if not client then
    fill(bufnr, { '// IntelliJ LSP: no server attached; cannot decompile', '// ' .. uri }, nil)
    return
  end

  local function on_result(err, result)
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
  end

  -- One request, waited on synchronously (see the header). Not `request_sync`: that cancels on
  -- timeout, and re-requesting would make the server start the decompile over. Here the same
  -- handler fills the buffer whether it lands inside the wait or after it.
  local done = false
  local sent = client:request('workspace/executeCommand', { command = COMMAND, arguments = { uri } },
    function(err, result)
      done = true
      on_result(err, result)
    end, bufnr)
  if not sent then
    on_result({ message = 'request could not be sent' }, nil)
    return
  end

  vim.wait(SYNC_TIMEOUT_MS, function() return done end, 10)
  if done then return end

  -- Placeholder while the request is still in flight: a slow decompile is better shown late than
  -- never, and an empty buffer is exactly the symptom this module exists to remove.
  fill(bufnr, { '// IntelliJ LSP: decompiling...', '// ' .. uri }, nil)
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
