--- Builds the server command line and environment.

local eula = require('intellij-lsp.eula')

local M = {}

--- Bundle root for a launcher path, i.e. the parent of `bin/`.
--- @param server_path string path to `bin/intellij-server`
--- @return string
function M.server_root(server_path)
  return vim.fs.dirname(vim.fs.dirname(server_path))
end

--- Per-workspace cache directory, passed as `--system-path`.
---
--- The server derives the index location from a fingerprint of the workspace folders and the
--- bundle name, so distinct roots never share an index. Keying our cache directory by root as well
--- keeps `:IntellijLspClearCache` scoped to a single project.
---
--- `slot` is which of this root's cache directories: 1 is the plain one, 2 and up carry a suffix.
--- Slots are only for a bundle without `lsp-router` (before 271, or a dev build), whose server runs
--- on stdio and keeps its index under this directory: two Neovims on one project cannot share one,
--- as the server locks its index, so the second takes the next slot. A bundle with the router
--- shares one server per project instead and uses slot 1 only; see `M.router_path`.
--- @param root_dir string
--- @param slot integer|nil defaults to 1
--- @return string
function M.system_path(root_dir, slot)
  local key = vim.fn.sha256(root_dir):sub(1, 16)
  if slot and slot > 1 then key = key .. '-' .. slot end
  return table.concat({ vim.fn.stdpath('cache'), 'intellij-lsp', key }, '/')
end

--- Name of the file inside a cache directory that records which Neovim process is using it.
local OWNER_FILE = 'nvim.pid'

--- How many concurrent instances per project get their own cache before we stop looking. Beyond
--- this the plain slot is handed out anyway and the server reports the lock conflict itself.
local MAX_SLOTS = 8

--- @param path string cache directory
--- @return integer|nil pid recorded in it
---
--- libuv rather than `readfile()`: this also runs from the client's `on_exit`, which Neovim calls in
--- a fast event context where Vimscript functions are refused (E5560).
local function read_owner(path)
  local fd = vim.uv.fs_open(path .. '/' .. OWNER_FILE, 'r', 438)
  if not fd then return nil end
  local data = vim.uv.fs_read(fd, 64, 0)
  vim.uv.fs_close(fd)
  return data and tonumber(vim.trim(data)) or nil
end

--- Whether a process with this pid exists. Signal 0 delivers nothing and only checks.
---
--- `EPERM` means the process exists but belongs to someone else, which for our purposes is alive.
--- Only `ESRCH` -- no such process -- says the recorded owner is gone.
--- @param pid integer
--- @return boolean
local function pid_alive(pid)
  local ok, err = vim.uv.kill(pid, 0)
  if ok == 0 then return true end
  return err ~= nil and not err:match('ESRCH')
end

--- Picks a cache directory for this root that no other live Neovim is using, and marks it ours.
---
--- Slot 1 is always preferred, so a single instance keeps its warm index across restarts; a second
--- instance running alongside gets slot 2, which is likewise reused by the second instance next
--- time. A stale owner file -- its pid no longer exists, because Neovim was killed without running
--- `on_exit` -- does not block a slot. The check is by pid liveness, not by lock, so two instances
--- starting in the same instant could still collide; the server then reports the lock and
--- `client.lua`'s init watchdog surfaces it.
--- @param root_dir string
--- @return string path, integer slot
function M.claim_system_path(root_dir)
  local me = vim.uv.os_getpid()
  for slot = 1, MAX_SLOTS do
    local path = M.system_path(root_dir, slot)
    local owner = read_owner(path)
    if owner == nil or owner == me or not pid_alive(owner) then
      vim.fn.mkdir(path, 'p')
      local fd = vim.uv.fs_open(path .. '/' .. OWNER_FILE, 'w', 420)
      if fd then
        vim.uv.fs_write(fd, tostring(me) .. '\n', 0)
        vim.uv.fs_close(fd)
      end
      return path, slot
    end
  end
  return M.system_path(root_dir, 1), 1
end

--- Gives a claimed cache directory back, if it is ours. Harmless on one we never claimed.
--- @param path string
function M.release_system_path(path)
  if read_owner(path) == vim.uv.os_getpid() then
    vim.uv.fs_unlink(path .. '/' .. OWNER_FILE)
  end
end

--- Which Neovim process holds a cache directory, for tests and `:checkhealth`.
--- @param path string
--- @return integer|nil
function M.system_path_owner(path)
  return read_owner(path)
end

--- Command line for the server.
--- @param opts table {server_path, root_dir, accept_eula, system_path?}
--- `accept_eula` is whether the user accepted this bundle's EULA, by config or on the consent screen.
--- `system_path` is the claimed cache directory; left out, the root's plain slot is used.
--- @return string[]
function M.build_cmd(opts)
  local system_path = opts.system_path or M.system_path(opts.root_dir)
  local cmd
  if opts.router then
    -- The router speaks stdio to us and TCP to the server, and starts the server itself, with
    -- `--socket --multi-client --idle-timeout`; everything after `--` is passed on unchanged.
    cmd = {
      opts.router, '--server-launcher', opts.server_path,
      '--workspace-id', opts.root_dir,
      '--system-path', system_path,
      '--',
    }
  else
    cmd = { opts.server_path, '--stdio', '--system-path', system_path }
  end

  -- Only a released bundle carries an EULA.txt to enforce; dev builds skip the check.
  if opts.accept_eula then
    local hash = eula.hash_for(M.server_root(opts.server_path))
    if hash then
      table.insert(cmd, '--eula')
      table.insert(cmd, hash)
    end
  end

  return cmd
end

--- The IntelliJ launcher a client runs on, for its CLI subcommands (`license`, `login`).
---
--- Not `server_cmd[1]`: with the router that is `lsp-router`, which has no subcommands.
--- @param config table a client's config
--- @return string|nil
function M.launcher_of(config)
  return config.server_launcher or (config.server_cmd and config.server_cmd[1]) or nil
end

--- The `lsp-router` that ships beside the launcher, or nil for a bundle without one.
---
--- The router lets several Neovims on one project share a server. Since 271 the server keeps a
--- workspace's index under the machine's cache root (`~/Library/Caches/JetBrains/IntelliJServer`,
--- `~/.cache/JetBrains/IntelliJServer`), whatever `--system-path` says, so a second server on the
--- same project fails `initialize` on the index lock. The router routes the second editor to the
--- first one's server instead.
--- @param server_path string|nil
--- @return string|nil
function M.router_path(server_path)
  if not server_path then return nil end
  local path = vim.fs.dirname(server_path) .. '/lsp-router'
  return vim.fn.executable(path) == 1 and path or nil
end

--- The router's discovery file for a workspace: the server's port on the first line, its pid on
--- the second, its build on the third. Same recipe as `workspace.rs` in `lsp-router`: the first 16
--- hex digits of the SHA-256 of the workspace id, which `build_cmd` sets to the root.
--- @param root_dir string
--- @return string
function M.port_file(root_dir)
  local dir = vim.env.INTELLIJ_LSP_PORT_DIR
  if not dir or vim.trim(dir) == '' then
    dir = (vim.uv.os_tmpdir() or '/tmp'):gsub('/+$', '') .. '/intellij-lsp-servers'
  end
  return dir .. '/' .. vim.fn.sha256(root_dir):sub(1, 16) .. '.port'
end

--- The pid of the live shared server for a workspace, or nil when none runs.
---
--- A discovery file can outlive its server, and a pid can be reused, so the process must exist and
--- still be the IntelliJ server before anyone signals it.
--- @param root_dir string
--- @return integer|nil
function M.shared_server_pid(root_dir)
  local fd = vim.uv.fs_open(M.port_file(root_dir), 'r', 438)
  if not fd then return nil end
  local data = vim.uv.fs_read(fd, 256, 0) or ''
  vim.uv.fs_close(fd)
  local pid = tonumber((data:match('^[^\n]*\n%s*(%d+)')))
  if not pid or not pid_alive(pid) then return nil end
  local ps = vim.system({ 'ps', '-o', 'command=', '-p', tostring(pid) }, { text = true }):wait()
  if ps.code ~= 0 or not (ps.stdout or ''):find('intellij%-server') then return nil end
  return pid
end

--- Quotes a JVM option for `IJ_JAVA_OPTIONS`, which the launcher splits on spaces.
--- @param arg string
--- @return string
local function shell_quote_if_needed(arg)
  if arg:match('^[a-zA-Z0-9._=:/@-]+$') then return arg end
  return '"' .. arg:gsub('(["\\$`])', '\\%1') .. '"'
end

--- Variables that must not be inherited by the server process.
---
--- `IJ_LAUNCHER_DEBUG` makes the launcher write its debug log to stdout, which *is* the LSP channel
--- under `--stdio`; inheriting it corrupts the protocol stream. The other two carry the user's
--- consent, which comes from `consent.lua` and nowhere else: an inherited value would bypass what the
--- user answered, and one the server does not recognise fails the launch outright.
local CLEARED = { 'IJ_LAUNCHER_DEBUG', 'INTELLIJ_DATA_SHARING', 'INTELLIJ_REGION' }

--- Complete environment for the server process.
---
--- Returns the *full* environment rather than a sparse overlay: `vim.system` has no way to express
--- "remove this variable" (a `false` value is stringified to "false", which the server then rejects
--- as an invalid data-sharing level), so unwanted variables must be absent from the table entirely.
--- Absent is not enough on its own either; see `spawn`.
---
--- `data_sharing = 'none'` sets nothing: it is the server's default, and VS Code leaves it out too.
--- @param jvm_args string[]|nil extra JVM options
--- @param consent { region: string|nil, data_sharing: string|nil }|nil
--- @return table<string, string>
function M.build_env(jvm_args, consent)
  local env = {}
  for key, value in pairs(vim.fn.environ()) do
    env[key] = value
  end

  for _, key in ipairs(CLEARED) do
    env[key] = nil
  end

  consent = consent or {}
  if consent.region then env.INTELLIJ_REGION = consent.region end
  if consent.data_sharing and consent.data_sharing ~= 'none' then
    env.INTELLIJ_DATA_SHARING = consent.data_sharing
  end

  -- JVM options reach the launcher through the environment, not argv.
  if jvm_args and #jvm_args > 0 then
    local quoted = vim.tbl_map(shell_quote_if_needed, jvm_args)
    local existing = env.IJ_JAVA_OPTIONS
    local extra = table.concat(quoted, ' ')
    env.IJ_JAVA_OPTIONS = existing and existing ~= '' and (existing .. ' ' .. extra) or extra
  end

  return env
end

--- A `vim.lsp.start` `cmd` function that starts the server with exactly `env`.
---
--- `vim.system` merges `env` over Neovim's own environment, so a variable `build_env` dropped is
--- inherited anyway, and the LSP client offers no `clear_env`. Instead, whatever Neovim has that
--- `env` lacks is unset in Neovim's own environment around the spawn and put back right after.
--- The spawn is synchronous, so nothing else runs while those variables are missing.
--- @param argv string[]
--- @param env table<string, string>
--- @return fun(dispatchers: vim.lsp.rpc.Dispatchers, config: vim.lsp.ClientConfig): vim.lsp.rpc.PublicClient
function M.spawn(argv, env)
  return function(dispatchers, config)
    local hidden = {}
    for key, value in pairs(vim.fn.environ()) do
      if env[key] == nil then
        hidden[key] = value
        vim.uv.os_unsetenv(key)
      end
    end
    local ok, rpc = pcall(vim.lsp.rpc.start, argv, dispatchers,
      { cwd = config.cmd_cwd, env = env, detached = config.detached })
    for key, value in pairs(hidden) do
      vim.uv.os_setenv(key, value)
    end
    if not ok then error(rpc, 0) end
    return rpc
  end
end

return M
