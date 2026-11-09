--- Runs and debugs JVM tests through the language server: the Run Test / Debug Test lenses, the
--- test at the cursor (IntelliJ's ContextRun / ContextDebug), and a rerun of the last one.
---
--- A test run is three server steps, every one of them answered by the server:
---
---   1. The lens names the test: `intellij.jvm.runTest` carries `{ testId, uri, moduleName,
---      noDebug }`, with `testId` a class (`com.acme.FooTest`) or a method (`com.acme.FooTest#bar`).
---   2. `intellij.jvm.resolveTestLaunch` turns that id into IntelliJ's own test runner: its main
---      class (`com.intellij.rt.junit.JUnitStarter`, or TestNG's), its arguments, and the runner's
---      jars. The module's own test class path is not in the answer.
---   3. A DAP launch with those, plus `tool = 'java'` and the runner's jars as
---      `additionalClassPaths`. The server adds them to the module's test runtime and runs the plain
---      JVM after the module's own build tool compiled the test scope.
---
--- `tool = 'java'` is not optional. Left to the module's tool (Maven, on 271.2085.0), the launch
--- compiles fine and then fails with `ClassNotFoundException: com.intellij.rt.junit.JUnitStarter`:
--- that route drops `additionalClassPaths`.
---
--- The runner does not print a readable report. It writes TeamCity service messages to stdout --
--- `##teamcity[testFailed name='bar()' message='...' details='...']`, the wire format the IDE's test
--- tree is built from -- mixed in with whatever the tests print. Everything below `Service messages`
--- turns that stream back into lines a person reads, a summary, and a quickfix list of failures.

local M = {}

local output = require('intellij-lsp.output')

-- -------------------------------------------------------------------------------------------------
-- Service messages
-- -------------------------------------------------------------------------------------------------

local MESSAGE_START = '##teamcity['

--- `|x` escapes, as the TeamCity library defines them. `|0xNNNN` is handled apart.
local ESCAPES = {
  n = '\n',
  r = '\r',
  b = '\b',
  x = '\194\133', -- U+0085 next line
  l = '\226\128\168', -- U+2028 line separator
  p = '\226\128\169', -- U+2029 paragraph separator
  ['|'] = '|',
  ["'"] = "'",
  ['['] = '[',
  [']'] = ']',
}

--- Reads the quoted value opening at `i` (the `'`).
--- @param s string
--- @param i integer
--- @return string|nil value nil for a value the line never closes
--- @return integer next the index just past the closing quote
local function read_value(s, i)
  local buf = {}
  local j = i + 1
  local n = #s
  while j <= n do
    local ch = s:sub(j, j)
    if ch == "'" then return table.concat(buf), j + 1 end
    if ch == '|' then
      local marker = s:sub(j + 1, j + 1)
      local hex = marker == '0' and s:sub(j + 2, j + 2) == 'x' and s:sub(j + 3, j + 6)
      if ESCAPES[marker] then
        buf[#buf + 1] = ESCAPES[marker]
        j = j + 2
      elseif hex and hex:match('^%x%x%x%x$') then
        buf[#buf + 1] = vim.fn.nr2char(tonumber(hex, 16))
        j = j + 7
      else
        -- An unknown escape stays literal, as the library keeps it.
        buf[#buf + 1] = ch
        j = j + 1
      end
    else
      buf[#buf + 1] = ch
      j = j + 1
    end
  end
  return nil, j
end

--- Parses one complete `##teamcity[name key='value' ...]` message.
---
--- Stops at the first malformed attribute and keeps what parsed before it, like the library. The
--- `##teamcity[name 'argument']` form parses too, with the argument and no attributes.
--- @param text string
--- @return { name: string, attributes: table<string, string>, argument: string|nil }|nil
function M._parse_message(text)
  local body = vim.trim(text):match('^##teamcity%[(.*)%]$')
  if not body then return nil end
  local name, pos = body:match('^%s*([^%s]+)()')
  if not name then return nil end
  local attributes = {}
  local i = pos
  while true do
    i = body:find('%S', i)
    if not i then break end
    if body:sub(i, i) == "'" then
      local argument = read_value(body, i)
      return { name = name, attributes = {}, argument = argument }
    end
    local eq = body:find('=', i, true)
    if not eq then break end
    local key = vim.trim(body:sub(i, eq - 1))
    i = body:find('%S', eq + 1)
    if key == '' or not i or body:sub(i, i) ~= "'" then break end
    local value, after = read_value(body, i)
    if not value then break end
    attributes[key] = value
    i = after
  end
  return { name = name, attributes = attributes }
end

--- The index of the `]` closing the message that opens at `start`, skipping escaped characters.
--- @param line string
--- @param start integer
--- @return integer|nil
local function message_end(line, start)
  local i = start + #MESSAGE_START
  while i <= #line do
    local ch = line:sub(i, i)
    if ch == '|' then
      i = i + 2
    elseif ch == ']' then
      return i
    else
      i = i + 1
    end
  end
  return nil
end

--- Splits one line of output into the messages it carries and the text around them.
---
--- The runner prints each message with `println` and no leading newline, so a test that printed
--- without a newline of its own leaves its text in front of the marker on the same line.
--- @param line string
--- @return (string|table)[] parts
function M._split_line(line)
  local parts = {}
  local rest = line
  while true do
    local start = rest:find(MESSAGE_START, 1, true)
    if not start then break end
    local stop = message_end(rest, start)
    local message = stop and M._parse_message(rest:sub(start, stop))
    if not message then break end
    if start > 1 then parts[#parts + 1] = rest:sub(1, start - 1) end
    parts[#parts + 1] = message
    rest = rest:sub(stop + 1)
  end
  if rest ~= '' or #parts == 0 then parts[#parts + 1] = rest end
  return parts
end

--- A line buffer over the output chunks of one stream: DAP `output` events may split a line, and a
--- message is only parseable once its line is complete.
--- @return { feed: fun(chunk: string): (string|table)[], flush: fun(): (string|table)[] }
function M._stream()
  local pending = ''
  local function parse(lines)
    local parts = {}
    for _, line in ipairs(lines) do vim.list_extend(parts, M._split_line(line)) end
    return parts
  end
  return {
    feed = function(chunk)
      local lines = vim.split((pending .. chunk):gsub('\r\n', '\n'):gsub('\r', '\n'), '\n', { plain = true })
      pending = table.remove(lines)
      return parse(lines)
    end,
    flush = function()
      local rest = pending
      pending = ''
      return rest ~= '' and parse({ rest }) or {}
    end,
  }
end

-- -------------------------------------------------------------------------------------------------
-- One run's report
-- -------------------------------------------------------------------------------------------------

--- @class IntellijLspTestResult
--- @field name string the runner's display name, e.g. `failsOnPurpose()`
--- @field location string|nil `java:test://com.acme.FooTest/bar` or `java:suite://com.acme.FooTest`
--- @field status 'running'|'passed'|'failed'|'skipped'|'interrupted'
--- @field message string|nil
--- @field expected string|nil
--- @field actual string|nil
--- @field details string|nil the stack trace

--- @class IntellijLspTestReport
--- @field tests table<string, IntellijLspTestResult>
--- @field order string[] test keys in the order they started
--- @field counts { passed: integer, failed: integer, skipped: integer }
--- @field exit_code integer|nil from the server's `Process finished with exit code N` line
--- @field stopped boolean the user stopped the run
local Report = {}
Report.__index = Report

--- @param emit fun(text: string, hl: string|nil) writes one panel line
--- @return IntellijLspTestReport
function M._report(emit)
  return setmetatable({
    emit = emit,
    tests = {},
    order = {},
    -- The current record of each name-only test, for a runner that sends no ids (JUnit 4).
    by_name = {},
    -- TestNG's configuration methods (`@BeforeMethod`, ...), which are not tests.
    configs = {},
    counts = { passed = 0, failed = 0, skipped = 0 },
    streams = {},
    started = vim.uv.now(),
  }, Report)
end

--- Writes multi-line text indented under a result line.
function Report:_emit_block(text, hl)
  for _, line in ipairs(vim.split(text, '\n', { plain = true })) do
    if line:match('%S') then self.emit('    ' .. line, hl) end
  end
end

--- The record a message is about.
---
--- `nodeId` is unique per invocation; a parametrized test repeats its `name`. JUnit 4's runner sends
--- no id at all, only the name, so a name-only `testStarted` for a name whose record already ended
--- (`works()` in two classes of one suite) opens a fresh record, and the name-only events after it
--- belong to that one.
--- @param attributes table<string, string>
--- @param starting boolean|nil the message is a `testStarted`
--- @return IntellijLspTestResult
function Report:_test(attributes, starting)
  local key = attributes.nodeId or attributes.id
  if not key then
    local name = attributes.name or '?'
    key = self.by_name[name]
    local current = key and self.tests[key]
    if not key or (starting and current.status ~= 'running') then
      key = ('%s\0%d'):format(name, #self.order + 1)
      self.by_name[name] = key
    end
  end
  local test = self.tests[key]
  if not test then
    test = { name = attributes.name or key, status = 'running' }
    self.tests[key] = test
    self.order[#self.order + 1] = key
  end
  if attributes.locationHint and attributes.locationHint ~= '' then test.location = attributes.locationHint end
  return test
end

--- Applies one service message.
--- @param message { name: string, attributes: table<string, string> }
function Report:message(message)
  local a = message.attributes
  local name = message.name
  local config_key = a.nodeId or a.id
  if config_key and (self.configs[config_key] or (name == 'testStarted' and a.config == 'true')) then
    -- A TestNG configuration method: not a test, so a success says nothing. A failure still does
    -- (a failing `@BeforeMethod` is why the tests after it are skipped), and counts as one.
    if name == 'testStarted' then
      self.configs[config_key] = true
      return
    elseif name ~= 'testFailed' then
      if name == 'testFinished' or name == 'testIgnored' then self.configs[config_key] = nil end
      return
    end
    self.configs[config_key] = nil
  end
  if name == 'testStarted' then
    self:_test(a, true)
  elseif name == 'testFailed' then
    local test = self:_test(a)
    -- A runner may report a second failure for one test (an assertion and then a failing
    -- `@AfterEach`); it counts once.
    if test.status ~= 'failed' then
      if test.status == 'passed' then self.counts.passed = self.counts.passed - 1 end
      self.counts.failed = self.counts.failed + 1
    end
    test.status = 'failed'
    test.message = test.message or a.message
    test.expected, test.actual = test.expected or a.expected, test.actual or a.actual
    test.details = test.details or a.details
    self.emit('✗ ' .. test.name, 'DiagnosticError')
    local summary = M._failure_text(test)
    if summary ~= '' then self:_emit_block(summary, 'DiagnosticError') end
    if a.details and a.details ~= '' then self:_emit_block(a.details, nil) end
  elseif name == 'testIgnored' then
    local test = self:_test(a)
    if test.status ~= 'skipped' then self.counts.skipped = self.counts.skipped + 1 end
    test.status = 'skipped'
    local why = a.message and a.message ~= '' and (' (' .. a.message .. ')') or ''
    self.emit('○ ' .. test.name .. why, 'Comment')
  elseif name == 'testFinished' then
    local test = self:_test(a)
    if test.status == 'running' then
      test.status = 'passed'
      self.counts.passed = self.counts.passed + 1
      local ms = tonumber(a.duration)
      self.emit('✓ ' .. test.name .. (ms and (' (%d ms)'):format(ms) or ''), 'DiagnosticOk')
    end
  elseif name == 'testSuiteStarted' then
    if a.name and a.name ~= '' then self.emit('▸ ' .. a.name, 'Title') end
  elseif name == 'testStdOut' or name == 'testStdErr' then
    local out = (a.out or ''):gsub('\n$', '')
    for _, line in ipairs(vim.split(out, '\n', { plain = true })) do
      self.emit(line, name == 'testStdErr' and 'WarningMsg' or nil)
    end
  end
  -- Everything else is the IDE's tree bookkeeping (`suiteTreeNode`, `rootName`, `treeEnded`,
  -- `enteredTheMatrix`, ...), which a flat report has no use for.
end

--- Feeds one DAP `output` event.
--- @param category string|nil `stdout`, `stderr`, or the server's own `console`
--- @param text string
function Report:feed(category, text)
  if category == 'console' then
    local line = vim.trim(text)
    if line ~= '' then self.emit(line, 'Comment') end
    -- The plain-JVM route sends no DAP `exited` event; this line is its only exit code.
    local code = line:match('Process finished with exit code (%-?%d+)')
    if code then self.exit_code = tonumber(code) end
    return
  end
  category = category or 'stdout'
  local stream = self.streams[category]
  if not stream then
    stream = M._stream()
    self.streams[category] = stream
  end
  self:_parts(stream.feed(text), category)
end

function Report:_parts(parts, category)
  local hl = require('intellij-lsp.progress')._import_hl
  for _, part in ipairs(parts) do
    if type(part) == 'table' then
      self:message(part)
    else
      -- The build that precedes the run streams through here too, hence the import log's colours.
      self.emit(part, hl(nil, part) or (category == 'stderr' and 'WarningMsg' or nil))
    end
  end
end

--- Flushes partial lines and writes the summary line.
---
--- Only a run that reported its tests and ended cleanly is a pass. A test still running when the
--- run ended (`System.exit`, a crash, `<C-c>`) is interrupted; a nonzero exit with no failure
--- reported, or a stop, fails the run even when every reported test passed. JUnit's runner exits
--- 255 when a test failed, so a nonzero code next to a reported failure says nothing new.
--- @param exit_code integer|nil the DAP `exited` code; else the server's console line's
--- @return { passed: integer, failed: integer, skipped: integer, interrupted: integer, exit_code: integer|nil, text: string, ok: boolean }
function Report:finish(exit_code)
  for category, stream in pairs(self.streams) do self:_parts(stream.flush(), category) end
  exit_code = exit_code or self.exit_code
  local interrupted = 0
  for _, key in ipairs(self.order) do
    local test = self.tests[key]
    if test.status == 'running' then
      test.status = 'interrupted'
      interrupted = interrupted + 1
      self.emit('! ' .. test.name .. ' (did not finish)', 'DiagnosticError')
    end
  end
  local c = self.counts
  local seconds = (vim.uv.now() - self.started) / 1000
  local text, ok
  if c.passed + c.failed + c.skipped + interrupted == 0 then
    ok = false
    if self.stopped then
      text = 'Stopped before any test ran.'
    elseif exit_code and exit_code ~= 0 then
      text = ('No tests ran: the run exited with code %d. The output above says why.'):format(exit_code)
    else
      text = 'No tests ran.'
    end
  else
    local parts = {}
    if c.failed > 0 then parts[#parts + 1] = ('%d failed'):format(c.failed) end
    if interrupted > 0 then parts[#parts + 1] = ('%d did not finish'):format(interrupted) end
    parts[#parts + 1] = ('%d passed'):format(c.passed)
    if c.skipped > 0 then parts[#parts + 1] = ('%d skipped'):format(c.skipped) end
    text = ('Tests: %s (%.1f s)'):format(table.concat(parts, ', '), seconds)
    local bad_exit = exit_code ~= nil and exit_code ~= 0 and c.failed == 0
    ok = c.failed == 0 and interrupted == 0 and not bad_exit and not self.stopped
    if self.stopped then
      text = text .. ', stopped'
    elseif bad_exit then
      text = text .. ('; the run exited with code %d'):format(exit_code)
    end
  end
  self.emit('--- ' .. text .. ' ---', ok and 'DiagnosticOk' or 'DiagnosticError')
  return { passed = c.passed, failed = c.failed, skipped = c.skipped, interrupted = interrupted,
    exit_code = exit_code, text = text, ok = ok }
end

--- The failed tests, in the order they ran.
--- @return IntellijLspTestResult[]
function Report:failures()
  local out = {}
  for _, key in ipairs(self.order) do
    if self.tests[key].status == 'failed' then out[#out + 1] = self.tests[key] end
  end
  return out
end

-- -------------------------------------------------------------------------------------------------
-- Failure locations
-- -------------------------------------------------------------------------------------------------

--- One line saying why a test failed: the assertion message, and expected/actual when the runner
--- split them out. AssertJ and JUnit 5 leave a bare `org.opentest4j.AssertionFailedError: ` message
--- with the values only in `expected` / `actual`.
--- @param test IntellijLspTestResult
--- @return string
function M._failure_text(test)
  local message = vim.trim((test.message or ''):gsub('%s*:%s*$', ''))
  -- The exception class alone says nothing the values do not.
  if test.expected and message:match('^[%w_.$]+$') then message = '' end
  if test.expected or test.actual then
    local values = ('expected: <%s> but was: <%s>'):format(test.expected or '', test.actual or '')
    message = message ~= '' and (message .. ': ' .. values) or values
  end
  return message
end

--- The class and method a runner location names.
--- @param location string|nil `java:test://com.acme.FooTest/bar` or `java:suite://com.acme.FooTest`
--- @return string|nil class
--- @return string|nil method
function M._location_parts(location)
  if not location then return nil, nil end
  local class, method = location:match('^java:test://([^/]+)/(.+)$')
  if class then return class, method end
  return location:match('^java:suite://(.+)$'), nil
end

--- The source line of a failure: the deepest frame of the test's own class in its stack trace,
--- which for an assertion is the line that asserted. A nested class (`FooTest$Inner`) counts as the
--- test class: JUnit 5's `@Nested` tests report the outer class's file.
---
--- A frame is read by its shape, not by what a method name may hold: a Kotlin test spelled with
--- backticks keeps its spaces in the frame (`at p.FooTest.adds two numbers(FooTest.kt:23)`), and a
--- JDK frame carries its module (`at java.base/java.lang.Thread.run(Thread.java:1583)`). Kotlin
--- names cannot contain a `.`, so the last one splits the class from the method.
--- @param details string|nil
--- @param class string|nil binary class name
--- @return integer|nil lnum 1-based
function M._failure_line(details, class)
  if not details or not class then return nil end
  for _, line in ipairs(vim.split(details, '\n', { plain = true })) do
    local reference, lnum = line:match('^%s*at%s+(.-)%([^()]*:(%d+)%)%s*$')
    if reference then
      reference = reference:gsub('^[^/]*/', '')
      local frame_class = reference:match('^(.*)%.[^.]*$')
      if frame_class == class or (frame_class and frame_class:sub(1, #class + 1) == class .. '$') then
        return tonumber(lnum)
      end
    end
  end
  return nil
end

-- -------------------------------------------------------------------------------------------------
-- Picking the test at the cursor
-- -------------------------------------------------------------------------------------------------

local SYMBOL_CLASS, SYMBOL_METHOD, SYMBOL_CONSTRUCTOR, SYMBOL_FUNCTION = 5, 6, 9, 12
local ENCLOSING = { [SYMBOL_CLASS] = true, [SYMBOL_METHOD] = true, [SYMBOL_CONSTRUCTOR] = true, [SYMBOL_FUNCTION] = true }

--- Whether a range holds the position (0-based row, 0-based byte column; nil column: any).
local function contains(range, row, col)
  if not range then return false end
  local s, e = range.start, range['end']
  if row < s.line or row > e.line then return false end
  if col == nil then return true end
  if row == s.line and col < s.character then return false end
  if row == e.line and col > e.character then return false end
  return true
end

--- The Run Test (or Debug Test) lens for the cursor, the way IntelliJ's ContextRun picks a test:
--- the innermost test method around the cursor, else the innermost test class, else the first
--- test class in the file.
---
--- The server puts each lens on the declaration's name only, not on its body, so a lens cannot be
--- picked by its own range: the document symbols say which method and class the cursor is in, and
--- the lens that starts on that symbol's name is the one wanted. By the name's columns, not just its
--- line: a one-line test class has the class's and the method's names on the same line.
--- @param lenses lsp.CodeLens[]
--- @param symbols lsp.DocumentSymbol[]
--- @param row integer 0-based cursor line
--- @param no_debug boolean
--- @param col integer|nil 0-based cursor column; nil matches by line only
--- @return lsp.CodeLens|nil
function M._pick_lens(lenses, symbols, row, no_debug, col)
  local tests = {}
  for _, lens in ipairs(lenses or {}) do
    local cmd = lens.command
    local args = cmd and cmd.command == 'intellij.jvm.runTest' and (cmd.arguments or {})[1]
    if args and (args.noDebug ~= false) == no_debug then tests[#tests + 1] = lens end
  end
  if #tests == 0 then return nil end

  -- The enclosing symbols, innermost first.
  local chain = {}
  local function walk(list)
    -- By line, so the indentation in front of a method still counts as the method. Columns only
    -- choose between declarations that share the line.
    -- With several on the line and the cursor in none of them, it is on their parent.
    local found, count, exact = nil, 0, nil
    for _, sym in ipairs(list or {}) do
      if ENCLOSING[sym.kind] and contains(sym.range, row) then
        found, count = found or sym, count + 1
        if not exact and contains(sym.range, row, col) then exact = sym end
      end
    end
    local sym = exact or (count == 1 and found or nil)
    if sym then
      table.insert(chain, 1, sym)
      walk(sym.children)
    end
  end
  walk(symbols)

  for _, sym in ipairs(chain) do
    local name_range = sym.selectionRange or sym.range
    for _, lens in ipairs(tests) do
      if contains(name_range, lens.range.start.line, lens.range.start.character) then return lens end
    end
  end
  -- A server whose symbol names and lenses disagree on columns: the names' lines, innermost first.
  for _, sym in ipairs(chain) do
    local name_range = sym.selectionRange or sym.range
    for _, lens in ipairs(tests) do
      if lens.range.start.line == name_range.start.line then return lens end
    end
  end
  -- Outside every test class (imports, a top-level helper): the whole file, as the first class lens.
  local first
  for _, lens in ipairs(tests) do
    local id = lens.command.arguments[1].testId or ''
    if not id:find('#', 1, true) and (not first or lens.range.start.line < first.range.start.line) then first = lens end
  end
  return first
end

-- -------------------------------------------------------------------------------------------------
-- Running
-- -------------------------------------------------------------------------------------------------

--- The run in flight, if any. Reserved the moment a run is asked for, before the server resolved
--- anything, so a second `<leader>rt` meanwhile is refused instead of racing the first.
---
--- `token` names the run in its launch configuration (`intellijTestRun`), which is how its DAP
--- session is recognised: by the launch it came from, not by a display name an older launch of the
--- same test shares. The server ignores the field, as it ignores VS Code's `testRunToken`.
---
--- `state` is `resolving` until the server answered `resolveTestLaunch`, `launching` until nvim-dap
--- created the session, then `running`.
--- @type { token: integer, name: string, report: IntellijLspTestReport, state: string, session_id: integer|nil, client_id: integer, uri: string, exit_code: integer|nil, launched: integer|nil }|nil
local active = nil
local next_token = 0

--- How long a launch may take to bring up its session before the reservation lapses. Only a launch
--- nvim-dap failed to connect lapses this way; the adapter's own failures release it at once.
local LAUNCH_DEADLINE_MS = 60000

--- The token field of a test run's launch configuration.
local TOKEN_FIELD = 'intellijTestRun'
M.TOKEN_FIELD = TOKEN_FIELD

--- What the last run was started with, for `rerun()`.
--- @type { args: table, client_id: integer }|nil
local last = nil

--- The newest run that has written the quickfix list, so a slow class lookup of an older run
--- cannot overwrite a newer run's list.
local quickfix_token = 0

--- Whether a nvim-dap session is the test run in flight.
--- @param session dap.Session|nil
--- @return boolean
function M.owns(session)
  if not active or not session then return false end
  if active.session_id then return active.session_id == session.id end
  -- Not bound yet: bound here, on `listeners.on_session` or on the session's first event.
  if active.state == 'launching' and session.config and session.config[TOKEN_FIELD] == active.token then
    active.session_id = session.id
    active.state = 'running'
    return true
  end
  return false
end

--- Gives up the reservation of the run with `token`, if it is still the one in flight.
--- @param token integer
--- @param message string|nil said in the panel and as a notification
local function release(token, message)
  if not active or active.token ~= token then return end
  active = nil
  if message then
    output.append('--- ' .. message .. ' ---', 'DiagnosticError')
    vim.notify('IntelliJ LSP: ' .. message, vim.log.levels.ERROR)
  end
end

--- Whether a run is in flight. A launch whose session never came up lapses after
--- `LAUNCH_DEADLINE_MS`; a bound session nvim-dap has already forgotten lapses at once.
local function busy()
  if not active then return false end
  if active.session_id then
    if require('dap').sessions()[active.session_id] ~= nil then return true end
  elseif active.state ~= 'launching' or vim.uv.now() - active.launched < LAUNCH_DEADLINE_MS then
    return true
  end
  active = nil
  return false
end

--- Called by `run.lua`'s adapter when it could not start a launch: no server for it, or the
--- server's debug server failed to start. Frees the run so the next one may start.
--- @param config table the launch configuration
--- @param reason string
function M._launch_failed(config, reason)
  local token = config and config[TOKEN_FIELD]
  if token then release(token, 'Test run did not start: ' .. reason) end
end

--- Stops the run in flight. One still resolving or launching has no session to terminate, so it is
--- dropped here; one with a session is marked stopped, so its report cannot pass, and `run.stop()`
--- terminates the session.
--- @return boolean handled true when there was nothing left for `run.stop()` to terminate
function M.stop()
  if not active then return false end
  if not active.session_id then
    release(active.token)
    output.append('--- Test run stopped ---', 'DiagnosticWarn')
    return true
  end
  active.report.stopped = true
  return false
end

--- A short, readable name for a test id: `FooTest#bar` for a method, `FooTest` for a class.
--- @param test_id string
--- @return string
function M._label(test_id)
  local class, method = test_id:match('^([^#]+)#(.+)$')
  class = class or test_id
  local simple = class:match('([^.]+)$') or class
  return method and (simple .. '#' .. method) or simple
end

local QUICKFIX_TITLE = 'IntelliJ: test failures'
M.QUICKFIX_TITLE = QUICKFIX_TITLE

--- Writes `items` as this module's quickfix list. A list of ours that is current is replaced, so
--- reruns do not pile lists onto the quickfix stack; any other current list is kept and a new one
--- pushed. A run without failures empties a current list of ours, and leaves anyone else's alone.
--- @param items table[]
local function write_quickfix(items)
  local current = vim.fn.getqflist({ title = 0 }).title
  local ours = current == QUICKFIX_TITLE
  if #items == 0 and not ours then return end
  vim.fn.setqflist({}, ours and 'r' or ' ', { title = QUICKFIX_TITLE, items = items })
end

--- Sets the quickfix list from the failures of a finished run, each on the line that asserted.
---
--- The runner names classes, not files, so each class goes through `intellij.java.resolveClassDocument`
--- once; a class the server cannot place falls back to the file the run was started from.
--- @param client vim.lsp.Client|nil
--- @param fallback_uri string
--- @param failures IntellijLspTestResult[]
--- @param done fun(items: table[])|nil
--- @param token integer|nil the run's; a run older than the last one to write the list writes nothing
function M._set_quickfix(client, fallback_uri, failures, done, token)
  token = token or (quickfix_token + 1)
  local uris = {}
  local classes = {}
  for _, test in ipairs(failures) do
    local class = M._location_parts(test.location)
    local top = class and class:gsub('%$.*$', '')
    if top and uris[top] == nil then
      uris[top] = false
      classes[#classes + 1] = top
    end
  end

  local function finish()
    local items = {}
    for _, test in ipairs(failures) do
      local class = M._location_parts(test.location)
      local top = class and class:gsub('%$.*$', '')
      local uri = top and uris[top] or fallback_uri
      items[#items + 1] = {
        filename = vim.uri_to_fname(uri),
        lnum = M._failure_line(test.details, class) or 1,
        text = test.name .. ': ' .. M._failure_text(test),
        type = 'E',
      }
    end
    if token >= quickfix_token then
      quickfix_token = token
      write_quickfix(items)
    end
    if done then done(items) end
  end

  local pending = #classes
  if pending == 0 or not client then return finish() end
  for _, fqn in ipairs(classes) do
    client:request('workspace/executeCommand', {
      command = 'intellij.java.resolveClassDocument',
      arguments = { { fqn = fqn } },
    }, function(err, result)
      if not err and type(result) == 'table' and result.uri then uris[fqn] = result.uri end
      pending = pending - 1
      if pending == 0 then vim.schedule(finish) end
    end)
  end
end

--- Listeners for the test of `M.on_finished`, and for anything else that wants a run's outcome.
--- @type table<string, fun(result: table)>
M.on_finished = {}

--- Ends the run in flight: summary line, quickfix list, notification.
local function finish_active()
  local run = active
  if not run then return end
  active = nil
  local result = run.report:finish(run.exit_code)
  local failures = run.report:failures()
  result.failures = failures
  local level = result.ok and vim.log.levels.INFO or vim.log.levels.WARN
  local client = vim.lsp.get_client_by_id(run.client_id)
  M._set_quickfix(client, run.uri, failures, function(items)
    result.quickfix = items
    local hint = #failures > 0 and ' -- :copen lists the failures' or ''
    vim.notify(('IntelliJ LSP: %s: %s%s'):format(run.name, result.text, hint), level)
    for _, fn in pairs(M.on_finished) do pcall(fn, result) end
  end, run.token)
end

local listeners_registered = false
local function ensure_listeners()
  if listeners_registered then return end
  listeners_registered = true
  local dap = require('dap')

  -- Binds the run to its session the moment nvim-dap creates it, before any event of it arrives.
  if dap.listeners.on_session then
    dap.listeners.on_session['intellij-lsp.test'] = function(_, new) M.owns(new) end
  end
  dap.listeners.after.event_output['intellij-lsp.test'] = function(session, body)
    if M.owns(session) and body and body.output then active.report:feed(body.category, body.output) end
  end
  dap.listeners.after.event_exited['intellij-lsp.test'] = function(session, body)
    if M.owns(session) then active.exit_code = body and body.exitCode end
  end
  dap.listeners.after.event_terminated['intellij-lsp.test'] = function(session)
    if M.owns(session) then finish_active() end
  end
  dap.listeners.after.disconnect['intellij-lsp.test'] = function(session)
    if M.owns(session) then finish_active() end
  end
end

--- Runs (or debugs) the test a `intellij.jvm.runTest` lens names.
--- @param args { testId: string, uri: string, moduleName: string|nil, noDebug: boolean|nil }
--- @param opts { client: vim.lsp.Client|nil }|nil
function M.run(args, opts)
  local run_mod = require('intellij-lsp.run')
  if not args or not args.testId or not args.uri then return end
  local c = run_mod._launch_client(args.uri, opts)
  if not c then return end
  if busy() then
    vim.notify('IntelliJ LSP: a test run is already in progress; <C-c> in the output panel stops it.',
      vim.log.levels.WARN)
    return
  end
  ensure_listeners()
  last = { args = args, client_id = c.id }
  local label = M._label(args.testId)
  local no_debug = args.noDebug ~= false
  local name = (no_debug and 'Test ' or 'Debug test ') .. label

  next_token = next_token + 1
  local token = next_token
  active = {
    token = token,
    name = name,
    report = M._report(output.append),
    state = 'resolving',
    client_id = c.id,
    uri = args.uri,
  }

  c:request('workspace/executeCommand', {
    command = 'intellij.jvm.resolveTestLaunch',
    arguments = { { testIds = { args.testId } } },
  }, function(err, launches)
    vim.schedule(function()
      -- Stopped, or superseded after a lapsed launch, while the server was answering.
      if not active or active.token ~= token then return end
      if err then
        release(token, 'could not resolve the test launch: ' .. tostring(err.message or err))
        return
      end
      -- One id names one class, and one class has one framework, so one launch. Several come only
      -- from a request naming classes of different frameworks, which nothing here sends.
      local l = type(launches) == 'table' and launches[1]
      if not l or not l.mainClass then
        release(token, 'the server found no test runner for ' .. label)
        return
      end

      output.append('--- ' .. name .. ' ---', 'Title')
      active.state = 'launching'
      active.launched = vim.uv.now()
      run_mod._dap_run(c, {
        name = name,
        mainClass = l.mainClass,
        args = l.args or {},
        -- A launch the server resolved for a file of its own (a Kotlin script) names it.
        file = vim.uri_to_fname(l.file or args.uri),
        additionalClassPaths = l.runtimeClasspath or {},
        additionalModulePaths = l.runtimeModulePath or {},
        tool = 'java',
        noDebug = no_debug,
        [TOKEN_FIELD] = token,
      })
    end)
  end)
end

--- Runs (or debugs) the test at the cursor: the method around it, else its class.
--- @param no_debug boolean|nil defaults to true
function M.run_at_cursor(no_debug)
  no_debug = no_debug == nil or no_debug
  local bufnr = vim.api.nvim_get_current_buf()
  local c = vim.lsp.get_clients({ bufnr = bufnr, name = require('intellij-lsp.client').NAME })[1]
  if not c then
    vim.notify('IntelliJ LSP: no server attached to this buffer.', vim.log.levels.ERROR)
    return
  end
  local cursor = vim.api.nvim_win_get_cursor(0)
  local row, col = cursor[1] - 1, cursor[2]
  local params = { textDocument = vim.lsp.util.make_text_document_params(bufnr) }
  c:request('textDocument/codeLens', params, function(lens_err, lenses)
    if lens_err then
      vim.notify('IntelliJ LSP: could not list the tests in this file: ' .. tostring(lens_err.message),
        vim.log.levels.ERROR)
      return
    end
    c:request('textDocument/documentSymbol', params, function(_, symbols)
      vim.schedule(function()
        local lens = M._pick_lens(lenses or {}, symbols or {}, row, no_debug, col)
        if not lens then
          vim.notify('IntelliJ LSP: no test at the cursor. The server shows a Run Test lens above each test it finds.',
            vim.log.levels.WARN)
          return
        end
        M.run(lens.command.arguments[1], { client = c })
      end)
    end, bufnr)
  end, bufnr)
end

--- Runs the last test run again, in the same mode.
function M.rerun()
  if not last then
    vim.notify('IntelliJ LSP: no test has run yet in this session.', vim.log.levels.WARN)
    return
  end
  M.run(last.args, { client = vim.lsp.get_client_by_id(last.client_id) })
end

function M.setup()
  vim.lsp.commands['intellij.jvm.runTest'] = function(command, ctx)
    local args = (command.arguments or {})[1]
    if not args then return end
    args = vim.tbl_extend('keep', args, { uri = vim.uri_from_bufnr(ctx and ctx.bufnr or 0) })
    M.run(args, { client = ctx and ctx.client_id and vim.lsp.get_client_by_id(ctx.client_id) or nil })
  end

  vim.api.nvim_create_user_command('IntellijLspTest', function() M.run_at_cursor(true) end, {
    desc = 'IntelliJ: run the test at the cursor (the method, else its class)',
  })
  vim.api.nvim_create_user_command('IntellijLspTestDebug', function() M.run_at_cursor(false) end, {
    desc = 'IntelliJ: debug the test at the cursor',
  })
  vim.api.nvim_create_user_command('IntellijLspTestLast', M.rerun, {
    desc = 'IntelliJ: run the last test run again',
  })
end

--- Forgets the run state, for tests.
function M._reset()
  active, last = nil, nil
  quickfix_token = 0
end

return M
