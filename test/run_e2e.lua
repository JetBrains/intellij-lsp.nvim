-- End-to-end: running a main class, and running and debugging JUnit 5 tests, against a real server.
--
--   IJLS_SERVER=<bundle>/bin/intellij-server IJLS_DAP=<nvim-dap checkout> \
--     nvim --headless -u NONE -l test/run_e2e.lua [maven|gradle]
--
-- Creates its own throwaway project, so it is safe to run repeatedly. Needs `mvn` or `gradle` on
-- PATH and JUnit 5.11.4 reachable (the local repository or Maven Central).
-- Absolute: the script `:cd`s into the project, which would strand a relative runtimepath entry.
vim.opt.runtimepath:prepend(vim.fs.dirname(vim.fs.dirname(vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p'))))
vim.opt.runtimepath:prepend(assert(vim.env.IJLS_DAP, 'IJLS_DAP not set (path to an nvim-dap checkout)'))
vim.cmd('filetype plugin indent on')
vim.cmd('syntax off')

local SERVER = assert(vim.env.IJLS_SERVER, 'IJLS_SERVER not set')
local TOOL = _G.arg and _G.arg[1] or 'maven'
assert(TOOL == 'maven' or TOOL == 'gradle', 'tool must be maven or gradle')

local root = vim.fn.tempname() .. '-run-' .. TOOL
vim.fn.mkdir(root .. '/src/main/java/com/example', 'p')
vim.fn.mkdir(root .. '/src/test/java/com/example', 'p')
if TOOL == 'maven' then
  vim.fn.writefile({
    '<?xml version="1.0" encoding="UTF-8"?>',
    '<project xmlns="http://maven.apache.org/POM/4.0.0">',
    '  <modelVersion>4.0.0</modelVersion>',
    '  <groupId>com.example</groupId>',
    '  <artifactId>ijrun</artifactId>',
    '  <version>1.0-SNAPSHOT</version>',
    '  <properties>',
    '    <maven.compiler.release>17</maven.compiler.release>',
    '    <project.build.sourceEncoding>UTF-8</project.build.sourceEncoding>',
    '  </properties>',
    '  <dependencies>',
    '    <dependency>',
    '      <groupId>org.junit.jupiter</groupId>',
    '      <artifactId>junit-jupiter</artifactId>',
    '      <version>5.11.4</version>',
    '      <scope>test</scope>',
    '    </dependency>',
    '  </dependencies>',
    '</project>',
  }, root .. '/pom.xml')
else
  vim.fn.writefile({ "rootProject.name = 'ijrun'" }, root .. '/settings.gradle')
  vim.fn.writefile({
    'plugins { id "java" }',
    'repositories { mavenCentral() }',
    'java { toolchain { languageVersion = JavaLanguageVersion.of(17) } }',
    'dependencies {',
    '  testImplementation "org.junit.jupiter:junit-jupiter:5.11.4"',
    '  testRuntimeOnly "org.junit.platform:junit-platform-launcher"',
    '}',
    'test { useJUnitPlatform() }',
  }, root .. '/build.gradle')
end
vim.fn.writefile({
  'package com.example;',
  '',
  'public class Greeter {',
  '    public String greet(String name) {',
  '        return "Hello, " + name + "!";',
  '    }',
  '}',
}, root .. '/src/main/java/com/example/Greeter.java')
vim.fn.writefile({
  'package com.example;',
  '',
  'public class Main {',
  '    public static void main(String[] args) {',
  '        System.out.println(new Greeter().greet("world"));',
  '    }',
  '}',
}, root .. '/src/main/java/com/example/Main.java')
local TEST_LINES = {
  'package com.example;', --  1
  '',
  'import static org.junit.jupiter.api.Assertions.assertEquals;',
  '',
  'import org.junit.jupiter.api.Disabled;', --  5
  'import org.junit.jupiter.api.Test;',
  '',
  'class GreeterTest {', --  8
  '    @Test',
  '    void greetsByName() {', -- 10
  '        String greeting = new Greeter().greet("world");',
  '        System.out.println("stdout from greetsByName");', -- 12
  '        assertEquals("Hello, world!", greeting);',
  '    }',
  '',
  '    @Test',
  '    void failsOnPurpose() {', -- 17
  '        assertEquals("Goodbye, world!", new Greeter().greet("world"));', -- 18
  '    }',
  '',
  '    @Test',
  '    @Disabled("not yet")',
  '    void skipped() {', -- 23
  '    }',
  '',
  '    private static String helper() {', -- 26
  '        return "x";',
  '    }',
  '}',
}
vim.fn.writefile(TEST_LINES, root .. '/src/test/java/com/example/GreeterTest.java')
-- A test run cut short: one test passes, the next ends the JVM before it reports.
vim.fn.writefile({
  'package com.example;',
  '',
  'import org.junit.jupiter.api.MethodOrderer;',
  'import org.junit.jupiter.api.Test;',
  'import org.junit.jupiter.api.TestMethodOrder;',
  '',
  '@TestMethodOrder(MethodOrderer.MethodName.class)',
  'class ExitTest {',
  '    @Test',
  '    void a_passes() {',
  '    }',
  '',
  '    @Test',
  '    void b_exits() {',
  '        System.exit(3);',
  '    }',
  '}',
}, root .. '/src/test/java/com/example/ExitTest.java')

local PROJECT = vim.uv.fs_realpath(root)
local MAIN = PROJECT .. '/src/main/java/com/example/Main.java'
local TEST = PROJECT .. '/src/test/java/com/example/GreeterTest.java'

local failures = 0
local function check(name, cond, detail)
  if cond then
    print('ok   ' .. name)
  else
    failures = failures + 1
    print('FAIL ' .. name .. (detail and ('  -> ' .. tostring(detail)) or ''))
  end
end
local function note(s) print('     .. ' .. s) end

require('intellij-lsp').setup({
  server_path = SERVER,
  accept_eula = true,
  region = 'europe',
  data_sharing = 'none',
  build_tool = TOOL,
})
vim.cmd('cd ' .. PROJECT)

local client_mod = require('intellij-lsp.client')
local output = require('intellij-lsp.output')
local test_mod = require('intellij-lsp.test')
local dap = require('dap')

vim.cmd('edit ' .. MAIN)
local client
vim.wait(120000, function()
  client = vim.lsp.get_clients({ name = client_mod.NAME })[1]
  return client ~= nil and client.initialized
end, 200)
check('client attached', client ~= nil)
if not client then vim.cmd('cq!') end
local ready = vim.wait(900000, function() return require('intellij-lsp.progress').is_ready(client.id) end, 1000)
check('import and indexing finished', ready)

local function panel_text()
  output._flush()
  return table.concat(vim.api.nvim_buf_get_lines(output.buf(), 0, -1, false), '\n')
end
local function lenses(path)
  vim.cmd('edit ' .. path)
  local buf = vim.api.nvim_get_current_buf()
  local r = client:request_sync('textDocument/codeLens', { textDocument = { uri = vim.uri_from_bufnr(buf) } }, 120000, buf)
  return r and r.result or {}, buf
end
local function find_lens(list, command, pred)
  for _, l in ipairs(list) do
    if l.command and l.command.command == command and pred(l.command.arguments[1]) then return l end
  end
end
--- Runs a lens's command the way `vim.lsp.codelens.run()` does.
local function click(l, bufnr)
  vim.lsp.commands[l.command.command](l.command, { client_id = client.id, bufnr = bufnr })
end

--- Puts the cursor on (row, col) of `buf` in an editor window. A run opens the output panel with
--- focus on its first output, as a user sees it, so every run after the first starts from there.
local function goto_pos(buf, row, col)
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_buf(win) ~= output.buf() and vim.api.nvim_win_get_config(win).relative == '' then
      vim.api.nvim_set_current_win(win)
      break
    end
  end
  vim.api.nvim_set_current_buf(buf)
  vim.api.nvim_win_set_cursor(0, { row, col })
end

-- A session's end, for the main-class launches (test runs report through `on_finished`).
local terminated, exit_code = 0, nil
dap.listeners.after.event_exited['run_e2e'] = function(_, body) exit_code = body and body.exitCode end
dap.listeners.after.event_terminated['run_e2e'] = function() terminated = terminated + 1 end

local finished = nil
test_mod.on_finished.run_e2e = function(result) finished = result end
local function wait_test(what)
  local ok = vim.wait(600000, function() return finished ~= nil end, 200)
  check(what .. ': the run finished', ok)
  local r = finished
  finished = nil
  if r then note(what .. ': ' .. r.text) end
  return r or {}
end

-- ---------------------------------------------------------------------------------------------
-- Main class
-- ---------------------------------------------------------------------------------------------
local main_lenses, main_buf = lenses(MAIN)
local run_main = find_lens(main_lenses, 'intellij.jvm.runMain', function(a) return a.noDebug ~= false end)
check('main: the server sends a Run lens', run_main ~= nil, vim.inspect(main_lenses))
check('main: lens titles carry no codicons', run_main and not run_main.command.title:find('$(', 1, true),
  run_main and run_main.command.title)
if run_main then
  output._reset()
  terminated, exit_code = 0, nil
  click(run_main, main_buf)
  check('main: the lens launch ends', vim.wait(600000, function() return terminated > 0 end, 200))
  check('main: exit code 0', exit_code == 0, tostring(exit_code))
  check('main: the program\'s output is in the panel', panel_text():find('Hello, world!', 1, true) ~= nil, panel_text())
  check('main: the build ran inside the launch', panel_text():find(TOOL == 'maven' and 'BUILD SUCCESS' or 'BUILD SUCCESSFUL', 1, true) ~= nil,
    panel_text())
end

-- `<leader>rr`: the class at the cursor, no lens involved.
output._reset()
terminated, exit_code = 0, nil
goto_pos(main_buf, 5, 8)
require('intellij-lsp.run').run_at_cursor(true)
check('main at cursor: ends', vim.wait(600000, function() return terminated > 0 end, 200))
check('main at cursor: exit 0 and output', exit_code == 0 and panel_text():find('Hello, world!', 1, true) ~= nil,
  tostring(exit_code) .. '\n' .. panel_text())

-- The Debug lens with a breakpoint in main: the debugger stops there, and the program then ends.
local debug_main = find_lens(main_lenses, 'intellij.jvm.runMain', function(a) return a.noDebug == false end)
check('main: the server sends a Debug lens', debug_main ~= nil)
if debug_main then
  local stopped_at = nil
  dap.listeners.after.event_stopped['run_e2e_main'] = function(session)
    vim.defer_fn(function()
      stopped_at = session.current_frame and session.current_frame.line or -1
      dap.continue()
    end, 500)
  end
  output._reset()
  terminated, exit_code = 0, nil
  goto_pos(main_buf, 5, 8)
  dap.toggle_breakpoint()
  click(debug_main, main_buf)
  check('debug main: the session ends', vim.wait(600000, function() return terminated > 0 end, 200))
  check('debug main: stopped on the breakpoint in main', stopped_at == 5, tostring(stopped_at))
  -- The plain-JVM route sends no DAP `exited` event, so the exit code is checked only when one came.
  check('debug main: then ran to the end', (exit_code == nil or exit_code == 0)
    and panel_text():find('Hello, world!', 1, true) ~= nil,
    tostring(exit_code) .. '\n' .. panel_text())
  dap.clear_breakpoints()
  dap.listeners.after.event_stopped['run_e2e_main'] = nil
end

-- ---------------------------------------------------------------------------------------------
-- Tests
-- ---------------------------------------------------------------------------------------------
local test_lenses, test_buf = lenses(TEST)
local count = 0
for _, l in ipairs(test_lenses) do if l.command and l.command.command == 'intellij.jvm.runTest' then count = count + 1 end end
-- The class, and its three test methods, a Run and a Debug lens each. `helper()` gets none.
check('tests: Run Test and Debug Test lenses on the class and each test method', count == 8, vim.inspect(test_lenses))

local class_lens = find_lens(test_lenses, 'intellij.jvm.runTest', function(a)
  return a.testId == 'com.example.GreeterTest' and a.noDebug ~= false
end)
check('tests: a Run Test lens for the class', class_lens ~= nil)
if class_lens then
  output._reset()
  click(class_lens, test_buf)
  local r = wait_test('class lens')
  check('class lens: 1 passed, 1 failed, 1 skipped', r.passed == 1 and r.failed == 1 and r.skipped == 1, vim.inspect(r))
  check('class lens: not ok', r.ok == false)
  local panel = panel_text()
  check('class lens: no raw service message in the panel', not panel:find('##teamcity', 1, true), panel)
  check('class lens: pass, fail and skip lines', panel:find('✓ greetsByName()', 1, true)
    and panel:find('✗ failsOnPurpose()', 1, true) and panel:find('○ skipped() (not yet)', 1, true), panel)
  check('class lens: why it failed', panel:find('expected: <Goodbye, world!> but was: <Hello, world!>', 1, true), panel)
  check('class lens: the test\'s own stdout', panel:find('stdout from greetsByName', 1, true), panel)
  local qf = vim.fn.getqflist({ title = 1, items = 1 })
  local item = qf.items[1]
  check('class lens: one quickfix entry, on the asserting line of GreeterTest.java', #qf.items == 1 and item
    and vim.api.nvim_buf_get_name(item.bufnr) == TEST and item.lnum == 18, vim.inspect(qf))
  check('class lens: the entry says why', item and item.text == 'failsOnPurpose(): expected: <Goodbye, world!> but was: <Hello, world!>',
    item and item.text)
end

-- `<leader>rt` inside a test method's body: that method only.
goto_pos(test_buf, 12, 10)
test_mod.run_at_cursor(true)
local r = wait_test('cursor in greetsByName')
check('cursor in a test method: runs that method only', r.passed == 1 and r.failed == 0 and r.skipped == 0 and r.ok,
  vim.inspect(r))

-- `<leader>rt` in a helper that is no test: the class.
goto_pos(test_buf, 27, 8)
test_mod.run_at_cursor(true)
r = wait_test('cursor in helper')
check('cursor in a helper: runs the class', r.passed == 1 and r.failed == 1 and r.skipped == 1, vim.inspect(r))

-- `<leader>rt` on the failing method.
goto_pos(test_buf, 18, 10)
test_mod.run_at_cursor(true)
r = wait_test('cursor in failsOnPurpose')
check('cursor in a failing test: one failure', r.failed == 1 and r.passed == 0 and not r.ok, vim.inspect(r))

-- `<leader>rT`: the last run again.
test_mod.rerun()
r = wait_test('rerun')
check('rerun: the same test again', r.failed == 1 and r.passed == 0, vim.inspect(r))

-- `<leader>dt` with a breakpoint in the method: the debugger stops there, then the test passes.
local stopped_line = nil
dap.listeners.after.event_stopped['run_e2e'] = function(session)
  vim.defer_fn(function()
    local frame = session.current_frame
    stopped_line = frame and frame.line or -1
    dap.continue()
  end, 500)
end
goto_pos(test_buf, 13, 8)
dap.toggle_breakpoint()
test_mod.run_at_cursor(false)
r = wait_test('debug greetsByName')
check('debug test: stopped on the breakpoint', stopped_line == 13, tostring(stopped_line))
check('debug test: then passed', r.passed == 1 and r.ok, vim.inspect(r))
dap.clear_breakpoints()
dap.listeners.after.event_stopped['run_e2e'] = nil

-- A test that ends the JVM mid-run: the run is not a pass, though every reported test passed.
local exit_lenses, exit_buf = lenses(PROJECT .. '/src/test/java/com/example/ExitTest.java')
local exit_lens = find_lens(exit_lenses, 'intellij.jvm.runTest', function(a)
  return a.testId == 'com.example.ExitTest' and a.noDebug ~= false
end)
check('System.exit: a lens for the class', exit_lens ~= nil, vim.inspect(exit_lenses))
if exit_lens then
  click(exit_lens, exit_buf)
  r = wait_test('System.exit')
  check('System.exit: not ok', r.ok == false, vim.inspect(r))
  check('System.exit: the passing test counts, the cut-off one did not finish', r.passed == 1 and r.interrupted == 1,
    vim.inspect(r))
  check('System.exit: the exit code is known', r.exit_code == 3, vim.inspect(r))
end

-- A test that does not compile: the run says so instead of reporting a pass.
local broken = vim.deepcopy(TEST_LINES)
broken[11] = '        String greeting = new Greeter().greet(42);'
vim.fn.writefile(broken, TEST)
goto_pos(test_buf, 1, 0)
vim.cmd('edit!')
goto_pos(vim.api.nvim_get_current_buf(), 12, 10)
output._reset()
test_mod.run_at_cursor(true)
r = wait_test('broken test')
check('compile error: no test ran, not ok', r.ok == false and (r.passed or 0) + (r.failed or 0) == 0, vim.inspect(r))
check('compile error: the build error is in the panel', panel_text():find('ERROR', 1, true) ~= nil
  or panel_text():find('error:', 1, true) ~= nil, panel_text())
vim.fn.writefile(TEST_LINES, TEST)

print(failures == 0 and '\nALL RUN E2E CHECKS PASSED' or ('\n' .. failures .. ' RUN E2E CHECK(S) FAILED'))
vim.cmd(failures == 0 and 'qa!' or 'cq!')
