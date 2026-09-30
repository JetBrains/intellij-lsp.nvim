-- Kotlin end-to-end, proving Java and Kotlin are served by one server.
--
--   IJLS_SERVER=<bundle>/bin/intellij-server \
--     nvim --headless -u NONE -l test/kotlin_e2e.lua
--
-- Note the Kotlin sources live under src/main/java: a bare Maven pom with no Kotlin plugin does not
-- register src/main/kotlin as a source root, and files outside a source root get no resolution
-- (documentSymbol still works, since that is pure syntax -- a misleading partial success).
vim.opt.runtimepath:prepend(vim.fs.dirname(vim.fs.dirname(debug.getinfo(1, 'S').source:sub(2))))
vim.cmd('filetype plugin indent on')

local SERVER = assert(vim.env.IJLS_SERVER, 'IJLS_SERVER not set')

local root = vim.fn.tempname() .. '-kotlin'
vim.fn.mkdir(root .. '/src/main/java/com/example', 'p')
vim.fn.writefile({
  '<?xml version="1.0" encoding="UTF-8"?>',
  '<project xmlns="http://maven.apache.org/POM/4.0.0">',
  '  <modelVersion>4.0.0</modelVersion>',
  '  <groupId>com.example</groupId>',
  '  <artifactId>ijktest</artifactId>',
  '  <version>1.0-SNAPSHOT</version>',
  '  <properties>',
  '    <maven.compiler.source>17</maven.compiler.source>',
  '    <maven.compiler.target>17</maven.compiler.target>',
  '  </properties>',
  '</project>',
}, root .. '/pom.xml')
vim.fn.writefile({
  'package com.example',
  '',
  'class Greeter(private val name: String) {',
  '    fun greet(): String = "Hello, $name!"',
  '}',
}, root .. '/src/main/java/com/example/Greeter.kt')
vim.fn.writefile({
  'package com.example',
  '',
  'fun main() {',
  '    val greeter = Greeter("world")',
  '    println(greeter.greet())',
  '}',
}, root .. '/src/main/java/com/example/Main.kt')

local PROJECT = vim.uv.fs_realpath(root)
local MAIN = PROJECT .. '/src/main/java/com/example/Main.kt'
local GREETER = PROJECT .. '/src/main/java/com/example/Greeter.kt'

local failures = 0
local function check(name, cond, detail)
  if cond then print('ok   ' .. name)
  else failures = failures + 1; print('FAIL ' .. name .. (detail and ('  -> ' .. tostring(detail)) or '')) end
end

require('intellij-lsp').setup({ server_path = SERVER, accept_eula = true, build_tool = 'maven' })

vim.cmd('edit ' .. GREETER)
vim.cmd('edit ' .. MAIN)
local bufnr = vim.api.nvim_get_current_buf()
check('filetype is kotlin', vim.bo[bufnr].filetype == 'kotlin', vim.bo[bufnr].filetype)

local client
vim.wait(120000, function()
  client = vim.lsp.get_clients({ name = 'intellij', bufnr = bufnr })[1]
  return client ~= nil
end, 500)
check('client attached', client ~= nil)
if not client then vim.cmd('cq!') end

local progress = require('intellij-lsp.progress')
check('indexing completed', vim.wait(600000, function() return progress.is_ready(client.id) end, 1000))

-- Greeter usage on line 4 (0-based 3)
local l4 = vim.fn.readfile(MAIN)[4]
local gcol = (l4:find('Greeter', 1, true) or 1) - 1
local d = client:request_sync('textDocument/definition', {
  textDocument = vim.lsp.util.make_text_document_params(bufnr),
  position = { line = 3, character = gcol },
}, 30000, bufnr)
local dres = d and d.result
local duri = dres and ((dres[1] and (dres[1].uri or dres[1].targetUri)) or dres.uri)
check('kotlin definition -> Greeter.kt', duri and duri:find('Greeter.kt', 1, true) ~= nil,
  vim.inspect(d and (d.err or dres)))

local h = client:request_sync('textDocument/hover', {
  textDocument = vim.lsp.util.make_text_document_params(bufnr),
  position = { line = 3, character = gcol },
}, 30000, bufnr)
check('kotlin hover', h and h.result and h.result.contents ~= nil)

local ds = client:request_sync('textDocument/documentSymbol', {
  textDocument = vim.lsp.util.make_text_document_params(bufnr),
}, 30000, bufnr)
check('kotlin documentSymbol', ds and ds.result and #ds.result > 0)

local ws = client:request_sync('workspace/symbol', { query = 'Greeter' }, 30000, bufnr)
check('kotlin workspaceSymbol', ws and ws.result and #ws.result > 0)

-- The decisive check: references in Kotlin (not license-gated).
vim.cmd('edit ' .. GREETER)
local gbuf = vim.api.nvim_get_current_buf()
local l3 = vim.fn.readfile(GREETER)[3]
local kcol = (l3:find('Greeter', 1, true) or 1) - 1
local r = client:request_sync('textDocument/references', {
  textDocument = vim.lsp.util.make_text_document_params(gbuf),
  position = { line = 2, character = kcol },
  context = { includeDeclaration = true },
}, 30000, gbuf)
local n = r and r.result and #r.result or -1
print('kotlin references count = ' .. n)
check('kotlin references > 0', n > 0, vim.inspect(r and r.err))

-- Kotlin ranges matter for the same reason Java's do: no range, no match highlight.
local krng = r and r.result and r.result[1] and r.result[1].range
check('kotlin references carry a range',
  krng and (krng['end'].character > krng.start.character or krng['end'].line > krng.start.line),
  vim.inspect(krng))

-- The plugin path. Java's suite covers the follow-mode mechanics; this confirms the Kotlin
-- filetype reaches the same code, since the grr keymap is installed per attached buffer.
local browse = require('intellij-lsp.references')
vim.api.nvim_win_set_cursor(0, { 3, kcol })
browse.run({ include_declaration = true })
check('kotlin references list opens', vim.wait(30000, function() return browse.is_open() end),
  'timed out waiting for the quickfix list')
if browse.is_open() then
  check('kotlin list is populated', #vim.fn.getqflist() > 0, #vim.fn.getqflist())
  local ns = vim.api.nvim_get_namespaces()['intellij-lsp.references.qf']
  check('kotlin match is highlighted',
    #vim.api.nvim_buf_get_extmarks(0, ns, 0, -1, {}) == 1,
    #vim.api.nvim_buf_get_extmarks(0, ns, 0, -1, {}))
  browse.close(true)
  check('kotlin list closes', not browse.is_open())
end
-- grr is buffer-local, so it must exist on this Kotlin buffer.
vim.cmd('edit ' .. GREETER)
check('grr is mapped on the kotlin buffer',
  vim.fn.maparg('grr', 'n', false, true).buffer == 1,
  vim.inspect(vim.fn.maparg('grr', 'n', false, true).buffer))

local c = client:request_sync('textDocument/completion', {
  textDocument = vim.lsp.util.make_text_document_params(bufnr),
  position = { line = 4, character = 20 },
}, 30000, bufnr)
local items = c and c.result and (c.result.items or c.result)
check('kotlin completion', items and #items > 0)

print('')
print(failures == 0 and 'ALL KOTLIN CHECKS PASSED' or (failures .. ' KOTLIN CHECK(S) FAILED'))
vim.cmd(failures == 0 and 'qa!' or 'cq!')
