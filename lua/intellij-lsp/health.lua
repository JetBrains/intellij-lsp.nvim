--- `:checkhealth intellij-lsp`
---
--- Focuses on the failure modes that are otherwise silent: an expired build, a parked (unlicensed)
--- server that answers every request with ServerCancelled, and a root whose build system could not
--- be resolved.

local M = {}

local function check_server_download(cfg)
  local status, detail = require('intellij-lsp.server_download').status(cfg)
  if status == 'not-configured' then return end

  if status == 'cached' then
    vim.health.ok('downloaded server bundle cached at ' .. detail)
  elseif status == 'downloading' then
    vim.health.info('server bundle download in progress: ' .. (detail or ''))
  elseif status == 'missing' then
    vim.health.info('no downloaded server bundle yet: ' .. (detail or ''), {
      "run require('intellij-lsp').setup({}) with no server_path, or open a Java/Kotlin file",
    })
  end
end

local function check_server_binary(cfg)
  if not cfg.server_path then
    vim.health.error('server_path is not set', {
      "call require('intellij-lsp').setup({ server_path = '.../bin/intellij-server' })",
      'or leave server_path unset to download the bundle for this platform',
    })
    return false
  end

  if vim.fn.filereadable(cfg.server_path) ~= 1 then
    vim.health.error('server binary not found: ' .. cfg.server_path)
    return false
  end

  if vim.fn.executable(cfg.server_path) ~= 1 then
    vim.health.error('server binary is not executable: ' .. cfg.server_path, {
      'chmod +x ' .. cfg.server_path,
    })
    return false
  end

  vim.health.ok('server binary: ' .. cfg.server_path)
  return true
end

local function check_runtime(cfg)
  local root = require('intellij-lsp.launch').server_root(cfg.server_path)

  -- The bundle ships its own JBR; there is no external JDK to discover.
  if vim.fn.isdirectory(root .. '/jbr') == 1 then
    vim.health.ok('bundled JBR present')
  else
    vim.health.warn('no jbr/ in the bundle: ' .. root, {
      'This may be a partial extraction. Re-extract the full intellij-server archive, or unset server_path to let the plugin download the published bundle.',
    })
  end

  local version = vim.fn.systemlist({ cfg.server_path, '--version' })[1]
  if vim.v.shell_error == 0 and version then
    vim.health.ok('server version: ' .. version)
  else
    vim.health.warn('could not read server version')
  end
end

local function check_eula(cfg)
  local eula = require('intellij-lsp.eula')
  local root = require('intellij-lsp.launch').server_root(cfg.server_path)
  local hash = eula.hash_for(root)

  if not hash then
    vim.health.ok('no EULA.txt in the bundle (dev build; enforcement is skipped)')
    return
  end

  if cfg.accept_eula then
    vim.health.ok('EULA accepted, hash ' .. hash)
  else
    vim.health.error('bundle requires EULA acceptance but accept_eula is false', {
      'The server will exit at startup without --eula.',
      'Read ' .. root .. '/EULA.txt, then set accept_eula = true.',
    })
  end
end

--- A buffer this plugin serves, or nil.
---
--- `:checkhealth` runs in its own scratch buffer, so the current buffer is never a project file;
--- look for a served buffer instead.
--- @return integer|nil
local function find_served_buffer()
  local filetypes = require('intellij-lsp').config.filetypes
    or require('intellij-lsp.client').FILETYPES
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(bufnr)
      and vim.tbl_contains(filetypes, vim.bo[bufnr].filetype)
      and vim.api.nvim_buf_get_name(bufnr) ~= ''
    then
      return bufnr
    end
  end
  return nil
end

local function check_root_and_build_system()
  local bufnr = find_served_buffer()
  if not bufnr then
    vim.health.info('no Java/Kotlin buffer open; open one for project diagnostics')
    return
  end

  local root = require('intellij-lsp.client').find_root(bufnr)

  if not root then
    vim.health.info('no project root for ' .. vim.api.nvim_buf_get_name(bufnr))
    return
  end
  vim.health.ok('project root: ' .. root)

  local primary = {}
  for _, probe in ipairs({
    { id = 'maven', files = { 'pom.xml' } },
    { id = 'gradle', files = { 'build.gradle', 'build.gradle.kts', 'settings.gradle', 'settings.gradle.kts' } },
    { id = 'jps', files = { '.idea/modules.xml' } },
  }) do
    for _, f in ipairs(probe.files) do
      if vim.fn.filereadable(root .. '/' .. f) == 1 then
        table.insert(primary, probe.id)
        break
      end
    end
  end

  if #primary == 0 then
    vim.health.warn('no build system detected in the project root', {
      'The server may import nothing. Set build_tool or projects explicitly.',
    })
  elseif #primary > 1 then
    vim.health.warn('several build systems detected: ' .. table.concat(primary, ', '), {
      'The server will ask which to use, or skip the import if unanswered.',
      "Set build_tool = '" .. primary[1] .. "' to decide up front.",
    })
  else
    vim.health.ok('build system: ' .. primary[1])
  end
end

local function check_running_clients()
  local client = require('intellij-lsp.client')
  local progress = require('intellij-lsp.progress')
  local clients = vim.lsp.get_clients({ name = client.NAME })

  if #clients == 0 then
    vim.health.info('no running server')
    return
  end

  for _, c in ipairs(clients) do
    vim.health.ok(('server running (id %d, root %s)'):format(c.id, c.config.root_dir or '?'))

    if progress.is_ready(c.id) then
      vim.health.ok('  indexing complete')
    else
      vim.health.info('  still importing/indexing; results may be incomplete')
    end

    -- The server's own verdict on the import, folder by folder. `phase` is the cycle's outcome;
    -- a BLOCKED folder names the reason (two build systems, no build file, ...).
    local state = progress.import_state(c.id)
    if state then
      local summary = {}
      for _, f in ipairs(state.folders or {}) do
        local reason = f.status == 'BLOCKED' and (progress.BLOCKED_REASONS[f.message] or f.message) or f.message
        summary[#summary + 1] = ('%s %s%s'):format(
          progress.folder_name(f.folderUri),
          (f.tool and (f.tool .. ' ') or '') .. (f.status or '?'),
          reason and reason ~= '' and (' (' .. reason .. ')') or '')
      end
      local text = '  last import: ' .. (state.phase or '?')
        .. (#summary > 0 and ('; ' .. table.concat(summary, '; ')) or '')
      if state.phase == 'FINISHED' then
        vim.health.ok(text)
      else
        vim.health.warn(text)
      end
    end
    local status = progress.import_status(c.id)
    if status and #(status.blockedFolders or {}) > 0 then
      for _, f in ipairs(status.blockedFolders) do
        vim.health.warn(('  blocked: %s (%s%s)'):format(
          progress.folder_name(f.folderUri),
          progress.BLOCKED_REASONS[f.reason] or f.reason or '?',
          f.candidates and #f.candidates > 0 and ('; candidates: ' .. table.concat(f.candidates, ', ')) or ''), {
          f.reason == 'ambiguousBuildSystem' and "set build_tool = '<one of the candidates>' or run :IntellijLspReload and answer the prompt"
            or 'set build_tool or projects in setup()',
        })
      end
    end

    if c.config.system_path then
      vim.health.info('  cache dir: ' .. c.config.system_path)
    end
    if c.config.index_dir then
      vim.health.info('  index dir: ' .. c.config.index_dir)
    end

    -- A parked (unlicensed) server answers every non-licensing request with ServerCancelled, which
    -- most clients swallow silently. Probe one cheap request to surface that state.
    local ok, err = pcall(function()
      return c:request_sync('workspace/symbol', { query = 'A' }, 3000)
    end)
    if ok and err and err.err then
      vim.health.warn('  server rejected a probe request: ' .. vim.inspect(err.err), {
        'ServerCancelled on every request means the build is unlicensed or expired.',
      })
    end
  end
end

function M.check()
  vim.health.start('intellij-lsp')

  local cfg = require('intellij-lsp').config
  check_server_download(cfg)
  if not check_server_binary(cfg) then return end

  check_runtime(cfg)
  check_eula(cfg)
  check_root_and_build_system()
  check_running_clients()
end

return M
