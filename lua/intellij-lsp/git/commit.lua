--- Commit detail: metadata, full message, changed files, and the selected file's diff.
---
--- The same previewing-list shape as everything else, one level deeper: the list is this commit's files
--- and the preview is that file's diff *within* the commit -- `git show <hash> -- <path>`, not a
--- working-tree diff, so it shows what the commit did rather than what the file looks like now.

local cmd = require('intellij-lsp.git.cmd')
local filelist = require('intellij-lsp.git.filelist')
local log = require('intellij-lsp.git.log')
local session = require('intellij-lsp.git.session')

local M = {}

local ns = vim.api.nvim_create_namespace('intellij-lsp.git.commit')


--- @type IntellijGitSession|nil
local state = nil

--- Builds the detail lines, row map and highlights.
--- @param d table from log.fetch_detail
--- @return string[] lines
--- @return table<integer, table> row -> file
--- @return table[] highlights
function M._render(d)
  local lines, map, hls = {}, {}, {}

  local function add(text, hl, item)
    lines[#lines + 1] = text
    if hl then hls[#hls + 1] = { row = #lines - 1, hl = hl } end
    if item then map[#lines] = item end
    return #lines
  end

  add(('commit %s'):format(d.short), 'IntellijGitCommitHeader')
  add(('Author: %s <%s>'):format(d.author, d.author_email), 'IntellijGitCommitMeta')
  add(('Date:   %s'):format(d.author_date), 'IntellijGitCommitMeta')
  -- Only shown when it differs: on the overwhelming majority of commits it is the same person and the
  -- same instant, and repeating it is noise.
  if d.committer ~= d.author or d.committer_date ~= d.author_date then
    add(('Commit: %s (%s)'):format(d.committer, d.committer_date), 'IntellijGitCommitMeta')
  end
  -- Parent count is how a merge announces itself, which changes how the diff should be read.
  if #d.parents > 1 then
    add(('Merge:  %s'):format(table.concat(vim.tbl_map(function(p) return p:sub(1, 7) end, d.parents), ' ')),
      'IntellijGitCommitMeta')
  end

  add('')
  local body_lines = vim.split((d.body or ''):gsub('%s+$', ''), '\n', { plain = true })
  for i, line in ipairs(body_lines) do
    -- The first line is the subject; the rest is the body, indented as git does.
    add('  ' .. line, i == 1 and 'IntellijGitCommitSubject' or nil)
  end

  add('')
  add(('Files (%d)'):format(#d.files), 'IntellijGitCommitSection')

  if #d.files == 0 then
    add('  (no file changes — merge or empty commit)', 'IntellijGitCommitMeta')
    return lines, map, hls
  end

  -- The shared renderer, so this list and the log's preview cannot drift into colouring the same data
  -- differently. See `filelist.lua` for why each column is coloured the way it is.
  for _, f in ipairs(d.files) do
    local text, spans = filelist.row(f)
    local r = add(text, nil, f) - 1
    for _, sp in ipairs(spans) do
      hls[#hls + 1] = { row = r, col = sp.col, end_col = sp.end_col, hl = sp.hl }
    end
  end

  return lines, map, hls
end

--- Previews one file's change side by side: parent on the left, this commit on the right.
---
--- The same two-pane diff mode `<CR>` opens in a tab, rendered live as you step the list -- so
--- `]c`/`[c`, synchronized scrolling and per-line highlighting are all there without a keypress. The
--- unified `+`/`-` patch this replaced showed the same information but had to be read rather than
--- glanced at.
---
--- Two git calls per step instead of one. Both are `git show <rev>:<path>`, measured in the low
--- milliseconds even on a large repository, and the session's debounce means holding `j` through
--- a long file list fetches only the row you stop on.
--- @param s IntellijGitSession
--- @param file table
local function preview(s, file)
  local seq = session.next_seq(s)
  local diff = require('intellij-lsp.git.diff')

  -- A rename must read the *old* path on the parent side, or a pure move renders as a whole-file
  -- addition against an empty pane.
  local parent_path = file.origin or file.path

  diff.read_revision(s.root, s.hash .. '^:' .. parent_path, function(before)
    if not session.is_current(s, seq) then return end

    diff.read_revision(s.root, s.hash .. ':' .. file.path, function(after)
      -- Checked again: the second read is a separate round trip, so the cursor may have moved on
      -- between the two.
      if not session.is_current(s, seq) then return end

      if before == nil and after == nil then
        -- Neither side is readable as text -- a binary file, or a merge resolution git will not
        -- attribute to one parent. Fall back to the single pane rather than showing two empty ones.
        session.close_diff_preview(s)
        session.render_preview(s, {
          ('# %s: no textual diff at this commit'):format(file.path),
          '# (binary, a mode change, or a merge resolution)',
        }, 'text')
        return
      end

      local short = s.hash:sub(1, 7)
      session.render_diff_preview(s,
        -- Empty tables rather than nil: an added file needs an empty left pane so every line reads as
        -- an addition, and a deleted file an empty right one.
        { name = ('intellij-git://%s^/%s'):format(short, parent_path), lines = before or {} },
        { name = ('intellij-git://%s/%s'):format(short, file.path), lines = after or {} },
        diff.filetype_for(file.path))
    end)
  end)
end

--- @return boolean
function M.is_open()
  return session.is_open(state)
end

function M.close(restore)
  session.close(state, restore)
  state = nil
end

--- The file under the cursor.
--- @return table|nil
function M.current()
  return session.current(state)
end

--- Opens the detail view for a commit.
--- @param root string
--- @param hash string
function M.open(root, hash)
  M.close(false)

  log.fetch_detail(root, hash, function(detail, err)
    if not detail then
      vim.notify('IntelliJ git: ' .. tostring(err), vim.log.levels.ERROR)
      return
    end

    state = session.open({
      root = root,
      name = 'intellij-git://commit/' .. detail.short,
      filetype = 'intellij-git-commit',
      -- Bottom, matching the log it is opened from: a full-width strip fits long paths and the +N/-N
      -- columns, and keeping the two panels in the same place means `<CR>` does not relocate the UI.
      height = 18,
    })
    state.hash = hash

    state.on_preview = preview
    -- `<CR>` opens the side-by-side diff of what this commit did to the file -- the same diff-mode
    -- experience as `:IntellijGitDiff`, but between two historical revisions. The unified patch is
    -- already in the preview pane, so opening it again here would add nothing; the file *as it is now*
    -- is reachable with `o`.
    state.on_select = function(s, file)
      require('intellij-lsp.git.diff').open_commit_file(s.root, s.hash, file)
    end

    session.attach(state, {
      -- The old `<CR>` behaviour, kept because "take me to this file" is still a thing you want after
      -- reading a commit -- just not the *primary* thing.
      ['o'] = function(s)
        local file = session.current(s)
        if not file then return end
        local path = s.root .. '/' .. file.path
        local win = session.preview_win(s)
        M.close(false)
        if win and vim.api.nvim_win_is_valid(win) then
          vim.api.nvim_set_current_win(win)
        end
        vim.cmd.edit(vim.fn.fnameescape(path))
      end,
      ['q'] = function() M.close(true) end,
      ['<Esc>'] = function() M.close(true) end,
    })

    local lines, map, hls = M._render(detail)
    session.fill(state, lines, map, hls, ns)
    session.select_first(state)
  end)
end

return M
