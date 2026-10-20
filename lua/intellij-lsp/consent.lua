--- Region, EULA and data-sharing consent, collected before the server starts.
---
--- The split of work follows the VS Code extension: the client asks these three questions and
--- passes the answers as launch parameters (`--eula <hash>`, `INTELLIJ_REGION`,
--- `INTELLIJ_DATA_SHARING`); the server does everything else about licensing itself.
---
--- An answer comes from the first of
---
---   1. the config (`accept_eula = true`, `region`, `data_sharing`), which never shows a screen,
---   2. the plugin's own store, `stdpath('data')/intellij-lsp/consent.json`,
---   3. for the EULA only, the server's record `<license dir>/eula-accepted.hashes`, written by any
---      earlier launch that passed `--eula` (VS Code, the CLI, this plugin),
---
--- and only what none of them answers is asked, in VS Code's order: region, EULA, data sharing.
--- The EULA is identified by the hash of the bundle's `EULA.txt`, so a changed agreement no longer
--- matches the stored hash and is asked again.

local eula = require('intellij-lsp.eula')
local launch = require('intellij-lsp.launch')

local M = {}

--- Europe first: the most common answer, and VS Code's preselection.
M.REGIONS = { 'europe', 'africa', 'americas', 'apac', 'china', 'middle_east', 'oceania' }

M.REGION_LABELS = {
  africa = 'Africa',
  americas = 'Americas',
  apac = 'Asia (except Mainland China)',
  china = 'Mainland China',
  europe = 'Europe',
  middle_east = 'Middle East',
  oceania = 'Oceania',
}

M.DATA_SHARING = { 'full', 'anonymous', 'none' }

M.DATA_SHARING_LABELS = {
  full = 'Send detailed statistics',
  anonymous = 'Send anonymous statistics',
  none = "Don't send",
}

M.DATA_SHARING_URL = 'https://www.jetbrains.com/legal/docs/terms/product_data_collection/'

--- The questions, in the order they are asked.
local STEPS = { 'region', 'eula', 'data_sharing' }

local STEP_NAMES = { region = 'region', eula = 'license agreement', data_sharing = 'data sharing' }

--- Why the server did not start, by the question that was declined or closed.
local DECLINED = {
  region = 'no region was chosen',
  eula = 'the license agreement was not accepted',
  data_sharing = 'no data-sharing choice was made',
}

--- Problems with the consent options in a config, one message each.
---
--- `setup()` reports these and drops the offending value, so the question is asked instead of the
--- server rejecting the launch: it refuses any region or data-sharing level it does not know.
--- @param cfg table
--- @return string[]
function M.validate(cfg)
  local problems = {}
  if cfg.region ~= nil and not vim.tbl_contains(M.REGIONS, cfg.region) then
    problems[#problems + 1] = ('region = %s is not one of %s'):format(
      vim.inspect(cfg.region), table.concat(M.REGIONS, ', '))
  end
  if cfg.data_sharing ~= nil and not vim.tbl_contains(M.DATA_SHARING, cfg.data_sharing) then
    problems[#problems + 1] = ('data_sharing = %s is not one of %s'):format(
      vim.inspect(cfg.data_sharing), table.concat(M.DATA_SHARING, ', '))
  end
  if cfg.accept_eula ~= nil and type(cfg.accept_eula) ~= 'boolean' then
    problems[#problems + 1] = ('accept_eula = %s is not a boolean'):format(vim.inspect(cfg.accept_eula))
  end
  return problems
end

--- @return string
function M.store_path()
  return vim.fs.normalize(vim.fn.stdpath('data') .. '/intellij-lsp/consent.json')
end

--- The stored answers, `{ eula_hash?, region?, data_sharing? }`; empty when nothing is stored or the
--- file does not parse. Values that are not valid answers are dropped, so a hand-edited file asks
--- again rather than failing the launch.
--- @return table
function M.read_store()
  local fd = io.open(M.store_path(), 'r')
  if not fd then return {} end
  local text = fd:read('*a')
  fd:close()
  local ok, data = pcall(vim.json.decode, text)
  if not ok or type(data) ~= 'table' then return {} end
  return {
    eula_hash = type(data.eula_hash) == 'string' and data.eula_hash or nil,
    region = vim.tbl_contains(M.REGIONS, data.region) and data.region or nil,
    data_sharing = vim.tbl_contains(M.DATA_SHARING, data.data_sharing) and data.data_sharing or nil,
  }
end

--- Merges `answers` into the store. A `false` value removes that key.
--- @param answers table
function M.update_store(answers)
  local data = M.read_store()
  for key, value in pairs(answers) do
    data[key] = value or nil
  end
  local path = M.store_path()
  vim.fn.mkdir(vim.fs.dirname(path), 'p')
  vim.fn.writefile({ vim.json.encode(data) }, path)
end

--- The value of `-Dintellij.server.license.dir=` in a string of JVM options, if any; the last one wins,
--- as on the JVM. Accepts the option quoted the way `launch.build_env` quotes it.
--- @param options string[]
--- @return string|nil
local function license_dir_option(options)
  local found
  for _, option in ipairs(options) do
    local value = option:match('^"?%-Dintellij%.server%.license%.dir=(.-)"?$')
    if value and value ~= '' then found = value end
  end
  return found
end

--- The server's license store, where it records accepted EULA hashes.
---
--- Mirrors the server's `defaultLicenseDir`: the `intellij.server.license.dir` system property when
--- one reaches the JVM -- from `IJ_JAVA_OPTIONS` or the plugin's `jvm_args`, which `build_env`
--- appends after it -- and otherwise IntelliJ's per-user config directory for "IntelliJServer".
--- @param jvm_args string[]|nil
--- @return string
function M.license_dir(jvm_args)
  local inherited = vim.split(vim.env.IJ_JAVA_OPTIONS or '', '%s+', { trimempty = true })
  local configured = license_dir_option(vim.list_extend(inherited, jvm_args or {}))
  if configured then return vim.fs.normalize(configured) end

  local home = vim.uv.os_homedir()
  local sysname = vim.uv.os_uname().sysname
  local base
  if sysname == 'Darwin' then
    base = home .. '/Library/Application Support'
  elseif sysname == 'Windows_NT' then
    base = vim.env.APPDATA or (home .. '/AppData/Roaming')
  else
    base = vim.env.XDG_CONFIG_HOME or (home .. '/.config')
  end
  return vim.fs.normalize(base .. '/JetBrains/IntelliJServer')
end

--- Whether the server has already recorded acceptance of this EULA hash.
--- @param license_dir string
--- @param hash string
--- @return boolean
function M.server_accepted(license_dir, hash)
  local fd = io.open(license_dir .. '/eula-accepted.hashes', 'r')
  if not fd then return false end
  local text = fd:read('*a')
  fd:close()
  for line in text:gmatch('[^\r\n]+') do
    if vim.trim(line):lower() == hash then return true end
  end
  return false
end

--- Set once a server exited with "EULA not accepted" although the server's own record said it was.
--- The record cannot be trusted for the rest of the session, or the relaunch would loop.
local distrust_server_record = false

--- @class IntellijLspConsent
--- @field eula_hash string|nil      hash of the bundle's EULA.txt; nil for a dev bundle
--- @field eula_accepted boolean     the launch may pass `--eula`, or needs none
--- @field region string|nil
--- @field data_sharing string|nil
--- @field sources table<string, 'config'|'store'|'server'|'bundle'>  where each answer came from
--- @field missing string[]          questions still to ask, in order

--- What is known about consent for a bundle, without asking anything.
--- @param cfg table plugin configuration
--- @param server_root string bundle root
--- @param store table|nil stored answers; read from disk when nil
--- @return IntellijLspConsent
function M.resolve(cfg, server_root, store)
  store = store or M.read_store()
  local hash = eula.hash_for(server_root)
  local result = { eula_hash = hash, eula_accepted = false, sources = {}, missing = {} }

  if cfg.region then
    result.region, result.sources.region = cfg.region, 'config'
  elseif store.region then
    result.region, result.sources.region = store.region, 'store'
  end

  if not hash then
    -- A dev bundle has no EULA and the server does not ask for one.
    result.eula_accepted, result.sources.eula = true, 'bundle'
  elseif cfg.accept_eula == true then
    result.eula_accepted, result.sources.eula = true, 'config'
  elseif store.eula_hash == hash then
    result.eula_accepted, result.sources.eula = true, 'store'
  elseif not distrust_server_record and M.server_accepted(M.license_dir(cfg.jvm_args), hash) then
    result.eula_accepted, result.sources.eula = true, 'server'
  end

  if cfg.data_sharing then
    result.data_sharing, result.sources.data_sharing = cfg.data_sharing, 'config'
  elseif store.data_sharing then
    result.data_sharing, result.sources.data_sharing = store.data_sharing, 'store'
  end

  if not result.region then table.insert(result.missing, 'region') end
  if not result.eula_accepted then table.insert(result.missing, 'eula') end
  if not result.data_sharing then table.insert(result.missing, 'data_sharing') end
  return result
end

-- ---------------------------------------------------------------------------------------------
-- Screens
-- ---------------------------------------------------------------------------------------------

--- The two single-choice questions: what each asks (lines), and its answers in order.
local QUESTIONS = {
  region = {
    text = { 'Select your region, for the product terms and data processing rules that apply to you.' },
    values = M.REGIONS,
    labels = M.REGION_LABELS,
  },
  data_sharing = {
    -- The URL on a line of its own, so it does not wrap mid-word.
    text = { 'Help JetBrains improve its products by sending usage statistics and error reports. Details:',
      M.DATA_SHARING_URL },
    values = M.DATA_SHARING,
    labels = M.DATA_SHARING_LABELS,
  },
}

--- `Java and Kotlin by IntelliJ IDEA · Setup 1/3`: every screen names the product and how far along
--- the questions are, since the first one opens before anything else of the plugin has shown.
--- @param index integer
--- @param total integer
--- @return string
function M._screen_title(index, total)
  return require('intellij-lsp.activation').title(('Setup %d/%d'):format(index, total))
end

--- The welcome that opens the first screen, as VS Code's setup does.
--- @param total integer how many questions follow
--- @return string[]
function M._welcome(total)
  return {
    'Welcome to ' .. require('intellij-lsp.licensing').PRODUCT .. '!',
    ('Before the server starts for the first time, %s. They are asked once; '):format(
      total == 1 and 'answer one question' or ('answer %d questions'):format(total))
      .. ':IntellijLspLicense setup asks again.',
    '',
  }
end

--- A single-choice question in the shared licensing float (`activation.choose`): a digit or <CR>
--- on an entry answers, `q`, <Esc> or closing the float declines. It replaces a license float open
--- from before, which must not hide the question: an unanswered question keeps every launch waiting.
--- @param step 'region'|'data_sharing'
--- @param index integer position among the questions asked now
--- @param total integer
--- @param done fun(value: string|nil)
function M._choose(step, index, total, done)
  local q = QUESTIONS[step]
  local text = index == 1 and M._welcome(total) or {}
  vim.list_extend(text, q.text)
  require('intellij-lsp.activation').choose({
    title = M._screen_title(index, total),
    text = text,
    items = q.values,
    format = function(value) return q.labels[value] end,
    highlights = index == 1 and { { 1, 'Title' } } or nil,
  }, function(value) done(value) end)
end

--- The EULA in a scrollable, read-only float: `a` accepts, `q` or <Esc> declines, and so does
--- closing the window any other way. As the first screen it opens with the welcome.
--- @param text string contents of EULA.txt
--- @param done fun(accepted: boolean)
--- @param opts { index: integer, total: integer }|nil where it stands among the questions
--- @return integer win
function M._open_eula(text, done, opts)
  opts = opts or { index = 1, total = 1 }
  local lines = vim.split(text:gsub('\r\n', '\n'), '\n')
  if opts.index == 1 then
    local welcome = vim.tbl_map(function(l) return l ~= '' and (' ' .. l) or '' end, M._welcome(opts.total))
    lines = vim.list_extend(welcome, lines)
  end
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = 'wipe'
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  if opts.index == 1 then
    vim.hl.range(buf, vim.api.nvim_create_namespace('intellij-lsp.consent'), 'Title', { 0, 0 }, { 0, -1 })
  end

  local width = require('intellij-lsp.activation').width()
  local height = math.max(5, vim.o.lines - 6)
  local win = vim.api.nvim_open_win(buf, true, {
    relative = 'editor',
    row = math.floor((vim.o.lines - height) / 2) - 1,
    col = math.floor((vim.o.columns - width) / 2),
    width = width, height = height,
    style = 'minimal', border = 'rounded', zindex = 200,
    title = ' ' .. M._screen_title(opts.index, opts.total) .. ': license agreement ', title_pos = 'center',
    footer = ' a  accept    q  decline ', footer_pos = 'center',
  })
  vim.wo[win].wrap = true
  vim.wo[win].linebreak = true

  local answered = false
  local function finish(accepted)
    if answered then return end
    answered = true
    pcall(vim.api.nvim_win_close, win, true)
    -- Out of the mapping or the WinClosed handler, so the next screen opens on a settled UI.
    vim.schedule(function() done(accepted) end)
  end

  local function map(lhs, accepted)
    vim.keymap.set('n', lhs, function() finish(accepted) end, { buffer = buf, nowait = true })
  end
  map('a', true)
  map('q', false)
  map('<Esc>', false)

  vim.api.nvim_create_autocmd('WinClosed', {
    pattern = tostring(win),
    once = true,
    callback = function() finish(false) end,
  })
  return win
end

local function ask_eula(server_root, index, total, done)
  local text = eula.read(server_root)
  if not text then return done(true) end
  M._open_eula(text, done, { index = index, total = total })
end

--- Asks the given questions in order and records each answer as it is given.
--- @param steps string[] subset of STEPS, in order
--- @param server_root string
--- @param done fun(completed: boolean, declined_step: string|nil)
local function ask(steps, server_root, done)
  local i = 0
  local function next_step()
    i = i + 1
    local step = steps[i]
    if not step then return done(true) end
    if step == 'region' then
      M._choose('region', i, #steps, function(region)
        if not region then return done(false, step) end
        M.update_store({ region = region })
        next_step()
      end)
    elseif step == 'eula' then
      ask_eula(server_root, i, #steps, function(accepted)
        if not accepted then return done(false, step) end
        local hash = eula.hash_for(server_root)
        if hash then M.update_store({ eula_hash = hash }) end
        next_step()
      end)
    else
      M._choose('data_sharing', i, #steps, function(level)
        if not level then return done(false, step) end
        M.update_store({ data_sharing = level })
        next_step()
      end)
    end
  end
  next_step()
end

M._ask = ask

-- ---------------------------------------------------------------------------------------------
-- The launch gate
-- ---------------------------------------------------------------------------------------------

--- Set once Neovim without a UI started a server on the server's defaults for region and data
--- sharing, so later launches do the same without saying it again.
local headless_defaults = false

--- The consent to launch with when there is no UI to ask: the server's own defaults for region (none)
--- and data sharing (none) stand in for the missing answers. The EULA has no default; nobody can
--- accept it for the user.
--- @param consent IntellijLspConsent
--- @return IntellijLspConsent
local function with_server_defaults(consent)
  return vim.tbl_extend('force', consent, { missing = {} })
end

--- Callbacks waiting on the one consent flow on screen. Every launch that finds consent incomplete
--- joins it, so several buffers attaching at once see the screens once.
--- @type fun(consent: IntellijLspConsent|nil)[]|nil
local pending = nil

--- Set when the user declined or closed a screen. No later launch in this session asks again;
--- `:IntellijLspLicense setup` clears it.
local declined = false

local REOPEN_HINT = 'Run :IntellijLspLicense setup to answer the questions again.'

--- Whether a consent screen was declined in this session, so no server starts until
--- `:IntellijLspLicense setup`; for `:checkhealth`.
function M.declined()
  return declined
end

--- Neovim with no UI attached (`--headless`, a script) cannot show the screens.
function M._has_ui()
  return #vim.api.nvim_list_uis() > 0
end

local function flush(result)
  local callbacks = pending or {}
  pending = nil
  for _, cb in ipairs(callbacks) do cb(result) end
end

--- Calls `callback` with the consent to launch with, or with nil when the server must not start.
---
--- Synchronous when nothing needs asking, so a fully configured or already answered setup starts
--- exactly as it would without this gate. Otherwise the screens open from the main loop and every
--- caller is answered once they are done.
--- @param cfg table plugin configuration, with `server_path` set
--- @param callback fun(consent: IntellijLspConsent|nil)
function M.ensure(cfg, callback)
  local server_root = launch.server_root(cfg.server_path)
  local consent = M.resolve(cfg, server_root)
  if #consent.missing == 0 then return callback(consent) end
  if declined then return callback(nil) end
  if headless_defaults and consent.eula_accepted and not M._has_ui() then
    return callback(with_server_defaults(consent))
  end
  if pending then
    table.insert(pending, callback)
    return
  end

  pending = { callback }
  vim.schedule(function()
    if not M._has_ui() then
      if not consent.eula_accepted then
        declined = true
        vim.notify(
          'IntelliJ LSP: the server was not started: no UI to show the license agreement. Read '
            .. server_root .. '/EULA.txt and set accept_eula = true in setup().',
          vim.log.levels.ERROR
        )
        return flush(nil)
      end
      -- Region and data sharing have server defaults, and a scripted or CI setup that set only
      -- `accept_eula` started a server before these questions existed; it keeps doing so.
      headless_defaults = true
      local names = vim.tbl_map(function(step) return STEP_NAMES[step] end, consent.missing)
      vim.notify(
        ('IntelliJ LSP: no UI to ask for %s; starting with the server\'s defaults (no region, no usage '
          .. 'statistics). Set region and data_sharing in setup() to choose.'):format(table.concat(names, ', ')),
        vim.log.levels.WARN
      )
      return flush(with_server_defaults(consent))
    end

    require('intellij-lsp.activation').when_idle(function() ask(consent.missing, server_root, function(completed, step)
      if not completed then
        declined = true
        vim.notify(
          ('IntelliJ LSP: the server was not started: %s. %s'):format(DECLINED[step], REOPEN_HINT),
          vim.log.levels.WARN
        )
        return flush(nil)
      end
      local final = M.resolve(cfg, server_root)
      flush(#final.missing == 0 and final or nil)
    end) end)
  end)
end

--- Asks every question the config does not answer, whatever is stored, for `:IntellijLspLicense
--- setup`. Closing a screen keeps the answers given before it and leaves the rest as they were.
--- @param cfg table plugin configuration
--- @param on_changed fun(before: IntellijLspConsent, after: IntellijLspConsent) called once all are answered
function M.setup_again(cfg, on_changed)
  if pending then
    vim.notify('IntelliJ LSP: the consent questions are already open.', vim.log.levels.WARN)
    return
  end
  local server_root = launch.server_root(cfg.server_path)
  local before = M.resolve(cfg, server_root)
  local steps = vim.tbl_filter(function(step)
    return before.sources[step] ~= 'config' and before.sources[step] ~= 'bundle'
  end, STEPS)
  if #steps == 0 then
    vim.notify(
      'IntelliJ LSP: accept_eula, region and data_sharing all come from your setup() config.',
      vim.log.levels.INFO
    )
    return
  end

  -- Launches that come in meanwhile wait on these screens too, and start with what they leave.
  pending = {}
  ask(steps, server_root, function(completed, step)
    local after = M.resolve(cfg, server_root)
    flush(#after.missing == 0 and after or nil)
    if not completed then
      vim.notify(('IntelliJ LSP: %s; the answers given so far are kept.'):format(DECLINED[step]),
        vim.log.levels.WARN)
      return
    end
    declined = false
    on_changed(before, after)
  end)
end

--- Whether a server started with `before` would start differently with `after`.
--- @param before IntellijLspConsent
--- @param after IntellijLspConsent
--- @return boolean
function M.launch_differs(before, after)
  return before.region ~= after.region
    or before.data_sharing ~= after.data_sharing
    or before.eula_accepted ~= after.eula_accepted
end

-- ---------------------------------------------------------------------------------------------
-- Exit codes
-- ---------------------------------------------------------------------------------------------

local handling_rejection = false

--- Exit code 11: the server did not accept the EULA. Forgets the stored acceptance and asks again;
--- `relaunch` runs once it is accepted. Several servers exiting together ask once.
--- @param cfg table
--- @param relaunch fun()
function M.eula_rejected(cfg, relaunch)
  if handling_rejection then return end
  if cfg.accept_eula == true then
    vim.notify(
      'IntelliJ LSP: the server did not accept the EULA although accept_eula = true (exit code 11). '
        .. 'See the server log.',
      vim.log.levels.ERROR
    )
    return
  end
  handling_rejection = true
  distrust_server_record = true
  M.update_store({ eula_hash = false })
  declined = false
  vim.notify('IntelliJ LSP: the server did not accept the EULA (exit code 11).', vim.log.levels.WARN)
  M.ensure(cfg, function(consent)
    handling_rejection = false
    if consent then relaunch() end
  end)
end

local handling_corruption = false

--- Exit code 12: the bundle's `EULA.txt` is missing or modified, so the bundle is not the one that
--- was published. A downloaded bundle can be replaced; a bundle the user pointed at cannot.
--- @param server_path string
--- @param reinstall fun() deletes and downloads the bundle again, then relaunches
function M.bundle_corrupted(server_path, reinstall)
  if handling_corruption then return end
  local root = launch.server_root(server_path)
  local cache = require('intellij-lsp.server_download').cache_root()
  if not vim.startswith(vim.fs.normalize(root), cache .. '/') then
    vim.notify(
      ('IntelliJ LSP: the server bundle at %s is corrupted: its EULA.txt is missing or modified '
        .. '(exit code 12). Reinstall it.'):format(root),
      vim.log.levels.ERROR
    )
    return
  end
  handling_corruption = true
  require('intellij-lsp.activation').choose({
    title = require('intellij-lsp.activation').title('Server bundle'),
    text = { 'The server bundle is corrupted: its EULA.txt is missing or modified (exit code 12).' },
    items = { 'Delete and download again', 'Not now' },
  }, function(_, idx)
    handling_corruption = false
    if idx == 1 then reinstall() end
  end)
end

--- Forgets every stored answer, so the next launch asks again what the config does not set; for
--- `:IntellijLspLicense reset`. A decline earlier in the session no longer holds launches back.
function M.forget()
  vim.fn.delete(M.store_path())
  declined, distrust_server_record = false, false
end

--- Clears the session state, for tests.
function M._reset()
  pending, declined, distrust_server_record, headless_defaults = nil, false, false, false
  handling_rejection, handling_corruption = false, false
end

return M
