--- The output panel: one bottom split and one buffer, shared by everything that streams text.
---
--- Two producers write here. `run.lua` appends a running program's stdout and stderr, and
--- `progress.lua` appends the build tool's output while Maven or Gradle import the project. They
--- share a buffer on purpose. A bottom split is expensive screen estate in Neovim, and IntelliJ can
--- only afford separate Build and Run tool windows because it has a tab strip to switch them; two
--- competing bottom panels here would be worse than either alone. The two streams also rarely
--- overlap in time: import runs at startup, when nothing is running yet, and after a workspace
--- reload. The one real cost is the long-running program whose log gets Maven lines spliced into it
--- when a POM edit triggers a reimport; the separators mark where that happened but do not unmix it.
---
--- Appends are coalesced. A Maven import that resolves dependencies emits hundreds of lines a
--- second, and one scheduled buffer write per line is wasteful, so producers queue lines and one
--- flush per event-loop tick writes them all. Line highlights ride along as extmarks, applied at
--- append time rather than by a syntax file: the buffer only grows, and re-scanning it with regexes
--- on every change would cost more the longer the session runs.
---
--- The panel follows the tail only while the cursor sits on the last line. Scrolling up to read a
--- stack trace must not be yanked back down by the next line of output; `G` starts following again.

local M = {}

local BUF_NAME = 'intellij-lsp://output'

local ns = vim.api.nvim_create_namespace('intellij-lsp-output')

--- @type integer|nil
local panel_buf = nil
--- @type integer|nil
local panel_win = nil

--- Producer-registered buffer-local keymaps, re-applied whenever the buffer is (re)created, so a
--- `:bwipeout` does not silently lose `run.lua`'s stop binding.
--- @type { lhs: string, rhs: function|string, desc: string }[]
local keymaps = {}

--- Queued chunks waiting for the next flush.
--- @type { lines: string[], hl: string|nil }[]
local pending = {}
local flush_scheduled = false

-- ---------------------------------------------------------------------------
-- Jump targets. Pure string parsing, driven by test/units.lua.
-- ---------------------------------------------------------------------------

--- Extracts a file location from one line of build or program output.
---
--- Absolute paths are returned as-is. A Java stack frame carries only the simple file name, so
--- `file` comes back bare and `bare = true` tells the caller to search for it.
---
--- Shapes recognised, in order:
---   * Maven compiler:      `[ERROR] /abs/File.java:[12,5] cannot find symbol`
---   * Maven POM:           `[FATAL] Non-parseable POM /abs/pom.xml: ... @ line 12, column 3`
---   * Gradle script:       `* Where: Build file '/abs/build.gradle' line: 12`
---   * Kotlin compiler:     `e: /abs/File.kt: (12, 5): unresolved reference`
---   * javac / generic:     `/abs/File.java:12: error: ...`, `/abs/File.java:12:5: ...`
---   * Java stack frame:    `    at pkg.Class.method(File.java:12)`
--- @param line string
--- @return { file: string, lnum: integer, col: integer|nil, bare: boolean }|nil
function M._jump_target(line)
  local f, l, c

  f, l, c = line:match('^%[%u+%]%s+(/[^%s:]+):%[(%d+),(%d+)%]')
  if f then return { file = f, lnum = tonumber(l), col = tonumber(c), bare = false } end

  f, l, c = line:match('(/[^%s:]+%.xml).-@ line (%d+), column (%d+)')
  if f then return { file = f, lnum = tonumber(l), col = tonumber(c), bare = false } end

  f, l = line:match("[Ff]ile '([^']+)' line: (%d+)")
  if f then return { file = f, lnum = tonumber(l), col = nil, bare = false } end

  f, l, c = line:match('^%a: (/[^%s:]+): %((%d+), (%d+)%)')
  if f then return { file = f, lnum = tonumber(l), col = tonumber(c), bare = false } end

  f, l, c = line:match('(/[^%s:]+%.%a+):(%d+):(%d+)')
  if f then return { file = f, lnum = tonumber(l), col = tonumber(c), bare = false } end
  f, l = line:match('(/[^%s:]+%.%a+):(%d+)')
  if f then return { file = f, lnum = tonumber(l), col = nil, bare = false } end

  f, l = line:match('%s+at%s+[%w_$.<>]+%(([%w_$%-]+%.%a+):(%d+)%)')
  if f then return { file = f, lnum = tonumber(l), col = nil, bare = true } end

  return nil
end

--- Finds a bare file name under the working directory, skipping build output and VCS directories:
--- `target/` and `build/` hold generated copies of sources, and a jump into one of those would land
--- on a file the user cannot usefully edit.
--- @param name string
--- @return string|nil
local function find_source(name)
  local hits = vim.fs.find(function(fname, path)
    if fname ~= name then return false end
    for _, dir in ipairs({ 'target', 'build', '.git' }) do
      if path:sub(-#dir - 1) == '/' .. dir or path:find('/' .. dir .. '/', 1, true) then return false end
    end
    return true
  end, { path = vim.fn.getcwd(), type = 'file', limit = 1 })
  return hits[1]
end

--- The window a jump should land in: the previously focused window when it is a normal one, else
--- the first non-floating window that is not the panel, else a new split above the panel.
--- @return integer winid
local function editor_win()
  local prev = vim.fn.win_getid(vim.fn.winnr('#'))
  local function usable(win)
    return win ~= 0 and win ~= panel_win and vim.api.nvim_win_is_valid(win)
      and vim.api.nvim_win_get_config(win).relative == ''
  end
  if usable(prev) then return prev end
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if usable(win) then return win end
  end
  vim.cmd('aboveleft new')
  return vim.api.nvim_get_current_win()
end

--- `<CR>` in the panel: open the file the current line refers to, at that line.
local function jump()
  local line = vim.api.nvim_get_current_line()
  local target = M._jump_target(line)
  if not target then return end

  local path = target.file
  if target.bare then
    path = find_source(target.file)
    if not path then
      vim.notify(('IntelliJ LSP: %s not found under %s'):format(target.file, vim.fn.getcwd()), vim.log.levels.WARN)
      return
    end
  end
  if vim.fn.filereadable(path) ~= 1 then
    vim.notify('IntelliJ LSP: no such file: ' .. path, vim.log.levels.WARN)
    return
  end

  local win = editor_win()
  vim.api.nvim_set_current_win(win)
  vim.cmd.edit(vim.fn.fnameescape(path))
  local last = vim.api.nvim_buf_line_count(0)
  vim.api.nvim_win_set_cursor(win, { math.min(target.lnum, last), math.max((target.col or 1) - 1, 0) })
end

-- ---------------------------------------------------------------------------
-- Buffer and window
-- ---------------------------------------------------------------------------

--- Registers a keymap that every incarnation of the panel buffer gets.
--- @param lhs string
--- @param rhs function|string
--- @param desc string
function M.keymap(lhs, rhs, desc)
  table.insert(keymaps, { lhs = lhs, rhs = rhs, desc = desc })
  if panel_buf and vim.api.nvim_buf_is_valid(panel_buf) then
    vim.keymap.set('n', lhs, rhs, { buffer = panel_buf, desc = desc })
  end
end

--- The panel buffer, created on first use and reused for the rest of the session so a second run
--- or a reimport appends below what is already there rather than orphaning it.
--- @return integer bufnr
function M.buf()
  if panel_buf and vim.api.nvim_buf_is_valid(panel_buf) then return panel_buf end
  panel_buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(panel_buf, BUF_NAME)
  vim.bo[panel_buf].buftype = 'nofile'
  vim.bo[panel_buf].swapfile = false
  vim.bo[panel_buf].filetype = 'intellij-output'
  local function close()
    if panel_win and vim.api.nvim_win_is_valid(panel_win) then vim.api.nvim_win_close(panel_win, false) end
  end
  vim.keymap.set('n', 'q', close, { buffer = panel_buf, desc = 'IntelliJ: close the output panel' })
  vim.keymap.set('n', '<Esc>', close, { buffer = panel_buf, desc = 'IntelliJ: close the output panel' })
  vim.keymap.set('n', '<CR>', jump, { buffer = panel_buf, desc = 'IntelliJ: open the file this line refers to' })
  for _, km in ipairs(keymaps) do
    vim.keymap.set('n', km.lhs, km.rhs, { buffer = panel_buf, desc = km.desc })
  end
  return panel_buf
end

--- Whether the panel is currently showing.
--- @return boolean
function M.is_open()
  return panel_win ~= nil and vim.api.nvim_win_is_valid(panel_win)
end

--- Opens the panel, or reuses the open one.
---
--- `focus = false` leaves the cursor where it is. That is what an import that opens the panel by
--- itself wants: it happens at startup, while the user is reading a file, and pulling them into the
--- panel would be an interruption. A run the user just triggered keeps the old behaviour and focuses
--- it. Either way the panel's cursor is put on the last line, so it follows the tail from the start.
--- @param opts { focus: boolean|nil }|nil
--- @return integer winid
function M.open(opts)
  local focus = not (opts and opts.focus == false)
  local buf = M.buf()
  local before = vim.api.nvim_get_current_win()

  if not M.is_open() then
    vim.cmd('botright new')
    panel_win = vim.api.nvim_get_current_win()
    vim.wo[panel_win].number = false
    vim.wo[panel_win].relativenumber = false
    vim.wo[panel_win].signcolumn = 'no'
    vim.wo[panel_win].wrap = false
  end
  vim.api.nvim_win_set_buf(panel_win, buf)
  vim.api.nvim_win_set_cursor(panel_win, { vim.api.nvim_buf_line_count(buf), 0 })

  if focus then
    vim.api.nvim_set_current_win(panel_win)
  elseif vim.api.nvim_win_is_valid(before) then
    vim.api.nvim_set_current_win(before)
  end
  return panel_win
end

--- Closes the panel window. The buffer and its contents stay.
function M.close()
  if M.is_open() then vim.api.nvim_win_close(panel_win, false) end
end

-- ---------------------------------------------------------------------------
-- Appending
-- ---------------------------------------------------------------------------

--- Writes every queued chunk in one buffer edit and highlights the lines that asked for it.
function M._flush()
  flush_scheduled = false
  if #pending == 0 then return end
  local chunks = pending
  pending = {}

  local buf = M.buf()
  local lines = {}
  for _, chunk in ipairs(chunks) do
    for _, l in ipairs(chunk.lines) do lines[#lines + 1] = l end
  end

  -- A fresh scratch buffer holds one empty line; writing over it keeps the log from starting with a
  -- blank. Detected by content rather than a flag, so a `:bwipeout` and recreate behaves the same.
  local count = vim.api.nvim_buf_line_count(buf)
  local fresh = count == 1 and vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1] == ''
  local first = fresh and 0 or count

  local win = M.is_open() and panel_win or nil
  local following = win and vim.api.nvim_win_get_cursor(win)[1] == count

  vim.api.nvim_buf_set_lines(buf, fresh and 0 or -1, -1, false, lines)

  local row = first
  for _, chunk in ipairs(chunks) do
    if chunk.hl then
      for i = 0, #chunk.lines - 1 do
        vim.api.nvim_buf_set_extmark(buf, ns, row + i, 0, { line_hl_group = chunk.hl, priority = 50 })
      end
    end
    row = row + #chunk.lines
  end

  if win and following then
    vim.api.nvim_win_set_cursor(win, { vim.api.nvim_buf_line_count(buf), 0 })
  end
end

--- Queues `text` for the panel. A trailing newline does not produce an empty line, matching how
--- program output arrives from DAP in newline-terminated chunks.
--- @param text string
--- @param hl string|nil highlight group applied to every line of this chunk
function M.append(text, hl)
  local lines = vim.split(text, '\n', { plain = true })
  if #lines > 1 and lines[#lines] == '' then table.remove(lines) end
  if #lines == 0 then return end
  pending[#pending + 1] = { lines = lines, hl = hl }
  if not flush_scheduled then
    flush_scheduled = true
    vim.schedule(M._flush)
  end
end

--- Forgets the buffer and window, for tests that want a clean slate.
function M._reset()
  M.close()
  if panel_buf and vim.api.nvim_buf_is_valid(panel_buf) then
    vim.api.nvim_buf_delete(panel_buf, { force = true })
  end
  panel_buf, panel_win, pending, flush_scheduled = nil, nil, {}, false
end

return M
