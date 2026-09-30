--- The log window: a commit list, with the selected commit's affected files previewed.
---
--- Built on `session.lua`, so the preview/debounce/teardown behaviour is identical to the status panel
--- and to reference browsing. What is specific here:
---
---   * Rows are a mix of commits and graph-only decoration, so the row map is sparse in a way the
---     status panel's never was -- `|\` is a real row with no commit behind it.
---   * The preview is a **rendered file list**, not a patch. Stepping through a log, the question is
---     "what did this commit touch?", and a raw `+`/`-` patch has to be read rather than glanced at.
---     The patch is one keypress away: `<CR>` opens the detail view.
---   * The page is bounded and extends on demand. Not a preference: unbounded `git log --graph`
---     on a large history can run for minutes and emit millions of lines.
---   * The path filter is slow enough on a large history (worst on a rarely-touched or mistyped
---     path) that it gets an in-flight message; the others feel synchronous.

local branches = require('intellij-lsp.git.branches')
local cmd = require('intellij-lsp.git.cmd')
local filelist = require('intellij-lsp.git.filelist')
local log = require('intellij-lsp.git.log')
local filter = require('intellij-lsp.git.filter')
local session = require('intellij-lsp.git.session')

local M = {}

local ns = vim.api.nvim_create_namespace('intellij-lsp.git.logview')


--- @type IntellijGitSession|nil
local state = nil

--- Live view state, kept beside the session rather than inside it.
--- @type table
local view = { filter = filter.empty(), rows = {}, limit = log.PAGE_SIZE, exhausted = false }

-- -------------------------------------------------------------------------------------------------
-- Rendering (pure; exposed for the tests)
-- -------------------------------------------------------------------------------------------------

--- Truncates to a display width, adding an ellipsis.
---
--- Uses `strcharpart`/`strdisplaywidth` rather than `sub`: a byte-wise cut through a multi-byte author
--- name or subject produces a broken character, and CJK subjects are double-width so a byte count is
--- not a column count either.
--- @param s string
--- @param width integer
--- @return string
function M._truncate(s, width)
  s = s or ''
  if vim.fn.strdisplaywidth(s) <= width then return s end
  if width <= 1 then return '…' end
  -- Walk back from a character-count estimate until it fits: display width is not invertible.
  local chars = vim.fn.strchars(s)
  while chars > 0 do
    local cut = vim.fn.strcharpart(s, 0, chars)
    if vim.fn.strdisplaywidth(cut) <= width - 1 then return cut .. '…' end
    chars = chars - 1
  end
  return '…'
end

--- Right-pads to a display width.
--- @param s string
--- @param width integer
--- @return string
local function pad(s, width)
  local w = vim.fn.strdisplaywidth(s or '')
  if w >= width then return s end
  return s .. string.rep(' ', width - w)
end

--- Renders the ref decorations for a commit, e.g. `(HEAD -> main, v1.0)`.
--- @param refs string
--- @return string text
--- @return table[] spans { offset, len, hl } relative to the returned text
function M._render_refs(refs)
  local parsed = log.parse_refs(refs)
  if #parsed == 0 then return '', {} end

  local HL = {
    head = 'IntellijGitLogHead',
    tag = 'IntellijGitLogTag',
    remote = 'IntellijGitLogRemote',
    branch = 'IntellijGitLogBranch',
  }

  local text, spans = '(', {}
  for i, ref in ipairs(parsed) do
    if i > 1 then text = text .. ', ' end
    spans[#spans + 1] = { offset = #text, len = #ref.name, hl = HL[ref.kind] }
    text = text .. ref.name
  end
  return text .. ')', spans
end

--- Builds the buffer lines, row map and highlights.
--- @param rows table[] from log.parse
--- @param opts { filter?: IntellijGitFilter, exhausted?: boolean, loading?: string, width?: integer }
--- @return string[] lines
--- @return table<integer, table> row -> commit
--- @return table[] highlights
function M._render(rows, opts)
  opts = opts or {}
  local lines, map, hls = {}, {}, {}

  local function add(text, hl)
    lines[#lines + 1] = text
    if hl then hls[#hls + 1] = { row = #lines - 1, hl = hl } end
    return #lines
  end

  local desc = filter.describe(opts.filter)
  add(('Log%s'):format(desc and ('  ·  ' .. desc) or ''), 'IntellijGitLogHeader')
  if opts.loading then
    add('  ' .. opts.loading, 'IntellijGitLogDate')
  end
  add('')

  -- Author and date are fixed-width so the subject column aligns; the graph is variable and stays on
  -- the left where git drew it.
  local AUTHOR_W, DATE_W = 16, 14

  for _, row in ipairs(rows) do
    if not row.commit then
      -- Graph-only decoration: rendered verbatim, mapped to nothing.
      add(row.graph, 'IntellijGitLogGraph')
    else
      local c = row.commit
      local ref_text, ref_spans = M._render_refs(c.refs)

      local prefix = row.graph .. c.short .. ' '
      local line = prefix
        .. pad(M._truncate(c.author, AUTHOR_W), AUTHOR_W) .. ' '
        .. pad(M._truncate(c.date, DATE_W), DATE_W) .. ' '
      local ref_at = #line
      if ref_text ~= '' then line = line .. ref_text .. ' ' end
      local subject_at = #line
      line = line .. c.subject

      local lnum = add(line)
      map[lnum] = c

      local r0 = lnum - 1
      -- Column highlights, so the graph, hash, author and date read as distinct columns rather than
      -- one wall of text. Byte offsets, which is what extmarks want.
      if #row.graph > 0 then
        hls[#hls + 1] = { row = r0, col = 0, end_col = #row.graph, hl = 'IntellijGitLogGraph' }
      end
      hls[#hls + 1] = {
        row = r0, col = #row.graph, end_col = #row.graph + #c.short, hl = 'IntellijGitLogHash',
      }
      hls[#hls + 1] = {
        row = r0, col = #prefix, end_col = #prefix + AUTHOR_W, hl = 'IntellijGitLogAuthor',
      }
      hls[#hls + 1] = {
        row = r0, col = #prefix + AUTHOR_W + 1, end_col = subject_at, hl = 'IntellijGitLogDate',
      }
      for _, span in ipairs(ref_spans) do
        hls[#hls + 1] = {
          row = r0, col = ref_at + span.offset, end_col = ref_at + span.offset + span.len,
          hl = span.hl,
        }
      end
    end
  end

  if #rows == 0 then
    add('')
    add(filter.is_active(opts.filter)
      and '  no commits match this filter'
      or '  no commits', 'IntellijGitLogDate')
  elseif not opts.exhausted then
    add('')
    add('  press + to load more', 'IntellijGitLogDate')
  end

  return lines, map, hls
end

-- -------------------------------------------------------------------------------------------------
-- Preview
-- -------------------------------------------------------------------------------------------------

--- Renders a commit as its message plus a colour-coded list of affected files.
---
--- Deliberately not the patch. `--patch-with-stat` answers "what exactly changed", which for anything
--- larger than a one-line fix is a wall of `+`/`-` that has to be read rather than glanced at -- and
--- while stepping through a log the question is almost always "what did this commit touch?". The patch
--- is still one keypress away: `<CR>` opens the detail view, where selecting a file shows its diff.
---
--- Colours follow the diff convention already used by the status panel, so added/deleted/modified read
--- the same everywhere in the plugin.
--- @param c table commit
--- @param files table[] from log.fetch_files
--- @return string[] lines
--- @return table[] highlights { row, col?, end_col?, hl }
function M._render_files(c, files)
  local lines, hls = {}, {}

  local function add(text, hl)
    lines[#lines + 1] = text
    if hl then hls[#hls + 1] = { row = #lines - 1, hl = hl } end
    return #lines
  end

  add(('%s  %s'):format(c.short, c.subject), 'IntellijGitFileSubject')
  add(('%s · %s'):format(c.author, c.date), 'IntellijGitFileMeta')
  add('')

  if #files == 0 then
    -- A merge with no conflicts touches nothing on its own, and so does an empty commit. Saying which
    -- is more useful than an empty pane that looks like a failure.
    add('  no files changed (merge, or an empty commit)', 'IntellijGitFileMeta')
    return lines, hls
  end

  -- Totals first, so the size of the change is apparent before reading any path.
  local summary_text, summary_spans = filelist.summary(files)
  local srow = add(summary_text) - 1
  for _, sp in ipairs(summary_spans) do
    hls[#hls + 1] = { row = srow, col = sp.col, end_col = sp.end_col, hl = sp.hl }
  end
  add('')

  -- Rows come from the shared renderer, so this list and the commit detail view cannot drift into
  -- colouring the same data differently.
  for _, f in ipairs(files) do
    local text, spans = filelist.row(f)
    local r = add(text) - 1
    for _, sp in ipairs(spans) do
      hls[#hls + 1] = { row = r, col = sp.col, end_col = sp.end_col, hl = sp.hl }
    end
  end

  return lines, hls
end

--- @param s IntellijGitSession
--- @param c table
local function preview(s, c)
  local seq = session.next_seq(s)
  log.fetch_files(s.root, c.hash, function(files, err)
    -- Async answers can arrive out of order; a response for a row the cursor has left is dropped.
    if not session.is_current(s, seq) then return end

    if not files then
      session.render_preview(s, { '# ' .. tostring(err) }, 'text')
      return
    end

    local lines, hls = M._render_files(c, files)
    -- `text`, not `diff`: this is a rendered list, and the diff syntax rules would colour any path
    -- starting with `-` or `+` as a patch line.
    if session.render_preview(s, lines, 'text') then
      session.highlight_preview(s, hls, ns)
    end
  end)
end

-- -------------------------------------------------------------------------------------------------
-- Loading
-- -------------------------------------------------------------------------------------------------

--- Fetches and repaints, preserving the cursor row.
--- @param opts { keep_cursor?: boolean }|nil
local function reload(opts)
  if not session.is_open(state) then return end
  opts = opts or {}

  local row = opts.keep_cursor and vim.api.nvim_win_get_cursor(state.win)[1] or nil

  -- The path filter is slow enough to look like a hang (~0.56s, and worst on a mistyped path, which
  -- walks all of history). Repaint with an in-flight line first so the delay is explained.
  if filter.is_slow(view.filter) then
    local lines, map, hls = M._render(view.rows, {
      filter = view.filter,
      exhausted = view.exhausted,
      loading = 'searching history…',
    })
    session.fill(state, lines, map, hls, ns)
  end

  local seq = session.next_seq(state)
  log.fetch(state.root, {
    limit = view.limit,
    filter_args = filter.args(view.filter),
    path_args = filter.path_args(view.filter),
    range = filter.range(view.filter),
  }, function(rows, err)
    if not session.is_current(state, seq) then return end
    if not rows then
      vim.notify('IntelliJ git: ' .. tostring(err), vim.log.levels.ERROR)
      return
    end

    -- Fewer commits than requested means history (or the filter) is exhausted, so the "load more"
    -- hint is dropped rather than offering a page that will come back identical.
    local commits = 0
    for _, r in ipairs(rows) do
      if r.commit then commits = commits + 1 end
    end
    view.rows = rows
    view.exhausted = commits < view.limit

    local lines, map, hls = M._render(rows, {
      filter = view.filter,
      exhausted = view.exhausted,
    })
    session.fill(state, lines, map, hls, ns)

    if row then
      local last = vim.api.nvim_buf_line_count(state.buf)
      pcall(vim.api.nvim_win_set_cursor, state.win, { math.min(row, last), 0 })
    else
      session.select_first(state)
    end
  end)
end

--- Doubles the page size and reloads.
---
--- Doubling rather than adding a page: fetch cost is dominated by the fixed overhead (0.02s at 100
--- commits, 0.04s at 2000), so re-fetching a larger window is cheaper and much simpler than splicing
--- a second page onto the first -- and splicing is not actually possible here, because the graph lanes
--- of page N+1 are drawn relative to page N's commits and cannot be concatenated.
local function load_more()
  if not session.is_open(state) or view.exhausted then return end
  view.limit = view.limit * 2
  reload({ keep_cursor = true })
end

-- -------------------------------------------------------------------------------------------------
-- Filters
-- -------------------------------------------------------------------------------------------------

--- Prompts for a filter value and reloads.
--- @param key string field on the filter table
--- @param label string
local function prompt_filter(key, label)
  if not session.is_open(state) then return end
  vim.ui.input({ prompt = label .. ': ', default = view.filter[key] or '' }, function(value)
    if value == nil then return end
    view.filter[key] = value ~= '' and value or nil
    -- A new filter invalidates the page size: keeping a grown limit would re-run an expensive query
    -- for a result set the user has not seen yet.
    view.limit = log.PAGE_SIZE
    reload()
  end)
end

local function clear_filters()
  if not session.is_open(state) then return end
  view.filter = filter.empty()
  view.limit = log.PAGE_SIZE
  reload()
end

-- -------------------------------------------------------------------------------------------------
-- Branch switching, without leaving the log
-- -------------------------------------------------------------------------------------------------

--- Runs a checkout and repaints the log around it.
---
--- The repaint is not cosmetic: `HEAD` moved, so the decorations are stale, and on a checkout that
--- changed which commits are reachable the whole list is wrong. `checktime` is what keeps open buffers
--- honest -- it reloads unmodified ones and warns about modified ones, so files that changed on disk
--- refresh while unsaved edits are never silently discarded.
--- @param branch table
local function do_checkout(branch)
  local root = state.root
  branches.checkout(root, branch, function(ok, message)
    vim.notify('IntelliJ git: ' .. message, ok and vim.log.levels.INFO or vim.log.levels.ERROR)
    if not ok then return end
    vim.cmd('checktime')
    -- Cursor is deliberately not kept: after a switch the row under it is likely a different commit,
    -- so landing on the new HEAD is both more useful and less misleading.
    reload()
  end)
end

--- Branch names decorating the selected commit.
---
--- `parse_refs` keeps the `HEAD -> ` arrow in the name, which is right for display but not for a
--- checkout argument, so it is stripped here. Tags are excluded: checking one out detaches HEAD, which
--- is not what picking a branch off a log row means.
--- @param c table|nil
--- @return string[]
function M._branches_at(c)
  if not c then return {} end
  local names = {}
  for _, ref in ipairs(log.parse_refs(c.refs)) do
    if ref.kind ~= 'tag' then
      local name = ref.name:gsub('^HEAD %-> ', '')
      -- A bare `HEAD` (detached) is not a branch, and `origin/HEAD` is a symbolic ref that would
      -- detach if checked out.
      if name ~= 'HEAD' and not name:match('/HEAD$') then
        names[#names + 1] = name
      end
    end
  end
  return names
end

--- Switches branches from inside the log.
---
--- Two cases, because both are things a user means by "switch branch here" and guessing wrong is
--- annoying either way:
---
---   * The selected commit **is** a branch tip -- one decorating branch switches straight to it, several
---     ask which. This is the "click the branch in the graph" gesture.
---   * The selected commit is not a tip, or `b` is pressed with no commit selected: fall back to a
---     picker over every branch, which is the same choice `:IntellijGitBranches` offers without leaving
---     the log.
local function switch_branch()
  if not session.is_open(state) then return end
  local root = state.root

  local at = M._branches_at(session.current(state))

  branches.fetch(root, function(list, err)
    if not list then
      vim.notify('IntelliJ git: ' .. tostring(err), vim.log.levels.ERROR)
      return
    end

    -- The single-branch fast path has to consult the real branch list first. Pressing `b` on the HEAD
    -- row decorates exactly one branch -- the one already checked out -- so shortcutting on `#at == 1`
    -- alone "switches" to where you already are and never opens the picker, which is a silent no-op on
    -- the most obvious row to try it from.
    if #at == 1 then
      local only
      for _, b in ipairs(list) do
        if b.name == at[1] then only = b end
      end
      if only and not only.current then
        do_checkout(only)
        return
      end
      -- Fall through to the picker: the sole branch here is the current one, so there is nothing to
      -- switch to at this commit and the useful answer is "which branch, then?".
    end

    --- Drops the checked-out branch: it is the one entry that cannot do anything.
    local function switchable(candidates)
      local out = {}
      for _, b in ipairs(candidates) do
        if not b.current then out[#out + 1] = b end
      end
      return out
    end

    local selectable = switchable(list)

    -- Several branches decorate this commit: offer just those, since the user pointed at them. Narrowed
    -- only when something switchable remains -- otherwise the narrow set is all-current and the picker
    -- would come up empty, which reads as the key being broken.
    if #at > 1 then
      local wanted, here = {}, {}
      for _, n in ipairs(at) do wanted[n] = true end
      for _, b in ipairs(list) do
        if wanted[b.name] then here[#here + 1] = b end
      end
      local narrowed = switchable(here)
      if #narrowed > 0 then selectable = narrowed end
    end

    if #selectable == 0 then
      vim.notify('IntelliJ git: no other branch to switch to.', vim.log.levels.WARN)
      return
    end

    vim.ui.select(selectable, {
      prompt = 'Switch to branch',
      format_item = function(b)
        local tail = b.upstream and (' → ' .. b.upstream) or ''
        return ('%s  (%s)%s'):format(b.name, b.date, tail)
      end,
    }, function(choice)
      if choice then do_checkout(choice) end
    end)
  end)
end

-- -------------------------------------------------------------------------------------------------
-- Lifecycle
-- -------------------------------------------------------------------------------------------------

--- @return boolean
function M.is_open()
  return session.is_open(state)
end

function M.close(restore)
  session.close(state, restore)
  state = nil
end

--- The commit under the cursor, for tests and for the detail view.
--- @return table|nil
function M.current()
  return session.current(state)
end

--- Opens the log view.
--- @param range string|nil revision range
function M.open(range)
  local root = cmd.root()
  if not root then
    vim.notify('IntelliJ git: not inside a git repository.', vim.log.levels.WARN)
    return
  end

  M.close(false)

  view = {
    filter = filter.empty(),
    rows = {},
    limit = log.PAGE_SIZE,
    exhausted = false,
  }
  if range and range ~= '' then view.filter.range = range end

  state = session.open({
    root = root,
    name = 'intellij-git://log',
    filetype = 'intellij-git-log',
    -- Bottom, like the status panel. A `botright split` spans the full editor width, so the graph,
    -- hash, author, date and subject columns actually get *more* room than in a right-hand vertical
    -- split -- the concern that originally made this vertical does not apply to a full-width strip.
    -- 18 rather than the status panel's 15: the log is the thing you scroll, so a few more rows of
    -- history are worth the space.
    height = 18,
  })

  state.on_preview = preview
  state.on_select = function(_, c)
    require('intellij-lsp.git.commit').open(root, c.hash)
  end

  session.attach(state, {
    ['+'] = load_more,
    ['/'] = function() prompt_filter('text', 'Filter by message') end,
    ['a'] = function() prompt_filter('author', 'Filter by author') end,
    ['f'] = function() prompt_filter('path', 'Filter by path') end,
    ['r'] = function() prompt_filter('range', 'Revision range') end,
    ['c'] = clear_filters,
    -- `b` switches branches without leaving the log: straight to the branch decorating the selected
    -- commit when there is exactly one, otherwise a picker.
    ['b'] = switch_branch,
    ['R'] = function() reload({ keep_cursor = true }) end,
    ['q'] = function() M.close(true) end,
    ['<Esc>'] = function() M.close(true) end,
  })

  reload()
end

M._view = function() return view end

return M
