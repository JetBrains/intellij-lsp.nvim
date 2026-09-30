--- Branch list and checkout.
---
--- `for-each-ref` in one call rather than N `rev-parse`es: measured at <0.01s for this repo's 268
--- local+remote refs, so the whole list is one cheap query.
---
--- The checkout behaviour is the part worth knowing, because it is not what it looks like. Git does
--- *not* generally refuse to switch branches with a dirty tree -- it carries local modifications across
--- whenever the file does not differ between the two branches, and refuses only when the switch would
--- overwrite them. Both outcomes therefore need handling: the success path has to say that changes
--- came along (otherwise the user thinks they were lost), and the refusal path has to report git's own
--- message rather than a guess.

local cmd = require('intellij-lsp.git.cmd')

local M = {}

local US = '\31'

M.LOCAL = 'local'
M.REMOTE = 'remote'

--- @class IntellijGitBranch
--- @field name string        short name, e.g. "main" or "origin/main"
--- @field refname string     full ref, e.g. "refs/heads/main"
--- @field kind string        M.LOCAL | M.REMOTE
--- @field current boolean    is HEAD
--- @field upstream string|nil
--- @field track string|nil   e.g. "[ahead 2, behind 1]"
--- @field date string        relative committer date
--- @field short string       abbreviated object name
--- @field subject string     tip commit subject

local FIELDS = {
  'refname:short',
  'refname',
  'upstream:short',
  'upstream:track',
  'HEAD',
  'committerdate:relative',
  'objectname:short',
  'contents:subject',
}

--- @return string[]
function M.args()
  return {
    'for-each-ref',
    '--format=' .. table.concat(vim.tbl_map(function(f) return '%(' .. f .. ')' end, FIELDS), US),
    -- Sorted so the most recently touched branches come first, which is almost always what you want
    -- in a repo with hundreds of them.
    '--sort=-committerdate',
    'refs/heads',
    'refs/remotes',
  }
end

--- Parses `for-each-ref` output.
--- @param stdout string
--- @return IntellijGitBranch[]
function M.parse(stdout)
  local out = {}
  for _, line in ipairs(vim.split(stdout or '', '\n', { trimempty = true })) do
    local f = vim.split(line, US, { plain = true })
    if f[1] and f[1] ~= '' then
      local refname = f[2] or ''
      -- A remote's symbolic HEAD points at another branch and would detach HEAD if checked out, so it
      -- is excluded. Matched on the **full** refname, not the short one: git abbreviates
      -- `refs/remotes/origin/HEAD` to plain `origin`, so a `/HEAD$`
      -- test on the short name misses it and the remote shows up in the list as a bogus branch called
      -- `origin`.
      local is_symbolic = refname:match('^refs/remotes/[^/]+/HEAD$') ~= nil
        or refname:match('/HEAD$') ~= nil
      if not is_symbolic then
        out[#out + 1] = {
          name = f[1],
          refname = refname,
          kind = refname:sub(1, 13) == 'refs/remotes/' and M.REMOTE or M.LOCAL,
          -- git writes a literal '*' in the HEAD column for the checked-out branch.
          current = (f[5] or ''):find('%*') ~= nil,
          upstream = (f[3] or '') ~= '' and f[3] or nil,
          track = (f[4] or '') ~= '' and f[4] or nil,
          date = f[6] or '',
          short = f[7] or '',
          subject = f[8] or '',
        }
      end
    end
  end
  return out
end

--- The current branch, or nil when HEAD is detached.
---
--- Detached HEAD is a real state that must be distinguished rather than shown as "no branch": no ref
--- carries the `*` marker, and `rev-parse --abbrev-ref HEAD` answers with the literal string `HEAD`.
--- @param list IntellijGitBranch[]
--- @return IntellijGitBranch|nil
function M.current(list)
  for _, b in ipairs(list or {}) do
    if b.current then return b end
  end
  return nil
end

--- Fetches the branch list.
--- @param root string
--- @param on_done fun(list: IntellijGitBranch[]|nil, err: string|nil)
function M.fetch(root, on_done)
  cmd.run(M.args(), { cwd = root }, function(res)
    if not res.ok then
      on_done(nil, cmd.error_message(res))
      return
    end
    on_done(M.parse(res.stdout), nil)
  end)
end

--- Checkout arguments for a branch.
---
--- A remote branch cannot be checked out by name without detaching HEAD, so `--track` is used to create
--- a local branch of the same short name following it -- which is what selecting `origin/feature` in a
--- branch list is universally taken to mean. If a local branch of that name already exists, git refuses
--- and its message is reported; switching to the existing local branch is then the user's call, not
--- something to guess at.
--- @param branch IntellijGitBranch
--- @return string[]
function M.checkout_args(branch)
  if branch.kind == M.REMOTE then
    -- `origin/feature` -> `feature`
    local local_name = branch.name:gsub('^[^/]+/', '')
    return { 'checkout', '--track', '-b', local_name, branch.name }
  end
  return { 'checkout', branch.name }
end

--- Whether git's output indicates local changes were carried across the switch.
---
--- git prints the branch line on stderr and the carried files on stdout as `M\tpath` rows, so a
--- successful checkout that moved modifications looks different from a clean one. Reported explicitly
--- because a user who does not notice will think the changes were lost.
--- @param res IntellijGitResult
--- @return string[] paths
function M.carried_changes(res)
  local paths = {}
  for _, stream in ipairs({ res.stdout or '', res.stderr or '' }) do
    for _, line in ipairs(vim.split(stream, '\n', { trimempty = true })) do
      local code, path = line:match('^(%a)\t(.+)$')
      if code and path then paths[#paths + 1] = path end
    end
  end
  return paths
end

--- Checks out `branch`.
--- @param root string
--- @param branch IntellijGitBranch
--- @param on_done fun(ok: boolean, message: string)
function M.checkout(root, branch, on_done)
  if branch.current then
    on_done(true, ('already on %s'):format(branch.name))
    return
  end

  cmd.run(M.checkout_args(branch), { cwd = root }, function(res)
    if not res.ok then
      -- git's own message is far more useful than anything synthesized: it names the files that would
      -- be overwritten, which is exactly what the user needs to decide what to do.
      on_done(false, cmd.error_message(res))
      return
    end

    local carried = M.carried_changes(res)
    if #carried > 0 then
      on_done(true, ('switched to %s; %d local change(s) came along: %s')
        :format(branch.name, #carried, table.concat(carried, ', ')))
    else
      on_done(true, 'switched to ' .. branch.name)
    end
  end)
end

M.US = US

return M
