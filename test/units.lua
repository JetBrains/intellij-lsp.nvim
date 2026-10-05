-- Unit checks for the pure launch/eula logic. No server required.
--
--   nvim --headless -u NONE -l test/units.lua
vim.opt.runtimepath:prepend(vim.fs.dirname(vim.fs.dirname(debug.getinfo(1, 'S').source:sub(2))))

local launch = require('intellij-lsp.launch')
local eula = require('intellij-lsp.eula')
local client = require('intellij-lsp.client')

local failures = 0
local function check(name, cond, detail)
  if cond then
    print('ok   ' .. name)
  else
    failures = failures + 1
    print('FAIL ' .. name .. (detail and ('  -> ' .. tostring(detail)) or ''))
  end
end

-- Path-shaped fixtures: these checks are pure string/hash logic and touch no real bundle.
local BUNDLE = vim.fs.normalize(vim.fn.tempname() .. '-bundle')
local SERVER = BUNDLE .. '/bin/intellij-server'

-- server_root strips bin/<launcher>
check('server_root', launch.server_root(SERVER) == BUNDLE, launch.server_root(SERVER))

-- system_path is deterministic and project-scoped
local sp1 = launch.system_path('/tmp/ijtest')
local sp2 = launch.system_path('/tmp/ijtest')
local sp3 = launch.system_path('/tmp/other')
check('system_path deterministic', sp1 == sp2)
check('system_path per-project', sp1 ~= sp3)
check('system_path under cache', sp1:find(vim.fn.stdpath('cache'), 1, true) == 1, sp1)

-- cmd: stdio + system-path, and no --eula for a dev bundle (no EULA.txt)
local cmd = launch.build_cmd({ server_path = SERVER, root_dir = '/tmp/ijtest', accept_eula = true })
check('cmd[1] is launcher', cmd[1] == SERVER)
check('cmd has --stdio', vim.tbl_contains(cmd, '--stdio'))
check('cmd has --system-path', vim.tbl_contains(cmd, '--system-path'))
check('dev bundle -> no --eula', not vim.tbl_contains(cmd, '--eula'), table.concat(cmd, ' '))

-- An explicitly claimed cache directory is what reaches the command line.
local cmd_slot = launch.build_cmd({ server_path = SERVER, root_dir = '/tmp/ijtest', accept_eula = false, system_path = '/tmp/ij-slot-2' })
check('cmd uses the claimed system path', cmd_slot[4] == '/tmp/ij-slot-2', cmd_slot[4])

-- Slots: one cache directory per live Neovim instance on the same project.
check('slot 1 is the plain path', launch.system_path('/tmp/ijtest', 1) == launch.system_path('/tmp/ijtest'))
check('slot 2 is suffixed', launch.system_path('/tmp/ijtest', 2) == launch.system_path('/tmp/ijtest') .. '-2',
  launch.system_path('/tmp/ijtest', 2))

do
  local root = vim.fn.tempname() .. '-claimroot'
  local me = vim.uv.os_getpid()
  local p1, p2 = launch.system_path(root, 1), launch.system_path(root, 2)

  local got, slot = launch.claim_system_path(root)
  check('first claim takes slot 1', got == p1 and slot == 1, got)
  check('claim records our pid', launch.system_path_owner(p1) == me, tostring(launch.system_path_owner(p1)))
  local again = launch.claim_system_path(root)
  check('re-claiming our own slot keeps it', again == p1, again)

  -- Another live process holds slot 1: the parent shell is alive for the duration of this test.
  vim.fn.writefile({ tostring(vim.uv.os_getppid()) }, p1 .. '/nvim.pid')
  got, slot = launch.claim_system_path(root)
  check('a live foreign owner pushes us to slot 2', got == p2 and slot == 2, got)
  check('slot 2 records our pid', launch.system_path_owner(p2) == me)

  -- A dead owner does not block a slot (Neovim killed before on_exit ran).
  vim.fn.writefile({ '4194000' }, p1 .. '/nvim.pid')
  got, slot = launch.claim_system_path(root)
  check('a stale owner is overtaken', got == p1 and slot == 1, got)

  launch.release_system_path(p1)
  check('release removes our owner file', launch.system_path_owner(p1) == nil)
  vim.fn.writefile({ tostring(vim.uv.os_getppid()) }, p1 .. '/nvim.pid')
  launch.release_system_path(p1)
  check('release leaves a foreign owner alone', launch.system_path_owner(p1) == vim.uv.os_getppid())

  vim.fn.delete(p1, 'rf'); vim.fn.delete(p2, 'rf')
end

-- Failed initialize: the reason is the line after the last SEVERE header in the server log.
local severe_log = {
  '2026-09-29 19:55:30,840 [    749]   INFO - #c.i.l.s.k.tt - Got `initialize` request',
  '2026-09-29 19:55:30,961 [    870] SEVERE - #c.j.l.i.LspClient - ',
  'org.rocksdb.RocksDBException: While lock file: /x/rocks/v276/LOCK: Resource temporarily unavailable',
  '\tat org.rocksdb.RocksDB.open(Native Method)',
}
check('last SEVERE reason is the exception line',
  client._last_severe(severe_log) == 'org.rocksdb.RocksDBException: While lock file: /x/rocks/v276/LOCK: Resource temporarily unavailable',
  client._last_severe(severe_log))
check('SEVERE with inline text falls back to that text',
  client._last_severe({ '2026-09-29 19:55:30,961 [ 870] SEVERE - #c.j.l.i.LspClient - License expired' }) == 'License expired',
  client._last_severe({ '2026-09-29 19:55:30,961 [ 870] SEVERE - #c.j.l.i.LspClient - License expired' }))
check('no SEVERE -> nil', client._last_severe({ 'INFO - fine', 'INFO - also fine' }) == nil)
check('server log path under the claimed directory',
  client.server_log_path('/c/slot') == '/c/slot/system/log/intellij-server.log')
check('eula.hash_for nil for dev bundle', eula.hash_for(BUNDLE) == nil)

-- eula hashing: 16 lowercase hex chars of sha256, matching the server's expectation
local tmp = vim.fs.normalize(vim.fn.tempname() .. '-released')
vim.fn.mkdir(tmp, 'p')
vim.fn.writefile({ 'LICENSE TEXT' }, tmp .. '/EULA.txt')
local h = eula.hash_for(tmp)
local expected = vim.fn.sha256(table.concat(vim.fn.readfile(tmp .. '/EULA.txt', 'b'), '\n')):lower():sub(1, 16)
check('hash is 16 chars', h and #h == 16, h)
check('hash is lowercase hex', h and h:match('^[0-9a-f]+$') ~= nil, h)
check('hash matches sha256 prefix', h == expected, tostring(h) .. ' vs ' .. tostring(expected))

local cmd2 = launch.build_cmd({ server_path = tmp .. '/bin/intellij-server', root_dir = '/tmp/ijtest', accept_eula = true })
check('released bundle -> --eula passed', vim.tbl_contains(cmd2, '--eula'), table.concat(cmd2, ' '))
local cmd3 = launch.build_cmd({ server_path = tmp .. '/bin/intellij-server', root_dir = '/tmp/ijtest', accept_eula = false })
check('accept_eula=false -> no --eula', not vim.tbl_contains(cmd3, '--eula'))

-- env hygiene: the three trap variables
vim.env.IJ_LAUNCHER_DEBUG = '1'
vim.env.INTELLIJ_DATA_SHARING = 'full'
vim.env.INTELLIJ_REGION = 'europe'
local env = launch.build_env({ '-Xmx4g', '-Dfoo=a b' })
-- Absent, not false: vim.system stringifies false to "false", which the server rejects.
check('IJ_LAUNCHER_DEBUG absent', env.IJ_LAUNCHER_DEBUG == nil, tostring(env.IJ_LAUNCHER_DEBUG))
check('INTELLIJ_DATA_SHARING absent', env.INTELLIJ_DATA_SHARING == nil, tostring(env.INTELLIJ_DATA_SHARING))
check('INTELLIJ_REGION absent', env.INTELLIJ_REGION == nil, tostring(env.INTELLIJ_REGION))
check('env carries inherited vars (PATH)', env.PATH ~= nil)
check('no value is a boolean', (function()
  for _, v in pairs(env) do if type(v) ~= 'string' then return false end end
  return true
end)())
check('jvm args -> IJ_JAVA_OPTIONS', env.IJ_JAVA_OPTIONS and env.IJ_JAVA_OPTIONS:find('-Xmx4g', 1, true) ~= nil, env.IJ_JAVA_OPTIONS)
check('jvm arg with space quoted', env.IJ_JAVA_OPTIONS:find('"-Dfoo=a b"', 1, true) ~= nil, env.IJ_JAVA_OPTIONS)
check('no jvm args -> unset', launch.build_env(nil).IJ_JAVA_OPTIONS == nil)

-- the load-bearing capability
local caps = client.capabilities()
check('window.workDoneProgress = true', caps.window.workDoneProgress == true)

-- init_options shape
local io_ = client.init_options('/tmp/ijtest', { build_tool = nil, projects = {} })
local uri = vim.uri_from_fname('/tmp/ijtest')
check('buildTools keyed by folder uri', next(io_.buildTools) == uri, vim.inspect(io_.buildTools))
check('nil build_tool -> vim.NIL (serializes as null)', io_.buildTools[uri] == vim.NIL, vim.inspect(io_.buildTools))
check('buildTools encodes as object with null', vim.json.encode(io_.buildTools):find('null', 1, true) ~= nil, vim.json.encode(io_.buildTools))
check('projects defaults to {}', type(io_.projects) == 'table')
-- Opted in, because extensions.lua answers both notifications it promises. Without the flag the
-- server maps ModCopyToClipboard/ModChooseAction to null and drops the whole enclosing quick fix.
check('intellijExtensions opted in', io_.intellijExtensions == true)
check('intellijExtensions can be declined', client.init_options('/tmp/ijtest', { intellij_extensions = false }).intellijExtensions == false)
-- Asked for only when the client can actually honour the lens: its command is dispatched client-side
-- into a DAP session, so without nvim-dap installed a lens would render and then fail on click, which
-- is worse than no lens. This suite runs under `-u NONE`, so nvim-dap is absent and the flag is false
-- -- which is exactly the degraded path worth pinning. `run = false` must decline it too, regardless.
check('runMainCodeLens declined without nvim-dap', io_.runMainCodeLens == false, tostring(io_.runMainCodeLens))
check('runMainCodeLens declined by run = false',
  client.init_options('/tmp/ijtest', { run = false }).runMainCodeLens == false)
local io2 = client.init_options('/tmp/ijtest', { build_tool = 'maven' })
check('build_tool forwarded', io2.buildTools[uri] == 'maven')

-- root detection
vim.fn.mkdir('/tmp/ijtest/src/main/java/com/example', 'p')
io.open('/tmp/ijtest/pom.xml', 'w'):close()
local root = vim.fs.dirname(vim.fs.find({ 'pom.xml' }, { path = '/tmp/ijtest/src/main/java/com/example', upward = true })[1] or '')
check('root markers find pom.xml', root == '/tmp/ijtest', root)

-- ---------------------------------------------------------------------------
-- Eager activation from build files
-- ---------------------------------------------------------------------------
-- A build file at or above cwd starts the server on a project opened with no source file open.
-- Real directories throughout, because the one-level rule is a filesystem property.

--- Builds a temp tree; keys are relative paths, all created as files.
local function fixture(tree)
  local dir = vim.fn.tempname() .. '-eager'
  vim.fn.mkdir(dir, 'p')
  for _, path in ipairs(tree) do
    vim.fn.mkdir(dir .. '/' .. vim.fs.dirname(path), 'p')
    vim.fn.writefile({ 'x' }, dir .. '/' .. path)
  end
  -- fs_realpath: on macOS /tmp is a symlink to /private/tmp, and find_build_root normalizes without
  -- resolving, so the expected value has to be the resolved one too. Same trap as the e2e suites.
  return vim.fs.normalize(vim.uv.fs_realpath(dir))
end

-- `.git` is in ROOT_MARKERS but must NOT be an activation trigger: any checkout of any language would
-- otherwise start a multi-minute IntelliJ import with nothing to index.
check('.git is not a build-file marker',
  not vim.tbl_contains(client.BUILD_FILE_MARKERS, '.git'), vim.inspect(client.BUILD_FILE_MARKERS))
check('.git is still a per-buffer root marker', vim.tbl_contains(client.ROOT_MARKERS, '.git'))

-- Exactly these seven. `BUILD`/`WORKSPACE`/`.bazelproject` are excluded on purpose.
check('seven build markers', #client.BUILD_FILE_MARKERS == 7,
  vim.inspect(client.BUILD_FILE_MARKERS))
for _, m in ipairs({ 'pom.xml', 'build.gradle', 'build.gradle.kts', 'settings.gradle',
                     'settings.gradle.kts', 'BUILD.bazel', 'MODULE.bazel' }) do
  check('build marker ' .. m, vim.tbl_contains(client.BUILD_FILE_MARKERS, m))
end
check('BUILD is not an activation marker', not vim.tbl_contains(client.BUILD_FILE_MARKERS, 'BUILD'))
check('WORKSPACE is not an activation marker',
  not vim.tbl_contains(client.BUILD_FILE_MARKERS, 'WORKSPACE'))

local in_cwd = fixture({ 'pom.xml' })
check('marker in cwd starts on cwd', client.find_build_root(in_cwd) == in_cwd,
  tostring(client.find_build_root(in_cwd)))

-- Below cwd must NOT match, at any depth. An earlier version matched `*/<name>` one level down, so
-- `nvim` in `~/Code`, a parent of many checkouts, imported all of them as one project rooted at
-- `~/Code`. Upward-only is the fix; this guards against it coming back.
local one_deep = fixture({ 'app/pom.xml' })
check('marker one level down does not activate', client.find_build_root(one_deep) == nil,
  tostring(client.find_build_root(one_deep)))
local two_deep = fixture({ 'a/b/pom.xml' })
check('marker two levels down does not activate', client.find_build_root(two_deep) == nil,
  tostring(client.find_build_root(two_deep)))

-- Upward walk: nvim opened inside a source directory still roots on the project.
local up = fixture({ 'pom.xml', 'src/main/java/.keep' })
check('upward walk from a source dir finds the project',
  client.find_build_root(up .. '/src/main/java') == up,
  tostring(client.find_build_root(up .. '/src/main/java')))

-- In `mono/app` with a reactor pom above and a module pom below, the reactor is the right root; a
-- downward rule would have answered `mono/app` and imported a fragment of the build.
local mono = fixture({ 'pom.xml', 'app/sub/pom.xml' })
check('upward walk finds the reactor above a module directory',
  client.find_build_root(mono .. '/app') == mono, tostring(client.find_build_root(mono .. '/app')))

-- Gradle and Bazel reach the same paths, so cover one of each rather than only Maven.
local gradle = fixture({ 'settings.gradle.kts' })
check('gradle settings activate', client.find_build_root(gradle) == gradle)
local bazel = fixture({ 'MODULE.bazel' })
check('bazel module activates', client.find_build_root(bazel) == bazel)

local git_only = fixture({ '.git/HEAD' })
check('.git alone does not activate', client.find_build_root(git_only) == nil,
  tostring(client.find_build_root(git_only)))
-- ...but the per-buffer path still falls back to it, which is why the two lists are separate.
check('.git still resolves a per-buffer root',
  vim.fs.dirname(vim.fs.find(client.ROOT_MARKERS, { path = git_only, upward = true })[1] or '')
    == git_only)

-- An empty directory is the common case for `nvim` in a scratch dir; must be cheap and silent.
check('no marker anywhere does not activate', client.find_build_root(fixture({})) == nil)
check('an unrelated file does not activate',
  client.find_build_root(fixture({ 'README.md', 'sub/Cargo.toml' })) == nil)

-- ---------------------------------------------------------------------------
-- A module widens to the build that aggregates it
-- ---------------------------------------------------------------------------
-- Regression: rooted at its nearest pom.xml, a module of antonarhipov/school-kernel was imported on
-- its own, could not resolve its sibling SNAPSHOT module, and so had no classpath at all.
local function pom(dir, path, body)
  vim.fn.writefile({ '<project>', body, '</project>' }, dir .. '/' .. path)
end

local reactor = fixture({ 'pom.xml', 'kernel-cli/pom.xml', 'kernel-cli/src/main/java/A.java',
  'examples/demo/pom.xml', 'appstore/pom.xml' })
pom(reactor, 'pom.xml', '<modules><module>kernel-contract</module><module>kernel-cli</module>'
  .. '<module>app</module></modules>')
check('a listed maven module widens to its reactor',
  client.build_root(reactor .. '/kernel-cli') == reactor, client.build_root(reactor .. '/kernel-cli'))
check('find_build_root widens from inside a module',
  client.find_build_root(reactor .. '/kernel-cli/src/main/java') == reactor)
local reactor_buf = vim.fn.bufadd(reactor .. '/kernel-cli/src/main/java/A.java')
check('find_root widens a module file to its reactor', client.find_root(reactor_buf) == reactor,
  tostring(client.find_root(reactor_buf)))
check('a pom nothing lists stays its own project',
  client.build_root(reactor .. '/examples/demo') == reactor .. '/examples/demo')
check('a module name is not a prefix match',
  client.build_root(reactor .. '/appstore') == reactor .. '/appstore')
check('the reactor itself stays put', client.build_root(reactor) == reactor)

local chain = fixture({ 'pom.xml', 'a/pom.xml', 'a/b/pom.xml' })
pom(chain, 'pom.xml', '<modules><module>a</module></modules>')
pom(chain, 'a/pom.xml', '<modules><module>b</module></modules>')
check('nested aggregators widen to the outermost', client.build_root(chain .. '/a/b') == chain)

local deep = fixture({ 'pom.xml', 'services/api/pom.xml' })
pom(deep, 'pom.xml', '<modules>\n  <module>./services/api/</module>\n</modules>')
check('a module path through a pom-less directory widens',
  client.build_root(deep .. '/services/api') == deep)

local by_file = fixture({ 'pom.xml', 'app/pom.xml' })
pom(by_file, 'pom.xml', '<modules><module>app/pom.xml</module></modules>')
check('a module named by its pom file widens', client.build_root(by_file .. '/app') == by_file)

local maven4 = fixture({ 'pom.xml', 'app/pom.xml' })
pom(maven4, 'pom.xml', '<subprojects><subproject>app</subproject></subprojects>')
check('a maven 4 subproject widens', client.build_root(maven4 .. '/app') == maven4)

local commented = fixture({ 'pom.xml', 'app/pom.xml' })
pom(commented, 'pom.xml', '<modules><!-- <module>app</module> --></modules>')
check('a commented-out module does not widen',
  client.build_root(commented .. '/app') == commented .. '/app')

local gradle_multi = fixture({ 'settings.gradle.kts', 'build.gradle.kts', 'app/build.gradle.kts' })
check('a gradle subproject widens to its settings file',
  client.build_root(gradle_multi .. '/app') == gradle_multi)
local gradle_single = fixture({ 'build.gradle' })
check('a gradle build with no settings stays put',
  client.build_root(gradle_single) == gradle_single)
local gradle_included = fixture({ 'settings.gradle', 'tools/settings.gradle', 'tools/build.gradle' })
check('the nearest gradle settings wins',
  client.build_root(gradle_included .. '/tools') == gradle_included .. '/tools')

-- ---------------------------------------------------------------------------
-- Shared directories decline the eager start
-- ---------------------------------------------------------------------------
-- A stray build file dropped directly into a shared directory would make that directory the root and
-- import everything under it as one project. start_eagerly declines these by name, resolved through
-- fs_realpath because /tmp is a symlink to /private/tmp on macOS and comparing unresolved paths lets
-- `cd /tmp` slip past.
local eager_skips = require('intellij-lsp')._is_shared_dir

check('/ is skipped', eager_skips('/'))
check('$HOME is skipped', eager_skips(vim.uv.os_homedir()))
check('the system temp dir is skipped', eager_skips(vim.uv.os_tmpdir()))
check('a real project directory is not skipped', not eager_skips(in_cwd), in_cwd)

-- The symlink case, fed the way the guard really sees it. `vim.uv.cwd()` reports the *resolved* path,
-- so after `cd /tmp` on macOS the guard is handed /private/tmp -- which the unresolved skip list does
-- not contain. Passing the literal '/tmp' here would pass without any realpath handling at all and
-- prove nothing, so resolve both shared dirs and check the resolved form is recognised.
for _, shared in ipairs({ '/tmp', vim.uv.os_tmpdir() }) do
  local resolved = vim.uv.fs_realpath(shared)
  if resolved then
    check('a resolved shared dir is skipped: ' .. resolved, eager_skips(resolved), resolved)
  end
end

-- ---------------------------------------------------------------------------
-- An eagerly started client is reused by a later buffer
-- ---------------------------------------------------------------------------
-- Regression: Neovim's own reuse check compares workspace folder URIs for string equality
-- (`reuse_client_default`), so a client eagerly started at cwd is NOT reused by a buffer whose
-- find_root walked up only as far as cwd/app -- vim.lsp.start would start a second server and import
-- and index the same project twice.
check('contains matches the dir itself', client._contains('/work/app', '/work/app'))
check('contains matches a descendant', client._contains('/work', '/work/app/src/Foo.java'))
-- A plain startswith would call /work/app an ancestor of /work/appstore.
check('contains rejects a sibling with a shared prefix',
  not client._contains('/work/app', '/work/appstore/Foo.java'))
check('contains rejects an unrelated path', not client._contains('/work', '/other/Foo.java'))
check('contains tolerates a trailing slash', client._contains('/work/', '/work/Foo.java'))

local eager_root = fixture({ 'pom.xml', 'app/pom.xml', 'app/src/main/java/com/example/Main.java' })
local MODULE_FILE = eager_root .. '/app/src/main/java/com/example/Main.java'

--- Answers just enough of the protocol to reach `initialized`.
local function stub_server(dispatch)
  return {
    request = function(method, _, callback)
      if method == 'initialize' then
        -- Deferred like a real server's reply, so the client is observably uninitialized first.
        vim.schedule(function() callback(nil, { capabilities = {} }) end)
      elseif method == 'shutdown' then
        callback(nil, nil)
      end
      return true, 1
    end,
    notify = function(method)
      if method == 'exit' then dispatch.on_exit(0, 0) end
      return true
    end,
    is_closing = function() return false end,
    terminate = function() end,
  }
end

-- The eager start: no buffer, so `attach = false`. Named after the real client so that
-- find_ancestor_client, which filters on client.NAME, sees it.
local eager_cfg = vim.tbl_extend('force', client.config(eager_root, {}), { cmd = stub_server })
local eager_id = vim.lsp.start(eager_cfg, { attach = false })
check('eager start needs no buffer', eager_id ~= nil, tostring(eager_id))
local eager_client = eager_id and vim.lsp.get_client_by_id(eager_id)
-- A file opened while the real server is still starting (seconds of JVM start) must find it too,
-- or it starts a second server on its module root.
check('the eager client starts uninitialized', eager_client and not eager_client.initialized)
local early = client.find_ancestor_client(MODULE_FILE)
check('an ancestor client is found before it has initialized',
  early ~= nil and early.id == eager_id, early and early.id)
vim.wait(2000, function() return eager_client and eager_client.initialized end)

if not (eager_client and eager_client.initialized) then
  check('eager client starts', false, 'client did not initialize')
else
  -- `attach = false` really means no buffer was touched; attaching to the unnamed startup buffer would
  -- have Neovim send didOpen for a document that does not exist.
  check('attach=false attaches no buffer', next(eager_client.attached_buffers) == nil,
    vim.inspect(vim.tbl_keys(eager_client.attached_buffers)))

  -- The multi-module trap: the buffer's own upward walk stops at the nearer `app/pom.xml`.
  local module_buf = vim.fn.bufadd(MODULE_FILE)
  vim.fn.bufload(module_buf)
  local buf_root = client.find_root(module_buf)
  check('the buffer resolves a narrower root than the eager one',
    buf_root == eager_root .. '/app', tostring(buf_root))
  -- Which is exactly why Neovim would not reuse the eager client. The URI inequality *is* the
  -- mechanism, so assert on it rather than starting a second client to demonstrate it.
  check('the two roots produce different workspace folder URIs',
    vim.uri_from_fname(eager_root) ~= vim.uri_from_fname(buf_root))

  -- The fix: the ancestor lookup finds the eager client for that file anyway.
  local found = client.find_ancestor_client(MODULE_FILE)
  check('an ancestor client is found for a module file',
    found ~= nil and found.id == eager_client.id, found and found.id)
  check('a file outside the root finds nothing',
    client.find_ancestor_client('/definitely/elsewhere/Foo.java') == nil)
  check('an empty path finds nothing', client.find_ancestor_client('') == nil)

  vim.lsp.stop_client(eager_id, true)
end

-- ---------------------------------------------------------------------------
-- Completion menu options
-- ---------------------------------------------------------------------------
-- Regression: on `import java.ut` the server sends filterText="java.util" (the FQ name, because the
-- item's edit starts before the prefix) while Neovim derives the prefix `ut` with `\k*$`. Without
-- 'fuzzy' the default startswith matcher drops the item and the menu comes up empty.
local function completeopt_after(cfg, initial)
  vim.opt.completeopt = initial or { 'menu', 'popup' }
  client.setup_completeopt(cfg)
  return vim.opt.completeopt:get()
end

local opts = completeopt_after({})
check('completeopt gains fuzzy', vim.tbl_contains(opts, 'fuzzy'), table.concat(opts, ','))
check('completeopt gains menuone', vim.tbl_contains(opts, 'menuone'), table.concat(opts, ','))
check('completeopt keeps existing flags', vim.tbl_contains(opts, 'popup'), table.concat(opts, ','))
-- Without 'noinsert' the menu writes the current entry into the buffer while you type, turning
-- `java.` + `u` into `java.timeu`.
check('completeopt gains noinsert', vim.tbl_contains(opts, 'noinsert'), table.concat(opts, ','))

-- Escape hatches: false keeps the user's value, an explicit value replaces it.
local untouched = completeopt_after({ completeopt = false }, { 'menu', 'noselect' })
check('completeopt=false is left alone', vim.deep_equal(untouched, { 'menu', 'noselect' }), table.concat(untouched, ','))
local explicit = completeopt_after({ completeopt = { 'menu', 'noinsert' } })
check('explicit completeopt replaces', vim.deep_equal(explicit, { 'menu', 'noinsert' }), table.concat(explicit, ','))

-- The filtering behaviour the 'fuzzy' flag is there to buy, pinned against Neovim's own matcher.
local function kept(value, prefix, fuzzy)
  if prefix == '' then return true end
  if fuzzy then return #(vim.fn.matchfuzzypos({ value }, prefix)[3] or {}) > 0 end
  return vim.startswith(value:lower(), prefix:lower())
end
check('prefix is "ut", not "java.ut"', vim.fn.match('import java.ut', '\\k*$') == 12)
check('startswith drops java.util', not kept('java.util', 'ut', false))
check('fuzzy keeps java.util', kept('java.util', 'ut', true))

-- ---------------------------------------------------------------------------
-- <CR> accepts the selected completion
-- ---------------------------------------------------------------------------
-- Regression: Vim reserves <C-y> for accepting and treats Enter as an ordinary character, so <CR>
-- ends completion and inserts a newline. This is NOT a 'noselect' problem -- the default
-- 'completeopt' is "menu,popup", which has no 'noselect' in it, and Neovim still preselects nothing.
-- Only a mapping fixes it, so this drives a real popup rather than asserting on options.
--
-- One feedkeys batch per case: flushing between keys closes the popup.
_G._units_omni = function(findstart, _)
  if findstart == 1 then
    -- Start of the dotted expression, mirroring the range the server's textEdit replaces.
    return vim.fn.match(vim.fn.getline('.'):sub(1, vim.fn.col('.') - 1), '[[:alnum:].]*$')
  end
  return { 'java.util', 'javax.annotation' }
end

local pum = {}
_G._units_probe = function()
  pum.visible = vim.fn.pumvisible()
  return ''
end

local function type_into_buffer(keys)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_current_buf(buf)
  vim.bo[buf].omnifunc = 'v:lua._units_omni'
  client.setup_enter_mapping(buf)
  vim.api.nvim_feedkeys(vim.keycode(keys), 'tx', false)
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  vim.api.nvim_buf_delete(buf, { force = true })
  return lines
end

local accepted = type_into_buffer('iimport java.ut<C-x><C-o><C-r>=v:lua._units_probe()<CR><CR><Esc>')
check('dotted prefix opens the menu', pum.visible == 1, pum.visible)
check('<CR> accepts instead of inserting a newline', #accepted == 1, vim.inspect(accepted))
check('<CR> inserts the completion text', accepted[1] == 'import java.util', vim.inspect(accepted[1]))

local newline = type_into_buffer('ifoo<CR>bar<Esc>')
check('<CR> still opens a line with no menu', vim.deep_equal(newline, { 'foo', 'bar' }), vim.inspect(newline))

-- ---------------------------------------------------------------------------
-- Completion keeps up while a word is typed
-- ---------------------------------------------------------------------------
-- Regression: the server advertises '.' as its only trigger character, and Neovim's `autotrigger`
-- requests completion ONLY on trigger characters. So `java.` opened a menu, the next keystroke
-- closed it, and nothing reopened it -- and a bare identifier never completed at all. This runs
-- against a real in-process LSP server, because the bug is in when requests are sent.
local requests, cancels = {}, 0
-- How long the faux server takes to answer a completion request; 0 answers inline.
local faux_latency = 0

--- Minimal server: one trigger character, FQ filterText, edits anchored at the start of the
--- dotted expression -- the shape `LSJavaCompletionProvider` produces. Distinct request ids and the
--- reply notification matter: that is what `client.requests` tracks, and the word trigger reads it.
local function faux_server(dispatch)
  local next_id = 0
  return {
    request = function(method, _, callback, notify_reply)
      next_id = next_id + 1
      local id = next_id
      local function reply(result)
        if notify_reply then notify_reply(id) end
        callback(nil, result, id)
      end
      if method == 'initialize' then
        reply({ capabilities = { completionProvider = { triggerCharacters = { '.' } } } })
      elseif method == 'textDocument/completion' then
        local line = vim.api.nvim_get_current_line()
        requests[#requests + 1] = line
        local from = vim.fn.match(line, '[[:alnum:].]*$')
        local range = { start = { line = 0, character = from }, ['end'] = { line = 0, character = #line } }
        local result = {
          isIncomplete = true,
          items = {
            { label = 'util', filterText = 'java.util', textEdit = { range = range, newText = 'java.util' } },
            { label = 'time', filterText = 'java.time', textEdit = { range = range, newText = 'java.time' } },
          },
        }
        if faux_latency > 0 then
          vim.defer_fn(function() reply(result) end, faux_latency)
        else
          reply(result)
        end
      elseif method == 'shutdown' then
        reply(nil)
      end
      return true, id
    end,
    notify = function(method)
      if method == '$/cancelRequest' then cancels = cancels + 1 end
      if method == 'exit' then dispatch.on_exit(0, 0) end
      return true
    end,
    is_closing = function() return false end,
    terminate = function() end,
  }
end

local lsp_buf = vim.api.nvim_create_buf(false, true)
vim.api.nvim_set_current_buf(lsp_buf)
vim.bo[lsp_buf].filetype = 'java'
local client_id = vim.lsp.start({ name = 'faux-intellij', cmd = faux_server, root_dir = '/tmp' }, { bufnr = lsp_buf })
local lsp_client = client_id and vim.lsp.get_client_by_id(client_id)
vim.wait(2000, function() return lsp_client and lsp_client.initialized end)

if not (lsp_client and lsp_client.initialized) then
  check('faux LSP client starts', false, 'client did not initialize')
else
  client.setup_completeopt({})
  vim.lsp.completion.enable(true, client_id, lsp_buf, { autotrigger = true })

  -- Baseline: the server's own trigger set means letters send nothing.
  requests = {}
  vim.api.nvim_feedkeys(vim.keycode('ifoo<Esc>'), 'tx', false)
  vim.wait(200)
  check('letters alone send no request', #requests == 0, vim.inspect(requests))

  client.setup_word_triggers(lsp_client, lsp_buf, { completion_delay = 20 })
  -- The built-in never re-reads this set for a client it already knows, and a later buffer would
  -- turn every letter into a second, undebounced request path. So it is left as the server sent it.
  local triggers = lsp_client.server_capabilities.completionProvider.triggerCharacters
  check("server's trigger set is left alone", vim.deep_equal(triggers, { '.' }), vim.inspect(triggers))

  -- `<C-r>=` pumps the debounce timer without leaving insert mode; `feedkeys` with 'x' would drop
  -- to normal mode first, and the callback deliberately bails outside insert.
  local pum_after_word
  _G._units_pump = function()
    vim.wait(250)
    pum_after_word = vim.fn.pumvisible()
    return ''
  end

  requests = {}
  vim.api.nvim_feedkeys(vim.keycode(
    'ccimport java.<C-r>=v:lua._units_pump()<CR>u<C-r>=v:lua._units_pump()<CR>' ..
    't<C-r>=v:lua._units_pump()<CR><CR><Esc>'), 'tx', false)

  check('typing after the dot keeps requesting', #requests >= 3, vim.inspect(requests))
  check('menu is still open after "ut"', pum_after_word == 1, pum_after_word)
  local final = vim.api.nvim_buf_get_lines(lsp_buf, 0, -1, false)
  check('the dotted candidate can be accepted', final[1] == 'import java.util', vim.inspect(final))

  -- Bare identifier, no dot anywhere: the in-scope-variable case.
  requests = {}
  vim.api.nvim_feedkeys(vim.keycode('ccbar<C-r>=v:lua._units_pump()<CR><Esc>'), 'tx', false)
  check('a bare identifier requests completion', #requests > 0, vim.inspect(requests))

  -- Regression: a server slower than the typing. `vim.lsp.completion.get` cancels whatever is in
  -- flight, so a debounce firing between keystrokes restarted the request on every letter and the
  -- menu could not appear until typing stopped. The in-flight request has to be left alone, and
  -- one fresh request has to follow once its reply is in.
  faux_latency = 150
  requests, cancels = {}, 0
  local pum_on_stale_reply
  _G._units_pump_short = function()
    vim.wait(40) -- past the 20 ms debounce, well inside the 150 ms reply
    return ''
  end
  _G._units_pump_long = function()
    -- The `.` reply lands first, with the whole word already typed.
    vim.wait(400, function() return vim.fn.pumvisible() ~= 0 end, 10)
    pum_on_stale_reply = vim.fn.pumvisible()
    -- Then let the catch-up request be answered before <Esc>, whose InsertLeave cancels whatever is
    -- still pending and would count as a cancel here.
    vim.wait(400, function() return #requests >= 2 end, 10)
    vim.wait(faux_latency + 100)
    return ''
  end
  vim.api.nvim_feedkeys(vim.keycode(
    'ccimport java.<C-r>=v:lua._units_pump_short()<CR>u<C-r>=v:lua._units_pump_short()<CR>' ..
    't<C-r>=v:lua._units_pump_short()<CR>i<C-r>=v:lua._units_pump_long()<CR><Esc>'), 'tx', false)
  check('a slow in-flight request is not cancelled by further typing', cancels == 0, cancels)
  -- One for the `.`, left to land while `uti` is typed; then exactly one catch-up for `uti`.
  check('one catch-up request after the stale reply, not one per letter',
    #requests == 2 and requests[2] == 'import java.uti', vim.inspect(requests))
  check('menu opens from the stale reply, before the catch-up answers', pum_on_stale_reply == 1, pum_on_stale_reply)
  faux_latency = 0

  vim.lsp.stop_client(client_id, true)
end

-- ---------------------------------------------------------------------------
-- gq / range formatting
-- ---------------------------------------------------------------------------
-- `gq` once did nothing: early bundles registered a `textDocument/rangeFormatting` handler without
-- advertising `documentRangeFormattingProvider`, and Neovim gates 'formatexpr' on exactly that
-- flag, so the plugin patched the capability in on_init. Bundle 263.4702.0 advertises it (the Java
-- e2e test checks), so the patch is gone and this pins the plain path: the advertised capability
-- alone installs formatexpr, and an absent one is left absent.
local fmt_buf = vim.api.nvim_create_buf(false, true)
vim.api.nvim_set_current_buf(fmt_buf)
vim.bo[fmt_buf].filetype = 'java'

local function formatting_server(dispatch)
  return {
    request = function(method, _, callback)
      if method == 'initialize' then
        callback(nil, { capabilities = { documentFormattingProvider = true, documentRangeFormattingProvider = true } })
      elseif method == 'shutdown' then
        callback(nil, nil)
      end
      return true, 1
    end,
    notify = function(method)
      if method == 'exit' then dispatch.on_exit(0, 0) end
      return true
    end,
    is_closing = function() return false end,
    terminate = function() end,
  }
end

local fmt_cfg = client.config('/tmp/ijtest', {})
local fmt_id = vim.lsp.start(
  vim.tbl_extend('force', fmt_cfg, { name = 'faux-intellij-fmt', cmd = formatting_server, root_dir = '/tmp' }),
  { bufnr = fmt_buf }
)
local fmt_client = fmt_id and vim.lsp.get_client_by_id(fmt_id)
vim.wait(2000, function() return fmt_client and fmt_client.initialized end)

if not (fmt_client and fmt_client.initialized) then
  check('formatting client starts', false, 'client did not initialize')
else
  check('rangeFormatting is supported as advertised', fmt_client:supports_method('textDocument/rangeFormatting'))
  -- The payoff: _set_defaults reads that capability on attach and installs formatexpr, which is
  -- what makes `gq` reformat a selection.
  check('formatexpr is installed', vim.bo[fmt_buf].formatexpr == 'v:lua.vim.lsp.formatexpr()', vim.bo[fmt_buf].formatexpr)
  vim.lsp.stop_client(fmt_id, true)
end

-- No patching any more: a server without the capability keeps it absent. `stub_server` above
-- advertises nothing, and `eager_client` came from it.
if eager_client and eager_client.initialized then
  check('an unadvertised rangeFormatting is not patched in',
    eager_client.server_capabilities.documentRangeFormattingProvider == nil)
end

-- ---------------------------------------------------------------------------
-- Inlay hint settings
-- ---------------------------------------------------------------------------
-- Regression: hints rendered nothing because the server asks for its own configuration section over
-- `workspace/configuration` before emitting any, and Neovim answers from `client.settings`, which
-- was empty. Java gates all four of its providers on that answer (so: no hints at all), Kotlin gates
-- only two (so: partial hints), which is why this presented as flakiness rather than as "off".
local settings = client.settings({})

-- The shape is pinned against Neovim's own resolution, not just eyeballed: `lookup_section` splits
-- the requested section on '.' and walks the table, then the server re-joins everything below it.
-- Hoisting the ids up to ['jetbrains.java.hints...'] would resolve to nil here.
local function section(tbl, name)
  return vim.tbl_get(tbl, unpack(vim.split(name, '.', { plain = true })))
end

local java = section(settings, 'jetbrains.java')
local kotlin = section(settings, 'jetbrains.kotlin')
check('jetbrains.java resolves the way lookup_section resolves it', type(java) == 'table', vim.inspect(java))
check('jetbrains.kotlin resolves', type(kotlin) == 'table', vim.inspect(kotlin))
check('java local variable hints on', java and java['hints.types.local variable'] == true)
check('java method parameter hints on', java and java['hints.settings.method parameter'] == true)
-- Gated separately on the Kotlin side; call chains are the one Kotlin hint off by default.
check('kotlin parameter hints on', kotlin and kotlin['hints.parameters'] == true)
check('kotlin call chains off', kotlin and kotlin['hints.call.chains'] == false)

-- Overrides merge rather than replace: switching one hint off must not drop the rest of the table.
local merged = client.settings({ inlay_hint_settings = { jetbrains = { java = { ['hints.types.call chain'] = false } } } })
local merged_java = section(merged, 'jetbrains.java')
check('override applies', merged_java['hints.types.call chain'] == false)
check('override keeps sibling keys', merged_java['hints.types.local variable'] == true, vim.inspect(merged_java))
check('override keeps the other language', section(merged, 'jetbrains.kotlin')['hints.parameters'] == true)
check('defaults are not mutated by an override', section(client.settings({}), 'jetbrains.java')['hints.types.call chain'] == true)

-- ---------------------------------------------------------------------------
-- Folding
-- ---------------------------------------------------------------------------
--- Returns the window options as `setup_folding` left them, starting from a window that looks the
--- way an unconfigured one does. 'foldlevel' starts at 0 because that is the value a window really
--- carries when `on_attach` runs: 'foldlevelstart' has already been consulted by then.
local function folding_after(cfg)
  local win = vim.api.nvim_get_current_win()
  vim.wo[win][0].foldmethod = 'manual'
  vim.wo[win][0].foldexpr = ''
  vim.wo[win][0].foldlevel = 0
  client.setup_folding(cfg)
  return {
    foldmethod = vim.wo[win][0].foldmethod,
    foldexpr = vim.wo[win][0].foldexpr,
    foldlevel = vim.wo[win][0].foldlevel,
  }
end

local folds = folding_after({})
check('foldmethod becomes expr', folds.foldmethod == 'expr', folds.foldmethod)
check('foldexpr uses vim.lsp.foldexpr', folds.foldexpr == 'v:lua.vim.lsp.foldexpr()', folds.foldexpr)
-- Without a start level every file would open fully collapsed, which reads as a broken plugin.
check('foldlevelstart is raised', vim.o.foldlevelstart >= 99, vim.o.foldlevelstart)
-- Regression: 'foldlevelstart' seeds 'foldlevel' only when a window starts editing a buffer, which
-- has already happened by the time on_attach runs. Setting the global alone left the *first* file of
-- a session fully collapsed while later ones opened fine, which presented as random folding.
check('foldlevel unfolds the attached window', folds.foldlevel >= 99, folds.foldlevel)
local off = folding_after({ folding = false })
check('folding=false is left alone', off.foldmethod == 'manual', off.foldmethod)
check('folding=false leaves foldlevel alone', off.foldlevel == 0, off.foldlevel)

-- ---------------------------------------------------------------------------
-- jar:/jrt: decompilation
-- ---------------------------------------------------------------------------
local decompiler = require('intellij-lsp.decompiler')
check('jar: is decompilable', decompiler._is_decompilable('jar:file:///a/lib.jar!/com/Foo.class'))
check('jrt: is decompilable', decompiler._is_decompilable('jrt:/java.base/java/lang/String.class'))
check('file: is not', not decompiler._is_decompilable('file:///a/Foo.java'))
-- The server only accepts these two schemes, so anything else must not reach it.
check('https: is not', not decompiler._is_decompilable('https://example.com/Foo.java'))

-- Regression: Neovim leaves `jrt:/...` alone but treats `jar:file://...` as a relative path and
-- prefixes it with the cwd. Sending that prefixed string back would fail the server's scheme check,
-- so it has to be stripped -- the same phantom-path trap references.lua hits from the quickfix side.
check('cwd-prefixed jar: is recovered',
  decompiler._uri_from_bufname('/some/where/jar:file:///a/lib.jar!/com/Foo.class')
    == 'jar:file:///a/lib.jar!/com/Foo.class')
check('bare jar: is left alone',
  decompiler._uri_from_bufname('jar:file:///a/lib.jar!/com/Foo.class') == 'jar:file:///a/lib.jar!/com/Foo.class')
check('jrt: is left alone',
  decompiler._uri_from_bufname('jrt:/java.base/java/lang/String.class') == 'jrt:/java.base/java/lang/String.class')

-- The autocmd patterns are their own trap: Vim only matches a pattern containing ':' once it also
-- contains '/', so the obvious `jar:*` / `jrt:*` spellings silently never fire. Drive real buffers.
decompiler.setup()
for _, case in ipairs({
  { uri = 'jrt:/java.base/java/lang/String.class', name = 'jrt:' },
  { uri = 'jar:file:///tmp/lib.jar!/com/example/Foo.class', name = 'jar:' },
}) do
  vim.cmd('silent! edit ' .. vim.fn.fnameescape(case.uri))
  local first = (vim.api.nvim_buf_get_lines(0, 0, -1, false)[1] or '')
  -- No server is attached in this suite, so the handler's own fallback text is the proof it ran.
  check(case.name .. ' BufReadCmd fires', first:find('IntelliJ LSP', 1, true) ~= nil, first)
  check(case.name .. ' buffer is a scratch', vim.bo.buftype == 'nofile' and not vim.bo.modifiable)
end

-- Regression: `vim.lsp.buf.definition` sets the cursor to the location's line the moment
-- `nvim_win_set_buf` returns, and `locations_to_items` reads lines straight after bufloading a
-- non-file URI. Both presuppose the BufReadCmd filled the buffer before returning. A `String`
-- definition lands at line 173 of src.zip's String.java; against the two-line "decompiling..."
-- placeholder that was "Invalid cursor line: out of range". The fake server answers on a timer, the
-- way a real reply arrives, so this fails if the read goes back to being asynchronous.
do
  local source = {}
  for i = 1, 200 do source[i] = ('line %d'):format(i) end
  local fake_decompile_client = {
    name = 'intellij',
    request = function(_, method, params, handler)
      check('decompile goes through executeCommand', method == 'workspace/executeCommand', method)
      check('decompile names its command', params.command == 'decompile', params.command)
      vim.defer_fn(function()
        handler(nil, { code = table.concat(source, '\n'), language = 'java' })
      end, 20)
      return true, 1
    end,
  }
  local real_get_clients = vim.lsp.get_clients
  vim.lsp.get_clients = function(filter)
    if filter and filter.name == 'intellij' then return { fake_decompile_client } end
    return real_get_clients(filter)
  end

  vim.cmd('silent! edit ' .. vim.fn.fnameescape('jrt:/java.base/java/lang/Deep.class'))
  check('decompiled source is in the buffer when :edit returns',
    vim.api.nvim_buf_line_count(0) == 200, vim.api.nvim_buf_line_count(0))
  check('decompiled buffer gets the server language as filetype', vim.bo.filetype == 'java', vim.bo.filetype)
  local ok_cursor = pcall(vim.api.nvim_win_set_cursor, 0, { 173, 0 })
  check('the definition handler can place the cursor deep in the source', ok_cursor)

  vim.lsp.get_clients = real_get_clients
end

-- Regression: setting the filetype on a decompiled buffer runs the plugin's FileType attach. Rooting
-- a URI-named buffer walks up to the relative directory ".", so with a build file in the cwd a second
-- server was started on "." and failed `initialize` ("Expected scheme-specific part at index 5:
-- file:"). A library buffer attaches to the client that decompiled it and never starts one.
do
  local started, attached = 0, nil
  local real_start, real_attach, real_by_id = vim.lsp.start, vim.lsp.buf_attach_client, vim.lsp.get_client_by_id
  vim.lsp.start = function() started = started + 1 end
  vim.lsp.buf_attach_client = function(_, id) attached = id end
  vim.lsp.get_client_by_id = function(id) return id == 4242 and { id = 4242 } or real_by_id(id) end
  local old_cwd = vim.fn.getcwd()
  local proj = vim.fn.tempname()
  vim.fn.mkdir(proj, 'p')
  vim.fn.writefile({ '<project/>' }, proj .. '/pom.xml')
  vim.cmd('cd ' .. vim.fn.fnameescape(proj))

  local start_for_buffer = require('intellij-lsp')._start_for_buffer
  local lib = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_buf_set_name(lib, 'jar:///jdk/lib/src.zip!/java.base/java/lang/String.java')
  vim.b[lib].intellij_lsp_library_client = 4242
  start_for_buffer(lib)
  check('a library buffer attaches to the client that served it', attached == 4242, attached)

  local orphan = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_buf_set_name(orphan, 'jrt:/java.base/java/lang/Orphan.class')
  start_for_buffer(orphan)
  check('a library buffer never starts a server of its own', started == 0, started)

  vim.cmd('cd ' .. vim.fn.fnameescape(old_cwd))
  vim.lsp.start, vim.lsp.buf_attach_client, vim.lsp.get_client_by_id = real_start, real_attach, real_by_id
end

do -- scoped: Lua allows 200 locals per chunk
-- ---------------------------------------------------------------------------
-- intellij/ extension notifications
-- ---------------------------------------------------------------------------
local extensions = require('intellij-lsp.extensions')
local ext = extensions.handlers()
check('copyToClipboard handled', type(ext['intellij/copyToClipboard']) == 'function')
check('chooseAction handled', type(ext['intellij/chooseAction']) == 'function')
check('runEditorCommand handled', type(ext['intellij/runEditorCommand']) == 'function')
check('showConflicts handled', type(ext['intellij/showConflicts']) == 'function')

vim.fn.setreg('+', '')
ext['intellij/copyToClipboard'](nil, { content = 'copied text' }, { client_id = 1 })
check('clipboard receives the content', vim.fn.getreg('+') == 'copied text', vim.fn.getreg('+'))
-- A malformed payload must not raise inside an LSP handler.
local ok_copy = pcall(ext['intellij/copyToClipboard'], nil, {}, { client_id = 1 })
check('copyToClipboard tolerates a missing content', ok_copy)

-- A fake client that records what is executed, standing in for vim.lsp.get_client_by_id.
local executed = {}
local fake_ext_client = {
  id = 4711,
  offset_encoding = 'utf-16',
  config = { root_dir = '/tmp/ijtest' },
  exec_cmd = function(_, command, ctx) executed[#executed + 1] = { command = command, ctx = ctx } end,
}
local real_get_client = vim.lsp.get_client_by_id
vim.lsp.get_client_by_id = function(id)
  if id == 4711 then return fake_ext_client end
  return real_get_client(id)
end

-- Old shape (bundle 263.4702.0): entries carry an index, the pick goes back through the
-- chooseModCommandAction command with the session and that index, and a dismissal still answers,
-- because the server caches the session until it hears back.
local select_stub = vim.ui.select
local chosen
vim.ui.select = function(items, _, on_choice) chosen = items; on_choice(items[1]) end
local ok_choose = pcall(ext['intellij/chooseAction'], nil,
  { sessionId = 's1', entries = { { index = 7, name = 'First' }, { index = 9, name = 'Second' } } },
  { client_id = 4711 })
check('chooseAction presents the entries', ok_choose and chosen and #chosen == 2, vim.inspect(chosen))
-- The reply carries the entry's own `index`, not its position in the list -- 7, not 1.
check('entries carry the server-side index', chosen and chosen[1].index == 7, vim.inspect(chosen and chosen[1]))
check('old shape replies through chooseModCommandAction',
  executed[1] and executed[1].command.command == 'chooseModCommandAction'
  and executed[1].command.arguments[1] == 's1' and executed[1].command.arguments[2] == 7, vim.inspect(executed[1]))
executed = {}
vim.ui.select = function(items, _, on_choice) on_choice(nil) end
ext['intellij/chooseAction'](nil, { sessionId = 's2', entries = { { index = 1, name = 'Only' } } }, { client_id = 4711 })
check('old shape answers a dismissal with null',
  executed[1] and executed[1].command.arguments[1] == 's2' and executed[1].command.arguments[2] == vim.NIL, vim.inspect(executed[1]))

-- New shape (later server builds): entries carry a complete LSP Command, the pick is executed as
-- is, and a dismissal says nothing because there is no session to release.
executed = {}
local lazy = { title = 'Apply ModCommand', command = 'applyModCommand', arguments = { { kind = 'LazyAction', sessionId = 0, index = 0 } } }
local prompt_seen
vim.ui.select = function(items, opts, on_choice) prompt_seen = opts.prompt; on_choice(items[1]) end
ext['intellij/chooseAction'](nil, { title = "Replace 'catch' with 'throws'", entries = { { name = 'Add throws', command = lazy } } }, { client_id = 4711 })
check('new shape executes the entry command', executed[1] and executed[1].command == lazy, vim.inspect(executed[1]))
check('new shape uses the server title as the prompt', prompt_seen == "Replace 'catch' with 'throws'", prompt_seen)
executed = {}
vim.ui.select = function(items, _, on_choice) on_choice(nil) end
ext['intellij/chooseAction'](nil, { entries = { { name = 'Add throws', command = lazy } } }, { client_id = 4711 })
check('new shape sends nothing on dismissal', #executed == 0, vim.inspect(executed))
vim.ui.select = select_stub

-- runEditorCommand: rename only when the notification names the current buffer.
local renamed, sig_shown = 0, 0
local real_rename, real_sig = vim.lsp.buf.rename, vim.lsp.buf.signature_help
vim.lsp.buf.rename = function() renamed = renamed + 1 end
vim.lsp.buf.signature_help = function() sig_shown = sig_shown + 1 end
local cur_buf = vim.api.nvim_create_buf(true, false)
vim.api.nvim_buf_set_name(cur_buf, '/tmp/ijtest/src/main/java/com/example/Cur.java')
vim.api.nvim_set_current_buf(cur_buf)
local other_buf = vim.api.nvim_create_buf(true, false)
vim.api.nvim_buf_set_name(other_buf, '/tmp/ijtest/src/main/java/com/example/Other.java')

check('rename runs for the current buffer', extensions.run_editor_command('editor.action.rename', vim.uri_from_bufnr(cur_buf)) and renamed == 1)
check('rename is dropped for another buffer', not extensions.run_editor_command('editor.action.rename', vim.uri_from_bufnr(other_buf)) and renamed == 1)
check('rename runs with no uri', extensions.run_editor_command('editor.action.rename', nil) and renamed == 2)
check('unknown commands are ignored', not extensions.run_editor_command('editor.action.doSomethingNew', nil))
check('parameter hints map to signature help', extensions.run_editor_command('editor.action.triggerParameterHints', nil) and sig_shown == 1)
-- Through the handler: scheduled, so it runs after the showDocument that selected the target.
ext['intellij/runEditorCommand'](nil, { command = 'editor.action.rename', arguments = {}, uri = vim.uri_from_bufnr(cur_buf) }, { client_id = 4711 })
vim.wait(100, function() return renamed == 3 end)
check('the handler runs the command', renamed == 3, tostring(renamed))
local ok_bad = pcall(ext['intellij/runEditorCommand'], nil, { arguments = {} }, { client_id = 4711 })
check('runEditorCommand tolerates a missing command', ok_bad)

-- The same names on a completion item's command dispatch locally instead of going to the server.
local cmds_tbl = extensions.commands()
check('client commands cover the three editor actions',
  cmds_tbl['editor.action.rename'] and cmds_tbl['editor.action.triggerSuggest'] and cmds_tbl['editor.action.triggerParameterHints'])
cmds_tbl['editor.action.rename']({ command = 'editor.action.rename' }, { bufnr = cur_buf, client_id = 4711 })
check('a completion command renames in its own buffer', renamed == 4, tostring(renamed))
cmds_tbl['editor.action.rename']({ command = 'editor.action.rename' }, { bufnr = other_buf, client_id = 4711 })
check('a completion command for another buffer is dropped', renamed == 4, tostring(renamed))
vim.lsp.buf.rename, vim.lsp.buf.signature_help = real_rename, real_sig

-- showConflicts is a request: the reply is the decision, produced from inside the coroutine Neovim
-- runs server requests in, exactly like window/showMessageRequest.
local conflicts_params = {
  title = 'Rename conflicts',
  conflicts = {
    { messages = { 'Field x is already defined' }, location = { uri = vim.uri_from_bufnr(other_buf), range = { start = { line = 4, character = 0 }, ['end'] = { line = 4, character = 3 } } } },
    { messages = { 'Library element' } },
  },
  continueLabel = 'Continue anyway', cancelLabel = 'Cancel', revealLabel = 'Show', documentChangedLabel = 'Changed',
}
local function ask_conflicts(pick)
  local rows
  vim.ui.select = function(items, _, on_choice) rows = items; on_choice(pick(items)) end
  local answer
  local co = coroutine.wrap(function() answer = ext['intellij/showConflicts'](nil, conflicts_params, { client_id = 4711 }) end)
  co()
  vim.wait(500, function() return answer ~= nil end)
  vim.ui.select = select_stub
  return answer, rows
end
local ans, rows = ask_conflicts(function(items) return items[#items - 1] end)
check('showConflicts lists conflicts then the two decisions', rows and #rows == 4 and rows[3].kind == 'continue' and rows[4].kind == 'cancel', vim.inspect(rows and vim.tbl_map(function(r) return r.kind end, rows)))
check('conflict rows name the file and line', rows and rows[1].label:find('Other.java:5', 1, true) ~= nil, rows and rows[1].label)
check('a conflict without a location shows a dash', rows and rows[2].label:sub(1, 1) == '-', rows and rows[2].label)
check('picking continue answers continue', ans and ans.decision == 'continue', vim.inspect(ans))
ans = ask_conflicts(function(items) return items[#items] end)
check('picking cancel answers cancel', ans and ans.decision == 'cancel', vim.inspect(ans))
ans = ask_conflicts(function() return nil end)
check('dismissing answers cancel', ans and ans.decision == 'cancel', vim.inspect(ans))
-- Picking a conflict reveals it and asks again; the second round decides.
local shown, round = 0, 0
local real_show = vim.lsp.util.show_document
vim.lsp.util.show_document = function() shown = shown + 1 end
ans = ask_conflicts(function(items) round = round + 1; return round == 1 and items[1] or items[3] end)
vim.lsp.util.show_document = real_show
check('picking a conflict reveals it and asks again', shown == 1 and round == 2 and ans and ans.decision == 'continue', ('%d/%d %s'):format(shown, round, vim.inspect(ans)))
-- Outside a coroutine (a direct call) the synchronous picker still yields a decision.
vim.ui.select = function(items, _, on_choice) on_choice(items[#items - 1]) end
local direct = extensions.show_conflicts(conflicts_params)
vim.ui.select = select_stub
check('a direct call answers synchronously', direct.decision == 'continue', vim.inspect(direct))
-- Editing while the question is open cancels it.
do
  local answer
  vim.ui.select = function() end -- an async picker that never answers
  local co = coroutine.wrap(function() answer = ext['intellij/showConflicts'](nil, conflicts_params, { client_id = 4711 }) end)
  co()
  vim.api.nvim_exec_autocmds('TextChanged', { buffer = cur_buf })
  vim.wait(500, function() return answer ~= nil end)
  vim.ui.select = select_stub
  check('a buffer edit while conflicts are shown answers cancel', answer and answer.decision == 'cancel', vim.inspect(answer))
end
vim.lsp.get_client_by_id = real_get_client

-- The handlers and commands travel with the init option, in both directions.
local with_ext = client.config('/tmp/ijtest', {})
check('extensions on: showConflicts registered', with_ext.handlers['intellij/showConflicts'] ~= nil)
check('extensions on: runEditorCommand registered', with_ext.handlers['intellij/runEditorCommand'] ~= nil)
check('extensions on: editor commands registered', with_ext.commands['editor.action.rename'] ~= nil)
check('extensions on: lazyIntentions asked for', with_ext.init_options.lazyIntentions == true)
local without_ext = client.config('/tmp/ijtest', { intellij_extensions = false })
check('extensions off: no intellij/ handlers', without_ext.handlers['intellij/showConflicts'] == nil and without_ext.handlers['intellij/chooseAction'] == nil)
check('extensions off: no editor commands', next(without_ext.commands) == nil)
check('extensions off: lazyIntentions declined', without_ext.init_options.lazyIntentions == false)

-- ---------------------------------------------------------------------------
-- Snippet edits (SnippetTextEdit in workspace/applyEdit)
-- ---------------------------------------------------------------------------
-- The server drops every fix ending in a mandatory live template unless the client advertises
-- snippetEditSupport, and Neovim's apply_workspace_edit fails on an edit with `snippet` instead of
-- `newText`. Advertise, extract, expand.
local snippet_edit = require('intellij-lsp.snippet_edit')
check('snippetEditSupport advertised', client.capabilities().workspace.workspaceEdit.snippetEditSupport == true)

local snip_buf = vim.api.nvim_create_buf(true, false)
vim.api.nvim_buf_set_name(snip_buf, '/tmp/ijtest/src/main/java/com/example/Snip.java')
vim.api.nvim_buf_set_lines(snip_buf, 0, -1, false, { 'class Snip {', '    int x = OLD;', '}' })
local snip_uri = vim.uri_from_bufnr(snip_buf)
local wedit = {
  documentChanges = {
    { textDocument = { uri = snip_uri, version = vim.NIL }, edits = {
      { range = { start = { line = 0, character = 6 }, ['end'] = { line = 0, character = 10 } }, newText = 'Renamed' },
      { range = { start = { line = 1, character = 12 }, ['end'] = { line = 1, character = 15 } }, snippet = { kind = 'snippet', value = 'compute(${1:arg})$0' } },
    } },
  },
}
local extracted = snippet_edit.extract(wedit)
check('extract pulls the snippet edit out', #extracted == 1 and extracted[1].uri == snip_uri and extracted[1].edit.snippet.value:find('compute', 1, true), vim.inspect(extracted))
check('extract leaves the plain edit in place', #wedit.documentChanges[1].edits == 1 and wedit.documentChanges[1].edits[1].newText == 'Renamed')
check('extract tolerates a nil edit', #snippet_edit.extract(nil) == 0 and #snippet_edit.extract({ changes = {} }) == 0)

vim.api.nvim_set_current_buf(snip_buf)
snippet_edit.apply_all(extracted, 'utf-16')
vim.cmd('stopinsert')
local snip_line = vim.api.nvim_buf_get_lines(snip_buf, 1, 2, false)[1]
check('the snippet replaces its range and expands', snip_line == '    int x = compute(arg);', snip_line)
check('the cursor sits in the expanded snippet', vim.api.nvim_win_get_cursor(0)[1] == 2, vim.inspect(vim.api.nvim_win_get_cursor(0)))

-- The full handler, against a live faux client: plain edit applied by Neovim, snippet expanded here.
vim.api.nvim_buf_set_lines(snip_buf, 0, -1, false, { 'class Snip {', '    int x = OLD;', '}' })
local snip_id = vim.lsp.start(vim.tbl_extend('force', client.config('/tmp/ijtest', {}), { name = 'faux-intellij-snippet', cmd = stub_server, root_dir = '/tmp' }), { attach = false })
local snip_client = snip_id and vim.lsp.get_client_by_id(snip_id)
vim.wait(2000, function() return snip_client and snip_client.initialized end)
if snip_client and snip_client.initialized then
  local handler = with_ext.handlers['workspace/applyEdit']
  local reply = handler(nil, { edit = {
    documentChanges = {
      { textDocument = { uri = snip_uri, version = vim.NIL }, edits = {
        { range = { start = { line = 0, character = 6 }, ['end'] = { line = 0, character = 10 } }, newText = 'Renamed' },
        { range = { start = { line = 1, character = 12 }, ['end'] = { line = 1, character = 15 } }, snippet = { kind = 'snippet', value = 'compute(${1:arg})$0' } },
      } },
    },
  } }, { client_id = snip_id, method = 'workspace/applyEdit' })
  vim.cmd('stopinsert')
  local lines = vim.api.nvim_buf_get_lines(snip_buf, 0, -1, false)
  check('applyEdit handler applies the plain edit', lines[1] == 'class Renamed {', lines[1])
  check('applyEdit handler expands the snippet edit', lines[2] == '    int x = compute(arg);', lines[2])
  check('applyEdit handler still answers applied', reply and reply.applied == true, vim.inspect(reply))
  vim.lsp.stop_client(snip_id, true)
else
  check('snippet client starts', false)
end
-- `vim.snippet.expand` enters insert mode through typeahead; drain it so later feedkeys-driven
-- tests start from normal mode with an empty queue.
pcall(vim.snippet.stop)
vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes('<Esc>', true, false, true), 'nx', false)

-- ---------------------------------------------------------------------------
-- Workspace import state and status
-- ---------------------------------------------------------------------------
local progress_mod = require('intellij-lsp.progress')
local ph = progress_mod.handlers()
check('workspaceImportState handled', type(ph['intellij/workspaceImportState']) == 'function')
check('workspaceImportStatus handled', type(ph['intellij/workspaceImportStatus']) == 'function')

local notified = {}
local real_notify = vim.notify
vim.notify = function(msg, level) notified[#notified + 1] = { msg = msg, level = level } end
local finished = { phase = 'FINISHED', folders = { { folderUri = 'file:///tmp/ijtest', tool = 'maven', status = 'SUCCESS' } } }
ph['intellij/workspaceImportState'](nil, finished, { client_id = 77 })
check('a successful import is stored', progress_mod.import_state(77) == finished)
check('a successful import says nothing', #notified == 0, vim.inspect(notified))
local failed = { phase = 'FAILED', message = 'boom', folders = {
  { folderUri = 'file:///tmp/ijtest', tool = 'gradle', status = 'FAILED', message = 'Could not resolve com.example:missing' },
  { folderUri = 'file:///tmp/other', status = 'BLOCKED', message = 'noBuildSystemFound' },
} }
ph['intellij/workspaceImportState'](nil, failed, { client_id = 77 })
check('one line per folder that did not import', #notified == 2, vim.inspect(notified))
check('a failed folder names the tool and the importer message',
  notified[1] and notified[1].msg:find('gradle', 1, true) and notified[1].msg:find('missing', 1, true) and notified[1].level == vim.log.levels.ERROR, notified[1] and notified[1].msg)
check('a blocked folder translates the reason id',
  notified[2] and notified[2].msg:find('no build file found', 1, true) ~= nil, notified[2] and notified[2].msg)
check('the last state replaces the previous one', progress_mod.import_state(77) == failed)
notified = {}
ph['intellij/workspaceImportState'](nil, { phase = 'CANCELLED', folders = {} }, { client_id = 77 })
check('a cancelled cycle with no folders is reported once', #notified == 1 and notified[1].msg:find('cancelled', 1, true), vim.inspect(notified))
vim.notify = real_notify

-- ambiguousBuildSystem: only a dismissed prompt is offered again, once, and the pick reloads with
-- that folder's buildTools entry set.
local reloads = {}
local real_reload = progress_mod._reload_with_tool
progress_mod._reload_with_tool = function(cid, uri, tool) reloads[#reloads + 1] = { cid, uri, tool } end
local selects = 0
vim.ui.select = function(items, _, on_choice) selects = selects + 1; on_choice(items[2]) end
local pending = { blockedFolders = { { folderUri = 'file:///tmp/ijtest', reason = 'ambiguousBuildSystem', candidates = { 'gradle', 'maven' }, dismissed = false } } }
ph['intellij/workspaceImportStatus'](nil, pending, { client_id = 77 })
check('status is stored', progress_mod.import_status(77) == pending)
check("the server's own prompt is not doubled", selects == 0)
local dismissed = { blockedFolders = { { folderUri = 'file:///tmp/ijtest', reason = 'ambiguousBuildSystem', candidates = { 'gradle', 'maven' }, dismissed = true } } }
ph['intellij/workspaceImportStatus'](nil, dismissed, { client_id = 77 })
check('a dismissed prompt is offered again', selects == 1)
check('the pick reloads with that tool', #reloads == 1 and reloads[1][2] == 'file:///tmp/ijtest' and reloads[1][3] == 'maven', vim.inspect(reloads))
ph['intellij/workspaceImportStatus'](nil, dismissed, { client_id = 77 })
check('the same folder is offered only once', selects == 1)
progress_mod.reset(77)
check('reset forgets import state and status', progress_mod.import_state(77) == nil and progress_mod.import_status(77) == nil)
vim.ui.select = select_stub
progress_mod._reload_with_tool = real_reload

-- The reload itself carries a full initializationOptions with the one folder pinned.
local reload_req
vim.lsp.get_client_by_id = function(id)
  if id == 4711 then
    return { id = 4711, config = { root_dir = '/tmp/ijtest' }, request = function(_, method, params) reload_req = { method, params } return true, 1 end }
  end
  return real_get_client(id)
end
progress_mod._reload_with_tool(4711, 'file:///tmp/ijtest/app', 'gradle')
vim.lsp.get_client_by_id = real_get_client
check('reload uses intellij/reloadWorkspace', reload_req and reload_req[1] == 'intellij/reloadWorkspace')
check('reload pins the folder to the chosen tool',
  reload_req and reload_req[2].initializationOptions.buildTools['file:///tmp/ijtest/app'] == 'gradle', vim.inspect(reload_req))
check('reload keeps the root folder entry',
  reload_req and reload_req[2].initializationOptions.buildTools[vim.uri_from_fname('/tmp/ijtest')] ~= nil, vim.inspect(reload_req))

-- ---------------------------------------------------------------------------
-- File templates
-- ---------------------------------------------------------------------------
local templates = require('intellij-lsp.templates')
local java_t = templates.templates_for({}, 'java')
check('java templates start with Class', java_t[1].name == 'Class' and #java_t == 6, vim.inspect(vim.tbl_map(function(t) return t.name end, java_t)))
check('kotlin templates include Data Class', vim.tbl_contains(vim.tbl_map(function(t) return t.name end, templates.templates_for({}, 'kotlin')), 'Data Class'))
check('unknown filetype has no templates', #templates.templates_for({}, 'python') == 0)
local custom = templates.templates_for({ file_templates = { java = { ['Class'] = false, ['Service'] = 'public class ${NAME} {}' } } }, 'java')
local custom_names = vim.tbl_map(function(t) return t.name end, custom)
check('a user entry adds a template', vim.tbl_contains(custom_names, 'Service'), vim.inspect(custom_names))
check('a false user entry removes a default', not vim.tbl_contains(custom_names, 'Class'), vim.inspect(custom_names))
check('defaults are not mutated by overrides', templates.templates_for({}, 'java')[1].name == 'Class')

local lines_, row_, col_ = templates.split_marker('package a;\n\npublic class A {\n\t|\n}')
check('split_marker removes the marker', lines_[4] == '\t' and #lines_ == 5, vim.inspect(lines_))
check('split_marker places the cursor at the marker', row_ == 4 and col_ == 1, row_ .. ':' .. col_)
local l2, r2, c2 = templates.split_marker('no marker here')
check('split_marker without a marker parks the cursor at the end', #l2 == 1 and r2 == 1 and c2 == #'no marker here')
local l3, r3, c3 = templates.split_marker('record R(|) {}')
check('split_marker on the first line', r3 == 1 and c3 == 9 and l3[1] == 'record R() {}', vim.inspect({ l3, r3, c3 }))

-- BufNewFile flags a buffer; an existing file is not flagged; the flag plus emptiness is the gate.
local tpl_group = vim.api.nvim_create_augroup('IntellijLspTest', { clear = true })
templates.setup_autocmd(tpl_group, { 'java', 'kotlin' })
vim.fn.mkdir('/tmp/ijtest/src/main/java/com/example', 'p')
vim.fn.delete('/tmp/ijtest/src/main/java/com/example/Fresh.java')
vim.cmd('edit /tmp/ijtest/src/main/java/com/example/Fresh.java')
local fresh = vim.api.nvim_get_current_buf()
check('BufNewFile flags a new java file', vim.b[fresh].intellij_lsp_new_file == true)
check('a flagged empty buffer is a template candidate', templates.is_empty_new_file(fresh))
vim.api.nvim_buf_set_lines(fresh, 0, -1, false, { 'typed' })
check('a buffer with text is not', not templates.is_empty_new_file(fresh))
vim.fn.writefile({ 'x' }, '/tmp/ijtest/src/main/java/com/example/Existing.java')
vim.cmd('edit /tmp/ijtest/src/main/java/com/example/Existing.java')
check('an existing file is not flagged', not vim.b[0].intellij_lsp_new_file)
vim.cmd('edit /tmp/ijtest/src/main/java/com/example/New.kt')
check('BufNewFile flags a new kotlin file', vim.b[0].intellij_lsp_new_file == true)
vim.api.nvim_del_augroup_by_id(tpl_group)

-- apply() creates the file first (the server resolves the URI through its VFS), sends exactly the
-- two arguments, and inserts the answer with the cursor at the marker.
do
  local req
  local tpl_client = { id = 1, request = function(_, method, params, handler) req = { method, params, handler } return true, 1 end }
  local target = '/tmp/ijtest/src/main/java/com/example/Made.java'
  vim.fn.delete(target)
  vim.cmd('edit ' .. target)
  local made = vim.api.nvim_get_current_buf()
  templates.apply(tpl_client, made, java_t[1])
  check('apply writes the empty file first', vim.fn.filereadable(target) == 1)
  check('apply sends interpolateFileTemplate with uri and text',
    req and req[1] == 'workspace/executeCommand' and req[2].command == 'interpolateFileTemplate'
    and req[2].arguments[1] == vim.uri_from_bufnr(made) and req[2].arguments[2] == java_t[1].text, vim.inspect(req and req[2]))
  req[3](nil, 'package com.example;\n\npublic class Made {\n\t|\n}')
  vim.cmd('stopinsert')
  local got_lines = vim.api.nvim_buf_get_lines(made, 0, -1, false)
  check('apply inserts the interpolated text', got_lines[1] == 'package com.example;' and got_lines[3] == 'public class Made {', vim.inspect(got_lines))
  check('apply parks the cursor at the marker', vim.api.nvim_win_get_cursor(0)[1] == 4, vim.inspect(vim.api.nvim_win_get_cursor(0)))
  -- A null answer (file outside any project) leaves the buffer alone.
  vim.api.nvim_buf_set_lines(made, 0, -1, false, {})
  templates.apply(tpl_client, made, java_t[1])
  req[3](nil, vim.NIL)
  check('a null answer inserts nothing', (vim.api.nvim_buf_get_lines(made, 0, -1, false)[1] or '') == '')
  -- Text typed while the request was out is not overwritten.
  templates.apply(tpl_client, made, java_t[1])
  vim.api.nvim_buf_set_lines(made, 0, -1, false, { 'typed meanwhile' })
  req[3](nil, 'package x;')
  check('a late answer does not overwrite typed text', vim.api.nvim_buf_get_lines(made, 0, -1, false)[1] == 'typed meanwhile')
  vim.cmd('bwipeout! ' .. made)
  vim.fn.delete(target)
end

-- ---------------------------------------------------------------------------
-- Compilation errors and workspace export
-- ---------------------------------------------------------------------------
local workspace = require('intellij-lsp.workspace')
workspace.register_commands()
local all_cmds = vim.api.nvim_get_commands({})
check(':IntellijLspCompilationErrors registered', all_cmds.IntellijLspCompilationErrors ~= nil)
check(':IntellijLspExportWorkspace registered', all_cmds.IntellijLspExportWorkspace ~= nil)
local diag_buf = vim.api.nvim_create_buf(true, false)
vim.api.nvim_buf_set_lines(diag_buf, 0, -1, false, { 'int x = "s";' })
local diags = workspace._to_diagnostics({
  { range = { start = { line = 0, character = 8 }, ['end'] = { line = 0, character = 11 } }, severity = 1, message = 'incompatible types' },
}, diag_buf, { offset_encoding = 'utf-16' })
check('compiler errors convert to diagnostics', #diags == 1 and diags[1].lnum == 0 and diags[1].col == 8 and diags[1].message == 'incompatible types' and diags[1].bufnr == diag_buf, vim.inspect(diags))
end

-- ---------------------------------------------------------------------------
-- Single-key answers to numbered prompts
-- ---------------------------------------------------------------------------
local ui_select = require('intellij-lsp.select')
local prev_select = vim.ui.select
ui_select.setup()

--- Drives the wrapper with real typeahead and reports what on_choice received.
local function pick(keys, items)
  local got_item, got_idx, called = nil, nil, false
  vim.api.nvim_feedkeys(keys, 'n', false)
  vim.ui.select(items, { prompt = 'pick', format_item = function(i) return i.name end },
    function(item, idx)
      called, got_item, got_idx = true, item, idx
    end)
  return called, got_item, got_idx
end

local short = { { name = 'alpha' }, { name = 'beta' }, { name = 'gamma' } }

local called, item, idx = pick('2', short)
check('a bare digit selects, no <CR>', called and idx == 2 and item.name == 'beta', tostring(idx))
-- Regression: the menu is echoed as `{text}` chunks. Flattening it to bare strings makes nvim_echo
-- throw, which the surrounding pcall turned into a silent dismissal -- every pick answered nil.
check('selecting returns the item', item ~= nil and item.name == 'beta')

for _, key in ipairs({ { '\27', 'Esc' }, { 'q', 'q' } }) do
  local c, it, ix = pick(key[1], short)
  -- Dismissal still has to call back: extensions.lua must answer the server or it leaks the session.
  check(key[2] .. ' cancels and still calls back', c and it == nil and ix == nil)
end

local c_oob = select(3, pick('7', short))
check('an out-of-range digit cancels', c_oob == nil)
local c_nan = select(3, pick('x', short))
check('a non-digit cancels', c_nan == nil)

-- Above nine entries a single digit is ambiguous, so the built-in line prompt takes over -- which is
-- why this one needs the <CR> the rest do not.
local many = {}
for i = 1, 12 do many[i] = { name = 'item' .. i } end
local _, many_item, many_idx = pick('11\r', many)
check('a long list falls back to the line prompt', many_idx == 11 and many_item.name == 'item11',
  tostring(many_idx))

-- The wrapper has to be a good citizen: vim.ui.select is shared, and dressing.nvim/snacks.nvim
-- replace it with something better than this.
local sentinel = function() end
ui_select.teardown()
vim.ui.select = sentinel
ui_select.setup()
check('wrapping keeps the previous picker', vim.ui.select ~= sentinel)
ui_select.setup()
check('setup does not wrap itself twice', vim.ui.select == ui_select.select)
ui_select.teardown()
check('teardown restores the previous picker', vim.ui.select == sentinel)

vim.ui.select = prev_select

-- ---------------------------------------------------------------------------
-- Import / indexing progress reporting
-- ---------------------------------------------------------------------------
local status = require('intellij-lsp.status')

-- These exact strings are the server's `title` and `message` joined, with nothing reworded;
-- pinning them here stops the line from drifting away from the server's wording.
local function text(t) return (status.describe(t)) end
check('importing reports the build tool',
  text({ title = 'Importing', message = 'Maven' }) == 'Importing: Maven',
  text({ title = 'Importing', message = 'Maven' }))
check('non-numeric indexing message passes through',
  text({ title = 'Indexing', message = 'Invalidating files' }) == 'Indexing: Invalidating files')
check('title without message', text({ title = 'Indexing' }) == 'Indexing')
-- Titles are never translated, so one this client has never heard of must still reach the user.
check('unknown title still reports',
  text({ title = 'Future Phase', message = 'x' }) == 'Future Phase: x')
check('no progress reports nothing', text(nil) == nil and text({}) == nil)

-- Neovim draws the `percent` field itself, so a message that is only the percentage would render
-- as "47% Indexing: 47%". The digits move to the field and the text collapses to the title.
local t47, p47 = status.describe({ title = 'Indexing', message = '47%', percent = 47 })
check('percentage-only message collapses to the title', t47 == 'Indexing', t47)
check('percentage travels as the field', p47 == 47, p47)
check('whitespace-padded percentage also collapses',
  (status.describe({ title = 'Indexing', message = ' 8 % ' })) == 'Indexing')
-- but a message that merely *contains* a number keeps its wording
check('prose with a number is kept',
  (status.describe({ title = 'Indexing', message = '3 of 9 roots' })) == 'Indexing: 3 of 9 roots')

-- The dots. Frames without a percentage get one to three trailing dots, so a line that can sit
-- unchanged for minutes ("Importing: Maven") still reads as alive rather than hung. Pure on purpose:
-- the frame is an argument, so all three frames and the wraparound are checked without a timer.
check('frame 1 is one dot', status.animate('Importing: Maven', nil, 1) == 'Importing: Maven .',
  status.animate('Importing: Maven', nil, 1))
check('frame 2 is two dots', status.animate('Importing: Maven', nil, 2) == 'Importing: Maven ..')
check('frame 3 is three dots', status.animate('Importing: Maven', nil, 3) == 'Importing: Maven ...')
-- Wraps back to one dot, never to none: a line that periodically loses its dots looks like it
-- finished and started over.
check('frame 4 wraps to one dot', status.animate('Importing: Maven', nil, 4) == 'Importing: Maven .',
  status.animate('Importing: Maven', nil, 4))
check('frame 6 is three dots', status.animate('Importing: Maven', nil, 6) == 'Importing: Maven ...')
check('frame 7 wraps to one dot', status.animate('Importing: Maven', nil, 7) == 'Importing: Maven .')
-- The counter free-runs across phases and is never reset, so any integer has to stay in range.
check('frame 100 stays in range',
  status.animate('Importing: Maven', nil, 100):match(' %.%.?%.?$') ~= nil,
  status.animate('Importing: Maven', nil, 100))

-- A percentage is its own liveness signal, so those frames stay byte-identical -- both signals at
-- once would say the same thing twice and jitter the width as the digits move.
for f = 1, 4 do
  check('percentage frames get no dots (frame ' .. f .. ')',
    status.animate('Indexing', 47, f) == 'Indexing', status.animate('Indexing', 47, f))
end
check('zero percent still counts as a percentage', status.animate('Indexing', 0, 2) == 'Indexing')
check('nothing to report stays nothing', status.animate(nil, nil, 1) == nil)

-- The closing frame carries no dots, which is structural rather than conditional: `finish` builds its
-- text from `describe` and never routes through `animate`. Pinned anyway, because "Ready ..." would
-- claim work is still running after the index was flushed. These two also fail loudly if anyone
-- later folds the decoration back into `describe`.
check('Ready is never decorated', (status.describe({ title = 'Ready' })) == 'Ready')
check('describe carries no dots',
  (status.describe({ title = 'Importing', message = 'Maven' })) == 'Importing: Maven')

-- State machine. Payloads mirror the wire, including the `title` Neovim back-fills onto report/end.
local CID = 4242
local function progress_event(token, value) status.on_progress(CID, { token = token, value = value }) end

status.reset(CID)
progress_event('t1', { kind = 'begin', title = 'Importing', message = 'Maven' })
check('begin importing', text(status.get(CID)) == 'Importing: Maven')

progress_event('t2', { kind = 'begin', title = 'Indexing' })
progress_event('t2', { kind = 'report', title = 'Indexing', message = '47%', percentage = 47 })
check('indexing outranks importing', text(status.get(CID)) == 'Indexing')
check('percent tracked', status.percent(CID) == 47, status.percent(CID))

-- The server ends the two overlapping bars in either order; a single scalar phase would let this
-- late import end wipe the indexing report.
progress_event('t1', { kind = 'end', title = 'Importing' })
check('late import end does not clobber indexing', text(status.get(CID)) == 'Indexing')
check('late import end keeps the percentage', status.percent(CID) == 47)

progress_event('t2', { kind = 'report', title = 'Indexing', message = 'Invalidating files' })
progress_event('t2', { kind = 'report', title = 'Indexing', percentage = 60 })
check('bare percentage report keeps the message',
  text(status.get(CID)) == 'Indexing: Invalidating files', text(status.get(CID)))
check('bare percentage report updates the number', status.percent(CID) == 60)

progress_event('t2', { kind = 'report', title = 'Indexing', percentage = 120 })
check('percentage clamped to 100', status.percent(CID) == 100, status.percent(CID))

-- Regression: the Importing bar outlives Indexing, so recomputing from live tokens alone dropped
-- the line back to "Importing: Maven" after indexing had finished, reading as a restarted import.
status.reset(CID)
progress_event('i1', { kind = 'begin', title = 'Importing', message = 'Maven' })
progress_event('i2', { kind = 'begin', title = 'Indexing' })
progress_event('i2', { kind = 'report', title = 'Indexing', message = 'Just a few more moments...' })
progress_event('i2', { kind = 'end', title = 'Indexing' })
check('indexing end does not fall back to importing',
  text(status.get(CID)) == 'Indexing: Just a few more moments...', text(status.get(CID)))
progress_event('i1', { kind = 'end', title = 'Importing' })
check('startup never moves backwards',
  text(status.get(CID)) == 'Indexing: Just a few more moments...', text(status.get(CID)))

-- With every token ended the index is still being flushed, so the last phase is held rather than
-- blanked; progress.lua's ready-for-test handler is what closes the line.
status.reset(CID)
progress_event('t2', { kind = 'begin', title = 'Indexing', message = 'Invalidating files' })
progress_event('t2', { kind = 'end', title = 'Indexing' })
check('last phase is held after all tokens end',
  text(status.get(CID)) == 'Indexing: Invalidating files', text(status.get(CID)))
check('nothing reported before any progress arrives', text(status.get(999)) == nil)

-- Attaching mid-session: the first payload seen may be a report, which the back-filled title makes
-- self-describing enough to adopt.
status.reset(CID)
progress_event('t9', { kind = 'report', title = 'Indexing', message = 'Just a moment', percentage = 5 })
check('report for an unseen token is adopted', text(status.get(CID)) == 'Indexing: Just a moment')
status.reset(CID)
check('reset clears the client', status.get(CID) == nil)

-- The in-place message. Reusing the id is what keeps ten reports a second on one line instead of
-- scrolling the message area; without it the hit-enter prompt would fire constantly.
local pm = { kind = 'progress', source = 'intellij-lsp', title = 'IntelliJ LSP', status = 'running' }
local first = vim.api.nvim_echo({ { 'Importing: Maven' } }, false, pm)
check('nvim_echo returns a message id', type(first) == 'number', type(first))
pm.id = first
local second = vim.api.nvim_echo({ { 'Indexing' } }, false, pm)
check('passing the id back reuses the message', second == first, tostring(second))

-- Regression: the server re-runs a short `Indexing` begin/end on every file event after the initial
-- flush -- it watches the project root's ancestors, so a shell writing ~/.zsh_history is enough --
-- and `ready-for-test` is sent once per session. Holding the line open after those rounds left a
-- "running" Indexing message on screen indefinitely. Drives the real autocmd path with a stubbed
-- client lookup and a captured message area.
do
  local progress_mod = require('intellij-lsp.progress')
  local SID = 4343
  local real_get, real_echo, real_notify = vim.lsp.get_client_by_id, vim.api.nvim_echo, vim.notify
  local echoes = {}
  vim.lsp.get_client_by_id = function(id) return id == SID and { name = client.NAME } or nil end
  vim.api.nvim_echo = function(chunks, _, opts)
    if opts.kind == 'progress' then table.insert(echoes, { status = opts.status, text = chunks[1][1] }) end
    return opts.id or 7
  end
  vim.notify = function() end
  status.setup_autocmds()
  local function fire(kind, message, percentage)
    vim.api.nvim_exec_autocmds('LspProgress', { data = { client_id = SID, params = {
      token = 's1', value = { kind = kind, title = 'Indexing', message = message, percentage = percentage },
    } } })
  end

  fire('begin'); fire('report', '47%', 47); fire('end')
  check('startup: line held open after end, before ready', status.get(SID).msg_id ~= nil)
  progress_mod.handlers()['intellij/ready-for-test'](nil, nil, { client_id = SID })
  check('startup: ready closes the line', status.get(SID).msg_id == nil)
  check('startup: closing frame is Ready', echoes[#echoes].status == 'success' and echoes[#echoes].text == 'Ready',
    vim.inspect(echoes[#echoes]))

  fire('begin'); fire('report', '0%', 0)
  check('post-ready round: a live token reopens the line', status.get(SID).msg_id ~= nil)
  check('post-ready round: shows as running', echoes[#echoes].status == 'running', echoes[#echoes].status)
  fire('end')
  check('post-ready round: its end closes the line', status.get(SID).msg_id == nil)
  check('post-ready round: closing frame is Ready', echoes[#echoes].status == 'success' and echoes[#echoes].text == 'Ready',
    vim.inspect(echoes[#echoes]))
  check('is_idle after the round', status.is_idle(SID))

  status.teardown_autocmds()
  status.reset(SID)
  progress_mod.reset(SID)
  vim.lsp.get_client_by_id, vim.api.nvim_echo, vim.notify = real_get, real_echo, real_notify
end

-- Server download: platform mapping, the published bundle table, and archive kinds. Pure, no network.
local server_download = require('intellij-lsp.server_download')
local bundles = require('intellij-lsp.server_bundles')
local BASE = 'https://download.jetbrains.com/language-server/intellij-server/' .. bundles.version
  .. '/intellij-server-' .. bundles.version

local platform_cases = {
  { uname = { sysname = 'Darwin', machine = 'arm64' }, os = 'macos', arch = 'aarch64', file = '-aarch64.sit' },
  { uname = { sysname = 'Darwin', machine = 'x86_64' }, os = 'macos', arch = 'x86_64', file = '.sit' },
  { uname = { sysname = 'Linux', machine = 'aarch64' }, os = 'linux', arch = 'aarch64', file = '-aarch64.tar.gz' },
  { uname = { sysname = 'Linux', machine = 'x86_64' }, os = 'linux', arch = 'x86_64', file = '.tar.gz' },
  { uname = { sysname = 'Windows_NT', machine = 'arm64' }, os = 'windows', arch = 'aarch64', file = '-aarch64.win.zip' },
  { uname = { sysname = 'Windows_NT', machine = 'AMD64' }, os = 'windows', arch = 'x86_64', file = '.win.zip' },
}
for _, case in ipairs(platform_cases) do
  local label = case.uname.sysname .. '/' .. case.uname.machine
  local os, arch, perr = server_download._platform(case.uname)
  check('platform ' .. label, os == case.os and arch == case.arch and perr == nil, tostring(perr))
  local bundle, berr = bundles.bundle(case.os, case.arch)
  check('bundle url ' .. label, bundle and bundle.url == BASE .. case.file, bundle and bundle.url or berr)
  check('bundle sha256 ' .. label, bundle and bundle.sha256:match('^%x+$') and #bundle.sha256 == 64
    and bundle.sha256 == bundle.sha256:lower(), bundle and bundle.sha256)
  check('bundle version ' .. label, bundle and bundle.version == bundles.version)
end

local uos, uarch, uerr = server_download._platform({ sysname = 'Linux', machine = 'riscv64' })
check('unknown machine -> error', uos == nil and uarch == nil and uerr and uerr:find('riscv64', 1, true), uerr)
check('live platform resolves', (server_download._platform()) ~= nil)
local nb, nberr = bundles.bundle('plan9', 'x86_64')
check('unknown os -> no bundle', nb == nil and nberr and nberr:find('plan9', 1, true), nberr)

check('archive_kind .sit -> zip', server_download._archive_kind(BASE .. '-aarch64.sit') == 'zip')
check('archive_kind .win.zip -> zip', server_download._archive_kind(BASE .. '.win.zip') == 'zip')
check('archive_kind .tar.gz', server_download._archive_kind(BASE .. '.tar.gz') == 'tar.gz')
check('archive_kind .tgz', server_download._archive_kind('x.tgz') == 'tar.gz')
check('archive_kind .dmg -> nil', server_download._archive_kind('x.dmg') == nil)

check('status: disabled -> not-configured', server_download.status({ server_download = false }) == 'not-configured')
check('status: own bundle -> not-configured',
  server_download.status({ server_path = '/opt/intellij-server/bin/intellij-server' }) == 'not-configured')
local st = server_download.status({})
check('status: default -> cached or missing', st == 'cached' or st == 'missing', st)

-- Download progress line text.
local pt, ppc = server_download._progress_text('1.0', 50e6, 200e6)
check('progress text with total', pt == 'Downloading intellij-server 1.0: 50 / 200 MB' and ppc == 25, pt .. ' ' .. tostring(ppc))
local pt2, ppc2 = server_download._progress_text('1.0', 5e6, nil)
check('progress text without total', pt2 == 'Downloading intellij-server 1.0: 5 MB' and ppc2 == nil, pt2)
local _, ppc3 = server_download._progress_text('1.0', 250e6, 200e6)
check('progress percent clamps at 100', ppc3 == 100, ppc3)

-- Install lock: owner PID, stale detection, sweep of the partial archive.
local vdir = vim.fs.normalize(vim.fn.tempname() .. '/server/1.0')
local lock = vdir .. '.lock'
local partial = vim.fs.normalize(vim.fn.tempname() .. '-archive')
check('lock acquired', server_download._try_lock(vdir, partial) == 'acquired')
check('lock records own pid', tonumber(vim.fn.readfile(lock .. '/pid')[1]) == vim.uv.os_getpid())
check('own lock is not stale', server_download._lock_is_stale(lock) == false)
check('own lock -> held', server_download._try_lock(vdir, partial) == 'held')

local dead_proc = vim.system({ 'true' })
local dead_pid = dead_proc.pid
dead_proc:wait()
vim.fn.writefile({ tostring(dead_pid) }, lock .. '/pid')
vim.fn.writefile({ 'partial' }, partial)
check('dead owner -> stale', server_download._lock_is_stale(lock) == true)
check('stale lock is swept and re-acquired', server_download._try_lock(vdir, partial) == 'acquired')
check('partial archive removed with stale lock', vim.fn.filereadable(partial) == 0)
check('pid file rewritten to own pid', tonumber(vim.fn.readfile(lock .. '/pid')[1]) == vim.uv.os_getpid())

vim.fn.delete(lock .. '/pid')
check('fresh lock without pid is not stale', server_download._lock_is_stale(lock) == false)
server_download._release_lock(vdir)
check('release removes the lock', vim.fn.isdirectory(lock) == 0)

-- ---------------------------------------------------------------------------
-- Output panel: jump targets, import-log highlighting, and the shared buffer
-- ---------------------------------------------------------------------------
local output = require('intellij-lsp.output')
local progress = require('intellij-lsp.progress')

local function jt(line) return output._jump_target(line) end
local t

t = jt('[ERROR] /w/src/main/java/App.java:[12,5] cannot find symbol')
check('jump: maven compiler line', t and t.file == '/w/src/main/java/App.java' and t.lnum == 12 and t.col == 5 and not t.bare, vim.inspect(t))
t = jt('[FATAL] Non-parseable POM /w/pom.xml: end tag name </b> must match start tag @ line 12, column 3')
check('jump: maven pom parse error', t and t.file == '/w/pom.xml' and t.lnum == 12 and t.col == 3, vim.inspect(t))
t = jt("* Where: Build file '/w/build.gradle' line: 7")
check('jump: gradle build script', t and t.file == '/w/build.gradle' and t.lnum == 7 and t.col == nil, vim.inspect(t))
t = jt('e: /w/src/main/kotlin/Main.kt: (3, 9): Unresolved reference: foo')
check('jump: kotlin compiler line', t and t.file == '/w/src/main/kotlin/Main.kt' and t.lnum == 3 and t.col == 9, vim.inspect(t))
t = jt('/w/src/App.java:12: error: missing return statement')
check('jump: javac line', t and t.file == '/w/src/App.java' and t.lnum == 12 and t.col == nil, vim.inspect(t))
t = jt('/w/src/App.java:12:5: warning: something')
check('jump: path:line:col', t and t.lnum == 12 and t.col == 5, vim.inspect(t))
t = jt('	at com.example.App.main(App.java:42)')
check('jump: stack frame is bare', t and t.file == 'App.java' and t.lnum == 42 and t.bare, vim.inspect(t))
check('jump: plain text has no target', jt('[INFO] Building demo 1.0-SNAPSHOT') == nil)
check('jump: download line has no target', jt('Downloading from central: https://repo.maven.apache.org/maven2/x/y/1.0/y-1.0.pom') == nil)

-- Highlighting: type first, then Maven/Gradle/Kotlin stdout conventions.
check('hl: error type', progress._import_hl(1, 'anything') == 'DiagnosticError')
check('hl: stderr is warn', progress._import_hl(2, 'Downloading from central: x') == 'DiagnosticWarn')
check('hl: [ERROR] on stdout', progress._import_hl(3, '[ERROR] Failed to execute goal') == 'DiagnosticError')
check('hl: BUILD FAILURE', progress._import_hl(3, '[INFO] BUILD FAILURE') == 'DiagnosticError')
check('hl: gradle FAILURE', progress._import_hl(3, 'FAILURE: Build failed with an exception.') == 'DiagnosticError')
check('hl: [WARNING]', progress._import_hl(3, '[WARNING] Some problems were encountered') == 'DiagnosticWarn')
check('hl: BUILD SUCCESS', progress._import_hl(3, '[INFO] BUILD SUCCESS') == 'DiagnosticOk')
check('hl: plain info', progress._import_hl(3, '[INFO] Building demo 1.0') == nil)

check('elapsed seconds', progress._elapsed(12345) == '12s', progress._elapsed(12345))
check('elapsed minutes', progress._elapsed(72000) == '1m 12s', progress._elapsed(72000))

-- The shared buffer: appends coalesce, the first line is not blank, highlights land as extmarks.
output._reset()
output.append('one\ntwo\n')
output.append('three', 'DiagnosticWarn')
output._flush()
local obuf = output.buf()
local olines = vim.api.nvim_buf_get_lines(obuf, 0, -1, false)
check('output: lines appended without leading blank', vim.deep_equal(olines, { 'one', 'two', 'three' }), vim.inspect(olines))
local marks = vim.api.nvim_buf_get_extmarks(obuf, vim.api.nvim_create_namespace('intellij-lsp-output'), 0, -1, { details = true })
check('output: one highlighted line', #marks == 1 and marks[1][2] == 2 and marks[1][4].line_hl_group == 'DiagnosticWarn', vim.inspect(marks))

-- Import log through the real handler, with the default policy: nothing opens on start or success.
progress.configure({ build_output = 'on_failure' })
local il = progress.handlers()['intellij/importLog']
il(nil, { type = 3, message = 'Importing with Maven in /w', tool = 'Maven', started = true }, {})
il(nil, { type = 3, message = '[INFO] Scanning for projects...' }, {})
il(nil, { type = 2, message = 'Downloading from central: x' }, {})
il(nil, { type = 3, message = 'Workspace imported successfully', succeeded = true }, {})
output._flush()
olines = vim.api.nvim_buf_get_lines(obuf, 0, -1, false)
check('import: separator uses server message', olines[4] == '--- Importing with Maven in /w ---', olines[4])
check('import: lines forwarded', olines[5] == '[INFO] Scanning for projects...' and olines[6] == 'Downloading from central: x')
check('import: success separator names the tool', olines[7] and olines[7]:match('^%-%-%- Maven: import succeeded in %d+s %-%-%-$'), olines[7])
check('import: success message not duplicated', #olines == 7, #olines)
check('import: panel stays closed on success (on_failure)', not output.is_open())

il(nil, { type = 3, message = 'Importing with Gradle in /w', tool = 'Gradle', started = true }, {})
il(nil, { type = 1, message = 'Failed to import Gradle project', tool = 'Gradle', failed = true }, {})
output._flush()
olines = vim.api.nvim_buf_get_lines(obuf, 0, -1, false)
check('import: failure message kept', olines[9] == 'Failed to import Gradle project', olines[9])
check('import: failure separator', olines[10] and olines[10]:match('^%-%-%- Gradle: import failed'), olines[10])
check('import: panel opens on failure', output.is_open())
check('import: failure did not steal focus', vim.api.nvim_get_current_buf() ~= obuf)
output.close()

progress.configure({ build_output = 'always' })
il(nil, { type = 3, message = 'Importing with Maven in /w', tool = 'Maven', started = true }, {})
check('import: always opens on start', output.is_open())
output.close()

progress.configure({ build_output = 'never' })
il(nil, { type = 1, message = 'boom', tool = 'Maven', failed = true }, {})
check('import: never keeps the panel closed on failure', not output.is_open())
output._reset()


-- ---------------------------------------------------------------------------
-- run.lua: the build that precedes a launch. Drives `_build` / `_run_build` directly with a fake
-- client and `sh`, so it needs neither a server nor nvim-dap (absent under `-u NONE` anyway).
-- ---------------------------------------------------------------------------
local run = require('intellij-lsp.run')

-- `_build_to_run` is the client-side half of the `resolveBuildCommand` contract: unsupported ->
-- nothing plus the reason, empty command -> nothing.
local b, why = run._build_to_run({ supported = true, tool = 'maven', cwd = '/w', command = { 'mvn', 'compile' } })
check('build: supported answer yields a build', b and b.command[1] == 'mvn' and b.cwd == '/w' and b.tool == 'maven')
b, why = run._build_to_run({ supported = false, reason = 'no build tool owns this module' })
check('build: unsupported yields nothing and the reason', b == nil and why == 'no build tool owns this module')
b, why = run._build_to_run({ supported = true, command = {} })
check('build: empty command yields nothing', b == nil and why == nil)
check('build: nil answer yields nothing', run._build_to_run(nil) == nil)

local function panel_text()
  return table.concat(vim.api.nvim_buf_get_lines(output.buf(), 0, -1, false), '\n')
end
local function wait_for(pred) return vim.wait(5000, pred, 20) end

-- A failing build stops the launch, its output (both streams) is in the panel, and the panel is open.
output._reset()
local result = nil
run._run_build({ tool = 'maven', command = { 'sh', '-c', 'echo compiling; echo "[ERROR] /w/A.java:[3,5] boom" >&2; exit 3' } },
  function(ok) result = ok end)
check('build: failure -> not ok', wait_for(function() return result ~= nil end) and result == false, tostring(result))
check('build: stdout reaches the panel', wait_for(function() return panel_text():find('compiling', 1, true) ~= nil end))
check('build: stderr reaches the panel', panel_text():find('[ERROR] /w/A.java', 1, true) ~= nil, panel_text())
check('build: failure separator names the exit code', panel_text():find('build failed, exit 3', 1, true) ~= nil, panel_text())
check('build: failure opens the panel', output.is_open())

-- Exit 0 continues to the launch. The output has no trailing newline, so the last line arrives as a
-- partial chunk and is only written by the exit-time flush.
output._reset()
result = nil
run._run_build({ tool = 'gradle', command = { 'sh', '-c', 'printf "one\\ntwo"' } }, function(ok) result = ok end)
check('build: success -> ok', wait_for(function() return result ~= nil end) and result == true, tostring(result))
check('build: partial last line is flushed', wait_for(function() return panel_text():find('\ntwo\n', 1, true) ~= nil end), panel_text())
check('build: success separator', panel_text():find('gradle: build succeeded', 1, true) ~= nil, panel_text())

-- A command that cannot be spawned is a failed build, not a skipped one.
output._reset()
result = nil
run._run_build({ command = { '/nonexistent/mvn', 'compile' } }, function(ok) result = ok end)
check('build: unspawnable -> not ok', wait_for(function() return result ~= nil end) and result == false, tostring(result))
check('build: unspawnable is reported', wait_for(function() return panel_text():find('build failed to start', 1, true) ~= nil end), panel_text())

-- `stop()` during a build kills it and the launch never happens.
output._reset()
result = nil
run._run_build({ tool = 'maven', command = { 'sh', '-c', 'sleep 30' } }, function(ok) result = ok end)
vim.wait(100)
run.stop()
check('build: stop reports it', wait_for(function() return panel_text():find('build stopped', 1, true) ~= nil end), panel_text())
vim.wait(100)
check('build: stop never continues to the launch', result == nil)

-- `_build` with a fake client: a lookup failure or an unsupported module launches anyway and says so.
local function fake_client(err, resolved)
  return { request = function(_, method, params, handler)
    check('build: asks resolveBuildCommand', method == 'workspace/executeCommand'
      and params.command == 'intellij.java.resolveBuildCommand' and params.arguments[1].uri == 'file:///w/A.java')
    handler(err, resolved)
  end }
end
output._reset()
result = nil
run._build(fake_client({ message = 'server busy' }, nil), 'file:///w/A.java', function(ok) result = ok end)
check('build: lookup error -> launch anyway', wait_for(function() return result ~= nil end) and result == true)
check('build: lookup error is noted', wait_for(function() return panel_text():find('build skipped: server busy', 1, true) ~= nil end), panel_text())
output._reset()
result = nil
run._build(fake_client(nil, { supported = false, reason = 'JPS module' }), 'file:///w/A.java', function(ok) result = ok end)
check('build: unsupported -> launch anyway', wait_for(function() return result ~= nil end) and result == true)
check('build: unsupported reason is noted', wait_for(function() return panel_text():find('build skipped: JPS module', 1, true) ~= nil end), panel_text())
output._reset()
result = nil
run._build(fake_client(nil, { supported = true, tool = 'maven', command = { 'sh', '-c', 'exit 0' } }), 'file:///w/A.java',
  function(ok) result = ok end)
check('build: resolved command runs and continues', wait_for(function() return result ~= nil end) and result == true)
output._reset()


-- ---------------------------------------------------------------------------------------------
-- versions.lua: the server's per-notification counter vs Neovim's changedtick
-- ---------------------------------------------------------------------------------------------
local versions = require('intellij-lsp.versions')
local URI = 'file:///w/Owner.java'
local CID = 901

-- The sequence measured against a live server: didOpen at version 0, then a rename (two edits in one
-- didChange, tick 6), a blank-line insert (tick 7) and a reformat (tick 8). The server answers 3.
versions.on_notify(CID, 'textDocument/didOpen', { textDocument = { uri = URI, version = 0 } })
versions.on_notify(CID, 'textDocument/didChange', { textDocument = { uri = URI, version = 6 } })
versions.on_notify(CID, 'textDocument/didChange', { textDocument = { uri = URI, version = 7 } })
versions.on_notify(CID, 'textDocument/didChange', { textDocument = { uri = URI, version = 8 } })
check('versions: current counter -> current tick', versions.translate(CID, URI, 3) == 8, versions.translate(CID, URI, 3))
check('versions: older counter -> the tick it was sent with', versions.translate(CID, URI, 2) == 7)
check('versions: first counter -> first tick', versions.translate(CID, URI, 1) == 6)
check('versions: untouched buffer keeps its version', versions.translate(CID, URI, 0) == 0)
check('versions: a fixed server answering with our tick passes through', versions.translate(CID, URI, 8) == 8)
check('versions: a fixed server answering with a stale tick passes through', versions.translate(CID, URI, 6) == 6)
check('versions: unknown value -> vim.NIL', versions.translate(CID, URI, 40) == vim.NIL)
check('versions: absent version -> vim.NIL', versions.translate(CID, URI, nil) == vim.NIL)
check('versions: explicit null stays null', versions.translate(CID, URI, vim.NIL) == vim.NIL)
check('versions: unknown document is left alone', versions.translate(CID, 'file:///w/Other.java', 3) == 3)

-- A reload sends didClose + didOpen with the current tick; the counter restarts from there.
versions.on_notify(CID, 'textDocument/didClose', { textDocument = { uri = URI } })
check('versions: didClose forgets the document', versions.translate(CID, URI, 3) == 3)
versions.on_notify(CID, 'textDocument/didOpen', { textDocument = { uri = URI, version = 12 } })
versions.on_notify(CID, 'textDocument/didChange', { textDocument = { uri = URI, version = 13 } })
check('versions: counter restarts from the reopened version', versions.translate(CID, URI, 13) == 13)
versions.on_notify(CID, 'textDocument/didChange', { textDocument = { uri = URI, version = 20 } })
check('versions: counter 14 is tick 20', versions.translate(CID, URI, 14) == 20)

-- Only TextDocumentEdit entries are touched; file operations and the `changes` map are not.
local edit = {
  documentChanges = {
    { kind = 'rename', oldUri = URI, newUri = 'file:///w/Pet.java' },
    { textDocument = { uri = URI, version = 14 }, edits = {} },
    { textDocument = { uri = URI }, edits = {} },
  },
}
versions.fix_workspace_edit(CID, edit)
check('fix_workspace_edit: rename op untouched', edit.documentChanges[1].kind == 'rename' and edit.documentChanges[1].oldUri == URI)
check('fix_workspace_edit: counter translated', edit.documentChanges[2].textDocument.version == 20)
check('fix_workspace_edit: missing version normalised to null', edit.documentChanges[3].textDocument.version == vim.NIL)
local plain = { changes = { [URI] = {} } }
versions.fix_workspace_edit(CID, plain)
check('fix_workspace_edit: changes map untouched', plain.documentChanges == nil and plain.changes[URI] ~= nil)

-- install(): the wrapped client feeds the ledger from notify and rewrites request results, for the
-- handler passed in, the client's own handler table, and code actions in both shapes.
local seen = {}
local fake = {
  id = 902,
  handlers = {},
  notify = function(_, method, params) seen.notified = { method, params } return true end,
  request = function(_, method, params, handler)
    seen.requested = method
    if method == 'textDocument/rename' or method == 'workspace/willRenameFiles' then
      handler(nil, { documentChanges = { { textDocument = { uri = URI, version = 2 }, edits = {} } } })
    elseif method == 'codeAction/resolve' then
      handler(nil, { title = 'x', edit = { documentChanges = { { textDocument = { uri = URI, version = 2 }, edits = {} } } } })
    elseif method == 'textDocument/codeAction' then
      handler(nil, {
        { title = 'cmd', command = 'noop' },
        { title = 'fix', edit = { documentChanges = { { textDocument = { uri = URI, version = 2 }, edits = {} } } } },
      })
    else
      handler(nil, { untouched = true, version = 2 })
    end
    return true, 1
  end,
}
versions.install(fake)
fake:notify('textDocument/didOpen', { textDocument = { uri = URI, version = 0 } })
fake:notify('textDocument/didChange', { textDocument = { uri = URI, version = 5 } })
fake:notify('textDocument/didChange', { textDocument = { uri = URI, version = 9 } })
check('install: notify still reaches the client', seen.notified[1] == 'textDocument/didChange' and seen.notified[2].textDocument.version == 9)

local got
fake:request('textDocument/rename', {}, function(_, result) got = result end)
check('install: rename result rewritten for the given handler', got.documentChanges[1].textDocument.version == 9, vim.inspect(got))
got = nil
fake.handlers['textDocument/rename'] = function(_, result) got = result end
fake:request('textDocument/rename', {}, nil)
check('install: nil handler resolves to the client handler table', got and got.documentChanges[1].textDocument.version == 9)
got = nil
fake:request('workspace/willRenameFiles', {}, function(_, result) got = result end)
check('install: willRenameFiles result rewritten', got.documentChanges[1].textDocument.version == 9)
got = nil
fake:request('codeAction/resolve', {}, function(_, result) got = result end)
check('install: resolved code action rewritten', got.edit.documentChanges[1].textDocument.version == 9)
got = nil
fake:request('textDocument/codeAction', {}, function(_, result) got = result end)
check('install: code action list rewritten, commands skipped',
  got[1].command == 'noop' and got[2].edit.documentChanges[1].textDocument.version == 9)
got = nil
fake:request('textDocument/hover', {}, function(_, result) got = result end)
check('install: other methods pass straight through', seen.requested == 'textDocument/hover' and got.untouched and got.version == 2)
versions.reset(902)
check('reset: ledger gone', versions.translate(902, URI, 2) == 2)

-- ---------------------------------------------------------------------------
-- Standard LSP the server offers and Neovim leaves off (editor.lua)
-- ---------------------------------------------------------------------------
-- Document highlight, signature help on `(`/`,`, hierarchy keymaps, formatting and symbol search
-- are all advertised by the real server and implemented by Neovim, and nothing between the two
-- ever requested them. Driven through the real `on_attach` against a faux server that advertises
-- exactly the capabilities the real one does.
local editor = require('intellij-lsp.editor')

local ed_buf = vim.api.nvim_create_buf(false, true)
vim.api.nvim_set_current_buf(ed_buf)
vim.bo[ed_buf].filetype = 'java'
vim.bo[ed_buf].buftype = ''

local function editor_server(dispatch)
  return {
    request = function(method, _, callback)
      if method == 'initialize' then
        callback(nil, { capabilities = {
          documentHighlightProvider = true,
          signatureHelpProvider = { triggerCharacters = { '(', ',' }, retriggerCharacters = { ',' } },
          typeHierarchyProvider = true,
          callHierarchyProvider = true,
          workspaceSymbolProvider = { workDoneProgress = true },
          documentFormattingProvider = true,
        } })
      elseif method == 'shutdown' then
        callback(nil, nil)
      end
      return true, 1
    end,
    notify = function(method)
      if method == 'exit' then dispatch.on_exit(0, 0) end
      return true
    end,
    is_closing = function() return false end,
    terminate = function() end,
  }
end

local ed_cfg = client.config('/tmp/ijtest', { format_on_save = true })
local ed_id = vim.lsp.start(
  vim.tbl_extend('force', ed_cfg, { name = 'faux-intellij-editor', cmd = editor_server, root_dir = '/tmp' }),
  { bufnr = ed_buf }
)
local ed_client = ed_id and vim.lsp.get_client_by_id(ed_id)
vim.wait(2000, function() return ed_client and ed_client.initialized end)

local function has_autocmd(group, event)
  local ok, cmds = pcall(vim.api.nvim_get_autocmds, { group = group, event = event, buffer = ed_buf })
  return ok and #cmds > 0
end
-- `vim.keymap.set` expands `<leader>` at mapping time, so match on the tail of the lhs.
local function has_map(lhs)
  local tail = lhs:gsub('^<leader>', '')
  for _, m in ipairs(vim.api.nvim_buf_get_keymap(ed_buf, 'n')) do
    if m.lhs:sub(-#tail) == tail and (m.desc or ''):find('^IntelliJ: ') then return true end
  end
  return false
end

if not (ed_client and ed_client.initialized) then
  check('editor client starts', false, 'client did not initialize')
else
  check('document highlight requested on CursorHold', has_autocmd('IntellijLspDocumentHighlight' .. ed_buf, 'CursorHold'))
  check('document highlight cleared on CursorMoved', has_autocmd('IntellijLspDocumentHighlight' .. ed_buf, 'CursorMoved'))
  check('signature help hooks InsertCharPre', has_autocmd('IntellijLspSignatureHelp' .. ed_buf, 'InsertCharPre'))
  check('format_on_save hooks BufWritePre', has_autocmd('IntellijLspFormatOnSave' .. ed_buf, 'BufWritePre'))
  check('type hierarchy keymaps', has_map('<leader>ts') and has_map('<leader>tu'))
  check('call hierarchy keymaps', has_map('<leader>ci') and has_map('<leader>co'))
  check('workspace symbol keymap', has_map('<leader>ws'))

  -- CursorHold asks for the highlight; the request itself is Neovim's, so stub the entry point.
  local highlighted, cleared = 0, 0
  local real_dh, real_cr = vim.lsp.buf.document_highlight, vim.lsp.buf.clear_references
  vim.lsp.buf.document_highlight = function() highlighted = highlighted + 1 end
  vim.lsp.buf.clear_references = function() cleared = cleared + 1 end
  vim.api.nvim_exec_autocmds('CursorHold', { buffer = ed_buf })
  vim.api.nvim_exec_autocmds('CursorMoved', { buffer = ed_buf })
  vim.lsp.buf.document_highlight, vim.lsp.buf.clear_references = real_dh, real_cr
  check('CursorHold highlights, CursorMoved clears', highlighted == 1 and cleared == 1, highlighted .. '/' .. cleared)

  -- Typing `(` or `,` opens the signature popup; typing a letter does not. `v:char` is what
  -- InsertCharPre reads, and it is writable outside the event, so the event is raised by hand
  -- rather than through insert mode, which swallows headless output.
  local sig_calls = 0
  local real_sh = vim.lsp.buf.signature_help
  vim.lsp.buf.signature_help = function() sig_calls = sig_calls + 1 end
  local function type_char(c)
    vim.v.char = c
    vim.api.nvim_exec_autocmds('InsertCharPre', { buffer = ed_buf })
    vim.wait(100, function() return false end)
  end
  type_char('(')
  check('`(` triggers signature help', sig_calls == 1, tostring(sig_calls))
  type_char('x')
  check('a letter does not', sig_calls == 1, tostring(sig_calls))
  type_char(',')
  check('`,` retriggers', sig_calls == 2, tostring(sig_calls))
  vim.lsp.buf.signature_help = real_sh

  -- `keymaps = false` keeps the <leader> namespace untouched but leaves the features reachable.
  local plain = vim.api.nvim_create_buf(false, true)
  vim.bo[plain].filetype = 'java'
  editor.setup_keymaps(ed_client, plain, { keymaps = false })
  check('keymaps = false installs nothing', #vim.api.nvim_buf_get_keymap(plain, 'n') == 0)
  editor.setup_document_highlight(ed_client, plain, { document_highlight = false })
  check('document_highlight = false installs nothing', not (function()
    local ok, cmds = pcall(vim.api.nvim_get_autocmds, { group = 'IntellijLspDocumentHighlight' .. plain })
    return ok and #cmds > 0
  end)())

  vim.lsp.stop_client(ed_id, true)
end

-- The commands exist independently of any attached buffer.
editor.register_commands()
local cmds = vim.api.nvim_get_commands({})
for _, name in ipairs({ 'IntellijLspTypeHierarchy', 'IntellijLspCallHierarchy', 'IntellijLspFormat', 'IntellijLspSymbols' }) do
  check(':' .. name .. ' registered', cmds[name] ~= nil)
end
check(':IntellijLspFormat takes a range', cmds.IntellijLspFormat.range ~= nil and cmds.IntellijLspFormat.range ~= '')

-- Direction arguments are validated rather than passed through to a confusing LSP error.
local real_th = vim.lsp.buf.typehierarchy
local th_kind
vim.lsp.buf.typehierarchy = function(k) th_kind = k end
editor.type_hierarchy('')
check('type hierarchy defaults to subtypes', th_kind == 'subtypes', tostring(th_kind))
editor.type_hierarchy('supertypes')
check('type hierarchy forwards supertypes', th_kind == 'supertypes')
th_kind = nil
editor.type_hierarchy('sideways')
check('type hierarchy rejects an unknown direction', th_kind == nil)
vim.lsp.buf.typehierarchy = real_th

local real_in, real_out = vim.lsp.buf.incoming_calls, vim.lsp.buf.outgoing_calls
local ch_kind
vim.lsp.buf.incoming_calls = function() ch_kind = 'incoming' end
vim.lsp.buf.outgoing_calls = function() ch_kind = 'outgoing' end
editor.call_hierarchy(nil)
check('call hierarchy defaults to incoming', ch_kind == 'incoming')
editor.call_hierarchy('outgoing')
check('call hierarchy forwards outgoing', ch_kind == 'outgoing')
vim.lsp.buf.incoming_calls, vim.lsp.buf.outgoing_calls = real_in, real_out

-- Formatting is pinned to our client by name, so a second formatter on the buffer is left alone.
local real_fmt = vim.lsp.buf.format
local fmt_opts
vim.lsp.buf.format = function(o) fmt_opts = o end
editor.format({ bufnr = ed_buf })
check('format addresses the intellij client only', fmt_opts and fmt_opts.name == 'intellij' and fmt_opts.range == nil, vim.inspect(fmt_opts))
vim.api.nvim_buf_set_lines(ed_buf, 0, -1, false, { 'a', 'bb', 'ccc' })
editor.format({ bufnr = ed_buf, line1 = 2, line2 = 3 })
check('format with a range covers the given lines', fmt_opts.range and fmt_opts.range['start'][1] == 2 and fmt_opts.range['end'][1] == 3 and fmt_opts.range['end'][2] == 3, vim.inspect(fmt_opts and fmt_opts.range))
vim.lsp.buf.format = real_fmt

-- asIs snippet completions: the line's own indentation comes off every continuation line, because
-- vim.snippet.expand adds it back. Plain-text, single-line and adjustIndentation items are untouched.
local ai_buf = vim.api.nvim_create_buf(false, true)
vim.api.nvim_buf_set_lines(ai_buf, 0, -1, false, { '\t\towner.getPets().for' })
local function ai_item(mode, fmt, text)
  return { insertTextMode = mode, insertTextFormat = fmt, textEdit = { newText = text,
    range = { start = { line = 0, character = 2 }, ['end'] = { line = 0, character = 19 } } } }
end
local ai_result = { items = {
  ai_item(1, 2, 'for (Pet ${1:pet} : owner.getPets()) {\n\t\t\t${0}\n\t\t\\}'),
  ai_item(1, 1, 'a\n\t\tb'),
  ai_item(2, 2, 'a\n\t\tb'),
  ai_item(1, 2, 'one line'),
  ai_item(1, 2, 'a\n\tshallower'),
} }
client.rebase_as_is_indent(ai_result, ai_buf)
local ai = vim.tbl_map(function(i) return i.textEdit.newText end, ai_result.items)
check('asIs snippet loses the base indent once', ai[1] == 'for (Pet ${1:pet} : owner.getPets()) {\n\t${0}\n\\}', ai[1])
check('asIs plain text is left alone', ai[2] == 'a\n\t\tb', ai[2])
check('adjustIndentation is left alone', ai[3] == 'a\n\t\tb', ai[3])
check('single-line snippet is left alone', ai[4] == 'one line', ai[4])
check('a line shallower than the base is left alone', ai[5] == 'a\n\tshallower', ai[5])
local ai_default = { itemDefaults = { insertTextMode = 1 }, items = { ai_item(nil, 2, 'x\n\t\t\ty') } }
client.rebase_as_is_indent(ai_default, ai_buf)
check('asIs from itemDefaults counts', ai_default.items[1].textEdit.newText == 'x\n\ty', ai_default.items[1].textEdit.newText)

-- The response fixes run on callers' own callbacks, which is how vim.lsp.completion and 0.12's
-- vim.lsp.codelens call: a handler-table entry would never see those responses.
local rf_replies = {
  ['textDocument/codeLens'] = { { range = {}, command = { title = '$(play) Run' } } },
  ['textDocument/hover'] = { contents = '$(play) untouched' },
}
local rf_client = { handlers = {}, request = function(_, method, _, h) h(nil, rf_replies[method], {}) return true, 1 end }
client.install_response_fixes(rf_client)
local rf_lens, rf_hover
rf_client:request('textDocument/codeLens', {}, function(_, r) rf_lens = r end, 0)
rf_client:request('textDocument/hover', {}, function(_, r) rf_hover = r end, 0)
check('lens codicons stripped on a caller callback', rf_lens and rf_lens[1].command.title == 'Run', vim.inspect(rf_lens))
local function rng(l, a, b) return { start = { line = l, character = a }, ['end'] = { line = l, character = b } } end
local calls = { { from = { name = 'f' }, fromRanges = { rng(66, 6, 35), rng(66, 6, 35), rng(70, 1, 2), rng(66, 6, 35) } } }
client.dedupe_call_ranges(calls)
check('call hierarchy keeps one row per call site', #calls[1].fromRanges == 2 and calls[1].fromRanges[2].start.line == 70, vim.inspect(calls[1].fromRanges))
check('other methods pass through untouched', rf_hover and rf_hover.contents == '$(play) untouched', vim.inspect(rf_hover))

print(failures == 0 and '\nALL UNIT CHECKS PASSED' or ('\n' .. failures .. ' UNIT CHECK(S) FAILED'))
vim.cmd(failures == 0 and 'qa!' or 'cq!')
