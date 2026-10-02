--- Reference browsing: a quickfix list whose selection previews live in the editor window.
---
--- Stock `grr` fills the quickfix list and leaves you there: stepping with j/k moves the selection
--- bar but the editor never follows, so seeing the code around a reference costs a jump and your
--- place in the file. This module keeps the built-in list -- so `:cnext`, `:copen` and quickfix
--- plugins keep working -- and adds the three things it lacks: the matched identifier is highlighted
--- (not just the row), moving the selection previews that reference in the editor window while focus
--- stays in the list, and quickfix's own selected entry follows the cursor so the 'QuickFixLine' bar
--- marks where you are rather than staying pinned to the first entry.
---
---   j / k        step, editor follows
---   <CR>         commit the jump, close the list
---   q / <Esc>    close the list, return to where grr was pressed
---
--- Everything is torn down by close(): one augroup, one timer, two namespaces.

local M = {}

--- Extmark namespaces. Two, because they are cleared on different schedules: the quickfix range
--- highlight is rewritten on every cursor move, the editor-side flash expires on its own timer.
local ns_qf = vim.api.nvim_create_namespace('intellij-lsp.references.qf')
local ns_flash = vim.api.nvim_create_namespace('intellij-lsp.references.flash')

--- Debounce interval. Holding `j` through a 200-entry list should load the file you stop on, not all
--- 200. 60ms sits below the threshold where the preview feels laggy but above a key-repeat interval.
local DEBOUNCE_MS = 60

--- How long the editor-side match flash stays visible.
local FLASH_MS = 400

--- Live browsing session, or nil when the list is closed. Kept as one table so close() can drop the
--- whole thing atomically and a re-entrant call sees a clean slate.
--- @type table|nil
local state = nil

-- -------------------------------------------------------------------------------------------------
-- Highlight groups
-- -------------------------------------------------------------------------------------------------

--- Defines the feature's highlight groups.
---
--- Deliberately here rather than in theme/groups.lua: the feature works for users who never opted
--- into the bundled colorscheme, so these must resolve to something sane under any theme. `default =
--- true` makes them lose to a user's own override, and linking rather than copying hex means a
--- `:colorscheme` restyles them for free instead of going stale.
---
--- Under islands-dark these resolve through IncSearch/Search to IntelliJ's own Find-Usages greens.
local function define_highlights()
  vim.api.nvim_set_hl(0, 'IntellijLspReferenceMatch', { link = 'IncSearch', default = true })
  vim.api.nvim_set_hl(0, 'IntellijLspReferencePreview', { link = 'Search', default = true })
end

define_highlights()

-- `hi clear` drops `default` links, so without this the groups vanish on the next :colorscheme.
vim.api.nvim_create_autocmd('ColorScheme', {
  group = vim.api.nvim_create_augroup('IntellijLspReferencesHl', { clear = true }),
  callback = define_highlights,
  desc = 'Re-assert IntelliJ LSP reference highlight groups',
})

-- -------------------------------------------------------------------------------------------------
-- Row helpers (exposed as M._* for the server-free test suite)
-- -------------------------------------------------------------------------------------------------

--- True for a location inside a library or the JDK.
---
--- The server answers those with `jar:` and `jrt:` URIs. By the time on_list runs, Neovim has
--- already turned each one into a buffer: `vim.lsp.util.locations_to_items` calls `vim.uri_to_bufnr`
--- on every URI. What it does next depends on the scheme, and inconsistently so. A `jrt:` name looks
--- absolute, so get_lines sees a non-`file:` URI and `bufload`s it expressly so a plugin's BufReadCmd
--- can fill it -- decompiler.lua's does -- and the item arrives with real text. A `jar:` URI is
--- treated as a *relative path under cwd*, the buffer is literally named "<cwd>/jar:file:///...",
--- and reading that name back yields a `file:` URI, so get_lines tries the filesystem instead, finds
--- nothing, and the item arrives with empty text and columns clamped to 1.
---
--- hydrate() below evens that out: it loads the buffer itself where Neovim did not and recomputes the
--- row from the Location's range. Either way the row is pinned to the buffer by number -- handing
--- quickfix the cwd-prefixed name as a `filename` would only resolve it a second time.
--- @param uri string
--- @return boolean
local function is_external(uri)
  return uri:sub(1, 5) ~= 'file:'
end

--- The recognisable tail of a `jar:`/`jrt:` URI, for a row whose text came back empty.
---
--- `jar:file:///.../lib.jar!/com/example/Foo.class` -> `lib.jar!/com/example/Foo.class`
--- `jrt:/java.base/java/lang/String.class`          -> `java.base/java/lang/String.class`
--- @param uri string
--- @return string
local function external_label(uri)
  local jar = uri:match('([^/]+%.jar!/.*)$')
  if jar then return jar end
  return (uri:gsub('^%a+:/*', ''))
end

--- Byte range of the match inside the *rendered* quickfix line.
---
--- Quickfix stores `text` verbatim but renders it leading-trimmed, behind a
--- "<file>|<lnum> col <c>-<e>| " prefix. `item.col` indexes the stored text, so it has to be rebased
--- by the number of bytes trimmed.
---
--- The prefix is measured from the right (`#rendered - #trimmed`), never parsed: a file name may
--- contain `|`, which defeats any pattern scanning forward for the separators. Suffix anchoring is
--- exact because the trimmed text is always the rendered line's tail.
---
--- Returns nil when the arithmetic does not land inside the line. A foreign 'quickfixtextfunc' can
--- render anything at all, and a wrong extmark is worse than none -- callers fall back to the row
--- highlight alone.
--- @param rendered string the line as quickfix drew it
--- @param stored string the item's `text` as stored
--- @param col integer 1-based byte column into `stored`
--- @param end_col integer 1-based byte column, exclusive
--- @return integer|nil start_byte 0-based, into `rendered`
--- @return integer|nil end_byte 0-based, exclusive
local function qf_line_range(rendered, stored, col, end_col)
  if not (col and end_col) or end_col <= col then return nil end

  local trimmed = stored:gsub('^%s+', '')
  local prefix = #rendered - #trimmed
  local lead = #stored - #trimmed
  -- The suffix check is what makes a third-party 'quickfixtextfunc' fail safe rather than mispaint.
  if prefix < 0 or rendered:sub(prefix + 1) ~= trimmed then return nil end

  local s = prefix + (col - 1 - lead)
  local e = prefix + (end_col - 1 - lead)
  if s < prefix or e <= s or e > #rendered then return nil end
  return s, e
end

--- Rebuilds a library row from its buffer, loading the buffer if Neovim did not.
---
--- `bufload` is what runs decompiler.lua's BufReadCmd, which blocks until the source is in the
--- buffer (its cache makes that once per class, not once per row). The line is then read back and
--- the Location's utf-16 columns converted against it -- the conversion locations_to_items did was
--- against whatever line it had, which for a `jar:` row was none.
---
--- Returns nil when there is still no line to show: the decompiler is disabled, no server is
--- attached, or the scheme is one no BufReadCmd claims.
--- @param item table item from on_list
--- @param uri string
--- @param encoding string the answering client's offset encoding
--- @return table|nil row quickfix entry pinned to the buffer by number
local function hydrate(item, uri, encoding)
  local range = vim.tbl_get(item, 'user_data', 'range')
    or vim.tbl_get(item, 'user_data', 'targetSelectionRange')
    or vim.tbl_get(item, 'user_data', 'targetRange')
  if not range then return nil end

  local buf = vim.uri_to_bufnr(uri)
  if not vim.api.nvim_buf_is_loaded(buf) then pcall(vim.fn.bufload, buf) end
  if not vim.api.nvim_buf_is_loaded(buf) then return nil end

  local line = vim.api.nvim_buf_get_lines(buf, range.start.line, range.start.line + 1, false)[1]
  if not line or line == '' then return nil end

  local function byte_col(pos)
    local ok, idx = pcall(vim.str_byteindex, line, encoding, pos.character, false)
    return (ok and idx or #line) + 1
  end

  local row = vim.deepcopy(item)
  row.filename = nil
  row.bufnr = buf
  row.text = line
  row.lnum = range.start.line + 1
  row.end_lnum = range['end'].line + 1
  row.col = byte_col(range.start)
  -- A range that ends on a later line has no end column on this one; highlight_qf_row clamps on it.
  row.end_col = range['end'].line == range.start.line and byte_col(range['end']) or nil
  row.valid = 1
  return row
end

--- Prepares LSP list items for quickfix, pinning library rows to their decompiled buffers.
---
--- A library row the decompiler can fill (see hydrate) is as navigable as any other: stepping onto it
--- previews the decompiled source and <CR> lands in it.
---
--- One it cannot fill is kept rather than dropped: silently filtering turns "17 references" into 4
--- with no explanation, indistinguishable from the stale-index case the README warns about.
--- `valid = 0` renders as a bare "|| text" row that `:cnext`/`:cprev` skip, and the URI's tail
--- stands in for the text it does not have.
--- @param items table[] items from on_list
--- @param encoding string|nil offset encoding of the client that answered; defaults to utf-16
--- @return table[] prepared copy
--- @return integer unopenable count of rows marked valid = 0
local function tag_items(items, encoding)
  encoding = encoding or 'utf-16'
  local out, unopenable = {}, 0

  for _, item in ipairs(items) do
    local uri = vim.tbl_get(item, 'user_data', 'uri')
      or vim.tbl_get(item, 'user_data', 'targetUri')

    if uri and is_external(uri) then
      local row = hydrate(item, uri, encoding)
      if not row then
        unopenable = unopenable + 1
        -- No filename and no bufnr: the empty buffer behind this row is wiped by the caller.
        row = { text = external_label(uri), valid = 0, user_data = item.user_data }
      end
      table.insert(out, row)
    else
      local copy = vim.deepcopy(item)
      copy.valid = 1
      table.insert(out, copy)
    end
  end

  return out, unopenable
end

M._qf_line_range = qf_line_range
M._is_external = is_external
M._external_label = external_label
M._tag_items = tag_items

-- -------------------------------------------------------------------------------------------------
-- Preview
-- -------------------------------------------------------------------------------------------------

--- Wipes the empty buffers behind the rows tag_items could not make navigable.
---
--- Only those. The decompiled buffers behind navigable rows are what the list previews, and a blanket
--- sweep over every `jar:`/`jrt:` name also caught the buffer `grr` was pressed in when that was a
--- decompiled class -- leaving `q` with no origin to restore. `uri_to_bufnr` looks the buffer up by
--- the same name locations_to_items gave it, so this never creates one; a buffer shown in a window is
--- left alone because wiping it would yank that window somewhere else.
--- @param items table[] prepared rows
local function wipe_unopenable_buffers(items)
  for _, item in ipairs(items) do
    if item.valid == 0 then
      local uri = vim.tbl_get(item, 'user_data', 'uri') or vim.tbl_get(item, 'user_data', 'targetUri')
      local buf = uri and vim.uri_to_bufnr(uri)
      if buf and vim.fn.bufwinid(buf) == -1 then
        pcall(vim.api.nvim_buf_delete, buf, { force = true, unload = false })
      end
    end
  end
end

--- The window to preview in.
---
--- Normally the window `grr` was pressed in. If that window is gone -- closed while browsing, or grr
--- pressed in a split the user then closed -- fall back to any non-quickfix window in the tab.
--- Without the validity check, every preview after such a close raises E5555 from nvim_win_call on an
--- invalid handle.
---
--- Never splits: creating windows from a CursorMoved handler is how layouts get mangled. Returns nil
--- instead, and preview simply does nothing.
--- @return integer|nil
local function preview_win()
  local function usable(win)
    if not win or not vim.api.nvim_win_is_valid(win) then return false end
    return vim.bo[vim.api.nvim_win_get_buf(win)].buftype ~= 'quickfix'
  end

  if usable(state.origin.win) then return state.origin.win end

  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if usable(win) then return win end
  end
  return nil
end

--- Shows `item` in the editor window and flashes its match range.
--- @param item table quickfix entry with bufnr/lnum/col
local function preview(item)
  local win = preview_win()
  if not win or not item or item.valid == 0 or not item.bufnr then return end
  if not vim.api.nvim_buf_is_valid(item.bufnr) then return end

  local buf = item.bufnr
  vim.fn.bufload(buf)

  -- bufload does NOT run filetype detection, and neither does displaying the buffer in a window, so
  -- without this the preview renders as unhighlighted plain text -- which defeats the point of it.
  -- Skipped when already detected, since this runs on every step.
  if vim.bo[buf].filetype == '' then
    vim.api.nvim_buf_call(buf, function() vim.cmd('filetype detect') end)
  end

  -- `keepjumps keepalt buffer N`, not nvim_win_set_buf and not `:edit`:
  --
  --   * nvim_win_set_buf pushes a jumplist entry per call, so twenty j presses leave twenty junk
  --     entries and <C-o> no longer walks back to where the user actually was.
  --   * `:edit` additionally rewrites the alternate file, so <C-^> starts pointing at whichever
  --     reference happened to be previewed last.
  --   * `keepjumps keepalt` suppresses both.
  --
  -- 'eventignore' is deliberately NOT set around this: suppressing events would skip FileType and
  -- kill syntax in the preview. That means the plugin's own FileType autocmd fires and
  -- start_for_buffer attaches the buffer, which is intended -- find_root resolves to the same root,
  -- vim.lsp.start reuses the running client rather than spawning a second server, and the
  -- buffer-local intellij_lsp_attached guard makes a re-preview a no-op. The cost is one didOpen per
  -- file, which is what a real jump would have cost anyway.
  local ok = pcall(vim.api.nvim_win_call, win, function()
    vim.cmd('keepjumps keepalt buffer ' .. buf)
    local lnum = math.min(item.lnum or 1, vim.api.nvim_buf_line_count(buf))
    vim.api.nvim_win_set_cursor(win, { math.max(lnum, 1), math.max((item.col or 1) - 1, 0) })
    vim.cmd('normal! zz')
  end)
  if not ok then return end

  -- Re-asserted AFTER the switch: showing a buffer in a window lists it, so bufadd's unlisted state
  -- does not survive on its own. Keeps :ls free of every file scrolled past while browsing.
  vim.bo[buf].buflisted = false

  -- Ordered strictly after bufload, or the range clamps against a zero-line buffer. `timeout` makes
  -- vim.hl.range clear itself, so there is no timer to own here.
  if item.col and item.end_col and item.end_col > item.col then
    local lnum = math.min(item.lnum or 1, vim.api.nvim_buf_line_count(buf)) - 1
    pcall(vim.hl.range, buf, ns_flash, 'IntellijLspReferenceMatch',
      { lnum, item.col - 1 }, { lnum, item.end_col - 1 }, { timeout = FLASH_MS })
  end
end

--- Highlights the matched identifier inside the selected quickfix row.
--- @param idx integer 1-based quickfix index
local function highlight_qf_row(idx)
  local buf = state.qf_buf
  if not vim.api.nvim_buf_is_valid(buf) then return end
  vim.api.nvim_buf_clear_namespace(buf, ns_qf, 0, -1)

  local item = state.items[idx]
  if not item or item.valid == 0 or not item.text then return end
  -- A multi-line range would need a different treatment; clamp to this line rather than guess.
  if item.end_lnum and item.lnum and item.end_lnum ~= item.lnum then return end

  local rendered = vim.api.nvim_buf_get_lines(buf, idx - 1, idx, false)[1]
  if not rendered then return end

  local s, e = qf_line_range(rendered, item.text, item.col, item.end_col)
  if not s then return end

  pcall(vim.api.nvim_buf_set_extmark, buf, ns_qf, idx - 1, s, {
    end_col = e,
    hl_group = 'IntellijLspReferenceMatch',
    -- Beats the qfText syntax match, which would otherwise paint over the range.
    priority = vim.hl.priorities.user,
  })
end

--- Points quickfix's own selection at `idx`.
---
--- Without this the 'QuickFixLine' bar stays pinned to entry 1 for the whole session: quickfix only
--- advances its index on :cc/:cnext, while j/k move nothing but the cursor. The result is two
--- disagreeing "you are here" markers -- a stale highlighted row and a live match highlight -- which
--- reads as a bug even though the preview is following correctly.
---
--- An empty item list with `'r'` updates the index *only*: items, title, resolved bufnrs, the window's
--- cursor and our extmarks all survive, and it costs ~2.5us on a 500-entry list, which is why it is
--- affordable on every CursorMoved.
---
--- Invalid (unopenable library) rows are skipped rather than selected. Quickfix's own :cnext refuses to land on
--- them, so pointing idx at one would put the bar somewhere :cc could never go.
--- @param idx integer 1-based quickfix index
local function sync_qf_idx(idx)
  local item = state.items[idx]
  if not item or item.valid == 0 then return end
  if vim.fn.getqflist({ idx = 0 }).idx == idx then return end
  pcall(vim.fn.setqflist, {}, 'r', { idx = idx })
end

--- Reacts to the selection moving: highlight now, preview after the debounce settles.
local function on_cursor_moved()
  if not state then return end
  local win = vim.api.nvim_get_current_win()
  if not vim.api.nvim_win_is_valid(win) then return end

  local idx = vim.api.nvim_win_get_cursor(win)[1]
  sync_qf_idx(idx)
  highlight_qf_row(idx)

  state.timer:stop()
  state.timer:start(DEBOUNCE_MS, 0, function()
    -- Runs on the libuv thread, where API calls are illegal.
    vim.schedule(function()
      -- Both the window and the cursor row can have changed -- or the list closed -- between the
      -- timer firing and this callback running, so nothing captured above is trusted here.
      if not state or not vim.api.nvim_win_is_valid(state.qf_win) then return end
      local row = vim.api.nvim_win_get_cursor(state.qf_win)[1]
      preview(state.items[row])
    end)
  end)
end

-- -------------------------------------------------------------------------------------------------
-- Lifecycle
-- -------------------------------------------------------------------------------------------------

--- Whether a browsing session is open.
--- @return boolean
function M.is_open()
  return state ~= nil
end

--- Tears the session down.
---
--- Idempotent and safe to call from an autocmd, which is why every step is guarded and the restore is
--- wrapped: a failure there would surface as an E5108 unrelated to whatever the user just did.
--- @param restore boolean|nil rewind the origin window to its pre-grr position
function M.close(restore)
  local s = state
  if not s then return end
  -- Dropped first, so the autocmds this teardown triggers see a closed session and return early.
  state = nil

  if s.timer then
    s.timer:stop()
    if not s.timer:is_closing() then s.timer:close() end
  end

  if vim.api.nvim_buf_is_valid(s.qf_buf) then
    vim.api.nvim_buf_clear_namespace(s.qf_buf, ns_qf, 0, -1)
  end

  -- Takes the buffer-local CursorMoved and the teardown autocmds with it.
  pcall(vim.api.nvim_del_augroup_by_id, s.augroup)

  if vim.api.nvim_win_is_valid(s.qf_win) then
    pcall(vim.cmd.cclose)
  end

  if restore and vim.api.nvim_win_is_valid(s.origin.win) then
    pcall(function()
      local buf = s.origin.buf
      if vim.api.nvim_buf_is_valid(buf) then
        vim.api.nvim_buf_clear_namespace(buf, ns_flash, 0, -1)
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

--- Installs keymaps and autocmds on the quickfix buffer.
local function attach_qf(qf_buf, qf_win, augroup)
  local function map(lhs, rhs, desc)
    vim.keymap.set('n', lhs, rhs, { buffer = qf_buf, nowait = true, desc = desc })
  end

  map('<CR>', function()
    local idx = vim.api.nvim_win_get_cursor(0)[1]
    -- close() before :cc so the list is gone when the jump lands, and so the jump itself *does* push
    -- the jumplist -- unlike the previews, this one the user asked for.
    M.close(false)
    pcall(vim.cmd, idx .. 'cc')
  end, 'Jump to this reference')

  map('q', function() M.close(true) end, 'Close and restore position')
  map('<Esc>', function() M.close(true) end, 'Close and restore position')

  -- Buffer-local, not `pattern = 'quickfix'` on a global group. The quickfix buffer number is stable
  -- across cclose/copen -- only the window id changes -- so this survives the user toggling the list.
  -- It also means other quickfix lists (:grep, trouble.nvim) never see the handler at all.
  vim.api.nvim_create_autocmd('CursorMoved', {
    group = augroup,
    buffer = qf_buf,
    callback = on_cursor_moved,
    desc = 'Preview the selected reference',
  })

  -- Leaving the list without `q` must not rewind the editor: the user may have navigated there
  -- deliberately. So restore = false on every path except the explicit q/<Esc> above.
  vim.api.nvim_create_autocmd({ 'BufWinLeave', 'BufWipeout' }, {
    group = augroup,
    buffer = qf_buf,
    callback = function() M.close(false) end,
    desc = 'Tear down reference browsing',
  })

  vim.api.nvim_create_autocmd('WinClosed', {
    group = augroup,
    pattern = tostring(qf_win),
    callback = function() M.close(false) end,
    desc = 'Tear down reference browsing',
  })
end

--- Requests references for the cursor position and opens the browsing list.
--- @param opts? { include_declaration?: boolean }
function M.run(opts)
  opts = opts or {}

  local clients = vim.lsp.get_clients({ bufnr = 0, method = 'textDocument/references' })
  if #clients == 0 then
    vim.notify('IntelliJ LSP: no client supports references here.', vim.log.levels.WARN)
    return
  end

  -- Captured BEFORE the request, not inside on_list: the callback is async and the user may have
  -- moved the cursor by the time it fires.
  local origin = {
    win = vim.api.nvim_get_current_win(),
    buf = vim.api.nvim_get_current_buf(),
    cursor = vim.api.nvim_win_get_cursor(0),
  }

  -- A second grr while browsing replaces the session rather than stacking one.
  M.close(false)

  local include = opts.include_declaration
  if include == nil then include = true end

  -- on_list rather than a hand-rolled buf_request_all: locations_to_items has already done the
  -- utf-16 -> byte column conversion via vim.str_byteindex, which is easy to get wrong by hand.
  vim.lsp.buf.references({ includeDeclaration = include }, {
    on_list = function(list)
      -- The list does not say which client answered; with one server per buffer, the first is it.
      local items, unopenable = tag_items(list.items or {}, clients[1].offset_encoding)

      if unopenable > 0 then wipe_unopenable_buffers(items) end

      if #items == 0 then
        vim.notify('IntelliJ LSP: no references found.', vim.log.levels.INFO)
        return
      end

      vim.fn.setqflist({}, ' ', { title = list.title or 'References', items = items })
      vim.cmd('botright copen')

      local qf_win = vim.api.nvim_get_current_win()
      local qf_buf = vim.api.nvim_win_get_buf(qf_win)
      local augroup = vim.api.nvim_create_augroup('IntellijLspReferences', { clear = true })

      -- getqflist() rather than the items we passed in: quickfix resolves filenames to bufnrs, and
      -- preview needs those. Reading them back also keeps indices aligned with the rendered rows.
      state = {
        items = vim.fn.getqflist(),
        qf_win = qf_win,
        qf_buf = qf_buf,
        augroup = augroup,
        origin = origin,
        timer = vim.uv.new_timer(),
      }

      attach_qf(qf_buf, qf_win, augroup)

      -- Select and preview the first entry, so the feature is useful before any keypress.
      pcall(vim.api.nvim_win_set_cursor, qf_win, { 1, 0 })
      sync_qf_idx(1)
      highlight_qf_row(1)
      preview(state.items[1])

      if unopenable > 0 then
        vim.schedule(function()
          vim.notify(
            ('IntelliJ LSP: %d reference(s) in libraries/JDK could not be opened; enable '
              .. '`decompiler` to browse them as source.'):format(unopenable),
            vim.log.levels.INFO
          )
        end)
      end
    end,
  })
end

return M
