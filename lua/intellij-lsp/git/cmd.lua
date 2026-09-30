--- Running `git`.
---
--- Every git call in this plugin goes through here, so the flags that must never be forgotten are
--- applied in one place rather than at ~30 call sites.
---
--- Async by default. `git status` on a large repository takes long enough to be felt, and `push`
--- takes seconds, so a blocking call would freeze the editor. `run_sync` exists for the tests and
--- for the two cases (repo root, in-progress state) where the answer is needed to decide what to
--- draw next.

local M = {}

--- Flags prepended to every invocation.
---
--- `core.quotepath=false` is the load-bearing one: by default git renders any byte above 0x7f as an
--- octal escape inside double quotes, so `Ünicode.java` arrives as `"\303\234nicode.java"`. That is
--- a second, entirely separate unescaping problem on top of the `-z` framing, and skipping it means
--- every non-ASCII path silently fails to open. Turning it off makes git emit raw UTF-8, which is
--- what Neovim wants anyway.
---
--- `--no-optional-locks` keeps a background `status` from taking the index lock. Without it a status
--- refresh can race a `git commit` the user is running in a terminal and make one of them fail.
local GLOBAL_ARGS = { '--no-optional-locks', '-c', 'core.quotepath=false' }

--- Environment additions for every invocation.
---
--- The three editor variables are the reason a naive `vim.system({'git', ...})` hangs instead of
--- failing: git spawns `$GIT_EDITOR` for a commit message, a rebase todo list or a tag annotation,
--- and with no tty it inherits ours and blocks forever with no output. Pointing them at `true` makes
--- git take the "editor exited without changing anything" path, which is a clean, reportable failure.
--- Commands that legitimately need an editor (interactive rebase, Phase 4) override these per-call.
---
--- `GIT_TERMINAL_PROMPT=0` is the same idea for credentials: it turns a blocking username prompt into
--- a non-zero exit with a message we can show. Real authentication is expected to come from a
--- credential helper or an SSH agent.
local BASE_ENV = {
  GIT_EDITOR = 'true',
  GIT_SEQUENCE_EDITOR = 'true',
  GIT_TERMINAL_PROMPT = '0',
  -- Locale-independent output. Callers match on git's own English words ("nothing to commit"), so a
  -- German or Japanese locale must not change them.
  LC_ALL = 'C',
  GIT_PAGER = 'cat',
  PAGER = 'cat',
}

--- @class IntellijGitResult
--- @field code integer          exit status
--- @field stdout string         raw stdout, undecoded
--- @field stderr string         raw stderr
--- @field ok boolean            code == 0
--- @field lines fun():string[]  stdout split on newlines, trailing blank dropped
--- @field records fun():string[] stdout split on NUL, trailing blank dropped

--- @param out table result of vim.system
--- @return IntellijGitResult
local function wrap(out)
  local stdout = out.stdout or ''
  return {
    code = out.code,
    stdout = stdout,
    stderr = out.stderr or '',
    ok = out.code == 0,
    lines = function() return vim.split(stdout, '\n', { trimempty = true }) end,
    -- Deliberately not `trimempty`: with `-z` an empty field between two NULs is meaningful in some
    -- git output, so only the single trailing terminator is dropped.
    records = function()
      local recs = vim.split(stdout, '\0', { plain = true })
      if recs[#recs] == '' then table.remove(recs) end
      return recs
    end,
  }
end

--- Full environment for a git subprocess.
---
--- Returns the complete environment rather than an overlay, and **must be passed with
--- `clear_env = true`** -- see `M.run`. `vim.system` merges `env` over the inherited environment, so
--- leaving a variable out of this table does not unset it in the child; only clearing first does.
---
--- What that protects: if Neovim was launched from a git hook, a `git rebase --exec`, or a terminal
--- where someone exported `GIT_DIR`, then every command here would silently operate on *that*
--- repository instead of the one the user is looking at. The failure is invisible -- git succeeds, on
--- the wrong repo -- which is why this is stripped rather than merely documented.
--- @param extra table<string, string>|nil per-call overrides
--- @return table<string, string>
function M.env(extra)
  local env = {}
  for key, value in pairs(vim.fn.environ()) do
    env[key] = value
  end
  env.GIT_DIR = nil
  env.GIT_WORK_TREE = nil
  env.GIT_INDEX_FILE = nil

  for key, value in pairs(BASE_ENV) do
    env[key] = value
  end
  for key, value in pairs(extra or {}) do
    env[key] = value
  end
  return env
end

--- Argument vector for a git call, including the global flags.
--- @param args string[]
--- @return string[]
function M.argv(args)
  local argv = { 'git' }
  vim.list_extend(argv, GLOBAL_ARGS)
  vim.list_extend(argv, args)
  return argv
end

--- Runs git asynchronously.
---
--- `on_done` is invoked on the main loop via `vim.schedule`, so it may call the API freely -- a
--- `vim.system` callback otherwise runs on the libuv thread where most of `nvim_*` is illegal.
--- @param args string[] git arguments, without the leading "git"
--- @param opts { cwd?: string, env?: table<string,string>, stdin?: string, timeout?: integer }|nil
--- @param on_done fun(res: IntellijGitResult)
function M.run(args, opts, on_done)
  opts = opts or {}
  -- Same guard as run_sync: a missing cwd raises out of vim.system rather than being reported, and
  -- here it would escape from whichever autocmd or keymap started the call. Answered on the next tick
  -- so the callback is always asynchronous, whether it failed to spawn or not -- a callback that
  -- sometimes runs inline is a re-entrancy bug waiting to happen in the panel's refresh path.
  local ok, err = pcall(vim.system, M.argv(args), {
    cwd = opts.cwd,
    env = M.env(opts.env),
    -- Load-bearing, not tidiness. Without it `env` is *merged over* the inherited environment, so an
    -- inherited GIT_DIR survives being omitted from the table and silently redirects this command at
    -- another repository. `M.env` returns a complete environment, so clearing loses nothing.
    clear_env = true,
    stdin = opts.stdin,
    timeout = opts.timeout,
    text = false,
  }, function(out)
    vim.schedule(function() on_done(wrap(out)) end)
  end)
  if not ok then
    vim.schedule(function()
      on_done(wrap({ code = 128, stdout = '', stderr = tostring(err) }))
    end)
  end
end

--- Runs git and blocks.
---
--- Only for calls that are cheap and whose answer decides what to render (`rev-parse`, reading
--- in-progress state). The timeout is a backstop: a `git` that blocks on a lock would otherwise hang
--- the editor with no way out.
--- @param args string[]
--- @param opts { cwd?: string, env?: table<string,string>, stdin?: string, timeout?: integer }|nil
--- @return IntellijGitResult
function M.run_sync(args, opts)
  opts = opts or {}
  -- `vim.system` *raises* on a cwd that does not exist rather than reporting it through the result,
  -- and a deleted or renamed directory is entirely ordinary -- a buffer whose file was moved, a
  -- worktree pruned by someone else. Left unguarded that error propagates out of whatever autocmd or
  -- keymap called us, so it is converted into the failed result every caller already handles.
  local ok, proc = pcall(vim.system, M.argv(args), {
    cwd = opts.cwd,
    env = M.env(opts.env),
    -- See M.run: omitting a variable from `env` does not unset it in the child.
    clear_env = true,
    stdin = opts.stdin,
    text = false,
  })
  if not ok then
    return wrap({ code = 128, stdout = '', stderr = tostring(proc) })
  end
  return wrap(proc:wait(opts.timeout or 10000))
end

--- Repository root for a path already known to belong to one of our own views.
---
--- Set by `session.open` and read by `M.root` before it falls back to the current buffer. This exists
--- because the plugin's own list buffers (`intellij-git://log`, `.../branches`, ...) have no file on
--- disk: opening the branch list *from* the log view would otherwise resolve the root from a scratch
--- buffer, fall through to the working directory, and report "not inside a git repository" for a
--- session that plainly is in one.
--- @type table<integer, string>
M.buffer_roots = {}

--- Records the repository a plugin-owned buffer belongs to.
--- @param bufnr integer
--- @param root string
function M.set_buffer_root(bufnr, root)
  M.buffer_roots[bufnr] = root
  -- Cleaned up with the buffer, so a long session does not accumulate entries for wiped scratches.
  vim.api.nvim_create_autocmd({ 'BufWipeout', 'BufDelete' }, {
    buffer = bufnr,
    once = true,
    desc = 'IntelliJ git: forget this buffer\'s repository root',
    callback = function() M.buffer_roots[bufnr] = nil end,
  })
end

--- Repository root containing `path`, or nil.
---
--- `--show-toplevel` rather than `--git-dir`: it answers with the work tree, which is what every
--- other command here wants as its `cwd`, and it fails cleanly inside a bare repository (where there
--- is nothing to stage or commit) instead of returning a path with no working files.
--- @param path string|nil defaults to the current buffer's root, then its directory, then cwd
--- @return string|nil
function M.root(path)
  local dir = path
  if not dir then
    -- A plugin-owned list buffer knows its repository; consulting that first is what lets one view
    -- open another.
    local known = M.buffer_roots[vim.api.nvim_get_current_buf()]
    if known then return known end

    local name = vim.api.nvim_buf_get_name(0)
    -- A non-empty name is not necessarily a path. Our own scratch buffers are named
    -- `intellij-git://preview/3`, and `dirname` on that yields `intellij-git:/` -- a directory that
    -- does not exist, so git fails and the caller reports "not inside a git repository" while sitting
    -- in a perfectly good working directory. The name is therefore used only when it resolves to a
    -- real directory on disk; otherwise fall through to cwd.
    local from_name
    if name ~= '' then
      local parent = vim.fs.dirname(name)
      if parent and vim.fn.isdirectory(parent) == 1 then from_name = parent end
    end
    dir = from_name or vim.uv.cwd()
  end
  if not dir or dir == '' then return nil end

  local res = M.run_sync({ 'rev-parse', '--show-toplevel' }, { cwd = dir })
  if not res.ok then return nil end
  local root = vim.split(res.stdout, '\n', { trimempty = true })[1]
  if not root or root == '' then return nil end

  -- Resolved, not merely normalized. `vim.fs.normalize` collapses `..` and `~` but does not follow
  -- symlinks, and git answers `--show-toplevel` with the *resolved* path -- so on macOS a repository
  -- reached as `/tmp/x` or `$TMPDIR/x` comes back as `/private/var/...`. Returning that unresolved
  -- would make the root compare unequal to the caller's own path, which is how a "not inside a git
  -- repository" warning appears for a directory that plainly is one.
  return vim.fs.normalize(vim.uv.fs_realpath(root) or root)
end

--- A one-line error message for a failed result.
---
--- git writes diagnostics to stderr but not always: `push` reports rejections on stderr while
--- `commit` reports "nothing to commit" on stdout, so both are consulted before falling back to the
--- exit code -- an error with an empty message reads as the feature silently doing nothing.
--- @param res IntellijGitResult
--- @return string
function M.error_message(res)
  for _, stream in ipairs({ res.stderr, res.stdout }) do
    local line = vim.split(stream or '', '\n', { trimempty = true })[1]
    if line and line ~= '' then return line end
  end
  return 'git exited with code ' .. tostring(res.code)
end

return M
