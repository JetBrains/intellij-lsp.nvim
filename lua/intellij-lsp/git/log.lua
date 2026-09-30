--- Commit log, from `git log --graph` with a sentinel-prefixed format.
---
--- Letting git draw the graph is a deliberate choice: the IDE's own lane layout is a large, complex
--- engine, and `--graph` is correct by construction for any topology. The cost is monochrome ASCII
--- lanes instead of coloured tracks.
---
--- The parsing trick, and the reason this module exists rather than a one-line format string: putting
--- the unit separator *first* in the format makes git's drawn prefix exactly "everything before the
--- first US byte", so the graph and the commit fields can be recovered from one stream:
---
---     *   <US>b6b9510<US>HEAD -> main<US>merge feature
---     |\
---     | * <US>4142b3e<US>feature<US>feature 2
---     * | <US>a776a48<US><US>main 3
---     |/
---
--- Two consequences that a naive parser gets wrong, both visible above:
---
---   * **Graph-only lines carry no US at all.** `|\`, `|/` and `| |` are decoration, not commits, so a
---     row->commit map is required; the row under the cursor may be no commit.
---   * **Graph prefixes carry trailing whitespace**, which is column alignment and must be preserved
---     in the rendered line, but is not part of any field.
---
--- A commit subject may itself contain a US byte, so fields are split with a **field count limit** --
--- splitting greedily would let a crafted subject shift every field after it, the same class of bug as
--- Phase 1's NUL-framed renames.

local cmd = require('intellij-lsp.git.cmd')

local M = {}

--- Unit separator. Chosen because it cannot appear in a hash, a ref name, an author name or a date,
--- and is vanishingly rare in a subject -- and the one place it can appear (the subject) is the last
--- field, so a limit-aware split contains the damage.
local US = '\31'

--- How many commits to request per page.
---
--- On a large history the fixed cost of the call dominates the page size, so there is nothing to
--- gain from a smaller page. Unbounded, the same query can run for minutes and emit millions of
--- lines -- which is why `args` never omits `-n`.
M.PAGE_SIZE = 500

--- Fields requested, in order. `%D` (ref names) is deliberately the second-to-last: it is the only
--- optional-and-possibly-empty field, and keeping it adjacent to the subject makes an empty value
--- (`<US><US>`) unambiguous.
local FIELDS = { 'H', 'h', 'an', 'ar', 'D', 's' }

--- @class IntellijGitCommit
--- @field graph string    the drawn graph prefix, whitespace preserved
--- @field hash string     full object name
--- @field short string    abbreviated object name
--- @field author string
--- @field date string     relative
--- @field refs string     comma-separated decorations, may be empty
--- @field subject string

--- Builds the argv for a log page.
---
--- The `-n` bound is not optional and not a tunable: on a large history, omitting it can cost
--- minutes and millions of lines. `filter.args()` supplies its own flags, and a path filter must
--- come last behind `--`, which is why the caller passes them pre-split rather than as one list.
--- @param opts { limit?: integer, skip?: integer, filter_args?: string[], path_args?: string[], range?: string }
--- @return string[]
function M.args(opts)
  opts = opts or {}
  local argv = {
    'log',
    '--graph',
    -- Guarded rather than trusted: a caller passing limit = 0 or nil must still get a bound.
    '-n', tostring(opts.limit and opts.limit > 0 and opts.limit or M.PAGE_SIZE),
    '--format=' .. US .. table.concat(vim.tbl_map(function(f) return '%' .. f end, FIELDS), US),
  }

  if opts.skip and opts.skip > 0 then
    table.insert(argv, '--skip=' .. tostring(opts.skip))
  end

  -- A revision range is a positional argument and must precede the `--` path separator.
  if opts.range and opts.range ~= '' then
    table.insert(argv, opts.range)
  end

  vim.list_extend(argv, opts.filter_args or {})

  -- `--` last, and only when there are paths: an empty `--` is harmless but a path placed before it
  -- would be read as a revision, so `git log foo` fails where `git log -- foo` succeeds.
  local paths = opts.path_args or {}
  if #paths > 0 then
    table.insert(argv, '--')
    vim.list_extend(argv, paths)
  end

  return argv
end

--- Splits a line into its graph prefix and its field payload.
---
--- Returns nil for the payload on a graph-only line, which is how the caller distinguishes decoration
--- from a commit.
--- @param line string
--- @return string graph
--- @return string|nil payload
function M.split_line(line)
  local at = line:find(US, 1, true)
  if not at then return line, nil end
  return line:sub(1, at - 1), line:sub(at + 1)
end

--- Parses a field payload into a commit.
---
--- The split is limited to `#FIELDS` pieces so a US byte inside the subject cannot shift the fields
--- before it. Lua has no limit-aware split, so the leading fields are consumed one at a time and the
--- remainder is taken whole as the subject.
--- @param payload string
--- @return IntellijGitCommit|nil
function M.parse_payload(payload)
  local values, rest = {}, payload
  for _ = 1, #FIELDS - 1 do
    local at = rest:find(US, 1, true)
    if not at then return nil end
    values[#values + 1] = rest:sub(1, at - 1)
    rest = rest:sub(at + 1)
  end
  -- Everything left is the subject, US bytes and all.
  values[#values + 1] = rest

  -- A hash is the one field that must be present and well-formed; without it the row cannot be acted
  -- on, so a malformed line is dropped rather than rendered as a commit that cannot be opened.
  if not values[1]:match('^%x+$') then return nil end

  return {
    hash = values[1],
    short = values[2],
    author = values[3],
    date = values[4],
    refs = values[5],
    subject = values[6],
  }
end

--- Parses `git log --graph` output.
---
--- Returns a flat list of rows in git's own order, each either a commit (with its graph prefix) or a
--- graph-only decoration row. The caller renders them in order and builds its row map from the
--- `commit` field being present.
--- @param stdout string
--- @return table[] rows { graph, commit? }
function M.parse(stdout)
  local rows = {}
  for _, line in ipairs(vim.split(stdout or '', '\n', { plain = true })) do
    -- git emits a trailing newline; an empty final line is not a row.
    if line ~= '' then
      local graph, payload = M.split_line(line)
      if payload then
        local commit = M.parse_payload(payload)
        -- A payload that fails to parse still had a graph prefix, so it is kept as decoration rather
        -- than dropped -- silently losing a row would misalign the lanes below it.
        rows[#rows + 1] = { graph = graph, commit = commit }
      else
        rows[#rows + 1] = { graph = graph }
      end
    end
  end
  return rows
end

--- Splits `%D` decorations into individual refs.
---
--- `HEAD -> main, origin/main, tag: v1.0` becomes three entries. The `tag: ` prefix is stripped since
--- it is a type marker rather than part of the name, but **`HEAD -> ` is kept in the rendered name**:
--- dropping it makes the checked-out branch indistinguishable from any other in the list, which is the
--- one distinction the decoration exists to draw. The `kind` field carries it too, so a renderer can
--- style it, but the text must survive for a renderer that does not.
--- @param refs string
--- @return table[] { name, kind } kind is "head" | "tag" | "remote" | "branch"
function M.parse_refs(refs)
  local out = {}
  for part in (refs or ''):gmatch('[^,]+') do
    local name = vim.trim(part)
    if name ~= '' then
      local kind = 'branch'
      if name:sub(1, 8) == 'HEAD -> ' then
        -- Name left intact, including the arrow.
        kind = 'head'
      elseif name == 'HEAD' then
        -- Detached: git decorates the commit with a bare `HEAD`.
        kind = 'head'
      elseif name:sub(1, 5) == 'tag: ' then
        name = name:sub(6)
        kind = 'tag'
      elseif name:find('/', 1, true) then
        kind = 'remote'
      end
      out[#out + 1] = { name = name, kind = kind }
    end
  end
  return out
end

--- Fetches a page of log.
--- @param root string
--- @param opts table see M.args
--- @param on_done fun(rows: table[]|nil, err: string|nil)
function M.fetch(root, opts, on_done)
  cmd.run(M.args(opts), { cwd = root }, function(res)
    if not res.ok then
      on_done(nil, cmd.error_message(res))
      return
    end
    on_done(M.parse(res.stdout), nil)
  end)
end

--- Full detail for one commit: metadata, body, and changed files.
---
--- Two calls rather than one. `show --stat` and `show --name-status` render the same commit differently
--- and neither is a superset, so parsing one combined output would mean splitting on a marker inside
--- git's own formatting -- brittle in exactly the way the sentinel trick avoids. Both are ~0.01s
--- measured, so the second call is free.
--- @param root string
--- @param hash string
--- @param on_done fun(detail: table|nil, err: string|nil)
function M.fetch_detail(root, hash, on_done)
  local fmt = '--format=' .. US .. table.concat({
    '%H', '%h', '%an', '%ae', '%ad', '%cn', '%cd', '%P', '%D', '%B',
  }, US)

  cmd.run({ 'show', '--no-patch', fmt, hash }, { cwd = root }, function(res)
    if not res.ok then
      on_done(nil, cmd.error_message(res))
      return
    end

    local _, payload = M.split_line((res.stdout:gsub('\n$', '')))
    if not payload then
      on_done(nil, 'could not parse commit ' .. hash)
      return
    end

    local parts = {}
    local rest = payload
    for _ = 1, 9 do
      local at = rest:find(US, 1, true)
      if not at then break end
      parts[#parts + 1] = rest:sub(1, at - 1)
      rest = rest:sub(at + 1)
    end
    -- The body is last and may contain anything, including newlines and US bytes.
    parts[#parts + 1] = rest

    local detail = {
      hash = parts[1],
      short = parts[2],
      author = parts[3],
      author_email = parts[4],
      author_date = parts[5],
      committer = parts[6],
      committer_date = parts[7],
      parents = vim.split(parts[8] or '', ' ', { trimempty = true }),
      refs = parts[9] or '',
      body = parts[10] or '',
      files = {},
    }

    -- Delegated rather than parsed again here: `fetch_files` already handles the change types, the
    -- rename origins and the numstat join (including binaries and numstat's brace-compressed rename
    -- paths), and the detail view renders the same list as the log preview -- so a second, simpler
    -- parser would only be a way for the two to disagree.
    M.fetch_files(root, hash, function(files)
      detail.files = files or {}
      on_done(detail, nil)
    end)
  end)
end

--- Parses `--numstat` output into per-file line counts.
---
--- Two shapes that a naive parser gets wrong, both verified against this repository:
---
---   * **Binary files report `-` rather than numbers.** `-\t-\tlogo.png` means "binary", not "zero
---     changes", and rendering it as `+0 -0` is actively misleading.
---   * **Renames use a brace-compressed path**: `remote-dev/{ => docs}/FILE.md`, which matches neither
---     the old nor the new path that `--name-status` reports. So numstat rows cannot be joined to
---     name-status rows by path.
---
--- Returned as an ordered list rather than a path-keyed map for exactly that reason -- git emits both
--- listings in the same order, so the join is positional.
--- @param stdout string
--- @return table[] { added, deleted, binary }
function M.parse_numstat(stdout)
  local out = {}
  for _, line in ipairs(vim.split(stdout or '', '\n', { trimempty = true })) do
    local a, d = line:match('^(%S+)\t(%S+)\t')
    if a then
      local binary = a == '-' or d == '-'
      out[#out + 1] = {
        added = binary and 0 or (tonumber(a) or 0),
        deleted = binary and 0 or (tonumber(d) or 0),
        binary = binary,
      }
    end
  end
  return out
end

--- The files a commit touched, with change type and line counts.
---
--- Two calls, joined positionally. `--name-status` carries the change type and the true old/new paths;
--- `--numstat` carries the counts. Neither is a superset and their path columns disagree on renames,
--- so both are asked for. Measured at ~0.01s each on this repository, so the second call is free.
--- @param root string
--- @param hash string
--- @param on_done fun(files: table[]|nil, err: string|nil)
function M.fetch_files(root, hash, on_done)
  cmd.run({ 'show', '--name-status', '--format=', '-M', hash }, { cwd = root }, function(nres)
    if not nres.ok then
      on_done(nil, cmd.error_message(nres))
      return
    end

    local files = {}
    for _, line in ipairs(vim.split(nres.stdout or '', '\n', { trimempty = true })) do
      -- `M\tpath`, or `R100\told\tnew` for a rename or copy.
      local code, a, b = line:match('^(%a%d*)\t([^\t]+)\t?(.*)$')
      if code then
        local renamed = b ~= nil and b ~= ''
        files[#files + 1] = {
          code = code:sub(1, 1),
          score = tonumber(code:match('%d+') or ''),
          path = renamed and b or a,
          origin = renamed and a or nil,
          added = 0,
          deleted = 0,
        }
      end
    end

    cmd.run({ 'show', '--numstat', '--format=', '-M', hash }, { cwd = root }, function(sres)
      local stats = M.parse_numstat(sres.stdout)
      -- Positional join, guarded by a length check: if the two listings ever disagree in length the
      -- counts are dropped rather than attached to the wrong file, since a wrong number is worse than
      -- no number.
      if #stats == #files then
        for i, f in ipairs(files) do
          f.added = stats[i].added
          f.deleted = stats[i].deleted
          f.binary = stats[i].binary
        end
      end
      on_done(files, nil)
    end)
  end)
end

M.US = US

return M
