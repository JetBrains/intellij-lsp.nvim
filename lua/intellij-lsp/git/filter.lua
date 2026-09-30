--- Log filter state, and its translation to `git log` flags.
---
--- Kept separate from the view and free of side effects, because this is where the interesting
--- correctness lives and it is all unit-testable: a path placed before `--` is read as a revision, a
--- `--grep` pattern is a regex unless told otherwise, and combining filters has to mean AND rather
--- than the last one winning.
---
--- Performance note that shapes the UI: on a large history a **path filter costs roughly ten times
--- what `--grep` does**, and the cost tracks how far git must walk to fill the page rather than how
--- broad the path is. A rarely-touched path is *slower* than a busy one, and a mistyped path is the
--- worst case because git walks all of history looking for matches it will never find. So
--- `is_slow()` exists to let the view show an in-flight indicator for exactly the filters that
--- need one.

local M = {}

--- @class IntellijGitFilter
--- @field text string|nil    matched against the commit message
--- @field author string|nil
--- @field path string|nil    repository-relative
--- @field range string|nil   revision range, e.g. "HEAD~50..HEAD" or "main..feature"

--- @return IntellijGitFilter
function M.empty()
  return {}
end

--- Whether any filter is set.
--- @param f IntellijGitFilter
--- @return boolean
function M.is_active(f)
  f = f or {}
  return (f.text or '') ~= ''
    or (f.author or '') ~= ''
    or (f.path or '') ~= ''
    or (f.range or '') ~= ''
end

--- Whether this filter is expected to take long enough to need a progress indicator.
---
--- Only the path filter qualifies. See the module comment for the measurements.
--- @param f IntellijGitFilter
--- @return boolean
function M.is_slow(f)
  return ((f or {}).path or '') ~= ''
end

--- Flags for the filters that are ordinary options.
---
--- Paths are deliberately *not* included: they are positional and must follow `--`, so they are
--- returned separately by `path_args` and the caller keeps them last.
---
--- `--fixed-strings` is applied to the message filter because a user typing `PROJ-123` into a search
--- box means it literally, and a bare `-` or `[` in a regex-interpreted pattern either errors or
--- silently matches the wrong thing. `--author` is left as a regex, matching git's own behaviour and
--- allowing `alice\|bob`.
--- @param f IntellijGitFilter
--- @return string[]
function M.args(f)
  f = f or {}
  local argv = {}

  if (f.text or '') ~= '' then
    -- `--all-match` is not needed: with a single --grep it is a no-op, and with several git already
    -- ORs them, which is not what a single search box means.
    argv[#argv + 1] = '--fixed-strings'
    argv[#argv + 1] = '--regexp-ignore-case'
    argv[#argv + 1] = '--grep=' .. f.text
  end

  if (f.author or '') ~= '' then
    argv[#argv + 1] = '--regexp-ignore-case'
    argv[#argv + 1] = '--author=' .. f.author
  end

  return argv
end

--- Positional path arguments, to be placed after `--`.
--- @param f IntellijGitFilter
--- @return string[]
function M.path_args(f)
  local path = (f or {}).path or ''
  if path == '' then return {} end
  return { path }
end

--- The revision range, or nil.
--- @param f IntellijGitFilter
--- @return string|nil
function M.range(f)
  local range = (f or {}).range or ''
  if range == '' then return nil end
  return range
end

--- One-line description for the view header.
---
--- Shows what is filtering, so an unexpectedly short list is explicable rather than looking like a
--- broken log.
--- @param f IntellijGitFilter
--- @return string|nil nil when nothing is set
function M.describe(f)
  f = f or {}
  local parts = {}
  if (f.range or '') ~= '' then parts[#parts + 1] = 'range ' .. f.range end
  if (f.text or '') ~= '' then parts[#parts + 1] = ('message ~ %q'):format(f.text) end
  if (f.author or '') ~= '' then parts[#parts + 1] = ('author ~ %q'):format(f.author) end
  if (f.path or '') ~= '' then parts[#parts + 1] = 'path ' .. f.path end
  if #parts == 0 then return nil end
  return table.concat(parts, ', ')
end

return M
