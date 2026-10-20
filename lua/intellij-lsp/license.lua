--- `:IntellijLspLicense`: the status float, and the subcommands that show, change or remove the
--- license.
---
--- With a server running, everything goes through its `jetbrains/licensing/*` requests
--- (`licensing.lua`, `activation.lua`). Every server reads the same license store, so one server is
--- enough: the current buffer's, or any other. Without one, the subcommands the server's CLI also
--- has (`status`, `trial`, `activate`, `login`, `reset`) run `intellij-server license ...` with the
--- environment a server would get (license dir, region), and a server started later finds the
--- license in the store.
---
--- Removing a license and signing out follow the VS Code extension (`licenseMessageHandler.ts`):
--- a subscription is released (`subscriptions/unuseAll`) and the account signed out; a trial, an
--- activation code or a product key file is disabled (`activationCode/disable`, which clears the
--- store's file license); a license server is removed. The replies carry nothing, so the state the
--- server pushes before each reply tells whether it worked.

local activation = require('intellij-lsp.activation')
local consent = require('intellij-lsp.consent')
local licensing = require('intellij-lsp.licensing')

local M = {}

local INFO, WARN, ERROR = vim.log.levels.INFO, vim.log.levels.WARN, vim.log.levels.ERROR

local REMOVAL_FAILED = "Couldn't remove the license. Try again."
local SUBSCRIPTION_REMOVAL_FAILED = "Couldn't remove this subscription. Try again."
local LOGOUT_FAILED = "Couldn't sign out. Try again."
local REFRESH_FAILED = "Couldn't refresh the subscriptions from the JetBrains Account. Try again."
M.NOT_SIGNED_IN = 'Not signed in to a JetBrains Account. :IntellijLspLicense login signs in.'
M.NO_SERVER = 'no running server; open a Java or Kotlin file first.'
local NOT_DOWNLOADED = 'the server is not downloaded yet; open a Java or Kotlin file first.'
--- The sign-in is stored with the JetBrains IDEs' own (`java.util.prefs`), so signing out here signs
--- them out too. The CLI's `reset --account` says the same.
local SHARED_SIGN_IN = 'JetBrains IDEs on this machine share the sign-in and are signed out too.'

local function notify(text, level)
  vim.notify('IntelliJ LSP: ' .. text, level or INFO)
end

--- The server to send licensing requests to: the current buffer's, or any running one (they share
--- one license store).
--- @return vim.lsp.Client|nil
function M.target()
  local name = require('intellij-lsp.client').NAME
  for _, opts in ipairs({ { name = name, bufnr = 0 }, { name = name } }) do
    for _, c in ipairs(vim.lsp.get_clients(opts)) do
      if licensing.supported(c) and not c:is_stopped() then return c end
    end
  end
  return nil
end

--- A yes/cancel question; `yes()` runs only on the first entry. A seam for tests.
--- @param prompt string
--- @param label string the first entry, e.g. "Remove"
--- @param yes fun()
function M._confirm(prompt, label, yes)
  activation.choose({ text = { prompt }, items = { label, 'Cancel' } }, function(_, idx)
    if idx == 1 then yes() end
  end)
end

-- ---------------------------------------------------------------------------
-- Remove, sign out, refresh, use
-- ---------------------------------------------------------------------------

--- The request that removes a license, by `activeLicense.source`. EAP and Toolbox licenses have none:
--- the build carries the first, Toolbox owns the second.
M.REMOVAL = {
  subscription = 'subscriptions/unuseAll',
  activationCode = 'activationCode/disable',
  trial = 'activationCode/disable',
  productKeyFile = 'activationCode/disable',
  licenseServer = 'licenseServer/remove',
}

--- Whether the license from `source` is still the valid one.
local function still_licensed_by(client, source)
  local view = licensing.view(client.id)
  return view ~= nil and view.source == source and view.status == 'Valid'
end

--- Removes the active license. A subscription also signs the account out, as VS Code does: it
--- would otherwise stay signed in with the subscription released.
--- @param client vim.lsp.Client
--- @param done fun(ok: boolean, message: string|nil)|nil
function M.remove(client, done)
  done = done or function() end
  local env_var = licensing.environment_license(client.config.cmd_env)
  if env_var then
    notify(licensing.environment_message(env_var), WARN)
    return done(false)
  end
  local view = licensing.view(client.id)
  if not view or not view.source then
    notify('there is no license to remove.')
    return done(false)
  end
  local source = view.source
  local name = M.REMOVAL[source]
  if not name then
    notify(("a license from %s can't be removed here."):format(view.source_label), WARN)
    return done(false)
  end
  activation.cancel_login(function()
    activation.run(client, name, nil, 'Removing the license…', function(err, _, finish)
      if err or still_licensed_by(client, source) then
        return finish(false, source == 'subscription' and SUBSCRIPTION_REMOVAL_FAILED or REMOVAL_FAILED)
      end
      if source ~= 'subscription' then return finish(true) end
      licensing.request(client, 'jba/logout', nil, function(logout_err)
        if logout_err then return finish(false, LOGOUT_FAILED) end
        finish(true)
      end)
    end, done)
  end)
end

--- Asks, then removes the active license.
--- @param client vim.lsp.Client
function M.confirm_remove(client)
  local view = licensing.view(client.id)
  if not view or not view.source or not M.REMOVAL[view.source]
    or licensing.environment_license(client.config.cmd_env) then
    return M.remove(client)
  end
  local prompt = ('Remove the license (%s)? Java and Kotlin features stop until another license is active.')
    :format(view.source_label)
  if view.source == 'subscription' then
    prompt = prompt .. ' This also signs out of the JetBrains Account; ' .. SHARED_SIGN_IN
  end
  M._confirm(prompt, 'Remove', function() M.remove(client) end)
end

--- Signs out of the JetBrains Account (`jba/logout`). A license from the account goes with it. A
--- sign-in still waiting on the browser is cancelled instead.
--- @param client vim.lsp.Client
--- @param done fun(ok: boolean, message: string|nil)|nil
function M.logout(client, done)
  done = done or function() end
  if activation.login_pending() then
    activation.cancel_login(function()
      notify('cancelled the sign-in.')
      done(true)
    end)
    return
  end
  local view = licensing.view(client.id)
  if not view or not view.account then
    notify(M.NOT_SIGNED_IN)
    return done(false)
  end
  activation.run(client, 'jba/logout', nil, 'Signing out…', function(err, _, finish)
    local after = licensing.view(client.id)
    if err or (after and after.account) then return finish(false, LOGOUT_FAILED) end
    local message = 'Signed out of the JetBrains Account.'
    if after and after.kind ~= 'licensed' then message = message .. ' ' .. after.message end
    finish(true, message)
  end, done)
end

--- Asks, then signs out.
--- @param client vim.lsp.Client
function M.confirm_logout(client)
  local view = licensing.view(client.id)
  if activation.login_pending() or not view or not view.account then return M.logout(client) end
  local prompt = 'Sign out of the JetBrains Account? ' .. SHARED_SIGN_IN
  if view.source == 'subscription' then prompt = prompt .. ' Its license is removed from this machine.' end
  M._confirm(prompt, 'Sign out', function() M.logout(client) end)
end

local function valid_subscriptions(view)
  return vim.tbl_filter(function(sub) return sub.status == 'Valid' end, view and view.subscriptions or {})
end

--- Fetches the account's subscriptions again (`subscriptions/update`), e.g. after buying one.
--- @param client vim.lsp.Client
--- @param done fun(ok: boolean, message: string|nil)|nil
function M.refresh(client, done)
  done = done or function() end
  local view = licensing.view(client.id)
  if not view or not view.account then
    notify(M.NOT_SIGNED_IN)
    return done(false)
  end
  activation.run(client, 'subscriptions/update', nil, 'Refreshing the subscriptions…', function(err, _, finish)
    if err then return finish(false, REFRESH_FAILED) end
    local count = #valid_subscriptions(licensing.view(client.id))
    if count == 0 then return finish(true, 'The JetBrains Account has no valid subscriptions.') end
    finish(true, ('The JetBrains Account has %d valid subscription%s.'):format(count, count == 1 and '' or 's'))
  end, done)
end

--- Picks one of the account's valid subscriptions and activates it (`subscriptions/use`).
--- @param client vim.lsp.Client
--- @param done fun(ok: boolean, message: string|nil)|nil
function M.use(client, done)
  done = done or function() end
  local view = licensing.view(client.id)
  if not view or not view.account then
    notify(M.NOT_SIGNED_IN)
    return done(false)
  end
  local valid = valid_subscriptions(view)
  if #valid == 0 then
    notify(activation.NO_LICENSES, WARN)
    return done(false)
  end
  -- By asset id: a license id is often missing on both sides, and nil == nil would mark them all.
  local function active(sub) return activation.subscription_active(client, sub.asset_id) end
  activation.choose({
    text = { 'Activate a subscription from your JetBrains Account:' },
    items = valid,
    format = function(sub)
      return ('%s, %s, valid through %s%s'):format(sub.product, sub.licensed_to, sub.valid_through,
        active(sub) and ' (active)' or '')
    end,
  }, function(sub)
    if not sub then return done(false) end
    if active(sub) then
      notify('that subscription is already active.')
      return done(true)
    end
    activation.run(client, 'subscriptions/use', sub.asset_id, 'Activating the subscription…', function(err, _, finish)
      if err or not activation.subscription_active(client, sub.asset_id) then
        return finish(false, activation.SUBSCRIPTION_FAILED)
      end
      finish(true)
    end, done)
  end)
end

-- ---------------------------------------------------------------------------
-- The status float
-- ---------------------------------------------------------------------------

--- The status float's entries. The ones offered are numbered from 1.
M.STATUS_ACTIONS = {
  { name = 'change', label = 'Change license' },
  { name = 'remove', label = 'Remove license' },
  { name = 'logout', label = 'Sign out of JetBrains Account' },
  { name = 'refresh', label = 'Refresh subscriptions' },
}

--- The entries to offer for a view. Without a license, 1 activates one. Remove only for a license
--- that has a removal, and not while an environment license overrides the store; signing out and
--- refreshing only with an account signed in.
--- @param view IntellijLspLicenseView|nil
--- @param opts { environment: boolean|nil }
--- @return table[]
function M.status_actions(view, opts)
  local out = {}
  for _, action in ipairs(M.STATUS_ACTIONS) do
    local name = action.name
    if name == 'change' then
      local label = view and view.source and action.label or 'Activate a license'
      table.insert(out, vim.tbl_extend('force', action, { label = label }))
    elseif name == 'remove' then
      if view and view.source and M.REMOVAL[view.source] and not opts.environment then table.insert(out, action) end
    elseif view and view.account then
      table.insert(out, action)
    end
  end
  for i, action in ipairs(out) do out[i] = vim.tbl_extend('force', action, { key = tostring(i) }) end
  return out
end

local days = licensing.days_left_text

--- The float's lines: the summary, the license's fields, problems, then the entries.
--- @param view IntellijLspLicenseView
--- @param actions table[]
--- @param opts { env_var: string|nil, offline: boolean|nil }
--- @return string[] lines, integer first entry's line (1-based)
function M._status_lines(view, actions, opts)
  local lines = { ' ' .. view.message, '' }
  local function row(label, value)
    if value and value ~= '' then lines[#lines + 1] = (' %-15s%s'):format(label, value) end
  end
  row('Source', view.source_label)
  if view.status ~= 'Valid' then row('Status', view.status) end
  row('Product', view.product)
  row('Licensed to', view.holder)
  row('License ID', view.license_id)
  if view.valid_through then
    row('Valid through', view.valid_through .. (view.days_left and (' (' .. days(view.days_left) .. ')') or ''))
  elseif view.days_left then
    row('Days left', tostring(view.days_left))
  end
  if view.grace_deadline then row('Grace until', licensing.format_deadline(view.grace_deadline)) end
  if view.account then
    local who = view.account.display_name or view.account.email or 'signed in'
    if view.account.email and view.account.display_name then who = who .. ' (' .. view.account.email .. ')' end
    row('Account', who)
  end
  if view.server_address and view.source ~= 'licenseServer' then row('License server', view.server_address) end
  if lines[#lines] == '' then lines[#lines] = nil end

  local notes = {}
  if view.error then notes[#notes + 1] = view.error end
  if opts.env_var then notes[#notes + 1] = licensing.environment_message(opts.env_var) end
  if opts.offline then
    notes[#notes + 1] = 'No server is running; this is the license store. '
      .. ':IntellijLspLicense trial, activate and login work without one.'
  end
  if #notes > 0 then
    lines[#lines + 1] = ''
    for _, note in ipairs(notes) do lines[#lines + 1] = ' ' .. note end
  end

  local first = #lines + 2
  if #actions > 0 then
    lines[#lines + 1] = ''
    for _, action in ipairs(actions) do lines[#lines + 1] = (' %s  %s'):format(action.key, action.label) end
  end
  return lines, first
end

--- Opens the status float. With `client`, its entries act on that server; without one (`offline`)
--- the float only shows what the CLI read from the license store.
--- @param client vim.lsp.Client|nil
--- @param view IntellijLspLicenseView
--- @param env_var string|nil the environment variable that owns the license
--- @return integer win
function M.open_status(client, view, env_var)
  local actions = client and M.status_actions(view, { environment = env_var ~= nil }) or {}
  local lines, first = M._status_lines(view, actions, { env_var = env_var, offline = client == nil })
  return activation.menu({
    title = activation.title('License'), footer = 'q  Close', lines = lines, first = first, actions = actions,
  }, function(name)
    if not name or not client then return end
    if client:is_stopped() then return notify('the server is not running.', WARN) end
    if name == 'change' then
      local current = licensing.view(client.id)
      activation.open(client, { change = current ~= nil and current.status == 'Valid' })
    elseif name == 'remove' then
      M.confirm_remove(client)
    elseif name == 'logout' then
      M.confirm_logout(client)
    else
      M.refresh(client)
    end
  end)
end

-- ---------------------------------------------------------------------------
-- The CLI, for when no server runs
-- ---------------------------------------------------------------------------

--- The environment a server would get: the config's JVM options (license dir) and consent.
--- @param cfg table plugin configuration
--- @return table<string, string>
function M.cli_env(cfg)
  local launch = require('intellij-lsp.launch')
  local settled = consent.resolve(cfg, launch.server_root(cfg.server_path))
  return launch.build_env(cfg.jvm_args, settled)
end

--- The line of CLI output to report: the first on stdout (the CLI prints its result there and its
--- boot noise on stderr), or on failure the last on stderr.
--- @param stdout string
--- @param stderr string
--- @param ok boolean
--- @return string|nil
function M._summary(stdout, stderr, ok)
  local function lines(text)
    return vim.tbl_filter(function(l) return vim.trim(l) ~= '' end,
      vim.split(require('intellij-lsp.signin').strip_ansi(text), '\r?\n'))
  end
  local out = lines(stdout)
  if out[1] then return vim.trim(out[1]) end
  if ok then return nil end
  local err = lines(stderr)
  return err[#err] and vim.trim(err[#err]) or nil
end

--- Runs `<launcher> <args>` with the server's environment and calls back with the exit code and its
--- output. False when the bundle is not there yet.
--- @param cfg table plugin configuration
--- @param args string[]
--- @param done fun(code: integer, stdout: string, stderr: string)
--- @return boolean started
function M.cli(cfg, args, done)
  if not cfg.server_path then
    notify(NOT_DOWNLOADED, WARN)
    return false
  end
  local cmd = vim.list_extend({ cfg.server_path }, args)
  local ok, err = pcall(vim.system, cmd, { env = M.cli_env(cfg), clear_env = true, text = true },
    vim.schedule_wrap(function(r) done(r.code, r.stdout or '', r.stderr or '') end))
  if not ok then
    notify(('could not run %s: %s'):format(cfg.server_path, err), ERROR)
    return false
  end
  return true
end

--- A `license` CLI command that changes the license, with a progress message while it runs and its
--- result reported once.
local function cli_change(cfg, args, text, fallback)
  local stop
  local started = M.cli(cfg, vim.list_extend({ 'license' }, args), function(code, stdout, stderr)
    local ok = code == 0
    local message = M._summary(stdout, stderr, ok) or fallback[ok]
    -- As `activation.run`: a success that showed in the message area is reported there; a failure
    -- also goes to `vim.notify`.
    local shown = stop(ok and message or text, ok and 'success' or 'failed')
    if not (ok and shown) then notify(message, ok and INFO or ERROR) end
  end)
  if started then stop = licensing.progress(text) end
end

--- `license status --json`, projected; the CLI exits 2 for "no valid license", which still reports.
--- @param cfg table
--- @param done fun(view: IntellijLspLicenseView|nil, err: string|nil)
--- @return boolean started
function M.cli_status(cfg, done)
  return M.cli(cfg, { 'license', 'status', '--json' }, function(code, stdout, stderr)
    local ok, state = pcall(vim.json.decode, stdout:match('%b{}') or '')
    if (code ~= 0 and code ~= 2) or not ok or type(state) ~= 'table' then
      return done(nil, M._summary('', stderr, false) or ('exit code ' .. code))
    end
    done(licensing.project(state))
  end)
end

-- ---------------------------------------------------------------------------
-- Subcommands
-- ---------------------------------------------------------------------------

local function usage(text)
  notify('usage: :IntellijLspLicense ' .. text, WARN)
end

--- Shows the status float: fresh from the server, or read by the CLI when none runs.
--- @param cfg table
--- @param on_unlicensed fun(client: vim.lsp.Client)|nil instead of the float when a server has no license
local function show_status(cfg, on_unlicensed)
  local target = M.target()
  if not target then
    M.cli_status(cfg, function(view, err)
      if not view then return notify("couldn't read the license: " .. err, ERROR) end
      M.open_status(nil, view, licensing.environment_license(M.cli_env(cfg)))
    end)
    return
  end
  licensing.refresh(target, function(err, view)
    if not view then return notify("couldn't read the license: " .. (err and err.message or 'no answer'), ERROR) end
    if on_unlicensed and not view.source then return on_unlicensed(target) end
    M.open_status(target, view, licensing.environment_license(target.config.cmd_env))
  end)
end

--- `:IntellijLspLicense` without an argument: the status float, or the activation float when there
--- is no license to show.
--- @param cfg table
function M.open(cfg)
  show_status(cfg, function(target) activation.open(target) end)
end

--- `login [--code]`: signs in with a JetBrains Account. In the browser through the server; with
--- `--code`, or from a remote machine whose browser cannot reach back, by pasting a code into the
--- CLI in a terminal (signin.lua). With no server running, the CLI signs in on its own.
local function login(fargs, cfg)
  local code = fargs[1] == '--code'
  if (fargs[1] and not code) or fargs[2] then return usage('login [--code]') end
  local signin = require('intellij-lsp.signin')
  local target = M.target()
  if target and (code or signin.remote()) then return activation.login_with_code(target) end
  if target then return activation.login(target) end
  if not cfg.server_path then return notify(NOT_DOWNLOADED, WARN) end
  signin.terminal_login(cfg.server_path, M.cli_env(cfg), { code = code })
end

local function trial(fargs, cfg)
  if fargs[1] then return usage('trial') end
  local target = M.target()
  if target then return activation.trial(target) end
  cli_change(cfg, { 'trial' }, 'Starting the trial…', { [true] = 'Trial started.', [false] = "Couldn't start your trial. Try again." })
end

--- `activate [code]`: the code may come in pieces, as pasted; without one, the input float asks.
local function activate(fargs, cfg)
  local code = activation.clean_code(table.concat(fargs, ''))
  local target = M.target()
  if target then
    if code == '' then return activation.ask_code(target) end
    return activation.use_code(target, code)
  end
  local function run_cli(text)
    text = activation.clean_code(text or '')
    if text == '' then return end
    cli_change(cfg, { 'activate', text }, 'Checking the activation code…', { [true] = 'License activated.', [false] = activation.CODE_REJECTED })
  end
  if code ~= '' then return run_cli(code) end
  if not cfg.server_path then return notify(NOT_DOWNLOADED, WARN) end
  activation._open_input({ title = 'Activation code' }, run_cli)
end

--- Runs `fn(target)` on a running server, or says that it needs one.
local function with_server(name, fn)
  return function(fargs)
    if fargs[1] then return usage(name) end
    local target = M.target()
    if not target then return notify(M.NO_SERVER, WARN) end
    fn(target)
  end
end

local function server(fargs)
  if fargs[2] then return usage('server [url]') end
  local target = M.target()
  if not target then return notify(M.NO_SERVER, WARN) end
  if fargs[1] then return activation.add_server(target, fargs[1]) end
  activation.ask_server(target)
end

--- `reset [--account]`: stops the servers, then removes this machine's server license
--- (`license reset`), the EULA acceptance (`--reset-eula`), the stored consent answers, and with
--- `--account` the JetBrains Account sign-in. Through the CLI with no server running, so nothing
--- holds the store meanwhile and it works the same whether or not one ran.
--- @param fargs string[]
--- @param cfg table
--- @param stop_all fun(done: fun()) stops every server, resets their per-client state, and calls
---   `done` once they have exited
function M.reset(fargs, cfg, stop_all)
  local account = fargs[1] == '--account'
  if (fargs[1] and not account) or fargs[2] then return usage('reset [--account]') end
  if not cfg.server_path then return notify(NOT_DOWNLOADED, WARN) end
  local prompt = 'Reset licensing? This stops the servers, removes the license on this machine, '
    .. 'and forgets the EULA acceptance and the region and data-sharing answers.'
  if account then prompt = prompt .. ' It also signs out of the JetBrains Account; ' .. SHARED_SIGN_IN end
  M._confirm(prompt, 'Reset', function()
    activation.cancel_login()
    stop_all(function()
      local args = { 'license', 'reset' }
      if account then table.insert(args, '--account') end
      M.cli(cfg, args, function(code, stdout, stderr)
        local license_ok = code == 0
        local license_line = M._summary(stdout, stderr, license_ok)
        M.cli(cfg, { '--reset-eula' }, function(eula_code, eula_out, eula_err)
          consent.forget()
          licensing._reset_session()
          local done = { 'the stored consent answers' }
          if eula_code == 0 then table.insert(done, 1, 'the EULA acceptance') end
          if license_ok then table.insert(done, 1, account and 'the license and the account sign-in' or 'the license') end
          local text = 'reset ' .. table.concat(done, ', ') .. '. :IntellijLspRestart starts again and asks the consent questions.'
          local problems = {}
          if not license_ok then table.insert(problems, 'License: ' .. (license_line or ('exit code ' .. code))) end
          if eula_code ~= 0 then
            table.insert(problems, 'EULA: ' .. (M._summary(eula_out, eula_err, false) or ('exit code ' .. eula_code)))
          end
          if #problems > 0 then text = text .. ' ' .. table.concat(problems, ' ') end
          notify(text, #problems > 0 and WARN or INFO)
        end)
      end)
    end)
  end)
end

--- Subcommands, each called with the arguments after its name and `ctx` (`config`, `stop_all`), and
--- what each one completes. `setup` is added by init.lua, which owns the launches it restarts.
M.SUBCOMMANDS = {
  status = { run = function(fargs, ctx)
    if fargs[1] then return usage('status') end
    show_status(ctx.config)
  end, args = {} },
  login = { run = function(fargs, ctx) login(fargs, ctx.config) end, args = { '--code' } },
  logout = { run = with_server('logout', M.confirm_logout), args = {} },
  trial = { run = function(fargs, ctx) trial(fargs, ctx.config) end, args = {} },
  activate = { run = function(fargs, ctx) activate(fargs, ctx.config) end, args = {} },
  server = { run = server, args = {} },
  use = { run = with_server('use', M.use), args = {} },
  refresh = { run = with_server('refresh', M.refresh), args = {} },
  remove = { run = with_server('remove', M.confirm_remove), args = {} },
  reset = { run = function(fargs, ctx) M.reset(fargs, ctx.config, ctx.stop_all) end, args = { '--account' } },
}

return M
