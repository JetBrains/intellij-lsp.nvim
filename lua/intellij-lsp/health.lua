--- `:checkhealth intellij-lsp`
---
--- Focuses on the failure modes that are otherwise silent: a refused build, missing consent, a
--- parked (unlicensed) server whose refusals the plugin turns into empty results, and a root whose
--- build system could not be resolved.

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

--- Where the consent answers come from. Unanswered ones are not a problem: the next server start
--- asks on the consent screen (|intellij-lsp-consent|), so they are only reported.
local function check_eula(cfg)
  local consent = require('intellij-lsp.consent')
  local root = require('intellij-lsp.launch').server_root(cfg.server_path)
  local c = consent.resolve(cfg, root)

  local from = {
    config = 'from setup()',
    store = 'on the consent screen (' .. consent.store_path() .. ')',
    server = "in the server's record (" .. consent.license_dir(cfg.jvm_args) .. ')',
  }
  -- `:checkhealth` from a script has no UI either. There a missing EULA acceptance keeps the server
  -- from starting, while region and data sharing fall back to the server's defaults. `info` takes no
  -- advice, so the hint goes into the line.
  local ui = consent._has_ui()
  local ask = ui and 'The next server start asks, or set %s in setup().'
    or "Neovim without a UI cannot ask and starts with the server's default: set %s in setup() to choose."
  if not c.eula_hash then
    vim.health.ok('no EULA.txt in the bundle (dev build; enforcement is skipped)')
  elseif c.eula_accepted then
    vim.health.ok(('EULA accepted %s, hash %s'):format(from[c.sources.eula], c.eula_hash))
  else
    local read = ' Read ' .. root .. '/EULA.txt first.'
    if ui then
      vim.health.info('EULA not accepted yet. ' .. ask:format('accept_eula = true') .. read)
    else
      vim.health.warn('EULA not accepted yet. Neovim without a UI cannot ask and does not start: '
        .. 'set accept_eula = true in setup().' .. read)
    end
  end

  for _, key in ipairs({ 'region', 'data_sharing' }) do
    if c[key] then
      vim.health.ok(('%s = %s (%s)'):format(key, c[key], from[c.sources[key]]))
    else
      vim.health.info(key .. ' not set yet. ' .. ask:format(key))
    end
  end

  if consent.declined() then
    vim.health.warn('a consent screen was declined in this session; no server starts', {
      'Run :IntellijLspLicense setup to answer the questions again.',
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

--- The server's license as `:checkhealth` lines, most important first. Pure.
---
--- A parked server answers every feature request with ServerCancelled, which the plugin turns into
--- empty results (|intellij-lsp-license-status|): silence in the editor, so this is where the reason
--- shows. The consent values are the ones the server was launched with, read from its environment;
--- answers changed since then apply on restart.
--- @param view IntellijLspLicenseView|false|nil the projected state; false when the server does not
---   speak the licensing protocol, nil when its state could not be read
--- @param env table<string, string>|nil the server's environment (`client.config.cmd_env`)
--- @return { level: 'ok'|'info'|'warn'|'error', text: string, advice: string[]|nil }[]
function M._license_report(view, env)
  local licensing = require('intellij-lsp.licensing')
  local days = licensing.days_left_text
  local out = {}
  local function add(level, text, advice) out[#out + 1] = { level = level, text = '  ' .. text, advice = advice } end

  if view == false then
    add('info', 'the server does not report its license (a bundle without the licensing protocol)')
  elseif view == nil then
    add('warn', 'could not read the license state', { 'Run :IntellijLspLicense status.' })
  else
    local details = {}
    if view.source_label then details[#details + 1] = 'source ' .. view.source_label end
    if view.status then details[#details + 1] = 'status ' .. view.status end
    if view.valid_through then
      details[#details + 1] = 'valid through ' .. view.valid_through
        .. (view.days_left and (' (' .. days(view.days_left) .. ')') or '')
    elseif view.days_left then
      details[#details + 1] = days(view.days_left)
    end
    if view.parked_reason then details[#details + 1] = 'parked: ' .. view.parked_reason end
    local text = 'license: ' .. view.message .. (#details > 0 and (' [' .. table.concat(details, ', ') .. ']') or '')

    if view.kind == 'licensed' then
      add('ok', text)
    elseif view.kind == 'authenticating' then
      add('info', text)
    elseif view.kind == 'parked' then
      add('error', text, {
        'The server refuses Java and Kotlin features; the editor stays silent instead of erroring.',
        'Run :IntellijLspLicense to activate a license.',
      })
    elseif view.kind == 'session-expired' then
      add('warn', text, { 'Run :IntellijLspLicense login.' })
    else
      add('warn', text, { 'Run :IntellijLspLicense.' })
    end
    if view.error then add('warn', view.error) end
  end

  local env_var = licensing.environment_license(env)
  if env_var then add('info', 'license set through ' .. env_var .. ', which overrides the license store') end
  if env then
    add('info', ('launched with region %s, data sharing %s'):format(
      env.INTELLIJ_REGION or 'unset', env.INTELLIJ_DATA_SHARING or 'none'))
  end
  return out
end

--- The server's current licensing state, asked for with `state/get` (the store may lag a moment
--- behind a change), else the last one it pushed.
--- @param c vim.lsp.Client
--- @return IntellijLspLicenseView|false|nil see `M._license_report`
local function license_view(c)
  local licensing = require('intellij-lsp.licensing')
  if not licensing.supported(c) then return false end
  local ok, reply = pcall(c.request_sync, c, 'jetbrains/licensing/state/get', vim.empty_dict(), 3000)
  if ok and reply and not reply.err and type(reply.result) == 'table' then
    return licensing.project(reply.result)
  end
  return licensing.view(c.id)
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

    for _, item in ipairs(M._license_report(license_view(c), c.config.cmd_env)) do
      vim.health[item.level](item.text, item.advice)
    end

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
