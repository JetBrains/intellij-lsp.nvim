-- Unit checks for the pure launch/eula logic. No server required.
--
--   nvim --headless -u NONE -l test/units.lua
vim.opt.runtimepath:prepend(vim.fs.dirname(vim.fs.dirname(debug.getinfo(1, 'S').source:sub(2))))

local launch = require('intellij-lsp.launch')
local eula = require('intellij-lsp.eula')
local client = require('intellij-lsp.client')

local failures = 0
local function check(name, cond, detail)
  if cond then
    print('ok   ' .. name)
  else
    failures = failures + 1
    print('FAIL ' .. name .. (detail and ('  -> ' .. tostring(detail)) or ''))
  end
end

-- Path-shaped fixtures: these checks are pure string/hash logic and touch no real bundle.
local BUNDLE = vim.fs.normalize(vim.fn.tempname() .. '-bundle')
local SERVER = BUNDLE .. '/bin/intellij-server'

-- server_root strips bin/<launcher>
check('server_root', launch.server_root(SERVER) == BUNDLE, launch.server_root(SERVER))

-- system_path is deterministic and project-scoped
local sp1 = launch.system_path('/tmp/ijtest')
local sp2 = launch.system_path('/tmp/ijtest')
local sp3 = launch.system_path('/tmp/other')
check('system_path deterministic', sp1 == sp2)
check('system_path per-project', sp1 ~= sp3)
check('system_path under cache', sp1:find(vim.fn.stdpath('cache'), 1, true) == 1, sp1)

-- cmd: stdio + system-path, and no --eula for a dev bundle (no EULA.txt)
local cmd = launch.build_cmd({ server_path = SERVER, root_dir = '/tmp/ijtest', accept_eula = true })
check('cmd[1] is launcher', cmd[1] == SERVER)
check('cmd has --stdio', vim.tbl_contains(cmd, '--stdio'))
check('cmd has --system-path', vim.tbl_contains(cmd, '--system-path'))
check('dev bundle -> no --eula', not vim.tbl_contains(cmd, '--eula'), table.concat(cmd, ' '))

-- An explicitly claimed cache directory is what reaches the command line.
local cmd_slot = launch.build_cmd({ server_path = SERVER, root_dir = '/tmp/ijtest', accept_eula = false, system_path = '/tmp/ij-slot-2' })
check('cmd uses the claimed system path', cmd_slot[4] == '/tmp/ij-slot-2', cmd_slot[4])

-- Slots: one cache directory per live Neovim instance on the same project.
check('slot 1 is the plain path', launch.system_path('/tmp/ijtest', 1) == launch.system_path('/tmp/ijtest'))
check('slot 2 is suffixed', launch.system_path('/tmp/ijtest', 2) == launch.system_path('/tmp/ijtest') .. '-2',
  launch.system_path('/tmp/ijtest', 2))

do
  local root = vim.fn.tempname() .. '-claimroot'
  local me = vim.uv.os_getpid()
  local p1, p2 = launch.system_path(root, 1), launch.system_path(root, 2)

  local got, slot = launch.claim_system_path(root)
  check('first claim takes slot 1', got == p1 and slot == 1, got)
  check('claim records our pid', launch.system_path_owner(p1) == me, tostring(launch.system_path_owner(p1)))
  local again = launch.claim_system_path(root)
  check('re-claiming our own slot keeps it', again == p1, again)

  -- Another live process holds slot 1: the parent shell is alive for the duration of this test.
  vim.fn.writefile({ tostring(vim.uv.os_getppid()) }, p1 .. '/nvim.pid')
  got, slot = launch.claim_system_path(root)
  check('a live foreign owner pushes us to slot 2', got == p2 and slot == 2, got)
  check('slot 2 records our pid', launch.system_path_owner(p2) == me)

  -- A dead owner does not block a slot (Neovim killed before on_exit ran).
  vim.fn.writefile({ '4194000' }, p1 .. '/nvim.pid')
  got, slot = launch.claim_system_path(root)
  check('a stale owner is overtaken', got == p1 and slot == 1, got)

  launch.release_system_path(p1)
  check('release removes our owner file', launch.system_path_owner(p1) == nil)
  vim.fn.writefile({ tostring(vim.uv.os_getppid()) }, p1 .. '/nvim.pid')
  launch.release_system_path(p1)
  check('release leaves a foreign owner alone', launch.system_path_owner(p1) == vim.uv.os_getppid())

  vim.fn.delete(p1, 'rf'); vim.fn.delete(p2, 'rf')
end

-- Failed initialize: the reason is the line after the last SEVERE header in the server log.
local severe_log = {
  '2026-09-29 19:55:30,840 [    749]   INFO - #c.i.l.s.k.tt - Got `initialize` request',
  '2026-09-29 19:55:30,961 [    870] SEVERE - #c.j.l.i.LspClient - ',
  'org.rocksdb.RocksDBException: While lock file: /x/rocks/v276/LOCK: Resource temporarily unavailable',
  '\tat org.rocksdb.RocksDB.open(Native Method)',
}
check('last SEVERE reason is the exception line',
  client._last_severe(severe_log) == 'org.rocksdb.RocksDBException: While lock file: /x/rocks/v276/LOCK: Resource temporarily unavailable',
  client._last_severe(severe_log))
check('SEVERE with inline text falls back to that text',
  client._last_severe({ '2026-09-29 19:55:30,961 [ 870] SEVERE - #c.j.l.i.LspClient - License expired' }) == 'License expired',
  client._last_severe({ '2026-09-29 19:55:30,961 [ 870] SEVERE - #c.j.l.i.LspClient - License expired' }))
check('no SEVERE -> nil', client._last_severe({ 'INFO - fine', 'INFO - also fine' }) == nil)
check('server log path under the claimed directory',
  client.server_log_path('/c/slot') == '/c/slot/system/log/intellij-server.log')
check('eula.hash_for nil for dev bundle', eula.hash_for(BUNDLE) == nil)

-- eula hashing: 16 lowercase hex chars of sha256, matching the server's expectation
local tmp = vim.fs.normalize(vim.fn.tempname() .. '-released')
vim.fn.mkdir(tmp, 'p')
vim.fn.writefile({ 'LICENSE TEXT' }, tmp .. '/EULA.txt')
local h = eula.hash_for(tmp)
local expected = vim.fn.sha256(table.concat(vim.fn.readfile(tmp .. '/EULA.txt', 'b'), '\n')):lower():sub(1, 16)
check('hash is 16 chars', h and #h == 16, h)
check('hash is lowercase hex', h and h:match('^[0-9a-f]+$') ~= nil, h)
check('hash matches sha256 prefix', h == expected, tostring(h) .. ' vs ' .. tostring(expected))

local cmd2 = launch.build_cmd({ server_path = tmp .. '/bin/intellij-server', root_dir = '/tmp/ijtest', accept_eula = true })
check('released bundle -> --eula passed', vim.tbl_contains(cmd2, '--eula'), table.concat(cmd2, ' '))
local cmd3 = launch.build_cmd({ server_path = tmp .. '/bin/intellij-server', root_dir = '/tmp/ijtest', accept_eula = false })
check('accept_eula=false -> no --eula', not vim.tbl_contains(cmd3, '--eula'))

-- env hygiene: the three trap variables
vim.env.IJ_LAUNCHER_DEBUG = '1'
vim.env.INTELLIJ_DATA_SHARING = 'full'
vim.env.INTELLIJ_REGION = 'europe'
local env = launch.build_env({ '-Xmx4g', '-Dfoo=a b' })
-- Absent, not false: vim.system stringifies false to "false", which the server rejects.
check('IJ_LAUNCHER_DEBUG absent', env.IJ_LAUNCHER_DEBUG == nil, tostring(env.IJ_LAUNCHER_DEBUG))
check('INTELLIJ_DATA_SHARING absent', env.INTELLIJ_DATA_SHARING == nil, tostring(env.INTELLIJ_DATA_SHARING))
check('INTELLIJ_REGION absent', env.INTELLIJ_REGION == nil, tostring(env.INTELLIJ_REGION))
check('env carries inherited vars (PATH)', env.PATH ~= nil)
check('no value is a boolean', (function()
  for _, v in pairs(env) do if type(v) ~= 'string' then return false end end
  return true
end)())
check('jvm args -> IJ_JAVA_OPTIONS', env.IJ_JAVA_OPTIONS and env.IJ_JAVA_OPTIONS:find('-Xmx4g', 1, true) ~= nil, env.IJ_JAVA_OPTIONS)
check('jvm arg with space quoted', env.IJ_JAVA_OPTIONS:find('"-Dfoo=a b"', 1, true) ~= nil, env.IJ_JAVA_OPTIONS)
check('no jvm args -> unset', launch.build_env(nil).IJ_JAVA_OPTIONS == nil)

-- Consent reaches the server only through build_env, replacing whatever was inherited.
local cenv = launch.build_env(nil, { region = 'apac', data_sharing = 'anonymous' })
check('consent region -> INTELLIJ_REGION', cenv.INTELLIJ_REGION == 'apac', tostring(cenv.INTELLIJ_REGION))
check('consent data sharing -> INTELLIJ_DATA_SHARING', cenv.INTELLIJ_DATA_SHARING == 'anonymous', tostring(cenv.INTELLIJ_DATA_SHARING))
check('consent full -> INTELLIJ_DATA_SHARING=full', launch.build_env(nil, { data_sharing = 'full' }).INTELLIJ_DATA_SHARING == 'full')
local none_env = launch.build_env(nil, { region = 'europe', data_sharing = 'none' })
check("data_sharing 'none' leaves the variable out", none_env.INTELLIJ_DATA_SHARING == nil, tostring(none_env.INTELLIJ_DATA_SHARING))
check('no region -> inherited INTELLIJ_REGION still cleared', launch.build_env(nil, { data_sharing = 'full' }).INTELLIJ_REGION == nil)

-- Absent from the table is not absent from the child: vim.system merges over Neovim's environment.
-- So look at what a real child process received.
do
  local out = vim.fn.tempname()
  local spawn = launch.spawn({ 'sh', '-c', 'env > ' .. vim.fn.shellescape(out) },
    launch.build_env(nil, { region = 'apac', data_sharing = 'none' }))
  local exited = false
  local ok, err = pcall(spawn, { on_exit = function() exited = true end }, {})
  vim.wait(5000, function() return exited end, 20)
  local child = {}
  for _, line in ipairs(vim.uv.fs_stat(out) and vim.fn.readfile(out) or {}) do
    local k, v = line:match('^([%w_]+)=(.*)$')
    if k then child[k] = v end
  end
  check('spawn starts the child', ok and exited and child.PATH ~= nil, tostring(err))
  check('child: inherited INTELLIJ_DATA_SHARING is unset', child.INTELLIJ_DATA_SHARING == nil, child.INTELLIJ_DATA_SHARING)
  check('child: inherited IJ_LAUNCHER_DEBUG is unset', child.IJ_LAUNCHER_DEBUG == nil, child.IJ_LAUNCHER_DEBUG)
  check('child: consent region replaces the inherited one', child.INTELLIJ_REGION == 'apac', child.INTELLIJ_REGION)
  check("spawn puts Neovim's own environment back",
    vim.env.INTELLIJ_DATA_SHARING == 'full' and vim.env.IJ_LAUNCHER_DEBUG == '1' and vim.env.INTELLIJ_REGION == 'europe')
end
vim.env.IJ_LAUNCHER_DEBUG, vim.env.INTELLIJ_DATA_SHARING, vim.env.INTELLIJ_REGION = nil, nil, nil

do -- scoped: Lua allows 200 locals per chunk
-- ---------------------------------------------------------------------------
-- Consent: region, EULA and data sharing before the server starts
-- ---------------------------------------------------------------------------
local consent = require('intellij-lsp.consent')
local real_store_path, real_has_ui = consent.store_path, consent._has_ui
local store_file = vim.fn.tempname() .. '-consent/consent.json'
consent.store_path = function() return store_file end

check('valid consent options pass', #consent.validate({ accept_eula = true, region = 'europe', data_sharing = 'none' }) == 0)
check('unset consent options pass', #consent.validate({}) == 0)
local bad = consent.validate({ region = 'mars', data_sharing = 'some', accept_eula = 'yes' })
check('three bad consent options -> three problems', #bad == 3, vim.inspect(bad))
check('the problem names the bad value', bad[1]:find('"mars"', 1, true) ~= nil, bad[1])
check('regions: Europe first', consent.REGIONS[1] == 'europe')
check('every region has a label', #vim.tbl_filter(function(r) return consent.REGION_LABELS[r] == nil end, consent.REGIONS) == 0)

-- Store
check('no store file -> empty store', vim.tbl_isempty(consent.read_store()))
consent.update_store({ region = 'china' })
consent.update_store({ data_sharing = 'full', eula_hash = 'abc' })
local stored = consent.read_store()
check('store merges answers', stored.region == 'china' and stored.data_sharing == 'full' and stored.eula_hash == 'abc', vim.inspect(stored))
consent.update_store({ eula_hash = false })
check('false removes a stored answer', consent.read_store().eula_hash == nil and consent.read_store().region == 'china')
vim.fn.writefile({ '{"region":"mars","data_sharing":"none"}' }, store_file)
check('an invalid stored value is dropped', consent.read_store().region == nil and consent.read_store().data_sharing == 'none', vim.inspect(consent.read_store()))
vim.fn.writefile({ 'not json' }, store_file)
check('an unparsable store reads as empty', vim.tbl_isempty(consent.read_store()))
vim.fn.delete(store_file)

-- The server's license dir and its EULA record
check('license dir from jvm_args', consent.license_dir({ '-Xmx1g', '-Dintellij.server.license.dir=/tmp/lic' }) == '/tmp/lic',
  consent.license_dir({ '-Dintellij.server.license.dir=/tmp/lic' }))
vim.env.IJ_JAVA_OPTIONS = '-Dintellij.server.license.dir=/tmp/inherited -Xss2m'
check('license dir from IJ_JAVA_OPTIONS', consent.license_dir(nil) == '/tmp/inherited', consent.license_dir(nil))
check('jvm_args win over IJ_JAVA_OPTIONS', consent.license_dir({ '-Dintellij.server.license.dir=/tmp/mine' }) == '/tmp/mine')
vim.env.IJ_JAVA_OPTIONS = nil
check('default license dir is JetBrains/IntelliJServer', vim.endswith(consent.license_dir(nil), '/JetBrains/IntelliJServer'), consent.license_dir(nil))

local lic_dir = vim.fn.tempname() .. '-lic'
vim.fn.mkdir(lic_dir, 'p')
vim.fn.writefile({ '1111111111111111', '2222222222222222' }, lic_dir .. '/eula-accepted.hashes')
check('server record: listed hash accepted', consent.server_accepted(lic_dir, '2222222222222222'))
check('server record: other hash not accepted', not consent.server_accepted(lic_dir, '3333333333333333'))
check('server record: no file -> not accepted', not consent.server_accepted(lic_dir .. '-none', '1111111111111111'))

-- resolve: config, then store, then the server's record
local cbundle = vim.fn.tempname() .. '-cbundle'
vim.fn.mkdir(cbundle .. '/bin', 'p')
vim.fn.writefile({ 'EULA text', 'second line' }, cbundle .. '/EULA.txt')
local chash = eula.hash_for(cbundle)
local empty_lic = { '-Dintellij.server.license.dir=' .. lic_dir .. '-none' }

local r = consent.resolve({ jvm_args = empty_lic }, cbundle, {})
check('nothing answered -> asks region, eula, data sharing in order',
  vim.deep_equal(r.missing, { 'region', 'eula', 'data_sharing' }), vim.inspect(r.missing))
check('unanswered EULA is not accepted', r.eula_accepted == false and r.eula_hash == chash)

r = consent.resolve({ accept_eula = true, region = 'europe', data_sharing = 'none' }, cbundle, { region = 'china' })
check('fully configured -> nothing to ask', #r.missing == 0, vim.inspect(r.missing))
check('config wins over the store', r.region == 'europe' and r.sources.region == 'config', vim.inspect(r))

r = consent.resolve({ jvm_args = empty_lic }, cbundle, { eula_hash = chash, region = 'oceania', data_sharing = 'full' })
check('stored answers -> nothing to ask', #r.missing == 0 and r.sources.eula == 'store' and r.region == 'oceania', vim.inspect(r))

r = consent.resolve({ jvm_args = empty_lic }, cbundle, { eula_hash = 'stalestalestale0', region = 'oceania', data_sharing = 'full' })
check('a changed EULA is asked again', vim.deep_equal(r.missing, { 'eula' }), vim.inspect(r.missing))

vim.fn.writefile({ chash }, lic_dir .. '/eula-accepted.hashes')
r = consent.resolve({ jvm_args = { '-Dintellij.server.license.dir=' .. lic_dir } }, cbundle, {})
check("the server's record accepts the EULA", r.eula_accepted and r.sources.eula == 'server', vim.inspect(r.sources))

r = consent.resolve({ region = 'europe', data_sharing = 'none' }, BUNDLE, {})
check('dev bundle: no EULA to ask', #r.missing == 0 and r.sources.eula == 'bundle' and r.eula_hash == nil, vim.inspect(r))

-- client.config launches with what consent settled
local ccfg = client.config('/tmp/ijconsent', { server_path = cbundle .. '/bin/intellij-server' },
  { eula_accepted = true, region = 'americas', data_sharing = 'anonymous' })
check('settled EULA -> --eula <hash>', vim.tbl_contains(ccfg.server_cmd, '--eula') and vim.tbl_contains(ccfg.server_cmd, chash), table.concat(ccfg.server_cmd, ' '))
check('settled region in cmd_env', ccfg.cmd_env.INTELLIJ_REGION == 'americas')
check('settled data sharing in cmd_env', ccfg.cmd_env.INTELLIJ_DATA_SHARING == 'anonymous')
local unsettled = client.config('/tmp/ijconsent', { server_path = cbundle .. '/bin/intellij-server' },
  { eula_accepted = false })
check('unaccepted EULA -> no --eula', not vim.tbl_contains(unsettled.server_cmd, '--eula'))
check('external showDocument goes to signin.lua',
  ccfg.handlers['window/showDocument'] == require('intellij-lsp.signin').show_document)
launch.release_system_path(ccfg.system_path)

-- ensure: one pending consent, shared by every launch
local select_mod = require('intellij-lsp.select')
local real_select, real_open_eula, real_ui_select = select_mod.select, consent._open_eula, vim.ui.select
local real_choose = consent._choose
local prompts, eula_opened, eula_answer = {}, 0, true
consent._choose = function(step, _, _, done)
  table.insert(prompts, step)
  -- Region: Europe (row 1). Data sharing: anonymous (row 2).
  vim.schedule(function() done(step == 'region' and 'europe' or 'anonymous') end)
end
consent._open_eula = function(_, done) eula_opened = eula_opened + 1; vim.schedule(function() done(eula_answer) end) end
consent._has_ui = function() return true end

local ecfg = { server_path = cbundle .. '/bin/intellij-server', jvm_args = empty_lic }
consent._reset()
vim.fn.delete(store_file)
local results, sync_result = {}, nil
for i = 1, 3 do consent.ensure(ecfg, function(c) results[i] = c or false end) end
check('incomplete consent answers nobody synchronously', vim.tbl_isempty(results))
vim.wait(1000, function() return #results == 3 end, 10)
check('three launches -> each screen shown once', #prompts == 2 and eula_opened == 1, vim.inspect(prompts) .. ' eula=' .. eula_opened)
check('screens in order: region, EULA, data sharing', prompts[1] == 'region' and prompts[2] == 'data_sharing', vim.inspect(prompts))
check('every waiting launch gets the consent', #results == 3 and results[3] and results[3].region == 'europe'
  and results[3].data_sharing == 'anonymous' and results[3].eula_accepted, vim.inspect(results[3]))
check('answers are stored', vim.deep_equal(consent.read_store(), { eula_hash = chash, region = 'europe', data_sharing = 'anonymous' }), vim.inspect(consent.read_store()))
consent.ensure(ecfg, function(c) sync_result = c end)
check('answered consent -> synchronous, no screens', sync_result and #prompts == 2 and eula_opened == 1)

-- Declining the EULA starts nothing, and no later launch asks again this session.
consent._reset()
vim.fn.delete(store_file)
prompts, eula_opened, eula_answer = {}, 0, false
local declined_results = {}
local real_notify, notified = vim.notify, {}
vim.notify = function(msg, level) table.insert(notified, { msg = msg, level = level }) end
for i = 1, 2 do consent.ensure(ecfg, function(c) declined_results[i] = c or false end) end
vim.wait(1000, function() return #declined_results == 2 end, 10)
check('declined EULA -> every launch refused', declined_results[1] == false and declined_results[2] == false, vim.inspect(declined_results))
check('declined EULA -> data sharing never asked', #prompts == 1, vim.inspect(prompts))
check('declining notifies once, with the way back', #notified == 1 and notified[1].msg:find(':IntellijLspLicense setup', 1, true), vim.inspect(notified))
check('the region answer before the decline is kept', consent.read_store().region == 'europe' and consent.read_store().eula_hash == nil)
local after_decline = 'unset'
consent.ensure(ecfg, function(c) after_decline = c end)
check('after a decline: refused at once, no screen', after_decline == nil and eula_opened == 1)
check('after a decline: declined() tells :checkhealth', consent.declined() == true)

-- No UI: nothing can be asked. Without the EULA accepted the launch is refused; with it, region and
-- data sharing fall back to the server's defaults, as before these questions existed.
consent._reset()
consent._has_ui = function() return false end
notified = {}
local headless_result = 'unset'
consent.ensure(ecfg, function(c) headless_result = c end)
vim.wait(1000, function() return headless_result ~= 'unset' end, 10)
check('headless, EULA not accepted: refused', headless_result == nil)
check('headless, EULA not accepted: says to set accept_eula', notified[1]
  and notified[1].msg:find('set accept_eula = true', 1, true), vim.inspect(notified))
consent._reset()
vim.fn.delete(store_file)
notified = {}
headless_result = 'unset'
local hcfg = vim.tbl_extend('force', ecfg, { accept_eula = true })
consent.ensure(hcfg, function(c) headless_result = c end)
vim.wait(1000, function() return headless_result ~= 'unset' end, 10)
check('headless, only accept_eula: starts on the server defaults', type(headless_result) == 'table'
  and headless_result.region == nil and headless_result.data_sharing == nil and #headless_result.missing == 0,
  vim.inspect(headless_result))
check('headless defaults: one warning naming the options', #notified == 1 and notified[1].level == vim.log.levels.WARN
  and notified[1].msg:find('region and data_sharing', 1, true), vim.inspect(notified))
local again = 'unset'
consent.ensure(hcfg, function(c) again = c end)
check('headless defaults: later launches start at once, without another warning',
  type(again) == 'table' and #notified == 1, vim.inspect(again))
check('headless defaults: the environment carries neither variable', (function()
  local env = launch.build_env(nil, headless_result)
  return env.INTELLIJ_REGION == nil and env.INTELLIJ_DATA_SHARING == nil
end)())
consent._reset()
consent._has_ui = function() return true end

-- :IntellijLspLicense setup asks again, except what the config fixes.
consent._reset()
consent.update_store({ eula_hash = chash, region = 'china', data_sharing = 'full' })
prompts, eula_opened, eula_answer = {}, 0, true
local changed
consent.setup_again(vim.tbl_extend('force', ecfg, { region = 'europe' }), function(before, after) changed = { before, after } end)
vim.wait(1000, function() return changed ~= nil end, 10)
check('setup again: region from config is not asked', #prompts == 1 and prompts[1] ~= 'region', vim.inspect(prompts))
check('setup again: stored EULA is asked again', eula_opened == 1)
check('setup again: reports before and after', changed and changed[1].data_sharing == 'full' and changed[2].data_sharing == 'anonymous', vim.inspect(changed))
check('a data-sharing change differs at launch', changed and consent.launch_differs(changed[1], changed[2]))
check('identical consent does not differ', not consent.launch_differs({ region = 'europe', data_sharing = 'none', eula_accepted = true }, { region = 'europe', data_sharing = 'none', eula_accepted = true }))

notified = {}
consent.setup_again({ server_path = ecfg.server_path, accept_eula = true, region = 'europe', data_sharing = 'none' }, function() error('nothing to ask') end)
check('setup again with everything configured says so', notified[1] and notified[1].msg:find('setup%(%) config'), vim.inspect(notified))

-- Exit code 11: forget the stored EULA, ask again, relaunch once accepted.
consent._reset()
consent.update_store({ eula_hash = chash, region = 'europe', data_sharing = 'none' })
prompts, eula_opened, eula_answer = {}, 0, true
local relaunched = 0
consent.eula_rejected(ecfg, function() relaunched = relaunched + 1 end)
consent.eula_rejected(ecfg, function() relaunched = relaunched + 1 end)
vim.wait(1000, function() return relaunched > 0 end, 10)
check('exit 11: EULA asked again once', eula_opened == 1 and #prompts == 0, 'eula=' .. eula_opened .. ' ' .. vim.inspect(prompts))
check('exit 11: relaunched once', relaunched == 1, relaunched)
-- The server record named the hash too, but the server refused it: it is no longer trusted.
vim.fn.writefile({ chash }, lic_dir .. '/eula-accepted.hashes')
consent.update_store({ eula_hash = false })
r = consent.resolve({ jvm_args = { '-Dintellij.server.license.dir=' .. lic_dir } }, cbundle, {})
check('exit 11: server record distrusted afterwards', not r.eula_accepted, vim.inspect(r.sources))

consent._reset()
notified, relaunched = {}, 0
consent.eula_rejected(vim.tbl_extend('force', ecfg, { accept_eula = true }), function() relaunched = relaunched + 1 end)
check('exit 11 with accept_eula = true: error, no loop', relaunched == 0 and notified[1] and notified[1].level == vim.log.levels.ERROR, vim.inspect(notified))

-- Exit code 12: a downloaded bundle is offered for re-download; a user's own bundle is not.
notified = {}
local reinstalled, offered = 0, nil
local orig_choose12 = require('intellij-lsp.activation').choose
require('intellij-lsp.activation').choose = function(opts, on_choice) offered = opts.items; on_choice(opts.items[1], 1) end
consent.bundle_corrupted(cbundle .. '/bin/intellij-server', function() reinstalled = reinstalled + 1 end)
check("exit 12, user's bundle: error, no re-download", reinstalled == 0 and offered == nil and notified[1] and notified[1].msg:find('exit code 12'), vim.inspect(notified))
local cached = require('intellij-lsp.server_download').cache_root() .. '/263.0/bin/intellij-server'
consent.bundle_corrupted(cached, function() reinstalled = reinstalled + 1 end)
check('exit 12, downloaded bundle: re-download offered and run', offered and reinstalled == 1, vim.inspect(offered))
require('intellij-lsp.activation').choose = orig_choose12

-- The real EULA float: scrollable, read-only, `a` accepts, closing declines.
consent._open_eula = real_open_eula
local accepted
local ewin = consent._open_eula('first line\nsecond line', function(a) accepted = a end, { index = 2, total = 3 })
local ebuf = vim.api.nvim_win_get_buf(ewin)
check('EULA opens in a focused float', vim.api.nvim_win_get_config(ewin).relative == 'editor' and vim.api.nvim_get_current_win() == ewin)
check('EULA text shown read-only', vim.api.nvim_buf_get_lines(ebuf, 0, -1, false)[2] == 'second line' and not vim.bo[ebuf].modifiable)
check('EULA title names the product and the step',
  vim.api.nvim_win_get_config(ewin).title[1][1] == ' Java and Kotlin by IntelliJ IDEA · Setup 2/3: license agreement ',
  vim.inspect(vim.api.nvim_win_get_config(ewin).title))
vim.api.nvim_feedkeys('a', 'x', false)
vim.wait(500, function() return accepted ~= nil end, 10)
check('`a` accepts and closes', accepted == true and not vim.api.nvim_win_is_valid(ewin))
accepted = nil
ewin = consent._open_eula('text', function(a) accepted = a end, { index = 1, total = 2 })
local elines = vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(ewin), 0, -1, false)
check('EULA as the first screen opens with the welcome', elines[1] == ' Welcome to Java and Kotlin by IntelliJ IDEA!'
  and elines[2]:find('answer 2 questions', 1, true) and elines[#elines] == 'text', vim.inspect(elines))
vim.api.nvim_win_close(ewin, true)
vim.wait(500, function() return accepted ~= nil end, 10)
check('closing the EULA declines', accepted == false)

-- The real question screens: centred, named, numbered; a digit answers, `q` cancels.
consent._choose = real_choose
local chosen = 'unset'
consent._choose('region', 1, 3, function(v) chosen = v end)
local cwin = vim.api.nvim_get_current_win()
local ccfg_win = vim.api.nvim_win_get_config(cwin)
local clines = vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(cwin), 0, -1, false)
check('question: a focused float titled with the product and step', ccfg_win.relative == 'editor'
  and ccfg_win.title[1][1] == ' Java and Kotlin by IntelliJ IDEA · Setup 1/3 ', vim.inspect(ccfg_win.title))
check('question: centred, not in a corner', ccfg_win.col > 0 and ccfg_win.row > 0
  and math.abs((vim.o.columns - ccfg_win.width) / 2 - ccfg_win.col) <= 1, vim.inspect({ ccfg_win.row, ccfg_win.col, ccfg_win.width }))
check('question 1 opens with the welcome, then the question and Europe first',
  clines[1] == ' Welcome to Java and Kotlin by IntelliJ IDEA!' and clines[2]:find('answer 3 questions', 1, true)
  and vim.tbl_contains(clines, ' 1  Europe'), vim.inspect(clines))
vim.api.nvim_feedkeys('3', 'x', false)
vim.wait(500, function() return chosen ~= 'unset' end, 10)
check('question: a digit answers and closes', chosen == 'americas' and not vim.api.nvim_win_is_valid(cwin), tostring(chosen))
chosen = 'unset'
consent._choose('data_sharing', 3, 3, function(v) chosen = v end)
cwin = vim.api.nvim_get_current_win()
clines = vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(cwin), 0, -1, false)
check('a later question has no welcome, names the data notice', clines[1]:find('Help JetBrains', 1, true)
  and table.concat(clines, ' '):find(consent.DATA_SHARING_URL, 1, true), vim.inspect(clines))
vim.api.nvim_feedkeys('q', 'x', false)
vim.wait(500, function() return chosen ~= 'unset' end, 10)
check('question: `q` cancels', chosen == nil and not vim.api.nvim_win_is_valid(cwin), tostring(chosen))
-- A license float already open does not swallow the question: it closes (choosing nothing) and the
-- question opens, so the launches waiting on it are answered.
local activation_mod = require('intellij-lsp.activation')
local license_choice = 'unset'
local lwin = activation_mod.menu({ title = 'license', footer = 'q', lines = { ' 1  x' }, first = 1,
  actions = { { key = '1', name = 'x', label = 'x' } } }, function(name) license_choice = name end)
chosen = 'unset'
consent._choose('region', 1, 1, function(v) chosen = v end)
cwin = vim.api.nvim_get_current_win()
check('question: replaces an open license float', not vim.api.nvim_win_is_valid(lwin) and cwin ~= lwin
  and vim.api.nvim_win_get_config(cwin).title[1][1]:find('Setup 1/1', 1, true) ~= nil)
vim.wait(500, function() return license_choice ~= 'unset' end, 10)
check('question: the replaced float chose nothing', license_choice == nil, tostring(license_choice))
vim.api.nvim_feedkeys('1', 'x', false)
vim.wait(500, function() return chosen ~= 'unset' end, 10)
check('question: and is answered', chosen == 'europe', tostring(chosen))
local plain = activation_mod.menu({ title = 'a', footer = 'q', lines = { ' 1  x' }, first = 1,
  actions = { { key = '1', name = 'x', label = 'x' } } }, function() end)
check('menu: without replace, a second call focuses the open float', activation_mod.menu({ title = 'b', footer = 'q',
  lines = { ' 1  y' }, first = 1, actions = { { key = '1', name = 'y', label = 'y' } } }, function() end) == plain)
vim.api.nvim_win_close(plain, true)

vim.notify, vim.ui.select = real_notify, real_ui_select
select_mod.select, consent._has_ui = real_select, real_has_ui
consent.store_path = real_store_path
consent._reset()
vim.fn.delete(cbundle, 'rf'); vim.fn.delete(lic_dir, 'rf'); vim.fn.delete(vim.fs.dirname(store_file), 'rf')
end

-- the load-bearing capability
local caps = client.capabilities()
check('window.workDoneProgress = true', caps.window.workDoneProgress == true)

-- init_options shape
local io_ = client.init_options('/tmp/ijtest', { build_tool = nil, projects = {} })
local uri = vim.uri_from_fname('/tmp/ijtest')
check('buildTools keyed by folder uri', next(io_.buildTools) == uri, vim.inspect(io_.buildTools))
check('nil build_tool -> vim.NIL (serializes as null)', io_.buildTools[uri] == vim.NIL, vim.inspect(io_.buildTools))
check('buildTools encodes as object with null', vim.json.encode(io_.buildTools):find('null', 1, true) ~= nil, vim.json.encode(io_.buildTools))
check('projects defaults to {}', type(io_.projects) == 'table')
-- Opted in, because extensions.lua answers both notifications it promises. Without the flag the
-- server maps ModCopyToClipboard/ModChooseAction to null and drops the whole enclosing quick fix.
check('intellijExtensions opted in', io_.intellijExtensions == true)
check('intellijExtensions can be declined', client.init_options('/tmp/ijtest', { intellij_extensions = false }).intellijExtensions == false)
-- Asked for only when the client can actually honour the lens: its command is dispatched client-side
-- into a DAP session, so without nvim-dap installed a lens would render and then fail on click, which
-- is worse than no lens. This suite runs under `-u NONE`, so nvim-dap is absent and the flag is false
-- -- which is exactly the degraded path worth pinning. `run = false` must decline it too, regardless.
check('runMainCodeLens declined without nvim-dap', io_.runMainCodeLens == false, tostring(io_.runMainCodeLens))
check('runMainCodeLens declined by run = false',
  client.init_options('/tmp/ijtest', { run = false }).runMainCodeLens == false)
local io2 = client.init_options('/tmp/ijtest', { build_tool = 'maven' })
check('build_tool forwarded', io2.buildTools[uri] == 'maven')

-- root detection
vim.fn.mkdir('/tmp/ijtest/src/main/java/com/example', 'p')
io.open('/tmp/ijtest/pom.xml', 'w'):close()
local root = vim.fs.dirname(vim.fs.find({ 'pom.xml' }, { path = '/tmp/ijtest/src/main/java/com/example', upward = true })[1] or '')
check('root markers find pom.xml', root == '/tmp/ijtest', root)

-- ---------------------------------------------------------------------------
-- Eager activation from build files
-- ---------------------------------------------------------------------------
-- A build file at or above cwd starts the server on a project opened with no source file open.
-- Real directories throughout, because the one-level rule is a filesystem property.

--- Builds a temp tree; keys are relative paths, all created as files.
local function fixture(tree)
  local dir = vim.fn.tempname() .. '-eager'
  vim.fn.mkdir(dir, 'p')
  for _, path in ipairs(tree) do
    vim.fn.mkdir(dir .. '/' .. vim.fs.dirname(path), 'p')
    vim.fn.writefile({ 'x' }, dir .. '/' .. path)
  end
  -- fs_realpath: on macOS /tmp is a symlink to /private/tmp, and find_build_root normalizes without
  -- resolving, so the expected value has to be the resolved one too. Same trap as the e2e suites.
  return vim.fs.normalize(vim.uv.fs_realpath(dir))
end

-- `.git` is in ROOT_MARKERS but must NOT be an activation trigger: any checkout of any language would
-- otherwise start a multi-minute IntelliJ import with nothing to index.
check('.git is not a build-file marker',
  not vim.tbl_contains(client.BUILD_FILE_MARKERS, '.git'), vim.inspect(client.BUILD_FILE_MARKERS))
check('.git is still a per-buffer root marker', vim.tbl_contains(client.ROOT_MARKERS, '.git'))

-- Exactly these seven. `BUILD`/`WORKSPACE`/`.bazelproject` are excluded on purpose.
check('seven build markers', #client.BUILD_FILE_MARKERS == 7,
  vim.inspect(client.BUILD_FILE_MARKERS))
for _, m in ipairs({ 'pom.xml', 'build.gradle', 'build.gradle.kts', 'settings.gradle',
                     'settings.gradle.kts', 'BUILD.bazel', 'MODULE.bazel' }) do
  check('build marker ' .. m, vim.tbl_contains(client.BUILD_FILE_MARKERS, m))
end
check('BUILD is not an activation marker', not vim.tbl_contains(client.BUILD_FILE_MARKERS, 'BUILD'))
check('WORKSPACE is not an activation marker',
  not vim.tbl_contains(client.BUILD_FILE_MARKERS, 'WORKSPACE'))

local in_cwd = fixture({ 'pom.xml' })
check('marker in cwd starts on cwd', client.find_build_root(in_cwd) == in_cwd,
  tostring(client.find_build_root(in_cwd)))

-- Below cwd must NOT match, at any depth. An earlier version matched `*/<name>` one level down, so
-- `nvim` in `~/Code`, a parent of many checkouts, imported all of them as one project rooted at
-- `~/Code`. Upward-only is the fix; this guards against it coming back.
local one_deep = fixture({ 'app/pom.xml' })
check('marker one level down does not activate', client.find_build_root(one_deep) == nil,
  tostring(client.find_build_root(one_deep)))
local two_deep = fixture({ 'a/b/pom.xml' })
check('marker two levels down does not activate', client.find_build_root(two_deep) == nil,
  tostring(client.find_build_root(two_deep)))

-- Upward walk: nvim opened inside a source directory still roots on the project.
local up = fixture({ 'pom.xml', 'src/main/java/.keep' })
check('upward walk from a source dir finds the project',
  client.find_build_root(up .. '/src/main/java') == up,
  tostring(client.find_build_root(up .. '/src/main/java')))

-- In `mono/app` with a reactor pom above and a module pom below, the reactor is the right root; a
-- downward rule would have answered `mono/app` and imported a fragment of the build.
local mono = fixture({ 'pom.xml', 'app/sub/pom.xml' })
check('upward walk finds the reactor above a module directory',
  client.find_build_root(mono .. '/app') == mono, tostring(client.find_build_root(mono .. '/app')))

-- Gradle and Bazel reach the same paths, so cover one of each rather than only Maven.
local gradle = fixture({ 'settings.gradle.kts' })
check('gradle settings activate', client.find_build_root(gradle) == gradle)
local bazel = fixture({ 'MODULE.bazel' })
check('bazel module activates', client.find_build_root(bazel) == bazel)

local git_only = fixture({ '.git/HEAD' })
check('.git alone does not activate', client.find_build_root(git_only) == nil,
  tostring(client.find_build_root(git_only)))
-- ...but the per-buffer path still falls back to it, which is why the two lists are separate.
check('.git still resolves a per-buffer root',
  vim.fs.dirname(vim.fs.find(client.ROOT_MARKERS, { path = git_only, upward = true })[1] or '')
    == git_only)

-- An empty directory is the common case for `nvim` in a scratch dir; must be cheap and silent.
check('no marker anywhere does not activate', client.find_build_root(fixture({})) == nil)
check('an unrelated file does not activate',
  client.find_build_root(fixture({ 'README.md', 'sub/Cargo.toml' })) == nil)

-- ---------------------------------------------------------------------------
-- A module widens to the build that aggregates it
-- ---------------------------------------------------------------------------
-- Regression: rooted at its nearest pom.xml, a module of antonarhipov/school-kernel was imported on
-- its own, could not resolve its sibling SNAPSHOT module, and so had no classpath at all.
local function pom(dir, path, body)
  vim.fn.writefile({ '<project>', body, '</project>' }, dir .. '/' .. path)
end

local reactor = fixture({ 'pom.xml', 'kernel-cli/pom.xml', 'kernel-cli/src/main/java/A.java',
  'examples/demo/pom.xml', 'appstore/pom.xml' })
pom(reactor, 'pom.xml', '<modules><module>kernel-contract</module><module>kernel-cli</module>'
  .. '<module>app</module></modules>')
check('a listed maven module widens to its reactor',
  client.build_root(reactor .. '/kernel-cli') == reactor, client.build_root(reactor .. '/kernel-cli'))
check('find_build_root widens from inside a module',
  client.find_build_root(reactor .. '/kernel-cli/src/main/java') == reactor)
local reactor_buf = vim.fn.bufadd(reactor .. '/kernel-cli/src/main/java/A.java')
check('find_root widens a module file to its reactor', client.find_root(reactor_buf) == reactor,
  tostring(client.find_root(reactor_buf)))
check('a pom nothing lists stays its own project',
  client.build_root(reactor .. '/examples/demo') == reactor .. '/examples/demo')
check('a module name is not a prefix match',
  client.build_root(reactor .. '/appstore') == reactor .. '/appstore')
check('the reactor itself stays put', client.build_root(reactor) == reactor)

local chain = fixture({ 'pom.xml', 'a/pom.xml', 'a/b/pom.xml' })
pom(chain, 'pom.xml', '<modules><module>a</module></modules>')
pom(chain, 'a/pom.xml', '<modules><module>b</module></modules>')
check('nested aggregators widen to the outermost', client.build_root(chain .. '/a/b') == chain)

local deep = fixture({ 'pom.xml', 'services/api/pom.xml' })
pom(deep, 'pom.xml', '<modules>\n  <module>./services/api/</module>\n</modules>')
check('a module path through a pom-less directory widens',
  client.build_root(deep .. '/services/api') == deep)

local by_file = fixture({ 'pom.xml', 'app/pom.xml' })
pom(by_file, 'pom.xml', '<modules><module>app/pom.xml</module></modules>')
check('a module named by its pom file widens', client.build_root(by_file .. '/app') == by_file)

local maven4 = fixture({ 'pom.xml', 'app/pom.xml' })
pom(maven4, 'pom.xml', '<subprojects><subproject>app</subproject></subprojects>')
check('a maven 4 subproject widens', client.build_root(maven4 .. '/app') == maven4)

local commented = fixture({ 'pom.xml', 'app/pom.xml' })
pom(commented, 'pom.xml', '<modules><!-- <module>app</module> --></modules>')
check('a commented-out module does not widen',
  client.build_root(commented .. '/app') == commented .. '/app')

local gradle_multi = fixture({ 'settings.gradle.kts', 'build.gradle.kts', 'app/build.gradle.kts' })
check('a gradle subproject widens to its settings file',
  client.build_root(gradle_multi .. '/app') == gradle_multi)
local gradle_single = fixture({ 'build.gradle' })
check('a gradle build with no settings stays put',
  client.build_root(gradle_single) == gradle_single)
local gradle_included = fixture({ 'settings.gradle', 'tools/settings.gradle', 'tools/build.gradle' })
check('the nearest gradle settings wins',
  client.build_root(gradle_included .. '/tools') == gradle_included .. '/tools')

-- ---------------------------------------------------------------------------
-- Shared directories decline the eager start
-- ---------------------------------------------------------------------------
-- A stray build file dropped directly into a shared directory would make that directory the root and
-- import everything under it as one project. start_eagerly declines these by name, resolved through
-- fs_realpath because /tmp is a symlink to /private/tmp on macOS and comparing unresolved paths lets
-- `cd /tmp` slip past.
local eager_skips = require('intellij-lsp')._is_shared_dir

check('/ is skipped', eager_skips('/'))
check('$HOME is skipped', eager_skips(vim.uv.os_homedir()))
check('the system temp dir is skipped', eager_skips(vim.uv.os_tmpdir()))
check('a real project directory is not skipped', not eager_skips(in_cwd), in_cwd)

-- The symlink case, fed the way the guard really sees it. `vim.uv.cwd()` reports the *resolved* path,
-- so after `cd /tmp` on macOS the guard is handed /private/tmp -- which the unresolved skip list does
-- not contain. Passing the literal '/tmp' here would pass without any realpath handling at all and
-- prove nothing, so resolve both shared dirs and check the resolved form is recognised.
for _, shared in ipairs({ '/tmp', vim.uv.os_tmpdir() }) do
  local resolved = vim.uv.fs_realpath(shared)
  if resolved then
    check('a resolved shared dir is skipped: ' .. resolved, eager_skips(resolved), resolved)
  end
end

-- ---------------------------------------------------------------------------
-- An eagerly started client is reused by a later buffer
-- ---------------------------------------------------------------------------
-- Regression: Neovim's own reuse check compares workspace folder URIs for string equality
-- (`reuse_client_default`), so a client eagerly started at cwd is NOT reused by a buffer whose
-- find_root walked up only as far as cwd/app -- vim.lsp.start would start a second server and import
-- and index the same project twice.
check('contains matches the dir itself', client._contains('/work/app', '/work/app'))
check('contains matches a descendant', client._contains('/work', '/work/app/src/Foo.java'))
-- A plain startswith would call /work/app an ancestor of /work/appstore.
check('contains rejects a sibling with a shared prefix',
  not client._contains('/work/app', '/work/appstore/Foo.java'))
check('contains rejects an unrelated path', not client._contains('/work', '/other/Foo.java'))
check('contains tolerates a trailing slash', client._contains('/work/', '/work/Foo.java'))

local eager_root = fixture({ 'pom.xml', 'app/pom.xml', 'app/src/main/java/com/example/Main.java' })
local MODULE_FILE = eager_root .. '/app/src/main/java/com/example/Main.java'

--- Answers just enough of the protocol to reach `initialized`.
local function stub_server(dispatch)
  return {
    request = function(method, _, callback)
      if method == 'initialize' then
        -- Deferred like a real server's reply, so the client is observably uninitialized first.
        vim.schedule(function() callback(nil, { capabilities = {} }) end)
      elseif method == 'shutdown' then
        callback(nil, nil)
      end
      return true, 1
    end,
    notify = function(method)
      if method == 'exit' then dispatch.on_exit(0, 0) end
      return true
    end,
    is_closing = function() return false end,
    terminate = function() end,
  }
end

-- The eager start: no buffer, so `attach = false`. Named after the real client so that
-- find_ancestor_client, which filters on client.NAME, sees it.
local eager_cfg = vim.tbl_extend('force', client.config(eager_root, {}), { cmd = stub_server })
local eager_id = vim.lsp.start(eager_cfg, { attach = false })
check('eager start needs no buffer', eager_id ~= nil, tostring(eager_id))
local eager_client = eager_id and vim.lsp.get_client_by_id(eager_id)
-- A file opened while the real server is still starting (seconds of JVM start) must find it too,
-- or it starts a second server on its module root.
check('the eager client starts uninitialized', eager_client and not eager_client.initialized)
local early = client.find_ancestor_client(MODULE_FILE)
check('an ancestor client is found before it has initialized',
  early ~= nil and early.id == eager_id, early and early.id)
vim.wait(2000, function() return eager_client and eager_client.initialized end)

if not (eager_client and eager_client.initialized) then
  check('eager client starts', false, 'client did not initialize')
else
  -- `attach = false` really means no buffer was touched; attaching to the unnamed startup buffer would
  -- have Neovim send didOpen for a document that does not exist.
  check('attach=false attaches no buffer', next(eager_client.attached_buffers) == nil,
    vim.inspect(vim.tbl_keys(eager_client.attached_buffers)))

  -- The multi-module trap: the buffer's own upward walk stops at the nearer `app/pom.xml`.
  local module_buf = vim.fn.bufadd(MODULE_FILE)
  vim.fn.bufload(module_buf)
  local buf_root = client.find_root(module_buf)
  check('the buffer resolves a narrower root than the eager one',
    buf_root == eager_root .. '/app', tostring(buf_root))
  -- Which is exactly why Neovim would not reuse the eager client. The URI inequality *is* the
  -- mechanism, so assert on it rather than starting a second client to demonstrate it.
  check('the two roots produce different workspace folder URIs',
    vim.uri_from_fname(eager_root) ~= vim.uri_from_fname(buf_root))

  -- The fix: the ancestor lookup finds the eager client for that file anyway.
  local found = client.find_ancestor_client(MODULE_FILE)
  check('an ancestor client is found for a module file',
    found ~= nil and found.id == eager_client.id, found and found.id)
  check('a file outside the root finds nothing',
    client.find_ancestor_client('/definitely/elsewhere/Foo.java') == nil)
  check('an empty path finds nothing', client.find_ancestor_client('') == nil)

  vim.lsp.stop_client(eager_id, true)
end

-- ---------------------------------------------------------------------------
-- Completion menu options
-- ---------------------------------------------------------------------------
-- Regression: on `import java.ut` the server sends filterText="java.util" (the FQ name, because the
-- item's edit starts before the prefix) while Neovim derives the prefix `ut` with `\k*$`. Without
-- 'fuzzy' the default startswith matcher drops the item and the menu comes up empty.
local function completeopt_after(cfg, initial)
  vim.opt.completeopt = initial or { 'menu', 'popup' }
  client.setup_completeopt(cfg)
  return vim.opt.completeopt:get()
end

local opts = completeopt_after({})
check('completeopt gains fuzzy', vim.tbl_contains(opts, 'fuzzy'), table.concat(opts, ','))
check('completeopt gains menuone', vim.tbl_contains(opts, 'menuone'), table.concat(opts, ','))
check('completeopt keeps existing flags', vim.tbl_contains(opts, 'popup'), table.concat(opts, ','))
-- Without 'noinsert' the menu writes the current entry into the buffer while you type, turning
-- `java.` + `u` into `java.timeu`.
check('completeopt gains noinsert', vim.tbl_contains(opts, 'noinsert'), table.concat(opts, ','))

-- Escape hatches: false keeps the user's value, an explicit value replaces it.
local untouched = completeopt_after({ completeopt = false }, { 'menu', 'noselect' })
check('completeopt=false is left alone', vim.deep_equal(untouched, { 'menu', 'noselect' }), table.concat(untouched, ','))
local explicit = completeopt_after({ completeopt = { 'menu', 'noinsert' } })
check('explicit completeopt replaces', vim.deep_equal(explicit, { 'menu', 'noinsert' }), table.concat(explicit, ','))

-- The filtering behaviour the 'fuzzy' flag is there to buy, pinned against Neovim's own matcher.
local function kept(value, prefix, fuzzy)
  if prefix == '' then return true end
  if fuzzy then return #(vim.fn.matchfuzzypos({ value }, prefix)[3] or {}) > 0 end
  return vim.startswith(value:lower(), prefix:lower())
end
check('prefix is "ut", not "java.ut"', vim.fn.match('import java.ut', '\\k*$') == 12)
check('startswith drops java.util', not kept('java.util', 'ut', false))
check('fuzzy keeps java.util', kept('java.util', 'ut', true))

-- ---------------------------------------------------------------------------
-- <CR> accepts the selected completion
-- ---------------------------------------------------------------------------
-- Regression: Vim reserves <C-y> for accepting and treats Enter as an ordinary character, so <CR>
-- ends completion and inserts a newline. This is NOT a 'noselect' problem -- the default
-- 'completeopt' is "menu,popup", which has no 'noselect' in it, and Neovim still preselects nothing.
-- Only a mapping fixes it, so this drives a real popup rather than asserting on options.
--
-- One feedkeys batch per case: flushing between keys closes the popup.
_G._units_omni = function(findstart, _)
  if findstart == 1 then
    -- Start of the dotted expression, mirroring the range the server's textEdit replaces.
    return vim.fn.match(vim.fn.getline('.'):sub(1, vim.fn.col('.') - 1), '[[:alnum:].]*$')
  end
  return { 'java.util', 'javax.annotation' }
end

local pum = {}
_G._units_probe = function()
  pum.visible = vim.fn.pumvisible()
  return ''
end

local function type_into_buffer(keys)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_current_buf(buf)
  vim.bo[buf].omnifunc = 'v:lua._units_omni'
  client.setup_enter_mapping(buf)
  vim.api.nvim_feedkeys(vim.keycode(keys), 'tx', false)
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  vim.api.nvim_buf_delete(buf, { force = true })
  return lines
end

local accepted = type_into_buffer('iimport java.ut<C-x><C-o><C-r>=v:lua._units_probe()<CR><CR><Esc>')
check('dotted prefix opens the menu', pum.visible == 1, pum.visible)
check('<CR> accepts instead of inserting a newline', #accepted == 1, vim.inspect(accepted))
check('<CR> inserts the completion text', accepted[1] == 'import java.util', vim.inspect(accepted[1]))

local newline = type_into_buffer('ifoo<CR>bar<Esc>')
check('<CR> still opens a line with no menu', vim.deep_equal(newline, { 'foo', 'bar' }), vim.inspect(newline))

-- ---------------------------------------------------------------------------
-- Completion keeps up while a word is typed
-- ---------------------------------------------------------------------------
-- Regression: the server advertises '.' as its only trigger character, and Neovim's `autotrigger`
-- requests completion ONLY on trigger characters. So `java.` opened a menu, the next keystroke
-- closed it, and nothing reopened it -- and a bare identifier never completed at all. This runs
-- against a real in-process LSP server, because the bug is in when requests are sent.
local requests, cancels = {}, 0
-- How long the faux server takes to answer a completion request; 0 answers inline.
local faux_latency = 0

--- Minimal server: one trigger character, FQ filterText, edits anchored at the start of the
--- dotted expression -- the shape `LSJavaCompletionProvider` produces. Distinct request ids and the
--- reply notification matter: that is what `client.requests` tracks, and the word trigger reads it.
local function faux_server(dispatch)
  local next_id = 0
  return {
    request = function(method, _, callback, notify_reply)
      next_id = next_id + 1
      local id = next_id
      local function reply(result)
        if notify_reply then notify_reply(id) end
        callback(nil, result, id)
      end
      if method == 'initialize' then
        reply({ capabilities = { completionProvider = { triggerCharacters = { '.' } } } })
      elseif method == 'textDocument/completion' then
        local line = vim.api.nvim_get_current_line()
        requests[#requests + 1] = line
        local from = vim.fn.match(line, '[[:alnum:].]*$')
        local range = { start = { line = 0, character = from }, ['end'] = { line = 0, character = #line } }
        local result = {
          isIncomplete = true,
          items = {
            { label = 'util', filterText = 'java.util', textEdit = { range = range, newText = 'java.util' } },
            { label = 'time', filterText = 'java.time', textEdit = { range = range, newText = 'java.time' } },
          },
        }
        if faux_latency > 0 then
          vim.defer_fn(function() reply(result) end, faux_latency)
        else
          reply(result)
        end
      elseif method == 'shutdown' then
        reply(nil)
      end
      return true, id
    end,
    notify = function(method)
      if method == '$/cancelRequest' then cancels = cancels + 1 end
      if method == 'exit' then dispatch.on_exit(0, 0) end
      return true
    end,
    is_closing = function() return false end,
    terminate = function() end,
  }
end

local lsp_buf = vim.api.nvim_create_buf(false, true)
vim.api.nvim_set_current_buf(lsp_buf)
vim.bo[lsp_buf].filetype = 'java'
local client_id = vim.lsp.start({ name = 'faux-intellij', cmd = faux_server, root_dir = '/tmp' }, { bufnr = lsp_buf })
local lsp_client = client_id and vim.lsp.get_client_by_id(client_id)
vim.wait(2000, function() return lsp_client and lsp_client.initialized end)

if not (lsp_client and lsp_client.initialized) then
  check('faux LSP client starts', false, 'client did not initialize')
else
  client.setup_completeopt({})
  vim.lsp.completion.enable(true, client_id, lsp_buf, { autotrigger = true })

  -- Baseline: the server's own trigger set means letters send nothing.
  requests = {}
  vim.api.nvim_feedkeys(vim.keycode('ifoo<Esc>'), 'tx', false)
  vim.wait(200)
  check('letters alone send no request', #requests == 0, vim.inspect(requests))

  client.setup_word_triggers(lsp_client, lsp_buf, { completion_delay = 20 })
  -- The built-in never re-reads this set for a client it already knows, and a later buffer would
  -- turn every letter into a second, undebounced request path. So it is left as the server sent it.
  local triggers = lsp_client.server_capabilities.completionProvider.triggerCharacters
  check("server's trigger set is left alone", vim.deep_equal(triggers, { '.' }), vim.inspect(triggers))

  -- `<C-r>=` pumps the debounce timer without leaving insert mode; `feedkeys` with 'x' would drop
  -- to normal mode first, and the callback deliberately bails outside insert.
  local pum_after_word
  _G._units_pump = function()
    vim.wait(250)
    pum_after_word = vim.fn.pumvisible()
    return ''
  end

  requests = {}
  vim.api.nvim_feedkeys(vim.keycode(
    'ccimport java.<C-r>=v:lua._units_pump()<CR>u<C-r>=v:lua._units_pump()<CR>' ..
    't<C-r>=v:lua._units_pump()<CR><CR><Esc>'), 'tx', false)

  check('typing after the dot keeps requesting', #requests >= 3, vim.inspect(requests))
  check('menu is still open after "ut"', pum_after_word == 1, pum_after_word)
  local final = vim.api.nvim_buf_get_lines(lsp_buf, 0, -1, false)
  check('the dotted candidate can be accepted', final[1] == 'import java.util', vim.inspect(final))

  -- Bare identifier, no dot anywhere: the in-scope-variable case.
  requests = {}
  vim.api.nvim_feedkeys(vim.keycode('ccbar<C-r>=v:lua._units_pump()<CR><Esc>'), 'tx', false)
  check('a bare identifier requests completion', #requests > 0, vim.inspect(requests))

  -- Regression: a server slower than the typing. `vim.lsp.completion.get` cancels whatever is in
  -- flight, so a debounce firing between keystrokes restarted the request on every letter and the
  -- menu could not appear until typing stopped. The in-flight request has to be left alone, and
  -- one fresh request has to follow once its reply is in.
  faux_latency = 150
  requests, cancels = {}, 0
  local pum_on_stale_reply
  _G._units_pump_short = function()
    vim.wait(40) -- past the 20 ms debounce, well inside the 150 ms reply
    return ''
  end
  _G._units_pump_long = function()
    -- The `.` reply lands first, with the whole word already typed.
    vim.wait(400, function() return vim.fn.pumvisible() ~= 0 end, 10)
    pum_on_stale_reply = vim.fn.pumvisible()
    -- Then let the catch-up request be answered before <Esc>, whose InsertLeave cancels whatever is
    -- still pending and would count as a cancel here.
    vim.wait(400, function() return #requests >= 2 end, 10)
    vim.wait(faux_latency + 100)
    return ''
  end
  vim.api.nvim_feedkeys(vim.keycode(
    'ccimport java.<C-r>=v:lua._units_pump_short()<CR>u<C-r>=v:lua._units_pump_short()<CR>' ..
    't<C-r>=v:lua._units_pump_short()<CR>i<C-r>=v:lua._units_pump_long()<CR><Esc>'), 'tx', false)
  check('a slow in-flight request is not cancelled by further typing', cancels == 0, cancels)
  -- One for the `.`, left to land while `uti` is typed; then exactly one catch-up for `uti`.
  check('one catch-up request after the stale reply, not one per letter',
    #requests == 2 and requests[2] == 'import java.uti', vim.inspect(requests))
  check('menu opens from the stale reply, before the catch-up answers', pum_on_stale_reply == 1, pum_on_stale_reply)
  faux_latency = 0

  vim.lsp.stop_client(client_id, true)
end

-- ---------------------------------------------------------------------------
-- gq / range formatting
-- ---------------------------------------------------------------------------
-- `gq` once did nothing: early bundles registered a `textDocument/rangeFormatting` handler without
-- advertising `documentRangeFormattingProvider`, and Neovim gates 'formatexpr' on exactly that
-- flag, so the plugin patched the capability in on_init. Bundle 263.4702.0 advertises it (the Java
-- e2e test checks), so the patch is gone and this pins the plain path: the advertised capability
-- alone installs formatexpr, and an absent one is left absent.
local fmt_buf = vim.api.nvim_create_buf(false, true)
vim.api.nvim_set_current_buf(fmt_buf)
vim.bo[fmt_buf].filetype = 'java'

local function formatting_server(dispatch)
  return {
    request = function(method, _, callback)
      if method == 'initialize' then
        callback(nil, { capabilities = { documentFormattingProvider = true, documentRangeFormattingProvider = true } })
      elseif method == 'shutdown' then
        callback(nil, nil)
      end
      return true, 1
    end,
    notify = function(method)
      if method == 'exit' then dispatch.on_exit(0, 0) end
      return true
    end,
    is_closing = function() return false end,
    terminate = function() end,
  }
end

local fmt_cfg = client.config('/tmp/ijtest', {})
local fmt_id = vim.lsp.start(
  vim.tbl_extend('force', fmt_cfg, { name = 'faux-intellij-fmt', cmd = formatting_server, root_dir = '/tmp' }),
  { bufnr = fmt_buf }
)
local fmt_client = fmt_id and vim.lsp.get_client_by_id(fmt_id)
vim.wait(2000, function() return fmt_client and fmt_client.initialized end)

if not (fmt_client and fmt_client.initialized) then
  check('formatting client starts', false, 'client did not initialize')
else
  check('rangeFormatting is supported as advertised', fmt_client:supports_method('textDocument/rangeFormatting'))
  -- The payoff: _set_defaults reads that capability on attach and installs formatexpr, which is
  -- what makes `gq` reformat a selection.
  check('formatexpr is installed', vim.bo[fmt_buf].formatexpr == 'v:lua.vim.lsp.formatexpr()', vim.bo[fmt_buf].formatexpr)
  vim.lsp.stop_client(fmt_id, true)
end

-- No patching any more: a server without the capability keeps it absent. `stub_server` above
-- advertises nothing, and `eager_client` came from it.
if eager_client and eager_client.initialized then
  check('an unadvertised rangeFormatting is not patched in',
    eager_client.server_capabilities.documentRangeFormattingProvider == nil)
end

-- ---------------------------------------------------------------------------
-- Inlay hint settings
-- ---------------------------------------------------------------------------
-- Regression: hints rendered nothing because the server asks for its own configuration section over
-- `workspace/configuration` before emitting any, and Neovim answers from `client.settings`, which
-- was empty. Java gates all four of its providers on that answer (so: no hints at all), Kotlin gates
-- only two (so: partial hints), which is why this presented as flakiness rather than as "off".
local settings = client.settings({})

-- The shape is pinned against Neovim's own resolution, not just eyeballed: `lookup_section` splits
-- the requested section on '.' and walks the table, then the server re-joins everything below it.
-- Hoisting the ids up to ['jetbrains.java.hints...'] would resolve to nil here.
local function section(tbl, name)
  return vim.tbl_get(tbl, unpack(vim.split(name, '.', { plain = true })))
end

local java = section(settings, 'jetbrains.java')
local kotlin = section(settings, 'jetbrains.kotlin')
check('jetbrains.java resolves the way lookup_section resolves it', type(java) == 'table', vim.inspect(java))
check('jetbrains.kotlin resolves', type(kotlin) == 'table', vim.inspect(kotlin))
check('java local variable hints on', java and java['hints.types.local variable'] == true)
check('java method parameter hints on', java and java['hints.settings.method parameter'] == true)
-- Gated separately on the Kotlin side; call chains are the one Kotlin hint off by default.
check('kotlin parameter hints on', kotlin and kotlin['hints.parameters'] == true)
check('kotlin call chains off', kotlin and kotlin['hints.call.chains'] == false)

-- Overrides merge rather than replace: switching one hint off must not drop the rest of the table.
local merged = client.settings({ inlay_hint_settings = { jetbrains = { java = { ['hints.types.call chain'] = false } } } })
local merged_java = section(merged, 'jetbrains.java')
check('override applies', merged_java['hints.types.call chain'] == false)
check('override keeps sibling keys', merged_java['hints.types.local variable'] == true, vim.inspect(merged_java))
check('override keeps the other language', section(merged, 'jetbrains.kotlin')['hints.parameters'] == true)
check('defaults are not mutated by an override', section(client.settings({}), 'jetbrains.java')['hints.types.call chain'] == true)

-- ---------------------------------------------------------------------------
-- Folding
-- ---------------------------------------------------------------------------
--- Returns the window options as `setup_folding` left them, starting from a window that looks the
--- way an unconfigured one does. 'foldlevel' starts at 0 because that is the value a window really
--- carries when `on_attach` runs: 'foldlevelstart' has already been consulted by then.
local function folding_after(cfg)
  local win = vim.api.nvim_get_current_win()
  vim.wo[win][0].foldmethod = 'manual'
  vim.wo[win][0].foldexpr = ''
  vim.wo[win][0].foldlevel = 0
  client.setup_folding(cfg)
  return {
    foldmethod = vim.wo[win][0].foldmethod,
    foldexpr = vim.wo[win][0].foldexpr,
    foldlevel = vim.wo[win][0].foldlevel,
  }
end

local folds = folding_after({})
check('foldmethod becomes expr', folds.foldmethod == 'expr', folds.foldmethod)
check('foldexpr uses vim.lsp.foldexpr', folds.foldexpr == 'v:lua.vim.lsp.foldexpr()', folds.foldexpr)
-- Without a start level every file would open fully collapsed, which reads as a broken plugin.
check('foldlevelstart is raised', vim.o.foldlevelstart >= 99, vim.o.foldlevelstart)
-- Regression: 'foldlevelstart' seeds 'foldlevel' only when a window starts editing a buffer, which
-- has already happened by the time on_attach runs. Setting the global alone left the *first* file of
-- a session fully collapsed while later ones opened fine, which presented as random folding.
check('foldlevel unfolds the attached window', folds.foldlevel >= 99, folds.foldlevel)
local off = folding_after({ folding = false })
check('folding=false is left alone', off.foldmethod == 'manual', off.foldmethod)
check('folding=false leaves foldlevel alone', off.foldlevel == 0, off.foldlevel)

-- ---------------------------------------------------------------------------
-- jar:/jrt: decompilation
-- ---------------------------------------------------------------------------
local decompiler = require('intellij-lsp.decompiler')
check('jar: is decompilable', decompiler._is_decompilable('jar:file:///a/lib.jar!/com/Foo.class'))
check('jrt: is decompilable', decompiler._is_decompilable('jrt:/java.base/java/lang/String.class'))
check('file: is not', not decompiler._is_decompilable('file:///a/Foo.java'))
-- The server only accepts these two schemes, so anything else must not reach it.
check('https: is not', not decompiler._is_decompilable('https://example.com/Foo.java'))

-- Regression: Neovim leaves `jrt:/...` alone but treats `jar:file://...` as a relative path and
-- prefixes it with the cwd. Sending that prefixed string back would fail the server's scheme check,
-- so it has to be stripped -- the same phantom-path trap references.lua hits from the quickfix side.
check('cwd-prefixed jar: is recovered',
  decompiler._uri_from_bufname('/some/where/jar:file:///a/lib.jar!/com/Foo.class')
    == 'jar:file:///a/lib.jar!/com/Foo.class')
check('bare jar: is left alone',
  decompiler._uri_from_bufname('jar:file:///a/lib.jar!/com/Foo.class') == 'jar:file:///a/lib.jar!/com/Foo.class')
check('jrt: is left alone',
  decompiler._uri_from_bufname('jrt:/java.base/java/lang/String.class') == 'jrt:/java.base/java/lang/String.class')

-- The autocmd patterns are their own trap: Vim only matches a pattern containing ':' once it also
-- contains '/', so the obvious `jar:*` / `jrt:*` spellings silently never fire. Drive real buffers.
decompiler.setup()
for _, case in ipairs({
  { uri = 'jrt:/java.base/java/lang/String.class', name = 'jrt:' },
  { uri = 'jar:file:///tmp/lib.jar!/com/example/Foo.class', name = 'jar:' },
}) do
  vim.cmd('silent! edit ' .. vim.fn.fnameescape(case.uri))
  local first = (vim.api.nvim_buf_get_lines(0, 0, -1, false)[1] or '')
  -- No server is attached in this suite, so the handler's own fallback text is the proof it ran.
  check(case.name .. ' BufReadCmd fires', first:find('IntelliJ LSP', 1, true) ~= nil, first)
  check(case.name .. ' buffer is a scratch', vim.bo.buftype == 'nofile' and not vim.bo.modifiable)
end

-- Regression: `vim.lsp.buf.definition` sets the cursor to the location's line the moment
-- `nvim_win_set_buf` returns, and `locations_to_items` reads lines straight after bufloading a
-- non-file URI. Both presuppose the BufReadCmd filled the buffer before returning. A `String`
-- definition lands at line 173 of src.zip's String.java; against the two-line "decompiling..."
-- placeholder that was "Invalid cursor line: out of range". The fake server answers on a timer, the
-- way a real reply arrives, so this fails if the read goes back to being asynchronous.
do
  local source = {}
  for i = 1, 200 do source[i] = ('line %d'):format(i) end
  local fake_decompile_client = {
    name = 'intellij',
    request = function(_, method, params, handler)
      check('decompile goes through executeCommand', method == 'workspace/executeCommand', method)
      check('decompile names its command', params.command == 'decompile', params.command)
      vim.defer_fn(function()
        handler(nil, { code = table.concat(source, '\n'), language = 'java' })
      end, 20)
      return true, 1
    end,
  }
  local real_get_clients = vim.lsp.get_clients
  vim.lsp.get_clients = function(filter)
    if filter and filter.name == 'intellij' then return { fake_decompile_client } end
    return real_get_clients(filter)
  end

  vim.cmd('silent! edit ' .. vim.fn.fnameescape('jrt:/java.base/java/lang/Deep.class'))
  check('decompiled source is in the buffer when :edit returns',
    vim.api.nvim_buf_line_count(0) == 200, vim.api.nvim_buf_line_count(0))
  check('decompiled buffer gets the server language as filetype', vim.bo.filetype == 'java', vim.bo.filetype)
  local ok_cursor = pcall(vim.api.nvim_win_set_cursor, 0, { 173, 0 })
  check('the definition handler can place the cursor deep in the source', ok_cursor)

  vim.lsp.get_clients = real_get_clients
end

-- Regression: setting the filetype on a decompiled buffer runs the plugin's FileType attach. Rooting
-- a URI-named buffer walks up to the relative directory ".", so with a build file in the cwd a second
-- server was started on "." and failed `initialize` ("Expected scheme-specific part at index 5:
-- file:"). A library buffer attaches to the client that decompiled it and never starts one.
do
  local started, attached = 0, nil
  local real_start, real_attach, real_by_id = vim.lsp.start, vim.lsp.buf_attach_client, vim.lsp.get_client_by_id
  vim.lsp.start = function() started = started + 1 end
  vim.lsp.buf_attach_client = function(_, id) attached = id end
  vim.lsp.get_client_by_id = function(id) return id == 4242 and { id = 4242 } or real_by_id(id) end
  local old_cwd = vim.fn.getcwd()
  local proj = vim.fn.tempname()
  vim.fn.mkdir(proj, 'p')
  vim.fn.writefile({ '<project/>' }, proj .. '/pom.xml')
  vim.cmd('cd ' .. vim.fn.fnameescape(proj))

  local start_for_buffer = require('intellij-lsp')._start_for_buffer
  local lib = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_buf_set_name(lib, 'jar:///jdk/lib/src.zip!/java.base/java/lang/String.java')
  vim.b[lib].intellij_lsp_library_client = 4242
  start_for_buffer(lib)
  check('a library buffer attaches to the client that served it', attached == 4242, attached)

  local orphan = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_buf_set_name(orphan, 'jrt:/java.base/java/lang/Orphan.class')
  start_for_buffer(orphan)
  check('a library buffer never starts a server of its own', started == 0, started)

  -- Diffview and fugitive name revision buffers with a URI and set filetype=java. Walked up as a
  -- path, the name ended at ".", where the cwd's pom.xml started a server on `file://.`.
  for _, name in ipairs({
    'diffview://' .. proj .. '/.git/abc1234/src/Main.java',
    'fugitive://' .. proj .. '/.git//abc1234/src/Main.java',
  }) do
    local virtual = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_buf_set_name(virtual, name)
    local scheme = name:match('^%a+')
    check(scheme .. ' buffer: find_root finds no root', client.find_root(virtual) == nil,
      tostring(client.find_root(virtual)))
    start_for_buffer(virtual)
    check(scheme .. ' buffer: no server starts', started == 0, started)
  end
  local scratch = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_buf_set_name(scratch, proj .. '/Scratch.java')
  vim.bo[scratch].buftype = 'nofile'
  start_for_buffer(scratch)
  check('a nofile buffer: no server starts', started == 0, started)
  check('a Windows drive path is not a URI', not client.is_uri_name([[C:\work\Main.java]]))

  -- A source buffer launches through the consent gate: synchronously once it is settled, and not at
  -- all when it cannot be asked, with the attach guard cleared so a later setup can attach it.
  local init = require('intellij-lsp')
  local consent = require('intellij-lsp.consent')
  local saved_cfg, saved_store, saved_ui = init.config, consent.store_path, consent._has_ui
  local store = vim.fn.tempname() .. '-gate.json'
  consent.store_path = function() return store end
  consent._reset()
  local launched
  vim.lsp.start = function(cfg) started = started + 1; launched = cfg end
  vim.fn.writefile({ 'class Main {}' }, proj .. '/Main.java')
  local src = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_buf_set_name(src, proj .. '/Main.java')

  init.config = { server_path = SERVER, region = 'europe', data_sharing = 'full' }
  start_for_buffer(src)
  check('settled consent: the buffer launches at once', started == 1 and launched.cmd_env.INTELLIJ_REGION == 'europe'
    and launched.cmd_env.INTELLIJ_DATA_SHARING == 'full', started)
  launch.release_system_path(launched.system_path)

  -- Headless with a bundle whose EULA nobody accepted: the one answer without a default.
  vim.b[src].intellij_lsp_attached = nil
  local eula_bundle = vim.fn.tempname() .. '-eula-bundle'
  vim.fn.mkdir(eula_bundle .. '/bin', 'p')
  vim.fn.writefile({ 'terms' }, eula_bundle .. '/EULA.txt')
  init.config = { server_path = eula_bundle .. '/bin/intellij-server',
    jvm_args = { '-Dintellij.server.license.dir=' .. eula_bundle .. '/license' } }
  consent._has_ui = function() return false end
  local real_notify = vim.notify
  vim.notify = function() end
  start_for_buffer(src)
  vim.wait(500, function() return vim.b[src].intellij_lsp_attached == nil end, 10)
  vim.notify = real_notify
  check('unanswerable consent: nothing launches', started == 1, started)
  check('unanswerable consent: the attach guard is cleared', vim.b[src].intellij_lsp_attached == nil)
  vim.fn.delete(eula_bundle, 'rf')

  init.config, consent.store_path, consent._has_ui = saved_cfg, saved_store, saved_ui
  consent._reset()

  vim.cmd('cd ' .. vim.fn.fnameescape(old_cwd))
  vim.lsp.start, vim.lsp.buf_attach_client, vim.lsp.get_client_by_id = real_start, real_attach, real_by_id
end

do -- scoped: Lua allows 200 locals per chunk
-- ---------------------------------------------------------------------------
-- intellij/ extension notifications
-- ---------------------------------------------------------------------------
local extensions = require('intellij-lsp.extensions')
local ext = extensions.handlers()
check('copyToClipboard handled', type(ext['intellij/copyToClipboard']) == 'function')
check('chooseAction handled', type(ext['intellij/chooseAction']) == 'function')
check('runEditorCommand handled', type(ext['intellij/runEditorCommand']) == 'function')
check('showConflicts handled', type(ext['intellij/showConflicts']) == 'function')

vim.fn.setreg('+', '')
ext['intellij/copyToClipboard'](nil, { content = 'copied text' }, { client_id = 1 })
check('clipboard receives the content', vim.fn.getreg('+') == 'copied text', vim.fn.getreg('+'))
-- A malformed payload must not raise inside an LSP handler.
local ok_copy = pcall(ext['intellij/copyToClipboard'], nil, {}, { client_id = 1 })
check('copyToClipboard tolerates a missing content', ok_copy)

-- A fake client that records what is executed, standing in for vim.lsp.get_client_by_id.
local executed = {}
local fake_ext_client = {
  id = 4711,
  offset_encoding = 'utf-16',
  config = { root_dir = '/tmp/ijtest' },
  exec_cmd = function(_, command, ctx) executed[#executed + 1] = { command = command, ctx = ctx } end,
}
local real_get_client = vim.lsp.get_client_by_id
vim.lsp.get_client_by_id = function(id)
  if id == 4711 then return fake_ext_client end
  return real_get_client(id)
end

-- Old shape (bundle 263.4702.0): entries carry an index, the pick goes back through the
-- chooseModCommandAction command with the session and that index, and a dismissal still answers,
-- because the server caches the session until it hears back.
local select_stub = vim.ui.select
local chosen
vim.ui.select = function(items, _, on_choice) chosen = items; on_choice(items[1]) end
local ok_choose = pcall(ext['intellij/chooseAction'], nil,
  { sessionId = 's1', entries = { { index = 7, name = 'First' }, { index = 9, name = 'Second' } } },
  { client_id = 4711 })
check('chooseAction presents the entries', ok_choose and chosen and #chosen == 2, vim.inspect(chosen))
-- The reply carries the entry's own `index`, not its position in the list -- 7, not 1.
check('entries carry the server-side index', chosen and chosen[1].index == 7, vim.inspect(chosen and chosen[1]))
check('old shape replies through chooseModCommandAction',
  executed[1] and executed[1].command.command == 'chooseModCommandAction'
  and executed[1].command.arguments[1] == 's1' and executed[1].command.arguments[2] == 7, vim.inspect(executed[1]))
executed = {}
vim.ui.select = function(items, _, on_choice) on_choice(nil) end
ext['intellij/chooseAction'](nil, { sessionId = 's2', entries = { { index = 1, name = 'Only' } } }, { client_id = 4711 })
check('old shape answers a dismissal with null',
  executed[1] and executed[1].command.arguments[1] == 's2' and executed[1].command.arguments[2] == vim.NIL, vim.inspect(executed[1]))

-- New shape (later server builds): entries carry a complete LSP Command, the pick is executed as
-- is, and a dismissal says nothing because there is no session to release.
executed = {}
local lazy = { title = 'Apply ModCommand', command = 'applyModCommand', arguments = { { kind = 'LazyAction', sessionId = 0, index = 0 } } }
local prompt_seen
vim.ui.select = function(items, opts, on_choice) prompt_seen = opts.prompt; on_choice(items[1]) end
ext['intellij/chooseAction'](nil, { title = "Replace 'catch' with 'throws'", entries = { { name = 'Add throws', command = lazy } } }, { client_id = 4711 })
check('new shape executes the entry command', executed[1] and executed[1].command == lazy, vim.inspect(executed[1]))
check('new shape uses the server title as the prompt', prompt_seen == "Replace 'catch' with 'throws'", prompt_seen)
executed = {}
vim.ui.select = function(items, _, on_choice) on_choice(nil) end
ext['intellij/chooseAction'](nil, { entries = { { name = 'Add throws', command = lazy } } }, { client_id = 4711 })
check('new shape sends nothing on dismissal', #executed == 0, vim.inspect(executed))
vim.ui.select = select_stub

-- runEditorCommand: rename only when the notification names the current buffer.
local renamed, sig_shown = 0, 0
local real_rename, real_sig = vim.lsp.buf.rename, vim.lsp.buf.signature_help
vim.lsp.buf.rename = function() renamed = renamed + 1 end
vim.lsp.buf.signature_help = function() sig_shown = sig_shown + 1 end
local cur_buf = vim.api.nvim_create_buf(true, false)
vim.api.nvim_buf_set_name(cur_buf, '/tmp/ijtest/src/main/java/com/example/Cur.java')
vim.api.nvim_set_current_buf(cur_buf)
local other_buf = vim.api.nvim_create_buf(true, false)
vim.api.nvim_buf_set_name(other_buf, '/tmp/ijtest/src/main/java/com/example/Other.java')

check('rename runs for the current buffer', extensions.run_editor_command('editor.action.rename', vim.uri_from_bufnr(cur_buf)) and renamed == 1)
check('rename is dropped for another buffer', not extensions.run_editor_command('editor.action.rename', vim.uri_from_bufnr(other_buf)) and renamed == 1)
check('rename runs with no uri', extensions.run_editor_command('editor.action.rename', nil) and renamed == 2)
check('unknown commands are ignored', not extensions.run_editor_command('editor.action.doSomethingNew', nil))
check('parameter hints map to signature help', extensions.run_editor_command('editor.action.triggerParameterHints', nil) and sig_shown == 1)
-- Through the handler: scheduled, so it runs after the showDocument that selected the target.
ext['intellij/runEditorCommand'](nil, { command = 'editor.action.rename', arguments = {}, uri = vim.uri_from_bufnr(cur_buf) }, { client_id = 4711 })
vim.wait(100, function() return renamed == 3 end)
check('the handler runs the command', renamed == 3, tostring(renamed))
local ok_bad = pcall(ext['intellij/runEditorCommand'], nil, { arguments = {} }, { client_id = 4711 })
check('runEditorCommand tolerates a missing command', ok_bad)

-- The same names on a completion item's command dispatch locally instead of going to the server.
local cmds_tbl = extensions.commands()
check('client commands cover the three editor actions',
  cmds_tbl['editor.action.rename'] and cmds_tbl['editor.action.triggerSuggest'] and cmds_tbl['editor.action.triggerParameterHints'])
cmds_tbl['editor.action.rename']({ command = 'editor.action.rename' }, { bufnr = cur_buf, client_id = 4711 })
check('a completion command renames in its own buffer', renamed == 4, tostring(renamed))
cmds_tbl['editor.action.rename']({ command = 'editor.action.rename' }, { bufnr = other_buf, client_id = 4711 })
check('a completion command for another buffer is dropped', renamed == 4, tostring(renamed))
vim.lsp.buf.rename, vim.lsp.buf.signature_help = real_rename, real_sig

-- showConflicts is a request: the reply is the decision, produced from inside the coroutine Neovim
-- runs server requests in, exactly like window/showMessageRequest.
local conflicts_params = {
  title = 'Rename conflicts',
  conflicts = {
    { messages = { 'Field x is already defined' }, location = { uri = vim.uri_from_bufnr(other_buf), range = { start = { line = 4, character = 0 }, ['end'] = { line = 4, character = 3 } } } },
    { messages = { 'Library element' } },
  },
  continueLabel = 'Continue anyway', cancelLabel = 'Cancel', revealLabel = 'Show', documentChangedLabel = 'Changed',
}
local function ask_conflicts(pick)
  local rows
  vim.ui.select = function(items, _, on_choice) rows = items; on_choice(pick(items)) end
  local answer
  local co = coroutine.wrap(function() answer = ext['intellij/showConflicts'](nil, conflicts_params, { client_id = 4711 }) end)
  co()
  vim.wait(500, function() return answer ~= nil end)
  vim.ui.select = select_stub
  return answer, rows
end
local ans, rows = ask_conflicts(function(items) return items[#items - 1] end)
check('showConflicts lists conflicts then the two decisions', rows and #rows == 4 and rows[3].kind == 'continue' and rows[4].kind == 'cancel', vim.inspect(rows and vim.tbl_map(function(r) return r.kind end, rows)))
check('conflict rows name the file and line', rows and rows[1].label:find('Other.java:5', 1, true) ~= nil, rows and rows[1].label)
check('a conflict without a location shows a dash', rows and rows[2].label:sub(1, 1) == '-', rows and rows[2].label)
check('picking continue answers continue', ans and ans.decision == 'continue', vim.inspect(ans))
ans = ask_conflicts(function(items) return items[#items] end)
check('picking cancel answers cancel', ans and ans.decision == 'cancel', vim.inspect(ans))
ans = ask_conflicts(function() return nil end)
check('dismissing answers cancel', ans and ans.decision == 'cancel', vim.inspect(ans))
-- Picking a conflict reveals it and asks again; the second round decides.
local shown, round = 0, 0
local real_show = vim.lsp.util.show_document
vim.lsp.util.show_document = function() shown = shown + 1 end
ans = ask_conflicts(function(items) round = round + 1; return round == 1 and items[1] or items[3] end)
vim.lsp.util.show_document = real_show
check('picking a conflict reveals it and asks again', shown == 1 and round == 2 and ans and ans.decision == 'continue', ('%d/%d %s'):format(shown, round, vim.inspect(ans)))
-- Outside a coroutine (a direct call) the synchronous picker still yields a decision.
vim.ui.select = function(items, _, on_choice) on_choice(items[#items - 1]) end
local direct = extensions.show_conflicts(conflicts_params)
vim.ui.select = select_stub
check('a direct call answers synchronously', direct.decision == 'continue', vim.inspect(direct))
-- Editing while the question is open cancels it.
do
  local answer
  vim.ui.select = function() end -- an async picker that never answers
  local co = coroutine.wrap(function() answer = ext['intellij/showConflicts'](nil, conflicts_params, { client_id = 4711 }) end)
  co()
  vim.api.nvim_exec_autocmds('TextChanged', { buffer = cur_buf })
  vim.wait(500, function() return answer ~= nil end)
  vim.ui.select = select_stub
  check('a buffer edit while conflicts are shown answers cancel', answer and answer.decision == 'cancel', vim.inspect(answer))
end
vim.lsp.get_client_by_id = real_get_client

-- The handlers and commands travel with the init option, in both directions.
local with_ext = client.config('/tmp/ijtest', {})
check('extensions on: showConflicts registered', with_ext.handlers['intellij/showConflicts'] ~= nil)
check('extensions on: runEditorCommand registered', with_ext.handlers['intellij/runEditorCommand'] ~= nil)
check('extensions on: editor commands registered', with_ext.commands['editor.action.rename'] ~= nil)
check('extensions on: lazyIntentions asked for', with_ext.init_options.lazyIntentions == true)
local without_ext = client.config('/tmp/ijtest', { intellij_extensions = false })
check('extensions off: no intellij/ handlers', without_ext.handlers['intellij/showConflicts'] == nil and without_ext.handlers['intellij/chooseAction'] == nil)
check('extensions off: no editor commands', next(without_ext.commands) == nil)
check('extensions off: lazyIntentions declined', without_ext.init_options.lazyIntentions == false)

-- ---------------------------------------------------------------------------
-- Snippet edits (SnippetTextEdit in workspace/applyEdit)
-- ---------------------------------------------------------------------------
-- The server drops every fix ending in a mandatory live template unless the client advertises
-- snippetEditSupport, and Neovim's apply_workspace_edit fails on an edit with `snippet` instead of
-- `newText`. Advertise, extract, expand.
local snippet_edit = require('intellij-lsp.snippet_edit')
check('snippetEditSupport advertised', client.capabilities().workspace.workspaceEdit.snippetEditSupport == true)

local snip_buf = vim.api.nvim_create_buf(true, false)
vim.api.nvim_buf_set_name(snip_buf, '/tmp/ijtest/src/main/java/com/example/Snip.java')
vim.api.nvim_buf_set_lines(snip_buf, 0, -1, false, { 'class Snip {', '    int x = OLD;', '}' })
local snip_uri = vim.uri_from_bufnr(snip_buf)
local wedit = {
  documentChanges = {
    { textDocument = { uri = snip_uri, version = vim.NIL }, edits = {
      { range = { start = { line = 0, character = 6 }, ['end'] = { line = 0, character = 10 } }, newText = 'Renamed' },
      { range = { start = { line = 1, character = 12 }, ['end'] = { line = 1, character = 15 } }, snippet = { kind = 'snippet', value = 'compute(${1:arg})$0' } },
    } },
  },
}
local extracted = snippet_edit.extract(wedit)
check('extract pulls the snippet edit out', #extracted == 1 and extracted[1].uri == snip_uri and extracted[1].edit.snippet.value:find('compute', 1, true), vim.inspect(extracted))
check('extract leaves the plain edit in place', #wedit.documentChanges[1].edits == 1 and wedit.documentChanges[1].edits[1].newText == 'Renamed')
check('extract tolerates a nil edit', #snippet_edit.extract(nil) == 0 and #snippet_edit.extract({ changes = {} }) == 0)

vim.api.nvim_set_current_buf(snip_buf)
snippet_edit.apply_all(extracted, 'utf-16')
vim.cmd('stopinsert')
local snip_line = vim.api.nvim_buf_get_lines(snip_buf, 1, 2, false)[1]
check('the snippet replaces its range and expands', snip_line == '    int x = compute(arg);', snip_line)
check('the cursor sits in the expanded snippet', vim.api.nvim_win_get_cursor(0)[1] == 2, vim.inspect(vim.api.nvim_win_get_cursor(0)))

-- The full handler, against a live faux client: plain edit applied by Neovim, snippet expanded here.
vim.api.nvim_buf_set_lines(snip_buf, 0, -1, false, { 'class Snip {', '    int x = OLD;', '}' })
local snip_id = vim.lsp.start(vim.tbl_extend('force', client.config('/tmp/ijtest', {}), { name = 'faux-intellij-snippet', cmd = stub_server, root_dir = '/tmp' }), { attach = false })
local snip_client = snip_id and vim.lsp.get_client_by_id(snip_id)
vim.wait(2000, function() return snip_client and snip_client.initialized end)
if snip_client and snip_client.initialized then
  local handler = with_ext.handlers['workspace/applyEdit']
  local reply = handler(nil, { edit = {
    documentChanges = {
      { textDocument = { uri = snip_uri, version = vim.NIL }, edits = {
        { range = { start = { line = 0, character = 6 }, ['end'] = { line = 0, character = 10 } }, newText = 'Renamed' },
        { range = { start = { line = 1, character = 12 }, ['end'] = { line = 1, character = 15 } }, snippet = { kind = 'snippet', value = 'compute(${1:arg})$0' } },
      } },
    },
  } }, { client_id = snip_id, method = 'workspace/applyEdit' })
  vim.cmd('stopinsert')
  local lines = vim.api.nvim_buf_get_lines(snip_buf, 0, -1, false)
  check('applyEdit handler applies the plain edit', lines[1] == 'class Renamed {', lines[1])
  check('applyEdit handler expands the snippet edit', lines[2] == '    int x = compute(arg);', lines[2])
  check('applyEdit handler still answers applied', reply and reply.applied == true, vim.inspect(reply))

  -- Stale: Neovim skips the document's plain edits as "newer than edits", and the snippet with them.
  pcall(vim.snippet.stop)
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes('<Esc>', true, false, true), 'nx', false)
  local function versioned(version)
    return { edit = { documentChanges = {
      { textDocument = { uri = snip_uri, version = version }, edits = {
        { range = { start = { line = 0, character = 6 }, ['end'] = { line = 0, character = 13 } }, newText = 'Again' },
        { range = { start = { line = 1, character = 12 }, ['end'] = { line = 1, character = 24 } }, snippet = { kind = 'snippet', value = 'other(${1:x})$0' } },
      } },
    } } }
  end
  vim.api.nvim_buf_set_lines(snip_buf, 0, -1, false, { 'class Renamed {', '    int x = compute(arg);', '}' })
  vim.lsp.util.buf_versions[snip_buf] = 10
  local real_print = print
  print = function() end
  handler(nil, versioned(2), { client_id = snip_id, method = 'workspace/applyEdit' })
  print = real_print
  vim.cmd('stopinsert')
  local stale_lines = vim.api.nvim_buf_get_lines(snip_buf, 0, -1, false)
  check('a stale snippet edit leaves the newer buffer untouched',
    stale_lines[1] == 'class Renamed {' and stale_lines[2] == '    int x = compute(arg);', vim.inspect(stale_lines))
  check('a stale snippet is not extracted', #snippet_edit.extract(versioned(2).edit) == 0)
  check('a current snippet is extracted', #snippet_edit.extract(versioned(10).edit) == 1)
  handler(nil, versioned(10), { client_id = snip_id, method = 'workspace/applyEdit' })
  vim.cmd('stopinsert')
  local current_lines = vim.api.nvim_buf_get_lines(snip_buf, 0, -1, false)
  check('a current snippet edit still expands',
    current_lines[1] == 'class Again {' and current_lines[2] == '    int x = other(x);', vim.inspect(current_lines))
  vim.lsp.util.buf_versions[snip_buf] = nil
  vim.lsp.stop_client(snip_id, true)
else
  check('snippet client starts', false)
end
-- `vim.snippet.expand` enters insert mode through typeahead; drain it so later feedkeys-driven
-- tests start from normal mode with an empty queue.
pcall(vim.snippet.stop)
vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes('<Esc>', true, false, true), 'nx', false)

-- ---------------------------------------------------------------------------
-- Workspace import state and status
-- ---------------------------------------------------------------------------
local progress_mod = require('intellij-lsp.progress')
local ph = progress_mod.handlers()
check('workspaceImportState handled', type(ph['intellij/workspaceImportState']) == 'function')
check('workspaceImportStatus handled', type(ph['intellij/workspaceImportStatus']) == 'function')

local notified = {}
local real_notify = vim.notify
vim.notify = function(msg, level) notified[#notified + 1] = { msg = msg, level = level } end
local finished = { phase = 'FINISHED', folders = { { folderUri = 'file:///tmp/ijtest', tool = 'maven', status = 'SUCCESS' } } }
ph['intellij/workspaceImportState'](nil, finished, { client_id = 77 })
check('a successful import is stored', progress_mod.import_state(77) == finished)
check('a successful import says nothing', #notified == 0, vim.inspect(notified))
local failed = { phase = 'FAILED', message = 'boom', folders = {
  { folderUri = 'file:///tmp/ijtest', tool = 'gradle', status = 'FAILED', message = 'Could not resolve com.example:missing' },
  { folderUri = 'file:///tmp/other', status = 'BLOCKED', message = 'noBuildSystemFound' },
} }
ph['intellij/workspaceImportState'](nil, failed, { client_id = 77 })
check('one line per folder that did not import', #notified == 2, vim.inspect(notified))
check('a failed folder names the tool and the importer message',
  notified[1] and notified[1].msg:find('gradle', 1, true) and notified[1].msg:find('missing', 1, true) and notified[1].level == vim.log.levels.ERROR, notified[1] and notified[1].msg)
check('a blocked folder translates the reason id',
  notified[2] and notified[2].msg:find('no build file found', 1, true) ~= nil, notified[2] and notified[2].msg)
check('the last state replaces the previous one', progress_mod.import_state(77) == failed)
notified = {}
ph['intellij/workspaceImportState'](nil, { phase = 'CANCELLED', folders = {} }, { client_id = 77 })
check('a cancelled cycle with no folders is reported once', #notified == 1 and notified[1].msg:find('cancelled', 1, true), vim.inspect(notified))
vim.notify = real_notify

-- ambiguousBuildSystem: only a dismissed prompt is offered again, once, and the pick reloads with
-- that folder's buildTools entry set.
local reloads = {}
local real_reload = progress_mod._reload_with_tool
progress_mod._reload_with_tool = function(cid, uri, tool) reloads[#reloads + 1] = { cid, uri, tool } end
local selects = 0
vim.ui.select = function(items, _, on_choice) selects = selects + 1; on_choice(items[2]) end
local pending = { blockedFolders = { { folderUri = 'file:///tmp/ijtest', reason = 'ambiguousBuildSystem', candidates = { 'gradle', 'maven' }, dismissed = false } } }
ph['intellij/workspaceImportStatus'](nil, pending, { client_id = 77 })
check('status is stored', progress_mod.import_status(77) == pending)
check("the server's own prompt is not doubled", selects == 0)
local dismissed = { blockedFolders = { { folderUri = 'file:///tmp/ijtest', reason = 'ambiguousBuildSystem', candidates = { 'gradle', 'maven' }, dismissed = true } } }
ph['intellij/workspaceImportStatus'](nil, dismissed, { client_id = 77 })
check('a dismissed prompt is offered again', selects == 1)
check('the pick reloads with that tool', #reloads == 1 and reloads[1][2] == 'file:///tmp/ijtest' and reloads[1][3] == 'maven', vim.inspect(reloads))
ph['intellij/workspaceImportStatus'](nil, dismissed, { client_id = 77 })
check('the same folder is offered only once', selects == 1)
progress_mod.reset(77)
check('reset forgets import state and status', progress_mod.import_state(77) == nil and progress_mod.import_status(77) == nil)
vim.ui.select = select_stub
progress_mod._reload_with_tool = real_reload

-- The reload itself carries a full initializationOptions with the one folder pinned.
local reload_req
vim.lsp.get_client_by_id = function(id)
  if id == 4711 then
    return { id = 4711, config = { root_dir = '/tmp/ijtest' }, request = function(_, method, params) reload_req = { method, params } return true, 1 end }
  end
  return real_get_client(id)
end
progress_mod._reload_with_tool(4711, 'file:///tmp/ijtest/app', 'gradle')
vim.lsp.get_client_by_id = real_get_client
check('reload uses intellij/reloadWorkspace', reload_req and reload_req[1] == 'intellij/reloadWorkspace')
check('reload pins the folder to the chosen tool',
  reload_req and reload_req[2].initializationOptions.buildTools['file:///tmp/ijtest/app'] == 'gradle', vim.inspect(reload_req))
check('reload keeps the root folder entry',
  reload_req and reload_req[2].initializationOptions.buildTools[vim.uri_from_fname('/tmp/ijtest')] ~= nil, vim.inspect(reload_req))

-- ---------------------------------------------------------------------------
-- File templates
-- ---------------------------------------------------------------------------
local templates = require('intellij-lsp.templates')
local java_t = templates.templates_for({}, 'java')
check('java templates start with Class', java_t[1].name == 'Class' and #java_t == 6, vim.inspect(vim.tbl_map(function(t) return t.name end, java_t)))
check('kotlin templates include Data Class', vim.tbl_contains(vim.tbl_map(function(t) return t.name end, templates.templates_for({}, 'kotlin')), 'Data Class'))
check('unknown filetype has no templates', #templates.templates_for({}, 'python') == 0)
local custom = templates.templates_for({ file_templates = { java = { ['Class'] = false, ['Service'] = 'public class ${NAME} {}' } } }, 'java')
local custom_names = vim.tbl_map(function(t) return t.name end, custom)
check('a user entry adds a template', vim.tbl_contains(custom_names, 'Service'), vim.inspect(custom_names))
check('a false user entry removes a default', not vim.tbl_contains(custom_names, 'Class'), vim.inspect(custom_names))
check('defaults are not mutated by overrides', templates.templates_for({}, 'java')[1].name == 'Class')

local lines_, row_, col_ = templates.split_marker('package a;\n\npublic class A {\n\t|\n}')
check('split_marker removes the marker', lines_[4] == '\t' and #lines_ == 5, vim.inspect(lines_))
check('split_marker places the cursor at the marker', row_ == 4 and col_ == 1, row_ .. ':' .. col_)
local l2, r2, c2 = templates.split_marker('no marker here')
check('split_marker without a marker parks the cursor at the end', #l2 == 1 and r2 == 1 and c2 == #'no marker here')
local l3, r3, c3 = templates.split_marker('record R(|) {}')
check('split_marker on the first line', r3 == 1 and c3 == 9 and l3[1] == 'record R() {}', vim.inspect({ l3, r3, c3 }))

-- BufNewFile flags a buffer; an existing file is not flagged; the flag plus emptiness is the gate.
local tpl_group = vim.api.nvim_create_augroup('IntellijLspTest', { clear = true })
templates.setup_autocmd(tpl_group, { 'java', 'kotlin' })
vim.fn.mkdir('/tmp/ijtest/src/main/java/com/example', 'p')
vim.fn.delete('/tmp/ijtest/src/main/java/com/example/Fresh.java')
vim.cmd('edit /tmp/ijtest/src/main/java/com/example/Fresh.java')
local fresh = vim.api.nvim_get_current_buf()
check('BufNewFile flags a new java file', vim.b[fresh].intellij_lsp_new_file == true)
check('a flagged empty buffer is a template candidate', templates.is_empty_new_file(fresh))
vim.api.nvim_buf_set_lines(fresh, 0, -1, false, { 'typed' })
check('a buffer with text is not', not templates.is_empty_new_file(fresh))
vim.fn.writefile({ 'x' }, '/tmp/ijtest/src/main/java/com/example/Existing.java')
vim.cmd('edit /tmp/ijtest/src/main/java/com/example/Existing.java')
check('an existing file is not flagged', not vim.b[0].intellij_lsp_new_file)
vim.cmd('edit /tmp/ijtest/src/main/java/com/example/New.kt')
check('BufNewFile flags a new kotlin file', vim.b[0].intellij_lsp_new_file == true)
vim.api.nvim_del_augroup_by_id(tpl_group)

-- apply() creates the file first (the server resolves the URI through its VFS), sends exactly the
-- two arguments, and inserts the answer with the cursor at the marker.
do
  local req
  local tpl_client = { id = 1, request = function(_, method, params, handler) req = { method, params, handler } return true, 1 end }
  local target = '/tmp/ijtest/src/main/java/com/example/Made.java'
  vim.fn.delete(target)
  vim.cmd('edit ' .. target)
  local made = vim.api.nvim_get_current_buf()
  templates.apply(tpl_client, made, java_t[1])
  check('apply writes the empty file first', vim.fn.filereadable(target) == 1)
  check('apply sends interpolateFileTemplate with uri and text',
    req and req[1] == 'workspace/executeCommand' and req[2].command == 'interpolateFileTemplate'
    and req[2].arguments[1] == vim.uri_from_bufnr(made) and req[2].arguments[2] == java_t[1].text, vim.inspect(req and req[2]))
  req[3](nil, 'package com.example;\n\npublic class Made {\n\t|\n}')
  vim.cmd('stopinsert')
  local got_lines = vim.api.nvim_buf_get_lines(made, 0, -1, false)
  check('apply inserts the interpolated text', got_lines[1] == 'package com.example;' and got_lines[3] == 'public class Made {', vim.inspect(got_lines))
  check('apply parks the cursor at the marker', vim.api.nvim_win_get_cursor(0)[1] == 4, vim.inspect(vim.api.nvim_win_get_cursor(0)))
  -- A null answer (file outside any project) leaves the buffer alone.
  vim.api.nvim_buf_set_lines(made, 0, -1, false, {})
  templates.apply(tpl_client, made, java_t[1])
  req[3](nil, vim.NIL)
  check('a null answer inserts nothing', (vim.api.nvim_buf_get_lines(made, 0, -1, false)[1] or '') == '')
  -- Text typed while the request was out is not overwritten.
  templates.apply(tpl_client, made, java_t[1])
  vim.api.nvim_buf_set_lines(made, 0, -1, false, { 'typed meanwhile' })
  req[3](nil, 'package x;')
  check('a late answer does not overwrite typed text', vim.api.nvim_buf_get_lines(made, 0, -1, false)[1] == 'typed meanwhile')
  vim.cmd('bwipeout! ' .. made)
  vim.fn.delete(target)
end

-- ---------------------------------------------------------------------------
-- Compilation errors and workspace export
-- ---------------------------------------------------------------------------
local workspace = require('intellij-lsp.workspace')
workspace.register_commands()
local all_cmds = vim.api.nvim_get_commands({})
check(':IntellijLspCompilationErrors registered', all_cmds.IntellijLspCompilationErrors ~= nil)
check(':IntellijLspExportWorkspace registered', all_cmds.IntellijLspExportWorkspace ~= nil)
local diag_buf = vim.api.nvim_create_buf(true, false)
vim.api.nvim_buf_set_lines(diag_buf, 0, -1, false, { 'int x = "s";' })
local diags = workspace._to_diagnostics({
  { range = { start = { line = 0, character = 8 }, ['end'] = { line = 0, character = 11 } }, severity = 1, message = 'incompatible types' },
}, diag_buf, { offset_encoding = 'utf-16' })
check('compiler errors convert to diagnostics', #diags == 1 and diags[1].lnum == 0 and diags[1].col == 8 and diags[1].message == 'incompatible types' and diags[1].bufnr == diag_buf, vim.inspect(diags))
end

-- ---------------------------------------------------------------------------
-- Single-key answers to numbered prompts
-- ---------------------------------------------------------------------------
local ui_select = require('intellij-lsp.select')
local prev_select = vim.ui.select
ui_select.setup()

--- Drives the wrapper with real typeahead and reports what on_choice received.
local function pick(keys, items)
  local got_item, got_idx, called = nil, nil, false
  vim.api.nvim_feedkeys(keys, 'n', false)
  vim.ui.select(items, { prompt = 'pick', format_item = function(i) return i.name end },
    function(item, idx)
      called, got_item, got_idx = true, item, idx
    end)
  return called, got_item, got_idx
end

local short = { { name = 'alpha' }, { name = 'beta' }, { name = 'gamma' } }

local called, item, idx = pick('2', short)
check('a bare digit selects, no <CR>', called and idx == 2 and item.name == 'beta', tostring(idx))
-- Regression: a menu that fails to render must not turn into a silent dismissal; the surrounding
-- pcall once made every pick answer nil that way.
check('selecting returns the item', item ~= nil and item.name == 'beta')

-- The menu is a float, not an echo: in a terminal an echoed multi-line menu raises the hit-enter
-- prompt, which says "Press ENTER" and blocks timers and RPC until a key arrives.
local menu_win = ui_select._open_menu(short, { prompt = 'Code actions:', format_item = function(i) return i.name end })
local menu_cfg = vim.api.nvim_win_get_config(menu_win)
local menu_lines = vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(menu_win), 0, -1, false)
check('menu opens as a float', menu_cfg.relative ~= '', vim.inspect(menu_cfg.relative))
check('menu numbers its entries', menu_lines[1] == ' 1  alpha ' and menu_lines[3] == ' 3  gamma ', vim.inspect(menu_lines))
check('menu carries the prompt as its title', vim.inspect(menu_cfg.title):find('Code actions:', 1, true) ~= nil, vim.inspect(menu_cfg.title))
vim.api.nvim_win_close(menu_win, true)
pick('2', short)
local floats_left = vim.tbl_filter(function(w) return vim.api.nvim_win_get_config(w).relative ~= '' end, vim.api.nvim_list_wins())
check('menu closes after the pick', #floats_left == 0, #floats_left)

for _, key in ipairs({ { '\27', 'Esc' }, { 'q', 'q' } }) do
  local c, it, ix = pick(key[1], short)
  -- Dismissal still has to call back: extensions.lua must answer the server or it leaks the session.
  check(key[2] .. ' cancels and still calls back', c and it == nil and ix == nil)
end

local c_oob = select(3, pick('7', short))
check('an out-of-range digit cancels', c_oob == nil)
local c_nan = select(3, pick('x', short))
check('a non-digit cancels', c_nan == nil)

-- Above nine entries a single digit is ambiguous, so the built-in line prompt takes over -- which is
-- why this one needs the <CR> the rest do not.
local many = {}
for i = 1, 12 do many[i] = { name = 'item' .. i } end
local _, many_item, many_idx = pick('11\r', many)
check('a long list falls back to the line prompt', many_idx == 11 and many_item.name == 'item11',
  tostring(many_idx))

-- The wrapper has to be a good citizen: vim.ui.select is shared, and dressing.nvim/snacks.nvim
-- replace it with something better than this.
local sentinel = function() end
ui_select.teardown()
vim.ui.select = sentinel
ui_select.setup()
check('wrapping keeps the previous picker', vim.ui.select ~= sentinel)
ui_select.setup()
check('setup does not wrap itself twice', vim.ui.select == ui_select.select)
ui_select.teardown()
check('teardown restores the previous picker', vim.ui.select == sentinel)

vim.ui.select = prev_select

-- ---------------------------------------------------------------------------
-- Import / indexing progress reporting
-- ---------------------------------------------------------------------------
local status = require('intellij-lsp.status')

-- These exact strings are the server's `title` and `message` joined, with nothing reworded;
-- pinning them here stops the line from drifting away from the server's wording.
local function text(t) return (status.describe(t)) end
check('importing reports the build tool',
  text({ title = 'Importing', message = 'Maven' }) == 'Importing: Maven',
  text({ title = 'Importing', message = 'Maven' }))
check('non-numeric indexing message passes through',
  text({ title = 'Indexing', message = 'Invalidating files' }) == 'Indexing: Invalidating files')
check('title without message', text({ title = 'Indexing' }) == 'Indexing')
-- Titles are never translated, so one this client has never heard of must still reach the user.
check('unknown title still reports',
  text({ title = 'Future Phase', message = 'x' }) == 'Future Phase: x')
check('no progress reports nothing', text(nil) == nil and text({}) == nil)

-- Neovim draws the `percent` field itself, so a message that is only the percentage would render
-- as "47% Indexing: 47%". The digits move to the field and the text collapses to the title.
local t47, p47 = status.describe({ title = 'Indexing', message = '47%', percent = 47 })
check('percentage-only message collapses to the title', t47 == 'Indexing', t47)
check('percentage travels as the field', p47 == 47, p47)
check('whitespace-padded percentage also collapses',
  (status.describe({ title = 'Indexing', message = ' 8 % ' })) == 'Indexing')
-- but a message that merely *contains* a number keeps its wording
check('prose with a number is kept',
  (status.describe({ title = 'Indexing', message = '3 of 9 roots' })) == 'Indexing: 3 of 9 roots')

-- The dots. Frames without a percentage get one to three trailing dots, so a line that can sit
-- unchanged for minutes ("Importing: Maven") still reads as alive rather than hung. Pure on purpose:
-- the frame is an argument, so all three frames and the wraparound are checked without a timer.
check('frame 1 is one dot', status.animate('Importing: Maven', nil, 1) == 'Importing: Maven .',
  status.animate('Importing: Maven', nil, 1))
check('frame 2 is two dots', status.animate('Importing: Maven', nil, 2) == 'Importing: Maven ..')
check('frame 3 is three dots', status.animate('Importing: Maven', nil, 3) == 'Importing: Maven ...')
-- Wraps back to one dot, never to none: a line that periodically loses its dots looks like it
-- finished and started over.
check('frame 4 wraps to one dot', status.animate('Importing: Maven', nil, 4) == 'Importing: Maven .',
  status.animate('Importing: Maven', nil, 4))
check('frame 6 is three dots', status.animate('Importing: Maven', nil, 6) == 'Importing: Maven ...')
check('frame 7 wraps to one dot', status.animate('Importing: Maven', nil, 7) == 'Importing: Maven .')
-- The counter free-runs across phases and is never reset, so any integer has to stay in range.
check('frame 100 stays in range',
  status.animate('Importing: Maven', nil, 100):match(' %.%.?%.?$') ~= nil,
  status.animate('Importing: Maven', nil, 100))

-- A percentage is its own liveness signal, so those frames stay byte-identical -- both signals at
-- once would say the same thing twice and jitter the width as the digits move.
for f = 1, 4 do
  check('percentage frames get no dots (frame ' .. f .. ')',
    status.animate('Indexing', 47, f) == 'Indexing', status.animate('Indexing', 47, f))
end
check('zero percent still counts as a percentage', status.animate('Indexing', 0, 2) == 'Indexing')
check('nothing to report stays nothing', status.animate(nil, nil, 1) == nil)

-- The closing frame carries no dots, which is structural rather than conditional: `finish` builds its
-- text from `describe` and never routes through `animate`. Pinned anyway, because "Ready ..." would
-- claim work is still running after the index was flushed. These two also fail loudly if anyone
-- later folds the decoration back into `describe`.
check('Ready is never decorated', (status.describe({ title = 'Ready' })) == 'Ready')
check('describe carries no dots',
  (status.describe({ title = 'Importing', message = 'Maven' })) == 'Importing: Maven')

-- State machine. Payloads mirror the wire, including the `title` Neovim back-fills onto report/end.
local CID = 4242
local function progress_event(token, value) status.on_progress(CID, { token = token, value = value }) end

status.reset(CID)
progress_event('t1', { kind = 'begin', title = 'Importing', message = 'Maven' })
check('begin importing', text(status.get(CID)) == 'Importing: Maven')

progress_event('t2', { kind = 'begin', title = 'Indexing' })
progress_event('t2', { kind = 'report', title = 'Indexing', message = '47%', percentage = 47 })
check('indexing outranks importing', text(status.get(CID)) == 'Indexing')
check('percent tracked', status.percent(CID) == 47, status.percent(CID))

-- The server ends the two overlapping bars in either order; a single scalar phase would let this
-- late import end wipe the indexing report.
progress_event('t1', { kind = 'end', title = 'Importing' })
check('late import end does not clobber indexing', text(status.get(CID)) == 'Indexing')
check('late import end keeps the percentage', status.percent(CID) == 47)

progress_event('t2', { kind = 'report', title = 'Indexing', message = 'Invalidating files' })
progress_event('t2', { kind = 'report', title = 'Indexing', percentage = 60 })
check('bare percentage report keeps the message',
  text(status.get(CID)) == 'Indexing: Invalidating files', text(status.get(CID)))
check('bare percentage report updates the number', status.percent(CID) == 60)

progress_event('t2', { kind = 'report', title = 'Indexing', percentage = 120 })
check('percentage clamped to 100', status.percent(CID) == 100, status.percent(CID))

-- Regression: the Importing bar outlives Indexing, so recomputing from live tokens alone dropped
-- the line back to "Importing: Maven" after indexing had finished, reading as a restarted import.
status.reset(CID)
progress_event('i1', { kind = 'begin', title = 'Importing', message = 'Maven' })
progress_event('i2', { kind = 'begin', title = 'Indexing' })
progress_event('i2', { kind = 'report', title = 'Indexing', message = 'Just a few more moments...' })
progress_event('i2', { kind = 'end', title = 'Indexing' })
check('indexing end does not fall back to importing',
  text(status.get(CID)) == 'Indexing: Just a few more moments...', text(status.get(CID)))
progress_event('i1', { kind = 'end', title = 'Importing' })
check('startup never moves backwards',
  text(status.get(CID)) == 'Indexing: Just a few more moments...', text(status.get(CID)))

-- With every token ended the index is still being flushed, so the last phase is held rather than
-- blanked; progress.lua's ready-for-test handler is what closes the line.
status.reset(CID)
progress_event('t2', { kind = 'begin', title = 'Indexing', message = 'Invalidating files' })
progress_event('t2', { kind = 'end', title = 'Indexing' })
check('last phase is held after all tokens end',
  text(status.get(CID)) == 'Indexing: Invalidating files', text(status.get(CID)))
check('nothing reported before any progress arrives', text(status.get(999)) == nil)

-- Attaching mid-session: the first payload seen may be a report, which the back-filled title makes
-- self-describing enough to adopt.
status.reset(CID)
progress_event('t9', { kind = 'report', title = 'Indexing', message = 'Just a moment', percentage = 5 })
check('report for an unseen token is adopted', text(status.get(CID)) == 'Indexing: Just a moment')
status.reset(CID)
check('reset clears the client', status.get(CID) == nil)

-- The in-place message. Reusing the id is what keeps ten reports a second on one line instead of
-- scrolling the message area; without it the hit-enter prompt would fire constantly.
local pm = { kind = 'progress', source = 'intellij-lsp', title = 'IntelliJ LSP', status = 'running' }
local first = vim.api.nvim_echo({ { 'Importing: Maven' } }, false, pm)
check('nvim_echo returns a message id', type(first) == 'number', type(first))
pm.id = first
local second = vim.api.nvim_echo({ { 'Indexing' } }, false, pm)
check('passing the id back reuses the message', second == first, tostring(second))

-- Regression: the server re-runs a short `Indexing` begin/end on every file event after the initial
-- flush -- it watches the project root's ancestors, so a shell writing ~/.zsh_history is enough --
-- and `ready-for-test` is sent once per session. Holding the line open after those rounds left a
-- "running" Indexing message on screen indefinitely. Drives the real autocmd path with a stubbed
-- client lookup and a captured message area.
do
  local progress_mod = require('intellij-lsp.progress')
  local SID = 4343
  local real_get, real_echo, real_notify = vim.lsp.get_client_by_id, vim.api.nvim_echo, vim.notify
  local echoes = {}
  vim.lsp.get_client_by_id = function(id) return id == SID and { name = client.NAME } or nil end
  vim.api.nvim_echo = function(chunks, _, opts)
    if opts.kind == 'progress' then table.insert(echoes, { status = opts.status, text = chunks[1][1] }) end
    return opts.id or 7
  end
  vim.notify = function() end
  status.setup_autocmds()
  local function fire(kind, message, percentage)
    vim.api.nvim_exec_autocmds('LspProgress', { data = { client_id = SID, params = {
      token = 's1', value = { kind = kind, title = 'Indexing', message = message, percentage = percentage },
    } } })
  end

  fire('begin'); fire('report', '47%', 47); fire('end')
  check('startup: line held open after end, before ready', status.get(SID).msg_id ~= nil)
  progress_mod.handlers()['intellij/ready-for-test'](nil, nil, { client_id = SID })
  check('startup: ready closes the line', status.get(SID).msg_id == nil)
  check('startup: closing frame is Ready', echoes[#echoes].status == 'success' and echoes[#echoes].text == 'Ready',
    vim.inspect(echoes[#echoes]))

  fire('begin'); fire('report', '0%', 0)
  check('post-ready round: a live token reopens the line', status.get(SID).msg_id ~= nil)
  check('post-ready round: shows as running', echoes[#echoes].status == 'running', echoes[#echoes].status)
  fire('end')
  check('post-ready round: its end closes the line', status.get(SID).msg_id == nil)
  check('post-ready round: closing frame is Ready', echoes[#echoes].status == 'success' and echoes[#echoes].text == 'Ready',
    vim.inspect(echoes[#echoes]))
  check('is_idle after the round', status.is_idle(SID))

  status.teardown_autocmds()
  status.reset(SID)
  progress_mod.reset(SID)
  vim.lsp.get_client_by_id, vim.api.nvim_echo, vim.notify = real_get, real_echo, real_notify
end

-- Neovim 0.11: `nvim_echo` rejects `kind = 'progress'` ("invalid key: kind"), and the pcall around it
-- swallowed every report, so a whole import went by with nothing on screen. The fallback is a plain
-- echo, coalesced so that a burst of reports is one echo and never stacks into the hit-enter prompt.
do
  local progress_mod = require('intellij-lsp.progress')
  local SID = 4344
  local real_get, real_echo, real_notify = vim.lsp.get_client_by_id, vim.api.nvim_echo, vim.notify
  local real_flag = status._progress_messages
  local echoes, notes = {}, {}
  status._progress_messages = false
  vim.lsp.get_client_by_id = function(id) return id == SID and { name = client.NAME } or nil end
  vim.api.nvim_echo = function(chunks, history, opts)
    if next(opts or {}) ~= nil then error('invalid key: kind') end
    table.insert(echoes, { text = chunks[1][1], history = history })
  end
  vim.notify = function(msg) table.insert(notes, msg) end
  status.setup_autocmds()
  local function fire(kind, message, percentage)
    vim.api.nvim_exec_autocmds('LspProgress', { data = { client_id = SID, params = {
      token = 'l1', value = { kind = kind, title = 'Indexing', message = message, percentage = percentage },
    } } })
  end
  local function settle() vim.wait(300, function() return false end) end

  check('0.11 line: title and percent spelled out', status._legacy_line('Indexing', 47) == 'IntelliJ LSP: 47% Indexing',
    status._legacy_line('Indexing', 47))
  check('0.11 line: no percent, no number', status._legacy_line('Importing: Maven') == 'IntelliJ LSP: Importing: Maven')

  fire('begin'); fire('report', '10%', 10); fire('report', '47%', 47)
  settle()
  check('0.11: a burst of reports is one echo', #echoes == 1, vim.inspect(echoes))
  check('0.11: the echo is the latest report', echoes[1] and echoes[1].text == 'IntelliJ LSP: 47% Indexing',
    vim.inspect(echoes[1]))
  check('0.11: kept out of :messages', echoes[1] and echoes[1].history == false)
  check('0.11: the line counts as open', status.get(SID).msg_id ~= nil)

  fire('end'); fire('begin'); fire('report', '90%', 90)
  progress_mod.handlers()['intellij/ready-for-test'](nil, nil, { client_id = SID })
  settle()
  check('0.11: ready closes the line', status.get(SID).msg_id == nil)
  check('0.11: the ready notification is the last word', #echoes == 1 and notes[#notes] == 'IntelliJ LSP: indexing complete',
    vim.inspect({ echoes = echoes, notes = notes }))

  fire('end'); fire('begin'); fire('report', '0%', 0); fire('end')
  settle()
  check('0.11: a post-ready round closes with Ready', echoes[#echoes].text == 'IntelliJ LSP: Ready',
    vim.inspect(echoes[#echoes]))
  check('0.11: and only Ready', #echoes == 2, #echoes)

  status.teardown_autocmds()
  status.reset(SID)
  progress_mod.reset(SID)
  status._progress_messages = real_flag
  vim.lsp.get_client_by_id, vim.api.nvim_echo, vim.notify = real_get, real_echo, real_notify
end

-- SIGKILL from outside is nearly always the OOM killer; Neovim's own exit message only names the signal.
check('killed: no message for a normal exit', client._killed_message(nil, 1400) == nil)
check('killed: no message for SIGTERM', client._killed_message(15, 1400) == nil)
local killed = client._killed_message(9, 1434)
check('killed: names the likely cause', killed and killed:find('running out of memory', 1, true) ~= nil, killed)
check('killed: reports what is free', killed and killed:find('(1.4 GB available without it)', 1, true) ~= nil, killed)
check('killed: no figure when unknown', not client._killed_message(9, nil):find('available', 1, true))
check('meminfo: MemAvailable in MiB',
  client._mem_available_mib('MemTotal:        3905896 kB\nMemAvailable:    1480204 kB\n') == 1445,
  client._mem_available_mib('MemTotal:        3905896 kB\nMemAvailable:    1480204 kB\n'))
check('meminfo: missing line is nil', client._mem_available_mib('MemTotal: 1 kB\n') == nil)

-- Server download: platform mapping, the published bundle table, and archive kinds. Pure, no network.
local server_download = require('intellij-lsp.server_download')
local bundles = require('intellij-lsp.server_bundles')
local BASE = 'https://download.jetbrains.com/language-server/intellij-server/' .. bundles.version
  .. '/intellij-server-' .. bundles.version

local platform_cases = {
  { uname = { sysname = 'Darwin', machine = 'arm64' }, os = 'macos', arch = 'aarch64', file = '-aarch64.sit' },
  { uname = { sysname = 'Darwin', machine = 'x86_64' }, os = 'macos', arch = 'x86_64', file = '.sit' },
  { uname = { sysname = 'Linux', machine = 'aarch64' }, os = 'linux', arch = 'aarch64', file = '-aarch64.tar.gz' },
  { uname = { sysname = 'Linux', machine = 'x86_64' }, os = 'linux', arch = 'x86_64', file = '.tar.gz' },
  { uname = { sysname = 'Windows_NT', machine = 'arm64' }, os = 'windows', arch = 'aarch64', file = '-aarch64.win.zip' },
  { uname = { sysname = 'Windows_NT', machine = 'AMD64' }, os = 'windows', arch = 'x86_64', file = '.win.zip' },
}
for _, case in ipairs(platform_cases) do
  local label = case.uname.sysname .. '/' .. case.uname.machine
  local os, arch, perr = server_download._platform(case.uname)
  check('platform ' .. label, os == case.os and arch == case.arch and perr == nil, tostring(perr))
  local bundle, berr = bundles.bundle(case.os, case.arch)
  check('bundle url ' .. label, bundle and bundle.url == BASE .. case.file, bundle and bundle.url or berr)
  check('bundle sha256 ' .. label, bundle and bundle.sha256:match('^%x+$') and #bundle.sha256 == 64
    and bundle.sha256 == bundle.sha256:lower(), bundle and bundle.sha256)
  check('bundle version ' .. label, bundle and bundle.version == bundles.version)
end

local uos, uarch, uerr = server_download._platform({ sysname = 'Linux', machine = 'riscv64' })
check('unknown machine -> error', uos == nil and uarch == nil and uerr and uerr:find('riscv64', 1, true), uerr)
check('live platform resolves', (server_download._platform()) ~= nil)
local nb, nberr = bundles.bundle('plan9', 'x86_64')
check('unknown os -> no bundle', nb == nil and nberr and nberr:find('plan9', 1, true), nberr)

check('archive_kind .sit -> zip', server_download._archive_kind(BASE .. '-aarch64.sit') == 'zip')
check('archive_kind .win.zip -> zip', server_download._archive_kind(BASE .. '.win.zip') == 'zip')
check('archive_kind .tar.gz', server_download._archive_kind(BASE .. '.tar.gz') == 'tar.gz')
check('archive_kind .tgz', server_download._archive_kind('x.tgz') == 'tar.gz')
check('archive_kind .dmg -> nil', server_download._archive_kind('x.dmg') == nil)

check('status: disabled -> not-configured', server_download.status({ server_download = false }) == 'not-configured')
check('status: own bundle -> not-configured',
  server_download.status({ server_path = '/opt/intellij-server/bin/intellij-server' }) == 'not-configured')
local st = server_download.status({})
check('status: default -> cached or missing', st == 'cached' or st == 'missing', st)

-- Download progress line text.
local pt, ppc = server_download._progress_text('1.0', 50e6, 200e6)
check('progress text with total', pt == 'Downloading intellij-server 1.0: 50 / 200 MB' and ppc == 25, pt .. ' ' .. tostring(ppc))
local pt2, ppc2 = server_download._progress_text('1.0', 5e6, nil)
check('progress text without total', pt2 == 'Downloading intellij-server 1.0: 5 MB' and ppc2 == nil, pt2)
local _, ppc3 = server_download._progress_text('1.0', 250e6, 200e6)
check('progress percent clamps at 100', ppc3 == 100, ppc3)

-- Install lock: owner PID, stale detection, sweep of the partial archive.
local vdir = vim.fs.normalize(vim.fn.tempname() .. '/server/1.0')
local lock = vdir .. '.lock'
local partial = vim.fs.normalize(vim.fn.tempname() .. '-archive')
check('lock acquired', server_download._try_lock(vdir, partial) == 'acquired')
check('lock records own pid', tonumber(vim.fn.readfile(lock .. '/pid')[1]) == vim.uv.os_getpid())
check('own lock is not stale', server_download._lock_is_stale(lock) == false)
check('own lock -> held', server_download._try_lock(vdir, partial) == 'held')

local dead_proc = vim.system({ 'true' })
local dead_pid = dead_proc.pid
dead_proc:wait()
vim.fn.writefile({ tostring(dead_pid) }, lock .. '/pid')
vim.fn.writefile({ 'partial' }, partial)
check('dead owner -> stale', server_download._lock_is_stale(lock) == true)
check('stale lock is swept and re-acquired', server_download._try_lock(vdir, partial) == 'acquired')
check('partial archive removed with stale lock', vim.fn.filereadable(partial) == 0)
check('pid file rewritten to own pid', tonumber(vim.fn.readfile(lock .. '/pid')[1]) == vim.uv.os_getpid())

vim.fn.delete(lock .. '/pid')
check('fresh lock without pid is not stale', server_download._lock_is_stale(lock) == false)
server_download._release_lock(vdir)
check('release removes the lock', vim.fn.isdirectory(lock) == 0)

-- Install: the bundle is published only once extracted whole. A local archive over file:// stands
-- in for the download.
;(function()
  local bundles = require('intellij-lsp.server_bundles')
  local saved_bundle, saved_root = bundles.bundle, server_download.cache_root
  local work = vim.fs.normalize(vim.fn.tempname() .. '-install')
  local root = work .. '/cache'
  vim.fn.mkdir(work .. '/src/intellij-server-9.9/bin', 'p')
  vim.fn.mkdir(work .. '/src/intellij-server-9.9/lib', 'p')
  vim.fn.writefile({ '#!/bin/sh' }, work .. '/src/intellij-server-9.9/bin/intellij-server')
  vim.fn.writefile({ 'runtime' }, work .. '/src/intellij-server-9.9/lib/runtime.jar')
  local archive = work .. '/intellij-server-9.9.tar.gz'
  vim.system({ 'tar', '-czf', archive, '-C', work .. '/src', 'intellij-server-9.9' }):wait()
  bundles.bundle = function()
    return { url = 'file://' .. archive, version = '9.9', sha256 = server_download._sha256_file(archive),
      size = vim.uv.fs_stat(archive).size }
  end
  server_download.cache_root = function() return root end
  local version_dir = root .. '/9.9'
  local launcher = version_dir .. '/bin/intellij-server'

  local function ensure()
    local got
    server_download.ensure(function(path, err) got = { path = path, err = err } end)
    return function() return got end
  end

  -- An extraction cut short: the launcher is there, the rest is not, and it is not taken as installed.
  vim.fn.mkdir(version_dir .. '.partial/bin', 'p')
  vim.fn.writefile({ '#!/bin/sh' }, version_dir .. '.partial/bin/intellij-server')
  -- What another instance polling for the launcher sees right after `tar` exits, before this one
  -- has checked and published the bundle.
  local real_system = vim.system
  local visible_mid_install
  vim.system = function(cmd, opts, on_exit)
    if cmd[1] == 'tar' and cmd[2] == '-xzf' then
      return real_system(cmd, opts, function(r)
        visible_mid_install = vim.uv.fs_stat(launcher) ~= nil
        on_exit(r)
      end)
    end
    return real_system(cmd, opts, on_exit)
  end
  local result = ensure()
  vim.wait(10000, function() return result() ~= nil end, 20)
  vim.system = real_system
  check('install: the launcher appears only once the bundle is published', visible_mid_install == false,
    tostring(visible_mid_install))
  check('install: an interrupted extraction is installed again, not accepted',
    result() and result().path == launcher and vim.fn.filereadable(version_dir .. '/lib/runtime.jar') == 1,
    vim.inspect(result()))
  check('install: no staging directory is left behind', vim.fn.isdirectory(version_dir .. '.partial') == 0)
  check('install: the launcher is executable', vim.fn.getfperm(launcher):sub(3, 3) == 'x', vim.fn.getfperm(launcher))

  -- Another instance mid-extraction: this one waits for the bundle instead of reporting success early.
  vim.fn.delete(version_dir, 'rf')
  vim.fn.mkdir(version_dir .. '.lock', 'p')
  vim.fn.writefile({ tostring(vim.uv.os_getppid()) }, version_dir .. '.lock/pid')
  vim.fn.mkdir(version_dir .. '.partial/bin', 'p')
  vim.fn.writefile({ '#!/bin/sh' }, version_dir .. '.partial/bin/intellij-server')
  result = ensure()
  vim.wait(1500)
  check('install: waits while another instance extracts', result() == nil, vim.inspect(result()))
  vim.fn.mkdir(version_dir .. '.partial/lib', 'p')
  vim.fn.writefile({ 'runtime' }, version_dir .. '.partial/lib/runtime.jar')
  vim.uv.fs_rename(version_dir .. '.partial', version_dir)
  vim.fn.delete(version_dir .. '.lock', 'rf')
  vim.wait(3000, function() return result() ~= nil end, 20)
  check('install: and takes the bundle once it is published', result() and result().path == launcher
    and vim.fn.filereadable(version_dir .. '/lib/runtime.jar') == 1, vim.inspect(result()))

  bundles.bundle, server_download.cache_root = saved_bundle, saved_root
  vim.fn.delete(work, 'rf')
end)()

-- ---------------------------------------------------------------------------
-- Output panel: jump targets, import-log highlighting, and the shared buffer
-- ---------------------------------------------------------------------------
local output = require('intellij-lsp.output')
local progress = require('intellij-lsp.progress')

local function jt(line) return output._jump_target(line) end
local t

t = jt('[ERROR] /w/src/main/java/App.java:[12,5] cannot find symbol')
check('jump: maven compiler line', t and t.file == '/w/src/main/java/App.java' and t.lnum == 12 and t.col == 5 and not t.bare, vim.inspect(t))
t = jt('[FATAL] Non-parseable POM /w/pom.xml: end tag name </b> must match start tag @ line 12, column 3')
check('jump: maven pom parse error', t and t.file == '/w/pom.xml' and t.lnum == 12 and t.col == 3, vim.inspect(t))
t = jt("* Where: Build file '/w/build.gradle' line: 7")
check('jump: gradle build script', t and t.file == '/w/build.gradle' and t.lnum == 7 and t.col == nil, vim.inspect(t))
t = jt('e: /w/src/main/kotlin/Main.kt: (3, 9): Unresolved reference: foo')
check('jump: kotlin compiler line', t and t.file == '/w/src/main/kotlin/Main.kt' and t.lnum == 3 and t.col == 9, vim.inspect(t))
t = jt('/w/src/App.java:12: error: missing return statement')
check('jump: javac line', t and t.file == '/w/src/App.java' and t.lnum == 12 and t.col == nil, vim.inspect(t))
t = jt('/w/src/App.java:12:5: warning: something')
check('jump: path:line:col', t and t.lnum == 12 and t.col == 5, vim.inspect(t))
t = jt('	at com.example.App.main(App.java:42)')
check('jump: stack frame is bare', t and t.file == 'App.java' and t.lnum == 42 and t.bare, vim.inspect(t))
check('jump: plain text has no target', jt('[INFO] Building demo 1.0-SNAPSHOT') == nil)
check('jump: download line has no target', jt('Downloading from central: https://repo.maven.apache.org/maven2/x/y/1.0/y-1.0.pom') == nil)

-- Highlighting: type first, then Maven/Gradle/Kotlin stdout conventions.
check('hl: error type', progress._import_hl(1, 'anything') == 'DiagnosticError')
check('hl: stderr is warn', progress._import_hl(2, 'Downloading from central: x') == 'DiagnosticWarn')
check('hl: [ERROR] on stdout', progress._import_hl(3, '[ERROR] Failed to execute goal') == 'DiagnosticError')
check('hl: BUILD FAILURE', progress._import_hl(3, '[INFO] BUILD FAILURE') == 'DiagnosticError')
check('hl: gradle FAILURE', progress._import_hl(3, 'FAILURE: Build failed with an exception.') == 'DiagnosticError')
check('hl: [WARNING]', progress._import_hl(3, '[WARNING] Some problems were encountered') == 'DiagnosticWarn')
check('hl: BUILD SUCCESS', progress._import_hl(3, '[INFO] BUILD SUCCESS') == 'DiagnosticOk')
check('hl: plain info', progress._import_hl(3, '[INFO] Building demo 1.0') == nil)

check('elapsed seconds', progress._elapsed(12345) == '12s', progress._elapsed(12345))
check('elapsed minutes', progress._elapsed(72000) == '1m 12s', progress._elapsed(72000))

-- The shared buffer: appends coalesce, the first line is not blank, highlights land as extmarks.
output._reset()
output.append('one\ntwo\n')
output.append('three', 'DiagnosticWarn')
output._flush()
local obuf = output.buf()
local olines = vim.api.nvim_buf_get_lines(obuf, 0, -1, false)
check('output: lines appended without leading blank', vim.deep_equal(olines, { 'one', 'two', 'three' }), vim.inspect(olines))
local marks = vim.api.nvim_buf_get_extmarks(obuf, vim.api.nvim_create_namespace('intellij-lsp-output'), 0, -1, { details = true })
check('output: one highlighted line', #marks == 1 and marks[1][2] == 2 and marks[1][4].line_hl_group == 'DiagnosticWarn', vim.inspect(marks))

-- Import log through the real handler, with the default policy: nothing opens on start or success.
progress.configure({ build_output = 'on_failure' })
local il = progress.handlers()['intellij/importLog']
il(nil, { type = 3, message = 'Importing with Maven in /w', tool = 'Maven', started = true }, {})
il(nil, { type = 3, message = '[INFO] Scanning for projects...' }, {})
il(nil, { type = 2, message = 'Downloading from central: x' }, {})
il(nil, { type = 3, message = 'Workspace imported successfully', succeeded = true }, {})
output._flush()
olines = vim.api.nvim_buf_get_lines(obuf, 0, -1, false)
check('import: separator uses server message', olines[4] == '--- Importing with Maven in /w ---', olines[4])
check('import: lines forwarded', olines[5] == '[INFO] Scanning for projects...' and olines[6] == 'Downloading from central: x')
check('import: success separator names the tool', olines[7] and olines[7]:match('^%-%-%- Maven: import succeeded in %d+s %-%-%-$'), olines[7])
check('import: success message not duplicated', #olines == 7, #olines)
check('import: panel stays closed on success (on_failure)', not output.is_open())

il(nil, { type = 3, message = 'Importing with Gradle in /w', tool = 'Gradle', started = true }, {})
il(nil, { type = 1, message = 'Failed to import Gradle project', tool = 'Gradle', failed = true }, {})
output._flush()
olines = vim.api.nvim_buf_get_lines(obuf, 0, -1, false)
check('import: failure message kept', olines[9] == 'Failed to import Gradle project', olines[9])
check('import: failure separator', olines[10] and olines[10]:match('^%-%-%- Gradle: import failed'), olines[10])
check('import: panel opens on failure', output.is_open())
check('import: failure did not steal focus', vim.api.nvim_get_current_buf() ~= obuf)
output.close()

progress.configure({ build_output = 'always' })
il(nil, { type = 3, message = 'Importing with Maven in /w', tool = 'Maven', started = true }, {})
check('import: always opens on start', output.is_open())
output.close()

progress.configure({ build_output = 'never' })
il(nil, { type = 1, message = 'boom', tool = 'Maven', failed = true }, {})
check('import: never keeps the panel closed on failure', not output.is_open())
output._reset()


-- ---------------------------------------------------------------------------
-- run.lua: the build that precedes a launch. Drives `_build` / `_run_build` directly with a fake
-- client and `sh`, so it needs neither a server nor nvim-dap (absent under `-u NONE` anyway).
-- ---------------------------------------------------------------------------
local run = require('intellij-lsp.run')

-- `_build_to_run` is the client-side half of the `resolveBuildCommand` contract: unsupported ->
-- nothing plus the reason, empty command -> nothing.
local b, why = run._build_to_run({ supported = true, tool = 'maven', cwd = '/w', command = { 'mvn', 'compile' } })
check('build: supported answer yields a build', b and b.command[1] == 'mvn' and b.cwd == '/w' and b.tool == 'maven')
b, why = run._build_to_run({ supported = false, reason = 'no build tool owns this module' })
check('build: unsupported yields nothing and the reason', b == nil and why == 'no build tool owns this module')
b, why = run._build_to_run({ supported = true, command = {} })
check('build: empty command yields nothing', b == nil and why == nil)
check('build: nil answer yields nothing', run._build_to_run(nil) == nil)

local function panel_text()
  return table.concat(vim.api.nvim_buf_get_lines(output.buf(), 0, -1, false), '\n')
end
local function wait_for(pred) return vim.wait(5000, pred, 20) end

-- A failing build stops the launch, its output (both streams) is in the panel, and the panel is open.
output._reset()
local result = nil
run._run_build({ tool = 'maven', command = { 'sh', '-c', 'echo compiling; echo "[ERROR] /w/A.java:[3,5] boom" >&2; exit 3' } },
  function(ok) result = ok end)
check('build: failure -> not ok', wait_for(function() return result ~= nil end) and result == false, tostring(result))
check('build: stdout reaches the panel', wait_for(function() return panel_text():find('compiling', 1, true) ~= nil end))
check('build: stderr reaches the panel', panel_text():find('[ERROR] /w/A.java', 1, true) ~= nil, panel_text())
check('build: failure separator names the exit code', panel_text():find('build failed, exit 3', 1, true) ~= nil, panel_text())
check('build: failure opens the panel', output.is_open())

-- Exit 0 continues to the launch. The output has no trailing newline, so the last line arrives as a
-- partial chunk and is only written by the exit-time flush.
output._reset()
result = nil
run._run_build({ tool = 'gradle', command = { 'sh', '-c', 'printf "one\\ntwo"' } }, function(ok) result = ok end)
check('build: success -> ok', wait_for(function() return result ~= nil end) and result == true, tostring(result))
check('build: partial last line is flushed', wait_for(function() return panel_text():find('\ntwo\n', 1, true) ~= nil end), panel_text())
check('build: success separator', panel_text():find('gradle: build succeeded', 1, true) ~= nil, panel_text())

-- A command that cannot be spawned is a failed build, not a skipped one.
output._reset()
result = nil
run._run_build({ command = { '/nonexistent/mvn', 'compile' } }, function(ok) result = ok end)
check('build: unspawnable -> not ok', wait_for(function() return result ~= nil end) and result == false, tostring(result))
check('build: unspawnable is reported', wait_for(function() return panel_text():find('build failed to start', 1, true) ~= nil end), panel_text())

-- `stop()` during a build kills it and the launch never happens.
output._reset()
result = nil
run._run_build({ tool = 'maven', command = { 'sh', '-c', 'sleep 30' } }, function(ok) result = ok end)
vim.wait(100)
run.stop()
check('build: stop reports it', wait_for(function() return panel_text():find('build stopped', 1, true) ~= nil end), panel_text())
vim.wait(100)
check('build: stop never continues to the launch', result == nil)

-- `_build` with a fake client: a lookup failure or an unsupported module launches anyway and says so.
local function fake_client(err, resolved)
  return { request = function(_, method, params, handler)
    check('build: asks resolveBuildCommand', method == 'workspace/executeCommand'
      and params.command == 'intellij.java.resolveBuildCommand' and params.arguments[1].uri == 'file:///w/A.java')
    handler(err, resolved)
  end }
end
output._reset()
result = nil
run._build(fake_client({ message = 'server busy' }, nil), 'file:///w/A.java', function(ok) result = ok end)
check('build: lookup error -> launch anyway', wait_for(function() return result ~= nil end) and result == true)
check('build: lookup error is noted', wait_for(function() return panel_text():find('build skipped: server busy', 1, true) ~= nil end), panel_text())
output._reset()
result = nil
run._build(fake_client(nil, { supported = false, reason = 'JPS module' }), 'file:///w/A.java', function(ok) result = ok end)
check('build: unsupported -> launch anyway', wait_for(function() return result ~= nil end) and result == true)
check('build: unsupported reason is noted', wait_for(function() return panel_text():find('build skipped: JPS module', 1, true) ~= nil end), panel_text())
output._reset()
result = nil
run._build(fake_client(nil, { supported = true, tool = 'maven', command = { 'sh', '-c', 'exit 0' } }), 'file:///w/A.java',
  function(ok) result = ok end)
check('build: resolved command runs and continues', wait_for(function() return result ~= nil end) and result == true)
output._reset()


-- ---------------------------------------------------------------------------------------------
-- versions.lua: the server's per-notification counter vs Neovim's changedtick
-- ---------------------------------------------------------------------------------------------
local versions = require('intellij-lsp.versions')
local URI = 'file:///w/Owner.java'
local CID = 901

-- The sequence measured against a live server: didOpen at version 0, then a rename (two edits in one
-- didChange, tick 6), a blank-line insert (tick 7) and a reformat (tick 8). The server answers 3.
versions.on_notify(CID, 'textDocument/didOpen', { textDocument = { uri = URI, version = 0 } })
versions.on_notify(CID, 'textDocument/didChange', { textDocument = { uri = URI, version = 6 } })
versions.on_notify(CID, 'textDocument/didChange', { textDocument = { uri = URI, version = 7 } })
versions.on_notify(CID, 'textDocument/didChange', { textDocument = { uri = URI, version = 8 } })
check('versions: current counter -> current tick', versions.translate(CID, URI, 3) == 8, versions.translate(CID, URI, 3))
check('versions: older counter -> the tick it was sent with', versions.translate(CID, URI, 2) == 7)
check('versions: first counter -> first tick', versions.translate(CID, URI, 1) == 6)
check('versions: untouched buffer keeps its version', versions.translate(CID, URI, 0) == 0)
check('versions: a fixed server answering with our tick passes through', versions.translate(CID, URI, 8) == 8)
check('versions: a fixed server answering with a stale tick passes through', versions.translate(CID, URI, 6) == 6)
check('versions: unknown value -> vim.NIL', versions.translate(CID, URI, 40) == vim.NIL)
check('versions: absent version -> vim.NIL', versions.translate(CID, URI, nil) == vim.NIL)
check('versions: explicit null stays null', versions.translate(CID, URI, vim.NIL) == vim.NIL)
check('versions: unknown document is left alone', versions.translate(CID, 'file:///w/Other.java', 3) == 3)

-- A reload sends didClose + didOpen with the current tick; the counter restarts from there.
versions.on_notify(CID, 'textDocument/didClose', { textDocument = { uri = URI } })
check('versions: didClose forgets the document', versions.translate(CID, URI, 3) == 3)
versions.on_notify(CID, 'textDocument/didOpen', { textDocument = { uri = URI, version = 12 } })
versions.on_notify(CID, 'textDocument/didChange', { textDocument = { uri = URI, version = 13 } })
check('versions: counter restarts from the reopened version', versions.translate(CID, URI, 13) == 13)
versions.on_notify(CID, 'textDocument/didChange', { textDocument = { uri = URI, version = 20 } })
check('versions: counter 14 is tick 20', versions.translate(CID, URI, 14) == 20)

-- Only TextDocumentEdit entries are touched; file operations and the `changes` map are not.
local edit = {
  documentChanges = {
    { kind = 'rename', oldUri = URI, newUri = 'file:///w/Pet.java' },
    { textDocument = { uri = URI, version = 14 }, edits = {} },
    { textDocument = { uri = URI }, edits = {} },
  },
}
versions.fix_workspace_edit(CID, edit)
check('fix_workspace_edit: rename op untouched', edit.documentChanges[1].kind == 'rename' and edit.documentChanges[1].oldUri == URI)
check('fix_workspace_edit: counter translated', edit.documentChanges[2].textDocument.version == 20)
check('fix_workspace_edit: missing version normalised to null', edit.documentChanges[3].textDocument.version == vim.NIL)
local plain = { changes = { [URI] = {} } }
versions.fix_workspace_edit(CID, plain)
check('fix_workspace_edit: changes map untouched', plain.documentChanges == nil and plain.changes[URI] ~= nil)

-- install(): the wrapped client feeds the ledger from notify and rewrites request results, for the
-- handler passed in, the client's own handler table, and code actions in both shapes.
local seen = {}
local fake = {
  id = 902,
  handlers = {},
  notify = function(_, method, params) seen.notified = { method, params } return true end,
  request = function(_, method, params, handler)
    seen.requested = method
    if method == 'textDocument/rename' or method == 'workspace/willRenameFiles' then
      handler(nil, { documentChanges = { { textDocument = { uri = URI, version = 2 }, edits = {} } } })
    elseif method == 'codeAction/resolve' then
      handler(nil, { title = 'x', edit = { documentChanges = { { textDocument = { uri = URI, version = 2 }, edits = {} } } } })
    elseif method == 'textDocument/codeAction' then
      handler(nil, {
        { title = 'cmd', command = 'noop' },
        { title = 'fix', edit = { documentChanges = { { textDocument = { uri = URI, version = 2 }, edits = {} } } } },
      })
    else
      handler(nil, { untouched = true, version = 2 })
    end
    return true, 1
  end,
}
versions.install(fake)
fake:notify('textDocument/didOpen', { textDocument = { uri = URI, version = 0 } })
fake:notify('textDocument/didChange', { textDocument = { uri = URI, version = 5 } })
fake:notify('textDocument/didChange', { textDocument = { uri = URI, version = 9 } })
check('install: notify still reaches the client', seen.notified[1] == 'textDocument/didChange' and seen.notified[2].textDocument.version == 9)

local got
fake:request('textDocument/rename', {}, function(_, result) got = result end)
check('install: rename result rewritten for the given handler', got.documentChanges[1].textDocument.version == 9, vim.inspect(got))
got = nil
fake.handlers['textDocument/rename'] = function(_, result) got = result end
fake:request('textDocument/rename', {}, nil)
check('install: nil handler resolves to the client handler table', got and got.documentChanges[1].textDocument.version == 9)
got = nil
fake:request('workspace/willRenameFiles', {}, function(_, result) got = result end)
check('install: willRenameFiles result rewritten', got.documentChanges[1].textDocument.version == 9)
got = nil
fake:request('codeAction/resolve', {}, function(_, result) got = result end)
check('install: resolved code action rewritten', got.edit.documentChanges[1].textDocument.version == 9)
got = nil
fake:request('textDocument/codeAction', {}, function(_, result) got = result end)
check('install: code action list rewritten, commands skipped',
  got[1].command == 'noop' and got[2].edit.documentChanges[1].textDocument.version == 9)
got = nil
fake:request('textDocument/hover', {}, function(_, result) got = result end)
check('install: other methods pass straight through', seen.requested == 'textDocument/hover' and got.untouched and got.version == 2)
versions.reset(902)
check('reset: ledger gone', versions.translate(902, URI, 2) == 2)

-- ---------------------------------------------------------------------------
-- Standard LSP the server offers and Neovim leaves off (editor.lua)
-- ---------------------------------------------------------------------------
-- Document highlight, signature help on `(`/`,`, hierarchy keymaps, formatting and symbol search
-- are all advertised by the real server and implemented by Neovim, and nothing between the two
-- ever requested them. Driven through the real `on_attach` against a faux server that advertises
-- exactly the capabilities the real one does.
local editor = require('intellij-lsp.editor')

local ed_buf = vim.api.nvim_create_buf(false, true)
vim.api.nvim_set_current_buf(ed_buf)
vim.bo[ed_buf].filetype = 'java'
vim.bo[ed_buf].buftype = ''

local function editor_server(dispatch)
  return {
    request = function(method, _, callback)
      if method == 'initialize' then
        callback(nil, { capabilities = {
          documentHighlightProvider = true,
          signatureHelpProvider = { triggerCharacters = { '(', ',' }, retriggerCharacters = { ',' } },
          typeHierarchyProvider = true,
          callHierarchyProvider = true,
          workspaceSymbolProvider = { workDoneProgress = true },
          documentFormattingProvider = true,
        } })
      elseif method == 'shutdown' then
        callback(nil, nil)
      end
      return true, 1
    end,
    notify = function(method)
      if method == 'exit' then dispatch.on_exit(0, 0) end
      return true
    end,
    is_closing = function() return false end,
    terminate = function() end,
  }
end

local ed_cfg = client.config('/tmp/ijtest', { format_on_save = true })
local ed_id = vim.lsp.start(
  vim.tbl_extend('force', ed_cfg, { name = 'faux-intellij-editor', cmd = editor_server, root_dir = '/tmp' }),
  { bufnr = ed_buf }
)
local ed_client = ed_id and vim.lsp.get_client_by_id(ed_id)
vim.wait(2000, function() return ed_client and ed_client.initialized end)

local function has_autocmd(group, event)
  local ok, cmds = pcall(vim.api.nvim_get_autocmds, { group = group, event = event, buffer = ed_buf })
  return ok and #cmds > 0
end
-- `vim.keymap.set` expands `<leader>` at mapping time, so match on the tail of the lhs.
local function has_map(lhs)
  local tail = lhs:gsub('^<leader>', '')
  for _, m in ipairs(vim.api.nvim_buf_get_keymap(ed_buf, 'n')) do
    if m.lhs:sub(-#tail) == tail and (m.desc or ''):find('^IntelliJ: ') then return true end
  end
  return false
end

if not (ed_client and ed_client.initialized) then
  check('editor client starts', false, 'client did not initialize')
else
  check('document highlight requested on CursorHold', has_autocmd('IntellijLspDocumentHighlight' .. ed_buf, 'CursorHold'))
  check('document highlight cleared on CursorMoved', has_autocmd('IntellijLspDocumentHighlight' .. ed_buf, 'CursorMoved'))
  check('signature help hooks InsertCharPre', has_autocmd('IntellijLspSignatureHelp' .. ed_buf, 'InsertCharPre'))
  check('format_on_save hooks BufWritePre', has_autocmd('IntellijLspFormatOnSave' .. ed_buf, 'BufWritePre'))
  check('type hierarchy keymaps', has_map('<leader>ts') and has_map('<leader>tu'))
  check('call hierarchy keymaps', has_map('<leader>ci') and has_map('<leader>co'))
  check('workspace symbol keymap', has_map('<leader>ws'))

  -- CursorHold asks for the highlight; the request itself is Neovim's, so stub the entry point.
  local highlighted, cleared = 0, 0
  local real_dh, real_cr = vim.lsp.buf.document_highlight, vim.lsp.buf.clear_references
  vim.lsp.buf.document_highlight = function() highlighted = highlighted + 1 end
  vim.lsp.buf.clear_references = function() cleared = cleared + 1 end
  vim.api.nvim_exec_autocmds('CursorHold', { buffer = ed_buf })
  vim.api.nvim_exec_autocmds('CursorMoved', { buffer = ed_buf })
  vim.lsp.buf.document_highlight, vim.lsp.buf.clear_references = real_dh, real_cr
  check('CursorHold highlights, CursorMoved clears', highlighted == 1 and cleared == 1, highlighted .. '/' .. cleared)

  -- Typing `(` or `,` opens the signature popup; typing a letter does not. `v:char` is what
  -- InsertCharPre reads, and it is writable outside the event, so the event is raised by hand
  -- rather than through insert mode, which swallows headless output.
  local sig_calls = 0
  local real_sh = vim.lsp.buf.signature_help
  vim.lsp.buf.signature_help = function() sig_calls = sig_calls + 1 end
  local function type_char(c)
    vim.v.char = c
    vim.api.nvim_exec_autocmds('InsertCharPre', { buffer = ed_buf })
    vim.wait(100, function() return false end)
  end
  type_char('(')
  check('`(` triggers signature help', sig_calls == 1, tostring(sig_calls))
  type_char('x')
  check('a letter does not', sig_calls == 1, tostring(sig_calls))
  type_char(',')
  check('`,` retriggers', sig_calls == 2, tostring(sig_calls))
  vim.lsp.buf.signature_help = real_sh

  -- `keymaps = false` keeps the <leader> namespace untouched but leaves the features reachable.
  local plain = vim.api.nvim_create_buf(false, true)
  vim.bo[plain].filetype = 'java'
  editor.setup_keymaps(ed_client, plain, { keymaps = false })
  check('keymaps = false installs nothing', #vim.api.nvim_buf_get_keymap(plain, 'n') == 0)
  editor.setup_document_highlight(ed_client, plain, { document_highlight = false })
  check('document_highlight = false installs nothing', not (function()
    local ok, cmds = pcall(vim.api.nvim_get_autocmds, { group = 'IntellijLspDocumentHighlight' .. plain })
    return ok and #cmds > 0
  end)())

  vim.lsp.stop_client(ed_id, true)
end

-- The commands exist independently of any attached buffer.
editor.register_commands()
local cmds = vim.api.nvim_get_commands({})
for _, name in ipairs({ 'IntellijLspTypeHierarchy', 'IntellijLspCallHierarchy', 'IntellijLspFormat', 'IntellijLspSymbols' }) do
  check(':' .. name .. ' registered', cmds[name] ~= nil)
end
check(':IntellijLspFormat takes a range', cmds.IntellijLspFormat.range ~= nil and cmds.IntellijLspFormat.range ~= '')

-- Direction arguments are validated rather than passed through to a confusing LSP error.
local real_th = vim.lsp.buf.typehierarchy
local th_kind
vim.lsp.buf.typehierarchy = function(k) th_kind = k end
editor.type_hierarchy('')
check('type hierarchy defaults to subtypes', th_kind == 'subtypes', tostring(th_kind))
editor.type_hierarchy('supertypes')
check('type hierarchy forwards supertypes', th_kind == 'supertypes')
th_kind = nil
editor.type_hierarchy('sideways')
check('type hierarchy rejects an unknown direction', th_kind == nil)
vim.lsp.buf.typehierarchy = real_th

local real_in, real_out = vim.lsp.buf.incoming_calls, vim.lsp.buf.outgoing_calls
local ch_kind
vim.lsp.buf.incoming_calls = function() ch_kind = 'incoming' end
vim.lsp.buf.outgoing_calls = function() ch_kind = 'outgoing' end
editor.call_hierarchy(nil)
check('call hierarchy defaults to incoming', ch_kind == 'incoming')
editor.call_hierarchy('outgoing')
check('call hierarchy forwards outgoing', ch_kind == 'outgoing')
vim.lsp.buf.incoming_calls, vim.lsp.buf.outgoing_calls = real_in, real_out

-- Formatting is pinned to our client by name, so a second formatter on the buffer is left alone.
local real_fmt = vim.lsp.buf.format
local fmt_opts
vim.lsp.buf.format = function(o) fmt_opts = o end
editor.format({ bufnr = ed_buf })
check('format addresses the intellij client only', fmt_opts and fmt_opts.name == 'intellij' and fmt_opts.range == nil, vim.inspect(fmt_opts))
vim.api.nvim_buf_set_lines(ed_buf, 0, -1, false, { 'a', 'bb', 'ccc' })
editor.format({ bufnr = ed_buf, line1 = 2, line2 = 3 })
check('format with a range covers the given lines', fmt_opts.range and fmt_opts.range['start'][1] == 2 and fmt_opts.range['end'][1] == 3 and fmt_opts.range['end'][2] == 3, vim.inspect(fmt_opts and fmt_opts.range))
vim.lsp.buf.format = real_fmt

-- asIs snippet completions: the line's own indentation comes off every continuation line, because
-- vim.snippet.expand adds it back. Plain-text, single-line and adjustIndentation items are untouched.
local ai_buf = vim.api.nvim_create_buf(false, true)
vim.api.nvim_buf_set_lines(ai_buf, 0, -1, false, { '\t\towner.getPets().for' })
local function ai_item(mode, fmt, text)
  return { insertTextMode = mode, insertTextFormat = fmt, textEdit = { newText = text,
    range = { start = { line = 0, character = 2 }, ['end'] = { line = 0, character = 19 } } } }
end
local ai_result = { items = {
  ai_item(1, 2, 'for (Pet ${1:pet} : owner.getPets()) {\n\t\t\t${0}\n\t\t\\}'),
  ai_item(1, 1, 'a\n\t\tb'),
  ai_item(2, 2, 'a\n\t\tb'),
  ai_item(1, 2, 'one line'),
  ai_item(1, 2, 'a\n\tshallower'),
} }
client.rebase_as_is_indent(ai_result, ai_buf)
local ai = vim.tbl_map(function(i) return i.textEdit.newText end, ai_result.items)
check('asIs snippet loses the base indent once', ai[1] == 'for (Pet ${1:pet} : owner.getPets()) {\n\t${0}\n\\}', ai[1])
check('asIs plain text is left alone', ai[2] == 'a\n\t\tb', ai[2])
check('adjustIndentation is left alone', ai[3] == 'a\n\t\tb', ai[3])
check('single-line snippet is left alone', ai[4] == 'one line', ai[4])
check('a line shallower than the base is left alone', ai[5] == 'a\n\tshallower', ai[5])
local ai_default = { itemDefaults = { insertTextMode = 1 }, items = { ai_item(nil, 2, 'x\n\t\t\ty') } }
client.rebase_as_is_indent(ai_default, ai_buf)
check('asIs from itemDefaults counts', ai_default.items[1].textEdit.newText == 'x\n\ty', ai_default.items[1].textEdit.newText)

-- The response fixes run on callers' own callbacks, which is how vim.lsp.completion and 0.12's
-- vim.lsp.codelens call: a handler-table entry would never see those responses.
local rf_replies = {
  ['textDocument/codeLens'] = { { range = {}, command = { title = '$(play) Run' } } },
  ['textDocument/hover'] = { contents = '$(play) untouched' },
}
local rf_client = { handlers = {}, request = function(_, method, _, h) h(nil, rf_replies[method], {}) return true, 1 end }
client.install_response_fixes(rf_client)
local rf_lens, rf_hover
rf_client:request('textDocument/codeLens', {}, function(_, r) rf_lens = r end, 0)
rf_client:request('textDocument/hover', {}, function(_, r) rf_hover = r end, 0)
check('lens codicons stripped on a caller callback', rf_lens and rf_lens[1].command.title == 'Run', vim.inspect(rf_lens))
local function rng(l, a, b) return { start = { line = l, character = a }, ['end'] = { line = l, character = b } } end
local calls = { { from = { name = 'f' }, fromRanges = { rng(66, 6, 35), rng(66, 6, 35), rng(70, 1, 2), rng(66, 6, 35) } } }
client.dedupe_call_ranges(calls)
check('call hierarchy keeps one row per call site', #calls[1].fromRanges == 2 and calls[1].fromRanges[2].start.line == 70, vim.inspect(calls[1].fromRanges))
check('other methods pass through untouched', rf_hover and rf_hover.contents == '$(play) untouched', vim.inspect(rf_hover))

-- Debug panel labels: no doubled `:98` on a frame whose name already carries it, no `:0` on the
-- hidden-frames placeholder, no leading spaces before the type of a value-less variable.
local dbg = require('intellij-lsp.debug')
check('frame label keeps the adapter location', dbg._frame_label({ name = 'at a.B.c(B.java:98)', line = 98 }) == 'at a.B.c(B.java:98)', dbg._frame_label({ name = 'at a.B.c(B.java:98)', line = 98 }))
check('frame label drops line 0', dbg._frame_label({ name = '53 hidden frames', line = 0 }) == '53 hidden frames', dbg._frame_label({ name = '53 hidden frames', line = 0 }))
check('frame label appends a missing line', dbg._frame_label({ name = 'main', line = 7 }) == 'main:7', dbg._frame_label({ name = 'main', line = 7 }))
check('value-less variable shows only its type', dbg._format_value({ value = ' ', type = 'Owner@1' }) == '(Owner@1)', dbg._format_value({ value = ' ', type = 'Owner@1' }))
check('value and type', dbg._format_value({ value = '1', type = 'int' }) == '1  (int)', dbg._format_value({ value = '1', type = 'int' }))

-- ---------------------------------------------------------------------------
-- Licensing protocol: capability, state store, requests, projection
-- ---------------------------------------------------------------------------
-- A function of its own: the main chunk is at Lua's limit of 200 locals.
;(function()
local licensing = require('intellij-lsp.licensing')

-- The capability that turns on the state pushes, and the one the sign-in page relies on.
check('experimental.licensingUi = true', caps.experimental and caps.experimental.licensingUi == true, vim.inspect(caps.experimental))
check('window.showDocument.support = true', vim.tbl_get(caps, 'window', 'showDocument', 'support') == true,
  vim.inspect(caps.window.showDocument))
check('client config handles the state push',
  type(client.config('/tmp/ijtest', {}).handlers[licensing.STATE]) == 'function')

-- Captured from 263.7084.0 (`license status --json`, 2026-10-20): this machine's trial, and an empty
-- license dir.
local CAPTURED_TRIAL = vim.json.decode([[{"activeLicense": {"source": "trial", "status": "Valid", "product": "intellij-server", "daysLeft": 27, "validThrough": "2026-11-17"}, "jbaLicensingState": {"authenticationStatus": "NotAuthenticated"}, "licenseServerFlowState": {"kind": "notConfigured"}, "featuresDeclined": false}]])
local CAPTURED_PARKED = vim.json.decode([[{"jbaLicensingState": {"authenticationStatus": "NotAuthenticated"}, "licenseServerFlowState": {"kind": "notConfigured"}, "featuresDeclined": true, "parkedReason": "StartedUnlicensed"}]])

-- Shaped after the server's licensing state, for the states a fresh store cannot reach.
local function lstate(t)
  return vim.tbl_extend('force', {
    jbaLicensingState = { authenticationStatus = 'NotAuthenticated' },
    licenseServerFlowState = { kind = 'notConfigured' },
    featuresDeclined = false,
  }, t)
end
local SUB = { kind = 'Subscription', licensedTo = 'Ada Lovelace', product = 'intellij-server', validThrough = '2027-01-31',
  licenseId = 'LIC123', assetId = 'asset-1', status = 'Valid' }
local DEADLINE = 1792000000000

local v = licensing.project(CAPTURED_TRIAL)
check('trial: licensed', v.kind == 'licensed', vim.inspect(v))
check('trial: display fields', v.source == 'trial' and v.source_label == 'Trial' and v.holder == 'Trial User'
  and v.days_left == 27 and v.valid_through == '2026-11-17' and v.product == 'Java and Kotlin by IntelliJ IDEA', vim.inspect(v))
check('trial: message', v.message == 'License is active (Trial)', v.message)

v = licensing.project(CAPTURED_PARKED)
check('empty store: parked StartedUnlicensed', v.kind == 'parked' and v.parked_reason == 'StartedUnlicensed', vim.inspect(v))
check('empty store: no license fields', v.source == nil and v.days_left == nil and #v.subscriptions == 0, vim.inspect(v))
check('empty store: message says to activate', v.message:find('^No active license%. Activate') ~= nil, v.message)

v = licensing.project(lstate({ activeLicense = { source = 'trial', status = 'Expired', product = 'intellij-server', daysLeft = 0, validThrough = '2026-10-19' },
  graceDeadline = DEADLINE }))
check('expired with a deadline: grace', v.kind == 'grace' and v.grace_deadline == DEADLINE, vim.inspect(v))
check('grace message names the time', v.message:find(licensing.format_deadline(DEADLINE), 1, true) ~= nil
  and v.message:find('^License Expired') ~= nil, v.message)
check('expired: days left 0 is shown', v.days_left == 0, vim.inspect(v.days_left))

v = licensing.project(lstate({ activeLicense = CAPTURED_TRIAL.activeLicense, graceDeadline = DEADLINE }))
check('grace deadline next to a valid license is ignored', v.kind == 'licensed' and v.grace_deadline == nil, vim.inspect(v))

v = licensing.project(lstate({ activeLicense = { source = 'trial', status = 'Expired', product = 'intellij-server' },
  featuresDeclined = true, parkedReason = 'GraceExpired' }))
check('parked after grace', v.kind == 'parked' and v.parked_reason == 'GraceExpired', vim.inspect(v))
check('parked after grace: message', v.message == 'License Expired: Java and Kotlin by IntelliJ IDEA. The grace period has ended. '
  .. 'Activate a license to use Java and Kotlin features.', v.message)
v = licensing.project(lstate({ featuresDeclined = true, parkedReason = 'LicenseRemoved' }))
check('parked after removal: message', v.message:find('^The license was removed%. Activate another') ~= nil, v.message)

-- A subscription carries its license id only in the account's subscription list.
v = licensing.project(lstate({
  activeLicense = { source = 'subscription', status = 'Valid', product = 'intellij-server', licensedTo = 'Ada Lovelace',
    daysLeft = 102, validThrough = '2027-01-31', assetId = 'asset-1' },
  jbaLicensingState = { authenticationStatus = 'Authenticated', accountInfo = { displayName = 'Ada', email = 'ada@example.com' },
    availableSubscriptions = { SUB } },
}))
check('subscription: licensed by the account', v.kind == 'licensed' and v.source_label == 'JetBrains Account'
  and v.holder == 'Ada Lovelace', vim.inspect(v))
check('subscription: license id from the account list', v.license_id == 'LIC123', vim.inspect(v.license_id))
check('subscription: account and list', v.account and v.account.display_name == 'Ada' and v.account.email == 'ada@example.com'
  and v.subscriptions[1].asset_id == 'asset-1' and v.subscriptions[1].product == 'Java and Kotlin by IntelliJ IDEA', vim.inspect(v))

v = licensing.project(lstate({
  activeLicense = { source = 'subscription', status = 'Valid', product = 'intellij-server', licensedTo = 'Ada', assetId = 'asset-1' },
  jbaLicensingState = { authenticationStatus = 'FailedToProlongateAuthentication', accountInfo = { displayName = 'Ada' }, errorMessage = 'x' },
}))
check('valid license, session not prolonged: session-expired', v.kind == 'session-expired'
  and v.message:find('session expired') ~= nil and v.account.display_name == 'Ada', vim.inspect(v))

v = licensing.project(lstate({ jbaLicensingState = { authenticationStatus = 'Authenticating' }, featuresDeclined = true,
  parkedReason = 'StartedUnlicensed' }))
check('sign-in under way: authenticating, before parked', v.kind == 'authenticating' and v.authenticating == 'account', vim.inspect(v))
v = licensing.project(lstate({ activeLicense = CAPTURED_TRIAL.activeLicense, jbaLicensingState = { authenticationStatus = 'Authenticating' } }))
check('sign-in under a valid trial stays licensed', v.kind == 'licensed', v.kind)

v = licensing.project(lstate({ licenseServerFlowState = { kind = 'configured', serverAddress = 'https://fls.example.com',
  status = 'Unknown', floatingTicketStatus = 'Obtaining' } }))
check('license server ticket requested: authenticating', v.kind == 'authenticating' and v.authenticating == 'licenseServer'
  and v.server_address == 'https://fls.example.com' and v.message:find('fls.example.com', 1, true) ~= nil, vim.inspect(v))

v = licensing.project(lstate({ licenseServerFlowState = { kind = 'configured', serverAddress = 'https://fls.example.com',
  status = 'Expired', floatingTicketStatus = 'FailedToRefresh' }, featuresDeclined = true, parkedReason = 'GraceExpired' }))
check('license server refresh failed: fallback error', v.kind == 'parked' and v.error and v.error:find('^Lost connection') ~= nil, vim.inspect(v))
v = licensing.project(lstate({ licenseServerFlowState = { kind = 'configured', serverAddress = 'https://fls.example.com',
  status = 'Unknown', floatingTicketStatus = 'NotObtained', errorMessage = '  No free seats  ' } }))
check('license server error message is trimmed', v.error == 'No free seats', vim.inspect(v.error))
v = licensing.project(lstate({ jbaLicensingState = { authenticationStatus = 'FailedToAuthenticate', availableSubscriptions = { SUB },
  errorMessage = 'raw backend text' } }))
check('sign-in failed: fixed sentence, not the raw message', v.error and v.error:find("^Couldn't sign in") ~= nil
  and #v.subscriptions == 1, vim.inspect(v))

v = licensing.project(lstate({ activeLicense = { source = 'activationCode', status = 'Invalid', product = 'intellij-server',
  licensedTo = 'Ada', licenseId = 'AC1' } }))
check('invalid code, not yet parked: unlicensed', v.kind == 'unlicensed' and v.license_id == 'AC1'
  and v.message == 'License Invalid: Java and Kotlin by IntelliJ IDEA', vim.inspect(v))

v = licensing.project(lstate({ activeLicense = { source = 'eap', status = 'Valid', product = 'intellij-server', daysLeft = 0 } }))
check('eap: 0 days without an end date is not counted down', v.kind == 'licensed' and v.days_left == nil
  and v.holder == 'Early Access Program' and v.message == 'EAP license is active', vim.inspect(v))
v = licensing.project(lstate({ activeLicense = { source = 'licenseServer', status = 'Valid', product = 'goland',
  serverAddress = 'https://fls.example.com' } }))
check('license server: holder is the address, unknown product kept', v.holder == 'https://fls.example.com' and v.product == 'goland', vim.inspect(v))

-- A null that does arrive must read as missing, not as a truthy vim.NIL.
v = licensing.project(lstate({ activeLicense = vim.NIL, graceDeadline = vim.NIL, parkedReason = vim.NIL }))
check('null fields read as missing', v.kind == 'unlicensed' and v.source == nil and v.grace_deadline == nil, vim.inspect(v))

-- Store: one copy per client, an event on change only, dropped on exit.
do
  local events = {}
  local au = vim.api.nvim_create_autocmd('User', {
    pattern = licensing.EVENT,
    callback = function(ev) table.insert(events, ev.data) end,
  })
  local push = licensing.handlers()[licensing.STATE]
  push(nil, CAPTURED_PARKED, { client_id = 9001 })
  check('push stored', licensing.state(9001) and licensing.state(9001).parkedReason == 'StartedUnlicensed')
  check('push fires the event with the view', #events == 1 and events[1].client_id == 9001 and events[1].view.kind == 'parked',
    vim.inspect(events))
  push(nil, vim.deepcopy(CAPTURED_PARKED), { client_id = 9001 })
  check('an identical push fires nothing', #events == 1, #events)
  push(nil, lstate({ activeLicense = CAPTURED_TRIAL.activeLicense, graceDeadline = DEADLINE }), { client_id = 9001 })
  check('a changed push fires again', #events == 2 and events[2].view.kind == 'licensed', vim.inspect(events[2]))
  check('stored state drops a grace deadline next to a valid license', licensing.state(9001).graceDeadline == nil,
    vim.inspect(licensing.state(9001)))
  check('other clients are separate', licensing.state(9002) == nil and licensing.view(9002) == nil)
  licensing.reset(9001)
  check('reset drops the state', licensing.state(9001) == nil)
  check('reset fires the event without a view', #events == 3 and events[3].client_id == 9001 and events[3].view == nil, vim.inspect(events[3]))
  licensing.reset(9001)
  check('a second reset fires nothing', #events == 3, #events)
  vim.api.nvim_del_autocmd(au)
end

-- Requests: gated on the server's capability, one parameter each where taken, a timeout.
do
  local sent, cancelled = {}, {}
  local pending = {}
  local function fake(id, supported)
    return {
      id = id,
      server_capabilities = { experimental = { licensing = supported } },
      request = function(_, method, params, handler)
        table.insert(sent, { method = method, params = params })
        pending[#sent] = handler
        return true, #sent
      end,
      cancel_request = function(_, rid) table.insert(cancelled, rid) end,
    }
  end

  local got
  licensing.request(fake(9010, false), 'state/get', nil, function(err) got = err end)
  vim.wait(500, function() return got ~= nil end, 10)
  check('no licensing on a server without the capability', #sent == 0 and got and got.message:find('does not support') ~= nil, vim.inspect(got))
  check('supported reads the server capability', licensing.supported(fake(1, true)) and not licensing.supported(fake(1, nil))
    and not licensing.supported(nil))

  local c = fake(9011, true)
  licensing.request(c, 'subscriptions/use', 'asset-1', function() end)
  check('request goes to jetbrains/licensing/', sent[1].method == 'jetbrains/licensing/subscriptions/use', sent[1].method)
  check('the single parameter is named', sent[1].params.assetId == 'asset-1', vim.inspect(sent[1].params))
  licensing.request(c, 'trial/startAnonymous', nil, function() end)
  check('a parameterless request sends an empty object', vim.json.encode(sent[2].params) == '{}', vim.json.encode(sent[2].params))
  check('a missing parameter is a programming error', not pcall(licensing.request, c, 'activationCode/use', nil, function() end))
  check('an unknown request is a programming error', not pcall(licensing.request, c, 'trial/start', nil, function() end))
  check('login waits out the server sign-in', licensing.REQUESTS['jba/login'].timeout == 310000
    and licensing.REQUESTS['licenseServer/add'].timeout == 360000 and licensing.REQUESTS['jba/logout'].timeout == 30000)

  -- Answered: the callback runs once, and a late timeout does not run it again.
  local calls = {}
  licensing.REQUESTS['state/get'].timeout = 50
  licensing.request(c, 'state/get', nil, function(err, result) table.insert(calls, { err = err, result = result }) end)
  pending[#sent](nil, CAPTURED_TRIAL, {})
  vim.wait(150, function() return false end, 10)
  check('an answered request calls back once', #calls == 1 and calls[1].result == CAPTURED_TRIAL and #cancelled == 0, vim.inspect(calls))

  -- Unanswered: a timeout error, the request cancelled, and the late reply ignored.
  calls = {}
  licensing.request(c, 'state/get', nil, function(err, result) table.insert(calls, { err = err, result = result }) end)
  local rid = #sent
  vim.wait(1000, function() return #calls > 0 end, 10)
  check('an unanswered request times out', #calls == 1 and calls[1].err and calls[1].err.code == licensing.TIMED_OUT, vim.inspect(calls))
  check('the timed-out request is cancelled', cancelled[1] == rid, vim.inspect(cancelled))
  pending[rid](nil, CAPTURED_TRIAL, {})
  check('a reply after the timeout is ignored', #calls == 1, #calls)

  -- refresh: the reply is recorded, unless a push overtook it.
  local view
  licensing.refresh(c, function(_, vw) view = vw end)
  pending[#sent](nil, CAPTURED_TRIAL, {})
  check('refresh records the reply', view and view.kind == 'licensed' and licensing.state(9011) ~= nil, vim.inspect(view))
  licensing.refresh(c, function(_, vw) view = vw end)
  local in_flight = #sent
  licensing.handlers()[licensing.STATE](nil, CAPTURED_PARKED, { client_id = 9011 })
  pending[in_flight](nil, CAPTURED_TRIAL, {})
  check('a push during state/get wins over the reply', view and view.kind == 'parked', vim.inspect(view))
  licensing.REQUESTS['state/get'].timeout = 10000
  licensing.reset(9011)
end

-- Environment licenses: the server's own, which nothing activated here overrides.
check('no environment license', licensing.environment_license({ HOME = '/home/x' }) == nil
  and licensing.environment_license(nil) == nil)
check('a blank variable is no environment license', licensing.environment_license({ INTELLIJ_SERVER_LICENSE = '  ' }) == nil)
check('INTELLIJ_SERVER_LICENSE_FILE is an environment license',
  licensing.environment_license({ INTELLIJ_SERVER_LICENSE_FILE = '/etc/key' }) == 'INTELLIJ_SERVER_LICENSE_FILE')
check('JETBRAINS_LICENSE_SERVER is an environment license',
  licensing.environment_license({ JETBRAINS_LICENSE_SERVER = 'https://fls.example' }) == 'JETBRAINS_LICENSE_SERVER')
check('the environment message names the variable and the restart',
  licensing.environment_message('INTELLIJ_SERVER_LICENSE'):find('INTELLIJ_SERVER_LICENSE, which overrides', 1, true) ~= nil
  and licensing.environment_message('INTELLIJ_SERVER_LICENSE'):find(':IntellijLspRestart', 1, true) ~= nil)

-- Startup: state/get, discovery when there is no license, one activation offer per session.
do
  local sent, offers = {}, {}
  local orig_offer = licensing.offer_activation
  licensing.offer_activation = function(c, view, env_var)
    table.insert(offers, { id = c.id, kind = view.kind, env_var = env_var })
  end
  licensing._reset_session()

  --- Answers each request with `replies[method]`; a function reply runs first (to push) and returns
  --- the result.
  local function fake(id, replies, env)
    return {
      id = id,
      server_capabilities = { experimental = { licensing = true } },
      config = { server_cmd = { '/b/bin/intellij-server' }, cmd_env = env or {} },
      request = function(_, method, _, handler)
        local name = method:gsub('^jetbrains/licensing/', '')
        table.insert(sent, { id = id, name = name })
        local reply = replies[name]
        vim.schedule(function()
          if type(reply) == 'function' then reply = reply() end
          handler(nil, reply, {})
        end)
        return true, #sent
      end,
      cancel_request = function() end,
    }
  end
  local function names(id)
    local out = {}
    for _, s in ipairs(sent) do if s.id == id then table.insert(out, s.name) end end
    return table.concat(out, ',')
  end
  local function run(c)
    local done, view = false, nil
    licensing.startup(c, function(vw) done, view = true, vw end)
    vim.wait(1000, function() return done end, 5)
    return done, view
  end

  local done, view = run(fake(9101, { ['state/get'] = CAPTURED_TRIAL }))
  check('startup: a licensed server only gets state/get', done and names(9101) == 'state/get' and #offers == 0,
    names(9101) .. ' ' .. vim.inspect(offers))
  check('startup: the state is recorded', view and view.kind == 'licensed', vim.inspect(view))

  done, view = run(fake(9102, { ['state/get'] = CAPTURED_PARKED, ['discovery/autoActivate'] = { activated = false } }))
  check('startup: no license -> discovery/autoActivate', names(9102) == 'state/get,discovery/autoActivate', names(9102))
  check('startup: still parked -> the activation is offered', #offers == 1 and offers[1].id == 9102
    and offers[1].kind == 'parked' and offers[1].env_var == nil, vim.inspect(offers))

  run(fake(9103, { ['state/get'] = CAPTURED_PARKED, ['discovery/autoActivate'] = { activated = false } }))
  check('startup: a second unlicensed root still syncs', names(9103) == 'state/get,discovery/autoActivate', names(9103))
  check('startup: but the activation is offered once per session', #offers == 1, vim.inspect(offers))
  licensing.offer_withdrawn()
  run(fake(9104, { ['state/get'] = CAPTURED_PARKED, ['discovery/autoActivate'] = { activated = false } }))
  check('startup: an offer withdrawn before it showed is made again', #offers == 2 and offers[2].id == 9104,
    vim.inspect(offers))

  licensing._reset_session()
  offers = {}
  done, view = run(fake(9104, {
    ['state/get'] = CAPTURED_PARKED,
    ['discovery/autoActivate'] = function()
      -- The server pushes the activated state before it replies.
      licensing.handlers()[licensing.STATE](nil, CAPTURED_TRIAL, { client_id = 9104 })
      return { activated = true, source = 'toolbox' }
    end,
  }))
  check('startup: discovery found a license -> nothing offered', #offers == 0 and view and view.kind == 'licensed',
    vim.inspect(offers) .. ' ' .. vim.inspect(view))

  local EXPIRED = lstate({ activeLicense = vim.tbl_extend('force', SUB, { status = 'Expired' }), featuresDeclined = true,
    parkedReason = 'GraceExpired' })
  run(fake(9105, { ['state/get'] = EXPIRED }, { JETBRAINS_LICENSE_SERVER = 'https://fls.example' }))
  check('startup: an existing license skips discovery', names(9105) == 'state/get', names(9105))
  check('startup: an environment license is named in the offer', #offers == 1 and offers[1].env_var == 'JETBRAINS_LICENSE_SERVER',
    vim.inspect(offers))

  licensing._reset_session()
  offers = {}
  run(fake(9106, { ['state/get'] = lstate({ graceDeadline = DEADLINE, featuresDeclined = false }) }))
  check('startup: a grace period is not offered', #offers == 0, vim.inspect(offers))

  local plain = fake(9107, {})
  plain.server_capabilities = {}
  done = run(plain)
  check('startup: a server without the protocol gets nothing', done and names(9107) == '', names(9107))

  -- A slow discovery shows "Checking license…" and closes it with the outcome.
  local echoes = {}
  local orig_echo = vim.api.nvim_echo
  vim.api.nvim_echo = function(chunks, _, opts)
    table.insert(echoes, { text = chunks[1][1], status = opts.status, id = opts.id })
    return 77
  end
  licensing.DISCOVERY_PROGRESS_DELAY = 10
  local slow = fake(9108, { ['state/get'] = CAPTURED_PARKED })
  local discovery_reply
  local request = slow.request
  slow.request = function(self, method, params, handler)
    if method:find('autoActivate') then
      table.insert(sent, { id = 9108, name = 'discovery/autoActivate' })
      discovery_reply = handler
      return true, #sent
    end
    return request(self, method, params, handler)
  end
  licensing.startup(slow)
  vim.wait(1000, function() return #echoes > 0 end, 5)
  check('startup: a slow discovery shows Checking license…', echoes[1] and echoes[1].text == 'Checking license…'
    and echoes[1].status == 'running', vim.inspect(echoes))
  if discovery_reply then discovery_reply(nil, { activated = false }, {}) end
  check('startup: and closes it with the outcome', echoes[2] and echoes[2].id == 77 and echoes[2].text == 'No license found'
    and echoes[2].status == 'failed', vim.inspect(echoes))

  echoes = {}
  licensing.DISCOVERY_PROGRESS_DELAY = 100
  run(fake(9109, { ['state/get'] = CAPTURED_PARKED, ['discovery/autoActivate'] = { activated = false } }))
  vim.wait(200, function() return false end, 10)
  check('startup: a fast discovery shows nothing', #echoes == 0, vim.inspect(echoes))
  vim.api.nvim_echo = orig_echo
  licensing.DISCOVERY_PROGRESS_DELAY = 500

  for id = 9101, 9109 do licensing.reset(id) end
  licensing.offer_activation = orig_offer
  licensing._reset_session()
end

-- The interim offer names the CLI of the running bundle, or the variable that owns the license.
do
  local notified = {}
  local orig_notify = vim.notify
  vim.notify = function(msg, level) table.insert(notified, { msg = msg, level = level }) end
  local c = { config = { server_cmd = { '/b/bin/intellij-server' } } }
  licensing.offer_activation(c, licensing.project(CAPTURED_PARKED), nil)
  licensing.offer_activation(c, licensing.project(CAPTURED_PARKED), 'INTELLIJ_SERVER_LICENSE')
  vim.notify = orig_notify
  check('offer: warns with the state and the CLI', notified[1] and notified[1].level == vim.log.levels.WARN
    and notified[1].msg:find('No active license.', 1, true) ~= nil
    and notified[1].msg:find('/b/bin/intellij-server license trial', 1, true) ~= nil, vim.inspect(notified[1]))
  check('offer: with an environment license, says why instead', notified[2]
    and notified[2].msg:find('INTELLIJ_SERVER_LICENSE, which overrides', 1, true) ~= nil
    and notified[2].msg:find('license trial', 1, true) == nil, vim.inspect(notified[2]))
end
end)()

-- ---------------------------------------------------------------------------
-- Activation: the float, and the result mapping of each way to activate
-- ---------------------------------------------------------------------------
;(function()
local licensing = require('intellij-lsp.licensing')
local activation = require('intellij-lsp.activation')

local function lstate(t)
  return vim.tbl_extend('force', {
    jbaLicensingState = { authenticationStatus = 'NotAuthenticated' },
    licenseServerFlowState = { kind = 'notConfigured' },
    featuresDeclined = false,
  }, t)
end
local PARKED = lstate({ featuresDeclined = true, parkedReason = 'StartedUnlicensed' })
local TRIAL = { source = 'trial', status = 'Valid', product = 'intellij-server', daysLeft = 30, validThrough = '2026-11-19' }
local ACCOUNT = { authenticationStatus = 'Authenticated', accountInfo = { displayName = 'Ada' }, availableSubscriptions = {} }
local function sub(asset, status)
  return { kind = 'Subscription', licensedTo = 'Ada', product = 'intellij-server', validThrough = '2027-01-31',
    licenseId = 'L-' .. asset, assetId = asset, status = status or 'Valid' }
end

-- Menu entries
local function keys(actions) return table.concat(vim.tbl_map(function(a) return a.key end, actions)) end
check('activation: all four entries', keys(activation.actions({})) == '1234', keys(activation.actions({})))
check('activation: changing a license hides the trial', keys(activation.actions({ change = true })) == '123'
  and activation.actions({ change = true })[1].name == 'login')
check('activation: an environment license leaves the license server', keys(activation.actions({ environment = true })) == '1'
  and activation.actions({ environment = true })[1].name == 'server')
local lines, first = activation._lines(licensing.project(PARKED), activation.actions({}), 'INTELLIJ_SERVER_LICENSE')
check('activation: the float says what is wrong, why, then the entries',
  lines[1]:find('No active license', 1, true) and lines[2]:find('INTELLIJ_SERVER_LICENSE, which overrides', 1, true)
  and lines[3] == '' and first == 4 and lines[4] == ' 1  Start 30-day trial' and lines[5] == ' 2  Sign in with JetBrains Account' and lines[7] == ' 4  Use a license server',
  vim.inspect(lines))

check('activation: license server URLs', activation.valid_server_url('https://fls.example.com')
  and activation.valid_server_url('  HTTP://fls:8080/path ') and not activation.valid_server_url('fls.example.com')
  and not activation.valid_server_url('ftp://fls') and not activation.valid_server_url('https://')
  and not activation.valid_server_url('https://fls example'))
check('activation: a pasted code loses its line breaks and spaces', activation.clean_code(' ABC-\n DEF\r\n-GHI ') == 'ABC-DEF-GHI')

-- A fake server: `replies[name]` is the result, or a function of the params that may push first.
local sent, notified = {}, {}
local orig_notify = vim.notify
vim.notify = function(msg, level) table.insert(notified, { msg = msg, level = level }) end
local function fake(id, replies)
  local c = {
    id = id,
    server_capabilities = { experimental = { licensing = true } },
    config = { server_cmd = { '/b/bin/intellij-server' }, cmd_env = {} },
    is_stopped = function() return false end,
    cancel_request = function() end,
  }
  c.request = function(_, method, params, handler)
    local name = method:gsub('^jetbrains/licensing/', '')
    table.insert(sent, { id = id, name = name, params = params })
    local reply = replies[name]
    if reply == 'never' then return true, #sent end
    vim.schedule(function()
      local err
      if type(reply) == 'function' then reply, err = reply(params) end
      handler(err, reply, {})
    end)
    return true, #sent
  end
  return c
end
local function push(id, state) licensing.handlers()[licensing.STATE](nil, state, { client_id = id }) end
local function names(id)
  local out = {}
  for _, s in ipairs(sent) do if s.id == id then table.insert(out, s.name) end end
  return table.concat(out, ',')
end
local function result_of(fn, ...)
  local got
  local args = { ... }
  table.insert(args, function(ok, message) got = { ok = ok, message = message } end)
  fn(unpack(args))
  vim.wait(1000, function() return got ~= nil end, 5)
  return got or {}
end
local function last() return notified[#notified] or {} end

-- Trial
local c = fake(9201, { ['trial/startAnonymous'] = function() push(9201, lstate({ activeLicense = TRIAL })) return { isSuccess = true } end })
push(9201, PARKED)
local r = result_of(activation.trial, c)
check('trial: success reports the license now active', r.ok and last().msg == 'IntelliJ LSP: License is active (Trial)'
  and last().level == vim.log.levels.INFO, vim.inspect(notified))
check('trial: not signed in -> no sign-out', names(9201) == 'trial/startAnonymous', names(9201))

c = fake(9202, { ['trial/startAnonymous'] = function()
  push(9202, lstate({ activeLicense = TRIAL, jbaLicensingState = ACCOUNT }))
  return { isSuccess = true }
end, ['jba/logout'] = vim.NIL })
push(9202, lstate({ jbaLicensingState = ACCOUNT, featuresDeclined = true }))
r = result_of(activation.trial, c)
vim.wait(200, function() return names(9202):find('logout') ~= nil end, 5)
check('trial: signed in to an account -> signed out once the trial is valid', r.ok and names(9202) == 'trial/startAnonymous,jba/logout', names(9202))

c = fake(9203, { ['trial/startAnonymous'] = { isSuccess = false, errorMessage = ' Trial already used ' } })
r = result_of(activation.trial, c)
check('trial: refused -> the sentence and the server reason', not r.ok
  and r.message == "Couldn't start your trial. Try again. Trial already used" and last().level == vim.log.levels.ERROR, vim.inspect(r))

-- Activation code
c = fake(9204, { ['activationCode/use'] = false })
r = result_of(activation.use_code, c, 'BAD\nCODE')
check('code: rejected', not r.ok and r.message == activation.CODE_REJECTED, vim.inspect(r))
check('code: sent without whitespace', sent[#sent].params.activationCode == 'BADCODE', vim.inspect(sent[#sent].params))
c = fake(9205, { ['activationCode/use'] = function()
  push(9205, lstate({ activeLicense = { source = 'activationCode', status = 'Valid', product = 'intellij-server', licensedTo = 'Ada', licenseId = 'AC' },
    jbaLicensingState = ACCOUNT }))
  return true
end, ['jba/logout'] = vim.NIL })
r = result_of(activation.use_code, c, 'GOOD')
vim.wait(200, function() return names(9205):find('logout') ~= nil end, 5)
check('code: accepted, and the account signed out', r.ok and names(9205) == 'activationCode/use,jba/logout'
  and last().msg:find('Activation Code', 1, true), names(9205) .. ' ' .. vim.inspect(last()))
local before = #sent
r = result_of(activation.use_code, c, ' \n ')
check('code: an empty code sends nothing', not r.ok and #sent == before)

-- License server
c = fake(9206, {})
r = result_of(activation.add_server, c, 'fls.example.com')
check('server: a URL without a scheme is not sent', not r.ok and r.message == activation.SERVER_URL_INVALID and names(9206) == '')
local function server(id, reply, pre)
  local fc = fake(id, { ['licenseServer/add'] = reply, ['jba/logout'] = vim.NIL })
  if pre then push(id, pre) end
  return result_of(activation.add_server, fc, ' https://fls.example.com ')
end
local LS = { source = 'licenseServer', status = 'Valid', product = 'intellij-server', serverAddress = 'https://fls.example.com' }
r = server(9207, function(params)
  push(9207, lstate({ activeLicense = LS, licenseServerFlowState = { kind = 'configured', serverAddress = params.serverAddress,
    status = 'Valid', floatingTicketStatus = 'Obtained' } }))
  return { status = 'Connected' }
end)
check('server: connected', r.ok and sent[#sent].params.serverAddress == 'https://fls.example.com', vim.inspect(r))
r = server(9208, function()
  push(9208, lstate({ licenseServerFlowState = { kind = 'configured', serverAddress = 'https://fls.example.com', status = 'Unknown',
    floatingTicketStatus = 'NotObtained', errorMessage = 'No free seats' } }))
  return { status = 'Connected' }
end)
check('server: connected but refused -> the server error', not r.ok and r.message == 'No free seats', vim.inspect(r))
r = server(9209, { status = 'Canceled' })
check('server: canceled is silent', not r.ok and r.message == nil, vim.inspect(r))
r = server(9210, { status = 'TimedOut' })
check('server: timed out', r.message == 'Sign-in to the license server timed out. Try again.', vim.inspect(r))
r = server(9211, { status = 'Failed', errorMessage = '  Unknown host  ' })
check('server: failed -> the trimmed server message', r.message == 'Unknown host', vim.inspect(r))
r = server(9212, { status = 'Failed' })
check('server: failed without a message -> the sentence', r.message and r.message:find("^Couldn't activate with the license server") ~= nil, vim.inspect(r))
r = server(9213, { status = 'Failed', errorMessage = 'Failed to open the sign-in page' })
check('server: the sign-in page did not open -> silent', r.message == nil, vim.inspect(r))

-- Signed in before: the account is signed out once the server's ticket arrives, even after the reply.
r = server(9214, function(params)
  push(9214, lstate({ jbaLicensingState = ACCOUNT, licenseServerFlowState = { kind = 'configured', serverAddress = params.serverAddress,
    status = 'Unknown', floatingTicketStatus = 'Obtaining' } }))
  return { status = 'Connected' }
end, lstate({ jbaLicensingState = ACCOUNT, featuresDeclined = true }))
check('server: no sign-out before the license is valid', names(9214) == 'licenseServer/add', names(9214))
push(9214, lstate({ activeLicense = LS, jbaLicensingState = ACCOUNT, licenseServerFlowState = { kind = 'configured',
  serverAddress = 'https://fls.example.com', status = 'Valid', floatingTicketStatus = 'Obtained' } }))
vim.wait(200, function() return names(9214):find('logout') ~= nil end, 5)
check('server: signed out once the license server licenses', names(9214) == 'licenseServer/add,jba/logout', names(9214))
push(9214, lstate({ activeLicense = LS }))
vim.wait(50, function() return false end, 5)
check('server: and only once', names(9214) == 'licenseServer/add,jba/logout', names(9214))

-- JetBrains Account sign-in
local function signin(id, reply, extra)
  local replies = vim.tbl_extend('force', { ['jba/login'] = reply, ['jba/logout'] = vim.NIL }, extra or {})
  return result_of(activation.login, fake(id, replies))
end
r = signin(9220, function()
  push(9220, lstate({ activeLicense = { source = 'subscription', status = 'Valid', product = 'intellij-server', licensedTo = 'Ada', assetId = 'a' },
    jbaLicensingState = ACCOUNT }))
  return { status = 'Licensed' }
end)
check('login: licensed', r.ok and last().msg:find('JetBrains Account', 1, true), vim.inspect(r))
check('login: no sign-in left pending', not activation.login_pending())

r = signin(9221, function()
  push(9221, lstate({ jbaLicensingState = vim.tbl_extend('force', ACCOUNT, { availableSubscriptions = { sub('x', 'Expired'), sub('a1') } }),
    featuresDeclined = true }))
  return { status = 'NoSuitableLicense' }
end, { ['subscriptions/use'] = function(params)
  push(9221, lstate({ activeLicense = { source = 'subscription', status = 'Valid', product = 'intellij-server', licensedTo = 'Ada',
    assetId = params.assetId }, jbaLicensingState = ACCOUNT }))
  return vim.NIL
end })
check('login: one valid subscription -> activated', r.ok and names(9221) == 'jba/login,subscriptions/use'
  and sent[#sent].params.assetId == 'a1', names(9221) .. ' ' .. vim.inspect(r))

local orig_choose, offered_items = activation.choose, nil
activation.choose = function(opts, on_choice)
  offered_items = vim.tbl_map(opts.format, opts.items)
  on_choice(opts.items[2], 2)
end
r = signin(9222, function()
  push(9222, lstate({ jbaLicensingState = vim.tbl_extend('force', ACCOUNT, { availableSubscriptions = { sub('a1'), sub('a2') } }),
    featuresDeclined = true }))
  return { status = 'NoSuitableLicense' }
end, { ['subscriptions/use'] = vim.NIL })
check('login: several -> picked', offered_items and #offered_items == 2
  and offered_items[1] == 'Java and Kotlin by IntelliJ IDEA, Ada, valid through 2027-01-31'
  and sent[#sent].params.assetId == 'a2', vim.inspect(offered_items))
check('login: a subscription that does not become active is a failure', not r.ok
  and r.message == "Couldn't activate a subscription from this JetBrains Account. Try again.", vim.inspect(r))
activation.choose = function(_, on_choice) on_choice(nil, nil) end
r = signin(9223, function()
  push(9223, lstate({ jbaLicensingState = vim.tbl_extend('force', ACCOUNT, { availableSubscriptions = { sub('a1'), sub('a2') } }),
    featuresDeclined = true }))
  return { status = 'NoSuitableLicense' }
end)
check('login: picker dismissed -> warned, still signed in', not r.ok and last().level == vim.log.levels.WARN
  and names(9223) == 'jba/login', names(9223) .. ' ' .. vim.inspect(r))
activation.choose = orig_choose

r = signin(9224, function()
  push(9224, lstate({ jbaLicensingState = vim.tbl_extend('force', ACCOUNT, { availableSubscriptions = { sub('x', 'Expired') } }),
    featuresDeclined = true }))
  return { status = 'NoSuitableLicense' }
end)
vim.wait(200, function() return names(9224):find('logout') ~= nil end, 5)
check('login: no valid subscription -> signed out and warned', names(9224) == 'jba/login,jba/logout'
  and r.message == 'No licenses available for activation were found in the JetBrains Account.' and last().level == vim.log.levels.WARN,
  names(9224) .. ' ' .. vim.inspect(r))

r = signin(9225, { status = 'NoLicenses' })
check('login: NoLicenses warns', r.message and r.message:find('^No licenses available') ~= nil and last().level == vim.log.levels.WARN)
r = signin(9226, { status = 'LicenseCheckFailed' })
check('login: LicenseCheckFailed warns', r.message == "Couldn't check licenses in the JetBrains Account. Try again.")
before = #notified
r = signin(9227, { status = 'Canceled' })
check('login: Canceled is silent', not r.ok and r.message == nil and #notified == before)
r = signin(9228, { status = 'TimedOut' })
check('login: TimedOut is an error', r.message == licensing.ACCOUNT_AUTH_FAILED and last().level == vim.log.levels.ERROR)
r = signin(9229, { status = 'Failed', errorMessage = 'Failed to open the sign-in page' })
check('login: the sign-in page did not open -> silent', r.message == nil)
r = signin(9230, { status = 'Failed', errorMessage = 'boom' })
check('login: other failures -> the fixed sentence', r.message == licensing.ACCOUNT_AUTH_FAILED)
push(9231, lstate({ jbaLicensingState = { authenticationStatus = 'Authenticating' }, featuresDeclined = true }))
r = signin(9231, function() return nil, { code = licensing.TIMED_OUT, message = 'jba/login did not answer' } end)
vim.wait(200, function() return names(9231):find('logout') ~= nil end, 5)
check('login: our wait ran out while authenticating -> signed out, error', names(9231) == 'jba/login,jba/logout'
  and r.message == licensing.ACCOUNT_AUTH_FAILED, names(9231))

-- Starting something else cancels a pending sign-in: jba/logout first, then the sign-in reply is dropped.
local login_handler
c = fake(9232, { ['jba/logout'] = vim.NIL, ['trial/startAnonymous'] = { isSuccess = false } })
local request = c.request
c.request = function(self, method, params, handler)
  if method:find('jba/login') then
    table.insert(sent, { id = 9232, name = 'jba/login' })
    login_handler = handler
    return true, #sent
  end
  return request(self, method, params, handler)
end
local login_result
activation.login(c, function(ok, message) login_result = { ok = ok, message = message } end)
check('login: pending while the browser is open', activation.login_pending())
r = result_of(activation.trial, c)
check('cancel: another activation signs out first', names(9232) == 'jba/login,jba/logout,trial/startAnonymous'
  and not activation.login_pending(), names(9232))
before = #notified
login_handler(nil, { status = 'Canceled' }, {})
check('cancel: the cancelled sign-in reports nothing', login_result and not login_result.ok and login_result.message == nil
  and #notified == before, vim.inspect(login_result))

-- The float: a digit runs its entry, q is "Later", hidden entries have no key.
local started = {}
local orig = { trial = activation.trial, login = activation.login, ask_code = activation.ask_code }
activation.trial = function(fc) table.insert(started, 'trial:' .. fc.id) end
activation.ask_code = function(fc) table.insert(started, 'code:' .. fc.id) end
activation.login = function(fc) table.insert(started, 'login:' .. fc.id) end
c = fake(9240, {})
push(9240, PARKED)
local win = activation.open(c)
check('float: opens focused with the state and the entries', win and vim.api.nvim_get_current_win() == win
  and vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(win), 0, -1, false)[3] == ' 1  Start 30-day trial')
check('float: a second open focuses the same float', activation.open(c) == win)
vim.api.nvim_feedkeys('1', 'x', false)
vim.wait(200, function() return #started > 0 end, 5)
check('float: 1 starts the trial', started[1] == 'trial:9240' and not vim.api.nvim_win_is_valid(win), vim.inspect(started))

local later = 0
win = activation.open(c, { on_later = function() later = later + 1 end })
vim.api.nvim_feedkeys('q', 'x', false)
vim.wait(200, function() return later > 0 end, 5)
check('float: q is later', later == 1 and not vim.api.nvim_win_is_valid(win))

started = {}
win = activation.open(c, { change = true })
vim.api.nvim_feedkeys('1', 'x', false)
vim.wait(200, function() return #started > 0 end, 5)
check('float: changing a license has no trial, 1 signs in', started[1] == 'login:9240' and not vim.api.nvim_win_is_valid(win),
  vim.inspect(started))

started = {}
win = activation.open(c, { change = true })
vim.api.nvim_feedkeys('j', 'x', false)
vim.api.nvim_feedkeys(vim.keycode('<CR>'), 'x', false)
vim.wait(200, function() return #started > 0 end, 5)
check('float: <CR> runs the entry under the cursor', started[1] == 'code:9240', vim.inspect(started))
activation._reset()

-- The startup offer waits for normal mode, and shows nothing once a license became valid.
local orig_mode, orig_open = vim.api.nvim_get_mode, activation.open
local mode, opened = 'i', {}
vim.api.nvim_get_mode = function() return { mode = mode, blocking = false } end
activation.open = function(fc) table.insert(opened, fc.id) end
activation.offer(c)
vim.wait(100, function() return false end, 5)
check('offer: waits while in insert mode', #opened == 0)
mode = 'n'
vim.wait(1000, function() return #opened > 0 end, 10)
check('offer: opens once back in normal mode', opened[1] == 9240, vim.inspect(opened))
push(9240, lstate({ activeLicense = TRIAL }))
opened = {}
activation.offer(c)
check('offer: a license that became valid shows nothing', #opened == 0)
push(9240, PARKED)
local orig_withdrawn, withdrawn = licensing.offer_withdrawn, 0
licensing.offer_withdrawn = function() withdrawn = withdrawn + 1 end
activation.offer(vim.tbl_extend('force', c, { is_stopped = function() return true end }))
check('offer: a server stopped before the float showed hands the offer back', #opened == 0 and withdrawn == 1)
licensing.offer_withdrawn = orig_withdrawn

-- With a UI, the startup offer is the float rather than the CLI hint.
local orig_uis = vim.api.nvim_list_uis
vim.api.nvim_list_uis = function() return { {} } end
push(9240, PARKED)
before = #notified
licensing.offer_activation(c, licensing.project(PARKED), nil)
check('offer: with a UI, the float and no warning', opened[1] == 9240 and #notified == before, vim.inspect(opened))
vim.api.nvim_list_uis = orig_uis
vim.api.nvim_get_mode, activation.open = orig_mode, orig_open
activation.trial, activation.login, activation.ask_code = orig.trial, orig.login, orig.ask_code

vim.notify = orig_notify
for id = 9201, 9240 do licensing.reset(id) end
activation._reset()
end)()

-- ---------------------------------------------------------------------------
-- Sign-in pages, and the paste-code sign-in for remote machines
-- ---------------------------------------------------------------------------
;(function()
local licensing = require('intellij-lsp.licensing')
local activation = require('intellij-lsp.activation')
local signin = require('intellij-lsp.signin')

-- Remote: the server CLI's rule, so both pick the same sign-in.
check('remote: SSH_CONNECTION', signin.remote({ SSH_CONNECTION = '1 2 3 4', DISPLAY = ':0' }, 'Linux'))
check('remote: SSH_TTY on a Mac', signin.remote({ SSH_TTY = '/dev/ttys001' }, 'Darwin'))
check('remote: a Mac without DISPLAY is local', not signin.remote({}, 'Darwin'))
check('remote: Windows is local', not signin.remote({}, 'Windows_NT'))
check('remote: Linux without a display', signin.remote({ DISPLAY = '' }, 'Linux'))
check('remote: Linux with X11 or Wayland is local', not signin.remote({ DISPLAY = ':0' }, 'Linux')
  and not signin.remote({ WAYLAND_DISPLAY = 'wayland-0' }, 'Linux'))

check('login cmd: paste-code', table.concat(signin.login_cmd('/b/bin/intellij-server', true), ' ') == '/b/bin/intellij-server license login --code')
check('login cmd: the CLI picks', table.concat(signin.login_cmd('/b/bin/intellij-server', false), ' ') == '/b/bin/intellij-server license login')

-- The CLI's URL, as 263.7084.0 prints it: unencoded spaces in the query.
local CLI_URL = 'https://account.jetbrains.com/oauth/login?client_id=ide&scope=openid offline_access r_ide_auth&state=aa'
check('cli url: none before its line is complete', signin._sign_in_url('No valid license found\r\nSign in to JetBrains Account: ' .. CLI_URL) == nil)
local url = signin._sign_in_url('No valid license found\r\n\27[1mSign in to JetBrains Account: ' .. CLI_URL .. '\27[0m\r\nEnter the')
check('cli url: complete line, escapes dropped, spaces encoded',
  url == 'https://account.jetbrains.com/oauth/login?client_id=ide&scope=openid%20offline_access%20r_ide_auth&state=aa', url)

-- The page float. Opening and copying are stubbed: no browser, no clipboard here.
local opened, copied = {}, {}
local orig = { open = signin._open, copy = signin._copy, remote = signin.remote, terminal = signin.terminal_login,
  default = vim.lsp.handlers['window/showDocument'] }
signin._open = function(u) table.insert(opened, u) return true end
signin._copy = function(u) table.insert(copied, u) return true end
signin.remote = function() return false end

local PAGE = 'https://account.jetbrains.com/oauth/login?client_id=ide&scope=openid%20offline_access'
local function float_text()
  local w = vim.api.nvim_get_current_win()
  if vim.api.nvim_win_get_config(w).relative == '' then return nil end
  return table.concat(vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(w), 0, -1, false), '\n')
end
local function press(key)
  local map = vim.fn.maparg(key, 'n', false, true)
  if map.callback then map.callback() end
end

local res = signin.show_document(nil, { uri = PAGE, external = true }, { client_id = 9301 })
local text = float_text() or ''
check('page: answers success so the server keeps waiting', res and res.success == true, vim.inspect(res))
check('page: opened in the browser and copied', opened[1] == PAGE and copied[1] == PAGE, vim.inspect({ opened, copied }))
check('page: the float shows the URL, the copy and the wait', text:find(PAGE, 1, true) and text:find('Copied to the clipboard', 1, true)
  and text:find('Waiting for the sign-in', 1, true) and text:find('Opened the sign-in page', 1, true), text)
local first_line = vim.api.nvim_buf_get_lines(0, -2, -1, false)[1]
vim.wait(400, function() return vim.api.nvim_buf_get_lines(0, -2, -1, false)[1] ~= first_line end, 20)
check('page: the spinner turns', vim.api.nvim_buf_get_lines(0, -2, -1, false)[1] ~= first_line)
press('y')
check('page: y copies again', #copied == 2)
signin.close()
check('page: close closes it', float_text() == nil)

-- From a remote session the browser would open on the wrong machine.
signin.remote = function() return true end
opened = {}
signin.show_document(nil, { uri = PAGE, external = true }, { client_id = 9301 })
text = float_text() or ''
check('page: remote -> not opened, link offered', #opened == 0 and text:find('Open this link in a browser', 1, true), text)
signin.close()
signin.remote = function() return false end

-- Not external: Neovim's own handler.
local delegated
vim.lsp.handlers['window/showDocument'] = function(_, params) delegated = params return { success = true } end
signin.show_document(nil, { uri = 'file:///tmp/A.java' }, { client_id = 9301 })
check('page: a file goes to the default handler, no float', delegated and delegated.uri == 'file:///tmp/A.java' and float_text() == nil)
vim.lsp.handlers['window/showDocument'] = orig.default

-- With the sign-in under way: a fake server that opens the page and then waits, or replies.
local sent = {}
local orig_notify = vim.notify
local notified = {}
vim.notify = function(msg, level) table.insert(notified, { msg = msg, level = level }) end
local function fake(id, login_reply)
  local c = {
    id = id,
    server_capabilities = { experimental = { licensing = true } },
    config = { server_cmd = { '/b/bin/intellij-server', '--stdio' }, cmd_env = { IJ_JAVA_OPTIONS = '-Dx=1' } },
    is_stopped = function() return false end,
    cancel_request = function() end,
  }
  c.request = function(_, method, _, handler)
    local name = method:gsub('^jetbrains/licensing/', '')
    table.insert(sent, { id = id, name = name })
    if name == 'jba/login' then
      vim.schedule(function() signin.show_document(nil, { uri = PAGE, external = true }, { client_id = id }) end)
      -- Without a reply of its own, the sign-in waits until a sign-out ends it, as on the server.
      if login_reply == nil then c.pending_login = handler return true, #sent end
      vim.defer_fn(function() handler(nil, login_reply, {}) end, 50)
    elseif name == 'jba/logout' and c.pending_login then
      local pending = c.pending_login
      c.pending_login = nil
      vim.schedule(function()
        pending(nil, { status = 'Canceled' }, {})
        handler(nil, vim.NIL, {})
      end)
    else
      vim.schedule(function() handler(nil, vim.NIL, {}) end)
    end
    return true, #sent
  end
  return c
end
local function names(id)
  local out = {}
  for _, s in ipairs(sent) do if s.id == id then table.insert(out, s.name) end end
  return table.concat(out, ',')
end
local function push(id, state) licensing.handlers()[licensing.STATE](nil, state, { client_id = id }) end

local finals = {}
local orig_progress = licensing.progress
licensing.progress = function() return function(final, status) table.insert(finals, final .. '/' .. status) return true end end
local c = fake(9302)
push(9302, { jbaLicensingState = { authenticationStatus = 'NotAuthenticated' }, featuresDeclined = true })
local got
activation.login(c, function(ok, message) got = { ok = ok, message = message } end)
vim.wait(1000, function() return float_text() ~= nil end, 10)
check('login: the page float is up and focused', float_text() ~= nil and activation.login_pending())
press('<Esc>')
vim.wait(500, function() return names(9302):find('logout') ~= nil end, 10)
check('login: <Esc> closes the float and cancels with jba/logout', float_text() == nil and names(9302) == 'jba/login,jba/logout'
  and not activation.login_pending(), names(9302))
vim.wait(500, function() return #finals > 0 end, 10)
check('login: the cancelled wait closes as Cancelled, not as still waiting', finals[1] == 'Cancelled./failed', vim.inspect(finals))
licensing.progress = orig_progress

c = fake(9303)
activation.login(c)
vim.wait(1000, function() return float_text() ~= nil end, 10)
vim.cmd('close')
vim.wait(500, function() return names(9303):find('logout') ~= nil end, 10)
check('login: closing the float cancels too', names(9303) == 'jba/login,jba/logout', names(9303))

c = fake(9304, { status = 'Licensed' })
got = nil
activation.login(c, function(ok, message) got = { ok = ok, message = message } end)
vim.wait(1000, function() return got ~= nil end, 10)
check('login: the reply closes the float without cancelling', got and got.ok and float_text() == nil
  and names(9304) == 'jba/login', names(9304) .. ' ' .. vim.inspect(got))

c = fake(9305)
push(9305, { jbaLicensingState = { authenticationStatus = 'Authenticating' }, featuresDeclined = true })
activation.login(c)
vim.wait(1000, function() return float_text() ~= nil end, 10)
licensing.reset(9305)
vim.wait(500, function() return float_text() == nil end, 10)
check('login: the server exiting closes the float', float_text() == nil)
activation._reset()

-- Remote: the sign-in entry is the paste-code one, run in a terminal with the server's launcher and env.
local terminals = {}
signin.terminal_login = function(launcher, env, opts) table.insert(terminals, { launcher = launcher, env = env, opts = opts }) end
signin.remote = function() return true end
local acts = activation.actions({ remote = true })
check('remote: entry 2 pastes a code', acts[2].key == '2' and acts[2].label == 'Sign in with JetBrains Account (paste a code)'
  and activation.ACTIONS[2].label == 'Sign in with JetBrains Account', vim.inspect(acts[2]))
c = fake(9306)
activation.open(c)
check('remote: the float names the paste-code sign-in', (float_text() or ''):find('paste a code', 1, true), float_text())
press('2')
vim.wait(500, function() return #terminals > 0 end, 10)
check('remote: 2 runs the CLI sign-in in a terminal, not jba/login', #terminals == 1 and terminals[1].launcher == '/b/bin/intellij-server'
  and terminals[1].env.IJ_JAVA_OPTIONS == '-Dx=1' and names(9306) == '', vim.inspect(terminals) .. names(9306))
signin.terminal_login, signin.remote = orig.terminal, orig.remote

-- The terminal itself, against a stand-in launcher that talks like the CLI.
local dir = vim.fn.tempname()
vim.fn.mkdir(dir, 'p')
local launcher = dir .. '/intellij-server'
vim.fn.writefile({
  '#!/bin/sh',
  'echo "args: $*"',
  'echo "Sign in to JetBrains Account: https://account.jetbrains.com/oauth/login?scope=openid offline_access&x=$MARK"',
  'echo "Enter the authorization code shown after signing in:"',
  'read code',
  '[ "$code" = good ] && exit 0',
  'echo "Login failed: bad code"',
  'exit 1',
}, launcher)
vim.fn.setfperm(launcher, 'rwxr-xr-x')
signin.remote = function() return false end
opened, copied, notified = {}, {}, {}
local function run_terminal(code)
  local job = signin.terminal_login(launcher, vim.tbl_extend('force', vim.fn.environ(), { MARK = 'm1' }))
  local buf = vim.api.nvim_get_current_buf()
  vim.wait(3000, function() return #copied > 0 end, 20)
  vim.fn.chansend(job, code .. '\n')
  vim.fn.jobwait({ job }, 3000)
  vim.wait(1000, function()
    local msg = (notified[#notified] or {}).msg or ''
    return msg:find('signed in', 1, true) or msg:find('did not complete', 1, true)
  end, 20)
  return buf
end
local buf = run_terminal('good')
check('terminal: the paste-code CLI runs with the given env', copied[1] == 'https://account.jetbrains.com/oauth/login?scope=openid%20offline_access&x=m1',
  vim.inspect(copied))
check('terminal: the link opens in the local browser', opened[1] == copied[1], vim.inspect(opened))
check('terminal: success closes the split and says so', not vim.api.nvim_buf_is_valid(buf)
  and notified[#notified].msg:find('signed in', 1, true), vim.inspect(notified))
opened, copied, notified = {}, {}, {}
buf = run_terminal('bad')
check('terminal: a failure keeps the split open', vim.api.nvim_buf_is_valid(buf)
  and table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), '\n'):find('args: license login --code', 1, true)
  and notified[#notified].level == vim.log.levels.WARN, vim.inspect(notified))
vim.cmd('stopinsert')
pcall(vim.api.nvim_buf_delete, buf, { force = true })
vim.fn.delete(dir, 'rf')

-- :IntellijLspLicense completion
local init = require('intellij-lsp')
check('complete: subcommands', table.concat(init._complete_license('', 'IntellijLspLicense '), ',')
  == 'activate,login,logout,refresh,remove,reset,server,setup,status,trial,use',
  vim.inspect(init._complete_license('', 'IntellijLspLicense ')))
check('complete: login takes --code', vim.deep_equal(init._complete_license('--', 'IntellijLspLicense login --'), { '--code' }))
check('complete: nothing after --code', #init._complete_license('', 'IntellijLspLicense login --code ') == 0)

signin._open, signin._copy, signin.remote = orig.open, orig.copy, orig.remote
vim.notify = orig_notify
for id = 9301, 9306 do licensing.reset(id) end
activation._reset()
signin._reset()
end)()

-- ---------------------------------------------------------------------------
-- :IntellijLspLicense: the status float, remove, sign out, subscriptions, the CLI without a server
-- ---------------------------------------------------------------------------
;(function()
local licensing = require('intellij-lsp.licensing')
local activation = require('intellij-lsp.activation')
local license = require('intellij-lsp.license')

local function lstate(t)
  return vim.tbl_extend('force', {
    jbaLicensingState = { authenticationStatus = 'NotAuthenticated' },
    licenseServerFlowState = { kind = 'notConfigured' },
    featuresDeclined = false,
  }, t)
end
local PARKED = lstate({ featuresDeclined = true, parkedReason = 'StartedUnlicensed' })
local REMOVED = lstate({ featuresDeclined = true, parkedReason = 'LicenseRemoved' })
local TRIAL = { source = 'trial', status = 'Valid', product = 'intellij-server', daysLeft = 30, validThrough = '2026-11-19' }
local function sub(asset, status)
  return { kind = 'Subscription', licensedTo = 'Ada', product = 'intellij-server', validThrough = '2027-01-31',
    licenseId = 'L-' .. asset, assetId = asset, status = status or 'Valid' }
end
local ACCOUNT = { authenticationStatus = 'Authenticated', accountInfo = { displayName = 'Ada', email = 'ada@example.com' },
  availableSubscriptions = { sub('A1'), sub('A2'), sub('A3', 'Expired') } }
local SUBSCRIBED = lstate({ jbaLicensingState = ACCOUNT, activeLicense = { source = 'subscription', status = 'Valid',
  product = 'intellij-server', licensedTo = 'Ada', assetId = 'A1', daysLeft = 100, validThrough = '2027-01-31' } })

local sent, notified = {}, {}
local orig_notify = vim.notify
vim.notify = function(msg, level) table.insert(notified, { msg = msg, level = level }) end
local function fake(id, replies, env)
  local c = {
    id = id,
    server_capabilities = { experimental = { licensing = true } },
    config = { server_cmd = { '/b/bin/intellij-server' }, cmd_env = env or {} },
    is_stopped = function() return false end,
    cancel_request = function() end,
  }
  c.request = function(_, method, params, handler)
    local name = method:gsub('^jetbrains/licensing/', '')
    table.insert(sent, { id = id, name = name, params = params })
    local reply = replies[name]
    vim.schedule(function()
      if type(reply) == 'function' then reply = reply(params) end
      handler(nil, reply, {})
    end)
    return true, #sent
  end
  return c
end
local function push(id, state) licensing.handlers()[licensing.STATE](nil, state, { client_id = id }) end
local function names(id)
  local out = {}
  for _, s in ipairs(sent) do if s.id == id then table.insert(out, s.name) end end
  return table.concat(out, ',')
end
local function result_of(fn, ...)
  local got
  local args = { ... }
  table.insert(args, function(ok, message) got = { ok = ok, message = message } end)
  fn(unpack(args))
  vim.wait(1000, function() return got ~= nil end, 5)
  return got or {}
end
local function last() return notified[#notified] or {} end

-- Entries
local function keys(view, opts) return table.concat(vim.tbl_map(function(a) return a.key end, license.status_actions(view, opts or {}))) end
check('status: no license -> only "Activate a license"', keys(licensing.project(PARKED)) == '1'
  and license.status_actions(licensing.project(PARKED), {})[1].label == 'Activate a license')
check('status: a trial can be changed and removed', keys(licensing.project(lstate({ activeLicense = TRIAL }))) == '12')
check('status: signed in -> sign out and refresh too', keys(licensing.project(SUBSCRIBED)) == '1234')
check('status: an EAP license has no removal', keys(licensing.project(lstate({ activeLicense = { source = 'eap', status = 'Valid' } }))) == '1')
check('status: a signed-in EAP license numbers sign out and refresh 2 and 3',
  keys(licensing.project(lstate({ jbaLicensingState = ACCOUNT, activeLicense = { source = 'eap', status = 'Valid' } }))) == '123'
  and license.status_actions(licensing.project(lstate({ jbaLicensingState = ACCOUNT, activeLicense = { source = 'eap', status = 'Valid' } })), {})[2].name == 'logout')
check('status: an environment license hides remove', keys(licensing.project(lstate({ activeLicense = TRIAL })), { environment = true }) == '1')

-- Lines
local lines, first = license._status_lines(licensing.project(SUBSCRIBED), license.status_actions(licensing.project(SUBSCRIBED), {}), {})
local text = table.concat(lines, '\n')
check('status: the fields', lines[1] == ' License is active (JetBrains Account)'
  and text:find(' Source         JetBrains Account', 1, true) and text:find(' Product        Java and Kotlin by IntelliJ IDEA', 1, true)
  and text:find(' Licensed to    Ada', 1, true) and text:find(' License ID     L-A1', 1, true)
  and text:find(' Valid through  2027-01-31 (100 days left)', 1, true) and text:find(' Account        Ada (ada@example.com)', 1, true)
  and lines[first] == ' 1  Change license' and lines[first + 3] == ' 4  Refresh subscriptions', text)
lines = license._status_lines(licensing.project(lstate({ activeLicense = vim.tbl_extend('force', TRIAL, { status = 'Expired', daysLeft = 1 }) })),
  {}, { env_var = 'INTELLIJ_SERVER_LICENSE', offline = true })
text = table.concat(lines, '\n')
check('status: an expired license, the environment, offline', text:find(' Status         Expired', 1, true)
  and text:find('(1 day left)', 1, true) and text:find('INTELLIJ_SERVER_LICENSE, which overrides', 1, true)
  and text:find('No server is running', 1, true) and not text:find(' 1  ', 1, true), text)

-- The float: digits act on the server.
local c = fake(9401, {})
push(9401, lstate({ activeLicense = TRIAL }))
local chose = {}
local orig = { open = activation.open, confirm = license._confirm, choose = activation.choose }
activation.open = function(_, opts) table.insert(chose, { 'activation', opts }) end
license._confirm = function(prompt, label, yes) table.insert(chose, { 'confirm', prompt, label }) end
license.open_status(c, licensing.view(9401))
check('status float: focused, titled', vim.api.nvim_win_get_config(0).relative ~= ''
  and vim.api.nvim_win_get_config(0).title[1][1] == ' Java and Kotlin by IntelliJ IDEA · License ')
vim.fn.maparg('1', 'n', false, true).callback()
vim.wait(200, function() return #chose > 0 end, 5)
check('status float: 1 opens the activation float in change mode', chose[1] and chose[1][1] == 'activation'
  and chose[1][2].change == true, vim.inspect(chose))
license.open_status(c, licensing.view(9401))
vim.fn.maparg('2', 'n', false, true).callback()
vim.wait(200, function() return #chose > 1 end, 5)
check('status float: 2 asks before removing', chose[2] and chose[2][1] == 'confirm' and chose[2][3] == 'Remove'
  and chose[2][2]:find('(Trial)', 1, true) and names(9401) == '', vim.inspect(chose))
license.open_status(c, licensing.view(9401))
check('status float: no 3 without an account', vim.fn.maparg('3', 'n') == '')
vim.api.nvim_win_close(0, true)

-- Remove, per source
c = fake(9402, { ['activationCode/disable'] = function() push(9402, REMOVED) return vim.NIL end })
push(9402, lstate({ activeLicense = TRIAL }))
local r = result_of(license.remove, c)
check('remove: a trial is disabled', r.ok and names(9402) == 'activationCode/disable'
  and last().msg == 'IntelliJ LSP: The license was removed. Activate another license to use Java and Kotlin features.', vim.inspect(notified))
c = fake(9403, { ['subscriptions/unuseAll'] = function()
  push(9403, lstate({ jbaLicensingState = ACCOUNT, featuresDeclined = true, parkedReason = 'LicenseRemoved' }))
  return vim.NIL
end, ['jba/logout'] = function() push(9403, REMOVED) return vim.NIL end })
push(9403, SUBSCRIBED)
r = result_of(license.remove, c)
check('remove: a subscription is released, then the account signed out', r.ok and names(9403) == 'subscriptions/unuseAll,jba/logout', names(9403))
c = fake(9404, { ['licenseServer/remove'] = function() push(9404, REMOVED) return vim.NIL end })
push(9404, lstate({ activeLicense = { source = 'licenseServer', status = 'Valid', serverAddress = 'https://fls' },
  licenseServerFlowState = { kind = 'configured', serverAddress = 'https://fls' } }))
r = result_of(license.remove, c)
check('remove: a license server is removed', r.ok and names(9404) == 'licenseServer/remove', names(9404))
c = fake(9405, { ['activationCode/disable'] = vim.NIL })
push(9405, lstate({ activeLicense = { source = 'activationCode', status = 'Valid', licenseId = 'AC' } }))
r = result_of(license.remove, c)
check('remove: still licensed afterwards -> failed', not r.ok and r.message == "Couldn't remove the license. Try again."
  and last().level == vim.log.levels.ERROR, vim.inspect(r))
c = fake(9406, {})
push(9406, lstate({ activeLicense = { source = 'toolbox', status = 'Valid' } }))
r = result_of(license.remove, c)
check('remove: a Toolbox license is not removable', not r.ok and names(9406) == ''
  and last().msg:find("JetBrains Toolbox can't be removed", 1, true), vim.inspect(last()))
c = fake(9407, {}, { INTELLIJ_SERVER_LICENSE = 'key' })
push(9407, lstate({ activeLicense = TRIAL }))
r = result_of(license.remove, c)
check('remove: refused under an environment license', not r.ok and names(9407) == ''
  and last().msg:find('INTELLIJ_SERVER_LICENSE', 1, true), vim.inspect(last()))
chose = {}
c = fake(9408, {})
push(9408, SUBSCRIBED)
license.confirm_remove(c)
check('remove: removing a subscription warns about the shared sign-in', chose[1]
  and chose[1][2]:find('signs out of the JetBrains Account', 1, true) and chose[1][2]:find('JetBrains IDEs on this machine', 1, true),
  vim.inspect(chose))

-- Sign out
c = fake(9409, { ['jba/logout'] = function() push(9409, lstate({ activeLicense = TRIAL })) return vim.NIL end })
push(9409, lstate({ activeLicense = TRIAL, jbaLicensingState = ACCOUNT }))
r = result_of(license.logout, c)
check('logout: signed out, the license stays', r.ok and names(9409) == 'jba/logout'
  and last().msg == 'IntelliJ LSP: Signed out of the JetBrains Account.', vim.inspect(last()))
c = fake(9410, { ['jba/logout'] = function() push(9410, REMOVED) return vim.NIL end })
push(9410, SUBSCRIBED)
r = result_of(license.logout, c)
check('logout: a subscription goes with the account, and it says so', r.ok
  and last().msg:find('Signed out of the JetBrains Account. The license was removed.', 1, true), vim.inspect(last()))
c = fake(9411, {})
push(9411, PARKED)
r = result_of(license.logout, c)
check('logout: not signed in -> nothing sent', not r.ok and names(9411) == '' and last().msg:find('Not signed in', 1, true))
chose = {}
c = fake(9412, {})
push(9412, SUBSCRIBED)
license.confirm_logout(c)
check('logout: asks first, naming the shared sign-in', chose[1] and chose[1][3] == 'Sign out'
  and chose[1][2]:find('Its license is removed', 1, true), vim.inspect(chose))

-- Subscriptions
c = fake(9413, { ['subscriptions/update'] = vim.NIL })
push(9413, SUBSCRIBED)
r = result_of(license.refresh, c)
check('refresh: counts the valid subscriptions', r.ok and names(9413) == 'subscriptions/update'
  and last().msg == 'IntelliJ LSP: The JetBrains Account has 2 valid subscriptions.', vim.inspect(last()))
local offered
activation.choose = function(opts, cb)
  offered = vim.tbl_map(opts.format, opts.items)
  cb(opts.items[2], 2)
end
c = fake(9414, { ['subscriptions/use'] = function(params)
  local state = vim.deepcopy(SUBSCRIBED)
  state.activeLicense.assetId = params.assetId
  push(9414, state)
  return vim.NIL
end })
push(9414, SUBSCRIBED)
r = result_of(license.use, c)
check('use: offers the valid ones, the active one marked', offered and #offered == 2 and offered[1]:find('(active)', 1, true)
  and not offered[2]:find('(active)', 1, true), vim.inspect(offered))
check('use: activates the one picked', r.ok and sent[#sent].name == 'subscriptions/use' and sent[#sent].params.assetId == 'A2', vim.inspect(sent[#sent]))
activation.choose = function(opts, cb) cb(opts.items[2], 2) end
local before = #sent
r = result_of(license.use, c)
check('use: not again for the active one', #sent == before)
local NO_IDS = vim.deepcopy(SUBSCRIBED)
for _, s in ipairs(NO_IDS.jbaLicensingState.availableSubscriptions) do s.licenseId = nil end
c = fake(9416, { ['subscriptions/use'] = function(params)
  local state = vim.deepcopy(NO_IDS)
  state.activeLicense.assetId = params.assetId
  push(9416, state)
  return vim.NIL
end })
push(9416, NO_IDS)
offered = nil
activation.choose = function(opts, cb)
  offered = vim.tbl_map(opts.format, opts.items)
  cb(opts.items[2], 2)
end
r = result_of(license.use, c)
check('use: without license ids, only the active asset is marked', offered and offered[1]:find('(active)', 1, true)
  and not offered[2]:find('(active)', 1, true), vim.inspect(offered))
check('use: and another one can still be picked', r.ok and sent[#sent].id == 9416 and sent[#sent].name == 'subscriptions/use'
  and sent[#sent].params.assetId == 'A2', vim.inspect(sent[#sent]))
c = fake(9415, {})
push(9415, lstate({ activeLicense = TRIAL }))
r = result_of(license.use, c)
check('use: not signed in -> nothing offered', not r.ok and names(9415) == '' and last().msg:find('Not signed in', 1, true))

-- No argument: the status float with a license, the activation float without.
local orig_target = license.target
chose = {}
c = fake(9416, { ['state/get'] = PARKED })
license.target = function() return c end
license.open({})
vim.wait(500, function() return #chose > 0 end, 5)
check('no argument, no license: the activation float', chose[1] and chose[1][1] == 'activation' and chose[1][2] == nil, vim.inspect(chose))
c = fake(9417, { ['state/get'] = lstate({ activeLicense = TRIAL }) })
license.open({})
vim.wait(500, function() return vim.api.nvim_win_get_config(0).relative ~= '' end, 5)
check('no argument, a license: the status float', vim.api.nvim_win_get_config(0).relative ~= ''
  and vim.api.nvim_buf_get_lines(0, 0, 1, false)[1] == ' License is active (Trial)' and names(9417) == 'state/get')
vim.api.nvim_win_close(0, true)
license.SUBCOMMANDS.remove.run({ 'extra' }, { config = {} })
check('subcommands: unexpected arguments -> usage', notified[#notified].msg:find('usage: :IntellijLspLicense remove', 1, true))
license.target = function() return nil end
license.SUBCOMMANDS.logout.run({}, { config = {} })
check('subcommands: sign out needs a running server', last().msg:find('no running server', 1, true), vim.inspect(last()))

-- Without a server: the CLI, against a stand-in launcher that talks like it.
local dir = vim.fn.tempname()
vim.fn.mkdir(dir .. '/bin', 'p')
local launcher = dir .. '/bin/intellij-server'
local log = dir .. '/args'
vim.fn.writefile({
  '#!/bin/sh',
  'echo "$* opts=$IJ_JAVA_OPTIONS" >> "' .. log .. '"',
  'echo "No valid license found" >&2',
  'case "$*" in',
  '  "license status --json") echo \'{"jbaLicensingState":{"authenticationStatus":"NotAuthenticated"},"licenseServerFlowState":{"kind":"notConfigured"},"featuresDeclined":true,"parkedReason":"StartedUnlicensed"}\'; exit 2 ;;',
  '  "license trial") echo "Trial started: 27 days left."; echo "License: licensed" ;;',
  '  "license activate GOOD") echo "Activated: Ada" ;;',
  '  "license activate"*) echo "Activation failed: Activation code rejected"; exit 1 ;;',
  '  "license reset"*) echo "Removed the active license." ;;',
  '  "--reset-eula") echo "Cleared the accepted-EULA record for this user and machine." ;;',
  'esac',
}, launcher)
vim.fn.setfperm(launcher, 'rwxr-xr-x')
local cfg = { server_path = launcher, jvm_args = { '-Dintellij.server.license.dir=/tmp/x' }, region = 'europe', data_sharing = 'none' }
local function wait_notified(pattern)
  vim.wait(5000, function() return (last().msg or ''):find(pattern, 1, true) ~= nil end, 10)
  return (last().msg or ''):find(pattern, 1, true) ~= nil
end
local view, verr
license.cli_status(cfg, function(v, e) view, verr = v or false, e end)
vim.wait(5000, function() return view ~= nil end, 10)
check('cli: status --json is projected (exit 2 is "not licensed")', view and view.kind == 'parked', vim.inspect(view) .. tostring(verr))
check('cli: runs with the server environment', table.concat(vim.fn.readfile(log), '\n'):find('opts=-Dintellij.server.license.dir=/tmp/x', 1, true))
license.SUBCOMMANDS.trial.run({}, { config = cfg })
check('cli: trial reports the CLI result', wait_notified('Trial started: 27 days left.') and last().level == vim.log.levels.INFO, vim.inspect(last()))
license.SUBCOMMANDS.activate.run({ 'BAD' }, { config = cfg })
check('cli: a rejected code is an error', wait_notified('Activation failed') and last().level == vim.log.levels.ERROR, vim.inspect(last()))
license.SUBCOMMANDS.activate.run({ 'GO', 'OD' }, { config = cfg })
check('cli: a code pasted in pieces is joined', wait_notified('Activated: Ada'), vim.inspect(last()))
license.SUBCOMMANDS.status.run({}, { config = cfg })
vim.wait(5000, function() return vim.api.nvim_win_get_config(0).relative ~= '' end, 10)
local float = table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), '\n')
check('cli: status without a server shows the store, no entries', float:find('No active license', 1, true)
  and float:find('No server is running', 1, true) and vim.fn.maparg('1', 'n') == '', float)
vim.api.nvim_win_close(0, true)
check('cli: not downloaded -> says so', not license.cli({}, { 'license', 'trial' }, function() end)
  and last().msg:find('not downloaded', 1, true))

-- Reset: asks, stops the servers, then license reset, --reset-eula, and the consent store.
local consent = require('intellij-lsp.consent')
local orig_store = consent.store_path
local store = dir .. '/consent.json'
consent.store_path = function() return store end
vim.fn.writefile({ '{"region":"europe"}' }, store)
vim.fn.writefile({}, log)
local stopped = 0
license._confirm = function(prompt, label, yes) chose = { prompt, label } yes() end
license.SUBCOMMANDS.reset.run({ '--account' }, { config = cfg, stop_all = function(done) stopped = stopped + 1 done() end })
check('reset: reports what it removed', wait_notified('reset the license and the account sign-in, the EULA acceptance, the stored consent answers')
  and last().level == vim.log.levels.INFO, vim.inspect(last()))
check('reset: asked first, naming the account', chose[2] == 'Reset' and chose[1]:find('signs out of the JetBrains Account', 1, true))
check('reset: servers stopped, CLI run in order', stopped == 1 and table.concat(vim.tbl_map(function(l) return l:match('^(.-) opts=') end,
  vim.fn.readfile(log)), '|') == 'license reset --account|--reset-eula', vim.inspect(vim.fn.readfile(log)))
check('reset: the consent store is gone', vim.fn.filereadable(store) == 0)
license.SUBCOMMANDS.reset.run({ '--all' }, { config = cfg, stop_all = function() end })
check('reset: only --account', last().msg:find('usage: :IntellijLspLicense reset [--account]', 1, true))

local init = require('intellij-lsp')
check('complete: reset takes --account', vim.deep_equal(init._complete_license('', 'IntellijLspLicense reset '), { '--account' }))

consent.store_path = orig_store
vim.fn.delete(dir, 'rf')
license.target, license._confirm, activation.open = orig_target, orig.confirm, orig.open
activation.choose = orig.choose
vim.notify = orig_notify
for id = 9401, 9417 do licensing.reset(id) end
activation._reset()
end)()

-- ---------------------------------------------------------------------------
-- Licensing status: statusline, notices per transition, a parked server kept quiet
-- ---------------------------------------------------------------------------
;(function()
local licensing = require('intellij-lsp.licensing')
local function lstate(t)
  return vim.tbl_extend('force', {
    jbaLicensingState = { authenticationStatus = 'NotAuthenticated' },
    licenseServerFlowState = { kind = 'notConfigured' },
    featuresDeclined = false,
  }, t)
end
local function trial(days, through)
  return { source = 'trial', status = 'Valid', product = 'intellij-server', daysLeft = days, validThrough = through or '2026-11-17' }
end
local NOW = 1792000000000
local function view_of(t) return licensing.project(lstate(t)) end
local LICENSED = view_of({ activeLicense = trial(27) })
local GRACE = view_of({ activeLicense = { source = 'trial', status = 'Expired', product = 'intellij-server' }, graceDeadline = NOW + 12 * 60000 })
local PARKED = view_of({ featuresDeclined = true, parkedReason = 'StartedUnlicensed' })
local REMOVED = view_of({ featuresDeclined = true, parkedReason = 'LicenseRemoved' })
local REVOKED = view_of({ activeLicense = { source = 'activationCode', status = 'Revoked', product = 'intellij-server' },
  featuresDeclined = true, parkedReason = 'LicenseRevoked' })

-- Statusline
check('statusline: nothing without a state', licensing.statusline(nil) == '')
check('statusline: quiet with more than 7 days', licensing.statusline(LICENSED) == '', licensing.statusline(LICENSED))
check('statusline: trial counts down', licensing.statusline(view_of({ activeLicense = trial(5) })) == 'IJ trial 5d')
check('statusline: 7 days is counted', licensing.statusline(view_of({ activeLicense = trial(7) })) == 'IJ trial 7d')
check('statusline: other licenses count down too', licensing.statusline(view_of({ activeLicense = { source = 'activationCode',
  status = 'Valid', product = 'intellij-server', daysLeft = 3, validThrough = '2026-10-23' } })) == 'IJ license 3d')
check('statusline: no end date, nothing to count', licensing.statusline(view_of({ activeLicense = { source = 'eap', status = 'Valid',
  product = 'intellij-server', daysLeft = 0 } })) == '')
check('statusline: grace in minutes', licensing.statusline(GRACE, NOW) == 'IJ grace 12m', licensing.statusline(GRACE, NOW))
check('statusline: long grace in hours', licensing.statusline(GRACE, NOW - 3 * 3600000) == 'IJ grace 3h',
  licensing.statusline(GRACE, NOW - 3 * 3600000))
check('statusline: grace past its deadline', licensing.statusline(GRACE, NOW + 3600000) == 'IJ grace 0m')
check('statusline: parked', licensing.statusline(PARKED) == 'IJ unlicensed')
check('statusline: unlicensed', licensing.statusline(view_of({ activeLicense = { source = 'activationCode', status = 'Invalid',
  product = 'intellij-server' } })) == 'IJ unlicensed')
check('statusline: session expired', licensing.statusline(view_of({ activeLicense = trial(27),
  jbaLicensingState = { authenticationStatus = 'FailedToProlongateAuthentication', accountInfo = { displayName = 'Ada' } } })) == 'IJ sign in')
check('statusline: signing in', licensing.statusline(view_of({ jbaLicensingState = { authenticationStatus = 'Authenticating' },
  featuresDeclined = true })) == 'IJ signing in')
check('license() is empty without a server', require('intellij-lsp').license() == '')

-- Notices: one per transition, the first view is the baseline.
local function run(views, own)
  local memo, out = {}, {}
  for i, v in ipairs(views) do
    out[i] = licensing._notices(memo, v, own and own[i] or false) or false
  end
  return out
end
local n = run({ PARKED })
check('notice: starting parked is the startup offer\'s', n[1] == false, vim.inspect(n))
n = run({ LICENSED, LICENSED })
check('notice: a licensed server says nothing', n[1] == false and n[2] == false, vim.inspect(n))
n = run({ LICENSED, GRACE, GRACE })
check('notice: grace started, once', n[2] and n[2].level == vim.log.levels.WARN and n[3] == false
  and n[2].text:find('Features work until ' .. licensing.format_deadline(NOW + 12 * 60000), 1, true)
  and n[2].text:find(':IntellijLspLicense', 1, true), vim.inspect(n))
n = run({ GRACE })
check('notice: a server starting in grace says so', n[1] and n[1].text:find('Features work until', 1, true), vim.inspect(n))
n = run({ LICENSED, GRACE, view_of({ activeLicense = { source = 'trial', status = 'Expired', product = 'intellij-server' },
  featuresDeclined = true, parkedReason = 'GraceExpired' }) })
check('notice: parked after grace, as an error', n[3] and n[3].level == vim.log.levels.ERROR
  and n[3].text:find('grace period has ended', 1, true) and n[3].text:find('Run :IntellijLspLicense.', 1, true), vim.inspect(n))
n = run({ LICENSED, REVOKED })
check('notice: license lost (revoked)', n[2] and n[2].text:find('was revoked', 1, true), vim.inspect(n))
n = run({ LICENSED, REMOVED })
check('notice: license removed elsewhere (CLI)', n[2] and n[2].text:find('was removed', 1, true), vim.inspect(n))
n = run({ LICENSED, REMOVED }, { false, true })
check('notice: a removal asked for here reports itself', n[2] == false, vim.inspect(n))
n = run({ LICENSED, REVOKED }, { false, true })
check('notice: a revocation is reported during a request too', n[2] ~= false, vim.inspect(n))
n = run({ PARKED, view_of({ jbaLicensingState = { authenticationStatus = 'Authenticating' }, featuresDeclined = true }), PARKED })
check('notice: a cancelled sign-in is not a loss', n[2] == false and n[3] == false, vim.inspect(n))

-- Requests in flight count for their own client only, and a sign-in waiting on the browser not at all.
do
  local function silent(id)
    return { id = id, server_capabilities = { experimental = { licensing = true } }, cancel_request = function() end,
      request = function() return true, 1 end }
  end
  local orig_n, told = licensing.notify, {}
  licensing.notify = function(notice) if notice then table.insert(told, notice.text) end end
  licensing.request(silent(9601), 'activationCode/disable', nil, function() end)
  licensing.request(silent(9602), 'jba/login', nil, function() end)
  for _, id in ipairs({ 9601, 9602, 9603 }) do
    licensing._set(id, lstate({ activeLicense = trial(27) }))
    licensing._set(id, lstate({ featuresDeclined = true, parkedReason = 'LicenseRemoved' }))
  end
  check('own change: only the client with the removal in flight stays quiet', #told == 2, vim.inspect(told))
  licensing.notify = orig_n
  for _, id in ipairs({ 9601, 9602, 9603 }) do licensing.reset(id) end
end
local EXPIRED_SESSION = view_of({ activeLicense = { source = 'subscription', status = 'Valid', product = 'intellij-server', assetId = 'a' },
  jbaLicensingState = { authenticationStatus = 'FailedToProlongateAuthentication', accountInfo = { displayName = 'Ada' } } })
n = run({ LICENSED, EXPIRED_SESSION, EXPIRED_SESSION })
check('notice: session expired, once', n[2] and n[2].text:find('session expired', 1, true)
  and n[2].text:find(':IntellijLspLicense login', 1, true) and n[3] == false, vim.inspect(n))

local function fls(ticket, extra)
  return view_of(vim.tbl_extend('force', { activeLicense = { source = 'licenseServer', status = 'Valid', product = 'intellij-server',
    serverAddress = 'https://fls.example.com' },
    licenseServerFlowState = { kind = 'configured', serverAddress = 'https://fls.example.com', status = 'Valid', floatingTicketStatus = ticket } },
    extra or {}))
end
n = run({ fls('Obtained'), fls('FailedToRefresh'), fls('Refreshing'), fls('FailedToRefresh'), fls('Obtained'), fls('FailedToRefresh') })
check('notice: license server refresh failed, latched until obtained again', n[2] and n[2].text:find('^Lost connection')
  and n[3] == false and n[4] == false and n[5] == false and n[6] ~= false, vim.inspect(n))
local lost = view_of({ activeLicense = { source = 'licenseServer', status = 'Unknown', product = 'intellij-server' },
  licenseServerFlowState = { kind = 'configured', serverAddress = 'https://fls.example.com', status = 'Unknown', floatingTicketStatus = 'NotObtained' },
  graceDeadline = NOW })
n = run({ fls('Obtained'), lost })
check('notice: ticket lost and grace, in one notification', n[2] and n[2].text:find('^Lost the license from https://fls.example.com%.')
  and n[2].text:find('Features work until', 1, true), vim.inspect(n))
n = run({ view_of({ licenseServerFlowState = { kind = 'configured', serverAddress = 'https://fls.example.com', status = 'Unknown',
  floatingTicketStatus = 'Obtaining' }, featuresDeclined = true }),
  view_of({ licenseServerFlowState = { kind = 'configured', serverAddress = 'https://fls.example.com', status = 'Unknown',
  floatingTicketStatus = 'NotObtained', errorMessage = 'No free seats' }, featuresDeclined = true }),
  view_of({ licenseServerFlowState = { kind = 'configured', serverAddress = 'https://fls.example.com', status = 'Unknown',
  floatingTicketStatus = 'NotObtained', errorMessage = 'No free seats' }, featuresDeclined = true, parkedReason = 'StartedUnlicensed' }) },
  { false, true, false })
check('notice: a failed licenseServer/add is the request\'s to report, and stays latched', n[2] == false and n[3] == false, vim.inspect(n))
n = run({ fls('Obtained'), fls('Obtained', { licenseServerFlowState = { kind = 'configured', serverAddress = 'https://fls.example.com',
  status = 'Valid', floatingTicketStatus = 'Obtained', errorMessage = 'Server restarting' } }) })
check('notice: a license server error message on its own', n[2] and n[2].text == 'Server restarting', vim.inspect(n))

-- Dedupe: the same push to every root's server shows once.
local notified = {}
local orig_notify = vim.notify
vim.notify = function(msg, level) table.insert(notified, { msg = msg, level = level }) end
licensing.notify({ text = 'unit dedupe', level = vim.log.levels.WARN })
licensing.notify({ text = 'unit dedupe', level = vim.log.levels.WARN })
licensing.notify(nil)
check('notify: once per text, prefixed', #notified == 1 and notified[1].msg == 'IntelliJ LSP: unit dedupe', vim.inspect(notified))

-- Through the store: two clients, one loss, one notification.
notified = {}
licensing._set(9501, lstate({ activeLicense = trial(27) }))
licensing._set(9502, lstate({ activeLicense = trial(27) }))
licensing._set(9501, lstate({ featuresDeclined = true, parkedReason = 'LicenseRevoked' }))
licensing._set(9502, lstate({ featuresDeclined = true, parkedReason = 'LicenseRevoked' }))
check('store: a loss pushed to two servers notifies once', #notified == 1 and notified[1].msg:find('was revoked', 1, true)
  and notified[1].level == vim.log.levels.ERROR, vim.inspect(notified))
licensing.reset(9501) licensing.reset(9502)

-- Trial reminders: 7 days, then 1 day, at most once a day, recorded across sessions.
local dir = vim.fn.tempname() .. '-notices'
local orig_path = licensing.notice_path
licensing.notice_path = function() return dir .. '/license-notices.json' end
check('trial reminder: none above 7 days', licensing._trial_reminder(LICENSED) == nil)
local r = licensing._trial_reminder(view_of({ activeLicense = trial(5) }))
check('trial reminder: 5 days is the 7-day reminder', r and r.stage == 7 and r.level == vim.log.levels.INFO
  and r.text == 'The trial ends in 5 days (valid through 2026-11-17). Run :IntellijLspLicense to activate a license.', vim.inspect(r))
r = licensing._trial_reminder(view_of({ activeLicense = trial(1) }))
check('trial reminder: tomorrow is the 1-day reminder', r and r.stage == 1 and r.level == vim.log.levels.WARN
  and r.text:find('ends tomorrow', 1, true), vim.inspect(r))
check('trial reminder: today', licensing._trial_reminder(view_of({ activeLicense = trial(0) })).text:find('ends today', 1, true))
check('trial reminder: not for other sources', licensing._trial_reminder(view_of({ activeLicense = { source = 'activationCode',
  status = 'Valid', product = 'intellij-server', daysLeft = 3 } })) == nil)

notified = {}
licensing.trial_notice(view_of({ activeLicense = trial(7) }), '2026-11-10')
licensing.trial_notice(view_of({ activeLicense = trial(7) }), '2026-11-10')
check('trial notice: shown once', #notified == 1 and notified[1].msg:find('in 7 days', 1, true), vim.inspect(notified))
licensing.trial_notice(view_of({ activeLicense = trial(6) }), '2026-11-11')
check('trial notice: not again the next day at the same stage', #notified == 1, vim.inspect(notified))
licensing.trial_notice(view_of({ activeLicense = trial(1) }), '2026-11-10')
check('trial notice: not twice on one day', #notified == 1, vim.inspect(notified))
licensing.trial_notice(view_of({ activeLicense = trial(1) }), '2026-11-16')
check('trial notice: the 1-day reminder', #notified == 2 and notified[2].msg:find('tomorrow', 1, true), vim.inspect(notified))
licensing.trial_notice(view_of({ activeLicense = trial(0) }), '2026-11-17')
check('trial notice: nothing after the 1-day reminder', #notified == 2, vim.inspect(notified))
licensing.trial_notice(view_of({ activeLicense = trial(5, '2027-01-05') }), '2026-12-31')
check('trial notice: a new trial reminds again', #notified == 3, vim.inspect(notified))
vim.fn.writefile({ 'not json' }, licensing.notice_path())
licensing.trial_notice(view_of({ activeLicense = trial(5, '2027-02-05') }), '2027-01-31')
check('trial notice: an unreadable record reminds', #notified == 4, vim.inspect(notified))
local no_end = view_of({ activeLicense = { source = 'trial', status = 'Valid', product = 'intellij-server', daysLeft = 5 } })
licensing.trial_notice(no_end, '2027-03-01')
licensing.trial_notice(no_end, '2027-03-02')
check('trial notice: a trial without an end date reminds once per stage', #notified == 5, vim.inspect(notified))

-- A parked server: ServerCancelled reads as an empty result for features, commands keep their errors.
do
  local replies = {}
  local fake = {
    id = 9510,
    handlers = {},
    request = function(_, method, _, handler, bufnr)
      handler(replies[method] or { code = licensing.SERVER_CANCELLED, message = 'parked', data = vim.NIL }, nil,
        { method = method, bufnr = bufnr })
      return true, 1
    end,
  }
  licensing.install_quiet(fake)
  local got = {}
  local function ask(method)
    fake:request(method, {}, function(err, result) got[method] = { err = err, result = result } end)
    return got[method]
  end
  local res = ask('textDocument/completion')
  check('quiet: not parked, the error passes', res.err and res.err.code == licensing.SERVER_CANCELLED, vim.inspect(res))
  check('quiet: a null error.data does not retrigger the diagnostic pull',
    vim.deep_equal(res.err.data, { retriggerRequest = false }), vim.inspect(res.err))
  licensing._set(9510, lstate({ featuresDeclined = true, parkedReason = 'StartedUnlicensed' }))
  check('declined reads featuresDeclined', licensing.declined(9510) and not licensing.declined(9511))
  for _, method in ipairs({ 'textDocument/diagnostic', 'textDocument/completion', 'codeLens/resolve',
    'workspace/diagnostic', 'textDocument/semanticTokens/full', 'textDocument/inlayHint', 'textDocument/documentHighlight' }) do
    res = ask(method)
    check('quiet: parked ' .. method .. ' is empty', res.err == nil and res.result == nil, vim.inspect(res))
  end
  -- Asked for on purpose: an empty result would read as done or nothing found.
  for _, method in ipairs({ 'workspace/executeCommand', 'intellij/reloadWorkspace', 'workspace/willRenameFiles',
    'textDocument/formatting', 'textDocument/rename', 'workspace/symbol', 'callHierarchy/incomingCalls' }) do
    res = ask(method)
    check('quiet: parked ' .. method .. ' keeps its error, saying why', res.err and res.err.code == licensing.SERVER_CANCELLED
      and res.err.message == 'No active license. Activate a license to use Java and Kotlin features. Run :IntellijLspLicense.',
      vim.inspect(res))
  end

  -- Neovim drops the errors of these, so they would say "nothing found": a prompt instead, and no
  -- handler call while this is the only server that answers the method.
  local orig_get_clients = vim.lsp.get_clients
  local others = {}
  vim.lsp.get_clients = function() return others end
  notified = {}
  got['textDocument/references'] = nil
  fake:request('textDocument/references', {}, function(err, result)
    got['textDocument/references'] = { err = err, result = result }
  end)
  check('quiet: parked references does not say "nothing found"', got['textDocument/references'] == nil,
    vim.inspect(got['textDocument/references']))
  vim.wait(200, function() return #notified > 0 end, 10)
  check('quiet: parked references names the feature and the cause', #notified == 1 and notified[1].level == vim.log.levels.WARN
    and notified[1].msg == 'IntelliJ LSP: Find References needs an active license. No active license. Activate a license'
      .. ' to use Java and Kotlin features. Run :IntellijLspLicense.', vim.inspect(notified))
  fake:request('textDocument/definition', {}, function() end)
  vim.wait(50, function() return false end, 10)
  check('quiet: one prompt for requests moments apart', #notified == 1, vim.inspect(notified))
  others = { { id = 9520 } }
  res = nil
  fake:request('textDocument/hover', {}, function(err, result) res = { err = err, result = result } end, 1)
  check('quiet: with another server in the buffer, its answer still shows', res and res.err == nil and res.result == nil,
    vim.inspect(res))
  others = {}
  local sync = require('vim.lsp.client').request_sync(fake, 'textDocument/definition', {}, 5000)
  check('quiet: a synchronous caller (tagfunc) is not held up, and gets the error', sync and sync.err
    and sync.err.message:find(':IntellijLspLicense', 1, true), vim.inspect(sync))
  vim.lsp.get_clients = orig_get_clients

  res = ask('textDocument/codeAction')
  check('quiet: parked code actions offer to activate a license', res.err == nil
    and vim.deep_equal(res.result, { licensing.ACTIVATE_ACTION }), vim.inspect(res))
  check('quiet: the activate command is the client\'s', type(fake.commands[licensing.ACTIVATE_COMMAND]) == 'function')
  replies['textDocument/hover'] = { code = -32603, message = 'boom' }
  res = ask('textDocument/hover')
  check('quiet: other errors pass while parked', res.err and res.err.code == -32603, vim.inspect(res))
  fake.handlers['textDocument/documentHighlight'] = function(err, result) got.default = { err = err, result = result } end
  fake:request('textDocument/documentHighlight', {})
  check('quiet: a handler resolved from the client is wrapped too', got.default and got.default.err == nil, vim.inspect(got.default))

  -- The code action's command opens the prompt for the client that offered it.
  local orig_get_by_id = vim.lsp.get_client_by_id
  vim.lsp.get_client_by_id = function(id) return id == 9510 and fake or orig_get_by_id(id) end
  local dedupe = licensing.PROMPT_DEDUPE_MS
  licensing.PROMPT_DEDUPE_MS = 0
  notified = {}
  fake.commands[licensing.ACTIVATE_COMMAND]({ command = licensing.ACTIVATE_COMMAND }, { client_id = 9510 })
  vim.wait(200, function() return #notified > 0 end, 10)
  licensing.PROMPT_DEDUPE_MS = dedupe
  check('activate command: prompts for code actions', notified[1] and notified[1].msg:find('Code actions needs an active license', 1, true),
    vim.inspect(notified))
  vim.lsp.get_client_by_id = orig_get_by_id

  -- The hint above the first line, while the buffer's server is parked.
  local hbuf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(hbuf, 0, -1, false, { 'class A {}' })
  local orig_clients = vim.lsp.get_clients
  local attached = { fake }
  vim.lsp.get_clients = function() return attached end
  licensing.show_hint(hbuf)
  local marks = vim.api.nvim_buf_get_extmarks(hbuf, licensing.HINT_NS, 0, -1, { details = true })
  check('hint: shown at the end of the first line while parked', #marks == 1 and marks[1][2] == 0
    and marks[1][4].virt_text_pos == 'eol' and marks[1][4].virt_text[1][1] == licensing.HINT, vim.inspect(marks))
  licensing.show_hint(hbuf)
  check('hint: shown once', #vim.api.nvim_buf_get_extmarks(hbuf, licensing.HINT_NS, 0, -1, {}) == 1)
  attached = {}
  licensing.show_hint(hbuf)
  check('hint: cleared without a parked server', #vim.api.nvim_buf_get_extmarks(hbuf, licensing.HINT_NS, 0, -1, {}) == 0)
  attached = { fake }
  licensing.install_hints()
  licensing._set(9510, lstate({ featuresDeclined = true, parkedReason = 'GraceExpired' }))
  check('hint: follows a license change', #vim.api.nvim_buf_get_extmarks(hbuf, licensing.HINT_NS, 0, -1, {}) == 1)
  licensing._set(9510, lstate({ activeLicense = trial(27) }))
  check('hint: gone once licensed', #vim.api.nvim_buf_get_extmarks(hbuf, licensing.HINT_NS, 0, -1, {}) == 0)
  -- Let the refresh that licensing schedules run now, while the client is unknown, not in the checks below.
  vim.wait(50, function() return false end, 10)
  licensing._set(9510, lstate({ featuresDeclined = true, parkedReason = 'StartedUnlicensed' }))
  vim.lsp.get_clients = orig_clients
  vim.api.nvim_buf_delete(hbuf, { force = true })

  -- After activation: lenses and hints are asked for again, once features come back.
  local refreshed = {}
  local orig_handlers, orig_get = {}, vim.lsp.get_client_by_id
  for _, m in ipairs({ 'workspace/diagnostic/refresh', 'workspace/semanticTokens/refresh', 'workspace/codeLens/refresh',
    'workspace/inlayHint/refresh' }) do
    orig_handlers[m] = vim.lsp.handlers[m]
    vim.lsp.handlers[m] = function(_, _, ctx) table.insert(refreshed, m .. '@' .. ctx.client_id) end
  end
  vim.lsp.get_client_by_id = function(id) return id == 9510 and fake or orig_get(id) end
  licensing._set(9510, lstate({ featuresDeclined = true, parkedReason = 'StartedUnlicensed', jbaLicensingState = { authenticationStatus = 'Authenticating' } }))
  vim.wait(50, function() return false end, 10)
  check('refresh: nothing while still parked', #refreshed == 0, vim.inspect(refreshed))
  licensing._set(9510, lstate({ activeLicense = trial(27) }))
  vim.wait(500, function() return #refreshed == 4 end, 10)
  check('refresh: diagnostics, tokens, lenses and hints once licensed', vim.deep_equal(refreshed,
    { 'workspace/diagnostic/refresh@9510', 'workspace/semanticTokens/refresh@9510', 'workspace/codeLens/refresh@9510',
      'workspace/inlayHint/refresh@9510' }), vim.inspect(refreshed))
  licensing._set(9510, lstate({ activeLicense = trial(26) }))
  vim.wait(50, function() return false end, 10)
  check('refresh: not on every licensed push', #refreshed == 4, vim.inspect(refreshed))
  res = ask('textDocument/completion')
  check('quiet: licensed again, errors pass', res.err ~= nil, vim.inspect(res))
  res = ask('textDocument/references')
  check('quiet: licensed again, references get their error', res.err ~= nil, vim.inspect(res))
  for m, h in pairs(orig_handlers) do vim.lsp.handlers[m] = h end
  vim.lsp.get_client_by_id = orig_get
  licensing.reset(9510)
end

vim.notify = orig_notify
licensing.notice_path = orig_path
vim.fn.delete(dir, 'rf')
end)()

-- ---------------------------------------------------------------------------
-- :checkhealth: the license of a running server, and the consent it was launched with
-- ---------------------------------------------------------------------------
;(function()
local health = require('intellij-lsp.health')
local licensing = require('intellij-lsp.licensing')
local function view_of(t)
  return licensing.project(vim.tbl_extend('force', {
    jbaLicensingState = { authenticationStatus = 'NotAuthenticated' },
    licenseServerFlowState = { kind = 'notConfigured' },
    featuresDeclined = false,
  }, t))
end
local function levels(report) return table.concat(vim.tbl_map(function(i) return i.level end, report), ',') end
local ENV = { INTELLIJ_REGION = 'europe' }

local r = health._license_report(view_of({ activeLicense = {
  source = 'trial', status = 'Valid', product = 'intellij-server', daysLeft = 27, validThrough = '2026-11-17' } }), ENV)
check('health: licensed is ok, then the launch consent', levels(r) == 'ok,info', vim.inspect(r))
check('health: source, status and days left',
  r[1].text == '  license: License is active (Trial) [source Trial, status Valid, valid through 2026-11-17 (27 days left)]',
  r[1].text)
check('health: region and data sharing from the environment, none when absent',
  r[2].text == '  launched with region europe, data sharing none', r[2].text)

r = health._license_report(view_of({ featuresDeclined = true, parkedReason = 'StartedUnlicensed' }),
  { INTELLIJ_REGION = 'apac', INTELLIJ_DATA_SHARING = 'anonymous' })
check('health: parked is an error naming the reason', r[1].level == 'error'
  and r[1].text:find('[parked: StartedUnlicensed]', 1, true) ~= nil, vim.inspect(r[1]))
check('health: parked advice names the command',
  vim.iter(r[1].advice):any(function(a) return a:find(':IntellijLspLicense', 1, true) ~= nil end), vim.inspect(r[1].advice))
check('health: data sharing as launched', r[2].text == '  launched with region apac, data sharing anonymous', r[2].text)

r = health._license_report(view_of({ featuresDeclined = true, parkedReason = 'LicenseRevoked', activeLicense = {
  source = 'activationCode', status = 'Revoked', product = 'intellij-server' } }), ENV)
check('health: a revoked license shows its source and status',
  r[1].text:find('source Activation Code, status Revoked, parked: LicenseRevoked', 1, true) ~= nil, r[1].text)

r = health._license_report(view_of({ activeLicense = {
  source = 'subscription', status = 'Valid', product = 'intellij-server', daysLeft = 200, validThrough = '2027-05-01' },
  jbaLicensingState = { authenticationStatus = 'FailedToProlongateAuthentication', accountInfo = { displayName = 'A' } } }), ENV)
check('health: session expired warns with login', r[1].level == 'warn' and r[1].advice[1]:find('login', 1, true) ~= nil,
  vim.inspect(r[1]))

r = health._license_report(view_of({ activeLicense = { source = 'trial', status = 'Expired', product = 'intellij-server' },
  graceDeadline = 1792000000000 }), ENV)
check('health: grace warns', r[1].level == 'warn' and r[1].text:find('Features work until', 1, true) ~= nil, r[1].text)

r = health._license_report(view_of({ licenseServerFlowState = { kind = 'configured', serverAddress = 'https://ls.example',
  floatingTicketStatus = 'FailedToRefresh' }, featuresDeclined = true, parkedReason = 'GraceExpired' }), ENV)
check('health: a license server failure gets its own line', levels(r) == 'error,warn,info'
  and r[2].text:find('license server', 1, true) ~= nil, vim.inspect(r))

r = health._license_report(view_of({ activeLicense = {
  source = 'licenseServer', status = 'Valid', product = 'intellij-server', serverAddress = 'https://ls.example' } }),
  { JETBRAINS_LICENSE_SERVER = 'https://ls.example', INTELLIJ_REGION = 'europe' })
check('health: an environment license is named', r[2].level == 'info'
  and r[2].text:find('JETBRAINS_LICENSE_SERVER', 1, true) ~= nil, vim.inspect(r))

r = health._license_report(false, ENV)
check('health: a server without the protocol says so', levels(r) == 'info,info'
  and r[1].text:find('does not report', 1, true) ~= nil, vim.inspect(r))
r = health._license_report(nil, nil)
check('health: unreadable state warns, no consent line without an env', levels(r) == 'warn', vim.inspect(r))
end)()

-- ---------------------------------------------------------------------------
-- Every licensing float: centred, one width, the product in the title
-- ---------------------------------------------------------------------------
;(function()
local activation = require('intellij-lsp.activation')
local consent = require('intellij-lsp.consent')
local license = require('intellij-lsp.license')
local signin = require('intellij-lsp.signin')
local function shape(win)
  local cfg = vim.api.nvim_win_get_config(win)
  return { width = cfg.width, col = cfg.col, row = cfg.row, height = cfg.height, title = cfg.title and cfg.title[1][1] or '' }
end
local function centred(sh)
  return sh.width == activation.width() and math.abs((vim.o.columns - sh.width) / 2 - sh.col) <= 1
    and math.abs((vim.o.lines - sh.height) / 2 - 1 - sh.row) <= 1
end
local floats = {}
local function grab(name)
  local win = vim.api.nvim_get_current_win()
  floats[name] = shape(win)
  return win
end

-- Remove: the whole question in the float, not cut into the title.
local said
license._confirm('Remove the license (Trial)? Java and Kotlin features stop until another license is active.', 'Remove',
  function() said = 'yes' end)
local win = grab('confirm')
local text = table.concat(vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(win), 0, -1, false), '\n')
check('confirm: the question in full, then Remove and Cancel', text:find('Remove the license (Trial)?', 1, true)
  and text:find(' 1  Remove', 1, true) and text:find(' 2  Cancel', 1, true), text)
check('confirm: titled with the product', floats.confirm.title == ' Java and Kotlin by IntelliJ IDEA · License ',
  floats.confirm.title)
vim.api.nvim_feedkeys('1', 'x', false)
vim.wait(500, function() return said ~= nil end, 10)
check('confirm: 1 runs it', said == 'yes')

activation.choose({ text = { 'Pick one' }, items = { 'a', 'b' } }, function() end)
vim.api.nvim_win_close(grab('choose'), true)
activation._open_input({ title = 'License server URL', single = true, lines = { 'https://' } }, function() end)
win = grab('url')
check('url input: one line, titled', floats.url.height == 1
  and floats.url.title == ' Java and Kotlin by IntelliJ IDEA · License server URL ', vim.inspect(floats.url))
vim.api.nvim_win_close(win, true)
vim.cmd('stopinsert')
activation._open_input({ title = 'Activation code' }, function() end)
vim.api.nvim_win_close(grab('code'), true)
vim.cmd('stopinsert')
consent._choose('region', 1, 3, function() end)
vim.api.nvim_win_close(grab('setup'), true)
consent._open_eula('terms', function() end, { index = 2, total = 3 })
vim.api.nvim_win_close(grab('eula'), true)
local orig_open, orig_copy = signin._open, signin._copy
signin._open, signin._copy = function() return true end, function() return false end
signin.show_page('https://account.jetbrains.com/x', 9701)
grab('signin')
signin.close()
signin._open, signin._copy = orig_open, orig_copy
local off = {}
for name, sh in pairs(floats) do
  -- The EULA fills the height on purpose; only its width and column count.
  local ok = name == 'eula' and sh.width == activation.width() or centred(sh)
  if not ok then off[name] = sh end
end
check('every licensing float is centred at one width', vim.tbl_isempty(off) and vim.tbl_count(floats) == 7, vim.inspect(off))
for name, sh in pairs(floats) do
  if not sh.title:find('Java and Kotlin by IntelliJ IDEA', 1, true) then off[name] = sh.title end
end
check('every licensing float names the product', vim.tbl_isempty(off), vim.inspect(off))
end)()

-- ---------------------------------------------------------------------------
-- Restart and cache clearing wait for the old server to exit
-- ---------------------------------------------------------------------------
-- Stand-in servers that take their time to exit, or never answer `initialize`. Every launch goes
-- through `client.config`, so swapping its `cmd` covers the replacement servers too.
;(function()
  local init = require('intellij-lsp')
  local consent = require('intellij-lsp.consent')
  local saved = { config = init.config, client_config = client.config, store = consent.store_path,
    stop = init.STOP_TIMEOUT, kill = init.KILL_TIMEOUT, notify = vim.notify }
  local proj = vim.fs.normalize(vim.uv.fs_realpath(vim.fn.tempname()) or vim.fn.tempname())
  if vim.uv.fs_stat(proj) == nil then vim.fn.mkdir(proj, 'p') end
  proj = vim.uv.fs_realpath(proj)
  vim.fn.writefile({ '<project/>' }, proj .. '/pom.xml')
  vim.fn.writefile({ 'class Main {}' }, proj .. '/Main.java')
  local index = proj .. '-index'
  local store = vim.fn.tempname() .. '-restart.json'
  consent.store_path = function() return store end
  consent._reset()
  init.config = { server_path = SERVER, region = 'europe', data_sharing = 'none' }
  local notes = {}
  vim.notify = function(msg) notes[#notes + 1] = msg end

  local mode = { exit_ms = 0, initialize = true, exits = true }
  local alive, overlapped, owner_at_start = 0, false, {}
  client.config = function(root, cfg, settled)
    local c = saved.client_config(root, cfg, settled)
    c.cmd = function(dispatch)
      if alive > 0 then overlapped = true end
      owner_at_start[#owner_at_start + 1] = launch.system_path_owner(c.system_path)
      alive = alive + 1
      local gone = false
      local function exit()
        if gone or not mode.exits then return end
        vim.defer_fn(function()
          gone = true
          alive = alive - 1
          dispatch.on_exit(0, 15)
        end, mode.exit_ms)
      end
      return {
        request = function(method, _, callback)
          if method == 'initialize' and mode.initialize then
            vim.schedule(function()
              callback(nil, { capabilities = { experimental = { indexDir = index } } })
            end)
          elseif method == 'shutdown' then
            vim.schedule(function() callback(nil, nil) end)
          end
          return true, 1
        end,
        notify = function(method)
          if method == 'exit' then exit() end
          return true
        end,
        is_closing = function() return gone end,
        terminate = exit,
      }
    end
    return c
  end

  local function ours()
    return vim.tbl_filter(function(c) return c.config.root_dir == proj end,
      vim.lsp.get_clients({ name = client.NAME, _uninitialized = true }))
  end

  local src = vim.fn.bufadd(proj .. '/Main.java')
  vim.fn.bufload(src)
  vim.bo[src].filetype = 'java'
  init._start_for_buffer(src)
  vim.wait(2000, function() return #ours() == 1 and ours()[1].initialized end, 20)
  local first = ours()[1]
  check('restart fixture: a server runs', first ~= nil and first.initialized and alive == 1, alive)

  if first then
    -- Slow shutdown: two seconds of the old server going on holding the cache directory.
    mode.exit_ms = 1500
    init.restart()
    vim.wait(700)
    check('restart: no replacement while the old server is alive', alive == 1 and #vim.tbl_filter(function(c)
      return c.id ~= first.id end, ours()) == 0, alive)
    vim.wait(4000, function()
      local now = ours()
      return #now == 1 and now[1].id ~= first.id and now[1].initialized
    end, 20)
    local second = ours()[1]
    check('restart: the replacement starts once the old one has exited', second and second.id ~= first.id and alive == 1,
      second and second.id)
    check('restart: the two servers never overlapped', not overlapped)
    vim.wait(300)
    check("restart: the old exit leaves the replacement's claim alone",
      second and launch.system_path_owner(second.config.system_path) == vim.uv.os_getpid(),
      second and tostring(launch.system_path_owner(second.config.system_path)))

    -- Clear cache: the index survives as long as the server that has it open.
    vim.fn.mkdir(index, 'p')
    init.clear_cache()
    vim.wait(700)
    check('clear cache: the index is kept while the server is alive', vim.uv.fs_stat(index) ~= nil and alive == 1)
    vim.wait(4000, function() return #ours() == 1 and ours()[1].id ~= second.id end, 20)
    check('clear cache: the index is deleted once the server has exited', vim.uv.fs_stat(index) == nil)
    check('clear cache: then a server starts again', #ours() == 1 and ours()[1].id ~= second.id and not overlapped)

    -- Stuck in `initialize`: still found, stopped and replaced.
    mode.exit_ms, mode.initialize = 0, false
    init.restart()
    vim.wait(2000, function() return #ours() == 1 and not ours()[1].initialized end, 20)
    local stuck = ours()[1]
    check('restart fixture: a server stuck in initialize', stuck and not stuck.initialized)
    mode.initialize = true
    init.restart()
    vim.wait(3000, function() return #ours() == 1 and ours()[1].id ~= stuck.id and ours()[1].initialized end, 20)
    check('restart: a server stuck in initialize is replaced', #ours() == 1 and ours()[1].id ~= (stuck and stuck.id),
      vim.inspect(vim.tbl_map(function(c) return c.id end, ours())))

    -- One that never exits: reported, and nothing starts on top of it.
    init.STOP_TIMEOUT, init.KILL_TIMEOUT = 200, 200
    mode.exits = false
    local immortal = ours()[1]
    notes = {}
    init.restart()
    vim.wait(1500, function() return #notes > 0 end, 20)
    check('restart: a server that will not exit is reported', (notes[1] or ''):find('did not exit', 1, true), vim.inspect(notes))
    check('restart: and no second server starts beside it', #ours() == 1 and ours()[1].id == immortal.id and alive == 1, alive)
  end

  init.STOP_TIMEOUT, init.KILL_TIMEOUT = saved.stop, saved.kill
  mode.exits = true
  for _, c in ipairs(ours()) do c:stop(true) end
  vim.wait(1000, function() return #ours() == 0 end, 20)
  vim.notify, client.config, consent.store_path, init.config = saved.notify, saved.client_config, saved.store, saved.config
  vim.api.nvim_buf_delete(src, { force = true })
end)()

-- ---------------------------------------------------------------------------
-- :IntellijLspRename keeps the buffer: unsaved changes and the server's edits survive the move
-- ---------------------------------------------------------------------------
;(function()
  local init = require('intellij-lsp')
  local dir = vim.uv.fs_realpath(vim.fn.tempname()) or vim.fn.tempname()
  vim.fn.mkdir(dir, 'p')
  dir = vim.uv.fs_realpath(dir)
  local old, new, user = dir .. '/Old.java', dir .. '/New.java', dir .. '/User.java'
  vim.fn.writefile({ 'class Old {', '}' }, old)
  vim.fn.writefile({ 'class User { Old o; }' }, user)
  local function edit(uri, line, from, to, text)
    return { textDocument = { uri = uri, version = vim.NIL }, edits = {
      { range = { start = { line = line, character = from }, ['end'] = { line = line, character = to } }, newText = text },
    } }
  end
  local renamed
  local cfg = vim.tbl_extend('force', client.config(dir, {}), {
    root_dir = dir,
    cmd = function(dispatch)
      return {
        request = function(method, params, callback)
          if method == 'initialize' then
            vim.schedule(function() callback(nil, { capabilities = {} }) end)
          elseif method == 'workspace/willRenameFiles' then
            renamed = params.files[1]
            vim.schedule(function()
              callback(nil, { documentChanges = {
                edit(params.files[1].oldUri, 0, 6, 9, 'New'),
                edit(vim.uri_from_fname(user), 0, 13, 16, 'New'),
              } })
            end)
          elseif method == 'shutdown' then
            callback(nil, nil)
          end
          return true, 1
        end,
        notify = function(method)
          if method == 'exit' then dispatch.on_exit(0, 0) end
          return true
        end,
        is_closing = function() return false end,
        terminate = function() dispatch.on_exit(0, 15) end,
      }
    end,
  })
  local id = vim.lsp.start(cfg, { attach = false })
  local c = id and vim.lsp.get_client_by_id(id)
  vim.wait(2000, function() return c and c.initialized end, 20)

  local hidden = vim.o.hidden
  vim.o.hidden = true
  vim.cmd.edit(vim.fn.fnameescape(old))
  local buf = vim.api.nvim_get_current_buf()
  vim.api.nvim_buf_set_lines(buf, 1, 1, false, { '  int unsaved;' })
  local real_notify = vim.notify
  local notes = {}
  vim.notify = function(msg) notes[#notes + 1] = msg end
  init.rename_file(new)
  vim.wait(3000, function() return #notes > 0 end, 20)
  vim.notify = real_notify

  check('rename: asks the server about the move', renamed and renamed.newUri == vim.uri_from_fname(new), vim.inspect(renamed))
  check('rename: reports success', (notes[1] or ''):find('renamed to', 1, true), vim.inspect(notes))
  check('rename: the old file is gone', vim.uv.fs_stat(old) == nil)
  local on_disk = vim.uv.fs_stat(new) and vim.fn.readfile(new) or {}
  check('rename: the moved file keeps the unsaved change and the server edit',
    on_disk[1] == 'class New {' and on_disk[2] == '  int unsaved;', vim.inspect(on_disk))
  check('rename: the same buffer now has the new name',
    vim.api.nvim_buf_is_valid(buf) and vim.api.nvim_buf_get_name(buf) == new and vim.api.nvim_get_current_buf() == buf,
    vim.api.nvim_buf_is_valid(buf) and vim.api.nvim_buf_get_name(buf))
  check('rename: the buffer is not left modified', vim.api.nvim_buf_is_valid(buf) and not vim.bo[buf].modified)
  local ref = vim.fn.bufnr(user)
  check('rename: references elsewhere are updated',
    ref > 0 and vim.api.nvim_buf_get_lines(ref, 0, 1, false)[1] == 'class User { New o; }',
    ref > 0 and vim.api.nvim_buf_get_lines(ref, 0, 1, false)[1])
  local write_ok, write_err = pcall(vim.cmd, 'write')
  check('rename: a later :write needs no !', write_ok, tostring(write_err))

  -- A taken name is refused before the server is asked, so no reference points at a file that never moved.
  renamed, notes = nil, {}
  vim.notify = function(msg) notes[#notes + 1] = msg end
  init.rename_file(user)
  vim.notify = real_notify
  check('rename: an existing target is refused up front', renamed == nil and (notes[1] or ''):find('already exists', 1, true),
    vim.inspect(notes))

  vim.o.hidden = hidden
  vim.lsp.stop_client(id, true)
  for _, b in ipairs({ buf, ref }) do
    if b > 0 and vim.api.nvim_buf_is_valid(b) then vim.api.nvim_buf_delete(b, { force = true }) end
  end
end)()

-- ---------------------------------------------------------------------------
-- Run and debug with two projects open, and next to another adapter's sessions
-- ---------------------------------------------------------------------------
-- A stand-in nvim-dap: listeners and adapters as tables, `run` recorded. run.lua and debug.lua are
-- loaded afresh against it, since both wire their listeners when nvim-dap is there.
;(function()
  local listeners = {}
  for _, phase in ipairs({ 'before', 'after' }) do
    listeners[phase] = setmetatable({}, { __index = function(t, k) t[k] = {}; return t[k] end })
  end
  local runs = {}
  local fake_dap = { listeners = listeners, adapters = {}, run = function(config) runs[#runs + 1] = config end,
    session = function() return nil end }
  local saved = { run = package.loaded['intellij-lsp.run'], debug = package.loaded['intellij-lsp.debug'] }
  package.loaded['dap'] = fake_dap
  package.loaded['intellij-lsp.run'], package.loaded['intellij-lsp.debug'] = nil, nil
  local run_mod = require('intellij-lsp.run')
  local debug_mod = require('intellij-lsp.debug')
  run_mod.setup()
  debug_mod.setup()

  local seen = {} --- @type { root: string, method: string, command: string|nil }[]
  local function project(name)
    local root = vim.fs.normalize(vim.fn.tempname() .. '-' .. name)
    vim.fn.mkdir(root, 'p')
    vim.fn.writefile({ '<project/>' }, root .. '/pom.xml')
    vim.fn.writefile({ 'package p;', 'class Main {', '}' }, root .. '/Main.java')
    local cmd = function(dispatch)
      return {
        request = function(method, params, callback)
          if method ~= 'initialize' and method ~= 'shutdown' then
            seen[#seen + 1] = { root = root, method = method, command = params and params.command }
          end
          local result
          if method == 'initialize' then
            result = { capabilities = { documentSymbolProvider = true, executeCommandProvider = { commands = {} } } }
          elseif method == 'textDocument/documentSymbol' then
            result = { { name = 'Main', kind = 5, range = rng(1, 0, 1), selectionRange = rng(1, 6, 10) } }
          elseif params and params.command == 'intellij.java.resolveLaunch' then
            result = { javaExec = '/jdk-' .. name .. '/bin/java', classpath = { root .. '/target/classes' }, workingDirectory = root }
          elseif params and params.command == 'start_debug_server' then
            result = 5005
          end
          vim.schedule(function() callback(nil, result) end)
          return true, 1
        end,
        notify = function(method)
          if method == 'exit' then dispatch.on_exit(0, 0) end
          return true
        end,
        is_closing = function() return false end,
        terminate = function() dispatch.on_exit(0, 15) end,
      }
    end
    return root, { name = client.NAME, cmd = cmd, root_dir = root,
      workspace_folders = { { uri = vim.uri_from_fname(root), name = name } } }
  end

  local root_a, cfg_a = project('a')
  local root_b, cfg_b = project('b')
  local id_a = vim.lsp.start(cfg_a, { attach = false })
  local buf_b = vim.fn.bufadd(root_b .. '/Main.java')
  vim.fn.bufload(buf_b)
  local id_b = vim.lsp.start(cfg_b, { bufnr = buf_b })
  vim.wait(2000, function()
    local a, b = vim.lsp.get_client_by_id(id_a), vim.lsp.get_client_by_id(id_b)
    return a and a.initialized and b and b.initialized
  end, 20)
  check('two projects: A is the first client', vim.lsp.get_clients({ name = client.NAME })[1].id == id_a)

  vim.api.nvim_set_current_buf(buf_b)
  vim.api.nvim_win_set_cursor(0, { 2, 0 })
  run_mod.run_at_cursor(true, { build = false })
  vim.wait(2000, function() return #runs == 1 end, 20)
  local config = runs[1]
  check('two projects: B resolves the launch for its own class', config and config.javaExec == '/jdk-b/bin/java',
    vim.inspect(seen))
  local resolved_on = vim.tbl_filter(function(s) return s.command == 'intellij.java.resolveLaunch' end, seen)
  check('two projects: A is never asked', #resolved_on == 1 and resolved_on[1].root == root_b, vim.inspect(resolved_on))

  local adapter
  fake_dap.adapters.intellij_jvm(function(a) adapter = a end, config or {})
  vim.wait(2000, function() return adapter ~= nil end, 20)
  local debug_on = vim.tbl_filter(function(s) return s.command == 'start_debug_server' end, seen)
  check('two projects: the debug server starts on B', #debug_on == 1 and debug_on[1].root == root_b, vim.inspect(debug_on))
  local sent
  if adapter and adapter.enrich_config then adapter.enrich_config(config, function(c) sent = c end) end
  check('two projects: the client id is not sent to the server', sent and sent.intellijClientId == nil
    and sent.mainClass == 'Main' and config.intellijClientId == id_b, vim.inspect(sent))

  -- The lens command: the client it came from, not the first one.
  seen, runs = {}, {}
  vim.lsp.commands['intellij.jvm.runMain']({ arguments = { { mainClass = 'p.Main' } } }, { client_id = id_b, bufnr = buf_b })
  vim.wait(2000, function() return #runs == 1 end, 20)
  check('two projects: a lens launches on its own server', runs[1] and runs[1].javaExec == '/jdk-b/bin/java', vim.inspect(seen))

  -- Another adapter's session: no IntelliJ panel, no stack requests, no output in the panel.
  local requests = {}
  local function session(id, type_)
    return { id = id, config = { type = type_ }, stopped_thread_id = nil,
      request = function(_, command) requests[#requests + 1] = { session = id, command = command } end }
  end
  local py, jvm = session(91, 'python'), session(92, 'intellij_jvm')
  local wins = #vim.api.nvim_list_wins()
  local output_mod = require('intellij-lsp.output')
  output_mod._reset()
  listeners.before.event_output['intellij-lsp.run.panel'](py, { output = 'python says hi\n' })
  listeners.after.event_output['intellij-lsp.run'](py, { output = 'python says hi\n' })
  listeners.after.event_stopped['intellij-lsp.debug'](py, { threadId = 1 })
  listeners.after.event_continued['intellij-lsp.debug'](py, {})
  vim.wait(200)
  check('another adapter: a stop sends no request to it', #requests == 0, vim.inspect(requests))
  check('another adapter: no panel opens', #vim.api.nvim_list_wins() == wins and not output_mod.is_open(),
    #vim.api.nvim_list_wins())
  local panel_lines = table.concat(vim.api.nvim_buf_get_lines(output_mod.buf(), 0, -1, false), '\n')
  check('another adapter: its output stays out of the panel', not panel_lines:find('python says hi', 1, true), panel_lines)

  listeners.after.event_stopped['intellij-lsp.debug'](jvm, { threadId = 1 })
  vim.wait(200)
  check('own session: a stop asks for its stack', #requests == 1 and requests[1].session == 92
    and requests[1].command == 'stackTrace', vim.inspect(requests))

  for _, w in ipairs(vim.api.nvim_list_wins()) do
    if #vim.api.nvim_list_wins() > 1 and vim.api.nvim_win_get_config(w).relative == '' and w ~= vim.api.nvim_get_current_win() then
      pcall(vim.api.nvim_win_close, w, true)
    end
  end
  vim.lsp.stop_client({ id_a, id_b }, true)
  vim.api.nvim_buf_delete(buf_b, { force = true })
  package.loaded['dap'] = nil
  package.loaded['intellij-lsp.run'], package.loaded['intellij-lsp.debug'] = saved.run, saved.debug
end)()

print(failures == 0 and '\nALL UNIT CHECKS PASSED' or ('\n' .. failures .. ' UNIT CHECK(S) FAILED'))
vim.cmd(failures == 0 and 'qa!' or 'cq!')
