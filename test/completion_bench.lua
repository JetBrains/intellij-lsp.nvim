-- Benchmark, not a test: how long after a keystroke the completion menu appears, with real typing.
--
--   IJLS_SERVER=<bundle>/bin/intellij-server \
--     [CPS=8] [BUILD_TOOL=maven] [COMPLETION_DELAY=100] [DIDCHANGE_MS=150] \
--     nvim --headless -u NONE -l test/completion_bench.lua <project> <file> <0-based line> 'text' ['text' ...]
--
-- Drives a second headless Neovim over RPC, because keys queued from a `-l` script are not
-- processed by its own loop. The driven instance runs the real plugin and the real server. Each
-- `text` is typed at CPS characters per second into an empty line inserted at <line>, and the
-- time from the first and the last keystroke to a visible menu is printed, together with every
-- completion request the client sent, how long it took and whether it was cancelled. The file is
-- never written.
--
-- Example, spring-petclinic:
--   nvim --headless -u NONE -l test/completion_bench.lua ~/Code/spring-petclinic \
--     src/main/java/org/springframework/samples/petclinic/owner/OwnerController.java 84 \
--     'this.owners.find' 'redirectAttr' 'String.val'
local PLUGIN = vim.fs.dirname(vim.fs.dirname(debug.getinfo(1, 'S').source:sub(2)))
local args = _G.arg or {}
local project, file, line0 = args[1], args[2], tonumber(args[3])
if not (project and file and line0 and args[4]) then
  io.stderr:write('usage: ... completion_bench.lua <project> <file> <line> text [text ...]\n')
  vim.cmd('cq!')
end
local texts = {}
for i = 4, #args do texts[#texts + 1] = args[i] end

local PROJECT = vim.uv.fs_realpath(vim.fn.expand(project))
local FILE = file:sub(1, 1) == '/' and file or (PROJECT .. '/' .. file)
local CPS = tonumber(vim.env.CPS or '8')
local SERVER = assert(vim.env.IJLS_SERVER, 'IJLS_SERVER not set')

local function log(fmt, ...) io.stdout:write(string.format(fmt, ...) .. '\n') io.stdout:flush() end

-- Init file for the driven instance: plugin, request trace, menu watcher.
local child_init = vim.fn.tempname() .. '-bench-init.lua'
vim.fn.writefile(vim.split(([[
vim.opt.runtimepath:prepend(%q)
vim.cmd('filetype plugin indent on')
vim.cmd('syntax off')
if vim.env.DIDCHANGE_MS then
  local start = vim.lsp.start
  vim.lsp.start = function(config, opts)
    config.flags = { debounce_text_changes = tonumber(vim.env.DIDCHANGE_MS) }
    return start(config, opts)
  end
end
require('intellij-lsp').setup({
  server_path = vim.env.IJLS_SERVER,
  accept_eula = true,
  build_tool = vim.env.BUILD_TOOL,
  completion_delay = tonumber(vim.env.COMPLETION_DELAY or '100'),
})
_G.TRACE, _G.SENT, _G.T0, _G.PUM_AT = {}, {}, 0, nil
local function now() return vim.uv.hrtime() / 1e6 end
vim.api.nvim_create_autocmd('LspRequest', {
  callback = function(ev)
    local r = ev.data.request
    if r.method ~= 'textDocument/completion' then return end
    if r.type == 'pending' then
      _G.SENT[ev.data.request_id] = now()
    else
      local t0 = _G.SENT[ev.data.request_id]
      if t0 then
        _G.TRACE[#_G.TRACE + 1] = string.format('[%%-8s] sent at +%%5.0f ms, %%5.0f ms', r.type, t0 - _G.T0, now() - t0)
      end
    end
  end,
})
vim.uv.new_timer():start(0, 5, vim.schedule_wrap(function()
  if not _G.PUM_AT and vim.fn.pumvisible() ~= 0 then _G.PUM_AT = now() end
end))
]]):format(PLUGIN), '\n'), child_init)

local sock = vim.fn.tempname() .. '.sock'
local job = vim.fn.jobstart({ 'nvim', '--headless', '--listen', sock, '-u', child_init, FILE }, {
  env = {
    IJLS_SERVER = SERVER,
    BUILD_TOOL = vim.env.BUILD_TOOL,
    COMPLETION_DELAY = vim.env.COMPLETION_DELAY,
    DIDCHANGE_MS = vim.env.DIDCHANGE_MS,
  },
  on_stdout = function() end,
  on_stderr = function() end,
})
assert(job > 0, 'could not start the driven Neovim')

local chan
vim.wait(20000, function()
  local ok, c = pcall(vim.fn.sockconnect, 'pipe', sock, { rpc = true })
  if ok and c > 0 then chan = c end
  return chan ~= nil
end, 200)
assert(chan, 'could not connect to the driven Neovim')

local function rpc(method, ...) return vim.rpcrequest(chan, method, ...) end
local function lua(code, ...) return rpc('nvim_exec_lua', code, { ... }) end
local function now_ms() return lua('return vim.uv.hrtime() / 1e6') end

log('waiting for the server to attach and index ...')
assert(vim.wait(900000, function()
  return lua([[
    local c = vim.lsp.get_clients({ name = 'intellij' })[1]
    return c ~= nil and require('intellij-lsp.progress').is_ready(c.id)
  ]])
end, 1000), 'server never became ready')
vim.wait(3000)
log('typing at %d chars/s, completion_delay=%s, didChange debounce=%s ms', CPS,
  vim.env.COMPLETION_DELAY or '100', vim.env.DIDCHANGE_MS or '150')

-- One scratch line, reset before every text so each starts from the same document.
lua('vim.api.nvim_buf_set_lines(0, ..., ..., false, { "" })', line0, line0)
vim.wait(300)

for _, text in ipairs(texts) do
  rpc('nvim_input', '<Esc>')
  lua('vim.api.nvim_buf_set_lines(0, ..., select(1, ...) + 1, false, { "" })', line0)
  lua('vim.api.nvim_win_set_cursor(0, { ... + 1, 0 })', line0)
  vim.wait(500)
  lua('_G.TRACE = {}; _G.PUM_AT = nil; _G.T0 = vim.uv.hrtime() / 1e6')
  rpc('nvim_input', 'A')
  vim.wait(30)
  local t_first = now_ms()
  for i = 1, #text do
    rpc('nvim_input', text:sub(i, i))
    vim.wait(math.floor(1000 / CPS))
  end
  local t_last = now_ms()
  local shown = vim.wait(15000, function() return lua('return _G.PUM_AT ~= nil') end, 10)
  local pum_at = lua('return _G.PUM_AT')
  local items = lua('return #(vim.fn.complete_info({ "items" }).items or {})')
  if shown then
    log('%-28s menu %5.0f ms after the first key, %5.0f ms after the last (%d items)',
      text, pum_at - t_first, pum_at - t_last, items)
  else
    log('%-28s no menu within 15 s', text)
  end
  for _, l in ipairs(lua('return _G.TRACE')) do log('    %s', l) end
  rpc('nvim_input', '<Esc>')
  vim.wait(300)
end

rpc('nvim_input', '<Esc>')
lua('vim.cmd("edit!")')
vim.wait(300)
pcall(rpc, 'nvim_command', 'qa!')
vim.wait(2000)
vim.fn.jobstop(job)
vim.cmd('qa!')
