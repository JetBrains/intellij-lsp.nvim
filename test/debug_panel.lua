-- Checks for the debug panel's call-stack preview: stepping over frame rows shows each frame's
-- source in the editor window. No server and no nvim-dap required -- a stand-in session answers the
-- panel's requests with frames shaped like the ones the server sends.
--
--   nvim --headless -u NONE -l test/debug_panel.lua
--
-- `-u NONE` loads no netrw, the setup issue #8 was reported from: `:edit file:///...` has no reader
-- there, so a preview that hands the frame's URI to `:edit` fails every check below.
vim.opt.runtimepath:prepend(vim.fs.dirname(vim.fs.dirname(debug.getinfo(1, 'S').source:sub(2))))

local failures = 0
local function check(name, cond, detail)
  if cond then
    print('ok   ' .. name)
  else
    failures = failures + 1
    print('FAIL ' .. name .. (detail and ('  -> ' .. tostring(detail)) or ''))
  end
end

-- A stand-in nvim-dap: listeners as tables, one stopped session.
local listeners = {}
for _, phase in ipairs({ 'before', 'after' }) do
  listeners[phase] = setmetatable({}, { __index = function(t, k) t[k] = {}; return t[k] end })
end
local session
package.loaded['dap'] = { listeners = listeners, session = function() return session end }

local root = vim.fs.normalize(vim.fn.tempname() .. '-panel')
vim.fn.mkdir(root, 'p')
root = vim.uv.fs_realpath(root)
local function source_file(name, n)
  local lines = {}
  for i = 1, n do lines[i] = ('// %s line %d'):format(name, i) end
  vim.fn.writefile(lines, root .. '/' .. name)
  return root .. '/' .. name
end
local GREETER = source_file('Greeter.java', 20)
local MAIN = source_file('Main.java', 30)
-- The server sends `Source.path` as a URI, not a path (DapStackFramesManager.toDapFrame).
local function uri(path) return vim.uri_from_fname(path) end
local LIB_URI = 'jar:///nowhere/lib.jar!/p/Lib.class'

-- Shaped after a real stop in `names.forEach(n -> greet(n))`, server 271.2085.0.
local FRAMES = {
  { id = 1, name = 'at com.example.Greeter.greet(Greeter.java:5)', line = 5, column = 0, source = { path = uri(GREETER) } },
  { id = 2, name = 'at com.example.Main.lambda$main$0(Main.java:9)', line = 9, column = 0, source = { path = uri(MAIN) } },
  { id = 3, name = 'at com.example.Main$$Lambda.accept(Unknown Source:-1)', line = -1, column = 0, source = { path = uri(MAIN) } },
  { id = 4, name = 'at p.Lib.run(Lib.java:1612)', line = 1612, column = 0, source = { path = LIB_URI } },
  { id = 5, name = 'at com.example.Main.main(Main.java:25)', line = 25, column = 0, source = { path = uri(MAIN) } },
  -- Read by a BufReadCmd that waits, as the decompiler's does; see the resume check below.
  { id = 6, name = 'at p.Slow.run(Slow.java:3)', line = 3, column = 0, source = { path = 'slow:///p/Slow.class' } },
}
session = {
  config = { type = 'intellij_jvm' },
  request = function(_, command, _, callback)
    local resp = ({
      stackTrace = { stackFrames = FRAMES },
      scopes = { scopes = {} },
      evaluate = { result = '1' },
    })[command] or {}
    vim.schedule(function() callback(nil, resp) end)
  end,
}

-- The decompiler's BufReadCmd claims the `jar:` frame; with no server it fills a two-line
-- placeholder, which is what a frame line past the end of a buffer looks like.
require('intellij-lsp.decompiler').setup()
local dbg = require('intellij-lsp.debug')
dbg.setup()

local editor_win = vim.api.nvim_get_current_win()
listeners.after.event_stopped['intellij-lsp.debug'](session, { threadId = 1 })

local panel_win
vim.wait(2000, function()
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    local name = vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(win))
    if name == 'intellij-lsp://debug' then panel_win = win end
  end
  return panel_win ~= nil
    and vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(panel_win), 1, 2, false)[1]:find('Greeter', 1, true) ~= nil
end, 20)
check('the panel opens on the stop with the stack', panel_win ~= nil)
if not panel_win then vim.cmd('cq!') end
local panel_buf = vim.api.nvim_win_get_buf(panel_win)
vim.api.nvim_set_current_win(panel_win)
-- Opening the panel's split itself records one jump; only what the previews add is measured.
local jumps_before = #vim.fn.getjumplist(editor_win)[1]

local function frame_row(id)
  for lnum, line in ipairs(vim.api.nvim_buf_get_lines(panel_buf, 0, -1, false)) do
    if line:find(FRAMES[id].name, 1, true) then return lnum end
  end
end

local function editor_state()
  local buf = vim.api.nvim_win_get_buf(editor_win)
  return vim.api.nvim_buf_get_name(buf), vim.api.nvim_win_get_cursor(editor_win)[1], buf
end

--- Moves the panel cursor onto frame `id` the way `j` does, and waits for the preview to settle.
local function step_to(id, expect_name)
  vim.v.errmsg = ''
  vim.api.nvim_win_set_cursor(panel_win, { frame_row(id), 0 })
  vim.api.nvim_exec_autocmds('CursorMoved', { buffer = panel_buf })
  vim.wait(1000, function() return expect_name == nil or editor_state() == expect_name end, 10)
  vim.wait(100)
  return vim.v.errmsg
end

local function no_uri_buffers()
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_get_name(b):find('file:', 1, true) then return false, vim.api.nvim_buf_get_name(b) end
  end
  return true
end

local err = step_to(1, GREETER)
local name, lnum, buf = editor_state()
check('top frame: no error', err == '', err)
check('top frame: the editor shows the real file at the frame line', name == GREETER and lnum == 5, name .. ':' .. lnum)
check('top frame: the file is read, not an empty buffer', vim.api.nvim_buf_line_count(buf) == 20,
  vim.api.nvim_buf_line_count(buf))
check('top frame: focus stays in the panel', vim.api.nvim_get_current_win() == panel_win)

err = step_to(2, MAIN)
name, lnum, buf = editor_state()
check('second frame: no error', err == '', err)
check('second frame: the editor follows', name == MAIN and lnum == 9, name .. ':' .. lnum)
local marks = vim.api.nvim_buf_get_extmarks(buf, -1, 0, -1, { details = true })
local marked = vim.tbl_filter(function(m) return m[4].line_hl_group == 'DapStoppedFrame' end, marks)
check('second frame: its line is marked as a previewed frame', #marked == 1 and marked[1][2] == 8, vim.inspect(marks))

err = step_to(3, nil)
name, lnum = editor_state()
check('frame with line -1: no error', err == '', err)
check('frame with line -1: the editor stays where it was', name == MAIN and lnum == 9, name .. ':' .. lnum)

err = step_to(4, nil)
vim.wait(1000, function() return editor_state():find('jar:', 1, true) ~= nil end, 10)
name, lnum, buf = editor_state()
check('library frame: no error', err == '', err)
check('library frame: the decompiler filled the jar: buffer', name:find('jar:', 1, true) ~= nil
  and vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1]:find('IntelliJ LSP', 1, true) ~= nil,
  name .. ' ' .. vim.inspect(vim.api.nvim_buf_get_lines(buf, 0, -1, false)))
check('library frame: a line past the end lands on the last line', lnum == vim.api.nvim_buf_line_count(buf),
  lnum .. '/' .. vim.api.nvim_buf_line_count(buf))

err = step_to(5, MAIN)
name, lnum = editor_state()
check('bottom frame: no error', err == '', err)
check('bottom frame: the editor follows', name == MAIN and lnum == 25, name .. ':' .. lnum)

local ok, bad = no_uri_buffers()
check('no buffer is named after a file: URI', ok, bad)
check('previews leave the jumplist alone', #vim.fn.getjumplist(editor_win)[1] == jumps_before,
  vim.inspect(vim.fn.getjumplist(editor_win)[1]))

-- Holding `j`: only the frame the cursor stops on is shown.
vim.api.nvim_win_set_cursor(panel_win, { frame_row(1), 0 })
vim.api.nvim_exec_autocmds('CursorMoved', { buffer = panel_buf })
vim.api.nvim_win_set_cursor(panel_win, { frame_row(2), 0 })
vim.api.nvim_exec_autocmds('CursorMoved', { buffer = panel_buf })
vim.wait(300)
name, lnum = editor_state()
check('fast steps: the preview lands on the last row', name == MAIN and lnum == 9, name .. ':' .. lnum)

-- <CR> on a frame: selects it and shows it, from a keymap rather than an autocmd.
vim.api.nvim_win_set_cursor(panel_win, { frame_row(1), 0 })
vim.v.errmsg = ''
vim.api.nvim_feedkeys(vim.keycode('<CR>'), 'x', false)
vim.wait(300)
name, lnum = editor_state()
check('<CR> on a frame: no error', vim.v.errmsg == '', vim.v.errmsg)
check('<CR> on a frame: the editor shows it', name == GREETER and lnum == 5, name .. ':' .. lnum)

-- Back to the editor before the preview settles: the file being worked on stays put.
vim.api.nvim_set_current_win(panel_win)
vim.api.nvim_win_set_cursor(panel_win, { frame_row(2), 0 })
vim.api.nvim_exec_autocmds('CursorMoved', { buffer = panel_buf })
vim.api.nvim_set_current_win(editor_win)
vim.wait(300)
name, lnum = editor_state()
check('left the panel before the preview: the editor keeps its file', name == GREETER and lnum == 5, name .. ':' .. lnum)
vim.api.nvim_set_current_win(panel_win)

-- The program resumes while a library frame's source is still loading. The decompiler waits for
-- the server with vim.wait, which runs the `continued` event; the stale frame must not be shown or
-- marked once the load returns.
local slow_buf
vim.api.nvim_create_autocmd('BufReadCmd', {
  pattern = 'slow:/*',
  callback = function(args)
    slow_buf = args.buf
    vim.schedule(function() listeners.after.event_continued['intellij-lsp.debug'](session) end)
    vim.wait(200)
    vim.api.nvim_buf_set_lines(args.buf, 0, -1, false, { 'a', 'b', 'c', 'd' })
  end,
})
vim.v.errmsg = ''
vim.api.nvim_win_set_cursor(panel_win, { frame_row(6), 0 })
vim.api.nvim_exec_autocmds('CursorMoved', { buffer = panel_buf })
vim.wait(1000, function() return slow_buf ~= nil end, 10)
vim.wait(400)
name, lnum = editor_state()
check('resumed during the load: no error', vim.v.errmsg == '', vim.v.errmsg)
check('resumed during the load: the stale frame is not shown', name == GREETER and lnum == 5, name .. ':' .. lnum)
local stale = slow_buf and vim.tbl_filter(function(m) return m[4].line_hl_group == 'DapStoppedFrame' end,
  vim.api.nvim_buf_get_extmarks(slow_buf, -1, 0, -1, { details = true })) or {}
check('resumed during the load: no previewed-frame mark is left', #stale == 0, vim.inspect(stale))

-- Stopped again, for the checks below.
listeners.after.event_stopped['intellij-lsp.debug'](session, { threadId = 1 })
vim.wait(1000, function() return frame_row(2) ~= nil end, 10)

-- The editor window closed: the preview finds no other window and does nothing, no split.
vim.api.nvim_win_close(editor_win, true)
local wins = #vim.api.nvim_list_wins()
vim.v.errmsg = ''
vim.api.nvim_win_set_cursor(panel_win, { frame_row(2), 0 })
vim.api.nvim_exec_autocmds('CursorMoved', { buffer = panel_buf })
vim.wait(300)
check('no editor window: no error and no new window', vim.v.errmsg == '' and #vim.api.nvim_list_wins() == wins,
  vim.v.errmsg .. ' ' .. #vim.api.nvim_list_wins())

-- preview.lua on its own.
local preview = require('intellij-lsp.preview')
check('buffer: a file: URI is the real path', vim.api.nvim_buf_get_name(preview.buffer(uri(GREETER))) == GREETER)
check('buffer: a plain path is that path', vim.api.nvim_buf_get_name(preview.buffer(GREETER)) == GREETER)
check('buffer: a jar: URI keeps its name', vim.api.nvim_buf_get_name(preview.buffer(LIB_URI)):find(LIB_URI, 1, true) ~= nil,
  vim.api.nvim_buf_get_name(preview.buffer(LIB_URI)))

print(failures == 0 and '\nALL DEBUG PANEL CHECKS PASSED' or ('\n' .. failures .. ' DEBUG PANEL CHECK(S) FAILED'))
vim.cmd(failures == 0 and 'qa!' or 'cq!')
