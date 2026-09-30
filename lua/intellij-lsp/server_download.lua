--- Downloads and caches an `intellij-server` bundle, for a user who has not built or pointed the
--- plugin at one already.
---
--- The download flow: check a cached bundle first, otherwise
--- pick the published bundle for this OS and CPU architecture from `server_bundles`, download the
--- archive, verify its checksum, extract it, and cache it under a per-OS data directory.
---
--- The download and the extraction run asynchronously, so the editor stays responsive. Progress
--- is one self-updating line in the message area, the same `nvim_echo` shape `status.lua` uses
--- for import and indexing. The percentage comes from polling the partial file's size against the
--- pinned archive size, not from parsing curl's terminal meter.
---
--- A lock directory guards against two Neovim instances installing the same version at once. It
--- records the owner's PID, so a lock left behind by a killed editor is detected and removed
--- instead of stalling the next start.

local bundles = require('intellij-lsp.server_bundles')

local M = {}

local TITLE = 'IntelliJ LSP'
local POLL_MS = 250
local WAIT_POLL_MS = 500
local WAIT_DEADLINE_MS = 5 * 60 * 1000
--- A lock with no `pid` file yet is fresh for this long; after that it is stale.
local LOCK_PID_GRACE_S = 10

--- Where downloaded bundles are cached, one subdirectory per version.
--- @return string
function M.cache_root()
  return vim.fs.normalize(vim.fn.stdpath('data') .. '/intellij-lsp/server')
end

--- The launcher path inside an extracted bundle directory.
--- @param server_dir string
--- @return string
local function launcher_path(server_dir)
  local name = vim.fn.has('win32') == 1 and 'intellij-server.exe' or 'intellij-server'
  return server_dir .. '/bin/' .. name
end

local OS_BY_SYSNAME = { Darwin = 'macos', Linux = 'linux', Windows_NT = 'windows' }
local ARCH_BY_MACHINE = { arm64 = 'aarch64', aarch64 = 'aarch64', x86_64 = 'x86_64', AMD64 = 'x86_64' }

--- The OS and architecture keys of `server_bundles` for this machine.
--- @param uname table|nil `vim.uv.os_uname()` result; defaults to the live one
--- @return string|nil os 'macos'|'linux'|'windows'
--- @return string|nil arch 'aarch64'|'x86_64'
--- @return string|nil error
local function platform(uname)
  uname = uname or vim.uv.os_uname()
  local os = OS_BY_SYSNAME[uname.sysname]
  local arch = ARCH_BY_MACHINE[uname.machine]
  if not os or not arch then
    return nil, nil,
      ('no intellij-server bundle for this platform (%s/%s)'):format(
        tostring(uname.sysname), tostring(uname.machine))
  end
  return os, arch, nil
end

--- The published bundle for this machine.
--- @return table|nil bundle {url, version, sha256, size}
--- @return string|nil error
local function bundle_for_this_platform()
  local os, arch, err = platform()
  if not os then return nil, err end
  return bundles.bundle(os, arch)
end

--- SHA-256 of a file's contents, lowercase hex.
--- @param path string
--- @return string|nil
local function sha256_file(path)
  local file = io.open(path, 'rb')
  if not file then return nil end
  local contents = file:read('*a')
  file:close()
  return vim.fn.sha256(contents):lower()
end

--- Extension for the archive named by `url`, one of the formats `extract` knows how to unpack.
--- `.sit` is the macOS distribution and `.win.zip` the Windows one; both are zip archives.
--- @param url string
--- @return string|nil kind 'tar.gz' | 'zip'
local function archive_kind(url)
  if url:match('%.tar%.gz$') or url:match('%.tgz$') then return 'tar.gz' end
  if url:match('%.zip$') or url:match('%.sit$') then return 'zip' end
  return nil
end

--- The text of the download progress line.
--- @param version string
--- @param size integer bytes on disk so far
--- @param total integer|nil pinned archive size, when known
--- @return string text
--- @return integer|nil percent
local function progress_text(version, size, total)
  local mb = function(n) return math.floor(n / 1e6) end
  if total and total > 0 then
    return ('Downloading intellij-server %s: %d / %d MB'):format(version, mb(size), mb(total)),
      math.min(100, math.floor(size * 100 / total))
  end
  return ('Downloading intellij-server %s: %d MB'):format(version, mb(size)), nil
end

--- One self-updating line in the message area. Passing the id from the first `nvim_echo` back
--- updates that line in place instead of appending another.
local function message_line()
  local id
  local line = {}

  --- @param text string
  --- @param percent integer|nil
  --- @param status 'running'|'success'|'failure'|nil
  function line.update(text, percent, status)
    local ok, new_id = pcall(vim.api.nvim_echo, { { text } }, false, {
      id = id,
      kind = 'progress',
      source = 'intellij-lsp',
      title = TITLE,
      status = status or 'running',
      percent = percent,
    })
    if ok then id = new_id end
  end

  --- Closes the line with a final frame.
  --- @param text string
  --- @param status 'success'|'failure'
  function line.finish(text, status)
    line.update(text, nil, status)
    id = nil
  end

  return line
end

--- Extracts `archive_path` (of `kind`) into `dest_dir`, stripping the single top-level directory
--- the bundle archives wrap their contents in.
--- @param archive_path string
--- @param kind string 'tar.gz' | 'zip'
--- @param dest_dir string
--- @param done fun(ok: boolean, err: string|nil)
local function extract(archive_path, kind, dest_dir, done)
  vim.fn.mkdir(dest_dir, 'p')

  local cmd
  if kind == 'tar.gz' then
    cmd = { 'tar', '-xzf', archive_path, '--strip-components=1', '-C', dest_dir }
  elseif kind == 'zip' then
    -- Extract flat, then promote the single top-level directory's contents, mirroring the tar
    -- case: the bundle zips also wrap everything in one directory.
    cmd = { 'unzip', '-q', archive_path, '-d', dest_dir }
  else
    done(false, 'unsupported archive type: ' .. kind)
    return
  end

  vim.system(cmd, { text = true }, vim.schedule_wrap(function(result)
    if result.code ~= 0 then
      done(false, 'extraction failed: ' .. (result.stderr ~= '' and result.stderr or ('exit code ' .. result.code)))
      return
    end

    if kind == 'zip' then
      local entries = vim.fn.readdir(dest_dir)
      if #entries == 1 and vim.fn.isdirectory(dest_dir .. '/' .. entries[1]) == 1 then
        local inner = dest_dir .. '/' .. entries[1]
        for _, name in ipairs(vim.fn.readdir(inner)) do
          vim.fn.rename(inner .. '/' .. name, dest_dir .. '/' .. name)
        end
        vim.fn.delete(inner, 'd')
      end
    end

    done(true, nil)
  end))
end

--- Whether the lock at `lock_dir` belongs to a process that no longer runs.
---
--- The owner writes its PID into the lock right after `mkdir`. A lock with no PID file is fresh
--- for a grace period, because the owner may be between those two steps. A PID this process owns
--- is never stale. `kill(pid, 0)` sends no signal and only asks whether the process exists; EPERM
--- means it exists under another user, so it counts as alive.
--- @param lock_dir string
--- @return boolean
local function lock_is_stale(lock_dir)
  local pid_file = lock_dir .. '/pid'
  local pid = vim.fn.filereadable(pid_file) == 1 and tonumber((vim.fn.readfile(pid_file)[1] or '')) or nil
  if not pid then
    local stat = vim.uv.fs_stat(lock_dir)
    return not stat or (os.time() - stat.mtime.sec) > LOCK_PID_GRACE_S
  end
  if pid == vim.uv.os_getpid() then return false end
  local ok, err_name = vim.uv.kill(pid, 0)
  return ok ~= 0 and err_name ~= 'EPERM'
end

--- Takes the install lock for `version_dir`, sweeping a stale one first.
---
--- On a stale lock the partial archive is deleted too: the previous owner died mid-download, so
--- the file is truncated and would only fail the checksum later.
--- @param version_dir string
--- @param archive_path string
--- @return 'acquired'|'held'
local function try_lock(version_dir, archive_path)
  local lock_dir = version_dir .. '.lock'
  vim.fn.mkdir(vim.fs.dirname(version_dir), 'p')

  -- `uv.fs_mkdir`, not `vim.fn.mkdir()`: the Vim function raises E739 on an existing directory,
  -- while this one reports EEXIST as a return value, which is the atomic test-and-set wanted here.
  for _ = 1, 2 do
    if vim.uv.fs_mkdir(lock_dir, 493) then
      vim.fn.writefile({ tostring(vim.uv.os_getpid()) }, lock_dir .. '/pid')
      return 'acquired'
    end
    if not lock_is_stale(lock_dir) then return 'held' end
    vim.fn.delete(lock_dir, 'rf')
    vim.fn.delete(archive_path)
  end
  return 'held'
end

--- @param version_dir string
local function release_lock(version_dir)
  vim.fn.delete(version_dir .. '.lock', 'rf')
end

--- Waits for another process's install of the same version to finish, then calls `done` with the
--- launcher. If that process gives up the lock without producing a launcher, `retry` runs so this
--- process installs itself.
--- @param version_dir string
--- @param launcher string
--- @param done fun(path: string|nil, err: string|nil)
--- @param retry fun()
local function wait_for_other_install(version_dir, launcher, done, retry)
  local line = message_line()
  line.update('Waiting for another install of intellij-server to finish', nil)
  local deadline = vim.uv.now() + WAIT_DEADLINE_MS
  local timer = vim.uv.new_timer()

  timer:start(WAIT_POLL_MS, WAIT_POLL_MS, vim.schedule_wrap(function()
    local function stop()
      timer:stop()
      timer:close()
    end
    if vim.fn.filereadable(launcher) == 1 then
      stop()
      line.finish('intellij-server installed', 'success')
      done(launcher, nil)
    elseif vim.fn.isdirectory(version_dir .. '.lock') ~= 1 then
      stop()
      line.finish('Other install finished without a server; retrying', 'running')
      retry()
    elseif vim.uv.now() > deadline then
      stop()
      line.finish('Timed out waiting for another install', 'failure')
      done(nil, 'timed out waiting for another install of the same version to finish')
    end
  end))
end

--- Downloads, verifies, and extracts `bundle` into `version_dir`. Holds the install lock throughout.
--- @param bundle table {url, version, sha256, size}
--- @param kind string 'tar.gz' | 'zip'
--- @param version_dir string
--- @param launcher string
--- @param done fun(path: string|nil, err: string|nil)
local function install(bundle, kind, version_dir, launcher, done)
  local archive_path = M.cache_root() .. '/downloads/' .. vim.fs.basename(bundle.url)

  local state = try_lock(version_dir, archive_path)
  if state == 'held' then
    wait_for_other_install(version_dir, launcher, done, function()
      install(bundle, kind, version_dir, launcher, done)
    end)
    return
  end

  -- The lock is ours from here on. Every exit path goes through `finish`.
  if vim.fn.filereadable(launcher) == 1 then
    release_lock(version_dir)
    done(launcher, nil)
    return
  end

  local line = message_line()

  local function finish(path, err)
    release_lock(version_dir)
    if path then
      line.finish(('intellij-server %s installed'):format(bundle.version), 'success')
    else
      vim.fn.delete(archive_path)
      line.finish(('intellij-server %s install failed'):format(bundle.version), 'failure')
    end
    done(path, err)
  end

  line.update(progress_text(bundle.version, 0, bundle.size))
  vim.fn.mkdir(vim.fs.dirname(archive_path), 'p')

  local poll = vim.uv.new_timer()
  poll:start(POLL_MS, POLL_MS, vim.schedule_wrap(function()
    local stat = vim.uv.fs_stat(archive_path)
    line.update(progress_text(bundle.version, stat and stat.size or 0, bundle.size))
  end))

  -- `-sS`: no terminal progress meter on stderr, errors only. Progress comes from the size poll.
  vim.system(
    { 'curl', '-fsSL', '--retry', '3', '-o', archive_path, bundle.url },
    { text = true },
    vim.schedule_wrap(function(result)
      poll:stop()
      poll:close()

      if result.code ~= 0 then
        finish(nil, 'download failed: ' .. (result.stderr ~= '' and result.stderr or ('exit code ' .. result.code)))
        return
      end

      line.update(('Verifying intellij-server %s checksum'):format(bundle.version), 100)
      local actual = sha256_file(archive_path)
      if actual ~= bundle.sha256 then
        finish(nil, ('checksum mismatch: expected %s, got %s'):format(bundle.sha256, actual or '?'))
        return
      end

      line.update(('Extracting intellij-server %s'):format(bundle.version), 100)
      extract(archive_path, kind, version_dir, function(ok, err)
        vim.fn.delete(archive_path)
        if not ok then
          vim.fn.delete(version_dir, 'rf')
          finish(nil, err)
          return
        end
        if vim.fn.filereadable(launcher) ~= 1 then
          vim.fn.delete(version_dir, 'rf')
          finish(nil, 'extracted bundle has no launcher at ' .. launcher)
          return
        end
        if vim.fn.has('win32') ~= 1 then
          vim.fn.setfperm(launcher, 'rwxr-xr-x')
        end
        finish(launcher, nil)
      end)
    end)
  )
end

--- The install this process is running, with every callback waiting on it. A second `ensure` during
--- a download joins it instead of contending for the lock with its own process.
--- @type { version: string, callbacks: fun(path: string|nil, err: string|nil)[] }|nil
local installing = nil

--- Ensures the server bundle for this platform is present locally, downloading and caching it if
--- needed.
---
--- `setup()` calls this when `server_path` is unset and `server_download` is not `false`. The
--- callback runs synchronously when the bundle is already cached, and from the main loop after an
--- asynchronous download otherwise.
--- @param callback fun(server_path: string|nil, err: string|nil)
function M.ensure(callback)
  if installing then
    table.insert(installing.callbacks, callback)
    return
  end

  local bundle, err = bundle_for_this_platform()
  if not bundle then
    callback(nil, err)
    return
  end

  local version_dir = M.cache_root() .. '/' .. bundle.version
  local launcher = launcher_path(version_dir)

  if vim.fn.filereadable(launcher) == 1 then
    callback(launcher, nil)
    return
  end

  local kind = archive_kind(bundle.url)
  if not kind then
    callback(nil, 'unsupported archive type in bundle url: ' .. bundle.url)
    return
  end

  installing = { version = bundle.version, callbacks = { callback } }
  vim.schedule(function()
    install(bundle, kind, version_dir, launcher, function(path, install_err)
      local callbacks = installing and installing.callbacks or {}
      installing = nil
      for _, cb in ipairs(callbacks) do
        cb(path, install_err)
      end
    end)
  end)
end

--- Status for `:checkhealth intellij-lsp`.
--- @param cfg table plugin configuration
--- @return 'cached'|'downloading'|'missing'|'not-configured' status
--- @return string|nil detail
function M.status(cfg)
  if cfg.server_download == false then return 'not-configured', nil end
  -- `setup()` stores the downloaded launcher in `server_path`, so only a path outside the cache
  -- means the user brought their own bundle.
  if cfg.server_path and not vim.startswith(vim.fs.normalize(cfg.server_path), M.cache_root()) then
    return 'not-configured', nil
  end
  if installing then return 'downloading', installing.version end

  local bundle, err = bundle_for_this_platform()
  if not bundle then return 'missing', err end

  local version_dir = M.cache_root() .. '/' .. bundle.version
  local launcher = launcher_path(version_dir)
  if vim.fn.filereadable(launcher) == 1 then
    return 'cached', launcher
  end
  return 'missing', 'not downloaded yet: ' .. bundle.version
end

M._platform = platform
M._sha256_file = sha256_file
M._archive_kind = archive_kind
M._progress_text = progress_text
M._lock_is_stale = lock_is_stale
M._try_lock = try_lock
M._release_lock = release_lock

return M
