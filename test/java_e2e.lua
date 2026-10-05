-- End-to-end: real plugin -> real server -> real Maven import -> navigation.
--
--   IJLS_SERVER=<bundle>/bin/intellij-server \
--     nvim --headless -u NONE -l test/java_e2e.lua
--
-- Creates its own throwaway Maven project, so it is safe to run repeatedly.
vim.opt.runtimepath:prepend(vim.fs.dirname(vim.fs.dirname(debug.getinfo(1, 'S').source:sub(2))))
-- `-u NONE` leaves filetype detection off, and the plugin attaches on FileType.
vim.cmd('filetype plugin indent on')
vim.cmd('syntax off')

local SERVER = assert(vim.env.IJLS_SERVER, 'IJLS_SERVER not set')

-- fs_realpath: on macOS /tmp is a symlink to /private/tmp, and Neovim resolves buffer names to the
-- real path. A URI built from the unresolved path names a document the server never opened, so
-- every position-based request silently returns nothing.
local root = vim.fn.tempname() .. '-java'
vim.fn.mkdir(root .. '/src/main/java/com/example', 'p')
vim.fn.writefile({
  '<?xml version="1.0" encoding="UTF-8"?>',
  '<project xmlns="http://maven.apache.org/POM/4.0.0">',
  '  <modelVersion>4.0.0</modelVersion>',
  '  <groupId>com.example</groupId>',
  '  <artifactId>ijtest</artifactId>',
  '  <version>1.0-SNAPSHOT</version>',
  '  <properties>',
  '    <maven.compiler.source>17</maven.compiler.source>',
  '    <maven.compiler.target>17</maven.compiler.target>',
  '  </properties>',
  '</project>',
}, root .. '/pom.xml')
vim.fn.writefile({
  'package com.example;',
  '',
  'public class Greeter {',
  '    private final String name;',
  '',
  '    public Greeter(String name) {',
  '        this.name = name;',
  '    }',
  '',
  '    public String greet() {',
  '        return "Hello, " + name + "!";',
  '    }',
  '}',
}, root .. '/src/main/java/com/example/Greeter.java')
vim.fn.writefile({
  'package com.example;',
  '',
  'public class Main {',
  '    public static void main(String[] args) {',
  '        Greeter greeter = new Greeter("world");',
  '        System.out.println(greeter.greet());',
  '    }',
  '}',
}, root .. '/src/main/java/com/example/Main.java')

local PROJECT = vim.uv.fs_realpath(root)
local MAIN = PROJECT .. '/src/main/java/com/example/Main.java'
local GREETER = PROJECT .. '/src/main/java/com/example/Greeter.java'

local failures, notes = 0, {}
local function check(name, cond, detail)
  if cond then
    print('ok   ' .. name)
  else
    failures = failures + 1
    print('FAIL ' .. name .. (detail and ('  -> ' .. tostring(detail)) or ''))
  end
end
local function note(s) table.insert(notes, s) print('     .. ' .. s) end

require('intellij-lsp').setup({
  server_path = SERVER,
  accept_eula = true,
  build_tool = 'maven',
})

vim.cmd('edit ' .. MAIN)
local bufnr = vim.api.nvim_get_current_buf()
check('buffer filetype is java', vim.bo[bufnr].filetype == 'java', vim.bo[bufnr].filetype)

-- wait for attach
local client
vim.wait(120000, function()
  client = vim.lsp.get_clients({ name = 'intellij', bufnr = bufnr })[1]
  return client ~= nil
end, 500)
check('client attached', client ~= nil)
if not client then
  print('\nno client; aborting')
  vim.cmd('cq!')
end

note('server ' .. (client.server_info and client.server_info.name or '?') ..
     ' ' .. (client.server_info and client.server_info.version or '?'))

-- capabilities we depend on
local sc = client.server_capabilities
check('definitionProvider', sc.definitionProvider ~= nil)
check('referencesProvider', sc.referencesProvider ~= nil)
check('hoverProvider', sc.hoverProvider ~= nil)
check('documentSymbolProvider', sc.documentSymbolProvider ~= nil)
check('workspaceSymbolProvider', sc.workspaceSymbolProvider ~= nil)
check('completionProvider', sc.completionProvider ~= nil)
check('diagnosticProvider', sc.diagnosticProvider ~= nil)
check('indexDir reported', client.config.index_dir ~= nil, client.config.index_dir)
-- Not checks: what this bundle advertises, for the notes the unit tests cannot know.
note('executeCommandProvider.commands: ' .. vim.inspect(vim.tbl_get(sc, 'executeCommandProvider', 'commands')))
-- Was patched in by the plugin for bundles that registered the handler without advertising it.
check('bundle advertises documentRangeFormattingProvider', sc.documentRangeFormattingProvider ~= nil)

-- wait for indexing to finish (intellij/ready-for-test)
local progress = require('intellij-lsp.progress')
local ready = vim.wait(600000, function() return progress.is_ready(client.id) end, 1000)
check('indexing completed (intellij/ready-for-test)', ready)

-- `:edit` unloads and rereads the buffer, which detaches the client; the FileType that follows must
-- attach it again, to the same server.
vim.cmd('edit')
vim.wait(5000, function() return #vim.lsp.get_clients({ bufnr = bufnr, name = 'intellij' }) > 0 end, 50)
local reattached = vim.lsp.get_clients({ bufnr = bufnr, name = 'intellij' })[1]
check(':edit keeps the buffer attached', reattached ~= nil)
check(':edit reattaches to the same server', reattached and reattached.id == client.id, reattached and reattached.id)

-- navigation: Greeter on line 5 of Main.java -> Greeter.java
vim.api.nvim_win_set_cursor(0, { 5, 8 })
local defs = client:request_sync('textDocument/definition', {
  textDocument = vim.lsp.util.make_text_document_params(bufnr),
  position = { line = 4, character = 8 },
}, 30000, bufnr)
local dres = defs and defs.result
local duri = dres and ((dres[1] and (dres[1].uri or dres[1].targetUri)) or dres.uri)
check('definition resolves', duri ~= nil, vim.inspect(defs and defs.err or dres))
check('definition -> Greeter.java', duri and duri:find('Greeter.java', 1, true) ~= nil, duri)

-- hover
local hov = client:request_sync('textDocument/hover', {
  textDocument = vim.lsp.util.make_text_document_params(bufnr),
  position = { line = 4, character = 8 },
}, 30000, bufnr)
check('hover returns content', hov and hov.result and hov.result.contents ~= nil)

-- document symbols
local ds = client:request_sync('textDocument/documentSymbol', {
  textDocument = vim.lsp.util.make_text_document_params(bufnr),
}, 30000, bufnr)
check('documentSymbol returns symbols', ds and ds.result and #ds.result > 0,
  vim.inspect(ds and (ds.err or #(ds.result or {}))))

-- workspace symbols
local ws = client:request_sync('workspace/symbol', { query = 'Greeter' }, 30000, bufnr)
check('workspaceSymbol finds Greeter', ws and ws.result and #ws.result > 0,
  vim.inspect(ws and (ws.err or #(ws.result or {}))))

-- references on Greeter's declaration. The document must be open (so the server has it) and the
-- URI must match what Neovim sends for that buffer, which is the symlink-resolved real path.
vim.cmd('edit ' .. GREETER)
local gbuf = vim.api.nvim_get_current_buf()
local gline = vim.fn.readfile(GREETER)[3]
local gcol = (gline:find('Greeter', 1, true) or 1) - 1
local refs = client:request_sync('textDocument/references', {
  textDocument = vim.lsp.util.make_text_document_params(gbuf),
  position = { line = 2, character = gcol },
  context = { includeDeclaration = false },
}, 30000, gbuf)
check('references finds usage in Main', refs and refs.result and #refs.result > 0,
  vim.inspect(refs and (refs.err or #(refs.result or {}))))

-- The whole extmark feature presupposes the server returns a *range*, not just a position. Asserted
-- once against a live server, because test/references.lua can only assume it.
local rng = refs and refs.result and refs.result[1] and refs.result[1].range
check('references carry a non-empty range',
  rng and (rng['end'].character > rng.start.character or rng['end'].line > rng.start.line),
  vim.inspect(rng))

-- ...and now the plugin path over the same position: the previewing quickfix list.
local browse = require('intellij-lsp.references')
vim.api.nvim_win_set_cursor(0, { 3, gcol })
local gwin = vim.api.nvim_get_current_win()
browse.run({ include_declaration = false })
check('references list opens', vim.wait(30000, function() return browse.is_open() end),
  'timed out waiting for the quickfix list')

if browse.is_open() then
  local qlist = vim.fn.getqflist()
  check('list is populated', #qlist > 0, #qlist)
  check('focus stays in the list',
    vim.bo[vim.api.nvim_get_current_buf()].buftype == 'quickfix',
    vim.bo[vim.api.nvim_get_current_buf()].buftype)

  local ns = vim.api.nvim_get_namespaces()['intellij-lsp.references.qf']
  check('the selected match is highlighted',
    #vim.api.nvim_buf_get_extmarks(0, ns, 0, -1, {}) == 1,
    #vim.api.nvim_buf_get_extmarks(0, ns, 0, -1, {}))

  -- Stepping follows in the editor window, which is the other half of the request.
  local first_valid
  for i, it in ipairs(qlist) do
    if it.valid == 1 and it.bufnr and it.bufnr ~= vim.api.nvim_win_get_buf(gwin) then
      first_valid = i
      break
    end
  end
  if first_valid then
    vim.api.nvim_win_set_cursor(0, { first_valid, 0 })
    vim.cmd('doautocmd CursorMoved')
    vim.wait(500)
    check('editor window follows the selection',
      vim.api.nvim_win_get_buf(gwin) == qlist[first_valid].bufnr,
      vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(gwin)))
  else
    note('all references live in one file; follow-mode step not exercised')
  end

  browse.close(true)
  check('list closes and restores', not browse.is_open())
end

-- A JDK-typed reference with the declaration included: the row inside the JDK must be a navigable
-- one backed by decompiled source, not a `valid = 0` placeholder and not an empty phantom buffer.
vim.cmd('edit ' .. MAIN)
local mbuf = vim.api.nvim_get_current_buf()
local mlines = vim.fn.readfile(MAIN)
local sline, scol
for i, l in ipairs(mlines) do
  local c = l:find('String', 1, true)
  if c then
    sline, scol = i - 1, c - 1
    break
  end
end
if sline then
  vim.api.nvim_win_set_cursor(0, { sline + 1, scol })
  browse.run({ include_declaration = true })
  if vim.wait(30000, function() return browse.is_open() end) then
    local qwin = vim.api.nvim_get_current_win()
    local jdk_idx, jdk_row
    for i, r in ipairs(vim.fn.getqflist()) do
      local u = vim.tbl_get(r, 'user_data', 'uri') or ''
      if u:find('^jrt:') or u:find('^jar:') then
        jdk_idx, jdk_row = i, r
        break
      end
    end
    check('the String declaration shows up as a library row', jdk_row ~= nil)
    if jdk_row then
      check('library row is navigable', jdk_row.valid == 1, jdk_row.valid)
      check('library row carries decompiled text', (jdk_row.text or '') ~= '', ('%q'):format(jdk_row.text))
      check('library row is pinned to a filled buffer',
        jdk_row.bufnr and vim.api.nvim_buf_line_count(jdk_row.bufnr) > 2,
        jdk_row.bufnr and vim.api.nvim_buf_line_count(jdk_row.bufnr))
      vim.api.nvim_win_set_cursor(qwin, { jdk_idx, 0 })
      vim.cmd('doautocmd CursorMoved')
      vim.wait(500)
      local shown = vim.api.nvim_win_get_buf(gwin)
      check('stepping onto the library row previews the decompiled class', shown == jdk_row.bufnr,
        vim.api.nvim_buf_get_name(shown))
      check('preview sits on the declaration line',
        vim.api.nvim_buf_get_lines(shown, vim.api.nvim_win_get_cursor(gwin)[1] - 1,
          vim.api.nvim_win_get_cursor(gwin)[1], false)[1]:find('class String', 1, true) ~= nil,
        vim.api.nvim_win_get_cursor(gwin)[1])
    end
    browse.close(true)
    check('closing restores Main.java', vim.api.nvim_get_current_buf() == mbuf,
      vim.api.nvim_buf_get_name(0))
  else
    note('String references did not resolve; JDK-row check skipped')
  end
else
  note('no String usage in Main.java; JDK-row check skipped')
end

-- Definition into the JDK through Neovim's own handler, which sets the cursor to the location's
-- line as soon as the jar:/jrt: buffer is in the window. The String declaration sits deep inside
-- src.zip's String.java, so this only passes when the BufReadCmd filled the buffer synchronously;
-- the asynchronous placeholder failed here with "Invalid cursor line: out of range".
if sline then
  -- Not `:edit`: reloading the buffer detaches the client until the next FileType round-trip, and
  -- `vim.lsp.buf.definition` only asks clients attached to the buffer right now.
  vim.api.nvim_set_current_buf(mbuf)
  vim.wait(10000, function() return vim.lsp.get_clients({ bufnr = mbuf, name = 'intellij' })[1] ~= nil end, 100)
  vim.api.nvim_win_set_cursor(0, { sline + 1, scol })
  vim.lsp.buf.definition()
  local jumped = vim.wait(30000, function() return vim.api.nvim_get_current_buf() ~= mbuf end, 50)
  vim.wait(200)
  local jbuf = vim.api.nvim_get_current_buf()
  local jname = vim.api.nvim_buf_get_name(jbuf)
  check('definition of String opens a library buffer',
    jumped and (jname:find('jar:', 1, true) or jname:find('jrt:', 1, true)) ~= nil, jname)
  if jumped then
    check('library buffer holds the source, not a placeholder',
      vim.api.nvim_buf_line_count(jbuf) > 2, vim.api.nvim_buf_line_count(jbuf))
    -- The failed cursor move leaves you on line 1; the declaration is what the server pointed at.
    check('cursor sits on the String declaration',
      vim.api.nvim_get_current_line():find('class String', 1, true) ~= nil, vim.api.nvim_get_current_line())
    note('String resolved to ' .. jname .. ':' .. vim.api.nvim_win_get_cursor(0)[1])

    -- grr *inside* the decompiled class, on a method of it. The declaration is itself a JDK
    -- location, and the old implementation wiped every jar:/jrt: buffer -- this one included -- then
    -- announced that the row was "not listed here". Now it is a row, and q brings you back.
    local lib_win = vim.api.nvim_get_current_win()
    vim.wait(10000, function() return vim.lsp.get_clients({ bufnr = jbuf, name = 'intellij' })[1] ~= nil end, 100)
    local mline, mcol
    for i, l in ipairs(vim.api.nvim_buf_get_lines(jbuf, 0, -1, false)) do
      local c = l:find('public int length()', 1, true)
      if c then
        mline, mcol = i, c + #'public int ' - 1
        break
      end
    end
    if mline then
      vim.api.nvim_win_set_cursor(lib_win, { mline, mcol })
      browse.run({ include_declaration = true })
      if vim.wait(30000, function() return browse.is_open() end) then
        check('grr inside a decompiled class keeps that buffer alive', vim.api.nvim_buf_is_valid(jbuf))
        local decl
        for _, r in ipairs(vim.fn.getqflist()) do
          if r.bufnr == jbuf and r.lnum == mline then decl = r end
        end
        check('the declaration inside the JDK is a navigable row', decl ~= nil and decl.valid == 1,
          vim.inspect(decl))
        browse.close(true)
        check('q returns to the decompiled class',
          vim.api.nvim_get_current_buf() == jbuf and vim.api.nvim_win_get_cursor(0)[1] == mline,
          vim.inspect({ vim.api.nvim_buf_get_name(0), vim.api.nvim_win_get_cursor(0) }))
      else
        note('references from inside String.class did not resolve; in-library grr check skipped')
      end
    else
      note('String.length() not found in the decompiled source; in-library grr check skipped')
    end
  end
end

-- back to Main.java for the remaining buffer-relative checks
vim.cmd('edit ' .. MAIN)
bufnr = vim.api.nvim_get_current_buf()

-- completion after '.'
local comp = client:request_sync('textDocument/completion', {
  textDocument = vim.lsp.util.make_text_document_params(bufnr),
  position = { line = 5, character = 30 },
}, 30000, bufnr)
local items = comp and comp.result and (comp.result.items or comp.result)
check('completion returns items', items and #items > 0,
  vim.inspect(comp and (comp.err or (items and #items))))

-- diagnostics on a deliberately broken file (only meaningful once indexed)
local BROKEN = PROJECT .. '/src/main/java/com/example/Broken.java'
vim.fn.writefile({
  'package com.example;',
  '',
  'public class Broken {',
  '    public void oops() {',
  '        int x = "not an int";',
  '    }',
  '}',
}, BROKEN)
vim.cmd('edit ' .. BROKEN)
local bbuf = vim.api.nvim_get_current_buf()
vim.wait(3000)
local diag = client:request_sync('textDocument/diagnostic', {
  textDocument = vim.lsp.util.make_text_document_params(bbuf),
}, 60000, bbuf)
local ditems = diag and diag.result and (diag.result.items or {})
check('diagnostics reported on broken file', ditems and #ditems > 0,
  vim.inspect(diag and (diag.err or (ditems and #ditems))))
if ditems and ditems[1] then note('first diagnostic: ' .. tostring(ditems[1].message)) end

-- Code actions on that diagnostic, and applying one. With `intellijExtensions` (and, on a server
-- that knows it, `lazyIntentions`) every fix arrives as a `command`, so applying means executing it
-- and waiting for the server's `workspace/applyEdit` to land in the buffer.
local first_diag = ditems and ditems[1]
if first_diag then
  local ca = client:request_sync('textDocument/codeAction', {
    textDocument = vim.lsp.util.make_text_document_params(bbuf),
    range = first_diag.range,
    context = { diagnostics = { first_diag } },
  }, 60000, bbuf)
  local actions = ca and ca.result or {}
  check('code actions offered for the diagnostic', #actions > 0, vim.inspect(ca and ca.err))
  local titles = vim.tbl_map(function(a) return a.title end, actions)
  note('code actions: ' .. table.concat(titles, ' | '))

  -- Prefer a fix that rewrites the line, so the effect is visible in the buffer. The server's
  -- order varies between runs ("Organize imports" sometimes comes first, and is a no-op here), so
  -- pick by what the action does, not by position: a real ModCommand fix over a named command.
  local pick
  for _, a in ipairs(actions) do
    if a.title:find('[Ww]rap') or a.title:find('[Cc]hange') or a.title:find('[Cc]ast') then pick = a break end
  end
  if not pick then
    for _, a in ipairs(actions) do
      if a.command and a.command.command == 'applyModCommand' and not a.title:find('[Cc]lipboard') then pick = a break end
    end
  end
  pick = pick or actions[1]
  if pick then
    local before = table.concat(vim.api.nvim_buf_get_lines(bbuf, 0, -1, false), '\n')
    note('applying: ' .. pick.title .. (pick.command and (' via ' .. pick.command.command) or ' via edit'))
    if pick.command then
      local ex = client:request_sync('workspace/executeCommand', {
        command = pick.command.command, arguments = pick.command.arguments,
      }, 60000, bbuf)
      check('executeCommand for the fix succeeds', ex and not ex.err, vim.inspect(ex and ex.err))
    elseif pick.edit then
      vim.lsp.util.apply_workspace_edit(pick.edit, client.offset_encoding)
    end
    local changed = vim.wait(15000, function()
      return table.concat(vim.api.nvim_buf_get_lines(bbuf, 0, -1, false), '\n') ~= before
    end, 100)
    check('the fix changed the buffer', changed, vim.inspect(vim.api.nvim_buf_get_lines(bbuf, 0, -1, false)))
  end
end

-- textDocument/compilationErrors: the compiler's view of the same file (before the fix above
-- landed the server may or may not still see the type error, so only the shape is pinned).
local ce = client:request_sync('textDocument/compilationErrors', {
  textDocument = vim.lsp.util.make_text_document_params(bbuf),
}, 60000, bbuf)
check('compilationErrors answers a full report', ce and ce.result and ce.result.kind == 'full' and type(ce.result.items) == 'table',
  vim.inspect(ce and (ce.err or ce.result)))
note('compiler errors: ' .. tostring(ce and ce.result and #ce.result.items))

-- interpolateFileTemplate: package line derived from the file's place in the source tree. The file
-- has to exist on disk, which is what templates.lua's `apply` ensures before asking.
local FRESH = PROJECT .. '/src/main/java/com/example/Fresh.java'
vim.fn.writefile({}, FRESH)
vim.cmd('edit ' .. FRESH)
vim.wait(1000)
local tpl = require('intellij-lsp.templates').templates_for({}, 'java')[1]
local it = client:request_sync('workspace/executeCommand', {
  command = 'interpolateFileTemplate', arguments = { vim.uri_from_fname(FRESH), tpl.text },
}, 60000, 0)
local tpl_text = it and it.result
check('interpolateFileTemplate returns text', type(tpl_text) == 'string', vim.inspect(it and (it.err or it.result)))
if type(tpl_text) == 'string' then
  check('template carries the package line', tpl_text:find('package com.example;', 1, true) ~= nil, tpl_text)
  check('template carries the class name', tpl_text:find('class Fresh', 1, true) ~= nil, tpl_text)
  check('template keeps the cursor marker', tpl_text:find('|', 1, true) ~= nil, tpl_text)
end

-- exportWorkspace writes workspace.json for the imported model.
local ex_dir = PROJECT .. '/export'
vim.fn.mkdir(ex_dir, 'p')
local ew = client:request_sync('workspace/executeCommand', { command = 'exportWorkspace', arguments = { ex_dir } }, 60000, 0)
check('exportWorkspace succeeds', ew and not ew.err, vim.inspect(ew and ew.err))
check('workspace.json written', vim.fn.filereadable(ex_dir .. '/workspace.json') == 1)

-- The import state is also a request; the server reads the params as Unit and insists on a JSON
-- object, so `vim.empty_dict()`: a plain `{}` serialises as `[]` and is rejected, and nil is
-- rejected too.
local st = client:request_sync('intellij/workspaceImportState', vim.empty_dict(), 30000, 0)
check('workspaceImportState answers', st and st.result and st.result.phase ~= nil, vim.inspect(st and (st.err or st.result)))
note('import state: ' .. vim.inspect(st and st.result))
local last_state = require('intellij-lsp.progress').import_state(client.id)
note('import state notification received: ' .. tostring(last_state ~= nil) .. ' ' .. vim.inspect(last_state))

print('')
print(failures == 0 and 'ALL INTEGRATION CHECKS PASSED'
                     or (failures .. ' INTEGRATION CHECK(S) FAILED'))
vim.cmd(failures == 0 and 'qa!' or 'cq!')
