--- Repository state, from `git status --porcelain=v2 -z`.
---
--- v2 rather than v1, and `-z` rather than newlines, for reasons that both show up as data loss
--- rather than as a parse error:
---
---   * v1 reports a rename as `R  new -> old` with no similarity score and no way to tell a literal
---     " -> " inside a filename from the separator. v2 gives the score and puts the two paths in
---     distinct fields.
---   * Without `-z`, git quotes any path containing a space, a quote or a byte above 0x7f and escapes
---     it in octal, so the parser would need a C-string unescaper to open `Ünicode.java`. With `-z`
---     (plus `core.quotepath=false`, set in cmd.lua) paths arrive raw.
---
--- The framing trap, and the reason this file has a test suite of its own: **under `-z` a rename
--- record's two paths are separated by a NUL, not a tab.** So a record is not simply "the text
--- between two NULs" -- a `2` record consumes the *following* field as its origin path. Split naively
--- and every rename injects a phantom entry and shifts the remainder of the list, which presents as
--- unrelated files showing the wrong status rather than as an obvious failure.

local M = {}

--- Which side of the index a change is on.
---
--- git reports two independent status characters per entry -- staged (index vs HEAD) and unstaged
--- (working tree vs index) -- and a file can be in both at once: stage a change, edit it again, and
--- it is simultaneously `M` staged and `M` unstaged. The panel therefore lists such a file twice,
--- once per side, because they are separately stageable.
M.STAGED = 'staged'
M.UNSTAGED = 'unstaged'
M.UNTRACKED = 'untracked'
M.CONFLICTED = 'conflicted'

--- Human labels for git's status codes.
local CODE_LABEL = {
  M = 'modified',
  T = 'typechange',
  A = 'added',
  D = 'deleted',
  R = 'renamed',
  C = 'copied',
  U = 'unmerged',
  ['?'] = 'untracked',
}

--- @param code string single git status character
--- @return string
function M.label(code)
  return CODE_LABEL[code] or code
end

--- Splits `-z` output into logical records, re-joining the two halves of a rename.
---
--- Returns records in git's own order, each still a raw string, with a rename's origin path appended
--- after a tab so downstream parsing sees one field-delimited line. The tab is safe as a joiner here
--- and nowhere else: it is the separator git itself uses in the non-`-z` form, and a path containing a
--- literal tab is re-split correctly because the origin is taken as everything after the *last* tab.
--- @param records string[] NUL-split fields
--- @return string[]
local function reframe(records)
  local out = {}
  local i = 1
  while i <= #records do
    local rec = records[i]
    -- A `2` record (rename/copy) is the only kind that spans two NUL-separated fields.
    if rec:sub(1, 2) == '2 ' then
      local origin = records[i + 1]
      if origin then
        out[#out + 1] = rec .. '\t' .. origin
        i = i + 2
      else
        -- Truncated output: keep the record rather than dropping it, so a partial read degrades to a
        -- rename with no origin instead of losing the file entirely.
        out[#out + 1] = rec
        i = i + 1
      end
    else
      out[#out + 1] = rec
      i = i + 1
    end
  end
  return out
end

--- Parses one entry record into zero or more panel entries.
---
--- Zero is a real outcome: an ordinary `1` record whose staged and unstaged codes are both `.` cannot
--- occur in practice, but a defensive parser must not emit an entry with no change to show.
--- @param rec string
--- @return table[]
local function parse_entry(rec)
  local kind = rec:sub(1, 1)

  -- `? path` -- untracked. Also `! path` for ignored, which we never request.
  if kind == '?' then
    return { { side = M.UNTRACKED, code = '?', path = rec:sub(3) } }
  end
  if kind == '!' then
    return {}
  end

  -- `u <XY> <sub> <m1> <m2> <m3> <mW> <h1> <h2> <h3> <path>` -- unmerged. Four mode fields and three
  -- object ids, unlike the two/one of an ordinary entry, which is why this is matched before `1`.
  if kind == 'u' then
    local xy, path = rec:match('^u (%S%S) %S+ %S+ %S+ %S+ %S+ %S+ %S+ %S+ (.+)$')
    if not xy then return {} end
    return { { side = M.CONFLICTED, code = 'U', xy = xy, path = path } }
  end

  -- `1 <XY> <sub> <mH> <mI> <mW> <hH> <hI> <path>`
  -- `2 <XY> <sub> <mH> <mI> <mW> <hH> <hI> <score> <path>\t<origin>`
  local staged, unstaged, rest
  if kind == '1' then
    staged, unstaged, rest = rec:match('^1 (%S)(%S) %S+ %S+ %S+ %S+ %S+ %S+ (.+)$')
  elseif kind == '2' then
    staged, unstaged, rest = rec:match('^2 (%S)(%S) %S+ %S+ %S+ %S+ %S+ %S+ %S+ (.+)$')
  else
    return {}
  end
  if not staged then return {} end

  local path, origin = rest, nil
  if kind == '2' then
    -- Last tab, not first: the *origin* is the appended half, and a path may itself contain a tab.
    local at = rest:find('\t[^\t]*$')
    if at then
      path = rest:sub(1, at - 1)
      origin = rest:sub(at + 1)
    end
  end

  local out = {}
  -- Order matters for the panel: staged first, matching how the IDE and `git status` both present it.
  if staged ~= '.' then
    out[#out + 1] = { side = M.STAGED, code = staged, path = path, origin = origin }
  end
  if unstaged ~= '.' then
    -- The unstaged half of a rename is a modification of the *new* path; the origin belongs to the
    -- staged half only, so it is deliberately not carried over.
    out[#out + 1] = { side = M.UNSTAGED, code = unstaged, path = path }
  end
  return out
end

--- Parses `git status --porcelain=v2 --branch -z` output.
--- @param stdout string raw, NUL-separated
--- @return table state { branch, oid, upstream, ahead, behind, detached, entries }
function M.parse(stdout)
  local state = {
    branch = nil,
    oid = nil,
    upstream = nil,
    ahead = 0,
    behind = 0,
    detached = false,
    entries = {},
  }

  for _, rec in ipairs(reframe(vim.split(stdout or '', '\0', { plain = true }))) do
    if rec == '' then goto continue end

    if rec:sub(1, 2) == '# ' then
      local key, value = rec:match('^# (%S+) (.*)$')
      if key == 'branch.head' then
        -- git writes the literal "(detached)" here, which is not a branch name.
        if value == '(detached)' then
          state.detached = true
        else
          state.branch = value
        end
      elseif key == 'branch.oid' then
        -- "(initial)" before the first commit; left as nil rather than stored as a fake oid.
        if value ~= '(initial)' then state.oid = value end
      elseif key == 'branch.upstream' then
        state.upstream = value
      elseif key == 'branch.ab' then
        local ahead, behind = value:match('^%+(%d+) %-(%d+)$')
        state.ahead = tonumber(ahead) or 0
        state.behind = tonumber(behind) or 0
      end
    else
      vim.list_extend(state.entries, parse_entry(rec))
    end

    ::continue::
  end

  return state
end

--- Counts entries per side.
--- @param state table
--- @return table<string, integer>
function M.counts(state)
  local counts = { [M.STAGED] = 0, [M.UNSTAGED] = 0, [M.UNTRACKED] = 0, [M.CONFLICTED] = 0 }
  for _, entry in ipairs(state.entries or {}) do
    counts[entry.side] = (counts[entry.side] or 0) + 1
  end
  return counts
end

--- Whether anything at all is reported.
--- @param state table
--- @return boolean
function M.is_clean(state)
  return #(state.entries or {}) == 0
end

--- One-line summary for the panel title.
--- @param state table
--- @return string
function M.summary(state)
  local parts = {}
  parts[#parts + 1] = state.detached and 'HEAD (detached)' or (state.branch or '(no branch)')

  if state.upstream then
    local track = {}
    if state.ahead > 0 then track[#track + 1] = '↑' .. state.ahead end
    if state.behind > 0 then track[#track + 1] = '↓' .. state.behind end
    parts[#parts + 1] = state.upstream .. (#track > 0 and (' ' .. table.concat(track, ' ')) or '')
  else
    parts[#parts + 1] = 'no upstream'
  end

  local counts = M.counts(state)
  local changes = {}
  if counts[M.CONFLICTED] > 0 then changes[#changes + 1] = counts[M.CONFLICTED] .. ' conflicted' end
  if counts[M.STAGED] > 0 then changes[#changes + 1] = counts[M.STAGED] .. ' staged' end
  if counts[M.UNSTAGED] > 0 then changes[#changes + 1] = counts[M.UNSTAGED] .. ' unstaged' end
  if counts[M.UNTRACKED] > 0 then changes[#changes + 1] = counts[M.UNTRACKED] .. ' untracked' end
  parts[#parts + 1] = #changes > 0 and table.concat(changes, ', ') or 'clean'

  return table.concat(parts, '  ·  ')
end

--- In-progress operation, read from the git directory rather than remembered.
---
--- State on disk is the only reliable source: an interactive rebase outlives the Neovim session that
--- started it, and the user may equally have started it in a terminal. Anything cached in Lua would
--- be wrong after a restart, which is exactly when `:IntellijGitStatus` matters most.
---
--- `rebase-merge` covers `rebase -i` and `rebase -m`; `rebase-apply` covers the older `am`-based
--- rebase and `git am` itself, distinguished by the `applying` marker file.
--- @param root string repository root
--- @return string|nil one of "merge", "rebase", "cherry-pick", "revert", "am", "bisect"
function M.in_progress(root)
  local git_dir = root .. '/.git'
  -- A worktree or submodule has a `.git` *file* pointing elsewhere, so the real directory is asked
  -- for rather than assumed. Only done when the fast path fails, to keep the common case cheap.
  if vim.fn.isdirectory(git_dir) == 0 then
    local cmd = require('intellij-lsp.git.cmd')
    local res = cmd.run_sync({ 'rev-parse', '--absolute-git-dir' }, { cwd = root })
    if not res.ok then return nil end
    git_dir = vim.split(res.stdout, '\n', { trimempty = true })[1] or git_dir
  end

  local function exists(rel)
    return vim.uv.fs_stat(git_dir .. '/' .. rel) ~= nil
  end

  if exists('rebase-merge') or exists('rebase-apply') then
    -- `git am` leaves an `applying` marker; a rebase does not.
    if exists('rebase-apply/applying') then return 'am' end
    return 'rebase'
  end
  -- Checked after rebase: a conflicted `rebase -i` also writes MERGE_HEAD, and reporting "merge"
  -- there would send the user to `git merge --abort`, which fails and leaves the rebase stuck.
  if exists('CHERRY_PICK_HEAD') then return 'cherry-pick' end
  if exists('REVERT_HEAD') then return 'revert' end
  if exists('MERGE_HEAD') then return 'merge' end
  if exists('BISECT_LOG') then return 'bisect' end
  return nil
end

--- Fetches and parses repository state.
--- @param root string
--- @param on_done fun(state: table|nil, err: string|nil)
function M.fetch(root, on_done)
  local cmd = require('intellij-lsp.git.cmd')
  -- `--untracked-files=all` rather than the default `normal`: the default collapses an untracked
  -- directory to a single entry, so a new package shows as `src/main/java/com/` and the files inside
  -- it cannot be staged individually from the panel.
  cmd.run({ 'status', '--porcelain=v2', '--branch', '--untracked-files=all', '-z' }, { cwd = root },
    function(res)
      if not res.ok then
        on_done(nil, cmd.error_message(res))
        return
      end
      local state = M.parse(res.stdout)
      state.root = root
      state.in_progress = M.in_progress(root)
      on_done(state, nil)
    end)
end

M._reframe = reframe
M._parse_entry = parse_entry

return M
