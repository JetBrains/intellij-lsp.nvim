--- The activation float, and the four ways to activate a license through it: a JetBrains Account
--- sign-in, the anonymous trial, an activation code, a license server.
---
--- Each one is a `jetbrains/licensing/*` request on a single server. The other servers read the same
--- license store and pick the result up from it within seconds. The replies are mapped the way the
--- VS Code extension maps them (`licenseMessageHandler.ts`), with its sentences, so both clients
--- report an outcome in the same words.
---
--- The push that follows a successful request arrives before its reply, so the licensing store
--- already holds the new state when a reply is inspected.

local licensing = require('intellij-lsp.licensing')
local signin = require('intellij-lsp.signin')

local M = {}

local INFO, WARN, ERROR = vim.log.levels.INFO, vim.log.levels.WARN, vim.log.levels.ERROR

local TRIAL_FAILED = "Couldn't start your trial. Try again."
M.CODE_REJECTED = "That activation code isn't valid. Check the code and try again."
M.NO_LICENSES = 'No licenses available for activation were found in the JetBrains Account.'
local LICENSE_CHECK_FAILED = "Couldn't check licenses in the JetBrains Account. Try again."
M.SUBSCRIPTION_FAILED = "Couldn't activate a subscription from this JetBrains Account. Try again."
local NO_SUBSCRIPTION_CHOSEN = 'Signed in, but no subscription was activated.'
local SERVER_FAILED = "Couldn't activate with the license server. Check the server and try again."
local SERVER_TIMED_OUT = 'Sign-in to the license server timed out. Try again.'
M.SERVER_URL_INVALID = 'A license server URL starts with http:// or https://.'
local LATER = 'Java and Kotlin features stay off until a license is active. Run :IntellijLspLicense to activate one.'

--- The server's `errorMessage` when the sign-in page could not be opened. The user saw nothing, so
--- there is nothing to report.
local DECLINED_SIGN_IN_PAGE = 'Failed to open the sign-in page'

local val = licensing.val

local function notify(text, level)
  vim.notify('IntelliJ LSP: ' .. text, level or INFO)
end

local function active_of(client)
  local state = licensing.state(client.id)
  return state and val(state.activeLicense)
end

local function jba_of(client)
  local state = licensing.state(client.id)
  return state and val(state.jbaLicensingState) or {}
end

--- Sends one request and hands its reply to `inspect`, with "`text`" in the message area while it
--- runs longer than half a second.
---
--- `inspect(err, result, finish)` decides the outcome and calls `finish(ok, message, level)` once,
--- possibly later (a sign-in goes on to activate a subscription). A success reports the license now
--- active; a failure reports `message`, or nothing when it is nil (the user cancelled).
---
--- A progress message that showed closes with a success in its own words. A failure closes it as
--- failed and goes to `vim.notify` with its level, so it is not lost in the message area; a cancel
--- closes it as "Cancelled.", so it does not go on saying it waits. A success with a message of its
--- own reports that instead of the license.
--- @param client vim.lsp.Client
--- @param name string
--- @param arg string|nil
--- @param text string
--- @param inspect fun(err: lsp.ResponseError|nil, result: any, finish: fun(ok: boolean, message: string|nil, level: integer|nil))
--- @param done fun(ok: boolean, message: string|nil)|nil
function M.run(client, name, arg, text, inspect, done)
  local stop = licensing.progress(text)
  licensing.request(client, name, arg, function(err, result)
    inspect(err, result, function(ok, message, level)
      if ok and not message then
        local view = licensing.view(client.id)
        message = view and view.message or 'License is active.'
      end
      local shown = stop(ok and message or (message and text or 'Cancelled.'), ok and 'success' or 'failed')
      if message and not (ok and shown) then notify(message, level or (ok and INFO or ERROR)) end
      if done then done(ok, message) end
    end)
  end)
end

--- Signs out of the JetBrains Account once a trial or an activation code has taken over from it,
--- as VS Code does: the account would otherwise stay signed in with nothing to license.
--- @param client vim.lsp.Client
--- @param source 'trial'|'activationCode'
local function logout_after(client, source)
  if jba_of(client).authenticationStatus ~= 'Authenticated' then return end
  local active = active_of(client)
  if not active or active.source ~= source or active.status ~= 'Valid' then return end
  licensing.request(client, 'jba/logout', nil, function() end)
end

-- ---------------------------------------------------------------------------
-- JetBrains Account
-- ---------------------------------------------------------------------------

--- The sign-in under way: the client it runs on, and whether it was cancelled since.
--- @type { client: vim.lsp.Client, cancelled: boolean }|nil
local login = nil

--- Whether a JetBrains Account sign-in is waiting on the browser.
function M.login_pending()
  return login ~= nil
end

--- Cancels the sign-in under way, if any. There is no cancel request: signing out ends the server's
--- wait, and the sign-in's own reply is then dropped without a message.
--- @param callback fun()|nil called once the sign-out is answered, or at once without a sign-in
function M.cancel_login(callback)
  local attempt = login
  if not attempt then
    if callback then callback() end
    return
  end
  attempt.cancelled = true
  login = nil
  signin.close()
  licensing.request(attempt.client, 'jba/logout', nil, function()
    if callback then callback() end
  end)
end

--- Activates one of the account's subscriptions (`subscriptions/use`). The reply carries nothing;
--- the push before it shows whether that subscription is now the valid license.
--- @param client vim.lsp.Client
--- @param sub { asset_id: string } an entry of the view's `subscriptions`
--- @param finish fun(ok: boolean, message: string|nil)
function M.activate_subscription(client, sub, finish)
  licensing.request(client, 'subscriptions/use', sub.asset_id, function(err)
    if not err and M.subscription_active(client, sub.asset_id) then return finish(true) end
    finish(false, M.SUBSCRIPTION_FAILED)
  end)
end

--- Whether the subscription with this asset id is the server's valid license.
--- @param client vim.lsp.Client
--- @param asset_id string
--- @return boolean
function M.subscription_active(client, asset_id)
  local active = active_of(client)
  return active ~= nil and active.source == 'subscription' and active.status == 'Valid' and active.assetId == asset_id
end

--- After a sign-in that found no license to activate on its own: activates the account's one valid
--- subscription, or the one the user picks from several.
local function use_subscription(client, finish)
  local jba = jba_of(client)
  if jba.authenticationStatus ~= 'Authenticated' then return finish(false, nil) end
  local view = licensing.view(client.id)
  local valid = vim.tbl_filter(function(sub) return sub.status == 'Valid' end, view and view.subscriptions or {})
  if #valid == 0 then
    licensing.request(client, 'jba/logout', nil, function() end)
    return finish(false, M.NO_LICENSES, WARN)
  end

  local function use(sub) M.activate_subscription(client, sub, finish) end
  if #valid == 1 then return use(valid[1]) end

  M.choose({
    text = { 'Activate a subscription from your JetBrains Account:' },
    items = valid,
    format = function(sub)
      return ('%s, %s, valid through %s'):format(sub.product, sub.licensed_to, sub.valid_through)
    end,
  }, function(sub)
    if not sub then return finish(false, NO_SUBSCRIPTION_CHOSEN, WARN) end
    use(sub)
  end)
end

--- Signs in to a JetBrains Account in the browser (`jba/login`) and activates a license from it.
---
--- A second sign-in cancels the first. The server waits up to five minutes for the browser and then
--- replies how it ended: `Licensed`; `NoSuitableLicense`, where the account's subscriptions are
--- offered; `NoLicenses` or `LicenseCheckFailed`, which keep any account signed in before; or
--- `Canceled`, `TimedOut`, `Failed`.
--- @param client vim.lsp.Client
--- @param done fun(ok: boolean, message: string|nil)|nil
function M.login(client, done)
  M.cancel_login(function()
    local attempt = { client = client, cancelled = false }
    login = attempt
    M.run(client, 'jba/login', nil, 'Waiting for the JetBrains Account sign-in in your browser…', function(err, result, finish)
      if login == attempt then
        login = nil
        signin.close()
      end
      if attempt.cancelled then return finish(false, nil) end
      if err then
        -- Our wait ran out, not necessarily the server's; signing out ends a wait still under way.
        if jba_of(client).authenticationStatus == 'Authenticating' then
          licensing.request(client, 'jba/logout', nil, function() end)
        end
        return finish(false, licensing.ACCOUNT_AUTH_FAILED)
      end
      local status = type(result) == 'table' and result.status or nil
      local message = type(result) == 'table' and vim.trim(val(result.errorMessage) or '') or ''
      if status == 'Licensed' then return finish(true) end
      if status == 'NoSuitableLicense' then return use_subscription(client, finish) end
      if status == 'NoLicenses' then return finish(false, M.NO_LICENSES, WARN) end
      if status == 'LicenseCheckFailed' then return finish(false, LICENSE_CHECK_FAILED, WARN) end
      if status == 'Canceled' then return finish(false, nil) end
      if status == 'Failed' and message == DECLINED_SIGN_IN_PAGE then return finish(false, nil) end
      finish(false, licensing.ACCOUNT_AUTH_FAILED)
    end, done)
  end)
end

-- ---------------------------------------------------------------------------
-- Trial, activation code, license server
-- ---------------------------------------------------------------------------

--- Starts the anonymous 30-day trial (`trial/startAnonymous`).
--- @param client vim.lsp.Client
--- @param done fun(ok: boolean, message: string|nil)|nil
function M.trial(client, done)
  M.cancel_login(function()
    M.run(client, 'trial/startAnonymous', nil, 'Starting the trial…', function(err, result, finish)
      if err or type(result) ~= 'table' then return finish(false, TRIAL_FAILED) end
      if result.isSuccess ~= true then
        local backend = vim.trim(val(result.errorMessage) or '')
        return finish(false, backend ~= '' and (TRIAL_FAILED .. ' ' .. backend) or TRIAL_FAILED)
      end
      logout_after(client, 'trial')
      finish(true)
    end, done)
  end)
end

--- An activation code as pasted: codes are long and mail clients wrap them, so every whitespace
--- character goes.
--- @param text string
--- @return string
function M.clean_code(text)
  return (text:gsub('%s+', ''))
end

--- Activates a license with an activation code (`activationCode/use`). The server answers `false`
--- for a code it rejects.
--- @param client vim.lsp.Client
--- @param code string
--- @param done fun(ok: boolean, message: string|nil)|nil
function M.use_code(client, code, done)
  code = M.clean_code(code)
  if code == '' then
    if done then done(false, nil) end
    return
  end
  M.cancel_login(function()
    M.run(client, 'activationCode/use', code, 'Checking the activation code…', function(err, result, finish)
      if err or result ~= true then return finish(false, M.CODE_REJECTED) end
      logout_after(client, 'activationCode')
      finish(true)
    end, done)
  end)
end

--- VS Code's check (`licenseServerUrl.ts`): http or https, a host, no whitespace.
--- @param url string
--- @return boolean
function M.valid_server_url(url)
  return vim.trim(url):lower():match('^https?://[^%s/$.?#]%S*$') ~= nil
end

--- The license server's own error, once a connect left a configured server without a license from it.
local function server_error(client)
  local state = licensing.state(client.id)
  if not state then return nil end
  local active = val(state.activeLicense)
  if active and active.source == 'licenseServer' then return nil end
  local flow = val(state.licenseServerFlowState) or {}
  if flow.kind ~= 'configured' then return nil end
  local message = vim.trim(val(flow.errorMessage) or '')
  return message ~= '' and message or nil
end

--- Signs out of the JetBrains Account once the license server's license is valid. The ticket can
--- arrive after `licenseServer/add` replied, so this waits for the push that brings it, and gives up
--- once the server stops trying.
local function logout_when_server_licensed(client)
  local function licensed(view)
    return view and view.kind == 'licensed' and view.source == 'licenseServer'
  end
  local function logout() licensing.request(client, 'jba/logout', nil, function() end) end
  if licensed(licensing.view(client.id)) then return logout() end
  vim.api.nvim_create_autocmd('User', {
    pattern = licensing.EVENT,
    callback = function(ev)
      if ev.data.client_id ~= client.id then return end
      local view = ev.data.view
      if licensed(view) then logout() end
      if not view or view.kind ~= 'authenticating' then return true end
    end,
  })
end

--- Activates through a license server (`licenseServer/add`). The server may first need a sign-in to
--- the license server in the browser, and waits up to five minutes for it.
--- @param client vim.lsp.Client
--- @param url string
--- @param done fun(ok: boolean, message: string|nil)|nil
function M.add_server(client, url, done)
  url = vim.trim(url)
  if not M.valid_server_url(url) then
    notify(M.SERVER_URL_INVALID, WARN)
    if done then done(false, M.SERVER_URL_INVALID) end
    return
  end
  M.cancel_login(function()
    local signed_in = jba_of(client).authenticationStatus == 'Authenticated'
    M.run(client, 'licenseServer/add', url, 'Connecting to ' .. url .. '…', function(err, result, finish)
      signin.close()
      if err or type(result) ~= 'table' then return finish(false, SERVER_FAILED) end
      local message = vim.trim(val(result.errorMessage) or '')
      if result.status == 'Connected' then
        local refused = server_error(client)
        if refused then return finish(false, refused) end
        if signed_in then logout_when_server_licensed(client) end
        return finish(true)
      end
      if result.status == 'Canceled' then return finish(false, nil) end
      if result.status == 'TimedOut' then return finish(false, SERVER_TIMED_OUT) end
      if message == DECLINED_SIGN_IN_PAGE then return finish(false, nil) end
      finish(false, message ~= '' and message or SERVER_FAILED)
    end, done)
  end)
end

-- ---------------------------------------------------------------------------
-- Input
-- ---------------------------------------------------------------------------

--- An input float, centred like the other licensing floats. Opens in insert mode. Multi-line by
--- default, for text that gets pasted: <C-s>, or <CR> in normal mode, submits. `single` makes it one
--- line, where <CR> submits and <Esc> cancels from insert mode too, as Neovim's own input prompt
--- does. `q` or <Esc> in normal mode, or closing the window, cancels.
--- @param opts { title: string, lines: string[]|nil, single: boolean|nil }
--- @param done fun(text: string|nil)
--- @return integer win
function M._open_input(opts, done)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = 'wipe'
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, opts.lines or { '' })

  local width = M.width()
  local height = opts.single and 1 or 6
  local win = vim.api.nvim_open_win(buf, true, {
    relative = 'editor',
    row = math.floor((vim.o.lines - height) / 2) - 1,
    col = math.floor((vim.o.columns - width) / 2),
    width = width, height = height,
    style = 'minimal', border = 'rounded', zindex = 200,
    title = ' ' .. M.title(opts.title) .. ' ', title_pos = 'center',
    footer = opts.single and ' <CR>  submit    <Esc>  cancel ' or ' <C-s>  submit    q  cancel ',
    footer_pos = 'center',
  })
  vim.wo[win].wrap = true
  -- One column of padding, as the menus' leading space gives them.
  vim.wo[win].foldcolumn = '1'

  local answered = false
  local function finish(text)
    if answered then return end
    answered = true
    vim.cmd('stopinsert')
    pcall(vim.api.nvim_win_close, win, true)
    vim.schedule(function() done(text) end)
  end
  local function submit()
    finish(table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), '\n'))
  end

  local map_opts = { buffer = buf, nowait = true }
  vim.keymap.set({ 'n', 'i' }, '<C-s>', submit, map_opts)
  vim.keymap.set(opts.single and { 'n', 'i' } or 'n', '<CR>', submit, map_opts)
  vim.keymap.set('n', 'q', function() finish(nil) end, map_opts)
  vim.keymap.set(opts.single and { 'n', 'i' } or 'n', '<Esc>', function() finish(nil) end, map_opts)
  vim.api.nvim_create_autocmd('WinClosed', {
    pattern = tostring(win),
    once = true,
    callback = function() finish(nil) end,
  })
  vim.cmd('startinsert!')
  return win
end

--- Asks for an activation code and activates with it; a rejected code is offered again for fixing.
--- @param client vim.lsp.Client
--- @param previous string|nil
function M.ask_code(client, previous)
  M._open_input({ title = 'Activation code', lines = previous and { previous } or nil }, function(text)
    if not text or M.clean_code(text) == '' then return end
    M.use_code(client, text, function(ok, message)
      if not ok and message == M.CODE_REJECTED then M.ask_code(client, M.clean_code(text)) end
    end)
  end)
end

--- Asks for a license server URL and connects to it; a malformed URL is asked again.
--- @param client vim.lsp.Client
--- @param previous string|nil
function M.ask_server(client, previous)
  local view = licensing.view(client.id)
  M._open_input({
    title = 'License server URL', single = true,
    lines = { previous or (view and view.server_address) or 'https://' },
  }, function(url)
    if not url or vim.trim(url) == '' or vim.trim(url) == 'https://' then return end
    if not M.valid_server_url(url) then
      notify(M.SERVER_URL_INVALID, WARN)
      return M.ask_server(client, url)
    end
    M.add_server(client, url)
  end)
end

-- ---------------------------------------------------------------------------
-- The float
-- ---------------------------------------------------------------------------

--- The menu entries, most used first. The ones offered are numbered from 1.
M.ACTIONS = {
  { name = 'trial', label = 'Start 30-day trial' },
  { name = 'login', label = 'Sign in with JetBrains Account' },
  { name = 'code', label = 'Enter activation code' },
  { name = 'server', label = 'Use a license server' },
}

--- The sign-in entry where the browser's redirect cannot come back (`signin.remote`).
local PASTE_CODE_LABEL = 'Sign in with JetBrains Account (paste a code)'

--- The entries to offer. Changing a license that exists hides the trial, as VS Code's "activate
--- another" view does. An environment license hides everything but the license server, as VS Code
--- does: nothing else activated here would take effect. On a remote machine the sign-in is the
--- paste-code one.
--- @param opts { change: boolean|nil, environment: boolean|nil, remote: boolean|nil }
--- @return table[]
function M.actions(opts)
  local actions = vim.tbl_filter(function(action)
    if opts.environment then return action.name == 'server' end
    return not (opts.change and action.name == 'trial')
  end, M.ACTIONS)
  for i, action in ipairs(actions) do
    local label = opts.remote and action.name == 'login' and PASTE_CODE_LABEL or action.label
    actions[i] = vim.tbl_extend('force', action, { key = tostring(i), label = label })
  end
  return actions
end

--- Signs in with a code pasted from the sign-in page, through the CLI in a terminal: for remote
--- machines, and for anyone whose browser redirect fails. Cancels a browser sign-in under way, which
--- would otherwise go on waiting for five minutes.
--- @param client vim.lsp.Client
function M.login_with_code(client)
  M.cancel_login(function()
    signin.terminal_login(client.config.cmd[1], client.config.cmd_env)
  end)
end

local function start(client, name)
  if client:is_stopped() then return notify('the server is not running.', WARN) end
  if name == 'login' and signin.remote() then
    M.login_with_code(client)
  elseif name == 'login' then
    M.login(client)
  elseif name == 'trial' then
    M.trial(client)
  elseif name == 'code' then
    M.ask_code(client)
  else
    M.ask_server(client)
  end
end

--- The float's lines: the feature that was asked for, if any, what the license is, why the actions
--- are limited if they are, the entries.
--- @return string[] lines, integer first entry's line (1-based)
function M._lines(view, actions, env_var, feature)
  local lines = {}
  if feature then lines[#lines + 1] = (' %s needs an active license.'):format(feature) end
  if view then lines[#lines + 1] = ' ' .. view.message end
  if view and view.error then lines[#lines + 1] = ' ' .. view.error end
  if env_var then lines[#lines + 1] = ' ' .. licensing.environment_message(env_var) end
  if #lines > 0 then lines[#lines + 1] = '' end
  local first = #lines + 1
  for _, action in ipairs(actions) do
    lines[#lines + 1] = (' %s  %s'):format(action.key, action.label)
  end
  return lines, first
end

local ns = vim.api.nvim_create_namespace('intellij-lsp.activation')

--- The license float on screen (this one or the status float), so a second one focuses it rather
--- than stacking another.
local open_win = nil

--- Width of every licensing float (setup, activation, status, questions, input, sign-in), so they
--- read as one flow; narrower only on a narrow screen.
M.WIDTH = 72

--- `M.WIDTH`, or what fits the screen.
--- @return integer
function M.width()
  return math.max(30, math.min(M.WIDTH, vim.o.columns - 4))
end

--- `Java and Kotlin by IntelliJ IDEA · <what>`, the title of every licensing float.
--- @param what string
--- @return string
function M.title(what)
  return licensing.PRODUCT .. ' · ' .. what
end

--- A focused float of text lines followed by numbered entries, centred. A digit (or <CR> on an
--- entry) chooses it; `q`, <Esc> or closing the window chooses nothing. `on_choice` runs once,
--- after the float has closed, with the entry's `name` or nil.
---
--- One such float at a time: while one is open, a second call focuses it and returns it, and its
--- `on_choice` is never called. With `replace`, the open one is closed instead (choosing nothing)
--- and this one opens: for screens that must not be lost behind another, such as consent.
--- Every one is `M.width()` wide and centred, like the other licensing floats. `highlights` are
--- `{ line, group }` pairs (1-based lines). An entry without a `key` is reached with <CR> only.
--- @param opts { title: string, footer: string, lines: string[], first: integer, actions: { key: string|nil, name: any }[], highlights: { [1]: integer, [2]: string }[]|nil, replace: boolean|nil }
--- @param on_choice fun(name: string|nil)
--- @return integer win
function M.menu(opts, on_choice)
  if open_win and vim.api.nvim_win_is_valid(open_win) then
    if not opts.replace then
      vim.api.nvim_set_current_win(open_win)
      return open_win
    end
    pcall(vim.api.nvim_win_close, open_win, true)
  end
  local lines, first, actions = opts.lines, opts.first, opts.actions

  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = 'wipe'
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  for i = first, first + #actions - 1 do
    vim.hl.range(buf, ns, 'Number', { i - 1, 1 }, { i - 1, 2 })
  end
  for _, hl in ipairs(opts.highlights or {}) do
    vim.hl.range(buf, ns, hl[2], { hl[1] - 1, 0 }, { hl[1] - 1, -1 })
  end

  local width = M.width()
  local win = vim.api.nvim_open_win(buf, true, {
    relative = 'editor', row = 0, col = 0, width = width, height = #lines,
    style = 'minimal', border = 'rounded', zindex = 200,
    title = ' ' .. opts.title .. ' ', title_pos = 'center',
    footer = ' ' .. opts.footer .. ' ', footer_pos = 'center',
  })
  vim.wo[win].wrap = true
  vim.wo[win].linebreak = true
  vim.wo[win].breakindent = true
  vim.wo[win].cursorline = true
  local height = math.min(vim.api.nvim_win_text_height(win, {}).all, vim.o.lines - 4)
  vim.api.nvim_win_set_config(win, {
    relative = 'editor', height = height,
    row = math.floor((vim.o.lines - height) / 2) - 1,
    col = math.floor((vim.o.columns - width) / 2),
  })
  vim.api.nvim_win_set_cursor(win, { #actions > 0 and first or 1, 0 })
  open_win = win

  local answered = false
  local function finish(name)
    if answered then return end
    answered = true
    if open_win == win then open_win = nil end
    pcall(vim.api.nvim_win_close, win, true)
    vim.schedule(function() on_choice(name) end)
  end

  local map_opts = { buffer = buf, nowait = true }
  for _, action in ipairs(actions) do
    if action.key then vim.keymap.set('n', action.key, function() finish(action.name) end, map_opts) end
  end
  vim.keymap.set('n', '<CR>', function()
    local action = actions[vim.api.nvim_win_get_cursor(win)[1] - first + 1]
    if action then finish(action.name) end
  end, map_opts)
  vim.keymap.set('n', 'q', function() finish(nil) end, map_opts)
  vim.keymap.set('n', '<Esc>', function() finish(nil) end, map_opts)
  vim.api.nvim_create_autocmd('WinClosed', {
    pattern = tostring(win),
    once = true,
    callback = function() finish(nil) end,
  })
  return win
end

--- A question with numbered answers in the license float: `text`, then one entry per item. A digit
--- (1-9) or <CR> on an entry answers with that item; `q`, <Esc> or closing the float answers nil.
--- It replaces a license float still open, so a question asked from one (remove, sign out) or over
--- one is never lost behind it.
--- @param opts { title: string|nil, text: string[], items: any[], format: (fun(item: any): string)|nil, highlights: { [1]: integer, [2]: string }[]|nil }
--- @param done fun(item: any|nil, idx: integer|nil)
--- @return integer win
function M.choose(opts, done)
  local lines = {}
  for _, line in ipairs(opts.text) do lines[#lines + 1] = line ~= '' and (' ' .. line) or '' end
  lines[#lines + 1] = ''
  local first = #lines + 1
  local actions = {}
  for i, item in ipairs(opts.items) do
    local key = i <= 9 and tostring(i) or nil
    actions[i] = { key = key, name = i }
    lines[#lines + 1] = (' %s  %s'):format(key or ' ', (opts.format or tostring)(item))
  end
  local keys = #opts.items == 1 and '1' or ('1-%d'):format(math.min(#opts.items, 9))
  return M.menu({
    title = opts.title or M.title('License'), footer = keys .. '  choose    q  cancel',
    lines = lines, first = first, actions = actions, highlights = opts.highlights, replace = true,
  }, function(i)
    if i then return done(opts.items[i], i) end
    done(nil, nil)
  end)
end

--- Opens the activation float for a client's server. A digit (or <CR> on an entry) runs it; `q`,
--- <Esc> or closing the window is "Later".
--- @param client vim.lsp.Client
--- @param opts { change: boolean|nil, on_later: fun()|nil, feature: string|nil }|nil `change` when a
---   license exists; `feature` names what the user asked for when the float opens because of it
--- @return integer|nil win
function M.open(client, opts)
  opts = opts or {}
  local env_var = licensing.environment_license(client.config.cmd_env)
  local actions = M.actions({ change = opts.change, environment = env_var ~= nil, remote = signin.remote() })
  local lines, first = M._lines(licensing.view(client.id), actions, env_var, opts.feature)
  return M.menu({
    title = M.title('License'), footer = 'q  Later', lines = lines, first = first, actions = actions,
    highlights = opts.feature and { { 1, 'WarningMsg' } } or nil,
  }, function(name)
    if name then
      start(client, name)
    elseif opts.on_later then
      opts.on_later()
    end
  end)
end

--- How often `when_idle` looks whether the user is back in normal mode.
local IDLE_POLL = 300

--- Runs `fn` once the user is in normal mode with no key pending, so a float that takes focus does
--- not swallow keys typed in insert mode or into another prompt. Shared by the activation offer and
--- the consent screens.
--- @param fn fun()
function M.when_idle(fn)
  local mode = vim.api.nvim_get_mode()
  if mode.mode ~= 'n' or mode.blocking then
    return vim.defer_fn(function() M.when_idle(fn) end, IDLE_POLL)
  end
  fn()
end

--- The float as the startup offer, shown through `when_idle`. A license that became valid meanwhile
--- (another root, the CLI) shows nothing. A server that stopped before the float could show hands
--- the session's one offer back, so its restarted successor still makes it.
--- @param client vim.lsp.Client
function M.offer(client)
  M.when_idle(function()
    if client:is_stopped() then return licensing.offer_withdrawn() end
    local view = licensing.view(client.id)
    if not view or (view.kind ~= 'parked' and view.kind ~= 'unlicensed') then return end
    M.open(client, { on_later = function() notify(LATER, WARN) end })
  end)
end

--- The float for a feature a parked server refused (`licensing.prompt_license`), through
--- `when_idle`. A server licensed meanwhile shows nothing.
--- @param client vim.lsp.Client
--- @param feature string|nil
function M.prompt(client, feature)
  M.when_idle(function()
    if client:is_stopped() or not licensing.declined(client.id) then return end
    M.open(client, { feature = feature })
  end)
end

--- Forgets a pending sign-in and the float, for tests.
function M._reset()
  login = nil
  if open_win then pcall(vim.api.nvim_win_close, open_win, true) end
  open_win = nil
end

return M
