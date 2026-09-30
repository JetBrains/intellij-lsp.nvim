--- Import and indexing phase, reported in the message area.
---
--- The server reports its startup phases as plain LSP `$/progress`. This module joins each report's
--- `title` and `message` into one line, keeping the server's own wording:
---
---   IntelliJ LSP: Importing: Maven          IntelliJ LSP: Indexing: Invalidating files
---   IntelliJ LSP: Importing: Gradle         IntelliJ LSP: 47% Indexing
---
--- `title` and `message` are reported verbatim, never translated into a local vocabulary.
---
--- These land where progress.lua's closing notification already lands, next to it and in the same
--- voice, rather than in a separate widget. That is `nvim_echo` with `kind='progress'`: it returns
--- a message id, and passing that id back *updates the message in place*. Without it, ten reports a
--- second would scroll the message area and trip the hit-enter prompt; with it there is one line
--- that ticks. Neovim renders `title` as the prefix and `percent` itself, so the message text
--- carries only the phase.
---
--- Two things are deliberately *not* taken from `$/progress`:
---
---   * Completion, during startup. An `Indexing` end event does not mean the index was flushed;
---     only `intellij/ready-for-test` means that, so `progress.lua` owns the final message of the
---     initial import. *After* that signal the rule flips: the server re-runs a short indexing
---     cycle on every file event it sees -- and it watches the project root's ancestors, so a
---     shell writing `~/.zsh_history` is enough -- reporting `Indexing` begin/end even when zero
---     files changed. `ready-for-test` is sent once per session, so those later rounds have to be
---     closed by their own `end` event, or the line reads "Indexing" forever. See `is_idle`.
---   * The percentage digits. The server bakes them into `message` as well, for clients that only
---     concatenate title and message -- but Neovim draws `percent` itself, so repeating them would
---     read "47% Indexing: 47%". They are stripped from the text and passed as the field instead.
---
--- Nothing here calls `vim.lsp.status()`. That function drains the client's progress ring buffer
--- (`for progress in client.progress do`), so a second consumer would race it; the `LspProgress`
--- autocmd carries the same payload without consuming anything.
---
--- Frames without a percentage carry one to three trailing dots, cycling on a timer, because
--- `Importing: Maven` can sit unchanged for minutes while the build tool works and a static line
--- there reads as a hang. The percentage frames are left alone -- a ticking number already says the
--- same thing, and better. The timer runs only while such a frame is on screen; see `sync_dots`.

local M = {}

--- @class IntellijLspToken
--- @field title   string|nil  server-sent progress title, verbatim
--- @field message string|nil  server-sent message, verbatim
--- @field percent integer|nil 0-100, when the server sent one

--- @class IntellijLspClientStatus
--- @field title   string|nil
--- @field message string|nil
--- @field percent integer|nil
--- @field tokens  table<string|integer, IntellijLspToken>
--- @field rank    integer|nil  highest phase rank reached; startup never moves backwards
--- @field msg_id  integer|nil  the in-place progress message being updated

--- @type table<integer, IntellijLspClientStatus>
local by_client = {}

--- Which progress wins the single message line while several run at once. Indexing outranks
--- importing because it is the phase that reports a percentage, and showing the build tool while a
--- percentage ticks would be a downgrade in information. Titles missing from this table still
--- report, at rank 0 -- an unrecognised server title should be shown, not swallowed.
local RANK = {
  ['Initializing server'] = 1,
  ['Importing'] = 2,
  ['Indexing'] = 3,
}

--- Matches the prefix on progress.lua's `vim.notify`, so the running report and the final
--- notification read as one conversation rather than two sources talking over each other.
local TITLE = 'IntelliJ LSP'

--- The animation: one, two, three dots, then back to one.
---
--- No zero-dot frame. A line that periodically loses its dots looks like it finished and started
--- over, which is the opposite of what the animation is for.
local DOT_FRAMES = 3

--- Slow enough not to pull the eye away from the file being read, fast enough to be legible as
--- motion. Also far slower than the server's report rate, so the animation never competes with a
--- real update for the message line -- a report simply lands on whichever frame is current.
local DOT_INTERVAL_MS = 400

-- ---------------------------------------------------------------------------
-- Pure core. No LSP session, no echoing -- all of this is driven directly by
-- test/units.lua.
-- ---------------------------------------------------------------------------

--- @param n any
--- @return integer|nil
local function clamp_percent(n)
  if type(n) ~= 'number' then return nil end
  return math.max(0, math.min(100, math.floor(n)))
end

--- Recomputes the visible fields from whichever live token currently outranks the others.
---
--- Startup only moves forwards. The `Importing` bar outlives `Indexing` -- the server ends them in
--- either order -- so picking the best *live* token alone would drop the line back to
--- "Importing: Maven" once indexing finished, reading as though the import had restarted. A rank
--- already reached is therefore never given up; the line simply holds the last phase until
--- `ready-for-test` closes it.
--- @param st IntellijLspClientStatus
local function recompute(st)
  local best, best_rank = nil, -1
  for _, tok in pairs(st.tokens) do
    local rank = RANK[tok.title] or 0
    if rank > best_rank then
      best, best_rank = tok, rank
    end
  end

  -- No live token, or only ones for phases already passed: keep showing the furthest phase reached.
  if not best or best_rank < (st.rank or -1) then return end

  st.rank = best_rank
  st.title = best.title
  st.message = best.message
  st.percent = best.percent
end

--- @param client_id integer
--- @return IntellijLspClientStatus
local function state_for(client_id)
  local st = by_client[client_id]
  if not st then
    st = { tokens = {} }
    by_client[client_id] = st
  end
  return st
end

--- Folds one `$/progress` notification into the client's state.
---
--- Neovim back-fills `value.title` from the `begin` payload onto later `report` and `end` payloads
--- (`vim/lsp/handlers.lua`), so every kind arrives self-describing and no token->title bookkeeping
--- is needed here.
--- @param client_id integer
--- @param params table `{ token, value }` from `ev.data.params`
function M.on_progress(client_id, params)
  local value = params and params.value
  if type(value) ~= 'table' then return end

  local token = params.token
  if token == nil then return end

  local st = state_for(client_id)

  if value.kind == 'end' then
    st.tokens[token] = nil
    recompute(st)
    return
  end

  -- `begin` and `report` are handled alike: a report for a token we never saw begin (we loaded
  -- mid-session) is complete enough to adopt, thanks to the back-filled title.
  local tok = st.tokens[token]
  if not tok then
    tok = {}
    st.tokens[token] = tok
  end

  tok.title = value.title or tok.title
  -- Only overwrite when the payload actually carries a field: the server sends bare reports, and
  -- blanking a good message on one of those would make the line flicker.
  if value.message ~= nil then tok.message = value.message end
  local pct = clamp_percent(value.percentage)
  if pct ~= nil then tok.percent = pct end

  recompute(st)
end

--- The message text for a phase, without the percentage.
---
--- The server puts the digits in `message` too ("47%"), but Neovim draws the `percent` field itself,
--- so echoing both reads "47% Indexing: 47%". A message that is *only* the percentage collapses to
--- the bare title; anything else is kept, since "Invalidating files" and "Just a few more
--- moments..." carry information the number does not.
--- @param st IntellijLspClientStatus|nil
--- @return string|nil text, integer|nil percent
function M.describe(st)
  if not st or not st.title then return nil, nil end
  local message = st.message
  if message and message:match('^%s*%d+%s*%%%s*$') then message = nil end
  return message and (st.title .. ': ' .. message) or st.title, st.percent
end

--- Raw state, for tests.
--- @param client_id integer
--- @return IntellijLspClientStatus|nil
function M.get(client_id)
  return by_client[client_id]
end

--- Whether no progress token is live for the client, i.e. every `begin` has seen its `end`.
---
--- Once `ready-for-test` has arrived this is the completion signal for the server's later refresh
--- rounds: there is no second `ready-for-test`, and holding the line open past the `end` -- right
--- for the startup flush -- would leave a stale "Indexing" on screen indefinitely.
--- @param client_id integer
--- @return boolean
function M.is_idle(client_id)
  local st = by_client[client_id]
  return st ~= nil and next(st.tokens) == nil
end

--- The indexing percentage, for callers who want the number rather than the message.
--- @param client_id integer
--- @return integer|nil
function M.percent(client_id)
  local st = by_client[client_id]
  return st and st.percent or nil
end

--- Adds the animation frame to text that has nothing else to show it is alive.
---
--- Kept out of `M.describe` on purpose. `describe` answers "what phase is this" in the server's own
--- words; the dots are this client's own liveness hint. Folding them together would mean every
--- assertion about the phase text had to know what time it was.
---
--- Pure, and exported, so every frame and the no-dots rule are checked by test/units.lua without an
--- LSP session or a running timer -- the timer is the only part of this that a unit test cannot reach.
--- @param text string|nil from `M.describe`
--- @param percent integer|nil from `M.describe`
--- @param frame integer animation frame; any integer, wrapped into 1..DOT_FRAMES
--- @return string|nil text
function M.animate(text, percent, frame)
  if not text then return nil end
  -- A percentage is its own liveness signal, and a better one. Dotting it as well would say the same
  -- thing twice and shift the text sideways every time a digit changes.
  if percent ~= nil then return text end
  -- Lua's `%` is floor-modulo, so this maps 1,2,3,4 -> 1,2,3,1 and stays in range for a counter that
  -- is never reset.
  local dots = ((frame - 1) % DOT_FRAMES) + 1
  return text .. ' ' .. ('.'):rep(dots)
end

-- ---------------------------------------------------------------------------
-- Session-facing half.
-- ---------------------------------------------------------------------------

--- @type uv.uv_timer_t|nil
local dot_timer = nil

--- The animation frame, shared by every client rather than held per client.
---
--- The dots are a clock, not per-client state. Two attached clients animating on independent timers
--- would drift out of phase, and two adjacent lines dotting out of step reads as a glitch; there is
--- nothing to gain from separate clocks. It is never reset either -- restarting at one dot whenever a
--- phase changes (the server rewrites `message` several times a second during import) would stutter
--- instead of spin.
local dot_frame = 1

--- Creates or updates the client's single in-place progress message.
--- @param client_id integer
local function report(client_id)
  local st = by_client[client_id]
  if not st then return end

  local text, percent = M.describe(st)
  if not text then return end
  -- Decorated here, at the echo, and nowhere else: `st` keeps the server's own wording, so nothing
  -- that reads the state ever sees a dot.
  text = M.animate(text, percent, dot_frame)

  -- Reusing `st.msg_id` is what makes this update one line instead of appending another.
  local opts = {
    id = st.msg_id,
    kind = 'progress',
    source = 'intellij-lsp',
    title = TITLE,
    status = 'running',
    percent = percent,
  }
  -- `false` for the history flag: a per-tick entry in `:messages` would bury everything else.
  local ok, id = pcall(vim.api.nvim_echo, { { text } }, false, opts)
  if ok then st.msg_id = id end
end

--- Whether any client currently shows a line the dots apply to.
---
--- This is the on/off condition for the timer. An idle session -- everything `Ready`, or nothing
--- attached -- must hold no repeating handle at all: a 400ms timer left running for the rest of the
--- session is a real cost that nobody asked for and nobody would notice was there.
---
--- The `msg_id` test is what makes it correct rather than merely plausible. A client whose message
--- `finish` has already closed still carries its `title` and `message`, so asking `describe` alone
--- would keep the timer alive forever after `Ready`.
--- @return boolean
local function any_animating()
  for _, st in pairs(by_client) do
    if st.msg_id then
      local text, percent = M.describe(st)
      if text and percent == nil then return true end
    end
  end
  return false
end

--- Releases the handle.
---
--- Two guards, both load-bearing: `uv` throws when `close()` is called on an already-closed handle,
--- and `is_closing()` is true for the window between a close request and the handle going away. This
--- runs from teardown, from reset, and from the tick itself, so it has to be idempotent.
local function stop_dots()
  local t = dot_timer
  if not t then return end
  -- Dropped before the close, not after: the scheduled tick body below bails when it finds no timer,
  -- so this is what stops an already-queued tick from closing the same handle a second time.
  dot_timer = nil
  t:stop()
  if not t:is_closing() then t:close() end
end

--- Starts or stops the animation to match what is on screen.
---
--- Called after every change that can affect eligibility rather than deciding at each of those sites,
--- so there is exactly one place that answers "should the timer exist". Starting is idempotent:
--- `setup_autocmds` is documented as safe to call twice, and without the check the second call would
--- strand the first handle -- a leaked libuv timer that nothing can ever stop again.
local function sync_dots()
  if not any_animating() then
    stop_dots()
    return
  end
  if dot_timer then return end

  dot_timer = vim.uv.new_timer()
  dot_timer:start(DOT_INTERVAL_MS, DOT_INTERVAL_MS, function()
    -- Runs on the libuv thread, where API calls are illegal.
    vim.schedule(function()
      -- The handle can have been stopped and the client can have gone `Ready` between the timer firing
      -- and this callback running, so nothing captured above is trusted here.
      if not dot_timer then return end
      dot_frame = dot_frame + 1
      -- Only the eligible lines are repainted. The frame changing *is* a change, so a repaint is
      -- required -- but repainting a percentage line here would fight the server's own reports for the
      -- message area several times a second to no visible effect.
      for client_id, st in pairs(by_client) do
        if st.msg_id then
          local text, percent = M.describe(st)
          if text and percent == nil then report(client_id) end
        end
      end
      -- A client may have finished during that loop; drop the handle rather than tick on emptily.
      sync_dots()
    end)
  end)
end

--- Closes the client's progress message, if one is open.
---
--- No `percent` is passed. Neovim draws that field itself, so including it would render
--- "IntelliJ LSP: 100% Ready" -- and a percentage on the closing frame is noise: the number tracked
--- indexing, which is over by the time this runs. Omitting the key is the way to drop it; passing
--- `vim.NIL` is rejected as a non-number.
--- No dots on the closing frame either, and that holds structurally rather than by a condition: the
--- text comes from `describe` and never passes through `M.animate`. "Ready ..." would claim work is
--- still running after the index was flushed, so a refactor that routes this through the decoration
--- is a bug -- test/units.lua pins it.
--- @param client_id integer
--- @param final string|nil text for the closing frame; omitted leaves the last text in place
local function finish(client_id, final)
  local st = by_client[client_id]
  if not st or not st.msg_id then return end

  local text = final or select(1, M.describe(st)) or ''
  pcall(vim.api.nvim_echo, { { text } }, false, {
    id = st.msg_id,
    kind = 'progress',
    source = 'intellij-lsp',
    title = TITLE,
    status = 'success',
  })
  st.msg_id = nil
  -- If that was the only animating line the timer now has nothing to repaint, and must not keep
  -- ticking for the rest of the session.
  sync_dots()
end

--- Clears state for a client that has stopped, so a restart starts from a clean slate.
--- @param client_id integer
function M.reset(client_id)
  finish(client_id)
  by_client[client_id] = nil
  -- After the state is dropped, not just after `finish`: that call still saw this client's entry, and
  -- a client dropped without an open message never reaches `finish` at all. This is what actually
  -- releases the handle on a restart.
  sync_dots()
end

--- Removes the subscriptions, for a re-`setup()` that turns reporting off.
function M.teardown_autocmds()
  pcall(vim.api.nvim_del_augroup_by_name, 'IntellijLspStatus')
  -- With the subscriptions gone nothing will ever repaint again, so a surviving handle would tick
  -- into a loop that finds nothing to do. `progress = false` on a re-`setup()` runs exactly this.
  stop_dots()
end

--- Subscribes to the events that drive the report. Safe to call more than once.
function M.setup_autocmds()
  local group = vim.api.nvim_create_augroup('IntellijLspStatus', { clear = true })

  -- Plugin managers re-run specs, so this may well be the second call. The augroup above replaces
  -- itself via `clear = true`, but a libuv handle has no such affordance -- it has to be released
  -- explicitly or it ticks forever with no owner. `sync_dots` brings it back on the next report if
  -- there is still something to animate.
  stop_dots()

  vim.api.nvim_create_autocmd('LspProgress', {
    group = group,
    callback = function(ev)
      local data = ev.data
      if not data or not data.params then return end
      -- `LspProgress` fires for every LSP client in the session; without this check another
      -- server's progress would be reported under the IntelliJ title.
      local c = vim.lsp.get_client_by_id(data.client_id)
      if not c or c.name ~= require('intellij-lsp.client').NAME then return end

      M.on_progress(data.client_id, data.params)

      if require('intellij-lsp.progress').is_ready(data.client_id) and M.is_idle(data.client_id) then
        -- A refresh round after the initial flush has ended. Nothing else will close this line:
        -- `ready-for-test` came and went, so its `end` has to be the closing frame. "Ready" again
        -- rather than the round's last text: what matters is that navigation is complete, and the
        -- text is the same one the startup flush closes with, so the two rounds read alike.
        finish(data.client_id, 'Ready')
      else
        -- During startup, once every token has ended the index is still being flushed, so the line
        -- stays open until `ready-for-test`; closing it here would blank the area during the final
        -- wait. After startup a live token means a real re-index is running, and stays visible.
        report(data.client_id)
      end

      -- This report may have opened the first line the dots apply to, or moved the last one onto a
      -- percentage; either way the answer to "should the timer exist" just changed.
      sync_dots()
    end,
  })

  -- `ready-for-test` is the real completion signal, and it arrives outside the `$/progress` stream.
  -- Closing the progress line here lets progress.lua's notify land as the last word.
  --
  -- "Ready" rather than a phase name: this signal means the index was *flushed*, so navigation
  -- results are complete from here on. That is the fact worth reporting, and it is not the same as
  -- the indexing bar reaching 100%. It also matches `progress.is_ready`, the name this state
  -- already has in the code.
  require('intellij-lsp.progress').on_ready(function(client_id)
    finish(client_id, 'Ready')
  end)
end

return M
