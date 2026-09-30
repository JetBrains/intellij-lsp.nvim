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

local tagged, external = refs._tag_items({
  { filename = '/tmp/A.java', lnum = 1, col = 1, end_col = 6, text = 'class A',
    user_data = { uri = 'file:///tmp/A.java' } },
  { filename = '', lnum = 4, col = 1, end_col = 1, text = '',
    user_data = { uri = 'jrt:/java.base/java/lang/String.class' } },
  { filename = '/tmp/B.java', lnum = 2, col = 1, end_col = 6, text = 'class B',
    user_data = { uri = 'file:///tmp/B.java' } },
})
check('external counted', external == 1, external)
check('file items stay valid', tagged[1].valid == 1 and tagged[3].valid == 1)
check('external item marked invalid', tagged[2].valid == 0, tagged[2].valid)
check('external item has synthesized text', tagged[2].text ~= '' and tagged[2].text ~= nil,
  ('%q'):format(tostring(tagged[2].text)))
-- No filename: quickfix would otherwise resolve it against cwd, which is the phantom-buffer bug.
check('external item carries no filename', tagged[2].filename == nil, tagged[2].filename)

-- Round-trip: valid=0 and the range columns have to survive quickfix, or the feature loses either its
-- skip-invalid behaviour or its extmarks.
vim.fn.setqflist({}, ' ', { title = 'References', items = tagged })
local got = vim.fn.getqflist()
check('valid=0 survives setqflist', got[2].valid == 0, got[2].valid)
check('end_col survives setqflist', got[1].end_col == 6, got[1].end_col)
check('title survives', vim.fn.getqflist({ title = 0 }).title == 'References',
  vim.fn.getqflist({ title = 0 }).title)

-- Quickfix's own :cnext skips invalid entries, which is why external rows can be kept as rows.
vim.fn.writefile({ 'class A', 'body' }, '/tmp/A.java')
vim.fn.writefile({ 'class B', 'body' }, '/tmp/B.java')
vim.cmd('cfirst')
vim.cmd('cnext')
check(':cnext skips the invalid row', vim.fn.getqflist({ idx = 0 }).idx == 3,
  vim.fn.getqflist({ idx = 0 }).idx)

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
    -- A JDK reference, to prove the invalid row survives the round trip and is skipped.
    { uri = 'jrt:/java.base/java/lang/String.class',
      range = { start = { line = 3, character = 0 }, ['end'] = { line = 3, character = 5 } } },
  }),
  root_dir = HYG,
}, { bufnr = 0 })
check('fake client attached', cid ~= nil, cid)

refs.run()
vim.wait(2000, function() return refs.is_open() end)
check('session open after run()', refs.is_open() == true)

local rows = vim.fn.getqflist()
check('external rows are kept, not filtered', #rows == 3, #rows)
check('the jrt row is invalid', rows[3].valid == 0, rows[3].valid)

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
check('syncing the index preserves the items', #vim.fn.getqflist() == 3, #vim.fn.getqflist())
check('syncing the index preserves the title',
  vim.fn.getqflist({ title = 0 }).title ~= '', vim.fn.getqflist({ title = 0 }).title)
check('editor follows the selection',
  vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(origin_win)):find('A2.java') ~= nil,
  vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(origin_win)))
check('focus stayed in the list while stepping', vim.api.nvim_get_current_win() == qf_win)
check('browsing leaves the editor jumplist clean',
  #vim.fn.getjumplist(origin_win)[1] == 0, #vim.fn.getjumplist(origin_win)[1])
check('no jar/jrt buffer leaked by run()', (function()
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    local n = vim.api.nvim_buf_get_name(b)
    if n:find('jar:', 1, true) or n:find('jrt:', 1, true) then return false end
  end
  return true
end)())

-- The invalid row is reachable with j even though :cnext skips it, so it must be inert.
vim.api.nvim_win_set_cursor(qf_win, { 3, 0 })
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
-- No phantom buffers left behind
-- -------------------------------------------------------------------------------------------------
-- locations_to_items creates one buffer per non-file URI, named after the URI resolved against cwd.
local items = vim.lsp.util.locations_to_items({
  { uri = 'jar:file:///l/lib.jar!/com/E.class',
    range = { start = { line = 3, character = 0 }, ['end'] = { line = 3, character = 5 } } },
}, 'utf-16')
check('locations_to_items yields empty text for jar:', items[1].text == '',
  ('%q'):format(items[1].text))

local leaked_before = 0
for _, b in ipairs(vim.api.nvim_list_bufs()) do
  if vim.api.nvim_buf_get_name(b):find('jar:', 1, true) then leaked_before = leaked_before + 1 end
end
check('the phantom buffer really is created (why the wipe exists)', leaked_before > 0, leaked_before)

-- Same predicate the module wipes with.
for _, b in ipairs(vim.api.nvim_list_bufs()) do
  local n = vim.api.nvim_buf_get_name(b)
  if n:find('jar:', 1, true) or n:find('jrt:', 1, true) then
    pcall(vim.api.nvim_buf_delete, b, { force = true, unload = false })
  end
end
local leaked_after = 0
for _, b in ipairs(vim.api.nvim_list_bufs()) do
  if vim.api.nvim_buf_get_name(b):find('jar:', 1, true) then leaked_after = leaked_after + 1 end
end
check('phantom buffers are wipeable', leaked_after == 0, leaked_after)

-- Origin state is still intact after all of the above.
check('origin buffer still valid', vim.api.nvim_buf_is_valid(origin_buf))

print(failures == 0 and '\nALL REFERENCE CHECKS PASSED'
  or ('\n' .. failures .. ' REFERENCE CHECK(S) FAILED'))
vim.cmd(failures == 0 and 'qa!' or 'cq!')
