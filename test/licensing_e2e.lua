-- End-to-end: real plugin -> real server with an isolated, empty license store.
--
--   IJLS_SERVER=<bundle>/bin/intellij-server \
--     nvim --headless -u NONE -l test/licensing_e2e.lua
--
-- Recipe: testing the unlicensed path on a machine that already has a license
--
-- The server keeps its licensing state in three places. Only the first one can be redirected:
--
--   1. The license store, `~/Library/Application Support/JetBrains/IntelliJServer` on macOS
--      (`~/.config/JetBrains/IntelliJServer` on Linux). It holds `intellij-server.key` (trial,
--      activation code, JetBrains Account asset, license server URL) and `eula-accepted.hashes`.
--      `-Dintellij.server.license.dir=<tmp>` (the plugin's `jvm_args`, which reach the launcher
--      as `IJ_JAVA_OPTIONS`) moves it. A fresh dir starts parked with `StartedUnlicensed`.
--
--   2. `java.util.prefs`, shared machine-wide with every JetBrains IDE and Toolbox: the JetBrains
--      Account sign-in, OAuth tokens, the license-server ticket, and a second copy of the
--      accepted EULA hashes. The license dir does not move it. On Linux
--      `-Djava.util.prefs.userRoot=<tmp>` would, but not on macOS: the JBR's
--      `FileSystemPreferencesFactory` has no native `chmod`, every license read throws
--      UnsatisfiedLinkError, and `license status` hangs retrying it every 30 s.
--      Consequences:
--      - JetBrains Account: a fresh license dir starts unlicensed only while nobody on this OS
--        user is signed in to a JetBrains Account. When someone is signed in (desktop IDE,
--        Toolbox), discovery provisions a license from that account into the fresh dir.
--        The pre-flight below checks for this and skips instead of failing.
--        (Checked 2026-10-20 on 263.7084.0: `NotAuthenticated` here, fresh dir unlicensed.)
--      - EULA: the prefs copy means a fresh license dir still counts the EULA as accepted;
--        launching without `--eula` starts normally. For consent tests, set
--        `INTELLIJ_SERVER_EULA_PERSISTENCE=false`. That turns off reading *and* recording of
--        both copies, so the launch then depends on `--eula` alone, and recording nothing
--        keeps the test from changing machine state:
--          no `--eula`, persistence off -> exit 11
--          `--eula <hash>`, persistence off -> starts, nothing written to the license dir
--          `EULA.txt` modified or missing -> exit 12. To get this without touching the real
--          bundle, use an APFS clone: `cp -cR <bundle> <tmp>` (instant), then edit
--          `<tmp>/EULA.txt`.
--
--      - Trial: starting the anonymous trial in a fresh license dir hands back this machine's
--        existing trial (same license id, same end date), not a new 30 days. So "trial start
--        licenses a parked server" is testable as long as the machine's trial is valid, and
--        will fail once it has ended. (Checked 2026-10-20: trial valid through 2026-11-17.)
--
--   3. Environment licenses (`INTELLIJ_SERVER_LICENSE`, `INTELLIJ_SERVER_LICENSE_FILE`,
--      `JETBRAINS_LICENSE_SERVER`) override everything. They must be unset for this test.
--
-- Pushes of `jetbrains/licensing/state` only go to clients that advertise
-- `experimental.licensingUi`, which the plugin does (`client.capabilities`); `licensing.lua` keeps
-- the pushed state.
vim.opt.runtimepath:prepend(vim.fs.dirname(vim.fs.dirname(debug.getinfo(1, 'S').source:sub(2))))
vim.cmd('filetype plugin indent on')
vim.cmd('syntax off')

local SERVER = assert(vim.env.IJLS_SERVER, 'IJLS_SERVER not set')

local failures, notes = 0, {}
local function check(name, cond, detail)
  if cond then
    print('ok   ' .. name)
  else
    failures = failures + 1
    print('FAIL ' .. name .. (detail and ('  -> ' .. tostring(detail)) or ''))
  end
end
local function note(s) table.insert(notes, s) print('     .. ' .. s) end

for _, var in ipairs({ 'INTELLIJ_SERVER_LICENSE', 'INTELLIJ_SERVER_LICENSE_FILE', 'JETBRAINS_LICENSE_SERVER' }) do
  if vim.env[var] then
    print('SKIP ' .. var .. ' is set; the environment license would win over the empty store')
    vim.cmd('cq! 2')
  end
end

--- `:checkhealth intellij-lsp` with `vim.health` captured: `{ level, text }` per reported line.
local function health_lines()
  local out, orig = {}, {}
  for _, level in ipairs({ 'start', 'ok', 'info', 'warn', 'error' }) do
    orig[level] = vim.health[level]
    vim.health[level] = function(text) table.insert(out, { level = level, text = text }) end
  end
  local ok, err = pcall(require('intellij-lsp.health').check)
  for level, fn in pairs(orig) do vim.health[level] = fn end
  if not ok then table.insert(out, { level = 'crash', text = tostring(err) }) end
  return out
end
local function health_line(lines, needle)
  for _, l in ipairs(lines) do
    if l.text:find(needle, 1, true) then return l end
  end
  return nil
end

local LICENSE_DIR = vim.fn.tempname() .. '-license'
vim.fn.mkdir(LICENSE_DIR, 'p')
local JVM_ARGS = { '-Dintellij.server.license.dir=' .. LICENSE_DIR }
vim.env.INTELLIJ_SERVER_EULA_PERSISTENCE = 'false'

-- Pre-flight: a JetBrains Account sign-in from a desktop IDE licenses even an empty store.
local status = vim.system({ SERVER, 'license', 'status', '--json' }, {
  env = { IJ_JAVA_OPTIONS = table.concat(JVM_ARGS, ' ') },
  text = true,
}):wait(120000)
local json = status.stdout and status.stdout:match('%b{}')
local ok, pre = pcall(vim.json.decode, json or '')
check('license status --json answers', ok and type(pre) == 'table', status.stdout .. status.stderr)
if ok and type(pre) == 'table' and pre.activeLicense then
  print('SKIP the isolated store came up licensed (' .. tostring(pre.activeLicense.source) ..
    '): a JetBrains Account sign-in on this machine leaks through java.util.prefs. ' ..
    'Run as an OS user without one.')
  vim.cmd('cq! 2')
end
note('pre-flight: ' .. vim.inspect(pre and pre.jbaLicensingState))

local root = vim.fn.tempname() .. '-licensing'
vim.fn.mkdir(root .. '/src/main/java/com/example', 'p')
vim.fn.writefile({
  '<?xml version="1.0" encoding="UTF-8"?>',
  '<project xmlns="http://maven.apache.org/POM/4.0.0">',
  '  <modelVersion>4.0.0</modelVersion>',
  '  <groupId>com.example</groupId>',
  '  <artifactId>ijlicense</artifactId>',
  '  <version>1.0-SNAPSHOT</version>',
  '</project>',
}, root .. '/pom.xml')
vim.fn.writefile({
  'package com.example;',
  '',
  'public class Main {}',
}, root .. '/src/main/java/com/example/Main.java')
local MAIN = vim.uv.fs_realpath(root) .. '/src/main/java/com/example/Main.java'

local licensing = require('intellij-lsp.licensing')
local events = {}
vim.api.nvim_create_autocmd('User', {
  pattern = licensing.EVENT,
  callback = function(ev) table.insert(events, ev.data) end,
})

-- What the startup sync sends, and what it offers.
local sent, offers = {}, {}
local orig_request = licensing.request
licensing.request = function(c, name, ...)
  table.insert(sent, { client_id = c.id, name = name })
  return orig_request(c, name, ...)
end
licensing.offer_activation = function(c, view, env_var)
  table.insert(offers, { client_id = c.id, kind = view.kind, env_var = env_var })
end
local function sent_by(id)
  return vim.tbl_map(function(s) return s.name end, vim.tbl_filter(function(s) return s.client_id == id end, sent))
end

require('intellij-lsp').setup({
  server_path = SERVER,
  accept_eula = true,
  -- Not 'none': that one sets no variable, so it would not show the consent reaching the server.
  region = 'europe',
  data_sharing = 'anonymous',
  build_tool = 'maven',
  jvm_args = JVM_ARGS,
})

vim.cmd('edit ' .. MAIN)
local bufnr = vim.api.nvim_get_current_buf()

local client
vim.wait(120000, function()
  client = vim.lsp.get_clients({ name = 'intellij', bufnr = bufnr })[1]
  return client ~= nil
end, 500)
check('client attached', client ~= nil)
if not client then
  print('\nno client; aborting')
  vim.cmd('cq!')
end

-- The server rejects an unknown region or data-sharing level at launch, so getting this far with
-- both set means it accepted them.
check('consent passed: INTELLIJ_REGION', client.config.cmd_env.INTELLIJ_REGION == 'europe',
  tostring(client.config.cmd_env.INTELLIJ_REGION))
check('consent passed: INTELLIJ_DATA_SHARING', client.config.cmd_env.INTELLIJ_DATA_SHARING == 'anonymous',
  tostring(client.config.cmd_env.INTELLIJ_DATA_SHARING))
check('consent passed: --eula <hash>', vim.tbl_contains(client.config.cmd, '--eula'), table.concat(client.config.cmd, ' '))
check('server initialized with the consent', vim.wait(120000, function() return client.initialized end, 200))

note('server ' .. (client.server_info and client.server_info.name or '?') ..
     ' ' .. (client.server_info and client.server_info.version or '?'))
note('server experimental capabilities: ' .. vim.inspect(client.server_capabilities.experimental))

check('server advertises the licensing protocol', licensing.supported(client),
  vim.inspect(client.server_capabilities.experimental))

-- The server pushes a baseline state right after `initialized`, before anything asks for it.
check('state push arrives and is stored', vim.wait(30000, function() return licensing.state(client.id) ~= nil end, 100))
check('the push fires User IntellijLspLicense', events[1] and events[1].client_id == client.id, vim.inspect(events[1]))
local pushed = licensing.view(client.id)
if pushed then note('pushed view: ' .. pushed.kind .. ' / ' .. tostring(pushed.parked_reason)) end

-- Startup: state/get, then discovery (the store is empty), then the activation offer.
check('startup syncs with state/get', vim.wait(30000, function() return sent_by(client.id)[1] == 'state/get' end, 100),
  vim.inspect(sent))
check('startup runs discovery on an empty store',
  vim.wait(70000, function() return sent_by(client.id)[2] == 'discovery/autoActivate' end, 100), vim.inspect(sent))
check('startup offers the activation once', vim.wait(70000, function() return #offers > 0 end, 100)
  and #offers == 1 and offers[1].client_id == client.id and offers[1].kind == 'parked' and offers[1].env_var == nil,
  vim.inspect(offers))

local err, view
licensing.refresh(client, function(e, vw) err, view = e, vw or false end)
check('state/get answers', vim.wait(30000, function() return view ~= nil end, 100) and not err,
  vim.inspect(err))
local state = licensing.state(client.id)
check('isolated store has no active license', state and state.activeLicense == nil,
  vim.inspect(state and state.activeLicense))
check('features declined', state and state.featuresDeclined == true, vim.inspect(state))
check('projected as parked, StartedUnlicensed', view and view.kind == 'parked' and view.parked_reason == 'StartedUnlicensed',
  vim.inspect(view))

-- A parked server refuses feature requests with ServerCancelled; straight on the RPC, past the
-- plugin's wrapper.
local function raw(c, method, params)
  local got
  c.rpc.request(method, params, function(e, result) got = { err = e, result = result } end)
  vim.wait(30000, function() return got ~= nil end, 100)
  return got
end
local ws = raw(client, 'workspace/symbol', { query = 'Main' })
check('feature request refused with ServerCancelled (-32802)',
  ws and ws.err and ws.err.code == -32802, vim.inspect(ws and (ws.err or ws.result)))
note('parked refusal: ' .. vim.inspect(ws and ws.err))

-- Through the client the same refusal is an empty result for what Neovim asks on its own, and an
-- error saying why for what the user asked for. Neovim's diagnostic pull, which re-sends itself on
-- every ServerCancelled, does not turn into a stream.
local hlr = client:request_sync('textDocument/documentHighlight', vim.lsp.util.make_position_params(0, client.offset_encoding), 30000, bufnr)
check('parked: an automatic request reads as empty', hlr and hlr.err == nil and hlr.result == nil, vim.inspect(hlr))
ws = client:request_sync('workspace/symbol', { query = 'Main' }, 30000, bufnr)
check('parked: a request the user made says there is no license', ws and ws.err
  and ws.err.message:find(':IntellijLspLicense', 1, true) ~= nil, vim.inspect(ws))

-- What Neovim would report as "nothing found": a prompt naming the feature instead (headless: a
-- warning), and code actions that lead to a license.
local prompts, orig_notify1 = {}, vim.notify
vim.notify = function(msg, level) table.insert(prompts, { msg = msg, level = level }) end
local refs_answered = false
client:request('textDocument/references', vim.tbl_extend('force', vim.lsp.util.make_position_params(0, client.offset_encoding),
  { context = { includeDeclaration = true } }), function() refs_answered = true end, bufnr)
vim.wait(30000, function() return #prompts > 0 end, 100)
vim.notify = orig_notify1
check('parked: references prompt for a license, naming the feature', prompts[1]
  and prompts[1].msg:find('Find References needs an active license', 1, true), vim.inspect(prompts))
check('parked: references never say "nothing found"', not refs_answered)
local params = vim.lsp.util.make_range_params(0, client.offset_encoding)
params.context = { diagnostics = {} }
local ca = client:request_sync('textDocument/codeAction', params, 30000, bufnr)
check('parked: code actions offer to activate a license', ca and ca.err == nil
  and vim.deep_equal(ca.result, { licensing.ACTIVATE_ACTION }), vim.inspect(ca))
local t0 = vim.uv.now()
local def = client:request_sync('textDocument/definition', vim.lsp.util.make_position_params(0, client.offset_encoding), 30000, bufnr)
check('parked: a synchronous definition (tagfunc) answers at once, with the error', def and def.err
  and vim.uv.now() - t0 < 10000, vim.inspect(def))
local hint = licensing.hint_text(bufnr)
check('parked: the buffer hint says why', hint == licensing.HINT, tostring(hint))
local pulls, loud = 0, {}
local orig_rpc_request = client.rpc.request
client.rpc.request = function(method, ...)
  if method == 'textDocument/diagnostic' then pulls = pulls + 1 end
  return orig_rpc_request(method, ...)
end
local orig_notify0 = vim.notify
vim.notify = function(msg, level)
  if (level or 0) >= vim.log.levels.WARN then table.insert(loud, msg) end
end
pcall(vim.lsp.diagnostic._refresh, bufnr, client.id)
client:request('textDocument/completion', vim.lsp.util.make_position_params(0, client.offset_encoding), nil, bufnr)
vim.wait(3000, function() return false end, 100)
client.rpc.request = orig_rpc_request
vim.notify = orig_notify0
check('parked: the diagnostic pull is not retriggered', pulls >= 1 and pulls <= 2, pulls)
check('parked: no warnings or errors from completion or diagnostics', #loud == 0, vim.inspect(loud))

-- :checkhealth asks the server with state/get and names the parked state and the launch consent.
local hl = health_lines()
local parked_line = health_line(hl, 'license:')
check('health: parked is an error with its reason', parked_line and parked_line.level == 'error'
  and parked_line.text:find('parked: StartedUnlicensed', 1, true) ~= nil, vim.inspect(hl))
check('health: the consent the server was launched with',
  health_line(hl, 'launched with region europe, data sharing anonymous') ~= nil, vim.inspect(hl))
check('health: no crash, no feature probe', not health_line(hl, 'probe') and not vim.iter(hl):any(function(l)
  return l.level == 'crash' end), vim.inspect(hl))

-- With persistence off, `--eula` was accepted without being recorded.
check('EULA acceptance not recorded in the license dir',
  vim.fn.filereadable(LICENSE_DIR .. '/eula-accepted.hashes') == 0,
  vim.inspect(vim.fn.readdir(LICENSE_DIR)))
check('license dir holds no license record',
  vim.fn.filereadable(LICENSE_DIR .. '/intellij-server.key') == 0,
  vim.inspect(vim.fn.readdir(LICENSE_DIR)))

-- A restart is a new client: it syncs again, but the activation was already offered this session.
local old_id = client.id
require('intellij-lsp').restart()
check('state dropped on exit', vim.wait(30000, function() return licensing.state(old_id) == nil end, 100))
local restarted
check('restarted client attached', vim.wait(120000, function()
  restarted = vim.lsp.get_clients({ name = 'intellij', bufnr = bufnr })[1]
  return restarted ~= nil and restarted.id ~= old_id and restarted.initialized
end, 200))
if restarted and restarted.id ~= old_id then
  check('restart syncs again', vim.wait(70000, function()
    return vim.deep_equal(sent_by(restarted.id), { 'state/get', 'discovery/autoActivate' })
  end, 100), vim.inspect(sent_by(restarted.id)))
  vim.wait(2000, function() return #offers > 1 end, 100)
  check('restart does not offer the activation again', #offers == 1, vim.inspect(offers))

  -- Activation through the float's actions: a bogus code is rejected, the trial licenses the
  -- parked server. The trial is this machine's (see the recipe), written into the isolated dir.
  local activation = require('intellij-lsp.activation')
  local function outcome(fn, ...)
    local got
    local args = { ... }
    table.insert(args, function(ok, message) got = { ok = ok, message = message } end)
    fn(unpack(args))
    vim.wait(90000, function() return got ~= nil end, 100)
    return got or {}
  end
  local r = outcome(activation.use_code, restarted, 'NOT-A-REAL-CODE')
  check('a bogus activation code is rejected', r.ok == false and r.message == activation.CODE_REJECTED, vim.inspect(r))
  check('and the server stays parked', licensing.view(restarted.id).kind == 'parked', licensing.view(restarted.id).kind)

  -- Sign-in: the server opens the JetBrains Account page through `window/showDocument`, which
  -- signin.lua shows in a float; <Esc> there cancels with `jba/logout`. No browser, no clipboard.
  local signin = require('intellij-lsp.signin')
  local pages, copied = {}, {}
  signin._open = function(u) table.insert(pages, u) return true end
  signin._copy = function(u) table.insert(copied, u) return true end
  signin.remote = function() return false end
  local login_result
  activation.login(restarted, function(ok, message) login_result = { ok = ok, message = message } end)
  check('sign-in opens the JetBrains Account page', vim.wait(30000, function() return #pages > 0 end, 100)
    and pages[1]:match('^https://account%.jetbrains%.com/') ~= nil, vim.inspect(pages))
  check('the sign-in float is up', vim.api.nvim_win_get_config(0).relative ~= '' and activation.login_pending())
  local esc = vim.fn.maparg('<Esc>', 'n', false, true)
  if esc.callback then esc.callback() end
  check('<Esc> cancels the sign-in silently', vim.wait(30000, function() return login_result ~= nil end, 100)
    and login_result.ok == false and login_result.message == nil, vim.inspect(login_result))
  check('and the server is parked again, not authenticating',
    vim.wait(10000, function() return licensing.view(restarted.id).kind == 'parked' end, 100), licensing.view(restarted.id).kind)

  -- The paste-code sign-in for remote machines: the real CLI in a terminal, sharing the license dir.
  copied = {}
  local job = signin.terminal_login(SERVER, restarted.config.cmd_env)
  local tbuf = vim.api.nvim_get_current_buf()
  check('the CLI paste-code sign-in prints a link, copied whole',
    vim.wait(90000, function() return #copied > 0 end, 100)
    and copied[1]:match('^https://account%.jetbrains%.com/oauth/') ~= nil and not copied[1]:find(' ', 1, true), vim.inspect(copied))
  vim.fn.chansend(job, '\n')
  vim.fn.jobwait({ job }, 30000)
  vim.wait(2000, function() return false end, 100)
  check('an empty code fails and the terminal stays open with the reason', vim.api.nvim_buf_is_valid(tbuf)
    and table.concat(vim.api.nvim_buf_get_lines(tbuf, 0, -1, false), '\n'):find('Login failed', 1, true),
    vim.api.nvim_buf_is_valid(tbuf) and table.concat(vim.api.nvim_buf_get_lines(tbuf, 0, -1, false), '\n'))
  vim.cmd('stopinsert')
  pcall(vim.api.nvim_buf_delete, tbuf, { force = true })
  -- Count what is asked for again once the trial licenses the server.
  local asked = {}
  local orig_rpc = restarted.rpc.request
  restarted.rpc.request = function(method, ...)
    asked[method] = (asked[method] or 0) + 1
    return orig_rpc(method, ...)
  end
  r = outcome(activation.trial, restarted)
  local after = licensing.view(restarted.id)
  check('starting the trial licenses the parked server', r.ok and after.kind == 'licensed' and after.source == 'trial',
    vim.inspect(r) .. ' ' .. vim.inspect(after))
  note('trial: ' .. tostring(after.license_id) .. ' through ' .. tostring(after.valid_through))
  check('the trial is written to the isolated license dir', vim.fn.filereadable(LICENSE_DIR .. '/intellij-server.key') == 1,
    vim.inspect(vim.fn.readdir(LICENSE_DIR)))
  local served
  check('features answer once licensed', vim.wait(30000, function()
    local res = restarted:request_sync('workspace/symbol', { query = 'Main' }, 10000, bufnr)
    served = res
    return res and res.err == nil and res.result ~= nil
  end, 500), vim.inspect(served))
  check('after activation: diagnostics, tokens, lenses and hints are asked for again', vim.wait(10000, function()
    return (asked['textDocument/codeLens'] or 0) > 0 and (asked['textDocument/inlayHint'] or 0) > 0
      and (asked['textDocument/diagnostic'] or 0) > 0
      and #vim.tbl_filter(function(m) return vim.startswith(m, 'textDocument/semanticTokens') end, vim.tbl_keys(asked)) > 0
  end, 100), vim.inspect(asked))
  restarted.rpc.request = orig_rpc
  check('statusline: the trial (more than 7 days left shows nothing)', require('intellij-lsp').license(bufnr)
    == licensing.statusline(after), require('intellij-lsp').license(bufnr))
  note('statusline: ' .. vim.inspect(require('intellij-lsp').license(bufnr)))
  local licensed_line = health_line(health_lines(), 'license:')
  check('health: the trial is ok, with source and days left', licensed_line and licensed_line.level == 'ok'
    and licensed_line.text:find('source Trial, status Valid', 1, true) ~= nil
    and licensed_line.text:find('days left', 1, true) ~= nil, vim.inspect(licensed_line))

  -- :IntellijLspLicense on a licensed server: the status float, then removing the trial.
  local license = require('intellij-lsp.license')
  license.open(require('intellij-lsp').config)
  vim.wait(30000, function() return vim.api.nvim_win_get_config(0).relative ~= '' end, 100)
  local float = table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), '\n')
  check('status float: shows the trial and offers to remove it', float:find('License is active (Trial)', 1, true)
    and float:find('Valid through', 1, true) and float:find('2  Remove license', 1, true), float)
  note('status float:\n' .. float)
  pcall(vim.api.nvim_win_close, 0, true)
  local told = {}
  local orig_notify1 = vim.notify
  vim.notify = function(msg, level) table.insert(told, { msg = msg, level = level }) end
  r = outcome(license.remove, restarted)
  vim.notify = orig_notify1
  local removed = licensing.view(restarted.id)
  check('removing the trial parks the server with LicenseRemoved', r.ok and removed.kind == 'parked'
    and removed.parked_reason == 'LicenseRemoved', vim.inspect(r) .. ' ' .. vim.inspect(removed))
  -- The removal's own outcome is the view's message; a notice would add the hint.
  check('the removal reports itself, no loss notice on top', #vim.tbl_filter(function(t)
    return t.msg:find(':IntellijLspLicense', 1, true) ~= nil end, told) == 0, vim.inspect(told))
  local refused = raw(restarted, 'workspace/symbol', { query = 'Main' })
  check('and features are refused again', refused and refused.err and refused.err.code == -32802,
    vim.inspect(refused and (refused.err or refused.result)))
  check('statusline: unlicensed', require('intellij-lsp').license(bufnr) == 'IJ unlicensed', require('intellij-lsp').license(bufnr))

  -- A loss from elsewhere is told: the trial again, then a removal the plugin did not send (straight
  -- on the RPC, so not one of its own requests).
  r = outcome(activation.trial, restarted)
  check('the trial licenses the server again', r.ok and licensing.view(restarted.id).kind == 'licensed', vim.inspect(r))
  told = {}
  vim.notify = function(msg, level) table.insert(told, { msg = msg, level = level }) end
  local disabled = raw(restarted, 'jetbrains/licensing/activationCode/disable', vim.empty_dict())
  note('removal from elsewhere: ' .. vim.inspect(disabled))
  local lost_view
  check('the server reports the removal', vim.wait(30000, function()
    lost_view = licensing.view(restarted.id)
    return lost_view.kind ~= 'licensed'
  end, 100), vim.inspect(lost_view))
  vim.wait(1000, function() return false end, 100)
  vim.notify = orig_notify1
  note('after the removal: ' .. lost_view.kind .. ' / ' .. tostring(lost_view.parked_reason))
  local loss = vim.tbl_filter(function(t) return t.msg:find('^IntelliJ LSP: ') ~= nil end, told)
  check('one loss notice, naming :IntellijLspLicense', #loss == 1 and loss[1].msg:find(':IntellijLspLicense', 1, true)
    and loss[1].level >= vim.log.levels.WARN, vim.inspect(told))
  note('license dir after removal: ' .. vim.inspect(vim.fn.readdir(LICENSE_DIR)))
  restarted:stop(true)
  vim.wait(30000, function() return restarted:is_stopped() end, 100)

  -- Without a server the subcommands fall back to the CLI, on the same license dir.
  local cfg = require('intellij-lsp').config
  local cli_view
  license.cli_status(cfg, function(v, e) cli_view = v or e end)
  check('cli: status --json without a server', vim.wait(60000, function() return cli_view ~= nil end, 100)
    and type(cli_view) == 'table' and cli_view.kind == 'parked', vim.inspect(cli_view))
  local said = {}
  local orig_notify = vim.notify
  vim.notify = function(msg, level) table.insert(said, { msg = msg, level = level }) end
  -- The outcome goes to vim.notify only when no progress message showed, so none may show; the
  -- stopped server's "quit with exit code 143" can arrive meanwhile.
  local delay = licensing.DISCOVERY_PROGRESS_DELAY
  licensing.DISCOVERY_PROGRESS_DELAY = 600000
  local function outcome_of(text) return vim.tbl_filter(function(t) return t.msg:find(text, 1, true) ~= nil end, said)[1] end
  license.SUBCOMMANDS.trial.run({}, { config = cfg })
  vim.wait(90000, function() return outcome_of('Trial started') ~= nil end, 100)
  licensing.DISCOVERY_PROGRESS_DELAY = delay
  check('cli: trial without a server', outcome_of('Trial started') and outcome_of('Trial started').level == vim.log.levels.INFO,
    vim.inspect(said))
  said = {}
  license.SUBCOMMANDS.activate.run({ 'NOT-A-REAL-CODE' }, { config = cfg })
  vim.wait(90000, function() return #said > 0 end, 100)
  check('cli: a bogus code without a server is rejected', said[1] and said[1].msg:find('Activation failed', 1, true)
    and said[1].level == vim.log.levels.ERROR, vim.inspect(said))
  vim.notify = orig_notify
  local reset_code
  license.cli(cfg, { 'license', 'reset' }, function(code) reset_code = code end)
  check('cli: license reset clears the isolated store', vim.wait(60000, function() return reset_code ~= nil end, 100)
    and reset_code == 0 and vim.fn.filereadable(LICENSE_DIR .. '/intellij-server.key') == 0, vim.inspect(vim.fn.readdir(LICENSE_DIR)))
end

print('')
print(failures == 0 and 'ALL LICENSING CHECKS PASSED'
                     or (failures .. ' LICENSING CHECK(S) FAILED'))
vim.cmd(failures == 0 and 'qa!' or 'cq!')
