--- Rendering for a list of files changed by a commit.
---
--- One implementation, used by both the log preview and the commit detail view. They previously each
--- had their own copy, which is how they came to disagree.
---
--- ## The colour scheme
---
--- Three columns, and each is coloured for a *different reason*. Mixing those reasons is what made the
--- earlier version read as noise -- a green "added" beside a red filename beside a green `+1`:
---
--- | Column | Colour | Why |
--- |---|---|---|
--- | status word | by change type — green added, red deleted, blue modified, cyan renamed | this *is* the change type |
--- | `+N` / `-N` | always green / always red | universal diff convention, independent of the row |
--- | path | one neutral colour for every row | it is an identifier, not a change |
---
--- The path is the key fix. Leaving it unhighlighted does **not** make it neutral -- it makes it
--- whatever the buffer's syntax or Treesitter paints, which varies per row and per colorscheme, so a
--- path could come out red on a green row for no reason the user can infer. Claiming it with an
--- explicit neutral group is the only way to be consistent.
---
--- Colouring the path *by change type* was the other option, and is deliberately rejected: it doubles
--- the same information already carried by the status word, and turns a long file list into stripes of
--- competing colour with nothing to anchor the eye. The status word carries the type; the path stays
--- calm; the counts stay conventional.

local M = {}

--- Status word and its colour, per git change code.
M.BY_CODE = {
  A = { label = 'added', hl = 'IntellijGitFileAdded' },
  D = { label = 'deleted', hl = 'IntellijGitFileDeleted' },
  M = { label = 'modified', hl = 'IntellijGitFileModified' },
  R = { label = 'renamed', hl = 'IntellijGitFileRenamed' },
  C = { label = 'copied', hl = 'IntellijGitFileRenamed' },
  T = { label = 'typechange', hl = 'IntellijGitFileModified' },
  U = { label = 'unmerged', hl = 'IntellijGitFileDeleted' },
}

local LABEL_W = 11
local STAT_W = 12

--- Renders one file row.
---
--- Returns the text plus the spans to highlight, as byte offsets into it, so the caller can place them
--- at whatever row it ends up on.
--- @param f table { code, path, origin?, added?, deleted?, binary? }
--- @return string text
--- @return table[] spans { col, end_col, hl }
function M.row(f)
  local kind = M.BY_CODE[f.code] or { label = f.code or '?', hl = 'IntellijGitFileModified' }

  -- `bin` rather than `+0 -0`: git reports `-` for a binary file because line counts are meaningless
  -- there, not because nothing changed.
  local counts = f.binary and 'bin' or ('+%d -%d'):format(f.added or 0, f.deleted or 0)
  local label = ('  %-' .. LABEL_W .. 's'):format(kind.label)
  local stat = ('%-' .. STAT_W .. 's'):format(counts)

  local text = label .. stat .. f.path
  local spans = {
    { col = 0, end_col = #label, hl = kind.hl },
  }

  if f.binary then
    spans[#spans + 1] = { col = #label, end_col = #label + #counts, hl = 'IntellijGitFileMeta' }
  else
    -- `+N` green and `-N` red regardless of the row's change type: that pairing is universal, and
    -- tinting it by change type would make a deletion's `+0` red.
    local plus = ('+%d'):format(f.added or 0)
    local minus = ('-%d'):format(f.deleted or 0)
    spans[#spans + 1] = { col = #label, end_col = #label + #plus, hl = 'IntellijGitFileAdded' }
    spans[#spans + 1] = {
      col = #label + #plus + 1, end_col = #label + #plus + 1 + #minus,
      hl = 'IntellijGitFileDeleted',
    }
  end

  -- The path, claimed explicitly. Unclaimed it inherits the buffer's syntax, which differs per row.
  local path_at = #label + #stat
  spans[#spans + 1] = { col = path_at, end_col = path_at + #f.path, hl = 'IntellijGitFilePath' }

  if f.origin then
    -- A rename shows both paths, or a pure move looks like nothing happened. The arrow and the old
    -- path are dimmed: the new path is the file's identity now, the old one is provenance.
    local arrow_at = #text
    text = text .. ' ← ' .. f.origin
    spans[#spans + 1] = { col = arrow_at, end_col = #text, hl = 'IntellijGitFileOrigin' }
  end

  return text, spans
end

--- Renders the "N files changed, +X -Y" summary.
--- @param files table[]
--- @return string text
--- @return table[] spans
function M.summary(files)
  local added, deleted, binaries = 0, 0, 0
  for _, f in ipairs(files) do
    added = added + (f.added or 0)
    deleted = deleted + (f.deleted or 0)
    if f.binary then binaries = binaries + 1 end
  end

  local head = ('%d file%s changed'):format(#files, #files == 1 and '' or 's')
  local plus, minus = ('+%d'):format(added), ('-%d'):format(deleted)
  local text = ('%s, %s %s'):format(head, plus, minus)
  local plus_at = #head + 2

  local spans = {
    { col = 0, end_col = #head, hl = 'IntellijGitFileMeta' },
    { col = plus_at, end_col = plus_at + #plus, hl = 'IntellijGitFileAdded' },
    {
      col = plus_at + #plus + 1, end_col = plus_at + #plus + 1 + #minus,
      hl = 'IntellijGitFileDeleted',
    },
  }

  if binaries > 0 then
    local at = #text
    text = text .. (', %d binary'):format(binaries)
    spans[#spans + 1] = { col = at, end_col = #text, hl = 'IntellijGitFileMeta' }
  end

  return text, spans
end

return M
