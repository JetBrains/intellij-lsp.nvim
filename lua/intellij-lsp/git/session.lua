--- A list window whose selection previews in the editor window.
---
--- Extracted rather than copied a third time. `references.lua` established this interaction, Phase 1's
--- `panel.lua` reimplemented it for the status list, and Phase 2 needs it twice more (log, branches) --
--- which is where drift starts. Everything here was already in `panel.lua`; the tricky parts are the
--- reasons, so they are kept with the code:
---
---   * **`keepjumps keepalt` for every preview.** `nvim_win_set_buf` pushes a jumplist entry per call
---     and `:edit` rewrites the alternate file, so thirty `j` presses would destroy both `<C-o>`
---     history and `<C-^>`. Only an explicit `<CR>` should push the jumplist.
---   * **A debounce, not a preview per keystroke.** Holding `j` through 500 rows must load the row you
---     stop on, not all 500.
---   * **A monotonic sequence guard.** Async answers can arrive out of order, so a slow response for a
---     row the cursor has already left must be dropped rather than rendered.
---   * **Teardown drops everything at once.** One augroup, one timer, one scratch buffer, and `state`
---     cleared *first* so autocmds fired during teardown see a closed session and return early.
---
--- Each caller owns its own session table; this module holds no global state, so a log view and a
--- branch list can be open at once without fighting over one `state`.

local M = {}

--- Matches references.lua and panel.lua: below the lag threshold, above a key-repeat interval.
local DEBOUNCE_MS = 60

--- @class IntellijGitSession
--- @field buf integer            the list buffer
--- @field win integer            the list window
--- @field root string            repository root
--- @field rows table<integer, any> row -> item; absent for headers, blanks and separators
--- @field origin table           { win, buf, cursor } captured before opening
--- @field augroup integer
--- @field timer uv.uv_timer_t
--- @field seq integer            monotonic, for the stale-response guard
--- @field preview_buf integer|nil reused scratch buffer for rendered previews
--- @field on_preview fun(session, item)|nil
--- @field on_select fun(session, item)|nil

--- Creates the list window and returns a session.
---
--- The caller fills the buffer with `M.fill`; nothing is rendered here, because the log needs its
--- content before it can decide where to put the cursor.
--- @param opts { root: string, name: string, filetype: string, height?: integer, vertical?: boolean }
--- @return IntellijGitSession
function M.open(opts)
  -- Captured before the window is created, so `close(true)` can put the user back exactly where they
  -- were rather than wherever the split left them.
  local origin = {
    win = vim.api.nvim_get_current_win(),
    buf = vim.api.nvim_get_current_buf(),
    cursor = vim.api.nvim_win_get_cursor(0),
  }

  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = 'wipe'
  vim.bo[buf].buftype = 'nofile'
  vim.bo[buf].swapfile = false
  vim.bo[buf].filetype = opts.filetype
  vim.api.nvim_buf_set_name(buf, opts.name)

  -- So a command run *from* this list resolves the same repository. Without it, `:IntellijGitBranches`
  -- pressed inside the log view resolves the root from a fileless scratch buffer and reports "not
  -- inside a git repository".
  require('intellij-lsp.git.cmd').set_buffer_root(buf, opts.root)

  -- A vertical split for the log: the graph plus subject is wide and reads badly in a 15-line strip,
  -- while the status list is short and wide. Both are `botright` so they do not displace the editor.
  if opts.vertical then
    vim.cmd('botright vsplit')
  else
    vim.cmd(('botright %dsplit'):format(opts.height or 15))
  end

  local win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(win, buf)
  vim.wo[win].number = false
  vim.wo[win].relativenumber = false
  vim.wo[win].signcolumn = 'no'
  vim.wo[win].wrap = false
  vim.wo[win].cursorline = true
  if opts.vertical then
    vim.wo[win].winfixwidth = true
  else
    vim.wo[win].winfixheight = true
  end

  return {
    buf = buf,
    win = win,
    root = opts.root,
    rows = {},
    origin = origin,
    augroup = vim.api.nvim_create_augroup('IntellijGitSession' .. buf, { clear = true }),
    timer = vim.uv.new_timer(),
    seq = 0,
  }
end

--- Whether the session's window is still usable.
--- @param s IntellijGitSession|nil
--- @return boolean
function M.is_open(s)
  return s ~= nil and vim.api.nvim_win_is_valid(s.win) and vim.api.nvim_buf_is_valid(s.buf)
end

--- Writes lines and a row map into the list buffer.
---
--- `rows` is a sparse map from 1-based row to item, and it is what makes the rest simple: headers,
--- blank spacers and graph-only lines cannot be distinguished from content rows by arithmetic, so the
--- map is built alongside the lines and stays definitionally in sync.
--- @param s IntellijGitSession
--- @param lines string[]
--- @param rows table<integer, any>
--- @param highlights table[]|nil { row (0-based), hl, col?, end_col? }
--- @param ns integer|nil namespace for the highlights
function M.fill(s, lines, rows, highlights, ns)
  if not M.is_open(s) then return end

  vim.bo[s.buf].modifiable = true
  vim.api.nvim_buf_set_lines(s.buf, 0, -1, false, lines)
  vim.bo[s.buf].modifiable = false

  s.rows = rows

  if ns then
    vim.api.nvim_buf_clear_namespace(s.buf, ns, 0, -1)
    for _, h in ipairs(highlights or {}) do
      M.apply_span(s.buf, ns, h)
    end
  end
end

--- Applies one highlight span.
---
--- `end_row` is always passed explicitly, and that is load-bearing rather than tidiness. Omitting it
--- while giving an `end_col` makes Neovim validate the column against the wrong line, so the call fails
--- with "Invalid 'end_col': out of range" for spans that are plainly inside their line. Because the
--- failure was swallowed by a `pcall`, the symptom was silent: a row whose spans all failed -- in
--- practice the rename rows, which are the longest -- simply rendered unhighlighted while every other
--- row looked right, which reads as an inconsistent colour scheme rather than as a bug.
---
--- Two shapes: a within-line span (`end_col` given, `end_row` is the same row) and a whole-line span
--- (no `end_col`, so it runs to the start of the next row with `hl_eol`).
--- @param buf integer
--- @param ns integer
--- @param h table { row, hl, col?, end_col? }
function M.apply_span(buf, ns, h)
  -- Still guarded: a highlight computed from one render must not break the next if the row count
  -- shrank between them.
  pcall(vim.api.nvim_buf_set_extmark, buf, ns, h.row, h.col or 0, {
    end_row = h.end_col and h.row or (h.row + 1),
    end_col = h.end_col,
    hl_group = h.hl,
    hl_eol = h.end_col == nil,
  })
end

--- The item under the cursor, or nil on a non-content row.
--- @param s IntellijGitSession|nil
--- @return any|nil
function M.current(s)
  if not M.is_open(s) then return nil end
  return s.rows[vim.api.nvim_win_get_cursor(s.win)[1]]
end

--- Moves the cursor to the first row that has an item, and previews it.
--- @param s IntellijGitSession
function M.select_first(s)
  if not M.is_open(s) then return end
  for row = 1, vim.api.nvim_buf_line_count(s.buf) do
    if s.rows[row] then
      pcall(vim.api.nvim_win_set_cursor, s.win, { row, 0 })
      M.preview_now(s)
      return
    end
  end
end

--- The window to preview in.
---
--- Never splits: creating windows from a `CursorMoved` handler is how layouts get mangled. Returns nil
--- instead, and the preview simply does nothing.
--- @param s IntellijGitSession
--- @return integer|nil
function M.preview_win(s)
  local function usable(win)
    if not win or not vim.api.nvim_win_is_valid(win) then return false end
    if win == s.win then return false end
    return vim.bo[vim.api.nvim_win_get_buf(win)].buftype ~= 'quickfix'
  end

  if usable(s.origin.win) then return s.origin.win end
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if usable(win) then return win end
  end
  return nil
end

--- Reusable scratch buffer for rendered previews.
---
--- One per session, rewritten in place. A buffer per preview would leave one behind for every row
--- stepped over, which is the mess `references.lua` works hard to avoid.
--- @param s IntellijGitSession
--- @param filetype string
--- @return integer
function M.preview_buf(s, filetype)
  if s.preview_buf and vim.api.nvim_buf_is_valid(s.preview_buf) then
    -- Filetype can change between rows (a diff preview vs. a commit message), so it is re-asserted --
    -- without running ftplugins, since this buffer is reused across rows. See set_scratch_filetype.
    M.set_scratch_filetype(s.preview_buf, filetype)
    return s.preview_buf
  end
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = 'hide'
  vim.bo[buf].buftype = 'nofile'
  vim.bo[buf].swapfile = false
  M.set_scratch_filetype(buf, filetype)
  vim.api.nvim_buf_set_name(buf, ('intellij-git://preview/%d'):format(buf))
  -- Registered like the list buffer: the preview is what the editor window is showing after a browse,
  -- so it is a very likely "current buffer" when the next git command runs.
  require('intellij-lsp.git.cmd').set_buffer_root(buf, s.root)
  s.preview_buf = buf
  return buf
end

--- Renders `lines` into the preview window.
---
--- Returns false when the session or window went away, so callers can drop a stale response.
--- @param s IntellijGitSession
--- @param lines string[]
--- @param filetype string
--- @return boolean
function M.render_preview(s, lines, filetype)
  if not M.is_open(s) then return false end
  local win = M.preview_win(s)
  if not win then return false end

  local buf = M.preview_buf(s, filetype)
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false

  -- See the module comment: `keepjumps keepalt` is what keeps `<C-o>` and `<C-^>` intact across a
  -- long browse.
  pcall(vim.api.nvim_win_call, win, function()
    vim.cmd('keepjumps keepalt buffer ' .. buf)
    pcall(vim.api.nvim_win_set_cursor, win, { 1, 0 })
  end)
  return true
end

--- Sets the filetype on a throwaway render buffer, without running filetype plugins.
---
--- Assigning 'filetype' fires `FileType`, which sources the ftplugin for that language. On a scratch
--- buffer that is at best pointless -- these are read-only renderings of a git object, so keymaps,
--- `formatexpr`, `omnifunc` and the rest have nothing to act on -- and at worst it breaks:
---
--- Neovim's bundled `ftplugin/java.vim` ends with
---
---     let b:undo_ftplugin = 'call JavaFileTypeCleanUp() | delfunction JavaFileTypeCleanUp'
---
--- so its undo hook *deletes* the function it just called, while the definition sits behind a
--- `b:did_ftplugin` guard. These buffers are reused across files, so stepping through a commit's Java
--- files reassigned 'filetype' on the same buffer repeatedly: the first change ran the undo (deleting
--- the function), and the next one ran it again against a function that no longer existed --
--- `E117: Unknown function: JavaFileTypeCleanUp`, once per step. `java.vim` is the only ftplugin in the
--- runtime that does this, which is why Java files were the ones that broke.
---
--- Syntax highlighting is what these buffers actually want, and 'syntax' provides it without the
--- plugin machinery.
--- @param buf integer
--- @param filetype string
function M.set_scratch_filetype(buf, filetype)
  if vim.b[buf].intellij_git_syntax == filetype then return end
  vim.b[buf].intellij_git_syntax = filetype

  -- `eventignore` rather than setting 'syntax' alone: some highlighting is installed by the ftplugin,
  -- and suppressing only the autocmds keeps 'filetype' correct for anything that inspects it (the
  -- statusline, a user's own autocmds) while skipping the plugin sourcing that causes the breakage.
  local saved = vim.o.eventignore
  vim.o.eventignore = 'FileType'
  local ok = pcall(function() vim.bo[buf].filetype = filetype end)
  vim.o.eventignore = saved
  if not ok then return end

  -- Syntax is normally switched on by the FileType autocmd that was just suppressed, so it is set
  -- explicitly. An empty filetype (an unrecognised extension) clears it rather than erroring.
  pcall(function() vim.bo[buf].syntax = filetype end)
end

--- Renders two revisions side by side in the preview area, in diff mode.
---
--- The single-pane `render_preview` cannot do this: diff mode is a property of *windows*, so showing
--- two sides means owning two of them. The pair is created once and then reused -- rebuilding the split
--- on every `j` would fight the cursor and make the layout flicker while stepping a list.
---
--- Both buffers are read-only. Whatever a caller puts here is a historical revision, and diff mode's
--- `do`/`dp` would otherwise offer to write into it.
---
--- Returns false when the session or the preview area went away, so a stale async response is dropped
--- rather than painting into a closed layout.
--- @param s IntellijGitSession
--- @param left { name: string, title?: string, lines: string[] } `title` is the pane header
--- @param right { name: string, title?: string, lines: string[] }
--- @param filetype string
--- @return boolean
function M.render_diff_preview(s, left, right, filetype)
  if not M.is_open(s) then return false end

  local host = M.preview_win(s)
  if not host then return false end

  --- One side's scratch buffer, reused across steps.
  local function side_buf(key, name, lines)
    local buf = s[key]
    if not buf or not vim.api.nvim_buf_is_valid(buf) then
      buf = vim.api.nvim_create_buf(false, true)
      vim.bo[buf].buftype = 'nofile'
      vim.bo[buf].swapfile = false
      vim.bo[buf].bufhidden = 'hide'
      s[key] = buf
      require('intellij-lsp.git.cmd').set_buffer_root(buf, s.root)
    end
    vim.bo[buf].modifiable = true
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.bo[buf].modifiable = false
    M.set_scratch_filetype(buf, filetype)
    -- Renamed per step: the two sides show different paths for a rename, and a stale name in the
    -- statusline is worse than none. `pcall` because two panes can legitimately want the same name.
    pcall(vim.api.nvim_buf_set_name, buf, name)
    return buf
  end

  local lbuf = side_buf('diff_left_buf', left.name, left.lines)
  local rbuf = side_buf('diff_right_buf', right.name, right.lines)

  -- Reuse the existing pair when it is still intact; only build the split the first time.
  local lwin, rwin = s.diff_left_win, s.diff_right_win
  local usable = lwin and rwin
    and vim.api.nvim_win_is_valid(lwin) and vim.api.nvim_win_is_valid(rwin)

  if not usable then
    -- Close a half-surviving pair before rebuilding, or the layout accumulates windows.
    for _, w in ipairs({ lwin, rwin }) do
      if w and vim.api.nvim_win_is_valid(w) and w ~= host then
        pcall(vim.api.nvim_win_close, w, true)
      end
    end

    local ok = pcall(vim.api.nvim_win_call, host, function()
      vim.api.nvim_win_set_buf(host, rbuf)
      vim.cmd('leftabove vsplit')
      lwin = vim.api.nvim_get_current_win()
      vim.api.nvim_win_set_buf(lwin, lbuf)
    end)
    if not ok then return false end
    rwin = host
    s.diff_left_win, s.diff_right_win = lwin, rwin
  else
    -- Buffers are already in place; just make sure each window still shows its own side.
    pcall(vim.api.nvim_win_set_buf, lwin, lbuf)
    pcall(vim.api.nvim_win_set_buf, rwin, rbuf)
  end

  -- Re-asserted every render: replacing a buffer in a window drops diff mode, so without this the
  -- second file stepped onto shows two plain panes with no highlighting at all.
  for _, w in ipairs({ lwin, rwin }) do
    pcall(vim.api.nvim_win_call, w, function()
      vim.cmd('diffthis')
      vim.cmd('normal! gg')
      -- Land on the first change rather than at line 1 of an unchanged preamble.
      pcall(function() vim.cmd('normal! ]c') end)
    end)
  end
  require('intellij-lsp.git.diff').style_panes(lwin, rwin, {
    old = left.title and { name = left.title, readonly = true },
    new = right.title and { name = right.title, readonly = true },
  })

  return true
end

--- Closes the side-by-side preview panes, restoring a single preview window.
--- @param s IntellijGitSession
function M.close_diff_preview(s)
  if not s then return end

  -- The left pane is the one this module created; the right one is the caller's original preview
  -- window and must survive.
  if s.diff_left_win and vim.api.nvim_win_is_valid(s.diff_left_win) then
    pcall(vim.api.nvim_win_close, s.diff_left_win, true)
  end
  if s.diff_right_win and vim.api.nvim_win_is_valid(s.diff_right_win) then
    pcall(vim.api.nvim_win_call, s.diff_right_win, function() vim.cmd('diffoff') end)
    require('intellij-lsp.git.diff').unstyle_pane(s.diff_right_win)
  end

  -- Order matters, and getting it wrong destroys the caller's window. Deleting a buffer closes every
  -- window displaying it, and the surviving pane is showing one of these scratches -- so the scratch
  -- has to be evicted from that window *before* it is deleted, or the window goes with it and the
  -- session's `restore` then has nothing to restore into.
  --
  -- The origin buffer is the natural thing to put back: it is what the window held before the preview
  -- took it over, and `restore` is about to reassert it anyway.
  local surviving = s.diff_right_win
  if surviving and vim.api.nvim_win_is_valid(surviving)
    and s.origin and vim.api.nvim_buf_is_valid(s.origin.buf) then
    pcall(vim.api.nvim_win_call, surviving, function()
      vim.cmd('keepjumps keepalt buffer ' .. s.origin.buf)
    end)
  end

  s.diff_left_win, s.diff_right_win = nil, nil
  for _, key in ipairs({ 'diff_left_buf', 'diff_right_buf' }) do
    if s[key] and vim.api.nvim_buf_is_valid(s[key]) then
      pcall(vim.api.nvim_buf_delete, s[key], { force = true })
    end
    s[key] = nil
  end
end

--- Applies highlights to the preview buffer.
---
--- Separate from `render_preview` because most previews are syntax-highlighted by their filetype and
--- need none; only a rendered list (the log's affected-files view) paints its own.
--- @param s IntellijGitSession
--- @param highlights table[] { row (0-based), hl, col?, end_col? }
--- @param ns integer
function M.highlight_preview(s, highlights, ns)
  if not M.is_open(s) then return end
  local buf = s.preview_buf
  if not buf or not vim.api.nvim_buf_is_valid(buf) then return end

  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  for _, h in ipairs(highlights or {}) do
    M.apply_span(buf, ns, h)
  end
end

--- Claims the next sequence number, invalidating any in-flight response.
--- @param s IntellijGitSession
--- @return integer
function M.next_seq(s)
  s.seq = (s.seq or 0) + 1
  return s.seq
end

--- Whether `seq` is still the newest request.
--- @param s IntellijGitSession|nil
--- @param seq integer
--- @return boolean
function M.is_current(s, seq)
  return M.is_open(s) and s.seq == seq
end

--- Previews the current row immediately, bypassing the debounce.
--- @param s IntellijGitSession
function M.preview_now(s)
  if not M.is_open(s) or not s.on_preview then return end
  local item = M.current(s)
  if item then s.on_preview(s, item) end
end

--- Tears the session down. Idempotent, and safe to call from an autocmd.
--- @param s IntellijGitSession|nil
--- @param restore boolean|nil put the origin window back where it was
function M.close(s, restore)
  if not s or s.closed then return end
  -- Marked first, so autocmds fired by this teardown see a closed session and return early.
  s.closed = true

  if s.timer then
    s.timer:stop()
    if not s.timer:is_closing() then s.timer:close() end
  end

  pcall(vim.api.nvim_del_augroup_by_id, s.augroup)

  -- Before the list window closes, so the restore below finds the origin window in its normal state
  -- rather than still split in two and stuck in diff mode.
  M.close_diff_preview(s)

  if vim.api.nvim_win_is_valid(s.win) then
    pcall(vim.api.nvim_win_close, s.win, true)
  end
  if s.preview_buf and vim.api.nvim_buf_is_valid(s.preview_buf) then
    pcall(vim.api.nvim_buf_delete, s.preview_buf, { force = true })
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

--- Installs the debounced preview and the teardown autocmds.
---
--- `keys` maps a left-hand side to a function taking the session; `<CR>`, `q` and `<Esc>` are provided
--- by default and can be overridden by naming them.
--- @param s IntellijGitSession
--- @param keys table<string, fun(s: IntellijGitSession)>|nil
function M.attach(s, keys)
  local function map(lhs, rhs, desc)
    vim.keymap.set('n', lhs, function() rhs(s) end,
      { buffer = s.buf, nowait = true, desc = desc })
  end

  local defaults = {
    ['<CR>'] = function(sess)
      local item = M.current(sess)
      if item and sess.on_select then sess.on_select(sess, item) end
    end,
    ['q'] = function(sess) M.close(sess, true) end,
    ['<Esc>'] = function(sess) M.close(sess, true) end,
  }
  for lhs, rhs in pairs(vim.tbl_extend('force', defaults, keys or {})) do
    map(lhs, rhs, 'IntelliJ git')
  end

  vim.api.nvim_create_autocmd('CursorMoved', {
    group = s.augroup,
    buffer = s.buf,
    desc = 'IntelliJ git: preview the selected row',
    callback = function()
      if not M.is_open(s) or not s.on_preview then return end
      s.timer:stop()
      s.timer:start(DEBOUNCE_MS, 0, function()
        -- Runs on the libuv thread, where API calls are illegal.
        vim.schedule(function()
          -- Nothing captured outside is trusted: the window may have closed and the cursor moved
          -- between the timer firing and this callback running.
          if not M.is_open(s) then return end
          local item = M.current(s)
          if item then s.on_preview(s, item) end
        end)
      end)
    end,
  })

  -- Leaving the list any other way must not rewind the editor: the user may have navigated there
  -- deliberately. So `restore = false` on every path except the explicit q/<Esc> above.
  vim.api.nvim_create_autocmd({ 'BufWinLeave', 'BufWipeout' }, {
    group = s.augroup,
    buffer = s.buf,
    callback = function() M.close(s, false) end,
    desc = 'IntelliJ git: tear down the list',
  })
  vim.api.nvim_create_autocmd('WinClosed', {
    group = s.augroup,
    pattern = tostring(s.win),
    callback = function() M.close(s, false) end,
    desc = 'IntelliJ git: tear down the list',
  })
end

--- Registers highlight groups that resolve under any colorscheme.
---
--- `default = true` loses to a user override, and linking rather than copying hex means a
--- `:colorscheme` restyles them instead of going stale. `hi clear` drops `default` links, hence the
--- `ColorScheme` re-assertion.
--- @param groups table<string, string> name -> link target
--- @param augroup_name string
function M.define_highlights(groups, augroup_name)
  local function define()
    for name, link in pairs(groups) do
      vim.api.nvim_set_hl(0, name, { link = link, default = true })
    end
  end
  define()
  vim.api.nvim_create_autocmd('ColorScheme', {
    group = vim.api.nvim_create_augroup(augroup_name, { clear = true }),
    callback = define,
    desc = 'Re-assert IntelliJ git highlight groups',
  })
end

return M
