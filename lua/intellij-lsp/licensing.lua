--- The `jetbrains/licensing/*` protocol: what the server says about its license, and the requests
--- that change it.
---
--- The server does all the licensing work (sign-in, tokens, trial, license store, grace, parking).
--- This module only carries it: a per-client copy of the last `LicensingState`, a wrapper per
--- request with the timeouts the VS Code extension uses, and `project`, the pure function from a
--- state to what the UI should show. The wire model is the server's `jetbrains/licensing/*`
--- protocol; `project` mirrors the VS Code extension's `licensingProjection.ts`.
---
--- Two server-side facts shape it:
---
---   * State arrives as a whole-snapshot push, `jetbrains/licensing/state`, but only to a client that
---     advertises `experimental.licensingUi` (see `client.capabilities`). The server pushes once after
---     `initialized` and again after every change; there is no version field, so the latest push
---     is the truth. Mutating requests return no state of their own for the same reason: the push
---     that follows them, sent before their reply, is the result.
---   * The same capability switches off the server's own `window/showMessage` warnings on grace,
---     parking and floating-ticket loss. Whatever replaces them reads this store.
---
--- Every licensing request is exempt from the parked-server gate, so a server that refuses features
--- can still be licensed through them.

local M = {}

M.STATE = 'jetbrains/licensing/state'

local PREFIX = 'jetbrains/licensing/'

--- Fired with `data = { client_id = <id>, view = <project() result or nil> }` whenever a client's
--- licensing state changes, and with `view = nil` when the client exits.
M.EVENT = 'IntellijLspLicense'

--- The error code a timed-out request reports. Not an LSP code: the request never failed on the
--- server, the client stopped waiting.
M.TIMED_OUT = -32099

--- Request names (after `jetbrains/licensing/`), each with how long to wait for it and, for the
--- four that take one, the name of its single parameter.
---
--- The long ones come from `licenseMessageHandler.ts`: the server holds a JetBrains Account sign-in
--- and a license-server authorization for five minutes, waiting on a browser, and replies with
--- a typed outcome when either ends; the client must outlast that or it reports a failure the
--- server never had. The rest contact a JetBrains or license server at most once.
M.REQUESTS = {
  ['state/get'] = { timeout = 10000 },
  ['discovery/autoActivate'] = { timeout = 60000 },
  ['trial/startAnonymous'] = { timeout = 60000 },
  ['jba/login'] = { timeout = 310000 },
  ['jba/logout'] = { timeout = 30000 },
  ['subscriptions/update'] = { timeout = 60000 },
  ['subscriptions/use'] = { timeout = 30000, param = 'assetId' },
  ['subscriptions/unuseAll'] = { timeout = 30000 },
  ['activationCode/use'] = { timeout = 60000, param = 'activationCode' },
  ['activationCode/disable'] = { timeout = 60000 },
  ['licenseServer/add'] = { timeout = 360000, param = 'serverAddress' },
  ['licenseServer/reconnect'] = { timeout = 360000 },
  ['licenseServer/remove'] = { timeout = 30000 },
  ['eula/reset'] = { timeout = 30000 },
}

--- The last state per client, with `graceDeadline` already dropped where it contradicts a valid
--- license.
--- @type table<integer, table>
local state_by_client = {}

--- `project` of each client's last state, computed once per change: the statusline reads it on every
--- redraw.
--- @type table<integer, IntellijLspLicenseView>
local view_by_client = {}

--- Pushes seen per client, so a `state/get` reply can tell whether a push overtook it.
--- @type table<integer, integer>
local pushes_by_client = {}

--- What the notices of each client compare a new state against; see `M._notices`.
--- @type table<integer, table>
local notice_memo = {}

--- Licensing requests sent from here that change the license and have not answered yet, per client.
--- Their pushes arrive before their replies, so a removal the user asked for is still in flight when
--- its push says the license was removed.
--- @type table<integer, integer>
local changes_in_flight = {}

--- Requests whose pushes are not their own outcome to report. `jba/login` waits on a browser for
--- up to five minutes, and what the server reports meanwhile (a license server failing to renew)
--- must still be told.
local NOT_A_CHANGE = { ['state/get'] = true, ['jba/login'] = true }

--- The JSON decoder maps `null` to `vim.NIL`, which is truthy; the server leaves absent fields out,
--- but a field that does arrive as null must read as missing.
local function val(v)
  if v == vim.NIL then return nil end
  return v
end
M.val = val

--- `1 day left`, `12 days left`.
--- @param n integer
--- @return string
function M.days_left_text(n)
  return n == 1 and '1 day left' or (n .. ' days left')
end

--- `graceDeadline` next to a `Valid` license is contradictory; the valid license wins
--- (`licensingProjection.ts`, `graceDeadlineOf`).
--- @param state table
--- @return integer|nil epoch milliseconds
local function grace_deadline(state)
  local deadline = val(state.graceDeadline)
  if deadline == nil then return nil end
  if val(state.activeLicense) and state.activeLicense.status == 'Valid' then return nil end
  return deadline
end

--- Whether the server speaks this protocol. Only a server that advertises it in its `initialize`
--- result gets licensing requests; on any other one the licensing features stay off.
--- @param client vim.lsp.Client|nil
--- @return boolean
function M.supported(client)
  return client ~= nil and vim.tbl_get(client.server_capabilities or {}, 'experimental', 'licensing') == true
end

--- The last licensing state a client reported, or nil before the first one.
--- @param client_id integer
--- @return table|nil
function M.state(client_id)
  return state_by_client[client_id]
end

--- What to show for a client's license, or nil before its first state; see `project`.
--- @param client_id integer
--- @return IntellijLspLicenseView|nil
function M.view(client_id)
  return view_by_client[client_id]
end

local function fire(client_id, view)
  -- `on_exit` can run in a fast event, where autocmds are off limits; the error would also skip the
  -- rest of `on_exit`.
  if vim.in_fast_event() then
    return vim.schedule(function() fire(client_id, view) end)
  end
  vim.api.nvim_exec_autocmds('User', {
    pattern = M.EVENT,
    modeline = false,
    data = { client_id = client_id, view = view },
  })
end

--- Records a state for a client and fires `User IntellijLspLicense` when it differs from the last.
--- @param client_id integer
--- @param state table
function M._set(client_id, state)
  if type(state) ~= 'table' then return end
  state = vim.deepcopy(state)
  if val(state.graceDeadline) ~= nil and grace_deadline(state) == nil then state.graceDeadline = nil end
  if vim.deep_equal(state_by_client[client_id], state) then return end
  local previous = state_by_client[client_id]
  state_by_client[client_id] = state
  local view = M.project(state)
  view_by_client[client_id] = view
  notice_memo[client_id] = notice_memo[client_id] or {}
  M.notify(M._notices(notice_memo[client_id], view, (changes_in_flight[client_id] or 0) > 0))
  M.trial_notice(view)
  if previous and val(previous.featuresDeclined) == true and val(state.featuresDeclined) ~= true then
    M.refresh_features(client_id)
  end
  fire(client_id, view)
end

--- Forgets a client's state; called from `on_exit`.
--- @param client_id integer
function M.reset(client_id)
  pushes_by_client[client_id] = nil
  notice_memo[client_id] = nil
  if state_by_client[client_id] == nil then return end
  state_by_client[client_id] = nil
  view_by_client[client_id] = nil
  fire(client_id, nil)
end

--- Handlers to merge into the client's own.
--- @return table<string, function>
function M.handlers()
  return {
    [M.STATE] = function(_, state, ctx)
      pushes_by_client[ctx.client_id] = (pushes_by_client[ctx.client_id] or 0) + 1
      M._set(ctx.client_id, state)
    end,
  }
end

--- Sends one licensing request and calls back exactly once: with the reply, with the error, or with
--- `M.TIMED_OUT` once the request's timeout passes (the request is then cancelled).
---
--- A server without the protocol, or one that is not running, gets nothing sent and an error back.
--- @param client vim.lsp.Client
--- @param name string a key of `M.REQUESTS`, e.g. `'jba/login'`
--- @param arg string|nil the single parameter of the four requests that take one
--- @param callback fun(err: lsp.ResponseError|nil, result: any)
function M.request(client, name, arg, callback)
  local spec = M.REQUESTS[name]
  if not spec then error('unknown licensing request: ' .. tostring(name)) end
  if spec.param and type(arg) ~= 'string' then
    error(('licensing request %s needs its %s'):format(name, spec.param))
  end

  local function fail(message)
    vim.schedule(function() callback({ code = -32603, message = message }, nil) end)
  end
  if not M.supported(client) then
    return fail('the server does not support licensing requests')
  end

  local params = spec.param and { [spec.param] = arg } or vim.empty_dict()
  local done = false
  local timer --- @type uv.uv_timer_t|nil
  local changes = not NOT_A_CHANGE[name]
  local id = client.id
  local function finish(err, result)
    if done then return end
    done = true
    if changes then changes_in_flight[id] = math.max(0, (changes_in_flight[id] or 1) - 1) end
    if timer then
      timer:stop()
      timer:close()
    end
    callback(err, result)
  end

  local ok, request_id = client:request(PREFIX .. name, params, function(err, result)
    finish(err, result)
  end)
  if not ok then return fail('the server is not running') end
  if changes then changes_in_flight[id] = (changes_in_flight[id] or 0) + 1 end

  timer = vim.uv.new_timer()
  timer:start(spec.timeout, 0, vim.schedule_wrap(function()
    if done then return end
    pcall(client.cancel_request, client, request_id)
    finish({
      code = M.TIMED_OUT,
      message = ('%s did not answer within %d s'):format(name, spec.timeout / 1000),
    }, nil)
  end))
end

--- Fetches the state with `state/get` and records it.
---
--- A push that arrives while the request is in flight is newer than the reply and wins: the reply is
--- then dropped rather than recorded over it.
--- @param client vim.lsp.Client
--- @param callback fun(err: lsp.ResponseError|nil, view: IntellijLspLicenseView|nil)|nil
function M.refresh(client, callback)
  local pushes = pushes_by_client[client.id] or 0
  M.request(client, 'state/get', nil, function(err, state)
    if not err and type(state) == 'table' and (pushes_by_client[client.id] or 0) == pushes then
      M._set(client.id, state)
    end
    if callback then callback(err, M.view(client.id)) end
  end)
end

-- ---------------------------------------------------------------------------
-- Startup
-- ---------------------------------------------------------------------------

--- Variables that hand the server a license of their own. Each overrides the license store, so a
--- license activated from Neovim would not take effect while one is set.
M.ENVIRONMENT_VARIABLES = { 'INTELLIJ_SERVER_LICENSE', 'INTELLIJ_SERVER_LICENSE_FILE', 'JETBRAINS_LICENSE_SERVER' }

--- The variable that licenses the server, or nil when the server owns no environment license.
--- @param env table<string, string>|nil the server's environment, normally `client.config.cmd_env`
--- @return string|nil
function M.environment_license(env)
  for _, name in ipairs(M.ENVIRONMENT_VARIABLES) do
    local value = env and env[name]
    if type(value) == 'string' and vim.trim(value) ~= '' then return name end
  end
  return nil
end

--- Why the activation actions are off while an environment license is set; VS Code's sentence
--- (`environmentLicense.ts`), with Neovim's restart.
--- @param name string a member of `M.ENVIRONMENT_VARIABLES`
--- @return string
function M.environment_message(name)
  return ('The license is set through %s, which overrides any license activated here. '):format(name)
    .. 'Unset it and run :IntellijLspRestart to activate a license from Neovim.'
end

--- How long `discovery/autoActivate` may run before "Checking license…" shows (VS Code's
--- `LICENSE_DISCOVERY_PROGRESS_DELAY_MS`). Most discoveries answer well within it.
M.DISCOVERY_PROGRESS_DELAY = 500

--- Discovery sources in words. `toolbox` and `productKeyFile` are also license sources and take
--- their label from `M.SOURCE_LABELS`.
local DISCOVERY_SOURCES = {
  environmentLicenseServer = 'License server from JETBRAINS_LICENSE_SERVER',
}

--- Whether the activation was offered in this Neovim session. One offer per session, not per root:
--- every root's server reads the same license store, so a second offer would ask the same question.
local offered = false

--- Offers the user to activate a license. Called at most once per session, by `startup`, when a
--- server comes up without a valid license.
---
--- With a UI this is the activation float (`activation.lua`), which waits until the user is back in
--- normal mode. Without one (`--headless`, a script) it is a warning naming the CLI commands that
--- activate a license, or, with an environment license set, why nothing activated here would take
--- effect.
--- @param client vim.lsp.Client
--- @param view IntellijLspLicenseView
--- @param env_var string|nil the environment variable that owns the license
function M.offer_activation(client, view, env_var)
  if #vim.api.nvim_list_uis() > 0 then
    return require('intellij-lsp.activation').offer(client)
  end
  local text
  if env_var then
    text = view.message .. ' ' .. M.environment_message(env_var)
  else
    local launcher = client.config.server_cmd and client.config.server_cmd[1] or 'intellij-server'
    text = view.message .. (' Run `%s license trial` or `%s license login` in a terminal;'):format(launcher, launcher)
      .. ' the server picks the license up within seconds.'
  end
  vim.notify('IntelliJ LSP: ' .. text, vim.log.levels.WARN)
end

local function echo(id, text, status)
  local ok, new_id = pcall(vim.api.nvim_echo, { { text } }, false, {
    id = id,
    kind = 'progress',
    source = 'intellij-lsp',
    title = 'IntelliJ LSP',
    status = status,
  })
  return ok and new_id or id
end

--- Shows `text` as a progress message in the message area once `M.DISCOVERY_PROGRESS_DELAY` has
--- passed, so a request that answers quickly shows nothing.
--- @param text string
--- @return fun(final: string, status: 'success'|'failed'): boolean closes the message with `final`;
---   true when it had shown
function M.progress(text)
  local done, msg_id = false, nil
  vim.defer_fn(function()
    if not done then msg_id = echo(nil, text, 'running') end
  end, M.DISCOVERY_PROGRESS_DELAY)
  return function(final, status)
    done = true
    if msg_id then echo(msg_id, final, status) end
    return msg_id ~= nil
  end
end

--- `discovery/autoActivate`, with "Checking license…" in the message area if it outlasts
--- `M.DISCOVERY_PROGRESS_DELAY`. The server looks for a license server in the environment, a
--- Toolbox login and a product key file, and activates the first it finds.
--- @param client vim.lsp.Client
--- @param callback fun()
local function discover(client, callback)
  local stop = M.progress('Checking license…')
  M.request(client, 'discovery/autoActivate', nil, function(err, result)
    local found = not err and type(result) == 'table' and result.activated == true
    stop(found and ('License found: ' .. (DISCOVERY_SOURCES[val(result.source)] or M.SOURCE_LABELS[val(result.source)] or 'activated'))
      or 'No license found', found and 'success' or 'failed')
    callback()
  end)
end

--- The first state sync of a server, from `on_init`; a restarted server is a new client and syncs
--- again.
---
---   1. `state/get`.
---   2. No license at all: `discovery/autoActivate`. A server already holding one, valid or not,
---      skips it, as VS Code does (`startLicenseDiscovery`).
---   3. Still parked or unlicensed: `M.offer_activation`, once per session. A grace period still
---      has working features, and an `authenticating` server is mid sign-in; neither is offered.
---
--- The push that follows a successful activation arrives before its reply, so the store already
--- holds the result when step 3 reads it.
--- @param client vim.lsp.Client
--- @param callback fun(view: IntellijLspLicenseView|nil)|nil for tests: called once the sync settles
function M.startup(client, callback)
  local function settle()
    local view = M.view(client.id)
    if view and (view.kind == 'parked' or view.kind == 'unlicensed') and not offered then
      offered = true
      M.offer_activation(client, view, M.environment_license(client.config.cmd_env))
    end
    if callback then callback(view) end
  end

  if not M.supported(client) then
    if callback then callback(nil) end
    return
  end
  M.refresh(client, function(err)
    local state = M.state(client.id)
    if err and not state then
      if callback then callback(nil) end
      return
    end
    if state and val(state.activeLicense) == nil then return discover(client, settle) end
    settle()
  end)
end

--- Forgets that the activation was offered, so the next unlicensed server offers it again; for
--- `:IntellijLspLicense reset` and tests.
function M._reset_session()
  offered = false
end

--- An offer that never reached the screen (its server stopped while the float waited for normal
--- mode) does not count as the session's one offer.
M.offer_withdrawn = M._reset_session

-- ---------------------------------------------------------------------------
-- Projection
-- ---------------------------------------------------------------------------

--- @class IntellijLspLicenseView
--- @field kind 'licensed'|'session-expired'|'grace'|'parked'|'authenticating'|'unlicensed'
--- @field message string one line for a notification, float or tooltip
--- @field source string|nil `activeLicense.source`: trial, eap, subscription, activationCode, licenseServer, toolbox, productKeyFile
--- @field source_label string|nil the source in words
--- @field status string|nil `activeLicense.status`: Valid, Expired, Invalid, Revoked, Unknown
--- @field product string|nil display name of the licensed product
--- @field holder string|nil who or what the license is for
--- @field license_id string|nil
--- @field valid_through string|nil `YYYY-MM-DD`
--- @field days_left integer|nil
--- @field grace_deadline integer|nil epoch milliseconds
--- @field parked_reason string|nil StartedUnlicensed, GraceExpired, LicenseRemoved, LicenseRevoked
--- @field authenticating 'account'|'licenseServer'|nil what `authenticating` waits on
--- @field account { display_name: string, email: string|nil }|nil the signed-in JetBrains Account
--- @field subscriptions { asset_id: string, product: string, licensed_to: string, status: string, valid_through: string, license_id: string }[]
--- @field server_address string|nil the configured license server
--- @field ticket string|nil the license server's `floatingTicketStatus`: NotObtained, Obtaining, Obtained, Refreshing, FailedToRefresh
--- @field server_error string|nil a license-server failure, in words
--- @field error string|nil a sign-in or license-server failure, in words

--- The product's name on every screen, as the VS Code extension calls it.
M.PRODUCT = 'Java and Kotlin by IntelliJ IDEA'

local PRODUCT_NAMES = {
  ['intellij-server'] = M.PRODUCT,
}

M.SOURCE_LABELS = {
  trial = 'Trial',
  eap = 'Early Access Program',
  subscription = 'JetBrains Account',
  activationCode = 'Activation Code',
  licenseServer = 'License Server',
  toolbox = 'JetBrains Toolbox',
  productKeyFile = 'Product Key File',
}

-- The sentences are VS Code's (`licensingProjection.ts`), so both clients say the same thing.
local ACCOUNT_AUTH_FAILED = "Couldn't sign in to your JetBrains Account. Try again or use another activation method."
M.ACCOUNT_AUTH_FAILED = ACCOUNT_AUTH_FAILED
local LICENSE_SERVER_REFRESH_FAILED = "Lost connection to the license server and couldn't renew your license. Check the server and try again."
local SESSION_EXPIRED = 'Your JetBrains Account session expired. Sign in again to keep your license active.'
local FEATURES_UNAVAILABLE = 'Activate a license to use Java and Kotlin features.'
local FEATURES_UNAVAILABLE_AFTER_LOSS = 'Activate another license to use Java and Kotlin features.'

M.PARKED_MESSAGES = {
  StartedUnlicensed = FEATURES_UNAVAILABLE,
  GraceExpired = 'The grace period has ended. ' .. FEATURES_UNAVAILABLE,
  LicenseRemoved = 'The license was removed. ' .. FEATURES_UNAVAILABLE_AFTER_LOSS,
  LicenseRevoked = 'The license was revoked. ' .. FEATURES_UNAVAILABLE_AFTER_LOSS,
}

local function holder_of(active)
  local source = active.source
  if source == 'trial' then return 'Trial User' end
  if source == 'eap' then return val(active.licensedTo) or 'Early Access Program' end
  if source == 'licenseServer' then return val(active.serverAddress) end
  return val(active.licensedTo)
end

--- A subscription carries its license id only in the account's subscription list.
local function license_id_of(active, jba)
  local id = val(active.licenseId)
  if id then return id end
  if active.source == 'subscription' and jba.authenticationStatus == 'Authenticated' then
    for _, sub in ipairs(val(jba.availableSubscriptions) or {}) do
      if sub.assetId == active.assetId then return sub.licenseId end
    end
  end
  return nil
end

local function subscriptions_of(jba)
  local out = {}
  for _, sub in ipairs(val(jba.availableSubscriptions) or {}) do
    table.insert(out, {
      asset_id = sub.assetId,
      product = PRODUCT_NAMES[sub.product] or sub.product,
      licensed_to = sub.licensedTo,
      status = sub.status,
      valid_through = sub.validThrough,
      license_id = sub.licenseId,
    })
  end
  return out
end

--- The grace deadline as a local time of day, the way VS Code shows it.
--- @param ms integer epoch milliseconds
--- @return string
function M.format_deadline(ms)
  return os.date('%H:%M', math.floor(ms / 1000)) --[[@as string]]
end

--- What to show for a licensing state: one `kind`, and the fields to fill a status line, a float or a
--- notification with. Pure; mirrors `deriveLicensingState` and `formatLicenseStatus` in
--- `licensingProjection.ts`, in the same order of precedence:
---
---   1. `authenticating`: no valid license, and a JetBrains Account sign-in or a license-server
---      ticket request is under way.
---   2. `licensed`, or `session-expired` when the license is valid but the JetBrains Account behind it
---      could not be prolonged. Features work in both; the second needs a new sign-in soon.
---   3. `grace`: the license was lost; features keep working until `grace_deadline`.
---   4. `parked`: the server refuses feature requests, for `parked_reason`.
---   5. `unlicensed`: none of the above, e.g. an expired license the server has not parked yet.
---      Not one of VS Code's views, which folds it into its activation screen.
--- @param state table a `LicensingState`
--- @return IntellijLspLicenseView
function M.project(state)
  local jba = val(state.jbaLicensingState) or {}
  local server = val(state.licenseServerFlowState) or {}
  local active = val(state.activeLicense)
  local valid = active ~= nil and active.status == 'Valid'
  local deadline = grace_deadline(state)
  local configured = server.kind == 'configured'

  local view = {
    subscriptions = subscriptions_of(jba),
    server_address = configured and val(server.serverAddress) or nil,
    ticket = configured and val(server.floatingTicketStatus) or nil,
    grace_deadline = deadline,
  }
  if jba.authenticationStatus == 'Authenticated' or jba.authenticationStatus == 'FailedToProlongateAuthentication' then
    local info = val(jba.accountInfo) or {}
    view.account = { display_name = info.displayName, email = val(info.email) }
  end

  if configured and (server.floatingTicketStatus == 'FailedToRefresh' or val(server.errorMessage)) then
    local message = vim.trim(val(server.errorMessage) or '')
    view.server_error = message ~= '' and message or LICENSE_SERVER_REFRESH_FAILED
  end
  view.error = jba.authenticationStatus == 'FailedToAuthenticate' and ACCOUNT_AUTH_FAILED or view.server_error

  if active then
    view.source = active.source
    view.source_label = M.SOURCE_LABELS[active.source] or active.source
    view.status = active.status
    view.product = PRODUCT_NAMES[active.product] or active.product
    view.holder = holder_of(active)
    view.license_id = license_id_of(active, jba)
    view.valid_through = val(active.validThrough)
    -- A valid license with 0 days and no end date has no end worth counting down to.
    local days = val(active.daysLeft)
    if days ~= nil and (view.valid_through ~= nil or not valid or days > 0) then
      view.days_left = days
    end
  end

  if not valid and jba.authenticationStatus == 'Authenticating' then
    view.kind, view.authenticating = 'authenticating', 'account'
    view.message = 'Waiting for the JetBrains Account sign-in in your browser…'
  elseif not valid and configured
    and (server.floatingTicketStatus == 'Obtaining' or server.floatingTicketStatus == 'Refreshing') then
    view.kind, view.authenticating = 'authenticating', 'licenseServer'
    view.message = 'Getting a license from ' .. (view.server_address or 'the license server') .. '…'
  elseif valid and jba.authenticationStatus == 'FailedToProlongateAuthentication' then
    view.kind, view.message = 'session-expired', SESSION_EXPIRED
  elseif valid then
    view.kind = 'licensed'
    if active.source == 'eap' then
      view.message = view.valid_through and ('EAP license is valid through ' .. view.valid_through)
        or 'EAP license is active'
    else
      view.message = 'License is active (' .. view.source_label .. ')'
    end
  elseif deadline then
    view.kind = 'grace'
    local lead = active and ('License ' .. active.status .. ': ' .. view.product) or 'No valid license'
    view.message = lead .. '. Features work until ' .. M.format_deadline(deadline) .. '.'
  elseif val(state.featuresDeclined) == true then
    view.kind = 'parked'
    view.parked_reason = val(state.parkedReason)
    local reason = view.parked_reason or 'StartedUnlicensed'
    local lead = ''
    if active then
      lead = 'License ' .. active.status .. ': ' .. view.product .. '. '
    elseif reason == 'StartedUnlicensed' then
      lead = 'No active license. '
    end
    view.message = lead .. (M.PARKED_MESSAGES[reason] or FEATURES_UNAVAILABLE)
  else
    view.kind = 'unlicensed'
    view.message = active and ('License ' .. active.status .. ': ' .. view.product) or 'No active license.'
  end
  return view
end


-- ---------------------------------------------------------------------------
-- Notices
-- ---------------------------------------------------------------------------

-- The capability that turns on the state pushes also turns off the server's own `window/showMessage`
-- warnings. These replace them, edge-triggered the same way:
-- one notification when a condition starts, none while it lasts.

local ACTIVATE_HINT = 'Run :IntellijLspLicense to activate a license.'

--- Ticket states in which a license server's license is still held, as the server counts them.
local TICKET_LIVE = { Obtained = true, Refreshing = true, FailedToRefresh = true }

--- Kinds in which features work, so moving from one of them to `parked` is a loss.
local FEATURES_WORK = { licensed = true, ['session-expired'] = true, grace = true }

--- What changed between the last view of a client and this one, as one notification, or nil.
---
--- `memo` holds what the last call saw (`view`, and `server_error`, the last license-server failure
--- reported, latched until the ticket is obtained again, as the server does) and is updated. A
--- client's first view is the baseline: the startup offer (`M.startup`) speaks for a server that
--- starts parked or unlicensed, so only conditions it does not cover are reported then.
---
---   * grace started: features work until the deadline.
---   * parked after a license that worked (VS Code `licenseLossNotifier.ts`), with the reason. A
---     removal asked for from here (`own_change`) reports its own outcome and is not repeated.
---   * the JetBrains Account session could not be prolonged.
---   * the license server failed to renew the license, or the license from it was lost.
--- @param memo table per client, kept between calls
--- @param view IntellijLspLicenseView
--- @param own_change boolean a license-changing request from this plugin is in flight
--- @return { text: string, level: integer }|nil
function M._notices(memo, view, own_change)
  local prev = memo.view
  memo.view = view
  local parts, level = {}, vim.log.levels.WARN
  local function add(text, lvl)
    table.insert(parts, text)
    if lvl and lvl > level then level = lvl end
  end

  -- License server first: it says why the grace or parking that comes with it started. A failure
  -- of a request made from here is that request's to report, but still latched.
  if view.ticket == nil or view.ticket == 'Obtained' then memo.server_error = nil end
  if view.server_error and view.server_error ~= memo.server_error then
    memo.server_error = view.server_error
    if not own_change then add(view.server_error) end
  elseif view.ticket == 'NotObtained' and prev and TICKET_LIVE[prev.ticket] and not own_change then
    add('Lost the license from ' .. (view.server_address or 'the license server') .. '.')
  end

  if view.kind == 'grace' and (not prev or prev.kind ~= 'grace') then
    add(view.message .. ' ' .. ACTIVATE_HINT)
  elseif view.kind == 'parked' and prev and FEATURES_WORK[prev.kind]
    and not (own_change and view.parked_reason == 'LicenseRemoved') then
    add(view.message .. ' Run :IntellijLspLicense.', vim.log.levels.ERROR)
  elseif view.kind == 'session-expired' and (not prev or prev.kind ~= 'session-expired') then
    add(SESSION_EXPIRED .. ' Run :IntellijLspLicense login.')
  end

  if #parts == 0 then return nil end
  return { text = table.concat(parts, ' '), level = level }
end

--- When each notice text was last shown, so the same push to every root's server shows once.
--- @type table<string, integer>
local shown_at = {}

--- How long an identical notice stays deduplicated.
M.NOTICE_DEDUPE_MS = 10000

--- Shows a notice from `M._notices` unless the same text was shown moments ago.
--- @param notice { text: string, level: integer }|nil
function M.notify(notice)
  if not notice then return end
  local now = vim.uv.now()
  if shown_at[notice.text] and now - shown_at[notice.text] < M.NOTICE_DEDUPE_MS then return end
  shown_at[notice.text] = now
  vim.notify('IntelliJ LSP: ' .. notice.text, notice.level)
end

--- Where the trial reminders are recorded, so a reminder shows once across sessions and restarts.
--- @return string
function M.notice_path()
  return vim.fs.normalize(vim.fn.stdpath('data') .. '/intellij-lsp/license-notices.json')
end

--- Days left at which the trial reminds, latest first.
M.TRIAL_REMINDERS = { 1, 7 }

--- The trial reminder due for a view, or nil: `{ stage, text, level }`. `stage` is the threshold
--- reached (7, then 1 day left). Pure.
--- @param view IntellijLspLicenseView
--- @return { stage: integer, text: string, level: integer }|nil
function M._trial_reminder(view)
  if view.kind ~= 'licensed' or view.source ~= 'trial' or view.days_left == nil then return nil end
  local stage
  for _, threshold in ipairs(M.TRIAL_REMINDERS) do
    if view.days_left <= threshold then stage = threshold break end
  end
  if not stage then return nil end
  local when = view.days_left <= 0 and 'today' or view.days_left == 1 and 'tomorrow'
    or ('in %d days'):format(view.days_left)
  local through = view.valid_through and (' (valid through %s)'):format(view.valid_through) or ''
  return {
    stage = stage,
    text = ('The trial ends %s%s. %s'):format(when, through, ACTIVATE_HINT),
    level = stage == 1 and vim.log.levels.WARN or vim.log.levels.INFO,
  }
end

--- Reminds of the trial's end once at 7 days left and once at 1 day left, at most once a day. The
--- reminder shown is recorded per trial (its end date) in `M.notice_path()`.
--- @param view IntellijLspLicenseView
--- @param today string|nil `YYYY-MM-DD`, for tests
function M.trial_notice(view, today)
  local reminder = M._trial_reminder(view)
  if not reminder then return end
  today = today or os.date('%Y-%m-%d') --[[@as string]]
  local path = M.notice_path()
  local record = {}
  local fd = io.open(path, 'r')
  if fd then
    local ok, data = pcall(vim.json.decode, fd:read('*a'))
    fd:close()
    if ok and type(data) == 'table' and type(data.trial) == 'table' then record = data.trial end
  end
  if record.day == today then return end
  -- A trial without an end date is stored as null, which decodes as `vim.NIL`.
  if val(record.valid_through) == view.valid_through and type(record.stage) == 'number' and record.stage <= reminder.stage then
    return
  end
  vim.fn.mkdir(vim.fs.dirname(path), 'p')
  vim.fn.writefile({ vim.json.encode({
    trial = { valid_through = view.valid_through or vim.NIL, stage = reminder.stage, day = today },
  }) }, path)
  M.notify(reminder)
end

-- ---------------------------------------------------------------------------
-- Statusline
-- ---------------------------------------------------------------------------

--- Days left at which the statusline starts counting down a valid license.
M.STATUSLINE_DAYS = 7

--- The statusline text for a view: `''` while nothing needs attention, otherwise a short tag such as
--- `IJ trial 5d`, `IJ grace 12m` or `IJ unlicensed`. Pure.
--- @param view IntellijLspLicenseView|nil
--- @param now_ms integer|nil epoch milliseconds, for tests
--- @return string
function M.statusline(view, now_ms)
  if not view then return '' end
  local kind = view.kind
  if kind == 'licensed' then
    if view.days_left == nil or view.days_left > M.STATUSLINE_DAYS then return '' end
    return ('IJ %s %dd'):format(view.source == 'trial' and 'trial' or 'license', view.days_left)
  elseif kind == 'session-expired' then
    return 'IJ sign in'
  elseif kind == 'grace' then
    local minutes = math.max(0, math.ceil((view.grace_deadline - (now_ms or os.time() * 1000)) / 60000))
    if minutes >= 120 then return ('IJ grace %dh'):format(math.floor(minutes / 60)) end
    return ('IJ grace %dm'):format(minutes)
  elseif kind == 'authenticating' then
    return 'IJ signing in'
  end
  return 'IJ unlicensed'
end

-- ---------------------------------------------------------------------------
-- Parked servers
-- ---------------------------------------------------------------------------

--- `ServerCancelled`, what a parked server answers to every feature request.
M.SERVER_CANCELLED = -32802

--- Requests Neovim makes on its own while editing: diagnostics, completion, highlights, hints,
--- lenses, tokens, folds. A parked server's refusal of them reads as an empty result, since nobody
--- asked and an error per keystroke helps no one.
---
--- Everything else is asked for on purpose (formatting, rename, code actions, navigation, hover,
--- hierarchies, symbol search, commands). There an empty result would read as "done" or "nothing
--- found", so the refusal stays an error and its message says why: no license.
local QUIET = {}
for _, method in ipairs({ 'textDocument/completion', 'textDocument/diagnostic', 'workspace/diagnostic',
  'textDocument/codeLens', 'textDocument/inlayHint', 'textDocument/documentHighlight', 'textDocument/documentLink',
  'textDocument/foldingRange', 'textDocument/signatureHelp', 'textDocument/onTypeFormatting',
  'textDocument/documentSymbol', 'textDocument/documentColor', 'textDocument/linkedEditingRange',
  'textDocument/inlineValue', 'textDocument/inlineCompletion', 'textDocument/selectionRange' }) do
  QUIET[method] = true
end
local QUIET_PREFIXES = { 'textDocument/semanticTokens/', 'completionItem/', 'codeLens/', 'inlayHint/', 'documentLink/' }

local function quiet_method(method)
  if QUIET[method] then return true end
  for _, prefix in ipairs(QUIET_PREFIXES) do
    if vim.startswith(method, prefix) then return true end
  end
  return false
end

--- Asked for on purpose, but Neovim keeps only the `result` of each reply and drops `err`
--- (`vim.lsp.buf.references`, `get_locations`, `hover` in `runtime/lua/vim/lsp/buf.lua`), so the
--- refusal would read as "No references found". The user is told here instead, by the name of what
--- they asked for.
M.REFUSED_FEATURES = {
  ['textDocument/references'] = 'Find References',
  ['textDocument/definition'] = 'Go to Definition',
  ['textDocument/declaration'] = 'Go to Declaration',
  ['textDocument/typeDefinition'] = 'Go to Type Definition',
  ['textDocument/implementation'] = 'Go to Implementation',
  ['textDocument/hover'] = 'Hover',
}

--- The client command behind the one code action a parked server offers.
M.ACTIVATE_COMMAND = 'intellij-lsp.license.activate'

--- The code action a parked server offers in place of its own, so `gra` leads to a license rather
--- than "No code actions available". A Command, not a CodeAction: Neovim runs it without asking the
--- server to resolve it.
M.ACTIVATE_ACTION = { title = 'Activate a license to use code actions', command = M.ACTIVATE_COMMAND }

--- How long after one license prompt another is not shown: a `K` pressed twice, or one request
--- per server of the buffer, is one prompt.
M.PROMPT_DEDUPE_MS = 1500

local prompted_at = nil

--- Tells the user that `feature` needs a license: the activation float with `feature` on its
--- first line, or without a UI a warning. Nothing while a prompt was shown moments ago.
--- @param client vim.lsp.Client
--- @param feature string|nil what the user asked for, e.g. `Find References`
function M.prompt_license(client, feature)
  local now = vim.uv.now()
  if prompted_at and now - prompted_at < M.PROMPT_DEDUPE_MS then return end
  prompted_at = now
  vim.schedule(function()
    if #vim.api.nvim_list_uis() > 0 then
      return require('intellij-lsp.activation').prompt(client, feature)
    end
    local view = M.view(client.id)
    vim.notify(('IntelliJ LSP: %s needs an active license. %s Run :IntellijLspLicense.')
      :format(feature or 'This feature', view and view.message or FEATURES_UNAVAILABLE), vim.log.levels.WARN)
  end)
end

--- Whether a client's server refuses feature requests.
--- @param client_id integer
--- @return boolean
function M.declined(client_id)
  local state = state_by_client[client_id]
  return state ~= nil and val(state.featuresDeclined) == true
end

local sync_callers = nil

--- Whether the request being sent is waited on: `buf_request_sync` and `request_sync` block until
--- every handler has run (Neovim's `tagfunc` asks for definitions so), so a handler held back
--- would hold up the editor for the whole timeout.
--- @return boolean
local function waited_on()
  sync_callers = sync_callers
    or { [vim.lsp.buf_request_sync] = true, [require('vim.lsp.client').request_sync] = true }
  for level = 3, 40 do
    local info = debug.getinfo(level, 'f')
    if not info then return false end
    if sync_callers[info.func] then return true end
  end
  return false
end

--- Wraps `request` on one client so a parked server stays quiet. Neovim reports a `ServerCancelled`
--- per request: completion warns on every keystroke, and the diagnostic pull re-sends itself at once
--- (`retriggerRequest`), so a parked server would get a stream of pulls. While the server declines
--- features, the replies to `QUIET` requests reach their handlers as an empty result; the others keep
--- the error, with a message that names the cause. `M.refresh_features` asks again once the server
--- is licensed.
---
--- Two exceptions to keeping the error, for requests whose errors Neovim drops:
---
---   * `REFUSED_FEATURES` prompt for a license (`M.prompt_license`). Their handler is not called
---     when this server is the only one that answers the method in the buffer: it would only say
---     "nothing found". With another server there, it gets an empty result, so that server's
---     answer still shows. A synchronous caller (`waited_on`) gets the error, as before.
---   * `textDocument/codeAction` answers with `M.ACTIVATE_ACTION`, which opens the float.
---
--- Also, always: the server sends `error.data = null` (`vim.NIL`), and `vim.lsp.diagnostic` both
--- indexes `error.data.retriggerRequest` and, for missing data, re-sends the pull at once, with no
--- delay. Before the first state push, or from a server without the licensing protocol, a parked
--- server is not known to be parked, and that retry would loop. `null` is read as "do not retrigger":
--- the next edit pulls again anyway.
--- @param client vim.lsp.Client
function M.install_quiet(client)
  -- By `client_id`, not this client: the commands table may be shared with other clients.
  client.commands = client.commands or {}
  client.commands[M.ACTIVATE_COMMAND] = function(_, ctx)
    local c = vim.lsp.get_client_by_id(ctx.client_id)
    if c then M.prompt_license(c, 'Code actions') end
  end
  local orig_request = client.request
  client.request = function(self, method, params, handler, bufnr, ...)
    local h = handler or (self.handlers and self.handlers[method]) or vim.lsp.handlers[method]
    if not h then
      return orig_request(self, method, params, handler, bufnr, ...)
    end
    local quiet = quiet_method(method)
    local waited = M.REFUSED_FEATURES[method] ~= nil and waited_on()
    return orig_request(self, method, params, function(err, result, ctx, ...)
      if err and err.code == M.SERVER_CANCELLED then
        if err.data == vim.NIL then err.data = { retriggerRequest = false } end
        if M.declined(self.id) then
          if quiet then return h(nil, nil, ctx, ...) end
          if method == 'textDocument/codeAction' then return h(nil, { M.ACTIVATE_ACTION }, ctx, ...) end
          local feature = M.REFUSED_FEATURES[method]
          if feature then
            M.prompt_license(self, feature)
            if not waited then
              local others = ctx and ctx.bufnr and vim.tbl_filter(function(c) return c.id ~= self.id end,
                vim.lsp.get_clients({ bufnr = ctx.bufnr, method = method })) or {}
              if #others > 0 then return h(nil, nil, ctx, ...) end
              return
            end
          end
          local view = M.view(self.id)
          err.message = (view and view.message or FEATURES_UNAVAILABLE) .. ' Run :IntellijLspLicense.'
        end
      end
      return h(err, result, ctx, ...)
    end, bufnr, ...)
  end
end

--- Asks again for what a parked server refused, through Neovim's own handlers for the server's refresh
--- requests: diagnostics, semantic tokens, code lenses and inlay hints. 263.7084.0 sends none of
--- these refreshes when it is licensed, and a refused diagnostic pull is not retried once
--- `M.install_quiet` has turned it into an empty result.
--- @param client_id integer
function M.refresh_features(client_id)
  vim.schedule(function()
    if not vim.lsp.get_client_by_id(client_id) then return end
    for _, method in ipairs({ 'workspace/diagnostic/refresh', 'workspace/semanticTokens/refresh',
      'workspace/codeLens/refresh', 'workspace/inlayHint/refresh' }) do
      local handler = vim.lsp.handlers[method]
      if handler then pcall(handler, nil, nil, { method = method, client_id = client_id }) end
    end
  end)
end

-- ---------------------------------------------------------------------------
-- Buffer hint
-- ---------------------------------------------------------------------------

--- While a parked server makes completion, diagnostics and highlights read as empty, a buffer
--- looks broken rather than unlicensed. A note at the end of the first line says why. Not a virtual
--- line above it: Neovim shows those only while the window's 'topfill' covers them, which `gg` and
--- a new window reset, so the note would be gone just when the top of the file is on screen. Short,
--- so a narrow window does not cut off the command.

M.HINT = 'No license, IntelliJ features are off · :IntellijLspLicense'

local hint_ns = vim.api.nvim_create_namespace('intellij-lsp.license-hint')
M.HINT_NS = hint_ns

local hints_installed = false

--- The hint for a buffer, or nil while none of its servers refuses features.
--- @param bufnr integer
--- @return string|nil
function M.hint_text(bufnr)
  for _, c in ipairs(vim.lsp.get_clients({ bufnr = bufnr })) do
    if M.declined(c.id) then return M.HINT end
  end
  return nil
end

--- Shows, updates or clears the hint of one buffer.
--- @param bufnr integer
function M.show_hint(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) then return end
  local text = M.hint_text(bufnr)
  vim.api.nvim_buf_clear_namespace(bufnr, hint_ns, 0, -1)
  if not text then return end
  vim.api.nvim_buf_set_extmark(bufnr, hint_ns, 0, 0, {
    virt_text = { { text, 'DiagnosticVirtualTextWarn' } },
    virt_text_pos = 'eol',
  })
end

--- Keeps the hint of every buffer current: on attach, and on every license change (the change
--- that ends a parking clears it). Once per session; later calls do nothing.
function M.install_hints()
  if hints_installed then return end
  hints_installed = true
  local group = vim.api.nvim_create_augroup('IntellijLspLicenseHint', { clear = true })
  vim.api.nvim_create_autocmd('LspAttach', {
    group = group,
    callback = function(args) M.show_hint(args.buf) end,
  })
  vim.api.nvim_create_autocmd('User', {
    group = group,
    pattern = M.EVENT,
    callback = function()
      for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
        if vim.api.nvim_buf_is_loaded(bufnr) then M.show_hint(bufnr) end
      end
    end,
  })
end

return M
