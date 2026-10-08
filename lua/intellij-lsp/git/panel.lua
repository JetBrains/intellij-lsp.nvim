--- The status list, with the selected entry's diff previewed in the editor window.
---
--- Shaped after `references.lua`, and for the same reason: a list you step through with j/k while the
--- editor follows, focus staying in the list, is the interaction that makes a change set readable
--- without losing your place. The differences from that module are forced by the data:
---
---   * A scratch buffer, not quickfix. Rows here are (side, path) pairs, not file positions, and half
---     of them have no line number to jump to at all. Using quickfix would also evict whatever list
---     the user had, and `:cnext` through a status list is meaningless.
---   * Preview shows a *diff*, not the file. The interesting thing about a modified file is what
---     changed, so previewing renders `git diff` into a scratch buffer with `filetype=diff`.
---
--- Teardown mirrors references.lua exactly: one augroup, one timer, one namespace, all dropped by
--- close().

local cmd = require('intellij-lsp.git.cmd')
local status = require('intellij-lsp.git.status')

local M = {}

local ns = vim.api.nvim_create_namespace('intellij-lsp.git.panel')
--- The line tints of the diff preview. Separate from `ns`, which each list render clears.
local preview_ns = vim.api.nvim_create_namespace('intellij-lsp.git.panel.preview')

--- Matches references.lua: below the lag threshold, above a key-repeat interval.
local DEBOUNCE_MS = 60

--- Live session, or nil when closed.
--- @type table|nil
local state = nil

-- -------------------------------------------------------------------------------------------------
-- Highlight groups
-- -------------------------------------------------------------------------------------------------

--- Defined here rather than in theme/groups.lua, following references.lua: the panel works for users
--- who never opted into the bundled colorscheme, so every group must resolve under any theme.
--- `default = true` loses to a user override, and linking rather than copying hex means a
--- `:colorscheme` restyles them instead of going stale.
local function define_highlights()
  local function hl(name, link)
    vim.api.nvim_set_hl(0, name, { link = link, default = true })
  end
  hl('IntellijGitHeader', 'Title')
  hl('IntellijGitSection', 'Statement')
  hl('IntellijGitStaged', 'DiffAdd')
  hl('IntellijGitUnstaged', 'DiffChange')
  hl('IntellijGitUntracked', 'Comment')
  hl('IntellijGitConflict', 'DiffDelete')
end

define_highlights()

vim.api.nvim_create_autocmd('ColorScheme', {
  group = vim.api.nvim_create_augroup('IntellijGitPanelHl', { clear = true }),
  callback = define_highlights,
  desc = 'Re-assert IntelliJ git panel highlight groups',
})

-- -------------------------------------------------------------------------------------------------
-- Rendering (pure; exposed as M._* for the server-free tests)
-- -------------------------------------------------------------------------------------------------

local SECTIONS = {
  { side = status.CONFLICTED, title = 'Conflicts', hl = 'IntellijGitConflict' },
  { side = status.STAGED, title = 'Staged', hl = 'IntellijGitStaged' },
  { side = status.UNSTAGED, title = 'Changes', hl = 'IntellijGitUnstaged' },
  { side = status.UNTRACKED, title = 'Untracked', hl = 'IntellijGitUntracked' },
}

--- Builds the buffer lines and a parallel row -> entry map.
---
--- The map is what makes the rest of the module simple: rows include a header, blank spacers and
--- section titles, so "the entry under the cursor" cannot be derived from the line number by
--- arithmetic. Returning it alongside the lines keeps the two definitionally in sync.
--- @param st table parsed status state
--- @return string[] lines
--- @return table<integer, table> entries keyed by 1-based row
--- @return table[] highlights { row, hl } 0-based rows
function M._render(st)
  local lines, entries, highlights = {}, {}, {}

  local function add(text, hl, entry)
    lines[#lines + 1] = text
    if hl then highlights[#highlights + 1] = { row = #lines - 1, hl = hl } end
    if entry then entries[#lines] = entry end
  end

  add(status.summary(st), 'IntellijGitHeader')
  if st.in_progress then
    add(('  %s in progress'):format(st.in_progress), 'IntellijGitConflict')
  end

  local any = false
  for _, section in ipairs(SECTIONS) do
    local rows = {}
    for _, entry in ipairs(st.entries or {}) do
      if entry.side == section.side then rows[#rows + 1] = entry end
    end
    if #rows > 0 then
      any = true
      add('')
      add(('%s (%d)'):format(section.title, #rows), 'IntellijGitSection')
      for _, entry in ipairs(rows) do
        local label = status.label(entry.code)
        local text
        if entry.origin then
          -- Rename: showing only the new path hides the move, which is the whole point of the entry.
          text = ('  %-11s %s ← %s'):format(label, entry.path, entry.origin)
        else
          text = ('  %-11s %s'):format(label, entry.path)
        end
        add(text, section.hl, entry)
      end
    end
  end

  if not any then
    add('')
    add('  nothing to commit, working tree clean', 'IntellijGitUntracked')
  end

  return lines, entries, highlights
end

-- -------------------------------------------------------------------------------------------------
-- Preview
-- -------------------------------------------------------------------------------------------------

--- The window to preview in. Same contract as references.lua's: never splits, returns nil rather
--- than creating a window from a CursorMoved handler.
--- @return integer|nil
local function preview_win()
  local function usable(win)
    if not win or not vim.api.nvim_win_is_valid(win) then return false end
    if win == state.win then return false end
    return vim.bo[vim.api.nvim_win_get_buf(win)].buftype ~= 'quickfix'
  end

  if usable(state.origin.win) then return state.origin.win end
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if usable(win) then return win end
  end
  return nil
end

--- Reusable scratch buffer for rendered diffs.
---
--- One buffer for the whole session, rewritten in place. Creating one per preview would leave a
--- buffer behind for every file stepped over, which is the mess `references.lua` goes out of its way
--- to avoid with its unlisted-buffer handling.
--- @return integer
local function diff_buf()
  if state.diff_buf and vim.api.nvim_buf_is_valid(state.diff_buf) then
    return state.diff_buf
  end
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = 'hide'
  vim.bo[buf].buftype = 'nofile'
  vim.bo[buf].swapfile = false
  vim.bo[buf].filetype = 'diff'
  vim.api.nvim_buf_set_name(buf, 'intellij-git://diff')
  state.diff_buf = buf
  return buf
end

--- git arguments that produce the diff for one entry.
---
--- The four sides need four different commands, and getting this wrong is silent -- it shows a diff,
--- just not the one asked for:
---
---   * staged   -> `diff --cached`, index against HEAD
---   * unstaged -> `diff`, working tree against index
---   * conflict -> `diff` shows the combined conflict-marker diff, which is what you want to read
---   * untracked -> not in the index at all, so `diff` says nothing; `--no-index` against /dev/null
---     renders the whole file as additions
--- @param entry table
--- @return string[]
function M._diff_args(entry)
  if entry.side == status.STAGED then
    return { 'diff', '--cached', '--', entry.path }
  elseif entry.side == status.UNTRACKED then
    -- Exits 1 by design when the files differ, so callers must not treat non-zero as failure here.
    return { 'diff', '--no-index', '--', '/dev/null', entry.path }
  else
    return { 'diff', '--', entry.path }
  end
end

--- The line tints of a unified diff, as IntelliJ's unified viewer paints them.
---
--- Only the lines inside a hunk count. The `---` and `+++` lines of a file header start with the same
--- characters, but they name the files and are not changes.
--- @param lines string[] `git diff` output
--- @return table[] { row (0-based), hl }
function M._line_highlights(lines)
  local result = {}
  local in_hunk = false
  for i, line in ipairs(lines) do
    if line:sub(1, 2) == '@@' then
      in_hunk = true
    elseif line:sub(1, 5) == 'diff ' then
      in_hunk = false
    elseif in_hunk then
      local mark = line:sub(1, 1)
      if mark == '+' then
        result[#result + 1] = { row = i - 1, hl = 'IntellijDiffInsertedLine' }
      elseif mark == '-' then
        result[#result + 1] = { row = i - 1, hl = 'IntellijDiffDeletedLine' }
      end
    end
  end
  return result
end

--- Renders the entry's diff into the editor window.
--- @param entry table|nil
local function preview(entry)
  local win = preview_win()
  if not win or not entry then return end

  local seq = (state.seq or 0) + 1
  state.seq = seq

  cmd.run(M._diff_args(entry), { cwd = state.root }, function(res)
    -- Stale-response guard. Holding `j` fires several requests and git may answer out of order, so a
    -- slow diff for a file the cursor has already left must not overwrite the current one.
    if not state or state.seq ~= seq then return end
    if not vim.api.nvim_win_is_valid(win) then return end

    local text = res.stdout
    -- `--no-index` and a plain `diff` both exit 1 when there are differences, which is the normal
    -- case; only an empty result with a non-zero code is a real failure worth reporting inline.
    if (text == nil or text == '') and not res.ok then
      text = '# ' .. cmd.error_message(res)
    end

    local lines = vim.split(text or '', '\n', { plain = true })
    if lines[#lines] == '' then table.remove(lines) end
    if #lines == 0 then lines = { '# no textual diff (binary, or mode change only)' } end

    local buf = diff_buf()
    vim.bo[buf].modifiable = true
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.bo[buf].modifiable = false

    vim.api.nvim_buf_clear_namespace(buf, preview_ns, 0, -1)
    for _, h in ipairs(M._line_highlights(lines)) do
      vim.api.nvim_buf_set_extmark(buf, preview_ns, h.row, 0, { line_hl_group = h.hl })
    end

    -- `keepjumps keepalt`, exactly as references.lua does it: nvim_win_set_buf pushes a jumplist
    -- entry per call and `:edit` rewrites the alternate file, so twenty j presses would otherwise
    -- destroy both <C-o> history and <C-^>.
    pcall(vim.api.nvim_win_call, win, function()
      vim.cmd('keepjumps keepalt buffer ' .. buf)
      pcall(vim.api.nvim_win_set_cursor, win, { 1, 0 })
    end)
  end)
end

-- -------------------------------------------------------------------------------------------------
-- Lifecycle
-- -------------------------------------------------------------------------------------------------

--- @return boolean
function M.is_open()
  return state ~= nil
end

--- The entry under the cursor, or nil on a header/blank row.
--- @return table|nil
function M.current_entry()
  if not state or not vim.api.nvim_win_is_valid(state.win) then return nil end
  return state.entries[vim.api.nvim_win_get_cursor(state.win)[1]]
end

--- Tears the session down. Idempotent, and safe to call from an autocmd.
--- @param restore boolean|nil return the origin window to its pre-open buffer and position
function M.close(restore)
  local s = state
  if not s then return end
  -- Dropped first, so autocmds fired by this teardown see a closed session and return early.
  state = nil

  if s.timer then
    s.timer:stop()
    if not s.timer:is_closing() then s.timer:close() end
  end

  pcall(vim.api.nvim_del_augroup_by_id, s.augroup)

  if vim.api.nvim_win_is_valid(s.win) then
    pcall(vim.api.nvim_win_close, s.win, true)
  end
  if s.diff_buf and vim.api.nvim_buf_is_valid(s.diff_buf) then
    pcall(vim.api.nvim_buf_delete, s.diff_buf, { force = true })
  end

  if restore and vim.api.nvim_win_is_valid(s.origin.win) then
    pcall(function()
      local buf = s.origin.buf
      if vim.api.nvim_buf_is_valid(buf) then
        vim.api.nvim_win_call(s.origin.win, function()
          vim.cmd('keepjumps keepalt buffer ' .. buf)
        end)
        -- Clamped: the file may have changed under us while browsing.
        local last = vim.api.nvim_buf_line_count(buf)
        local lnum = math.min(s.origin.cursor[1], last)
        vim.api.nvim_win_set_cursor(s.origin.win, { math.max(lnum, 1), s.origin.cursor[2] })
      end
      vim.api.nvim_set_current_win(s.origin.win)
    end)
  end
end

--- Opens the entry's file in the editor window and leaves the list.
local function open_entry()
  local entry = M.current_entry()
  if not entry then return end
  local path = state.root .. '/' .. entry.path
  local win = preview_win()
  M.close(false)
  if win and vim.api.nvim_win_is_valid(win) then
    vim.api.nvim_set_current_win(win)
  end
  -- A real jump, so unlike the previews this one does push the jumplist.
  vim.cmd.edit(vim.fn.fnameescape(path))
end

--- Repaints the panel from fresh git state, keeping the cursor row where it was.
function M.refresh()
  if not state then return end
  local root = state.root
  local row = vim.api.nvim_win_is_valid(state.win)
    and vim.api.nvim_win_get_cursor(state.win)[1] or 1

  status.fetch(root, function(st, err)
    if not state then return end
    if not st then
      vim.notify('IntelliJ git: ' .. tostring(err), vim.log.levels.ERROR)
      return
    end
    M._fill(st)
    if vim.api.nvim_win_is_valid(state.win) then
      local last = vim.api.nvim_buf_line_count(state.buf)
      pcall(vim.api.nvim_win_set_cursor, state.win, { math.min(row, last), 0 })
    end
  end)
end

--- Writes rendered state into the panel buffer.
--- @param st table
function M._fill(st)
  local lines, entries, highlights = M._render(st)

  vim.bo[state.buf].modifiable = true
  vim.api.nvim_buf_set_lines(state.buf, 0, -1, false, lines)
  vim.bo[state.buf].modifiable = false

  state.entries = entries
  state.status = st

  vim.api.nvim_buf_clear_namespace(state.buf, ns, 0, -1)
  for _, h in ipairs(highlights) do
    pcall(vim.api.nvim_buf_set_extmark, state.buf, ns, h.row, 0, {
      end_row = h.row + 1,
      hl_group = h.hl,
      hl_eol = true,
    })
  end
end

--- Reacts to the selection moving: preview after the debounce settles.
local function on_cursor_moved()
  if not state then return end
  state.timer:stop()
  state.timer:start(DEBOUNCE_MS, 0, function()
    -- Runs on the libuv thread, where API calls are illegal.
    vim.schedule(function()
      -- Nothing captured outside is trusted: the window may have closed and the cursor moved between
      -- the timer firing and this callback running.
      if not state or not vim.api.nvim_win_is_valid(state.win) then return end
      preview(state.entries[vim.api.nvim_win_get_cursor(state.win)[1]])
    end)
  end)
end

--- Installs keymaps and autocmds on the panel buffer.
local function attach(buf, win, augroup)
  local function map(lhs, rhs, desc)
    vim.keymap.set('n', lhs, rhs, { buffer = buf, nowait = true, desc = desc })
  end

  map('<CR>', open_entry, 'Open this file')
  map('q', function() M.close(true) end, 'Close and restore position')
  map('<Esc>', function() M.close(true) end, 'Close and restore position')
  map('R', M.refresh, 'Refresh')

  vim.api.nvim_create_autocmd('CursorMoved', {
    group = augroup,
    buffer = buf,
    callback = on_cursor_moved,
    desc = 'Preview the selected change',
  })

  -- Leaving the panel any other way must not rewind the editor: the user may have navigated there
  -- deliberately. So restore = false everywhere except the explicit q/<Esc> above.
  vim.api.nvim_create_autocmd({ 'BufWinLeave', 'BufWipeout' }, {
    group = augroup,
    buffer = buf,
    callback = function() M.close(false) end,
    desc = 'Tear down the git panel',
  })
  vim.api.nvim_create_autocmd('WinClosed', {
    group = augroup,
    pattern = tostring(win),
    callback = function() M.close(false) end,
    desc = 'Tear down the git panel',
  })
end

--- Opens the status panel.
function M.open()
  local root = cmd.root()
  if not root then
    vim.notify('IntelliJ git: not inside a git repository.', vim.log.levels.WARN)
    return
  end

  -- Captured before the async fetch: the user may move the cursor while git runs.
  local origin = {
    win = vim.api.nvim_get_current_win(),
    buf = vim.api.nvim_get_current_buf(),
    cursor = vim.api.nvim_win_get_cursor(0),
  }

  -- A second call replaces the session rather than stacking one.
  M.close(false)

  status.fetch(root, function(st, err)
    if not st then
      vim.notify('IntelliJ git: ' .. tostring(err), vim.log.levels.ERROR)
      return
    end

    local buf = vim.api.nvim_create_buf(false, true)
    vim.bo[buf].bufhidden = 'wipe'
    vim.bo[buf].buftype = 'nofile'
    vim.bo[buf].swapfile = false
    vim.bo[buf].filetype = 'intellij-git-status'
    vim.api.nvim_buf_set_name(buf, 'intellij-git://status')

    vim.cmd('botright 15split')
    local win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(win, buf)
    vim.wo[win].number = false
    vim.wo[win].relativenumber = false
    vim.wo[win].signcolumn = 'no'
    vim.wo[win].wrap = false
    vim.wo[win].cursorline = true
    vim.wo[win].winfixheight = true

    state = {
      buf = buf,
      win = win,
      root = root,
      origin = origin,
      entries = {},
      augroup = vim.api.nvim_create_augroup('IntellijGitPanel', { clear = true }),
      timer = vim.uv.new_timer(),
      seq = 0,
    }

    M._fill(st)
    attach(buf, win, state.augroup)

    -- Land on the first real entry, so the panel is useful before any keypress.
    local first
    for row = 1, vim.api.nvim_buf_line_count(buf) do
      if state.entries[row] then
        first = row
        break
      end
    end
    if first then
      pcall(vim.api.nvim_win_set_cursor, win, { first, 0 })
      preview(state.entries[first])
    end
  end)
end

return M
