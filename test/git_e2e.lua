-- End-to-end checks against a real throwaway repository. No language server required.
--
--   nvim --headless -u NONE -l test/git_e2e.lua
--
-- Generates its own repository in a temp directory, the way java_e2e.lua generates a Maven project,
-- so it needs nothing but `git` on PATH. Fast: no network, no server, a few seconds.
--
-- What this covers that git_units.lua cannot: that the flags in cmd.lua actually work against real
-- git, that the panel opens and previews, and that the shapes the parser expects are the shapes this
-- git version really emits -- the fixtures in the unit suite are frozen captures and would not notice
-- a format change.
vim.opt.runtimepath:prepend(vim.fs.dirname(vim.fs.dirname(debug.getinfo(1, 'S').source:sub(2))))

local cmd = require('intellij-lsp.git.cmd')
local status = require('intellij-lsp.git.status')
local panel = require('intellij-lsp.git.panel')
local diff = require('intellij-lsp.git.diff')

local failures = 0
local function check(name, cond, detail)
  if cond then
    print('ok   ' .. name)
  else
    failures = failures + 1
    print('FAIL ' .. name .. (detail and ('  -> ' .. tostring(detail)) or ''))
  end
end

--- Runs git in the fixture repo, failing loudly: a broken fixture must not read as a failing feature.
local function git(repo, args)
  local res = cmd.run_sync(args, { cwd = repo })
  if not res.ok then
    error(('fixture setup failed: git %s -> %s'):format(
      table.concat(args, ' '), cmd.error_message(res)))
  end
  return res
end

local function write(path, text)
  vim.fn.mkdir(vim.fs.dirname(path), 'p')
  local fd = assert(io.open(path, 'w'))
  fd:write(text)
  fd:close()
end

--- Creates a directory and returns its *resolved* path.
---
--- `tempname()` hands back an unresolved path -- on macOS `$TMPDIR` lives under `/var/folders`, which
--- is a symlink to `/private/var/folders`. git always reports the resolved form, and so does
--- `cmd.root`, so a fixture that keeps the unresolved path would compare unequal to every root this
--- suite asks about and fail for a reason that has nothing to do with the code under test.
local function make_dir(suffix)
  local path = vim.fn.tempname() .. suffix
  vim.fn.mkdir(path, 'p')
  return vim.fs.normalize(vim.uv.fs_realpath(path) or path)
end

--- Blocks until `predicate` holds, pumping the event loop.
---
--- The panel and preview are async, so the assertions need somewhere to wait. `vim.wait` runs the
--- loop rather than sleeping, so scheduled callbacks actually fire.
local function wait_for(predicate, what)
  local ok = vim.wait(5000, predicate, 25)
  if not ok then check('timed out waiting for ' .. what, false) end
  return ok
end

-- -------------------------------------------------------------------------------------------------
-- Fixture: a repository with one of every interesting state
-- -------------------------------------------------------------------------------------------------

local repo = make_dir('-ijgit')

git(repo, { 'init', '-q', '-b', 'main' })
-- Identity and signing are set locally, so the suite does not depend on the developer's ~/.gitconfig
-- and cannot be broken by a global commit.gpgsign.
git(repo, { 'config', 'user.email', 'test@example.com' })
git(repo, { 'config', 'user.name', 'IntelliJ Test' })
git(repo, { 'config', 'commit.gpgsign', 'false' })

write(repo .. '/tracked.txt', 'one\ntwo\nthree\n')
write(repo .. '/to-rename.txt', 'rename me\n')
write(repo .. '/to-delete.txt', 'delete me\n')
write(repo .. '/sub/nested.txt', 'nested\n')
git(repo, { 'add', '-A' })
git(repo, { 'commit', '-qm', 'initial' })

-- Now produce every side at once.
write(repo .. '/tracked.txt', 'one\nCHANGED\nthree\n')          -- unstaged modification
write(repo .. '/sub/nested.txt', 'nested\nstaged change\n')
git(repo, { 'add', 'sub/nested.txt' })                          -- staged modification
git(repo, { 'mv', 'to-rename.txt', 'renamed.txt' })             -- staged rename
git(repo, { 'rm', '-q', 'to-delete.txt' })                      -- staged deletion
write(repo .. '/untracked.txt', 'brand new\n')                  -- untracked
write(repo .. '/Ünicode.txt', 'non-ascii name\n')               -- untracked, non-ASCII path
write(repo .. '/with space.txt', 'spaced name\n')               -- untracked, space in path

-- -------------------------------------------------------------------------------------------------
-- Repository discovery
-- -------------------------------------------------------------------------------------------------

check('root found from the repo directory', cmd.root(repo) == repo, tostring(cmd.root(repo)))
check('root found from a subdirectory', cmd.root(repo .. '/sub') == repo,
  tostring(cmd.root(repo .. '/sub')))
-- The temp directory itself is not a repository, so this must be nil rather than a stray ancestor.
check('root nil outside a repository', cmd.root(vim.fn.tempname() .. '-nonrepo') == nil)

-- -------------------------------------------------------------------------------------------------
-- Status against real git
-- -------------------------------------------------------------------------------------------------

local st
status.fetch(repo, function(s, err)
  if not s then error('status.fetch failed: ' .. tostring(err)) end
  st = s
end)
wait_for(function() return st ~= nil end, 'status.fetch')

local function find(side, path)
  for _, e in ipairs(st.entries) do
    if e.side == side and e.path == path then return e end
  end
  return nil
end

check('branch is main', st.branch == 'main', tostring(st.branch))
check('no upstream in a fresh repo', st.upstream == nil, tostring(st.upstream))
check('oid is a real hash', st.oid and #st.oid == 40, tostring(st.oid))
check('nothing in progress', st.in_progress == nil, tostring(st.in_progress))

check('unstaged modification seen', find(status.UNSTAGED, 'tracked.txt') ~= nil)
check('staged modification seen', find(status.STAGED, 'sub/nested.txt') ~= nil)
check('untracked file seen', find(status.UNTRACKED, 'untracked.txt') ~= nil)

-- The two path shapes that break naive parsers, end to end through real git this time. Non-ASCII
-- works only because cmd.lua sets core.quotepath=false; without it the path arrives octal-escaped.
check('non-ascii path round-trips', find(status.UNTRACKED, 'Ünicode.txt') ~= nil,
  vim.inspect(vim.tbl_map(function(e) return e.path end, st.entries)))
check('spaced path round-trips', find(status.UNTRACKED, 'with space.txt') ~= nil)

-- The rename, which is the record the unit suite spends the most effort on.
local ren = find(status.STAGED, 'renamed.txt')
check('rename seen as one staged entry', ren ~= nil, vim.inspect(st.entries))
check('rename code is R', ren and ren.code == 'R', ren and ren.code)
check('rename origin recovered from real git', ren and ren.origin == 'to-rename.txt',
  ren and tostring(ren.origin))

local del = find(status.STAGED, 'to-delete.txt')
check('deletion seen', del ~= nil and del.code == 'D', del and del.code)

-- Untracked directories must not collapse: --untracked-files=all is what makes a new package's files
-- individually stageable rather than showing as a single directory entry.
write(repo .. '/newpkg/a.txt', 'a\n')
write(repo .. '/newpkg/b.txt', 'b\n')
local st2
status.fetch(repo, function(s) st2 = s end)
wait_for(function() return st2 ~= nil end, 'second status.fetch')
local newpkg = 0
for _, e in ipairs(st2.entries) do
  if e.side == status.UNTRACKED and e.path:find('^newpkg/') then newpkg = newpkg + 1 end
end
check('untracked directory is expanded to files', newpkg == 2, newpkg)

-- -------------------------------------------------------------------------------------------------
-- Panel
-- -------------------------------------------------------------------------------------------------

-- Open from inside the repo so cmd.root() resolves without an argument, as it would for a user.
vim.cmd.edit(repo .. '/tracked.txt')
local origin_win = vim.api.nvim_get_current_win()

panel.open()
wait_for(function() return panel.is_open() end, 'panel to open')
check('panel opens', panel.is_open())

if panel.is_open() then
  -- Lands on a real entry, so the panel is useful before any keypress.
  check('panel selects an entry on open', panel.current_entry() ~= nil,
    vim.inspect(panel.current_entry()))

  -- The preview renders a diff into the origin window. Waiting on the buffer *name* rather than a
  -- timer keeps this from being a flaky sleep.
  local previewed = wait_for(function()
    if not vim.api.nvim_win_is_valid(origin_win) then return false end
    local name = vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(origin_win))
    return name:find('intellij%-git://diff') ~= nil
  end, 'diff preview to render')
  check('preview renders into the editor window', previewed)

  if previewed then
    local pbuf = vim.api.nvim_win_get_buf(origin_win)
    check('preview buffer has diff filetype', vim.bo[pbuf].filetype == 'diff', vim.bo[pbuf].filetype)
    check('preview buffer is not modifiable', vim.bo[pbuf].modifiable == false)
    local text = table.concat(vim.api.nvim_buf_get_lines(pbuf, 0, -1, false), '\n')
    check('preview shows diff content', text:find('@@', 1, true) ~= nil or text:find('^#') ~= nil,
      text:sub(1, 200))
  end

  -- Refresh must survive: it re-fetches and repaints in place.
  panel.refresh()
  check('panel survives refresh', panel.is_open())

  panel.close(true)
  check('panel closes', not panel.is_open())
  -- close(true) restores the editor window to the buffer it held before the panel opened.
  local restored = vim.api.nvim_win_is_valid(origin_win)
    and vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(origin_win))
  check('close(true) restores the original buffer',
    restored and restored:find('tracked.txt', 1, true) ~= nil, tostring(restored))
end

-- close() is idempotent, and is called from autocmds where a double call is normal.
panel.close(false)
check('close is idempotent', not panel.is_open())

-- -------------------------------------------------------------------------------------------------
-- Diff view
-- -------------------------------------------------------------------------------------------------

vim.cmd('silent! only')
vim.cmd.edit(repo .. '/tracked.txt')
local work_buf = vim.api.nvim_get_current_buf()

check('relative_path resolves a tracked file', diff.relative_path(repo, work_buf) == 'tracked.txt',
  tostring(diff.relative_path(repo, work_buf)))

diff.open()
local in_diff = wait_for(function()
  return #vim.api.nvim_tabpage_list_wins(0) >= 2 and vim.wo[vim.api.nvim_get_current_win()].diff
end, 'diff mode')
check('diff opens two panes', in_diff)

if in_diff then
  check('working pane is in diff mode', vim.wo[vim.api.nvim_get_current_win()].diff)
  -- Cursor must land in the editable pane; landing in the read-only one makes the first keystroke
  -- fail for no visible reason.
  check('cursor stays in the working-tree pane',
    vim.api.nvim_get_current_buf() == work_buf,
    vim.api.nvim_buf_get_name(vim.api.nvim_get_current_buf()))

  local rev_buf
  for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    local b = vim.api.nvim_win_get_buf(w)
    if b ~= work_buf then rev_buf = b end
  end
  check('revision pane exists', rev_buf ~= nil)
  if rev_buf then
    check('revision pane is read-only', vim.bo[rev_buf].modifiable == false)
    check('revision pane inherits the filetype', vim.bo[rev_buf].filetype == vim.bo[work_buf].filetype,
      vim.bo[rev_buf].filetype)
    local rev_text = table.concat(vim.api.nvim_buf_get_lines(rev_buf, 0, -1, false), '\n')
    -- The index copy is the committed content, so it must show the pre-edit line.
    check('revision pane shows the indexed content', rev_text == 'one\ntwo\nthree', vim.inspect(rev_text))
    -- git's trailing newline must not become a spurious blank line, which would register as a diff.
    check('no spurious trailing blank line',
      vim.api.nvim_buf_get_lines(rev_buf, -2, -1, false)[1] == 'three',
      vim.inspect(vim.api.nvim_buf_get_lines(rev_buf, -2, -1, false)))

    -- Diff-transfer keys. `]c`/`[c`/`do` are diff mode's own and must stay untouched; only the
    -- transfers that would write into the read-only snapshot are intercepted, so they explain
    -- themselves rather than raising a bare E21 on a pane that looks like the writable one.
    local function mapped(buf, lhs)
      for _, m in ipairs(vim.api.nvim_buf_get_keymap(buf, 'n')) do
        if m.lhs == lhs then return true end
      end
      return false
    end
    check('dp is intercepted in the working pane', mapped(work_buf, 'dp'))
    -- The load-bearing negative: `do` against the index *is* "revert this hunk", the operation users
    -- want most, so shadowing it would remove the one write the diff view legitimately offers.
    check('do is left alone in the working pane', not mapped(work_buf, 'do'))
    check('do is intercepted in the revision pane', mapped(rev_buf, 'do'))
    check('dp is intercepted in the revision pane', mapped(rev_buf, 'dp'))

    -- Pressing the intercepted key must notify rather than raise. `pcall` around `feedkeys` would not
    -- catch E21 anyway (it surfaces asynchronously), so the mapping is invoked directly.
    local notified
    local real_notify = vim.notify
    vim.notify = function(msg) notified = msg end
    for _, m in ipairs(vim.api.nvim_buf_get_keymap(work_buf, 'n')) do
      if m.lhs == 'dp' and m.callback then m.callback() end
    end
    vim.notify = real_notify
    check('dp explains itself', notified ~= nil and notified:find('read%-only') ~= nil,
      tostring(notified))
    check('dp points at the working alternative', notified ~= nil and notified:find('`do`', 1, true) ~= nil,
      tostring(notified))
    check('dp mentions staging is not implemented',
      notified ~= nil and notified:find('not implemented', 1, true) ~= nil, tostring(notified))

    -- Closing the revision pane must leave the working buffer out of diff mode, or it stays stuck
    -- with 'foldmethod=diff' and rewritten window options.
    vim.api.nvim_buf_delete(rev_buf, { force = true })
    wait_for(function()
      for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
        if vim.api.nvim_win_get_buf(w) == work_buf then return vim.wo[w].diff == false end
      end
      return false
    end, 'diff mode to clear')
    for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
      if vim.api.nvim_win_get_buf(w) == work_buf then
        check('closing the revision pane leaves diff mode', vim.wo[w].diff == false)
      end
    end
  end
end

vim.cmd('silent! only')

-- A revision that does not exist must report, not throw.
diff.open('definitely-not-a-ref')
check('bad revision does not crash', true)

-- -------------------------------------------------------------------------------------------------
-- In-progress detection: read from disk, so it survives a restart
-- -------------------------------------------------------------------------------------------------

git(repo, { 'stash', '-q', '-u' })
git(repo, { 'checkout', '-q', '-b', 'other' })
write(repo .. '/tracked.txt', 'one\nOTHER\nthree\n')
git(repo, { 'commit', '-qam', 'other side' })
git(repo, { 'checkout', '-q', 'main' })
write(repo .. '/tracked.txt', 'one\nMAIN\nthree\n')
git(repo, { 'commit', '-qam', 'main side' })

-- Expected to fail: that is the point.
cmd.run_sync({ 'merge', 'other' }, { cwd = repo })
check('merge conflict detected as in progress', status.in_progress(repo) == 'merge',
  tostring(status.in_progress(repo)))

local conflicted
status.fetch(repo, function(s) conflicted = s end)
wait_for(function() return conflicted ~= nil end, 'conflicted status')
local found_conflict = false
for _, e in ipairs(conflicted and conflicted.entries or {}) do
  if e.side == status.CONFLICTED and e.path == 'tracked.txt' then found_conflict = true end
end
check('conflicted file reported', found_conflict,
  vim.inspect(vim.tbl_map(function(e) return e.side .. ':' .. e.path end,
    conflicted and conflicted.entries or {})))
check('conflict state reaches the panel state', conflicted and conflicted.in_progress == 'merge',
  conflicted and tostring(conflicted.in_progress))

cmd.run_sync({ 'merge', '--abort' }, { cwd = repo })
check('merge abort clears in-progress state', status.in_progress(repo) == nil,
  tostring(status.in_progress(repo)))

-- A conflicted rebase also writes MERGE_HEAD, so "rebase" must win over "merge" -- reporting merge
-- there would send the user to `git merge --abort`, which fails and leaves the rebase stuck.
git(repo, { 'checkout', '-q', 'other' })
cmd.run_sync({ 'rebase', 'main' }, { cwd = repo })
check('rebase reported in preference to merge', status.in_progress(repo) == 'rebase',
  tostring(status.in_progress(repo)))
cmd.run_sync({ 'rebase', '--abort' }, { cwd = repo })
check('rebase abort clears state', status.in_progress(repo) == nil, tostring(status.in_progress(repo)))

-- -------------------------------------------------------------------------------------------------
-- Upstream tracking, via a local clone: covers ahead/behind with no network
-- -------------------------------------------------------------------------------------------------

local clone_path = vim.fn.tempname() .. '-ijgit-clone'
cmd.run_sync({ 'clone', '-q', repo, clone_path })
local clone = vim.fs.normalize(vim.uv.fs_realpath(clone_path) or clone_path)
if vim.fn.isdirectory(clone) == 1 then
  git(clone, { 'config', 'user.email', 'test@example.com' })
  git(clone, { 'config', 'user.name', 'IntelliJ Test' })
  git(clone, { 'config', 'commit.gpgsign', 'false' })
  write(clone .. '/local-only.txt', 'local\n')
  git(clone, { 'add', '-A' })
  git(clone, { 'commit', '-qm', 'local only' })

  local cst
  status.fetch(clone, function(s) cst = s end)
  wait_for(function() return cst ~= nil end, 'clone status')
  check('upstream detected in a clone', cst and cst.upstream ~= nil, cst and tostring(cst.upstream))
  check('ahead counted', cst and cst.ahead == 1, cst and cst.ahead)
  check('behind zero', cst and cst.behind == 0, cst and cst.behind)
  check('summary shows the upstream',
    cst and status.summary(cst):find(cst.upstream or 'x', 1, true) ~= nil,
    cst and status.summary(cst))
  vim.fn.delete(clone, 'rf')
end

-- -------------------------------------------------------------------------------------------------
-- Hostile environment: an inherited GIT_DIR must not redirect anything
-- -------------------------------------------------------------------------------------------------

-- This is what a Neovim launched from a git hook or `rebase --exec` looks like. Without the stripping
-- in cmd.env() every command below would run against the wrong repository.
vim.env.GIT_DIR = repo .. '/.git'
vim.env.GIT_WORK_TREE = repo
local other = make_dir('-ijgit-other')
git(other, { 'init', '-q', '-b', 'trunk' })
git(other, { 'config', 'user.email', 'test@example.com' })
git(other, { 'config', 'user.name', 'IntelliJ Test' })
git(other, { 'config', 'commit.gpgsign', 'false' })
write(other .. '/only-here.txt', 'x\n')
git(other, { 'add', '-A' })
git(other, { 'commit', '-qm', 'other repo' })

check('inherited GIT_DIR does not hijack root', cmd.root(other) == other, tostring(cmd.root(other)))
local ost
status.fetch(other, function(s) ost = s end)
wait_for(function() return ost ~= nil end, 'other repo status')
check('inherited GIT_DIR does not hijack status', ost and ost.branch == 'trunk',
  ost and tostring(ost.branch))
vim.env.GIT_DIR = nil
vim.env.GIT_WORK_TREE = nil

-- -------------------------------------------------------------------------------------------------
-- Phase 2: log, filters, branches, commit detail
-- -------------------------------------------------------------------------------------------------

local log = require('intellij-lsp.git.log')
local branches = require('intellij-lsp.git.branches')
local logview = require('intellij-lsp.git.logview')
local branchview = require('intellij-lsp.git.branchview')
local commitview = require('intellij-lsp.git.commit')
local filter_mod = require('intellij-lsp.git.filter')

--- Filter flags for a filter table. Named to avoid shadowing the `filter` local used above.
local function filter_mod_args(f) return filter_mod.args(f) end

-- A real merge topology, so the graph has lanes rather than a straight line. The fixture repo above
-- has been through a merge and a rebase abort; this adds a durable merge commit.
vim.fn.delete(repo .. '/newpkg', 'rf')
git(repo, { 'checkout', '-q', 'main' })
git(repo, { 'checkout', '-q', '--', '.' })
write(repo .. '/graph.txt', 'base\n')
git(repo, { 'add', '-A' })
git(repo, { 'commit', '-qm', 'graph base' })
git(repo, { 'checkout', '-q', '-b', 'topic' })
write(repo .. '/topic.txt', 'topic\n')
git(repo, { 'add', '-A' })
git(repo, { 'commit', '-qm', 'topic work FINDME' })
git(repo, { 'checkout', '-q', 'main' })
write(repo .. '/graph.txt', 'base\nmain side\n')
git(repo, { 'commit', '-qam', 'main side' })
git(repo, { 'merge', '--no-ff', '-q', 'topic', '-m', 'merge topic' })
git(repo, { 'tag', 'v9.9' })

-- Parsing against this git version, not against frozen fixtures: the unit suite pins the format, this
-- pins that git still emits it.
local parsed
log.fetch(repo, { limit = 50 }, function(rows, err)
  if not rows then error('log.fetch failed: ' .. tostring(err)) end
  parsed = rows
end)
wait_for(function() return parsed ~= nil end, 'log.fetch')

local commits, graph_only = 0, 0
for _, r in ipairs(parsed) do
  if r.commit then commits = commits + 1 else graph_only = graph_only + 1 end
end
check('log returns commits', commits > 0, commits)
-- A `--no-ff` merge always produces at least one `|\` or `|/` row.
check('merge topology produces graph-only rows', graph_only > 0, graph_only)

local count_res = cmd.run_sync({ 'rev-list', '--count', 'HEAD' }, { cwd = repo })
local total = tonumber(vim.split(count_res.stdout, '\n', { trimempty = true })[1])
check('commit count matches rev-list', commits == total, ('%s vs %s'):format(commits, total))

-- Decorations must survive the round trip through real git.
local found_head, found_tag = false, false
for _, r in ipairs(parsed) do
  if r.commit then
    for _, ref in ipairs(log.parse_refs(r.commit.refs)) do
      if ref.kind == 'head' then found_head = true end
      if ref.kind == 'tag' and ref.name == 'v9.9' then found_tag = true end
    end
  end
end
check('HEAD decoration found', found_head)
check('tag decoration found', found_tag)

-- The `-n` bound is mandatory: unbounded, this query can run for minutes on a large repo.
local bounded
log.fetch(repo, { limit = 2 }, function(rows) bounded = rows end)
wait_for(function() return bounded ~= nil end, 'bounded log.fetch')
local bounded_commits = 0
for _, r in ipairs(bounded) do if r.commit then bounded_commits = bounded_commits + 1 end end
check('limit is honoured against real git', bounded_commits == 2, bounded_commits)

-- Filters, each against real git rather than argv assertions.
local function count_with(opts)
  local got
  log.fetch(repo, vim.tbl_extend('force', { limit = 100 }, opts), function(rows) got = rows end)
  wait_for(function() return got ~= nil end, 'filtered log.fetch')
  local n = 0
  for _, r in ipairs(got or {}) do if r.commit then n = n + 1 end end
  return n
end

check('message filter narrows',
  count_with({ filter_args = filter_mod_args({ text = 'FINDME' }) }) == 1,
  count_with({ filter_args = filter_mod_args({ text = 'FINDME' }) }))
check('path filter narrows',
  count_with({ path_args = { 'topic.txt' } }) == 1,
  count_with({ path_args = { 'topic.txt' } }))
-- A filter matching nothing must be an empty list, not an error.
check('unmatched filter yields zero, not an error',
  count_with({ filter_args = filter_mod_args({ text = 'NOSUCHCOMMITZZZ' }) }) == 0)
check('author filter narrows',
  count_with({ filter_args = filter_mod_args({ author = 'IntelliJ Test' }) }) == total,
  count_with({ filter_args = filter_mod_args({ author = 'IntelliJ Test' }) }))

-- Commit detail, including a rename so the origin path is exercised.
git(repo, { 'mv', 'graph.txt', 'graph-renamed.txt' })
git(repo, { 'commit', '-qm', 'rename for detail' })
local head = vim.split(cmd.run_sync({ 'rev-parse', 'HEAD' }, { cwd = repo }).stdout, '\n',
  { trimempty = true })[1]

local detail
log.fetch_detail(repo, head, function(d, err)
  if not d then error('fetch_detail failed: ' .. tostring(err)) end
  detail = d
end)
wait_for(function() return detail ~= nil end, 'fetch_detail')
check('detail has the hash', detail.hash == head, detail.hash)
check('detail has an author', detail.author == 'IntelliJ Test', detail.author)
check('detail has a body', detail.body:find('rename for detail', 1, true) ~= nil,
  vim.inspect(detail.body))
check('detail has one parent', #detail.parents == 1, #detail.parents)
check('detail lists the changed file', #detail.files == 1, vim.inspect(detail.files))
check('rename detected with an origin',
  detail.files[1] and detail.files[1].code == 'R'
    and detail.files[1].origin == 'graph.txt', vim.inspect(detail.files[1]))

-- A merge commit has multiple parents, which changes how its diff reads.
local merge_hash = vim.split(
  cmd.run_sync({ 'rev-list', '--merges', '-n', '1', 'HEAD' }, { cwd = repo }).stdout,
  '\n', { trimempty = true })[1]
if merge_hash then
  local mdetail
  log.fetch_detail(repo, merge_hash, function(d) mdetail = d end)
  wait_for(function() return mdetail ~= nil end, 'merge detail')
  check('merge commit reports two parents', mdetail and #mdetail.parents == 2,
    mdetail and #mdetail.parents)
end

-- Branch list against real git.
local blist
branches.fetch(repo, function(l, err)
  if not l then error('branches.fetch failed: ' .. tostring(err)) end
  blist = l
end)
wait_for(function() return blist ~= nil end, 'branches.fetch')
check('branch list is non-empty', #blist > 0, #blist)
check('current branch is main', (branches.current(blist) or {}).name == 'main',
  vim.inspect((branches.current(blist) or {}).name))
check('topic branch listed', (function()
  for _, b in ipairs(blist) do if b.name == 'topic' then return true end end
  return false
end)())

-- Detached HEAD: no ref carries the marker.
git(repo, { 'checkout', '-q', '--detach', 'HEAD~1' })
local dlist
branches.fetch(repo, function(l) dlist = l end)
wait_for(function() return dlist ~= nil end, 'detached branches.fetch')
check('detached HEAD has no current branch', branches.current(dlist) == nil,
  vim.inspect((branches.current(dlist) or {}).name))
git(repo, { 'checkout', '-q', 'main' })

-- Checkout: the clean path, the carried-change path, and the no-op path. The carried case is the one
-- worth pinning, because git does *not* refuse -- it moves the modification across, and a user who is
-- not told will think it was lost.
local ck_ok, ck_msg
branches.checkout(repo, { name = 'topic', kind = branches.LOCAL }, function(ok, msg)
  ck_ok, ck_msg = ok, msg
end)
wait_for(function() return ck_ok ~= nil end, 'clean checkout')
check('clean checkout succeeds', ck_ok == true, tostring(ck_msg))
check('clean checkout names the branch', ck_msg:find('topic', 1, true) ~= nil, ck_msg)

write(repo .. '/tracked.txt', 'one\nCARRIED EDIT\nthree\n')
ck_ok, ck_msg = nil, nil
branches.checkout(repo, { name = 'main', kind = branches.LOCAL }, function(ok, msg)
  ck_ok, ck_msg = ok, msg
end)
wait_for(function() return ck_ok ~= nil end, 'dirty checkout')
check('checkout with a local edit still succeeds', ck_ok == true, tostring(ck_msg))
check('carried change is reported',
  ck_msg:find('came along', 1, true) ~= nil and ck_msg:find('tracked.txt', 1, true) ~= nil, ck_msg)
git(repo, { 'checkout', '-q', '--', '.' })

ck_ok, ck_msg = nil, nil
branches.checkout(repo, { name = 'main', kind = branches.LOCAL, current = true }, function(ok, msg)
  ck_ok, ck_msg = ok, msg
end)
wait_for(function() return ck_ok ~= nil end, 'same-branch checkout')
check('checking out the current branch is a no-op',
  ck_ok == true and ck_msg:find('already on', 1, true) ~= nil, tostring(ck_msg))

-- -------------------------------------------------------------------------------------------------
-- Phase 2 views
-- -------------------------------------------------------------------------------------------------

vim.cmd('silent! only')
vim.cmd.edit(repo .. '/tracked.txt')
local view_origin = vim.api.nvim_get_current_win()

logview.open()
wait_for(function() return logview.is_open() and logview.current() ~= nil end, 'log view')
check('log view opens', logview.is_open())
check('log view selects a commit', logview.current() ~= nil, vim.inspect(logview.current()))

if logview.is_open() then
  local previewed = wait_for(function()
    if not vim.api.nvim_win_is_valid(view_origin) then return false end
    local name = vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(view_origin))
    return name:find('intellij%-git://preview') ~= nil
  end, 'log preview')
  check('log preview renders', previewed)

  -- The row map must be sparse: the header is not a commit.
  local lbuf
  for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    local b = vim.api.nvim_win_get_buf(w)
    if vim.api.nvim_buf_get_name(b):find('intellij%-git://log') then lbuf = b end
  end
  check('log buffer exists', lbuf ~= nil)
  if lbuf then
    pcall(vim.api.nvim_win_set_cursor, vim.fn.bufwinid(lbuf), { 1, 0 })
    check('header row is not a commit', logview.current() == nil)
  end

  -- The log is a full-width bottom split, not a right-hand vertical one: same column as the editor,
  -- lower down, and the full editor width rather than a share of it.
  -- The editor window is identified by exclusion, not by filename: by now the preview has replaced
  -- `tracked.txt` in it with the preview buffer, which is exactly what the previewing design does.
  local lwin, ewin
  for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    local n = vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(w))
    if n:find('intellij%-git://log') then lwin = w else ewin = ewin or w end
  end
  if lwin and ewin then
    local lp = vim.api.nvim_win_get_position(lwin)
    local ep = vim.api.nvim_win_get_position(ewin)
    check('log window is below the editor', lp[1] > ep[1], ('%d vs %d'):format(lp[1], ep[1]))
    check('log window shares the editor column', lp[2] == ep[2], ('%d vs %d'):format(lp[2], ep[2]))
    check('log window spans the full width',
      vim.api.nvim_win_get_width(lwin) == vim.o.columns,
      ('%d vs %d'):format(vim.api.nvim_win_get_width(lwin), vim.o.columns))
  else
    check('log and editor windows both found', false, ('lwin=%s ewin=%s'):format(tostring(lwin), tostring(ewin)))
  end

  local selected = logview.current()
  logview.close(true)
  check('log view closes', not logview.is_open())
  local restored = vim.api.nvim_win_is_valid(view_origin)
    and vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(view_origin))
  check('log close(true) restores the buffer',
    restored and restored:find('tracked.txt', 1, true) ~= nil, tostring(restored))
  local _ = selected
end
logview.close(false)
check('log close is idempotent', not logview.is_open())

-- -------------------------------------------------------------------------------------------------
-- Affected-files preview, against real git
-- -------------------------------------------------------------------------------------------------

-- A commit with a rename and a binary file, because those are the two shapes that break a naive
-- name-status/numstat join: numstat compresses a rename to `dir/{ => sub}/file` (matching neither the
-- old nor the new path) and reports `-` for binary files instead of numbers.
git(repo, { 'checkout', '-q', 'main' })
vim.fn.mkdir(repo .. '/assets', 'p')
--- Writes a file containing a NUL byte, which is what makes git treat it as binary.
---
--- Via `io.open` in binary mode rather than `vim.fn.writefile`: writefile takes a list of *lines* and
--- rejects an embedded NUL ("Expected a Number or a String, Blob found").
local function write_binary(path, text)
  vim.fn.mkdir(vim.fs.dirname(path), 'p')
  local fd = assert(io.open(path, 'wb'))
  fd:write(text)
  fd:close()
end

write_binary(repo .. '/assets/logo.bin', 'PNG\0\1\2\3binary payload')
write(repo .. '/assets/keep.txt', 'one\ntwo\n')
git(repo, { 'add', '-A' })
git(repo, { 'commit', '-qm', 'add assets' })

git(repo, { 'mv', 'assets/keep.txt', 'assets/renamed.txt' })
write(repo .. '/assets/renamed.txt', 'one\ntwo\nthree\n')
write_binary(repo .. '/assets/logo.bin', 'PNG\0\9\9\9changed payload')
write(repo .. '/assets/added.txt', 'brand new\n')
git(repo, { 'rm', '-q', 'topic.txt' })
git(repo, { 'add', '-A' })
git(repo, { 'commit', '-qm', 'mixed change' })
local mixed = vim.split(cmd.run_sync({ 'rev-parse', 'HEAD' }, { cwd = repo }).stdout, '\n',
  { trimempty = true })[1]

local mfiles
log.fetch_files(repo, mixed, function(f, err)
  if not f then error('fetch_files failed: ' .. tostring(err)) end
  mfiles = f
end)
wait_for(function() return mfiles ~= nil end, 'fetch_files')

local by_path = {}
for _, f in ipairs(mfiles) do by_path[f.path] = f end

check('added file detected', by_path['assets/added.txt']
  and by_path['assets/added.txt'].code == 'A',
  vim.inspect(by_path['assets/added.txt']))
check('deleted file detected', by_path['topic.txt'] and by_path['topic.txt'].code == 'D',
  vim.inspect(by_path['topic.txt']))
check('rename detected with its origin', by_path['assets/renamed.txt']
  and by_path['assets/renamed.txt'].code == 'R'
  and by_path['assets/renamed.txt'].origin == 'assets/keep.txt',
  vim.inspect(by_path['assets/renamed.txt']))
-- The positional join is what makes counts survive numstat's compressed rename path.
check('rename still carries line counts',
  by_path['assets/renamed.txt'] and by_path['assets/renamed.txt'].added == 1,
  vim.inspect(by_path['assets/renamed.txt']))
check('added file has real counts',
  by_path['assets/added.txt'] and by_path['assets/added.txt'].added == 1,
  vim.inspect(by_path['assets/added.txt']))
check('binary file flagged', by_path['assets/logo.bin']
  and by_path['assets/logo.bin'].binary == true,
  vim.inspect(by_path['assets/logo.bin']))

local rendered = table.concat(
  logview._render_files({ short = 'abcdefg', subject = 'mixed change', author = 'A', date = 'now' },
    mfiles), '\n')
check('rendered list shows the rename arrow',
  rendered:find('assets/renamed.txt ← assets/keep.txt', 1, true) ~= nil, rendered)
check('rendered list shows bin for binary',
  rendered:find('bin', 1, true) ~= nil, rendered)
check('rendered list has a totals line',
  rendered:find('files changed', 1, true) ~= nil, rendered)
-- The raw patch is what this preview deliberately replaced.
check('rendered list is not a raw patch',
  rendered:find('@@', 1, true) == nil and rendered:find('^%+%+%+') == nil, rendered)

-- An empty commit has no files, and must say so rather than render a blank pane.
git(repo, { 'commit', '-q', '--allow-empty', '-m', 'empty commit' })
local empty_hash = vim.split(cmd.run_sync({ 'rev-parse', 'HEAD' }, { cwd = repo }).stdout, '\n',
  { trimempty = true })[1]
local efiles
log.fetch_files(repo, empty_hash, function(f) efiles = f end)
wait_for(function() return efiles ~= nil end, 'empty commit files')
check('empty commit has no files', #efiles == 0, #efiles)
check('empty commit is explained',
  table.concat(logview._render_files({ short = 'e', subject = 's', author = 'a', date = 'n' },
    efiles), '\n'):find('no files changed', 1, true) ~= nil)

-- The preview must render as a highlighted list, not as diff-syntax text.
vim.cmd('silent! only')
vim.cmd.edit(repo .. '/tracked.txt')
local fp_origin = vim.api.nvim_get_current_win()
logview.open()
wait_for(function() return logview.is_open() and logview.current() ~= nil end, 'log for file preview')
local fp_ok = wait_for(function()
  if not vim.api.nvim_win_is_valid(fp_origin) then return false end
  local b = vim.api.nvim_win_get_buf(fp_origin)
  return vim.api.nvim_buf_get_name(b):find('intellij%-git://preview') ~= nil
    and #vim.api.nvim_buf_get_extmarks(b, -1, 0, -1, {}) > 0
end, 'highlighted file preview')
check('preview renders a highlighted file list', fp_ok)
if fp_ok then
  local pbuf = vim.api.nvim_win_get_buf(fp_origin)
  -- `text`, not `diff`: diff syntax would colour any path beginning with `-` or `+` as a patch line.
  check('preview is not diff filetype', vim.bo[pbuf].filetype == 'text', vim.bo[pbuf].filetype)
  local ptext = table.concat(vim.api.nvim_buf_get_lines(pbuf, 0, -1, false), '\n')
  check('preview shows a file summary', ptext:find('changed', 1, true) ~= nil, ptext:sub(1, 200))
  check('preview contains no hunk headers', ptext:find('@@', 1, true) == nil, ptext:sub(1, 200))
end
logview.close(false)
vim.cmd('silent! only')

-- -------------------------------------------------------------------------------------------------
-- Switching branches from inside the log
-- -------------------------------------------------------------------------------------------------

vim.cmd('silent! only')
vim.cmd.edit(repo .. '/tracked.txt')
git(repo, { 'checkout', '-q', 'main' })

-- `vim.ui.select` is stubbed so the picker can be observed and answered headlessly.
local real_select = vim.ui.select
local real_notify = vim.notify
local picker_items, notes

local function with_stubs(fn)
  picker_items, notes = nil, {}
  vim.ui.select = function(items, opts, cb)
    picker_items = vim.tbl_map(function(b) return b.name end, items)
    -- Also exercises format_item, which would otherwise never run under test.
    for _, it in ipairs(items) do local _ = opts.format_item(it) end
    cb(items[1])
  end
  vim.notify = function(m) notes[#notes + 1] = m end
  fn()
  vim.ui.select = real_select
  vim.notify = real_notify
end

--- The log row whose decorations contain `needle`.
local function row_with(needle)
  local buf
  for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    local b = vim.api.nvim_win_get_buf(w)
    if vim.api.nvim_buf_get_name(b):find('intellij%-git://log') then buf = b end
  end
  if not buf then return nil, nil end
  for i, l in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
    if l:find(needle, 1, true) then return i, buf end
  end
  return nil, buf
end

local function branch_now()
  return vim.trim(vim.split(
    cmd.run_sync({ 'rev-parse', '--abbrev-ref', 'HEAD' }, { cwd = repo }).stdout, '\n')[1] or '')
end

logview.open()
wait_for(function() return logview.is_open() and logview.current() ~= nil end, 'log for switching')

-- `--all` so branch tips other than HEAD's are in the list.
logview._view().filter.range = '--all'
vim.cmd('normal R')
wait_for(function() return row_with('(topic)') ~= nil or row_with('topic') ~= nil end, 'topic row')

-- Case 1: the HEAD row. Exactly one branch decorates it -- the current one -- so a naive `#at == 1`
-- fast path would "switch" to where you already are and never prompt. That was a real bug: the most
-- obvious row to press `b` on was a silent no-op. It must fall through to the picker instead.
local head_row = row_with('HEAD ->')
if head_row then
  local _, lbuf = row_with('HEAD ->')
  pcall(vim.api.nvim_win_set_cursor, vim.fn.bufwinid(lbuf), { head_row, 0 })
  local at_head = logview._branches_at(logview.current())
  check('HEAD row decorates exactly one branch', #at_head == 1, vim.inspect(at_head))

  with_stubs(function()
    vim.cmd('normal b')
    -- Waiting on `picker_items` alone is not enough and previously made this flaky-looking: the stub
    -- sets it synchronously the moment the picker opens, which is *before* the checkout it triggers has
    -- run. The notification is what marks the checkout complete.
    wait_for(function() return #notes > 0 end, 'checkout after the picker')
  end)
  check('b on the HEAD row opens the picker rather than no-opping',
    picker_items ~= nil, vim.inspect(notes))
  -- The current branch is never offered: it is the one entry that can do nothing.
  if picker_items then
    check('picker excludes the current branch', not vim.tbl_contains(picker_items, 'main'),
      vim.inspect(picker_items))
    check('picker offers another branch', #picker_items > 0, vim.inspect(picker_items))
  end
  -- Must have switched to one of the branches actually offered -- not merely "not main", which a
  -- checkout of some unrelated branch would satisfy. Membership rather than `picker_items[1]`, because
  -- the list is sorted by committer date and the fixture's branches share a timestamp, so which one
  -- sorts first is not stable.
  local landed = branch_now()
  check('the picker choice actually switched',
    picker_items and vim.tbl_contains(picker_items, landed),
    ('now=%s offered=%s'):format(landed, vim.inspect(picker_items)))
end

-- Case 2: a row whose sole decorating branch is not current -- switch straight there, no prompt.
git(repo, { 'checkout', '-q', 'main' })
logview.close(false)
vim.cmd('silent! only')
vim.cmd.edit(repo .. '/tracked.txt')
logview.open()
wait_for(function() return logview.is_open() and logview.current() ~= nil end, 'log again')
logview._view().filter.range = '--all'
vim.cmd('normal R')
wait_for(function() return row_with('(topic)') ~= nil end, 'topic tip row')

local topic_row, tbuf = row_with('(topic)')
if topic_row then
  pcall(vim.api.nvim_win_set_cursor, vim.fn.bufwinid(tbuf), { topic_row, 0 })
  local at_topic = logview._branches_at(logview.current())
  check('topic row decorates topic only', vim.deep_equal(at_topic, { 'topic' }), vim.inspect(at_topic))

  with_stubs(function()
    vim.cmd('normal b')
    wait_for(function() return #notes > 0 end, 'direct switch')
  end)
  check('single non-current branch switches with no picker', picker_items == nil,
    vim.inspect(picker_items))
  check('direct switch landed on topic', branch_now() == 'topic', branch_now())
  check('direct switch was reported',
    #notes > 0 and notes[1]:find('topic', 1, true) ~= nil, vim.inspect(notes))
end

logview.close(false)
git(repo, { 'checkout', '-q', 'main' })
vim.cmd('silent! only')

-- Commit detail view.
vim.cmd('silent! only')
vim.cmd.edit(repo .. '/tracked.txt')
local cv_origin = vim.api.nvim_get_current_win()
commitview.open(repo, mixed)
wait_for(function() return commitview.is_open() and commitview.current() ~= nil end, 'commit view')
check('commit view opens', commitview.is_open())
check('commit view selects a file', commitview.current() ~= nil, vim.inspect(commitview.current()))

-- Bottom, matching the log: `<CR>` from the log must not relocate the UI to the other side.
local cwin
for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
  if vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(w)):find('intellij%-git://commit') then
    cwin = w
  end
end
check('commit view window found', cwin ~= nil)
if cwin and vim.api.nvim_win_is_valid(cv_origin) then
  local cp = vim.api.nvim_win_get_position(cwin)
  local op = vim.api.nvim_win_get_position(cv_origin)
  check('commit view is below the editor', cp[1] > op[1], ('%d vs %d'):format(cp[1], op[1]))
  check('commit view spans the full width',
    vim.api.nvim_win_get_width(cwin) == vim.o.columns)
end

-- The preview is a live side-by-side diff, not a unified patch: two extra windows, both in diff mode
-- and both read-only, refreshed as the cursor steps the file list.
local sbs_ok = wait_for(function()
  local diffs = 0
  for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if vim.wo[w].diff then diffs = diffs + 1 end
  end
  return diffs == 2
end, 'side-by-side preview panes')
check('preview opens two diff panes', sbs_ok)

if sbs_ok then
  local pane_names, all_ro = {}, true
  for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if vim.wo[w].diff then
      local b = vim.api.nvim_win_get_buf(w)
      pane_names[#pane_names + 1] = vim.api.nvim_buf_get_name(b)
      if vim.bo[b].modifiable then all_ro = false end
    end
  end
  check('both preview panes are read-only', all_ro, vim.inspect(pane_names))
  -- One side is the parent revision (`<short>^`), the other the commit itself.
  check('one pane is the parent revision',
    table.concat(pane_names, ' '):find('%^/') ~= nil, vim.inspect(pane_names))
  -- The unified patch is what this replaced.
  local any_patch = false
  for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if vim.wo[w].diff then
      local text = table.concat(vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(w), 0, -1, false), '\n')
      if text:find('@@', 1, true) then any_patch = true end
    end
  end
  check('preview panes hold file content, not a patch', not any_patch)
end

-- Stepping to another file must refresh both panes and keep diff mode. Replacing a buffer in a window
-- silently drops diff mode, so without a re-assert the second file shows two plain, unhighlighted
-- panes -- which looks like the feature working for one file and breaking for the next.
if cwin then
  local first_pane
  for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if vim.wo[w].diff then
      first_pane = table.concat(vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(w), 0, 3, false), '|')
      break
    end
  end
  -- Move to a different file in the list.
  for row = 1, vim.api.nvim_buf_line_count(vim.api.nvim_win_get_buf(cwin)) do
    pcall(vim.api.nvim_win_set_cursor, cwin, { row, 0 })
    local f = commitview.current()
    if f and f.path == 'assets/added.txt' then break end
  end
  vim.api.nvim_set_current_win(cwin)
  vim.cmd('doautocmd CursorMoved')
  local stepped = wait_for(function()
    local diffs, changed = 0, false
    for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
      if vim.wo[w].diff then
        diffs = diffs + 1
        local now = table.concat(vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(w), 0, 3, false), '|')
        if now ~= first_pane then changed = true end
      end
    end
    return diffs == 2 and changed
  end, 'preview refresh on step')
  check('stepping refreshes both panes and keeps diff mode', stepped)
end

-- Scratch render buffers must not source filetype plugins.
--
-- Neovim's bundled `ftplugin/java.vim` sets
--   b:undo_ftplugin = 'call JavaFileTypeCleanUp() | delfunction JavaFileTypeCleanUp'
-- so its undo hook deletes the function it just called, while the definition sits behind a
-- `b:did_ftplugin` guard. These preview buffers are reused across files, so reassigning 'filetype' on
-- each step ran the undo twice and raised `E117: Unknown function: JavaFileTypeCleanUp` -- once per
-- step, with a hit-enter prompt. `java.vim` is the only ftplugin in the runtime that does this.
vim.cmd('silent! filetype plugin on')
write(repo .. '/Alpha.java', 'class Alpha { int x; }\n')
write(repo .. '/Beta.java', 'class Beta { int y; }\n')
git(repo, { 'add', '-A' })
git(repo, { 'commit', '-qm', 'add java' })
write(repo .. '/Alpha.java', 'class Alpha { int x2; }\n')
write(repo .. '/Beta.java', 'class Beta { int y2; }\n')
git(repo, { 'commit', '-qam', 'touch java' })
local java_hash = vim.split(cmd.run_sync({ 'rev-parse', 'HEAD' }, { cwd = repo }).stdout, '\n',
  { trimempty = true })[1]

commitview.close(false)
vim.cmd('silent! only')
vim.cmd.edit(repo .. '/Alpha.java')
commitview.open(repo, java_hash)
wait_for(function() return commitview.is_open() and commitview.current() ~= nil end, 'java commit view')

local jwin
for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
  if vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(w)):find('intellij%-git://commit') then
    jwin = w
  end
end

if jwin then
  -- Step every file several times: the bug needed the *second* filetype change on a reused buffer.
  for _ = 1, 3 do
    for row = 1, vim.api.nvim_buf_line_count(vim.api.nvim_win_get_buf(jwin)) do
      pcall(vim.api.nvim_win_set_cursor, jwin, { row, 0 })
      if commitview.current() then
        vim.api.nvim_set_current_win(jwin)
        vim.cmd('doautocmd CursorMoved')
        vim.wait(120, function() return false end, 20)
      end
    end
  end
end

-- `pcall` around the step is NOT how this bug surfaces and must not be relied on: the error is raised
-- inside a `FileType` autocmd, which Neovim reports and continues past rather than propagating to the
-- caller. A `pcall`-based check passes even with the fix removed -- verified by reverting it.
--
-- The reliable signal is the function itself. `ftplugin/java.vim` defines it behind a `b:did_ftplugin`
-- guard and *deletes* it from `b:undo_ftplugin`, so if our scratch buffers ran that undo the function
-- is gone; if they did not, it survives. That inverts cleanly and is what actually fails when the
-- suppression is removed.
check('the java ftplugin function survives stepping',
  vim.fn.exists('*JavaFileTypeCleanUp') == 1,
  ('exists=%d (0 means our scratch buffers ran its undo hook and destroyed it)')
    :format(vim.fn.exists('*JavaFileTypeCleanUp')))

-- The scratch buffers must never have sourced an ftplugin in the first place.
for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
  local b = vim.api.nvim_win_get_buf(w)
  local n = vim.api.nvim_buf_get_name(b)
  if n:find('intellij%-git://') and n:find('%.java$') then
    check('revision pane did not source an ftplugin',
      vim.b[b].did_ftplugin == nil, tostring(vim.b[b].did_ftplugin))
  end
end

-- Suppressing the ftplugin must not cost syntax highlighting, which is the reason to set a filetype at
-- all on these buffers.
local checked_syntax = false
for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
  local b = vim.api.nvim_win_get_buf(w)
  local n = vim.api.nvim_buf_get_name(b)
  if n:find('intellij%-git://') and n:find('%.java$') then
    check('revision pane keeps its filetype', vim.bo[b].filetype == 'java', vim.bo[b].filetype)
    check('revision pane keeps its syntax', vim.bo[b].syntax == 'java', vim.bo[b].syntax)
    checked_syntax = true
  end
end
check('java revision panes were rendered', checked_syntax)

commitview.close(false)
vim.cmd('silent! only')
vim.cmd.edit(repo .. '/tracked.txt')
commitview.open(repo, mixed)
wait_for(function() return commitview.is_open() and commitview.current() ~= nil end, 'view restored')
cwin = nil
for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
  if vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(w)):find('intellij%-git://commit') then
    cwin = w
  end
end

-- The file list is rendered like the log's preview, counts and all, so the two cannot drift apart.
if cwin then
  local ctext = table.concat(vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(cwin), 0, -1, false), '\n')
  check('detail list shows line counts', ctext:find('%+%d+ %-%d+') ~= nil, ctext)
  check('detail list shows the rename arrow', ctext:find('←', 1, true) ~= nil, ctext)
  check('detail list marks the binary', ctext:find('bin', 1, true) ~= nil, ctext)

  -- Every file row must actually carry highlights in the buffer, not merely have them computed.
  -- `nvim_buf_set_extmark` rejects an `end_col` when `end_row` is omitted, and the call is wrapped in a
  -- `pcall`, so a whole row's spans could vanish silently. That is exactly what happened to the rename
  -- rows -- the longest ones -- leaving them unstyled while every other row looked right, which reads
  -- as an inconsistent colour scheme rather than as a bug.
  local cbuf = vim.api.nvim_win_get_buf(cwin)
  local unstyled, styled = {}, 0
  -- File rows only: a two-space indent, a status word, then the counts column (`+N -N` or `bin`). The
  -- indent alone is not enough -- the commit subject is indented the same way, and matching it made
  -- this check report one more row than there are files.
  local FILE_ROW = '^  %a+%s+[%+b]'
  for row = 0, vim.api.nvim_buf_line_count(cbuf) - 1 do
    local line = vim.api.nvim_buf_get_lines(cbuf, row, row + 1, false)[1] or ''
    if line:match(FILE_ROW) then
      local marks = vim.api.nvim_buf_get_extmarks(cbuf, -1, { row, 0 }, { row, -1 }, {})
      if #marks == 0 then unstyled[#unstyled + 1] = line else styled = styled + 1 end
    end
  end
  check('every file row is highlighted', #unstyled == 0, vim.inspect(unstyled))
  check('file rows were found at all', styled > 0, styled)

  -- The path column is claimed on every row, so it cannot inherit per-row syntax colouring.
  local path_spans = 0
  for _, m in ipairs(vim.api.nvim_buf_get_extmarks(cbuf, -1, 0, -1, { details = true })) do
    if m[4].hl_group == 'IntellijGitFilePath' then path_spans = path_spans + 1 end
  end
  check('paths are explicitly coloured', path_spans == styled,
    ('%d path spans for %d rows'):format(path_spans, styled))
end

-- `<CR>` opens a two-pane diff of what the commit did to the file: parent left, commit right, both
-- read-only, both in diff mode -- the `:IntellijGitDiff` experience applied to history.
local tabs_before = #vim.api.nvim_list_tabpages()
local target_file
for row = 1, vim.api.nvim_buf_line_count(vim.api.nvim_win_get_buf(cwin or 0)) do
  pcall(vim.api.nvim_win_set_cursor, cwin, { row, 0 })
  local f = commitview.current()
  if f and f.path == 'assets/renamed.txt' then target_file = f break end
end
check('found the renamed file in the detail list', target_file ~= nil)

if target_file then
  require('intellij-lsp.git.diff').open_commit_file(repo, mixed, target_file)
  local opened = wait_for(function()
    return #vim.api.nvim_list_tabpages() > tabs_before
  end, 'historical diff tab')
  check('commit-file diff opens', opened)

  if opened then
    local dwins = vim.api.nvim_tabpage_list_wins(0)
    check('historical diff has two panes', #dwins == 2, #dwins)
    local both_diff, both_ro, names = true, true, {}
    for _, w in ipairs(dwins) do
      local b = vim.api.nvim_win_get_buf(w)
      if not vim.wo[w].diff then both_diff = false end
      -- Neither side is editable: both are historical revisions, unlike the working-tree diff where
      -- the right pane is the live file.
      if vim.bo[b].modifiable then both_ro = false end
      names[#names + 1] = vim.api.nvim_buf_get_name(b)
    end
    check('both panes are in diff mode', both_diff)
    check('both panes are read-only', both_ro, vim.inspect(names))
    -- A rename must read the *old* path on the parent side, or a pure move renders as a whole-file
    -- addition against an empty pane.
    check('parent pane uses the pre-rename path',
      table.concat(names, ' '):find('assets/keep.txt', 1, true) ~= nil, vim.inspect(names))
    check('commit pane uses the post-rename path',
      table.concat(names, ' '):find('assets/renamed.txt', 1, true) ~= nil, vim.inspect(names))
    vim.cmd('tabclose')
  end
end

-- An added file has no parent revision; the left pane must be empty rather than the diff failing.
local added_file = { path = 'assets/added.txt', code = 'A' }
require('intellij-lsp.git.diff').open_commit_file(repo, mixed, added_file)
local added_opened = wait_for(function()
  return #vim.api.nvim_list_tabpages() > tabs_before
end, 'added-file diff')
check('added file still opens a diff', added_opened)
if added_opened then
  local empty_side = false
  for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    local b = vim.api.nvim_win_get_buf(w)
    local l = vim.api.nvim_buf_get_lines(b, 0, -1, false)
    -- An empty Neovim buffer reports a single empty line.
    if #l == 1 and l[1] == '' then empty_side = true end
  end
  check('added file has an empty parent pane', empty_side)
  vim.cmd('tabclose')
end

-- Teardown must leave the layout as it was found. The trap: deleting a buffer closes every window
-- showing it, and after the split one of the scratch revisions is displayed in the *caller's own*
-- window -- so deleting it before evicting it destroys the origin window, and `restore` then has
-- nothing to restore into. That bug left the panel buffer sitting in the editor area.
vim.cmd('silent! only')
vim.cmd.edit(repo .. '/tracked.txt')
local td_origin = vim.api.nvim_get_current_win()
local td_buf = vim.api.nvim_get_current_buf()
local windows_before = #vim.api.nvim_tabpage_list_wins(0)

commitview.open(repo, mixed)
wait_for(function() return commitview.is_open() and commitview.current() ~= nil end, 'view for teardown')
wait_for(function()
  local diffs = 0
  for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if vim.wo[w].diff then diffs = diffs + 1 end
  end
  return diffs == 2
end, 'diff panes before teardown')

commitview.close(true)
check('commit view closes', not commitview.is_open())
check('teardown restores the window count',
  #vim.api.nvim_tabpage_list_wins(0) == windows_before,
  ('%d vs %d'):format(#vim.api.nvim_tabpage_list_wins(0), windows_before))
check('teardown leaves the origin window alive', vim.api.nvim_win_is_valid(td_origin))
if vim.api.nvim_win_is_valid(td_origin) then
  check('teardown restores the original buffer',
    vim.api.nvim_win_get_buf(td_origin) == td_buf,
    vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(td_origin)))
  -- Left in diff mode, the restored buffer would carry `foldmethod=diff` and rewritten window options.
  check('teardown leaves diff mode', vim.wo[td_origin].diff == false)
end
vim.cmd('silent! only')

-- Branch view, and the bug that motivated cmd.set_buffer_root: opening one view from another must
-- resolve the same repository even though the current buffer is a fileless scratch.
vim.cmd('silent! only')
vim.cmd.edit(repo .. '/tracked.txt')
logview.open()
wait_for(function() return logview.is_open() end, 'log view for nesting')
branchview.open()
local nested = wait_for(function() return branchview.is_open() end, 'branch view from the log view')
check('branch view opens from inside another view', nested)
if branchview.is_open() then
  check('branch view finds the repository', branchview.current() ~= nil
    or vim.api.nvim_buf_line_count(0) > 0)
  branchview.close(false)
end
logview.close(false)
vim.cmd('silent! only')

-- The root must also resolve when the current buffer is a preview scratch, whose name
-- (`intellij-git://preview/3`) is non-empty but is not a path -- `dirname` on it yields a directory
-- that does not exist.
local scratch = vim.api.nvim_create_buf(false, true)
vim.api.nvim_buf_set_name(scratch, 'intellij-git://preview/999')
vim.api.nvim_set_current_buf(scratch)
local old_cwd = vim.uv.cwd()
vim.cmd.cd(repo)
check('root resolves from a non-path buffer name via cwd', cmd.root() == repo, tostring(cmd.root()))
vim.cmd.cd(old_cwd)
vim.api.nvim_set_current_buf(vim.api.nvim_create_buf(true, true))
pcall(vim.api.nvim_buf_delete, scratch, { force = true })

-- -------------------------------------------------------------------------------------------------

vim.fn.delete(repo, 'rf')
vim.fn.delete(other, 'rf')

print(('\n%s'):format(failures == 0 and 'ALL GIT E2E CHECKS PASSED'
  or (failures .. ' GIT E2E CHECK(S) FAILED')))
if failures > 0 then vim.cmd('cquit 1') end
