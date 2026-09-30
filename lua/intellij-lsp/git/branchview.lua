--- The branch list: local and remote branches, with checkout on `<CR>`.
---
--- Preview here is the branch tip's recent log rather than a diff -- "what is on this branch" is the
--- question you ask before switching to it.

local branches = require('intellij-lsp.git.branches')
local cmd = require('intellij-lsp.git.cmd')
local log = require('intellij-lsp.git.log')
local session = require('intellij-lsp.git.session')

local M = {}

local ns = vim.api.nvim_create_namespace('intellij-lsp.git.branchview')


--- @type IntellijGitSession|nil
local state = nil

--- Builds the branch list lines, row map and highlights.
--- @param list IntellijGitBranch[]
--- @return string[] lines
--- @return table<integer, table> row -> branch
--- @return table[] highlights
function M._render(list)
  local lines, map, hls = {}, {}, {}

  local function add(text, hl, item)
    lines[#lines + 1] = text
    if hl then hls[#hls + 1] = { row = #lines - 1, hl = hl } end
    if item then map[#lines] = item end
  end

  local current = branches.current(list)
  -- Detached HEAD must be said, not implied by the absence of a marker: it changes what a checkout
  -- means and is a state users land in by accident.
  add(current and ('On %s'):format(current.name) or 'HEAD detached',
    'IntellijGitBranchHeader')

  for _, section in ipairs({
    { kind = branches.LOCAL, title = 'Local', hl = 'IntellijGitBranchLocal' },
    { kind = branches.REMOTE, title = 'Remote', hl = 'IntellijGitBranchRemote' },
  }) do
    local rows = {}
    for _, b in ipairs(list) do
      if b.kind == section.kind then rows[#rows + 1] = b end
    end
    if #rows > 0 then
      add('')
      add(('%s (%d)'):format(section.title, #rows), 'IntellijGitBranchSection')
      for _, b in ipairs(rows) do
        local marker = b.current and '* ' or '  '
        local tail = {}
        if b.upstream then tail[#tail + 1] = '→ ' .. b.upstream end
        if b.track then tail[#tail + 1] = b.track end
        local text = ('%s%-28s %-14s %s'):format(
          marker, b.name, b.date, table.concat(tail, ' '))
        add((text:gsub('%s+$', '')), b.current and 'IntellijGitBranchCurrent' or section.hl, b)
      end
    end
  end

  if #list == 0 then
    add('')
    add('  no branches', 'IntellijGitBranchMeta')
  end

  return lines, map, hls
end

--- Previews the branch tip's recent history.
--- @param s IntellijGitSession
--- @param branch table
local function preview(s, branch)
  local seq = session.next_seq(s)
  -- Bounded like every other log call. 20 is enough to recognise a branch without paying for more.
  cmd.run(log.args({ limit = 20, range = branch.name }), { cwd = s.root }, function(res)
    if not session.is_current(s, seq) then return end

    if not res.ok then
      session.render_preview(s, { '# ' .. cmd.error_message(res) }, 'diff')
      return
    end

    local lines = {}
    for _, row in ipairs(log.parse(res.stdout)) do
      if row.commit then
        lines[#lines + 1] = ('%s%s  %s  %s'):format(
          row.graph, row.commit.short, row.commit.date, row.commit.subject)
      else
        lines[#lines + 1] = row.graph
      end
    end
    if #lines == 0 then lines = { '# no commits' } end
    session.render_preview(s, lines, 'git')
  end)
end

--- Reloads the list.
--- @param keep_cursor boolean|nil
local function reload(keep_cursor)
  if not session.is_open(state) then return end
  local row = keep_cursor and vim.api.nvim_win_get_cursor(state.win)[1] or nil

  branches.fetch(state.root, function(list, err)
    if not session.is_open(state) then return end
    if not list then
      vim.notify('IntelliJ git: ' .. tostring(err), vim.log.levels.ERROR)
      return
    end
    local lines, map, hls = M._render(list)
    session.fill(state, lines, map, hls, ns)
    if row then
      local last = vim.api.nvim_buf_line_count(state.buf)
      pcall(vim.api.nvim_win_set_cursor, state.win, { math.min(row, last), 0 })
    else
      session.select_first(state)
    end
  end)
end

--- Checks out the branch under the cursor.
local function checkout()
  local branch = session.current(state)
  if not branch then return end
  local root = state.root

  branches.checkout(root, branch, function(ok, message)
    vim.notify('IntelliJ git: ' .. message, ok and vim.log.levels.INFO or vim.log.levels.ERROR)
    if not ok then return end

    -- Files on disk changed under every open buffer, so Neovim's view of them is stale. `checktime`
    -- reloads unmodified buffers and warns about modified ones, which is the correct division: a
    -- buffer with unsaved edits must not be silently overwritten.
    vim.cmd('checktime')
    reload(true)
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

--- @return table|nil
function M.current()
  return session.current(state)
end

--- Opens the branch list.
function M.open()
  local root = cmd.root()
  if not root then
    vim.notify('IntelliJ git: not inside a git repository.', vim.log.levels.WARN)
    return
  end

  M.close(false)

  state = session.open({
    root = root,
    name = 'intellij-git://branches',
    filetype = 'intellij-git-branches',
    vertical = true,
  })

  state.on_preview = preview
  state.on_select = function() checkout() end

  session.attach(state, {
    ['R'] = function() reload(true) end,
    ['q'] = function() M.close(true) end,
    ['<Esc>'] = function() M.close(true) end,
  })

  reload()
end

return M
