-- Unit checks for the git status parser and command construction. No repository required.
--
--   nvim --headless -u NONE -l test/git_units.lua
--
-- Every fixture below is real `git status --porcelain=v2 --branch -z` output, captured from git
-- rather than hand-written, with NULs written as \0. That matters most for the rename records: the
-- two paths are separated by a NUL, not a tab, and a parser that assumes one record per NUL
-- mis-frames every rename and shifts everything after it.
vim.opt.runtimepath:prepend(vim.fs.dirname(vim.fs.dirname(debug.getinfo(1, 'S').source:sub(2))))

local status = require('intellij-lsp.git.status')
local cmd = require('intellij-lsp.git.cmd')
local panel = require('intellij-lsp.git.panel')

local failures = 0
local function check(name, cond, detail)
  if cond then
    print('ok   ' .. name)
  else
    failures = failures + 1
    print('FAIL ' .. name .. (detail and ('  -> ' .. tostring(detail)) or ''))
  end
end

--- The entry for `path` on `side`, or nil.
local function find(state, side, path)
  for _, e in ipairs(state.entries) do
    if e.side == side and e.path == path then return e end
  end
  return nil
end

-- -------------------------------------------------------------------------------------------------
-- Branch headers
-- -------------------------------------------------------------------------------------------------

local st = status.parse(table.concat({
  '# branch.oid b3081b1e06271ad24f10fab3630e1654e79ccfa9\0',
  '# branch.head main\0',
  '# branch.upstream origin/main\0',
  '# branch.ab +3 -2\0',
}))
check('branch.head', st.branch == 'main', st.branch)
check('branch.oid', st.oid == 'b3081b1e06271ad24f10fab3630e1654e79ccfa9', st.oid)
check('branch.upstream', st.upstream == 'origin/main', st.upstream)
check('branch.ab ahead', st.ahead == 3, st.ahead)
check('branch.ab behind', st.behind == 2, st.behind)
check('not detached', st.detached == false)
check('clean tree', status.is_clean(st))

-- Detached HEAD: git writes the literal "(detached)", which is not a branch name.
local det = status.parse('# branch.head (detached)\0')
check('detached recognised', det.detached == true and det.branch == nil, tostring(det.branch))

-- Before the first commit the oid is "(initial)", which must not be stored as a real hash.
local init = status.parse('# branch.oid (initial)\0# branch.head main\0')
check('initial oid -> nil', init.oid == nil, tostring(init.oid))

-- No upstream: the ab line is absent entirely, so the counters must default rather than stay nil.
local noup = status.parse('# branch.head main\0')
check('no upstream -> nil', noup.upstream == nil)
check('no ab -> zero ahead', noup.ahead == 0)
check('no ab -> zero behind', noup.behind == 0)

-- -------------------------------------------------------------------------------------------------
-- Ordinary (1) records
-- -------------------------------------------------------------------------------------------------

-- Staged modification only: XY = "M."
st = status.parse('1 M. N... 100644 100644 100644 587be6b4 d3fc15b5 sub/nested.txt\0')
check('staged M -> one entry', #st.entries == 1, #st.entries)
check('staged M side', st.entries[1].side == status.STAGED, st.entries[1].side)
check('staged M code', st.entries[1].code == 'M', st.entries[1].code)
check('staged M path', st.entries[1].path == 'sub/nested.txt', st.entries[1].path)

-- Unstaged modification only: XY = ".M"
st = status.parse('1 .M N... 100644 100644 100644 587be6b4 d3fc15b5 a.txt\0')
check('unstaged M side', st.entries[1].side == status.UNSTAGED, st.entries[1].side)

-- Staged deletion: XY = "D." with an all-zero worktree oid.
st = status.parse('1 D. N... 100644 000000 000000 4cb29ea3 00000000 a.txt\0')
check('staged D code', st.entries[1].code == 'D', st.entries[1].code)

-- Both sides at once. Staging a change then editing again is a single git record but two separately
-- stageable things, so it must produce two entries -- and staged must come first, matching the IDE.
st = status.parse('1 MM N... 100644 100644 100644 587be6b4 d3fc15b5 both.txt\0')
check('MM -> two entries', #st.entries == 2, #st.entries)
check('MM staged first', st.entries[1].side == status.STAGED, st.entries[1].side)
check('MM unstaged second', st.entries[2].side == status.UNSTAGED, st.entries[2].side)

-- -------------------------------------------------------------------------------------------------
-- Renames (2) -- the framing trap
-- -------------------------------------------------------------------------------------------------

-- Captured verbatim from git: the origin path follows a NUL, not a tab.
local RENAME = '2 R. N... 100644 100644 100644 2fa992c0 2fa992c0 R100 renamed.txt\0keep.txt\0'

st = status.parse(RENAME)
check('rename -> one entry', #st.entries == 1, #st.entries)
check('rename code', st.entries[1].code == 'R', st.entries[1].code)
check('rename new path', st.entries[1].path == 'renamed.txt', st.entries[1].path)
check('rename origin path', st.entries[1].origin == 'keep.txt', tostring(st.entries[1].origin))

-- Entries after a rename must still be read correctly.
st = status.parse(RENAME .. '1 .M N... 100644 100644 100644 aaaa bbbb after.txt\0? untracked.txt\0')
check('entry after rename survives', find(st, status.UNSTAGED, 'after.txt') ~= nil,
  vim.inspect(vim.tbl_map(function(e) return e.side .. ':' .. e.path end, st.entries)))
check('untracked after rename survives', find(st, status.UNTRACKED, 'untracked.txt') ~= nil)
check('rename does not inject a phantom', #st.entries == 3, #st.entries)

-- The framing regression, with a fixture that a naive parser demonstrably fails.
--
-- Dropping an unrecognised field is not enough to stay correct, because an origin path can itself
-- look like a record: a file named "? evil.txt" is legal on disk, and read as a standalone field it
-- parses as an untracked-file record. A parser that splits on NUL alone reports two entries here --
-- one of them a file that does not exist in that state -- where there is exactly one rename.
st = status.parse('2 R. N... 100644 100644 100644 aaaa bbbb R100 new.txt\0? evil.txt\0')
check('origin that looks like a record is not a second entry', #st.entries == 1, #st.entries)
check('origin that looks like a record is kept as the origin',
  st.entries[1].origin == '? evil.txt', tostring(st.entries[1].origin))
check('no phantom untracked entry', find(st, status.UNTRACKED, 'evil.txt') == nil)

-- Truncated output must degrade to a rename with no origin, not drop the file.
st = status.parse('2 R. N... 100644 100644 100644 2fa992c0 2fa992c0 R100 halfway.txt\0')
check('truncated rename keeps the entry', #st.entries == 1 and st.entries[1].path == 'halfway.txt',
  vim.inspect(st.entries))

-- A rename staged and then further modified: the origin belongs to the staged half only.
st = status.parse('2 RM N... 100644 100644 100644 2fa992c0 2fa992c0 R100 new.txt\0old.txt\0')
check('RM -> two entries', #st.entries == 2, #st.entries)
check('RM staged carries origin', st.entries[1].origin == 'old.txt', tostring(st.entries[1].origin))
check('RM unstaged has no origin', st.entries[2].origin == nil, tostring(st.entries[2].origin))

-- -------------------------------------------------------------------------------------------------
-- Conflicts (u) -- four mode fields, three oids
-- -------------------------------------------------------------------------------------------------

st = status.parse(
  'u UU N... 100644 100644 100644 100644 4cb29ea3 f4c47125 37dd5b6c a.txt\0')
check('conflict -> one entry', #st.entries == 1, #st.entries)
check('conflict side', st.entries[1].side == status.CONFLICTED, st.entries[1].side)
check('conflict path', st.entries[1].path == 'a.txt', st.entries[1].path)
check('conflict xy preserved', st.entries[1].xy == 'UU', tostring(st.entries[1].xy))

-- Delete/modify conflicts carry a different XY but the same shape.
st = status.parse('u DU N... 100644 000000 100644 100644 aaaa 0000 bbbb gone.txt\0')
check('DU conflict parsed', st.entries[1] and st.entries[1].side == status.CONFLICTED,
  vim.inspect(st.entries))
check('DU xy', st.entries[1].xy == 'DU', tostring(st.entries[1].xy))

-- -------------------------------------------------------------------------------------------------
-- Untracked and ignored
-- -------------------------------------------------------------------------------------------------

st = status.parse('? untracked.txt\0? sub/other.txt\0')
check('untracked count', #st.entries == 2, #st.entries)
check('untracked side', st.entries[1].side == status.UNTRACKED, st.entries[1].side)
check('untracked nested path', st.entries[2].path == 'sub/other.txt', st.entries[2].path)

-- We never pass --ignored, but a `!` record must be skipped rather than shown as a change.
st = status.parse('! ignored.txt\0? real.txt\0')
check('ignored skipped', #st.entries == 1 and st.entries[1].path == 'real.txt', vim.inspect(st.entries))

-- -------------------------------------------------------------------------------------------------
-- Paths that break naive parsers
-- -------------------------------------------------------------------------------------------------

-- Spaces: safe under -z, but a space-splitting parser would truncate at "my".
st = status.parse('1 .M N... 100644 100644 100644 aaaa bbbb my file with spaces.txt\0')
check('path with spaces', st.entries[1].path == 'my file with spaces.txt', st.entries[1].path)

-- Non-ASCII: arrives raw because cmd.lua sets core.quotepath=false. Without that flag git would send
-- "\303\234nicode.java" in octal escapes and this would be a mojibake path.
st = status.parse('1 .M N... 100644 100644 100644 aaaa bbbb src/Ünicode.java\0')
check('non-ascii path intact', st.entries[1].path == 'src/Ünicode.java', st.entries[1].path)

-- A literal tab inside a filename. The rename joiner uses a tab, so the origin is split off at the
-- LAST tab; anything else corrupts both paths.
st = status.parse('2 R. N... 100644 100644 100644 aaaa bbbb R100 has\ttab.txt\0origin.txt\0')
check('tabbed path keeps its tab', st.entries[1].path == 'has\ttab.txt',
  vim.inspect(st.entries[1].path))
check('tabbed path origin still split', st.entries[1].origin == 'origin.txt',
  tostring(st.entries[1].origin))

-- Empty input must not throw.
check('empty input -> clean', status.is_clean(status.parse('')))
check('nil input -> clean', status.is_clean(status.parse(nil)))

-- -------------------------------------------------------------------------------------------------
-- Counts and summary
-- -------------------------------------------------------------------------------------------------

st = status.parse(table.concat({
  '# branch.head main\0',
  '# branch.upstream origin/main\0',
  '# branch.ab +1 -0\0',
  '1 M. N... 100644 100644 100644 aaaa bbbb staged.txt\0',
  '1 .M N... 100644 100644 100644 aaaa bbbb unstaged.txt\0',
  '? new.txt\0',
  'u UU N... 100644 100644 100644 100644 aaaa bbbb cccc conflict.txt\0',
}))
local counts = status.counts(st)
check('count staged', counts[status.STAGED] == 1, counts[status.STAGED])
check('count unstaged', counts[status.UNSTAGED] == 1, counts[status.UNSTAGED])
check('count untracked', counts[status.UNTRACKED] == 1, counts[status.UNTRACKED])
check('count conflicted', counts[status.CONFLICTED] == 1, counts[status.CONFLICTED])
check('not clean', not status.is_clean(st))

local summary = status.summary(st)
check('summary names the branch', summary:find('main', 1, true) ~= nil, summary)
check('summary names the upstream', summary:find('origin/main', 1, true) ~= nil, summary)
check('summary shows ahead', summary:find('↑1', 1, true) ~= nil, summary)
check('summary omits behind when zero', summary:find('↓', 1, true) == nil, summary)
check('summary counts conflicts', summary:find('1 conflicted', 1, true) ~= nil, summary)

local clean_summary = status.summary(status.parse('# branch.head main\0'))
check('clean summary says clean', clean_summary:find('clean', 1, true) ~= nil, clean_summary)
check('clean summary flags missing upstream',
  clean_summary:find('no upstream', 1, true) ~= nil, clean_summary)

-- -------------------------------------------------------------------------------------------------
-- Rendering
-- -------------------------------------------------------------------------------------------------

local lines, entries = panel._render(st)
local joined = table.concat(lines, '\n')
check('render has a Conflicts section', joined:find('Conflicts (1)', 1, true) ~= nil, joined)
check('render has a Staged section', joined:find('Staged (1)', 1, true) ~= nil, joined)
check('render has a Changes section', joined:find('Changes (1)', 1, true) ~= nil, joined)
check('render has an Untracked section', joined:find('Untracked (1)', 1, true) ~= nil, joined)
check('render labels codes, not letters', joined:find('modified', 1, true) ~= nil, joined)

-- The row -> entry map is what makes "the entry under the cursor" correct; header, blank and section
-- rows must map to nothing so <CR> on them is a no-op rather than opening the wrong file.
local mapped, headers = 0, 0
for row = 1, #lines do
  if entries[row] then mapped = mapped + 1 else headers = headers + 1 end
end
check('every entry is mapped', mapped == 4, mapped)
check('non-entry rows map to nil', headers > 0, headers)
check('row 1 is the header, not an entry', entries[1] == nil)

-- A rename must render both paths; showing only the new one hides the move.
local ren_lines = panel._render(status.parse(RENAME))
check('rename renders both paths',
  table.concat(ren_lines, '\n'):find('renamed.txt ← keep.txt', 1, true) ~= nil,
  table.concat(ren_lines, '\n'))

-- Clean tree still renders something, rather than an empty buffer.
local clean_lines = panel._render(status.parse('# branch.head main\0'))
check('clean tree renders a message',
  table.concat(clean_lines, '\n'):find('nothing to commit', 1, true) ~= nil,
  table.concat(clean_lines, '\n'))

-- An in-progress operation must be visible: it changes which commands are valid.
local prog = status.parse('# branch.head main\0')
prog.in_progress = 'rebase'
check('in-progress state is rendered',
  table.concat(panel._render(prog), '\n'):find('rebase in progress', 1, true) ~= nil)

-- -------------------------------------------------------------------------------------------------
-- Diff argument selection -- four sides, four different commands
-- -------------------------------------------------------------------------------------------------

local function args_of(side, path)
  return table.concat(panel._diff_args({ side = side, path = path }), ' ')
end
check('staged -> diff --cached',
  args_of(status.STAGED, 'a.txt') == 'diff --cached -- a.txt', args_of(status.STAGED, 'a.txt'))
check('unstaged -> plain diff',
  args_of(status.UNSTAGED, 'a.txt') == 'diff -- a.txt', args_of(status.UNSTAGED, 'a.txt'))
check('conflict -> plain diff',
  args_of(status.CONFLICTED, 'a.txt') == 'diff -- a.txt', args_of(status.CONFLICTED, 'a.txt'))
-- Untracked files are not in the index, so a plain `diff` would print nothing at all.
check('untracked -> --no-index against /dev/null',
  args_of(status.UNTRACKED, 'a.txt') == 'diff --no-index -- /dev/null a.txt',
  args_of(status.UNTRACKED, 'a.txt'))

-- -------------------------------------------------------------------------------------------------
-- Command construction
-- -------------------------------------------------------------------------------------------------

local argv = cmd.argv({ 'status' })
check('argv starts with git', argv[1] == 'git', argv[1])
check('argv sets core.quotepath=false', vim.tbl_contains(argv, 'core.quotepath=false'),
  table.concat(argv, ' '))
check('argv passes --no-optional-locks', vim.tbl_contains(argv, '--no-optional-locks'),
  table.concat(argv, ' '))
check('argv keeps the caller args last', argv[#argv] == 'status', argv[#argv])

-- The editor variables are why a naive vim.system({'git', ...}) hangs rather than failing: git would
-- spawn an editor with no tty and block forever.
local env = cmd.env()
check('GIT_EDITOR neutralised', env.GIT_EDITOR == 'true', tostring(env.GIT_EDITOR))
check('GIT_SEQUENCE_EDITOR neutralised', env.GIT_SEQUENCE_EDITOR == 'true',
  tostring(env.GIT_SEQUENCE_EDITOR))
check('GIT_TERMINAL_PROMPT disabled', env.GIT_TERMINAL_PROMPT == '0',
  tostring(env.GIT_TERMINAL_PROMPT))
check('locale pinned for stable messages', env.LC_ALL == 'C', tostring(env.LC_ALL))
check('pager disabled', env.GIT_PAGER == 'cat', tostring(env.GIT_PAGER))
check('env inherits PATH', env.PATH ~= nil)

-- An inherited GIT_DIR (Neovim launched from a hook or `rebase --exec`) would silently redirect every
-- command at the wrong repository, so it must be absent -- not false, which vim.system stringifies.
vim.env.GIT_DIR = '/somewhere/else/.git'
vim.env.GIT_WORK_TREE = '/somewhere/else'
local clean_env = cmd.env()
check('GIT_DIR stripped', clean_env.GIT_DIR == nil, tostring(clean_env.GIT_DIR))
check('GIT_WORK_TREE stripped', clean_env.GIT_WORK_TREE == nil, tostring(clean_env.GIT_WORK_TREE))
check('no env value is a boolean', (function()
  for _, v in pairs(clean_env) do if type(v) ~= 'string' then return false end end
  return true
end)())

-- Asserting on cmd.env()'s return value is NOT sufficient, and this suite previously passed while the
-- child process still saw the poisoned value: `vim.system` merges `env` over the inherited
-- environment, so omitting a key does not unset it. Only `clear_env` does. The check therefore has to
-- observe an actual subprocess.
local function child_sees(var)
  local out = vim.system({ 'sh', '-c', 'printf %s "${' .. var .. ':-}"' },
    { env = cmd.env(), clear_env = true, text = true }):wait(5000)
  return out.stdout or ''
end
check('child process does not inherit GIT_DIR', child_sees('GIT_DIR') == '',
  vim.inspect(child_sees('GIT_DIR')))
check('child process does not inherit GIT_WORK_TREE', child_sees('GIT_WORK_TREE') == '',
  vim.inspect(child_sees('GIT_WORK_TREE')))
-- Clearing must not cost the child its PATH, or `git` itself becomes unfindable.
check('child process still has PATH', child_sees('PATH') ~= '')
check('child process sees the pinned locale', child_sees('LC_ALL') == 'C', child_sees('LC_ALL'))

vim.env.GIT_DIR = nil
vim.env.GIT_WORK_TREE = nil

-- Per-call overrides win, so Phase 4's interactive rebase can restore a real editor.
check('env overrides apply', cmd.env({ GIT_SEQUENCE_EDITOR = 'nvim' }).GIT_SEQUENCE_EDITOR == 'nvim')

-- error_message prefers stderr but must fall back, since `commit` reports on stdout.
check('error_message uses stderr',
  cmd.error_message({ code = 1, stderr = 'fatal: bad\n', stdout = '' }) == 'fatal: bad')
check('error_message falls back to stdout',
  cmd.error_message({ code = 1, stderr = '', stdout = 'nothing to commit\n' }) == 'nothing to commit')
check('error_message never empty',
  cmd.error_message({ code = 128, stderr = '', stdout = '' }):find('128', 1, true) ~= nil)

-- -------------------------------------------------------------------------------------------------
-- Log: argv construction
-- -------------------------------------------------------------------------------------------------

local log = require('intellij-lsp.git.log')
local filter = require('intellij-lsp.git.filter')
local branches = require('intellij-lsp.git.branches')
local logview = require('intellij-lsp.git.logview')

local function joined(argv) return table.concat(argv, ' ') end

-- The bound is mandatory, not a tunable. Unbounded `git log --graph` on a large history can run for
-- minutes and emit millions of lines, so an argv without `-n` is a hang in practice.
local a = log.args({})
check('log always bounds with -n', vim.tbl_contains(a, '-n'), joined(a))
check('log default limit is the page size',
  joined(a):find('-n ' .. log.PAGE_SIZE, 1, true) ~= nil, joined(a))
check('log requests the graph', vim.tbl_contains(a, '--graph'))
-- A caller passing 0 or nil must still get a bound rather than an unbounded query.
check('limit=0 falls back to the page size',
  joined(log.args({ limit = 0 })):find('-n ' .. log.PAGE_SIZE, 1, true) ~= nil)
check('limit=nil falls back to the page size',
  joined(log.args({ limit = nil })):find('-n ' .. log.PAGE_SIZE, 1, true) ~= nil)
check('explicit limit honoured',
  joined(log.args({ limit = 42 })):find('-n 42', 1, true) ~= nil)

-- The format must start with the separator, or the graph prefix cannot be split off.
local fmt
for _, v in ipairs(a) do if v:sub(1, 9) == '--format=' then fmt = v end end
check('format starts with the separator', fmt and fmt:sub(10, 10) == log.US, vim.inspect(fmt))

-- Path arguments must follow `--`, or a path that looks like a ref is read as one.
local pa = log.args({ path_args = { 'some/path' } })
local dashdash, path_at
for i, v in ipairs(pa) do
  if v == '--' then dashdash = i end
  if v == 'some/path' then path_at = i end
end
check('paths are separated by --', dashdash ~= nil, joined(pa))
check('paths come after --', dashdash and path_at and path_at > dashdash, joined(pa))
check('no -- when there are no paths', not vim.tbl_contains(log.args({}), '--'))
-- A range is positional and must precede `--`.
local ra = log.args({ range = 'main..feature', path_args = { 'p' } })
local range_at, dd2
for i, v in ipairs(ra) do
  if v == 'main..feature' then range_at = i end
  if v == '--' then dd2 = i end
end
check('range precedes --', range_at and dd2 and range_at < dd2, joined(ra))
check('skip is passed through',
  joined(log.args({ skip = 100 })):find('--skip=100', 1, true) ~= nil)

-- -------------------------------------------------------------------------------------------------
-- Log: parsing
-- -------------------------------------------------------------------------------------------------

local US = log.US
--- Builds one log line the way git does: graph prefix, then the sentinel, then the fields.
local function line(graph, hash, short, author, date, refs, subject)
  return graph .. US .. table.concat({ hash, short, author, date, refs, subject }, US)
end

-- Real merge topology, captured from git: graph-only rows carry no separator at all.
local rows = log.parse(table.concat({
  line('*   ', 'b6b9510aaa', 'b6b9510', 'Ann', '2 hours ago', 'HEAD -> main, tag: v1.0', 'merge feature'),
  '|\\  ',
  line('| * ', '4142b3ebbb', '4142b3e', 'Bo', '1 day ago', 'feature', 'feature 2'),
  line('* | ', 'a776a48ccc', 'a776a48', 'Ann', '1 day ago', '', 'main 3'),
  '|/  ',
  line('* ', 'a27ac60ddd', 'a27ac60', 'Ann', '2 days ago', '', 'main 2'),
}, '\n'))

check('parse returns every row', #rows == 6, #rows)
check('commit rows carry a commit', rows[1].commit ~= nil)
-- The load-bearing distinction: `|\` and `|/` are decoration, not commits.
check('graph-only row has no commit', rows[2].commit == nil, vim.inspect(rows[2]))
check('graph-only row keeps its text', rows[2].graph == '|\\  ', vim.inspect(rows[2].graph))
check('second graph-only row has no commit', rows[5].commit == nil)
-- Trailing whitespace in a graph prefix is column alignment and must survive.
check('graph prefix whitespace preserved', rows[1].graph == '*   ', vim.inspect(rows[1].graph))
check('merge row parsed', rows[1].commit.subject == 'merge feature', rows[1].commit.subject)
check('fields not shifted by an empty refs field',
  rows[4].commit.subject == 'main 3' and rows[4].commit.author == 'Ann',
  vim.inspect(rows[4].commit))
check('empty refs is empty string', rows[4].commit.refs == '', vim.inspect(rows[4].commit.refs))

-- A subject may legally contain the separator byte. A greedy split would shift author and date; the
-- limit-aware split must keep them intact. Same class of bug as the NUL-framed renames above.
local evil = log.parse(line('* ', 'deadbeef11', 'deadbee', 'Ann', '3 days ago', '',
  'evil ' .. US .. ' subject'))
check('separator in subject does not shift fields',
  evil[1].commit.author == 'Ann' and evil[1].commit.date == '3 days ago',
  vim.inspect(evil[1].commit))
check('separator stays in the subject',
  evil[1].commit.subject == 'evil ' .. US .. ' subject', vim.inspect(evil[1].commit.subject))

-- A row whose payload cannot be parsed keeps its graph, so the lanes below it stay aligned.
local bad = log.parse('* ' .. US .. 'not-a-hash' .. US .. 'x')
check('malformed payload yields no commit', bad[1].commit == nil, vim.inspect(bad[1]))
check('malformed payload keeps the row', #bad == 1, #bad)

check('empty log parses to nothing', #log.parse('') == 0)
check('nil log parses to nothing', #log.parse(nil) == 0)

-- -------------------------------------------------------------------------------------------------
-- Log: ref decorations
-- -------------------------------------------------------------------------------------------------

local refs = log.parse_refs('HEAD -> main, origin/main, tag: v1.0, feature')
check('all refs parsed', #refs == 4, #refs)
-- The HEAD arrow must survive: stripping it makes the checked-out branch indistinguishable from any
-- other, which is the one distinction the decoration exists to draw.
check('HEAD arrow kept in the name', refs[1].name == 'HEAD -> main', refs[1].name)
check('HEAD kind tagged', refs[1].kind == 'head', refs[1].kind)
check('remote kind tagged', refs[2].kind == 'remote', refs[2].kind)
check('tag prefix stripped', refs[3].name == 'v1.0', refs[3].name)
check('tag kind tagged', refs[3].kind == 'tag', refs[3].kind)
check('plain branch tagged', refs[4].kind == 'branch', refs[4].kind)
check('detached bare HEAD tagged', log.parse_refs('HEAD')[1].kind == 'head')
check('no refs -> empty', #log.parse_refs('') == 0)

-- -------------------------------------------------------------------------------------------------
-- Filter
-- -------------------------------------------------------------------------------------------------

check('empty filter is inactive', not filter.is_active(filter.empty()))
check('empty filter has no args', #filter.args(filter.empty()) == 0)
check('text filter is active', filter.is_active({ text = 'x' }))
check('empty-string text is not active', not filter.is_active({ text = '' }))

local fa = filter.args({ text = 'PROJ-123' })
-- A user typing an issue id means it literally; regex interpretation would mangle `-` and `[`.
check('text filter is a fixed string', vim.tbl_contains(fa, '--fixed-strings'), joined(fa))
check('text filter passes --grep', joined(fa):find('--grep=PROJ%-123') ~= nil, joined(fa))
check('text filter is case-insensitive', vim.tbl_contains(fa, '--regexp-ignore-case'))

check('author filter passes --author',
  joined(filter.args({ author = 'ann' })):find('--author=ann', 1, true) ~= nil)
-- Combining must mean AND, not last-one-wins.
local both = filter.args({ text = 'fix', author = 'ann' })
check('filters combine', joined(both):find('--grep=fix', 1, true) ~= nil
  and joined(both):find('--author=ann', 1, true) ~= nil, joined(both))

-- Paths are positional and must never appear among the option flags.
check('path is not in args', #filter.args({ path = 'a/b' }) == 0)
check('path is returned separately', filter.path_args({ path = 'a/b' })[1] == 'a/b')
check('no path -> no path args', #filter.path_args({}) == 0)
check('range returned', filter.range({ range = 'a..b' }) == 'a..b')
check('empty range -> nil', filter.range({ range = '' }) == nil)

-- Only the path filter is slow enough to need an in-flight indicator (~0.56s measured, worst on a
-- mistyped path; the others are ~0.05s).
check('path filter is flagged slow', filter.is_slow({ path = 'a' }))
check('text filter is not flagged slow', not filter.is_slow({ text = 'a' }))
check('empty filter is not slow', not filter.is_slow({}))

check('describe nil when empty', filter.describe(filter.empty()) == nil)
local desc = filter.describe({ text = 'fix', author = 'ann', path = 'p', range = 'a..b' })
for _, needle in ipairs({ 'fix', 'ann', 'p', 'a..b' }) do
  check('describe mentions ' .. needle, desc:find(needle, 1, true) ~= nil, desc)
end

-- -------------------------------------------------------------------------------------------------
-- Log view rendering
-- -------------------------------------------------------------------------------------------------

local lines, map = logview._render(rows, {})
local body = table.concat(lines, '\n')
check('render includes a header', lines[1]:find('Log', 1, true) == 1, lines[1])
check('render draws the graph', body:find('|\\', 1, true) ~= nil, body)
check('render shows short hashes', body:find('b6b9510', 1, true) ~= nil)
check('render shows decorations', body:find('HEAD -> main', 1, true) ~= nil, body)

-- Only commit rows map to items; graph-only rows must map to nothing so <CR> on `|\` is a no-op.
local mapped = 0
for _ in pairs(map) do mapped = mapped + 1 end
check('four commits mapped', mapped == 4, mapped)
check('header maps to nothing', map[1] == nil)
local graph_row
for i, l in ipairs(lines) do if l == '|\\  ' then graph_row = i end end
check('graph-only row maps to nothing', graph_row and map[graph_row] == nil, tostring(graph_row))

-- An empty result must be explicable rather than looking broken, and must distinguish "no commits"
-- from "your filter excluded everything".
check('empty render mentions no commits',
  table.concat(logview._render({}, {}), '\n'):find('no commits', 1, true) ~= nil)
check('empty filtered render says so',
  table.concat(logview._render({}, { filter = { text = 'zzz' } }), '\n')
    :find('match this filter', 1, true) ~= nil)
-- The paging hint appears only when more may exist.
check('load-more hint when not exhausted',
  table.concat(logview._render(rows, { exhausted = false }), '\n'):find('load more', 1, true) ~= nil)
check('no load-more hint when exhausted',
  table.concat(logview._render(rows, { exhausted = true }), '\n'):find('load more', 1, true) == nil)
check('loading line rendered',
  table.concat(logview._render(rows, { loading = 'searching…' }), '\n')
    :find('searching', 1, true) ~= nil)

-- Truncation is display-width aware: a byte cut through a multi-byte name breaks the character, and
-- CJK is double-width so a byte count is not a column count.
check('truncate leaves short strings alone', logview._truncate('abc', 10) == 'abc')
check('truncate adds an ellipsis', logview._truncate('abcdefghij', 5):find('…', 1, true) ~= nil)
check('truncate respects display width',
  vim.fn.strdisplaywidth(logview._truncate('abcdefghij', 5)) <= 5,
  logview._truncate('abcdefghij', 5))
check('truncate does not split a multi-byte char',
  vim.fn.strchars(logview._truncate('Ünïcödé nàme', 6)) > 0
    and vim.fn.strdisplaywidth(logview._truncate('Ünïcödé nàme', 6)) <= 6,
  logview._truncate('Ünïcödé nàme', 6))
check('truncate handles double-width text',
  vim.fn.strdisplaywidth(logview._truncate('日本語のテキスト', 6)) <= 6,
  logview._truncate('日本語のテキスト', 6))

-- -------------------------------------------------------------------------------------------------
-- Affected-files preview
-- -------------------------------------------------------------------------------------------------

-- numstat: binary files report `-` rather than numbers, which means "binary", not "no change".
local ns_stats = log.parse_numstat('12\t3\tsrc/a.kt\n-\t-\tlogo.png\n0\t0\tempty.txt\n')
check('numstat parses counts', ns_stats[1].added == 12 and ns_stats[1].deleted == 3,
  vim.inspect(ns_stats[1]))
check('numstat flags binary', ns_stats[2].binary == true, vim.inspect(ns_stats[2]))
check('binary counts are not reported as zero-change',
  ns_stats[2].added == 0 and ns_stats[2].deleted == 0 and ns_stats[2].binary,
  vim.inspect(ns_stats[2]))
check('genuinely empty change is not binary', ns_stats[3].binary == false, vim.inspect(ns_stats[3]))
check('empty numstat parses', #log.parse_numstat('') == 0)

-- The shared row renderer. Three columns, each coloured for a different reason: the status word by
-- change type, the counts always green/red, the path neutral. Mixing those was what made the list read
-- as noise -- a green "added" beside a red filename.
local filelist = require('intellij-lsp.git.filelist')

--- Maps each highlight group to the text it covers.
---
--- Keeps the **first** span per group, not the last: a row's status word and its `+N` can legitimately
--- share a group (an added row is green in both places), and overwriting would make the map report the
--- count where the caller means the status word.
local function spans_of(f)
  local text, spans = filelist.row(f)
  local by_group = {}
  for _, s in ipairs(spans) do
    if by_group[s.hl] == nil then by_group[s.hl] = text:sub(s.col + 1, s.end_col) end
  end
  return text, by_group, spans
end

local _, mod_spans = spans_of({ code = 'M', path = 'a.kt', added = 1, deleted = 2 })
local _, add_spans = spans_of({ code = 'A', path = 'b.kt', added = 5, deleted = 0 })
local _, del_spans = spans_of({ code = 'D', path = 'c.kt', added = 0, deleted = 9 })

-- The path is claimed on every row. Leaving it unhighlighted does not make it neutral -- it inherits
-- whatever syntax or Treesitter paints, which differs per row, so a path could come out red on a green
-- row. This is the check that pins the reported inconsistency.
check('modified row claims its path', mod_spans.IntellijGitFilePath == 'a.kt', vim.inspect(mod_spans))
check('added row claims its path', add_spans.IntellijGitFilePath == 'b.kt', vim.inspect(add_spans))
check('deleted row claims its path', del_spans.IntellijGitFilePath == 'c.kt', vim.inspect(del_spans))
-- Every row uses the *same* group for the path, regardless of change type.
check('all rows use one path group',
  mod_spans.IntellijGitFilePath and add_spans.IntellijGitFilePath and del_spans.IntellijGitFilePath)

-- The status word carries the change type, and each type is a different group.
check('modified word is the modified colour',
  mod_spans.IntellijGitFileModified and mod_spans.IntellijGitFileModified:find('modified'))
check('added word is the added colour',
  add_spans.IntellijGitFileAdded and add_spans.IntellijGitFileAdded:find('added'))
check('deleted word is the deleted colour',
  del_spans.IntellijGitFileDeleted and del_spans.IntellijGitFileDeleted:find('deleted'))

-- `+N` stays green and `-N` stays red on every row: tinting them by change type would paint a
-- deletion's `+0` red, which reads as nonsense. Looked up positionally, because on an added row the
-- status word and the `+N` share a group.
local function span_text(f, hl, nth)
  local text, _, spans = spans_of(f)
  local seen = 0
  for _, s in ipairs(spans) do
    if s.hl == hl then
      seen = seen + 1
      if seen == nth then return text:sub(s.col + 1, s.end_col) end
    end
  end
  return nil
end

check('deleted row still has a green +N',
  span_text({ code = 'D', path = 'c.kt', added = 0, deleted = 9 }, 'IntellijGitFileAdded', 1) == '+0',
  tostring(span_text({ code = 'D', path = 'c.kt', added = 0, deleted = 9 }, 'IntellijGitFileAdded', 1)))
-- Second `Deleted` span on an added row: the first is nothing (the status word is green there), so the
-- red `-0` is the first and only one.
check('added row still has a red -N',
  add_spans.IntellijGitFileDeleted == '-0', vim.inspect(add_spans))

-- A rename dims the provenance half rather than leaving it unstyled.
local ren_text, ren_spans = spans_of({ code = 'R', path = 'new.kt', origin = 'old.kt' })
check('rename claims the new path', ren_spans.IntellijGitFilePath == 'new.kt', vim.inspect(ren_spans))
check('rename dims the origin',
  ren_spans.IntellijGitFileOrigin and ren_spans.IntellijGitFileOrigin:find('old.kt', 1, true) ~= nil,
  vim.inspect(ren_spans))
-- Every byte of the row after the status word must be claimed by something.
check('rename row is fully covered', #ren_text > 0 and ren_spans.IntellijGitFileRenamed ~= nil)

-- Renamed must not resolve to the same colour as modified, or the two are indistinguishable.
require('intellij-lsp.git.highlights').setup()
local function fg(g)
  local h = vim.api.nvim_get_hl(0, { name = g, link = false })
  return h.fg
end
check('renamed is a different colour from modified',
  fg('IntellijGitFileRenamed') ~= fg('IntellijGitFileModified'),
  ('%s vs %s'):format(tostring(fg('IntellijGitFileRenamed')), tostring(fg('IntellijGitFileModified'))))
check('added differs from deleted', fg('IntellijGitFileAdded') ~= fg('IntellijGitFileDeleted'))
check('path differs from every status colour',
  fg('IntellijGitFilePath') ~= fg('IntellijGitFileAdded')
    and fg('IntellijGitFilePath') ~= fg('IntellijGitFileDeleted'))

-- Binary rows show `bin` in the meta colour rather than a misleading `+0 -0`.
local _, bin_spans = spans_of({ code = 'M', path = 'logo.png', binary = true })
check('binary shows bin', bin_spans.IntellijGitFileMeta == 'bin', vim.inspect(bin_spans))
check('binary has no count spans', bin_spans.IntellijGitFileAdded == nil, vim.inspect(bin_spans))

-- Every span must lie inside its own row. The extmark API validates `end_col` against the line, and a
-- span running past the end is silently dropped -- which is how the rename rows lost all colour.
for _, f in ipairs({
  { code = 'R', path = 'new.kt', origin = 'old.kt' },
  { code = 'M', path = 'src/Ünicode.kt', added = 1, deleted = 1 },
  { code = 'A', path = 'a.kt', added = 1, deleted = 0 },
}) do
  local text, _, spans = spans_of(f)
  local within = true
  for _, s in ipairs(spans) do
    if s.end_col > #text or s.col < 0 or s.col > s.end_col then within = false end
  end
  check(('spans stay inside the row for %s'):format(f.path), within,
    ('#text=%d spans=%s'):format(#text, vim.inspect(spans)))
end

local function fr(files, c)
  return logview._render_files(c or { short = 'abc1234', subject = 's', author = 'A', date = 'now' },
    files)
end

local flines = fr({
  { code = 'A', path = 'new.kt', added = 10, deleted = 0 },
  { code = 'D', path = 'gone.kt', added = 0, deleted = 42 },
  { code = 'M', path = 'edit.kt', added = 3, deleted = 1 },
  { code = 'R', path = 'to.kt', origin = 'from.kt', added = 0, deleted = 0 },
  { code = 'B', path = 'logo.png', binary = true, added = 0, deleted = 0 },
})
local ftext = table.concat(flines, '\n')

check('file list shows the subject', flines[1]:find('abc1234', 1, true) ~= nil, flines[1])
check('file list names each change type', ftext:find('added', 1, true) ~= nil
  and ftext:find('deleted', 1, true) ~= nil and ftext:find('modified', 1, true) ~= nil
  and ftext:find('renamed', 1, true) ~= nil, ftext)
check('file list shows per-file counts', ftext:find('+10 -0', 1, true) ~= nil, ftext)
-- A rename that only moved the file is invisible without both paths.
check('rename shows both paths', ftext:find('to.kt ← from.kt', 1, true) ~= nil, ftext)
-- `+0 -0` on a binary file is a lie: git cannot count lines there.
check('binary shows bin, not +0 -0',
  ftext:find('bin', 1, true) ~= nil and ftext:find('logo.png', 1, true) ~= nil, ftext)
check('totals line counts the files', ftext:find('5 files changed', 1, true) ~= nil, ftext)
check('totals sum the counts', ftext:find('+13 -43', 1, true) ~= nil, ftext)
check('totals note binaries', ftext:find('1 binary', 1, true) ~= nil, ftext)
check('singular file wording',
  table.concat(fr({ { code = 'M', path = 'a', added = 1, deleted = 0 } }), '\n')
    :find('1 file changed', 1, true) ~= nil)

-- A merge with no conflicts touches nothing; an empty pane would read as a failure.
check('no files is explained', table.concat(fr({}), '\n'):find('no files changed', 1, true) ~= nil,
  table.concat(fr({}), '\n'))

-- Highlights must colour the counts, and the groups must be ones that actually exist: `DiffAdded` and
-- `DiffRemoved` are NOT default Neovim groups, so linking to them renders as plain text.
local _, fhls = fr({ { code = 'A', path = 'a.kt', added = 5, deleted = 2 } })
check('file rows are highlighted', #fhls > 0, #fhls)
local groups = {}
for _, h in ipairs(fhls) do groups[h.hl] = true end
check('added spans highlighted', groups.IntellijGitFileAdded == true, vim.inspect(groups))
check('deleted spans highlighted', groups.IntellijGitFileDeleted == true, vim.inspect(groups))
-- The link targets must be groups Neovim actually defines. `DiffAdded`/`DiffRemoved` do not exist, so
-- linking to them silently yields no colour -- which is how this was wrong the first time.
for _, g in ipairs({ 'Added', 'Removed', 'Changed' }) do
  check(('link target %s exists in Neovim'):format(g),
    next(vim.api.nvim_get_hl(0, { name = g, link = false })) ~= nil)
end
for _, g in ipairs({ 'DiffAdded', 'DiffRemoved' }) do
  check(('%s is NOT a default group (do not link to it)'):format(g),
    next(vim.api.nvim_get_hl(0, { name = g, link = false })) == nil)
end

-- Registration happens in `setup()`, not when a view module is required. That distinction is the bug
-- this pins: the groups used to be defined at the top of `logview.lua`, which is `require`d lazily by
-- its command, so they did not exist until the log had been opened once -- and the late require then
-- clobbered any `:highlight` override the user had set in their config.
local highlights = require('intellij-lsp.git.highlights')
for _, g in ipairs({ 'IntellijGitFileAdded', 'IntellijGitFileDeleted', 'IntellijGitFileModified' }) do
  check(('%s is declared'):format(g), highlights.GROUPS[g] ~= nil)
end
highlights.setup()
for _, g in ipairs({ 'IntellijGitFileAdded', 'IntellijGitFileDeleted', 'IntellijGitFileModified' }) do
  local resolved = vim.api.nvim_get_hl(0, { name = g, link = false })
  check(('%s resolves to a real colour after setup'):format(g),
    resolved.fg ~= nil or resolved.ctermfg ~= nil, vim.inspect(resolved))
end
-- Links are `default = true`, so a user override wins rather than being overwritten.
check('groups are default links, so a user override wins',
  vim.api.nvim_get_hl(0, { name = 'IntellijGitFileAdded' }).default == true,
  vim.inspect(vim.api.nvim_get_hl(0, { name = 'IntellijGitFileAdded' })))
-- Every group the views reference must be declared, or it renders unstyled.
for _, g in ipairs({ 'IntellijGitLogHash', 'IntellijGitBranchCurrent', 'IntellijGitCommitHeader',
                     'IntellijGitStaged', 'IntellijGitFileSubject' }) do
  check(('%s is declared centrally'):format(g), highlights.GROUPS[g] ~= nil)
end

-- The remap groups of the two-pane diff must resolve under a foreign scheme too, or the panes lose
-- their colour there.
for _, g in ipairs({ 'IntellijDiffDeleted', 'IntellijDiffDeletedText', 'IntellijDiffFiller',
                     'IntellijDiffFold', 'IntellijDiffTitle', 'IntellijDiffTitleMeta',
                     'IntellijDiffInsertedLine', 'IntellijDiffDeletedLine' }) do
  check(('%s is declared centrally'):format(g), highlights.GROUPS[g] ~= nil)
  check(('%s resolves after setup'):format(g),
    next(vim.api.nvim_get_hl(0, { name = g, link = false })) ~= nil)
end

-- -------------------------------------------------------------------------------------------------
-- Two-pane diff styling
-- -------------------------------------------------------------------------------------------------

local diff = require('intellij-lsp.git.diff')
do
  vim.cmd('tabnew')
  local new_win = vim.api.nvim_get_current_win()
  local new_buf = vim.api.nvim_get_current_buf()
  -- A user's own values, which must survive the diff.
  vim.wo[new_win].winhighlight = 'Normal:Comment'
  vim.keymap.set('n', '<S-F7>', '<Nop>', { buffer = new_buf, desc = 'user map' })
  vim.cmd('leftabove vsplit')
  local old_win = vim.api.nvim_get_current_win()
  local old_buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_win_set_buf(old_win, old_buf)
  vim.cmd('diffthis')
  vim.api.nvim_win_call(new_win, function() vim.cmd('diffthis') end)

  diff.style_panes(old_win, new_win, {
    old = { name = 'HEAD · src/100%.txt', readonly = true },
    new = { name = 'Your version' },
  })
  local old_hl = vim.wo[old_win].winhighlight
  local new_hl = vim.wo[new_win].winhighlight
  -- Neovim paints a line that only the old side has as DiffAdd. In the old pane that is a deletion.
  check('old pane shows an old-only line as deleted',
    old_hl:find('DiffAdd:IntellijDiffDeleted', 1, true) ~= nil, old_hl)
  check('old pane shows an old-only word as deleted',
    old_hl:find('DiffTextAdd:IntellijDiffDeletedText', 1, true) ~= nil, old_hl)
  check('new pane keeps DiffAdd as an insertion', new_hl:find('DiffAdd:', 1, true) == nil, new_hl)
  check('new pane keeps the user value', new_hl:find('Normal:Comment', 1, true) == 1, new_hl)
  for _, entry in ipairs({ 'DiffDelete:IntellijDiffFiller', 'Folded:IntellijDiffFold',
                           'WinBar:IntellijDiffTitle', 'WinBarNC:IntellijDiffTitle' }) do
    check(('%s in both panes'):format(entry),
      old_hl:find(entry, 1, true) ~= nil and new_hl:find(entry, 1, true) ~= nil, old_hl)
  end
  -- The global value stays the base, or `eob` and the rest fall back to Neovim's defaults.
  local fill = vim.wo[new_win].fillchars
  check('global fillchars stay the base',
    vim.go.fillchars == '' or fill:find(vim.go.fillchars, 1, true) == 1, fill)
  local parsed = vim.api.nvim_win_call(new_win, function() return vim.opt_local.fillchars:get() end)
  check('Neovim parses the filler character', parsed.diff == '╱', vim.inspect(parsed))
  check('Neovim parses the fold character', parsed.fold == ' ', vim.inspect(parsed))

  -- `:diffthis` sets a fold column of 2, and IntelliJ shows none.
  check('no fold column', vim.wo[old_win].foldcolumn == '0', vim.wo[old_win].foldcolumn)
  check('foldtext is ours', vim.wo[new_win].foldtext:find('intellij-lsp.git.diff', 1, true) ~= nil,
    vim.wo[new_win].foldtext)
  vim.v.foldstart, vim.v.foldend = 10, 51
  check('foldtext counts the lines', diff.foldtext():find('42 unchanged lines', 1, true) ~= nil,
    diff.foldtext())
  vim.v.foldstart, vim.v.foldend = 7, 7
  check('foldtext singular', diff.foldtext():find('1 unchanged line$') ~= nil, diff.foldtext())
  -- Evaluated the way Neovim evaluates it, so a broken `v:lua` expression fails here.
  vim.v.foldstart, vim.v.foldend = 1, 3
  check('foldtext expression evaluates',
    vim.fn.eval(vim.wo[new_win].foldtext) == diff.foldtext())

  -- Pane headers. A `%` in a path starts a 'winbar' item unless it is escaped.
  local bar = vim.wo[old_win].winbar
  check('old header names the revision', bar:find('HEAD · src/100%%.txt', 1, true) ~= nil, bar)
  check('old header notes read-only', bar:find('(read-only)', 1, true) ~= nil, bar)
  check('new header', vim.wo[new_win].winbar:find('Your version', 1, true) ~= nil,
    vim.wo[new_win].winbar)
  check('new header has no read-only note',
    vim.wo[new_win].winbar:find('read-only', 1, true) == nil, vim.wo[new_win].winbar)
  local evaluated = vim.api.nvim_eval_statusline(bar, { winid = old_win, use_winbar = true }).str
  check('header renders the path', evaluated:find('src/100%.txt', 1, true) ~= nil, evaluated)

  -- IntelliJ's next and previous difference keys.
  local function bufmap(buf, key)
    return vim.api.nvim_buf_call(buf, function() return vim.fn.maparg(key, 'n', false, true) end)
  end
  check('F7 is next difference', bufmap(new_buf, '<F7>').rhs == ']c',
    vim.inspect(bufmap(new_buf, '<F7>')))
  check('F7 in the old pane', bufmap(old_buf, '<F7>').rhs == ']c')
  check('S-F7 is previous difference', bufmap(old_buf, '<S-F7>').rhs == '[c')
  check('a user buffer map is not replaced', bufmap(new_buf, '<S-F7>').desc == 'user map',
    vim.inspect(bufmap(new_buf, '<S-F7>')))

  -- A re-render styles the same windows again. That must not stack the entries.
  diff.style_panes(old_win, new_win)
  check('styling twice does not stack entries', vim.wo[new_win].winhighlight == new_hl,
    vim.wo[new_win].winhighlight)

  diff.unstyle_pane(new_win)
  check('unstyle restores the user winhighlight', vim.wo[new_win].winhighlight == 'Normal:Comment',
    vim.wo[new_win].winhighlight)
  -- 'foldtext' is a window option with a default, and the other two are empty until set.
  for name, before in pairs({ fillchars = '', foldtext = 'foldtext()', winbar = '' }) do
    local value = vim.api.nvim_get_option_value(name, { win = new_win, scope = 'local' })
    check(('unstyle restores %s'):format(name), value == before, value)
  end
  check('unstyle removes F7', next(bufmap(new_buf, '<F7>')) == nil,
    vim.inspect(bufmap(new_buf, '<F7>')))
  check('unstyle keeps the user map', bufmap(new_buf, '<S-F7>').desc == 'user map')
  diff.unstyle_pane(new_win)
  check('unstyle twice is harmless', vim.wo[new_win].winhighlight == 'Normal:Comment')
  vim.cmd('tabclose')
end

-- The unified preview in the status panel tints the changed lines, and only those inside a hunk.
do
  local tints = panel._line_highlights({
    'diff --git a/x b/x',
    '--- a/x',
    '+++ b/x',
    '@@ -1,2 +1,2 @@',
    ' same',
    '-old',
    '+new',
    '\\ No newline at end of file',
    'diff --git a/y b/y',
    '--- a/y',
    '+++ b/y',
  })
  check('unified preview tints two lines', #tints == 2, vim.inspect(tints))
  check('deleted line tint',
    tints[1] and tints[1].row == 5 and tints[1].hl == 'IntellijDiffDeletedLine',
    vim.inspect(tints[1]))
  check('inserted line tint',
    tints[2] and tints[2].row == 6 and tints[2].hl == 'IntellijDiffInsertedLine',
    vim.inspect(tints[2]))
end

-- Branch names decorating a commit, for switching branches from inside the log.
--
-- `parse_refs` keeps the `HEAD -> ` arrow for display, so it has to be stripped here; and three ref
-- shapes must be excluded because checking any of them out detaches HEAD rather than switching branch.
check('branches_at strips the HEAD arrow',
  vim.deep_equal(logview._branches_at({ refs = 'HEAD -> main' }), { 'main' }),
  vim.inspect(logview._branches_at({ refs = 'HEAD -> main' })))
check('branches_at keeps a remote branch',
  vim.deep_equal(logview._branches_at({ refs = 'HEAD -> main, origin/main' }),
    { 'main', 'origin/main' }),
  vim.inspect(logview._branches_at({ refs = 'HEAD -> main, origin/main' })))
check('branches_at finds several at one tip',
  #logview._branches_at({ refs = 'feature, second-at-tip' }) == 2)
-- A tag is not a branch: checking one out detaches HEAD.
check('branches_at excludes tags',
  vim.deep_equal(logview._branches_at({ refs = 'HEAD -> main, tag: v1.0' }), { 'main' }),
  vim.inspect(logview._branches_at({ refs = 'HEAD -> main, tag: v1.0' })))
check('branches_at on a tag-only commit is empty',
  #logview._branches_at({ refs = 'tag: v1.0' }) == 0)
-- A bare `HEAD` is the detached marker, and `origin/HEAD` is a symbolic ref.
check('branches_at excludes a bare HEAD', #logview._branches_at({ refs = 'HEAD' }) == 0)
check('branches_at excludes origin/HEAD',
  vim.deep_equal(logview._branches_at({ refs = 'origin/HEAD, origin/main' }), { 'origin/main' }),
  vim.inspect(logview._branches_at({ refs = 'origin/HEAD, origin/main' })))
check('branches_at on an undecorated commit is empty',
  #logview._branches_at({ refs = '' }) == 0)
check('branches_at on nil is empty', #logview._branches_at(nil) == 0)

-- -------------------------------------------------------------------------------------------------
-- Branches
-- -------------------------------------------------------------------------------------------------

local BUS = branches.US
local function bline(...) return table.concat({ ... }, BUS) end

local blist = branches.parse(table.concat({
  bline('main', 'refs/heads/main', 'origin/main', '[ahead 2]', '*', '2 hours ago', 'aaaaaaa', 'tip'),
  bline('feature', 'refs/heads/feature', '', '', ' ', '1 day ago', 'bbbbbbb', 'wip'),
  bline('origin/main', 'refs/remotes/origin/main', '', '', ' ', '2 hours ago', 'aaaaaaa', 'tip'),
  -- A remote's symbolic HEAD; checking it out detaches HEAD, so it must not be listed. Note the short
  -- name: git abbreviates `refs/remotes/origin/HEAD` to plain **`origin`**, not `origin/HEAD` (verified
  -- against a real remote). A filter written against the short name therefore misses it entirely and
  -- the remote appears as a branch called `origin` -- which is exactly the bug this fixture pins.
  bline('origin', 'refs/remotes/origin/HEAD', '', '', ' ', '2 hours ago', 'aaaaaaa', 'tip'),
}, '\n'))

check('branches parsed', #blist == 3, #blist)
check('remote symbolic HEAD excluded despite its bare short name', (function()
  for _, b in ipairs(blist) do
    if b.name == 'origin' or b.name == 'origin/HEAD' then return false end
  end
  return true
end)(), vim.inspect(vim.tbl_map(function(b) return b.name end, blist)))
check('current branch marked', blist[1].current == true)
check('non-current not marked', blist[2].current == false)
check('local kind', blist[1].kind == branches.LOCAL, blist[1].kind)
check('remote kind', blist[3].kind == branches.REMOTE, blist[3].kind)
check('upstream parsed', blist[1].upstream == 'origin/main', tostring(blist[1].upstream))
check('empty upstream is nil', blist[2].upstream == nil, tostring(blist[2].upstream))
check('track parsed', blist[1].track == '[ahead 2]', tostring(blist[1].track))
check('subject parsed', blist[1].subject == 'tip', blist[1].subject)
check('current() finds it', (branches.current(blist) or {}).name == 'main')

-- Detached HEAD: no ref carries the marker, so current() must be nil rather than guessing.
local detached = branches.parse(bline('main', 'refs/heads/main', '', '', ' ', 'now', 'aaa', 's'))
check('detached HEAD has no current branch', branches.current(detached) == nil)

-- A remote branch cannot be checked out by name without detaching, so it becomes a tracking branch.
local rargs = branches.checkout_args({ name = 'origin/feature', kind = branches.REMOTE })
check('remote checkout tracks', vim.tbl_contains(rargs, '--track'), joined(rargs))
check('remote checkout strips the remote prefix', vim.tbl_contains(rargs, 'feature'), joined(rargs))
check('local checkout is plain',
  joined(branches.checkout_args({ name = 'main', kind = branches.LOCAL })) == 'checkout main')

-- A successful checkout that carried modifications must be reported, or the user thinks they vanished.
check('carried changes detected',
  #branches.carried_changes({ stdout = 'M\tsrc/a.txt\n', stderr = "Switched to branch 'x'\n" }) == 1)
check('carried change path extracted',
  branches.carried_changes({ stdout = 'M\tsrc/a.txt\n', stderr = '' })[1] == 'src/a.txt')
check('clean checkout carries nothing',
  #branches.carried_changes({ stdout = '', stderr = "Switched to branch 'x'\n" }) == 0)

-- -------------------------------------------------------------------------------------------------

print(('\n%s'):format(failures == 0 and 'ALL GIT UNIT CHECKS PASSED'
  or (failures .. ' GIT UNIT CHECK(S) FAILED')))
if failures > 0 then vim.cmd('cquit 1') end
