--- EULA hash computation for released server bundles.
---
--- The server refuses to start unless `--eula <hash>` matches the hash baked into the bundle.
--- The expected value is the first 16 characters of the lowercase hex SHA-256 of the bundle's
--- own `EULA.txt`.
---
--- Dev builds and builds run from sources have no `EULA.txt` and skip the check entirely, which is
--- why `hash_for` returning nil is a normal outcome rather than an error.

local M = {}

local HASH_HEX_LENGTH = 16

--- Reads the bundle's EULA.txt.
--- @param server_root string bundle root (the directory containing `bin/`)
--- @return string|nil contents, or nil when the bundle has no EULA (dev build)
function M.read(server_root)
  local path = server_root .. '/EULA.txt'
  local file = io.open(path, 'rb')
  if not file then return nil end
  local contents = file:read('*a')
  file:close()
  return contents
end

--- Computes the accepted-EULA hash for a bundle.
---
--- Returns nil when the bundle ships no `EULA.txt`; the server skips enforcement in that case, so
--- the caller should omit `--eula` rather than pass an empty value.
--- @param server_root string bundle root
--- @return string|nil hash 16 lowercase hex characters
function M.hash_for(server_root)
  local contents = M.read(server_root)
  if not contents then return nil end
  return vim.fn.sha256(contents):lower():sub(1, HASH_HEX_LENGTH)
end

return M
