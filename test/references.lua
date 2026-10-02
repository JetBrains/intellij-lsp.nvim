-- Checks for reference browsing: quickfix range math, jar:/jrt: handling, preview state hygiene,
-- and session lifecycle. No server required -- the quickfix list is populated by hand.
--
--   nvim --headless -u NONE -l test/references.lua
vim.opt.runtimepath:prepend(vim.fs.dirname(vim.fs.dirname(debug.getinfo(1, 'S').source:sub(2))))

local refs = require('intellij-lsp.references')

local failures = 0
local function check(name, cond, detail)
  if cond then
    print('ok   ' .. name)
  else
    failures = failures + 1
    print('FAIL ' .. name .. (detail and ('  -> ' .. tostring(detail)) or ''))
  end
end

-- -------------------------------------------------------------------------------------------------
-- qf_line_range, exercised through a real setqflist + copen
-- -------------------------------------------------------------------------------------------------
-- Driven through the actual renderer rather than a model of it: the whole point of the suffix
-- anchoring is that the prefix width is not predictable, so a hand-built "expected" line would test
-- the wrong thing.

--- Renders one entry, then extracts what qf_line_range points at.
--- @return string|nil extracted substring, or nil when the range was rejected
local function extract(filename, stored, col, end_col)
  vim.fn.setqflist({
    { filename = filename, lnum = 1, col = col, end_col = end_col, text = stored, valid = 1 },
  }, 'r')
  vim.cmd('copen')
  local rendered = vim.api.nvim_buf_get_lines(0, 0, 1, false)[1]
  vim.cmd('cclose')
  local s, e = refs._qf_line_range(rendered, stored, col, end_col)
  if not s then return nil end
  return rendered:sub(s + 1, e)
end

check('space-indented line', extract('/tmp/A.java', '        Greeter g = new Greeter();', 9, 16) == 'Greeter',
  extract('/tmp/A.java', '        Greeter g = new Greeter();', 9, 16))

-- Byte count, not display width: a naive strdisplaywidth() implementation gets this wrong, because a
-- tab renders as several columns but is one byte.
check('tab-indented line', extract('/tmp/A.java', '\t\tGreeter g;', 3, 10) == 'Greeter',
  extract('/tmp/A.java', '\t\tGreeter g;', 3, 10))
check('mixed tabs and spaces', extract('/tmp/A.java', '\t  \tGreeter g;', 5, 12) == 'Greeter',
  extract('/tmp/A.java', '\t  \tGreeter g;', 5, 12))
check('zero-indent line', extract('/tmp/A.java', 'Greeter g;', 1, 8) == 'Greeter',
  extract('/tmp/A.java', 'Greeter g;', 1, 8))
check('trailing whitespace preserved', extract('/tmp/A.java', '    Greeter g;   ', 5, 12) == 'Greeter',
  extract('/tmp/A.java', '    Greeter g;   ', 5, 12))

-- A file name containing `|` defeats every implementation that scans forward for the separators.
check('filename containing a pipe', extract('/tmp/Weird|Name.java', '    Greeter g;', 5, 12) == 'Greeter',
  extract('/tmp/Weird|Name.java', '    Greeter g;', 5, 12))

-- The identifier also appears twice in the path, so a plain string search would land in the prefix.
check('identifier repeated in the path',
  extract('/tmp/Greeter/Greeter.java', '    Greeter g = new Greeter();', 5, 12) == 'Greeter',
  extract('/tmp/Greeter/Greeter.java', '    Greeter g = new Greeter();', 5, 12))

-- Degenerate inputs: nil rather than a wrong extmark.
check('end_col <= col rejected', refs._qf_line_range('a|1| x', 'x', 5, 5) == nil)
check('nil columns rejected', refs._qf_line_range('a|1| x', 'x', nil, nil) == nil)
check('range past end of line rejected',
  refs._qf_line_range('/tmp/A.java|1 col 1| Greeter', '    Greeter g;', 5, 400) == nil)
-- Simulates a foreign 'quickfixtextfunc': the trimmed text is no longer the rendered line's tail.
check('garbage prefix rejected (quickfixtextfunc)',
  refs._qf_line_range('totally unrelated rendering', '    Greeter g;', 5, 12) == nil)

-- -------------------------------------------------------------------------------------------------
-- jar:/jrt: partitioning
-- -------------------------------------------------------------------------------------------------
check('is_external: jar', refs._is_external('jar:file:///l/lib.jar!/com/E.class') == true)
check('is_external: jrt', refs._is_external('jrt:/java.base/java/lang/String.class') == true)
check('is_external: file', refs._is_external('file:///tmp/A.java') == false)

check('external_label: jar tail',
  refs._external_label('jar:file:///l/lib.jar!/com/E.class') == 'lib.jar!/com/E.class',
  refs._external_label('jar:file:///l/lib.jar!/com/E.class'))
check('external_label: jrt tail',
  refs._external_label('jrt:/java.base/java/lang/String.class') == 'java.base/java/lang/String.class',
  refs._external_label('jrt:/java.base/java/lang/String.class'))

-- Stands in for what locations_to_items leaves behind: a buffer per external URI, which the
-- decompiler's BufReadCmd filled (the jar: row) or nothing did (the jrt: row). The jar: item carries
-- the empty text and clamped columns Neovim really produces for that scheme (see is_external), so
-- this checks that the row is rebuilt from the buffer rather than trusted.
local JAR = 'jar:file:///l/lib.jar!/com/E.class'
local jar_buf = vim.uri_to_bufnr(JAR)
vim.fn.bufload(jar_buf)
vim.api.nvim_buf_set_lines(jar_buf, 0, -1, false, { 'package com;', 'public class E {}' })
local empty_buf = vim.uri_to_bufnr('jrt:/java.base/java/lang/String.class')

local function rng(line, s, e)
  return { start = { line = line, character = s }, ['end'] = { line = line, character = e } }
end

local tagged, unopenable = refs._tag_items({
  { filename = '/tmp/A.java', lnum = 1, col = 1, end_col = 6, text = 'class A',
    user_data = { uri = 'file:///tmp/A.java', range = rng(0, 0, 5) } },
  { filename = '', lnum = 4, col = 1, end_col = 1, text = '',
    user_data = { uri = 'jrt:/java.base/java/lang/String.class', range = rng(3, 0, 5) } },
  { filename = '/tmp/B.java', lnum = 2, col = 1, end_col = 6, text = 'class B',
    user_data = { uri = 'file:///tmp/B.java', range = rng(1, 0, 5) } },
  { filename = vim.uri_to_fname(JAR), lnum = 2, col = 1, end_col = 1, text = '',
    user_data = { uri = JAR, range = rng(1, 13, 14) } },
}, 'utf-16')
check('only the unfilled row counted as unopenable', unopenable == 1, unopenable)
check('file items stay valid', tagged[1].valid == 1 and tagged[3].valid == 1)
check('unfilled library item marked invalid', tagged[2].valid == 0, tagged[2].valid)
check('unfilled library item has synthesized text', tagged[2].text ~= '' and tagged[2].text ~= nil,
  ('%q'):format(tostring(tagged[2].text)))
-- No filename: quickfix would otherwise resolve it against cwd, which is the phantom-buffer bug.
check('unfilled library item carries no filename', tagged[2].filename == nil, tagged[2].filename)

-- The decompiled row is navigable, and pinned to the buffer that already holds the source rather than
-- re-resolved from the cwd-prefixed name.
check('decompiled library item made valid', tagged[4].valid == 1, tagged[4].valid)
check('decompiled library item reads its text from the buffer', tagged[4].text == 'public class E {}',
  tagged[4].text)
check('decompiled library item recomputes its columns', tagged[4].col == 14 and tagged[4].end_col == 15,
  vim.inspect({ tagged[4].col, tagged[4].end_col }))
check('decompiled library item pinned by bufnr', tagged[4].bufnr == jar_buf and tagged[4].filename == nil,
  vim.inspect({ tagged[4].bufnr, jar_buf, tagged[4].filename }))

-- Round-trip: valid=0, the bufnr and the range columns have to survive quickfix, or the feature loses
-- its skip-invalid behaviour, its preview target or its extmarks.
vim.fn.setqflist({}, ' ', { title = 'References', items = tagged })
local got = vim.fn.getqflist()
check('valid=0 survives setqflist', got[2].valid == 0, got[2].valid)
check('end_col survives setqflist', got[1].end_col == 6, got[1].end_col)
check('library bufnr survives setqflist', got[4].bufnr == jar_buf, got[4].bufnr)
check('title survives', vim.fn.getqflist({ title = 0 }).title == 'References',
  vim.fn.getqflist({ title = 0 }).title)

-- Quickfix's own :cnext skips invalid entries, which is why unopenable rows can be kept as rows.
vim.fn.writefile({ 'class A', 'body' }, '/tmp/A.java')
vim.fn.writefile({ 'class B', 'body' }, '/tmp/B.java')
vim.cmd('cfirst')
vim.cmd('cnext')
check(':cnext skips the invalid row', vim.fn.getqflist({ idx = 0 }).idx == 3,
  vim.fn.getqflist({ idx = 0 }).idx)
-- ...and lands on the decompiled row, in its buffer, on the referenced line.
vim.cmd('cnext')
check(':cnext reaches the decompiled row', vim.fn.getqflist({ idx = 0 }).idx == 4,
  vim.fn.getqflist({ idx = 0 }).idx)
check(':cc enters the decompiled buffer',
  vim.api.nvim_get_current_buf() == jar_buf and vim.api.nvim_win_get_cursor(0)[1] == 2,
  vim.inspect({ vim.api.nvim_get_current_buf(), vim.api.nvim_win_get_cursor(0) }))
check('the unfilled buffer is left for the caller to wipe', vim.api.nvim_buf_is_valid(empty_buf))

-- Clean slate for the end-to-end section, which asserts on which library buffers exist.
for _, b in ipairs({ jar_buf, empty_buf }) do
  pcall(vim.api.nvim_buf_delete, b, { force = true, unload = false })
end

-- -------------------------------------------------------------------------------------------------
-- Preview state hygiene
-- -------------------------------------------------------------------------------------------------
-- The highest-value assertions here, because all three regress silently: nothing errors, the plugin
-- just quietly wrecks <C-o>, <C-^> and :ls.

local HYG = '/tmp/ijls-refs-hyg'
vim.fn.mkdir(HYG, 'p')
-- Line 2 is what the fake server's ranges below point into: `Greeter` at byte columns 5-11.
for i = 1, 3 do
  vim.fn.writefile({ 'class A' .. i, '    Greeter g = new Greeter();' }, HYG .. '/A' .. i .. '.java')
end

-- Two edits, so `#` holds a real prior file rather than being empty: an assertion that "" stayed ""
-- would pass for the wrong reason.
vim.cmd('edit ' .. HYG .. '/A2.java')
vim.cmd('edit ' .. HYG .. '/A1.java')
local origin_win = vim.api.nvim_get_current_win()
vim.cmd('clearjumps')
local alt_before = vim.fn.expand('#')

-- Mirrors what preview() does, so a regression there shows up here.
local previewed = {}
for i = 2, 3 do
  local buf = vim.fn.bufadd(HYG .. '/A' .. i .. '.java')
  vim.fn.bufload(buf)
  if vim.bo[buf].filetype == '' then
    vim.api.nvim_buf_call(buf, function() vim.cmd('filetype detect') end)
  end
  vim.api.nvim_win_call(origin_win, function() vim.cmd('keepjumps keepalt buffer ' .. buf) end)
  vim.bo[buf].buflisted = false
  previewed[i] = buf
end

check('previews leave the jumplist empty', #vim.fn.getjumplist()[1] == 0, #vim.fn.getjumplist()[1])
-- Scoped to the preview step on purpose. `:copen` itself rewrites the alternate file -- stock Neovim
-- behaviour that plain `grr` already has -- so only the buffer switch is ours to keep clean.
check('previews leave the alternate file alone', vim.fn.expand('#') == alt_before, vim.fn.expand('#'))
-- Showing a buffer in a window lists it, so bufadd's unlisted state does not survive on its own.
check('previewed buffer stays unlisted', vim.bo[previewed[3]].buflisted == false)
-- bufload does not run filetype detection, and neither does displaying the buffer.
check('previewed buffer has a filetype', vim.bo[previewed[3]].filetype == 'java',
  ('%q'):format(vim.bo[previewed[3]].filetype))

-- The contrast that motivates keepjumps: the obvious API pollutes.
vim.cmd('clearjumps')
vim.api.nvim_win_set_buf(origin_win, previewed[2])
check('nvim_win_set_buf would have polluted the jumplist', #vim.fn.getjumplist()[1] > 0,
  #vim.fn.getjumplist()[1])

-- -------------------------------------------------------------------------------------------------
-- Lifecycle
-- -------------------------------------------------------------------------------------------------
check('closed before any run', refs.is_open() == false)
-- Safe to call with no session; teardown runs from autocmds, so this path is real.
local ok_close = pcall(refs.close, true)
check('close() with no session is a no-op', ok_close)

-- The whole run() -> browse -> close() path, driven by an in-process fake server. Worth the setup:
-- everything above tests a helper in isolation, and the interesting failures (preview not following,
-- restore landing in the wrong buffer, teardown leaving an augroup behind) only appear end to end.
--- @return function
local function fake_server(locations)
  return function()
    local closing = false
    return {
      request = function(method, _, cb)
        if method == 'initialize' then
          cb(nil, { capabilities = { referencesProvider = true } })
        elseif method == 'textDocument/references' then
          cb(nil, locations)
        elseif method == 'shutdown' then
          cb(nil, nil)
        end
        return true, 1
      end,
      notify = function() return true end,
      is_closing = function() return closing end,
      terminate = function() closing = true end,
    }
  end
end

local function loc(path, line)
  return {
    uri = vim.uri_from_fname(path),
    range = { start = { line = line, character = 4 }, ['end'] = { line = line, character = 11 } },
  }
end

-- Stands in for decompiler.lua: fills a `jar:` buffer the way its BufReadCmd does, so the row behind
-- it is navigable. The `jrt:` URI below is deliberately left unclaimed, so that row stays empty and
-- exercises the fallback.
local DECOMPILED = { 'package com;', 'public class E {', '    Greeter g = new Greeter();', '}' }
vim.api.nvim_create_autocmd('BufReadCmd', {
  group = vim.api.nvim_create_augroup('IntellijLspRefsFakeDecompiler', { clear = true }),
  pattern = '*/jar:*',
  callback = function(args)
    vim.api.nvim_buf_set_lines(args.buf, 0, -1, false, DECOMPILED)
    vim.bo[args.buf].modified = false
    vim.bo[args.buf].buftype = 'nofile'
  end,
})

vim.cmd('edit ' .. HYG .. '/A1.java')
origin_win = vim.api.nvim_get_current_win()
local origin_buf = vim.api.nvim_get_current_buf()
vim.api.nvim_win_set_cursor(origin_win, { 2, 4 })
-- The nvim_win_set_buf check above deliberately polluted this window's jumplist; reset so the
-- browsing assertion below measures only what run() and the previews did.
vim.cmd('clearjumps')

local cid = vim.lsp.start({
  name = 'intellij-refs-fake',
  cmd = fake_server({
    loc(HYG .. '/A1.java', 1),
    loc(HYG .. '/A2.java', 1),
    -- A JDK reference nothing decompiles, to prove the invalid row survives the round trip and is
    -- skipped.
    { uri = 'jrt:/java.base/java/lang/String.class',
      range = { start = { line = 3, character = 0 }, ['end'] = { line = 3, character = 5 } } },
    -- A library reference the stand-in decompiler fills: a navigable row like any project file's.
    { uri = JAR,
      range = { start = { line = 2, character = 4 }, ['end'] = { line = 2, character = 11 } } },
  }),
  root_dir = HYG,
}, { bufnr = 0 })
check('fake client attached', cid ~= nil, cid)

refs.run()
vim.wait(2000, function() return refs.is_open() end)
check('session open after run()', refs.is_open() == true)

local rows = vim.fn.getqflist()
check('external rows are kept, not filtered', #rows == 4, #rows)
-- locations_to_items sorts by URI, so the rows are looked up rather than indexed: `jar:` sorts
-- before `jrt:`, and both after the file: rows only by accident of the /tmp path.
local jar_idx, jrt_idx
for i, r in ipairs(rows) do
  local u = vim.tbl_get(r, 'user_data', 'uri') or ''
  if u == JAR then jar_idx = i elseif u:find('^jrt:') then jrt_idx = i end
end
check('both library rows are present', jar_idx ~= nil and jrt_idx ~= nil, vim.inspect({ jar_idx, jrt_idx }))
jar_idx, jrt_idx = jar_idx or 3, jrt_idx or 4
local jar_row, jrt_row = rows[jar_idx], rows[jrt_idx]
check('the jrt row is invalid', jrt_row.valid == 0, jrt_row.valid)
check('the decompiled jar row is valid', jar_row.valid == 1, jar_row.valid)
check('the decompiled jar row carries its source line',
  jar_row.text == DECOMPILED[3], ('%q'):format(tostring(jar_row.text)))
check('the decompiled jar row points at the filled buffer',
  jar_row.bufnr and vim.api.nvim_buf_get_name(jar_row.bufnr):find('jar:', 1, true) ~= nil
    and vim.api.nvim_buf_line_count(jar_row.bufnr) == #DECOMPILED,
  jar_row.bufnr and vim.api.nvim_buf_get_name(jar_row.bufnr))

local qf_win = vim.api.nvim_get_current_win()
check('focus is in the list, not the editor',
  vim.bo[vim.api.nvim_win_get_buf(qf_win)].buftype == 'quickfix',
  vim.bo[vim.api.nvim_win_get_buf(qf_win)].buftype)
check('first entry is previewed without a keypress',
  vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(origin_win)):find('A1.java') ~= nil,
  vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(origin_win)))

-- The extmark must cover the identifier, not the row: this is the "nice UX" half of the request.
local ns = vim.api.nvim_get_namespaces()['intellij-lsp.references.qf']
local marks = vim.api.nvim_buf_get_extmarks(0, ns, 0, -1, { details = true })
check('exactly one match extmark', #marks == 1, #marks)
if #marks == 1 then
  local line = vim.api.nvim_buf_get_lines(0, marks[1][2], marks[1][2] + 1, false)[1]
  check('extmark covers the identifier',
    line:sub(marks[1][3] + 1, marks[1][4].end_col) == 'Greeter',
    ('%q'):format(line:sub(marks[1][3] + 1, marks[1][4].end_col)))
end

-- Quickfix's own selection must start on entry 1, or the 'QuickFixLine' bar marks nothing.
check('quickfix index starts on the first entry', vim.fn.getqflist({ idx = 0 }).idx == 1,
  vim.fn.getqflist({ idx = 0 }).idx)

-- Stepping down follows in the editor while focus stays put.
vim.api.nvim_win_set_cursor(qf_win, { 2, 0 })
vim.cmd('doautocmd CursorMoved')
vim.wait(400)

-- The regression this guards: quickfix only advances its index on :cc/:cnext, so without an explicit
-- sync the highlighted row stays on entry 1 while the cursor and the preview move away from it.
check('quickfix index follows the cursor', vim.fn.getqflist({ idx = 0 }).idx == 2,
  vim.fn.getqflist({ idx = 0 }).idx)
-- Syncing the index must not cost the match highlight: an item-less setqflist keeps the buffer, so
-- the extmarks placed on it survive. If this fails, the sync is rebuilding the list.
check('syncing the index preserves the match extmark',
  #vim.api.nvim_buf_get_extmarks(vim.api.nvim_win_get_buf(qf_win), ns, 0, -1, {}) == 1,
  #vim.api.nvim_buf_get_extmarks(vim.api.nvim_win_get_buf(qf_win), ns, 0, -1, {}))
check('syncing the index preserves the items', #vim.fn.getqflist() == 4, #vim.fn.getqflist())
check('syncing the index preserves the title',
  vim.fn.getqflist({ title = 0 }).title ~= '', vim.fn.getqflist({ title = 0 }).title)
check('editor follows the selection',
  vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(origin_win)):find('A2.java') ~= nil,
  vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(origin_win)))
check('focus stayed in the list while stepping', vim.api.nvim_get_current_win() == qf_win)
check('browsing leaves the editor jumplist clean',
  #vim.fn.getjumplist(origin_win)[1] == 0, #vim.fn.getjumplist(origin_win)[1])
-- The empty buffer behind the unopenable row is wiped; the decompiled one behind the navigable row
-- is what that row previews, so it has to stay.
check('the empty jrt buffer was wiped by run()', (function()
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_get_name(b):find('jrt:', 1, true) then return false end
  end
  return true
end)())
check('the decompiled jar buffer survived run()', vim.api.nvim_buf_is_valid(jar_row.bufnr))

-- The invalid row is reachable with j even though :cnext skips it, so it must be inert.
vim.api.nvim_win_set_cursor(qf_win, { jrt_idx, 0 })
check('stepping onto the invalid row does not error', pcall(vim.cmd, 'doautocmd CursorMoved'))
vim.wait(400)
check('invalid row leaves the preview untouched',
  vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(origin_win)):find('A2.java') ~= nil,
  vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(origin_win)))
check('invalid row gets no extmark',
  #vim.api.nvim_buf_get_extmarks(0, ns, 0, -1, {}) == 0,
  #vim.api.nvim_buf_get_extmarks(0, ns, 0, -1, {}))
-- :cnext refuses to land on an invalid row, so pointing the index at one would put the selection bar
-- somewhere <CR> could never go. It stays on the last valid entry instead.
check('invalid row leaves the quickfix index alone', vim.fn.getqflist({ idx = 0 }).idx == 2,
  vim.fn.getqflist({ idx = 0 }).idx)

-- The decompiled row previews like a project file: the editor shows the library buffer, the match
-- is highlighted in the list, and the selection bar follows.
vim.api.nvim_win_set_cursor(qf_win, { jar_idx, 0 })
vim.cmd('doautocmd CursorMoved')
vim.wait(400)
check('decompiled row previews its buffer',
  vim.api.nvim_win_get_buf(origin_win) == jar_row.bufnr,
  vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(origin_win)))
check('decompiled row previews on the referenced line',
  vim.api.nvim_win_get_cursor(origin_win)[1] == 3, vim.inspect(vim.api.nvim_win_get_cursor(origin_win)))
check('decompiled row gets a match extmark',
  #vim.api.nvim_buf_get_extmarks(0, ns, 0, -1, {}) == 1,
  #vim.api.nvim_buf_get_extmarks(0, ns, 0, -1, {}))
check('decompiled row moves the quickfix index', vim.fn.getqflist({ idx = 0 }).idx == jar_idx,
  vim.fn.getqflist({ idx = 0 }).idx)

-- q / <Esc>: back exactly where grr was pressed, however far the browsing wandered.
refs.close(true)
check('closed after close(true)', refs.is_open() == false)
check('list is gone', vim.bo[vim.api.nvim_get_current_buf()].buftype ~= 'quickfix')
check('restored the origin window', vim.api.nvim_get_current_win() == origin_win)
check('restored the origin buffer', vim.api.nvim_get_current_buf() == origin_buf,
  vim.api.nvim_buf_get_name(vim.api.nvim_get_current_buf()))
check('restored the origin cursor',
  vim.deep_equal(vim.api.nvim_win_get_cursor(origin_win), { 2, 4 }),
  vim.inspect(vim.api.nvim_win_get_cursor(origin_win)))
check('augroup torn down',
  not pcall(vim.api.nvim_get_autocmds, { group = 'IntellijLspReferences' }))
check('close() twice is a no-op', pcall(refs.close, true))

-- grr pressed *inside* a decompiled class. The old blanket wipe of every jar:/jrt: buffer took the
-- origin buffer with it, so q had nothing to restore to and the window was yanked elsewhere.
local lib_buf = jar_row.bufnr
vim.api.nvim_set_current_buf(lib_buf)
vim.lsp.buf_attach_client(lib_buf, cid)
vim.api.nvim_win_set_cursor(0, { 3, 4 })
refs.run()
vim.wait(2000, function() return refs.is_open() end)
check('session opens from a decompiled buffer', refs.is_open() == true)
check('the origin library buffer survives run()', vim.api.nvim_buf_is_valid(lib_buf))
refs.close(true)
check('q restores the decompiled origin buffer',
  vim.api.nvim_get_current_buf() == lib_buf and vim.deep_equal(vim.api.nvim_win_get_cursor(0), { 3, 4 }),
  vim.inspect({ vim.api.nvim_buf_get_name(0), vim.api.nvim_win_get_cursor(0) }))
vim.cmd('edit ' .. HYG .. '/A1.java')

-- <CR>: unlike the previews, this jump *should* be in the jumplist.
vim.cmd('clearjumps')
refs.run()
vim.wait(2000, function() return refs.is_open() end)
refs.close(false)
pcall(vim.cmd, '2cc')
check('<CR> path lands on the reference', vim.api.nvim_buf_get_name(0):find('A2.java') ~= nil,
  vim.api.nvim_buf_get_name(0))
check('<CR> path pushes a jumplist entry', #vim.fn.getjumplist()[1] > 0, #vim.fn.getjumplist()[1])

-- The origin window closed mid-browse: preview must degrade instead of raising E5555.
vim.cmd('only')
vim.cmd('edit ' .. HYG .. '/A1.java')
refs.run()
vim.wait(2000, function() return refs.is_open() end)
local surviving = vim.api.nvim_get_current_win()
for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
  if w ~= surviving then pcall(vim.api.nvim_win_close, w, true) end
end
check('preview degrades when the origin window is gone', pcall(function()
  vim.api.nvim_win_set_cursor(surviving, { 2, 0 })
  vim.cmd('doautocmd CursorMoved')
  vim.wait(300)
end))
check('close(true) is safe when the origin window is gone', pcall(refs.close, true))

local fake = vim.lsp.get_client_by_id(cid)
if fake then fake:stop(true) end

-- -------------------------------------------------------------------------------------------------
-- Wiring: the keymap gate and the opt-out
-- -------------------------------------------------------------------------------------------------
local client = require('intellij-lsp.client')
--- Stands in for a client that answers references.
local stub = {
  id = 1,
  supports_method = function(_, m) return m == 'textDocument/references' end,
}

vim.cmd('enew')
client.config('/tmp', { references = true }).on_attach(stub, vim.api.nvim_get_current_buf())
check('grr is mapped buffer-locally when enabled',
  vim.fn.maparg('grr', 'n', false, true).buffer == 1,
  vim.inspect(vim.fn.maparg('grr', 'n', false, true).buffer))

vim.cmd('enew')
client.config('/tmp', { references = false }).on_attach(stub, vim.api.nvim_get_current_buf())
local opted_out = vim.fn.maparg('grr', 'n', false, true)
check('no buffer-local grr when references = false', (opted_out.buffer or 0) == 0,
  vim.inspect(opted_out.buffer))
-- Opting out means falling back to the built-in, not losing `grr` altogether.
check('built-in global grr is left in place',
  opted_out.desc ~= nil and opted_out.desc:find('vim.lsp.buf.references') ~= nil,
  vim.inspect(opted_out.desc))

-- A client without the capability must not get the map either.
vim.cmd('enew')
client.config('/tmp', { references = true }).on_attach(
  { id = 2, supports_method = function() return false end },
  vim.api.nvim_get_current_buf())
check('no grr when the server lacks referencesProvider',
  (vim.fn.maparg('grr', 'n', false, true).buffer or 0) == 0,
  vim.inspect(vim.fn.maparg('grr', 'n', false, true).buffer))

-- run() with no attached client notifies instead of throwing.
vim.cmd('enew')
local notified
local real_notify = vim.notify
vim.notify = function(msg) notified = msg end
local ok_noclient = pcall(refs.run)
vim.notify = real_notify
check('run() without a client does not error', ok_noclient)
check('run() without a client notifies',
  notified ~= nil and tostring(notified):find('no client') ~= nil, vim.inspect(notified))

-- -------------------------------------------------------------------------------------------------
-- The premise: what locations_to_items does with jar: and jrt: URIs
-- -------------------------------------------------------------------------------------------------
-- hydrate() exists because Neovim treats the two schemes differently (see is_external): a `jrt:`
-- buffer is bufloaded -- so a BufReadCmd fills it and the item carries the line -- while a `jar:`
-- buffer, named under cwd, is read as a file and the item comes back empty with columns clamped to 1.
-- Asserted against the real locations_to_items, so a Neovim release changing either half shows up
-- here rather than as library rows silently falling back to the unopenable path.
local filled = {}
vim.api.nvim_create_autocmd('BufReadCmd', {
  group = vim.api.nvim_create_augroup('IntellijLspRefsFakeDecompiler', { clear = true }),
  pattern = { '*/jar:*', 'jrt:/*' },
  callback = function(args)
    filled[#filled + 1] = args.file
    vim.api.nvim_buf_set_lines(args.buf, 0, -1, false, { 'a', 'b', 'c', 'class F {}' })
  end,
})
local items = vim.lsp.util.locations_to_items({
  { uri = 'jrt:/java.base/java/lang/Object.class',
    range = { start = { line = 3, character = 6 }, ['end'] = { line = 3, character = 7 } } },
  { uri = 'jar:file:///l/other.jar!/com/F.class',
    range = { start = { line = 3, character = 6 }, ['end'] = { line = 3, character = 7 } } },
}, 'utf-16')
local by_uri = {}
for _, it in ipairs(items) do by_uri[it.user_data.uri] = it end
local jrt_item = by_uri['jrt:/java.base/java/lang/Object.class']
local jar_item = by_uri['jar:file:///l/other.jar!/com/F.class']
check('jrt: is loaded through BufReadCmd by locations_to_items',
  #filled == 1 and filled[1]:find('jrt:', 1, true) ~= nil, vim.inspect(filled))
check('jrt: item carries the filled line and columns',
  jrt_item.text == 'class F {}' and jrt_item.col == 7 and jrt_item.end_col == 8,
  vim.inspect({ jrt_item.text, jrt_item.col, jrt_item.end_col }))
check('jar: item comes back empty with clamped columns (why hydrate reloads)',
  jar_item.text == '' and jar_item.col == 1 and jar_item.end_col == 1,
  vim.inspect({ jar_item.text, jar_item.col, jar_item.end_col }))
check('jar: buffer exists but is not loaded',
  vim.fn.bufexists(vim.uri_to_fname('jar:file:///l/other.jar!/com/F.class')) == 1
    and vim.fn.bufloaded(vim.uri_to_fname('jar:file:///l/other.jar!/com/F.class')) == 0)

-- ...and hydrate turns that jar: item into a navigable row anyway.
local fixed, left = refs._tag_items({ jar_item }, 'utf-16')
check('hydrate loads the jar: buffer and rebuilds the row',
  left == 0 and fixed[1].valid == 1 and fixed[1].text == 'class F {}' and fixed[1].col == 7
    and fixed[1].end_col == 8 and fixed[1].lnum == 4,
  vim.inspect(fixed[1]))

-- Origin state is still intact after all of the above.
check('origin buffer still valid', vim.api.nvim_buf_is_valid(origin_buf))

print(failures == 0 and '\nALL REFERENCE CHECKS PASSED'
  or ('\n' .. failures .. ' REFERENCE CHECK(S) FAILED'))
vim.cmd(failures == 0 and 'qa!' or 'cq!')
