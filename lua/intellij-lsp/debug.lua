--- Breakpoints, stepping, and a locals/watch panel, on top of the session `run.lua` launches.
---
--- Debugging is a `run.lua` launch with `noDebug` flipped to false -- the server always starts the
--- JVM with JDWP `suspend=y`, so a run and a debug session differ only in whether nvim-dap waits on
--- the protocol handshake before letting the program go. Everything here drives that one session
--- through nvim-dap's `Session:request`; no server command is specific to debugging.
---
--- The panel is deliberately small: one scope (the top frame's locals), an expansion tree, watches,
--- and expression evaluation. See README "Debugging" > "Scope" for what is left out and why.

local M = {}

-- -------------------------------------------------------------------------------------------------
-- Breakpoints and stepping
-- -------------------------------------------------------------------------------------------------

--- Toggles a plain breakpoint on the current line.
function M.toggle_breakpoint()
  if not (pcall(require, 'dap')) then
    vim.notify('IntelliJ LSP: debugging requires nvim-dap (mfussenegger/nvim-dap).', vim.log.levels.ERROR)
    return
  end
  require('dap').toggle_breakpoint()
end

--- Sets a breakpoint with a condition, prompted for.
function M.toggle_conditional_breakpoint()
  if not (pcall(require, 'dap')) then
    vim.notify('IntelliJ LSP: debugging requires nvim-dap (mfussenegger/nvim-dap).', vim.log.levels.ERROR)
    return
  end
  local condition = vim.fn.input('Breakpoint condition: ')
  if condition == '' then return end
  require('dap').set_breakpoint(condition)
end

--- The session to step or continue, or nil with a message already shown.
---
--- `dap.continue()` is not safe to call unconditionally: with no session it prompts from
--- `dap.configurations`, which this plugin leaves empty on purpose, and with a session that is not
--- suspended it opens an eight-item picker offering "Terminate session" -- surprising for a keymap
--- named "continue", and fatal for a headless test. Both directions are checked here, once, so every
--- caller below gets the same guard for free.
--- @return dap.Session|nil
local function suspended_session()
  local ok, dap = pcall(require, 'dap')
  if not ok then
    vim.notify('IntelliJ LSP: debugging requires nvim-dap (mfussenegger/nvim-dap).', vim.log.levels.ERROR)
    return nil
  end
  local session = dap.session()
  if not session then
    vim.notify('IntelliJ LSP: no debug session. Start one with <leader>rd.', vim.log.levels.WARN)
    return nil
  end
  if not session.stopped_thread_id then
    vim.notify('IntelliJ LSP: the program is running, not suspended.', vim.log.levels.WARN)
    return nil
  end
  return session
end

function M.continue()
  if suspended_session() then require('dap').continue() end
end

function M.step_over()
  if suspended_session() then require('dap').step_over() end
end

function M.step_into()
  if suspended_session() then require('dap').step_into() end
end

function M.step_out()
  if suspended_session() then require('dap').step_out() end
end

--- Stops the session. Delegates to run.lua rather than nvim-dap directly, so `<leader>dq` and
--- `:IntellijLspRunStop` are one code path.
function M.stop()
  require('intellij-lsp.run').stop()
end

-- -------------------------------------------------------------------------------------------------
-- Cursor-expression extraction (for <leader>de / <leader>dw)
-- -------------------------------------------------------------------------------------------------

--- The expression under the cursor, stopping at the call the cursor points at.
---
--- Walks a dotted/call chain (`a.b().c[0].d()`) and truncates it right after the segment whose name
--- span contains the cursor column: pointing at `getLastName` in `owner.getLastName().toUpperCase()`
--- evaluates `owner.getLastName()`, pointing at `toUpperCase` evaluates the whole chain. A bare
--- identifier under the cursor, with no chain at all, evaluates itself.
--- @param line string the source line
--- @param col integer 0-based cursor column (byte index)
--- @return string|nil
function M._expression_at_cursor(line, col)
  -- One token: an identifier, then any run of `.identifier`, `(...)` or `[...]` segments. Matched
  -- greedily and then trimmed back, rather than parsed piecewise, because Lua patterns cannot count
  -- nested parens -- `(` and `)` below are matched by balance, not by the regex.
  local start = nil
  for i = col + 1, 1, -1 do
    local c = line:sub(i, i)
    if c:match('[%w_%.%(%)%[%]]') then
      start = i
    else
      break
    end
  end
  if not start then return nil end

  -- Extends the match rightward from `start` past the cursor, so a click on the first half of a
  -- longer chain still sees the segments after it -- needed to find where each call's `)` lands.
  local stop = start
  local n = #line
  while stop <= n and line:sub(stop, stop):match('[%w_%.%(%)%[%]]') do
    stop = stop + 1
  end
  local chain = line:sub(start, stop - 1)
  if chain == '' then return nil end

  -- Splits the chain into segments: a leading identifier, then `.name`, `(...)` or `[...]` pieces,
  -- balancing brackets by hand since Lua patterns have no recursion.
  local segments = {}
  local i = 1
  local m = chain:match('^[%w_]+', i)
  if not m then return nil end
  table.insert(segments, { text = m, from = i, to = i + #m - 1 })
  i = i + #m

  while i <= #chain do
    local c = chain:sub(i, i)
    if c == '.' then
      local name = chain:match('^%.([%w_]+)', i)
      if not name then break end
      table.insert(segments, { text = '.' .. name, from = i, to = i + #name })
      i = i + #name + 1
    elseif c == '(' or c == '[' then
      local close = c == '(' and ')' or ']'
      local depth = 1
      local j = i + 1
      while j <= #chain and depth > 0 do
        if chain:sub(j, j) == c then
          depth = depth + 1
        elseif chain:sub(j, j) == close then
          depth = depth - 1
        end
        j = j + 1
      end
      if depth ~= 0 then break end
      -- Attached to the previous segment: `getLastName` and its `()` truncate together.
      local last = segments[#segments]
      last.text = last.text .. chain:sub(i, j - 1)
      last.to = j - 1
      i = j
    else
      break
    end
  end

  -- The cursor's column within `chain`, then the last segment whose span reaches at or past it.
  local cursor_in_chain = col - (start - 1) + 1
  local cut = #chain
  for _, seg in ipairs(segments) do
    if cursor_in_chain <= seg.to then
      cut = seg.to
      break
    end
  end

  return chain:sub(1, cut)
end

--- The expression to evaluate: a visual selection if one is active, else the chain under the cursor.
--- @return string|nil
local function expression_for_evaluate()
  local mode = vim.fn.mode()
  if mode == 'v' or mode == 'V' then
    vim.cmd('normal! ' .. vim.api.nvim_replace_termcodes('<Esc>', true, false, true))
    local s = vim.fn.getpos("'<")
    local e = vim.fn.getpos("'>")
    if s[2] ~= e[2] then
      -- Multi-line visual selections are not a valid single expression; take the first line's span.
      return vim.api.nvim_buf_get_lines(0, s[2] - 1, s[2], false)[1]:sub(s[3])
    end
    local line = vim.api.nvim_buf_get_lines(0, s[2] - 1, s[2], false)[1] or ''
    return line:sub(s[3], e[3])
  end

  local line = vim.api.nvim_get_current_line()
  local col = vim.api.nvim_win_get_cursor(0)[2]
  return M._expression_at_cursor(line, col)
end

-- -------------------------------------------------------------------------------------------------
-- Panel state
-- -------------------------------------------------------------------------------------------------

--- One generation per `stopped` event. Every async callback that touches the panel (variables,
--- evaluate, watch) is issued with the generation current when it was sent, and discards its result
--- if the generation has since moved on.
---
--- Not session-identity: `continued` clears `panel.frame` to nil, so a staleness check that compared
--- against the (now nil) frame could never tell a step's late response from a fresh one. This bit
--- The first version of this file compared session identity instead, per README "Stepping must not
--- lose the locals" -- caught by running the feature, not by reading it.
--- @type integer
local generation = 0

--- @class DebugPanelState
--- @field session dap.Session|nil the session the panel is showing
--- @field frame dap.StackFrame|nil the frame locals/watches are evaluated against; nil while running
--- @field expanded table<string, boolean> name path -> open/closed
--- @field watches string[] expressions, in display order
--- @field root_buf integer|nil the left-hand call-stack + locals + watches buffer
--- @field root_win integer|nil
--- @field rows table[] one entry per rendered line: {kind, ...}
--- @field augroup integer|nil
--- @type DebugPanelState|nil
local panel = nil

--- Creates the panel state on first use. Idempotent, and called from both `M.open()` and
--- `on_stopped` so a breakpoint hit before anyone has called `M.open()` still has a `panel` to write
--- into, rather than silently dropping the stop.
local function ensure_panel()
  if panel then return end
  panel = {
    session = nil,
    frame = nil,
    frames = nil,
    locals = nil,
    expanded = {},
    children_by_path = {},
    watches = {},
    watch_results = {},
    root_buf = nil,
    root_win = nil,
    rows = {},
    augroup = nil,
  }
end

--- Render placeholder for a value not yet fetched from the adapter.
local PENDING = 'Collecting data…'

--- The server silently caps children at 100 with no signal that the list was cut, so a list that
--- lands on exactly that count is hedged rather than trusted. See README "Scope".
local MAX_CHILDREN = 100
local TRUNCATION_NOTE = '(100 shown; the list may be truncated)'

--- Cap on tree depth. Object graphs the debuggee reaches can be cyclic (`this.parent.children[0] ==
--- this`), and expansion state keyed by name path has no other way to bound such a graph.
local MAX_DEPTH = 32

--- Sentinel `result` text the server returns as a *successful* `evaluate` response when there is no
--- usable frame to evaluate against. Recognized by exact text and re-labeled as an error; there is
--- no error code to check instead.
local EVAL_ERROR_SENTINELS = {
  ['Evaluation is supported for stack frames only'] = true,
  ['No active suspend context'] = true,
}

-- -------------------------------------------------------------------------------------------------
-- Highlighting
-- -------------------------------------------------------------------------------------------------

--- nvim-dap already places its own `DapStopped` sign (linehl = 'debugPC') on the real execution
--- line; theme/groups.lua colours that group to match IntelliJ. nvim-dap has no separate highlight
--- for "a non-top frame previewed from the call stack", so that half is this module's own concern:
--- one extmark, moved to the previewed source line and cleared once nothing but the top frame is
--- shown.
local frame_preview_ns = vim.api.nvim_create_namespace('intellij-lsp.debug.frame_preview')
local frame_preview_buf = nil

--- Highlights the panel row for the frame currently shown as `panel.frame`.
local panel_row_ns = vim.api.nvim_create_namespace('intellij-lsp.debug.panel_row')

--- Highlights for the rendered rows themselves: the marker, name, value and type of a variable
--- row, and the section headers. The panel is built on plain buffer text (README "Scope" -- there
--- is no real tree widget), so without these every row is one undifferentiated colour and a
--- watch's name is not visually distinct from its value.
---
--- Defined here rather than in theme/groups.lua, and for the same reason as
--- IntellijLspReferenceMatch in references.lua: the panel must be legible for a user who never
--- opted into the bundled colorscheme, so these link to groups every Neovim colorscheme defines,
--- with `default = true` so a user override or a `:colorscheme` switch always wins.
---
--- Link targets follow the IntelliJ debugger tree's own colouring: the value name uses a reddish
--- accent distinct from plain text -- `Identifier` is the wrong analogue since IntelliJ
--- deliberately colours this, so this links to `Special` instead; the type suffix is a dimmed
--- grey, matched by `Comment`; and the "Collecting data…" placeholder uses the same dimmed grey
--- the real tree shows while a value is still being fetched.
local function define_highlights()
  vim.api.nvim_set_hl(0, 'IntellijLspDebugHeader', { link = 'Title', default = true })
  vim.api.nvim_set_hl(0, 'IntellijLspDebugMarker', { link = 'Comment', default = true })
  vim.api.nvim_set_hl(0, 'IntellijLspDebugName', { link = 'Special', default = true })
  vim.api.nvim_set_hl(0, 'IntellijLspDebugType', { link = 'Comment', default = true })
  vim.api.nvim_set_hl(0, 'IntellijLspDebugPending', { link = 'Comment', default = true })
  vim.api.nvim_set_hl(0, 'IntellijLspDebugError', { link = 'ErrorMsg', default = true })
end

define_highlights()

-- `hi clear` drops `default` links, so without this the groups vanish on the next :colorscheme.
vim.api.nvim_create_autocmd('ColorScheme', {
  group = vim.api.nvim_create_augroup('IntellijLspDebugHl', { clear = true }),
  callback = define_highlights,
  desc = 'Re-assert IntelliJ LSP debug panel highlight groups',
})

--- Clears the non-top-frame preview line highlight, if one is set.
local function clear_frame_preview()
  if frame_preview_buf and vim.api.nvim_buf_is_valid(frame_preview_buf) then
    vim.api.nvim_buf_clear_namespace(frame_preview_buf, frame_preview_ns, 0, -1)
  end
  frame_preview_buf = nil
end

--- Marks `line` (1-based) in `bufnr` as a previewed, non-top stack frame.
local function set_frame_preview(bufnr, line)
  clear_frame_preview()
  frame_preview_buf = bufnr
  vim.api.nvim_buf_set_extmark(bufnr, frame_preview_ns, line - 1, 0, {
    line_hl_group = 'DapStoppedFrame',
    priority = 22,
  })
end

-- -------------------------------------------------------------------------------------------------
-- Panel: buffer, window, rendering
-- -------------------------------------------------------------------------------------------------

local function ensure_root_buf()
  if panel.root_buf and vim.api.nvim_buf_is_valid(panel.root_buf) then return panel.root_buf end
  panel.root_buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(panel.root_buf, 'intellij-lsp://debug')
  vim.bo[panel.root_buf].buftype = 'nofile'
  vim.bo[panel.root_buf].swapfile = false
  return panel.root_buf
end

local function ensure_root_win()
  local buf = ensure_root_buf()
  if panel.root_win and vim.api.nvim_win_is_valid(panel.root_win) then
    vim.api.nvim_win_set_buf(panel.root_win, buf)
    return panel.root_win
  end
  vim.cmd('topleft 50vnew')
  panel.root_win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(panel.root_win, buf)
  vim.wo[panel.root_win].number = false
  vim.wo[panel.root_win].relativenumber = false
  vim.wo[panel.root_win].signcolumn = 'no'
  vim.wo[panel.root_win].wrap = false
  return panel.root_win
end

--- The byte range of the `format_value` type suffix inside a rendered `value_text`, i.e. the
--- trailing `  (Type)` that `format_value` appends -- or nil when the value carries no type (an
--- `evaluate` response with no `type` field). Recovered from the formatted string rather than
--- threaded through as a separate field, since every caller already has `value_text` as one string.
--- @param value_text string
--- @return integer|nil start 0-based
local function type_suffix_start(value_text)
  local start = value_text:find('  %([^()]*%)$')
  return start and start - 1 or nil
end

--- Renders one variable (or scope-root) row and its already-expanded descendants.
--- @param lines string[] accumulator
--- @param rows table[] accumulator, index-aligned with `lines`
--- @param hls table[] accumulator of { row (0-based), col, end_col, hl }
--- @param name string display name, e.g. "owner" or "[0]"
--- @param name_path string full path used as the expansion key, e.g. "locals.owner.children[0]"
--- @param value_text string
--- @param variables_reference integer
--- @param depth integer
local function render_variable(lines, rows, hls, name, name_path, value_text, variables_reference, depth)
  local indent = string.rep('  ', depth)
  local has_children = variables_reference and variables_reference ~= 0
  local marker = ''
  if has_children then
    marker = panel.expanded[name_path] and '▾ ' or '▸ '
  end
  local prefix = indent .. marker
  table.insert(lines, ('%s%s = %s'):format(prefix, name, value_text))
  local row = #lines - 1
  table.insert(rows, {
    kind = 'variable',
    name_path = name_path,
    variables_reference = variables_reference,
    depth = depth,
  })

  if marker ~= '' then
    hls[#hls + 1] = { row = row, col = #indent, end_col = #prefix, hl = 'IntellijLspDebugMarker' }
  end
  local name_col = #prefix
  hls[#hls + 1] = { row = row, col = name_col, end_col = name_col + #name, hl = 'IntellijLspDebugName' }
  local value_col = name_col + #name + 3 -- past "name = "
  local type_at = type_suffix_start(value_text)
  if type_at then
    hls[#hls + 1] = { row = row, col = value_col + type_at, end_col = value_col + #value_text, hl = 'IntellijLspDebugType' }
  end

  if has_children and panel.expanded[name_path] and depth < MAX_DEPTH then
    local children = panel.children_by_path[name_path]
    if children == nil then
      -- Not fetched yet; request now, render will re-run once the response lands.
      M._fetch_children(name_path, variables_reference)
      table.insert(lines, indent .. '  ' .. PENDING)
      table.insert(rows, { kind = 'pending' })
      hls[#hls + 1] = { row = #lines - 1, col = #indent + 2, end_col = #indent + 2 + #PENDING, hl = 'IntellijLspDebugPending' }
    else
      for idx, child in ipairs(children) do
        if idx > MAX_CHILDREN then break end
        local child_path = name_path .. '.' .. child.name
        render_variable(lines, rows, hls, child.name, child_path, child.value_text, child.variables_reference, depth + 1)
      end
      if #children >= MAX_CHILDREN then
        table.insert(lines, indent .. '  ' .. TRUNCATION_NOTE)
        table.insert(rows, { kind = 'note' })
        hls[#hls + 1] = { row = #lines - 1, col = #indent + 2, end_col = #indent + 2 + #TRUNCATION_NOTE, hl = 'IntellijLspDebugPending' }
      end
    end
  end
end

--- Rebuilds the whole panel buffer from `panel` state.
---
--- Always goes through this one path, in every state (suspended, running, no session) -- README
--- "A resume must not blank the watch list" is a consequence of `clear()` writing a *different*,
--- fixed rendering instead of re-rendering watches through here with pending placeholders.
function M._render()
  if not panel then return end
  local buf = ensure_root_buf()
  local lines, rows, hls = {}, {}, {}

  local function header(text)
    table.insert(lines, text)
    table.insert(rows, { kind = 'header' })
    hls[#hls + 1] = { row = #lines - 1, col = 0, end_col = #text, hl = 'IntellijLspDebugHeader' }
  end

  header('Call stack')
  local current_frame_line = nil
  if panel.frame then
    for _, frame in ipairs(panel.frames or { panel.frame }) do
      local is_current = frame.id == panel.frame.id
      local marker = is_current and '▸ ' or '  '
      table.insert(lines, marker .. (frame.name or '?') .. (frame.line and (':' .. frame.line) or ''))
      table.insert(rows, { kind = 'frame', frame = frame })
      if is_current then current_frame_line = #lines end
    end
  else
    table.insert(lines, '  (running)')
    table.insert(rows, { kind = 'note' })
  end

  table.insert(lines, '')
  table.insert(rows, { kind = 'blank' })
  header('Locals')
  if panel.frame and panel.locals then
    if #panel.locals == 0 then
      table.insert(lines, '  (no locals)')
      table.insert(rows, { kind = 'note' })
    end
    for _, v in ipairs(panel.locals) do
      render_variable(lines, rows, hls, v.name, 'locals.' .. v.name, v.value_text, v.variables_reference, 1)
    end
  else
    table.insert(lines, '  ' .. PENDING)
    table.insert(rows, { kind = 'pending' })
    hls[#hls + 1] = { row = #lines - 1, col = 2, end_col = 2 + #PENDING, hl = 'IntellijLspDebugPending' }
  end

  table.insert(lines, '')
  table.insert(rows, { kind = 'blank' })
  header('Watches')
  if #panel.watches == 0 then
    table.insert(lines, '  (none -- press w to add one)')
    table.insert(rows, { kind = 'note' })
  end
  for _, expr in ipairs(panel.watches) do
    local w = panel.watch_results[expr]
    local name_path = 'watch.' .. expr
    if not w then
      local text = panel.frame and PENDING or '(paused)'
      table.insert(lines, ('  %s = %s'):format(expr, text))
      table.insert(rows, { kind = 'watch', expr = expr })
      local row = #lines - 1
      hls[#hls + 1] = { row = row, col = 2, end_col = 2 + #expr, hl = 'IntellijLspDebugName' }
      if panel.frame then
        local at = 2 + #expr + 3
        hls[#hls + 1] = { row = row, col = at, end_col = at + #text, hl = 'IntellijLspDebugPending' }
      end
    elseif w.error then
      table.insert(lines, ('  %s = <error: %s>'):format(expr, w.error))
      table.insert(rows, { kind = 'watch', expr = expr })
      local row = #lines - 1
      hls[#hls + 1] = { row = row, col = 2, end_col = 2 + #expr, hl = 'IntellijLspDebugName' }
      local at = 2 + #expr + 3
      hls[#hls + 1] = { row = row, col = at, end_col = #lines[#lines], hl = 'IntellijLspDebugError' }
    else
      render_variable(lines, rows, hls, expr, name_path, w.value_text, w.variables_reference, 1)
      -- render_variable already inserted the row; retag it so `dd` finds the owning watch.
      rows[#rows].kind = 'watch'
      rows[#rows].expr = expr
    end
  end

  panel.rows = rows
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false

  vim.api.nvim_buf_clear_namespace(buf, panel_row_ns, 0, -1)
  for _, h in ipairs(hls) do
    pcall(vim.api.nvim_buf_set_extmark, buf, panel_row_ns, h.row, h.col, {
      end_row = h.row,
      end_col = h.end_col,
      hl_group = h.hl,
    })
  end
  if current_frame_line then
    vim.api.nvim_buf_set_extmark(buf, panel_row_ns, current_frame_line - 1, 0, {
      line_hl_group = 'IntellijLspDebugCurrentFrame',
    })
  end
end

-- -------------------------------------------------------------------------------------------------
-- Fetching
-- -------------------------------------------------------------------------------------------------

--- Formats a DAP `Variable` for display. Kept to one line; multi-line values (a `toString()` with
--- embedded newlines) are flattened so one row is always one line.
--- @param variable table DAP Variable
--- @return string
local function format_value(variable)
  local v = variable.value or ''
  v = v:gsub('\n', ' ')
  if variable.type and variable.type ~= '' then
    return v .. '  (' .. variable.type .. ')'
  end
  return v
end

--- Requests a `variablesReference`'s children and stores them under `name_path`.
--- @param name_path string
--- @param variables_reference integer
function M._fetch_children(name_path, variables_reference)
  local session = panel and panel.session
  if not session then return end
  local gen = generation
  session:request('variables', { variablesReference = variables_reference }, function(err, resp)
    if not panel or gen ~= generation then return end
    if err or not resp then
      panel.children_by_path[name_path] = {}
    else
      local children = {}
      for _, v in ipairs(resp.variables or {}) do
        table.insert(children, {
          name = v.name,
          value_text = format_value(v),
          variables_reference = v.variablesReference,
        })
      end
      panel.children_by_path[name_path] = children
    end
    M._render()
  end)
end

--- Requests the top frame's locals (the one non-expensive scope) and re-renders.
local function fetch_locals()
  local session, frame = panel.session, panel.frame
  if not session or not frame then return end
  local gen = generation
  session:request('scopes', { frameId = frame.id }, function(err, resp)
    if not panel or gen ~= generation then return end
    if err or not resp or not resp.scopes or not resp.scopes[1] then
      panel.locals = {}
      M._render()
      return
    end
    -- Locals is always the first, cheap scope for the JVM adapter; this plugin does not offer scope
    -- selection (README "Scope").
    local scope = resp.scopes[1]
    session:request('variables', { variablesReference = scope.variablesReference }, function(err2, vresp)
      if not panel or gen ~= generation then return end
      if err2 or not vresp then
        panel.locals = {}
      else
        local locals = {}
        for _, v in ipairs(vresp.variables or {}) do
          table.insert(locals, {
            name = v.name,
            value_text = format_value(v),
            variables_reference = v.variablesReference,
          })
        end
        panel.locals = locals
      end
      M._render()
    end)
  end)
end

--- Re-evaluates every watch against the current frame.
local function fetch_watches()
  local session, frame = panel.session, panel.frame
  if not session or not frame or #panel.watches == 0 then
    M._render()
    return
  end
  local gen = generation
  for _, expr in ipairs(panel.watches) do
    session:request('evaluate', { expression = expr, frameId = frame.id, context = 'watch' }, function(err, resp)
      if not panel or gen ~= generation then return end
      if err then
        panel.watch_results[expr] = { error = tostring(err.message or err) }
      elseif resp and EVAL_ERROR_SENTINELS[resp.result] then
        panel.watch_results[expr] = { error = resp.result }
      elseif resp then
        panel.watch_results[expr] = {
          value_text = format_value({ value = resp.result, type = resp.type }),
          variables_reference = resp.variablesReference,
        }
      end
      M._render()
    end)
  end
end

-- -------------------------------------------------------------------------------------------------
-- Session lifecycle
-- -------------------------------------------------------------------------------------------------

--- Clears per-stop data without touching the things that must survive: expansion state (the user's
--- own view of the tree, not the program's) and watch expressions (only their values go stale).
--- Re-renders through the normal path rather than a separate "cleared" view -- see README "A resume
--- must not blank the watch list".
local function on_continued()
  generation = generation + 1
  clear_frame_preview()
  if not panel then return end
  panel.frame, panel.frames, panel.locals = nil, nil, nil
  panel.children_by_path = {}
  for expr in pairs(panel.watch_results) do
    panel.watch_results[expr] = nil
  end
  M._render()
end

--- Requests the stopped thread's own stack trace and only then fetches locals/watches.
---
--- `dap.listeners.after.event_stopped` fires the moment the `stopped` message is scheduled, which is
--- before nvim-dap's own internal `stackTrace` round trip (started inside `Session:event_stopped`'s
--- coroutine) has come back -- so `session.current_frame` is reliably still nil or stale at this
--- point. Requesting the stack trace here, on this module's own timeline, is what makes `panel.frame`
--- dependable instead of racing nvim-dap for it.
--- @param session dap.Session
--- @param thread_id integer
local function fetch_stopped_frame(session, thread_id)
  local gen = generation
  session:request('stackTrace', { threadId = thread_id, startFrame = 0 }, function(err, resp)
    if not panel or gen ~= generation then return end
    local frames = resp and resp.stackFrames or {}
    panel.frame = frames[1]
    panel.frames = frames
    if err or not panel.frame then
      -- Nothing to show; render as "(running)" rather than leaving a stale pending placeholder.
      M._render()
      return
    end
    M._render()
    fetch_locals()
    fetch_watches()
  end)
end

--- @param session dap.Session
--- @param body dap.StoppedEvent the just-received event, read for `threadId` directly
local function on_stopped(session, body)
  generation = generation + 1
  ensure_panel()
  panel.session = session
  panel.frame = nil
  panel.frames = nil
  panel.children_by_path = {}
  M._render()
  -- Not `session.stopped_thread_id`: nvim-dap's own `event_stopped` handler only assigns that
  -- field from inside the async coroutine it launches, which has not run yet when this listener
  -- fires -- reading it here raced the field to `nil` on every stop, and the panel never got past
  -- "(running)"/"Collecting data...". The event body carries the same id immediately.
  local thread_id = body and body.threadId or session.stopped_thread_id
  if thread_id then
    fetch_stopped_frame(session, thread_id)
  end
  vim.schedule(function()
    -- Not just `== nil`: a panel closed with `q`/`<Esc>` leaves `root_win` set to the now-invalid
    -- window handle, and without this check a stop after that close would never reopen it.
    if panel and not (panel.root_win and vim.api.nvim_win_is_valid(panel.root_win)) then M.open() end
  end)
end

local function on_invalidated()
  -- The one case the server sends this for: a value served as a placeholder (`Collecting data…`)
  -- settled asynchronously. Discard cached children and re-fetch everything visible.
  if not panel or not panel.frame then return end
  panel.children_by_path = {}
  fetch_locals()
  fetch_watches()
end

--- Registers the dap listeners once. Idempotent for the same reason `run.lua`'s adapter
--- registration is: a plugin manager that re-runs specs must not accumulate duplicate handlers.
---
--- A no-op, not an error, when nvim-dap is absent: `run.lua` already reports that degraded path to
--- the user at the moment it matters (a run or debug attempt), and `setup()` must not fail the whole
--- plugin over an optional dependency it does not yet need.
local listeners_registered = false
local function ensure_listeners()
  if listeners_registered then return end
  local ok, dap = pcall(require, 'dap')
  if not ok then return end
  listeners_registered = true
  dap.listeners.after.event_stopped['intellij-lsp.debug'] = on_stopped
  dap.listeners.after.event_continued['intellij-lsp.debug'] = on_continued
  dap.listeners.after.event_terminated['intellij-lsp.debug'] = on_continued
  dap.listeners.after.event_invalidated['intellij-lsp.debug'] = on_invalidated
end

-- -------------------------------------------------------------------------------------------------
-- Panel keymaps and lifecycle
-- -------------------------------------------------------------------------------------------------

--- Row and depth-of-toggle-target under the cursor.
--- @return table|nil row
local function current_row()
  if not panel or not panel.root_win or not vim.api.nvim_win_is_valid(panel.root_win) then return nil end
  local lnum = vim.api.nvim_win_get_cursor(panel.root_win)[1]
  return panel.rows[lnum]
end

local function toggle_row()
  local row = current_row()
  if not row then return end
  if row.kind == 'frame' then
    panel.frame = row.frame
    panel.children_by_path = {}
    generation = generation + 1
    M._render()
    fetch_locals()
    fetch_watches()
    return
  end
  if row.kind == 'variable' or row.kind == 'watch' then
    local path = row.name_path
    if not path or not row.variables_reference or row.variables_reference == 0 then return end
    panel.expanded[path] = not panel.expanded[path]
    M._render()
  end
end

local function jump_to_frame_row()
  local row = current_row()
  if not row or row.kind ~= 'frame' or not row.frame or not row.frame.source then return end
  local frame = row.frame
  local path = frame.source.path
  if not path then return end
  local win = vim.fn.win_getid(vim.fn.winnr('#'))
  if win == 0 then
    vim.cmd('wincmd p')
    win = vim.api.nvim_get_current_win()
  end
  local top_frame = panel.frames and panel.frames[1]
  local is_top_frame = top_frame ~= nil and frame.id == top_frame.id
  vim.api.nvim_win_call(win, function()
    vim.cmd('keepjumps edit ' .. vim.fn.fnameescape(path))
    vim.api.nvim_win_set_cursor(win, { frame.line or 1, math.max((frame.column or 1) - 1, 0) })
    vim.cmd('normal! zz')
    -- The real execution point already gets nvim-dap's own DapStopped/debugPC highlight; only a
    -- non-top frame previewed here needs this module's own line highlight.
    if is_top_frame then
      clear_frame_preview()
    else
      set_frame_preview(vim.api.nvim_get_current_buf(), frame.line or 1)
    end
  end)
end

local function prompt_evaluate()
  local session = panel and panel.session
  local frame = panel and panel.frame
  if not session then return end
  local expr = vim.fn.input('Evaluate: ')
  if expr == '' then return end
  if not frame then
    vim.notify('IntelliJ LSP: the program is running, not suspended.', vim.log.levels.WARN)
    return
  end
  session:request('evaluate', { expression = expr, frameId = frame.id, context = 'repl' }, function(err, resp)
    if err then
      vim.notify('IntelliJ LSP: ' .. tostring(err.message or err), vim.log.levels.ERROR)
    elseif resp and EVAL_ERROR_SENTINELS[resp.result] then
      vim.notify('IntelliJ LSP: ' .. resp.result, vim.log.levels.ERROR)
    elseif resp then
      vim.notify(expr .. ' = ' .. format_value({ value = resp.result, type = resp.type }), vim.log.levels.INFO)
    end
  end)
end

local function prompt_watch()
  if not panel then return end
  local expr = vim.fn.input('Watch: ')
  if expr == '' then return end
  table.insert(panel.watches, expr)
  M._render()
  fetch_watches()
end

local function remove_watch_under_cursor()
  local row = current_row()
  if not row or row.kind ~= 'watch' or not row.expr then return end
  for i, expr in ipairs(panel.watches) do
    if expr == row.expr then
      table.remove(panel.watches, i)
      panel.watch_results[row.expr] = nil
      break
    end
  end
  M._render()
end

--- Evaluates the expression under the cursor in the *source* window (not the panel), per README
--- `<leader>de`. Delegates to the same evaluate path the panel's `e` uses.
function M.evaluate_at_cursor()
  local session = panel and panel.session
  if not session then
    vim.notify('IntelliJ LSP: no debug session.', vim.log.levels.WARN)
    return
  end
  local expr = expression_for_evaluate()
  if not expr then
    vim.notify('IntelliJ LSP: no expression under the cursor.', vim.log.levels.WARN)
    return
  end
  local frame = panel.frame
  if not frame then
    vim.notify('IntelliJ LSP: the program is running, not suspended.', vim.log.levels.WARN)
    return
  end
  session:request('evaluate', { expression = expr, frameId = frame.id, context = 'repl' }, function(err, resp)
    if err then
      vim.notify('IntelliJ LSP: ' .. tostring(err.message or err), vim.log.levels.ERROR)
    elseif resp and EVAL_ERROR_SENTINELS[resp.result] then
      vim.notify('IntelliJ LSP: ' .. resp.result, vim.log.levels.ERROR)
    elseif resp then
      vim.notify(expr .. ' = ' .. format_value({ value = resp.result, type = resp.type }), vim.log.levels.INFO)
    end
  end)
end

--- Watches the expression under the cursor, per README `<leader>dw`.
function M.watch_at_cursor()
  if not panel then
    vim.notify('IntelliJ LSP: no debug session.', vim.log.levels.WARN)
    return
  end
  local expr = expression_for_evaluate()
  if not expr then
    vim.notify('IntelliJ LSP: no expression under the cursor.', vim.log.levels.WARN)
    return
  end
  table.insert(panel.watches, expr)
  M._render()
  fetch_watches()
end

--- Opens (or reuses) the debug panel.
function M.open()
  ensure_panel()
  local ok, dap = pcall(require, 'dap')
  if ok then panel.session = dap.session() end

  local win = ensure_root_win()
  local buf = panel.root_buf

  if not panel.augroup then
    panel.augroup = vim.api.nvim_create_augroup('IntellijLspDebugPanel', { clear = true })
    local function map(lhs, rhs, desc)
      vim.keymap.set('n', lhs, rhs, { buffer = buf, nowait = true, desc = desc })
    end
    map('<CR>', function()
      local row = current_row()
      if row and row.kind == 'frame' then
        toggle_row()
        jump_to_frame_row()
      else
        toggle_row()
      end
    end, 'IntelliJ: jump to frame, or expand/collapse a variable')
    map('<Tab>', toggle_row, 'IntelliJ: expand/collapse')
    map('zo', toggle_row, 'IntelliJ: expand')
    map('zc', toggle_row, 'IntelliJ: collapse')
    map('za', toggle_row, 'IntelliJ: expand/collapse')
    map('c', M.continue, 'IntelliJ: continue')
    map('n', M.step_over, 'IntelliJ: step over')
    map('i', M.step_into, 'IntelliJ: step into')
    map('o', M.step_out, 'IntelliJ: step out')
    map('e', prompt_evaluate, 'IntelliJ: evaluate an expression')
    map('w', prompt_watch, 'IntelliJ: add a watch')
    map('dd', remove_watch_under_cursor, 'IntelliJ: remove the watch under the cursor')
    map('q', '<cmd>close<CR>', 'IntelliJ: close the debug panel')
    map('<Esc>', '<cmd>close<CR>', 'IntelliJ: close the debug panel')

    -- Preview-follows-cursor for frames, matching references.lua and the git log panel: moving off a
    -- frame row shows its source without jumping, so <C-o> is never spent on a row you only glanced at.
    vim.api.nvim_create_autocmd('CursorMoved', {
      group = panel.augroup,
      buffer = buf,
      callback = function()
        local row = current_row()
        if row and row.kind == 'frame' then jump_to_frame_row() end
      end,
      desc = 'IntelliJ: preview the selected frame',
    })
  end

  ensure_listeners()
  M._render()
  return win
end

--- @param bufnr integer
function M.set_keymaps(bufnr)
  local function map(lhs, rhs, desc)
    vim.keymap.set('n', lhs, rhs, { buffer = bufnr, desc = desc })
  end

  map('<leader>b', M.toggle_breakpoint, 'IntelliJ: toggle a breakpoint')
  map('<leader>B', M.toggle_conditional_breakpoint, 'IntelliJ: breakpoint with a condition')
  map('<leader>rd', function() require('intellij-lsp.run').run_at_cursor(false) end, 'IntelliJ: debug the class at the cursor')
  map('<leader>dc', M.continue, 'IntelliJ: continue')
  map('<leader>dn', M.step_over, 'IntelliJ: step over')
  map('<leader>di', M.step_into, 'IntelliJ: step into')
  map('<leader>do', M.step_out, 'IntelliJ: step out')
  map('<leader>dq', M.stop, 'IntelliJ: stop the debug session')
  map('<leader>de', M.evaluate_at_cursor, 'IntelliJ: evaluate the expression at the cursor')
  map('<leader>dw', M.watch_at_cursor, 'IntelliJ: watch the expression at the cursor')
  map('<leader>dv', M.open, 'IntelliJ: open the debug panel (call stack, locals, watches)')
end

--- Recolors nvim-dap's breakpoint signs to IntelliJ's breakpoint-line colour.
---
--- `sign_define` always overwrites, so this does not depend on running before nvim-dap's own
--- `plugin/dap.lua` -- unlike `DapStopped` (styled through the `debugPC` group nvim-dap already
--- references), the breakpoint signs' default `linehl` is empty, so there is no group to colour;
--- they must be redefined outright. Glyphs are copied from nvim-dap's own defaults so this only
--- changes the colour, not the sign text.
local function style_breakpoint_signs()
  local ok = pcall(require, 'dap')
  if not ok then return end
  local glyphs = {
    DapBreakpoint = '●',
    DapBreakpointCondition = '◆',
    DapBreakpointRejected = '○',
    DapLogPoint = '◆',
  }
  for name, text in pairs(glyphs) do
    vim.fn.sign_define(name, { text = text, texthl = 'DapBreakpointSign', linehl = 'DapBreakpointLine', numhl = '' })
  end
end

function M.setup()
  ensure_listeners()
  style_breakpoint_signs()

  vim.api.nvim_create_user_command('IntellijLspDebugPanel', M.open, {
    desc = 'IntelliJ: open the debug panel (call stack, locals, watches)',
  })
end

return M
