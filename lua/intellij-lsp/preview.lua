--- Showing a server location in an editor window while focus stays where it is: the
--- follow-the-cursor previews of references.lua's quickfix list and the debug panel's call stack.
---
--- A location arrives as a URI -- `file:///...` for project files, `jar:`/`jrt:` for libraries and
--- the JDK -- and none of those is something `:edit` can take. `:edit file:///x` only works when a
--- `BufReadCmd` for `file://*` exists (netrw's, which many setups disable), and otherwise opens an
--- empty buffer named after the URI; moving the cursor to the location's line in it then fails with
--- "Invalid cursor line: out of range". `vim.uri_to_bufnr` maps a `file:` URI to the buffer for the
--- real path, and keeps any other URI as the buffer name so decompiler.lua's `BufReadCmd` can fill it.
---
--- Callers run these from a timer or `vim.schedule`, never straight from a `CursorMoved` callback:
--- an autocmd callback that is not `nested` fires no other autocmds, so a `bufload` inside one skips
--- the decompiler's `BufReadCmd` -- and the `FileType` that attaches the server -- and leaves the
--- buffer empty.

local M = {}

--- The buffer for a location the server sent: a URI, or (from a client that sends them) a plain path.
--- Created unloaded if it does not exist yet; `load` reads it.
--- @param location string
--- @return integer bufnr
function M.buffer(location)
  -- Two or more characters before the colon, so a Windows drive letter (`C:\x`) reads as a path.
  if location:match('^%a[%w+.-]+:') then return vim.uri_to_bufnr(location) end
  return vim.fn.bufadd(location)
end

--- Reads `buf` and detects its filetype, as a jump would have.
---
--- `bufload` does NOT run filetype detection, and neither does showing the buffer in a window, so
--- without the detect step a preview renders as unhighlighted plain text and is never attached.
--- Skipped when already detected, since this runs on every step. A `jar:`/`jrt:` buffer gets its
--- filetype from decompiler.lua inside the `bufload`.
--- @param buf integer
--- @return boolean ok false when the buffer could not be read
function M.load(buf)
  if not vim.api.nvim_buf_is_valid(buf) then return false end
  if not pcall(vim.fn.bufload, buf) then return false end
  if vim.bo[buf].filetype == '' then
    pcall(vim.api.nvim_buf_call, buf, function() vim.cmd('filetype detect') end)
  end
  return true
end

--- The editor window to preview in: `preferred` when it is usable, else the first usable window in
--- the tab.
---
--- Usable means a valid, non-floating window other than `exclude` that does not show a quickfix
--- list, a terminal or a prompt. Never splits: creating windows from a cursor-follow handler is how
--- layouts get mangled, so with no usable window this returns nil and the preview does nothing.
--- @param preferred integer|nil
--- @param exclude integer|nil e.g. the panel the preview is driven from
--- @return integer|nil
function M.window(preferred, exclude)
  local function usable(win)
    if not win or win == 0 or win == exclude or not vim.api.nvim_win_is_valid(win) then return false end
    if vim.api.nvim_win_get_config(win).relative ~= '' then return false end
    local buftype = vim.bo[vim.api.nvim_win_get_buf(win)].buftype
    return buftype ~= 'quickfix' and buftype ~= 'terminal' and buftype ~= 'prompt'
  end

  if usable(preferred) then return preferred end
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if usable(win) then return win end
  end
  return nil
end

--- Shows the loaded buffer `buf` in `win` at `lnum`/`col`, centred, without touching the jumplist or
--- the alternate file.
---
--- `keepjumps keepalt buffer N`, not nvim_win_set_buf and not `:edit`: nvim_win_set_buf pushes a
--- jumplist entry per call, so twenty j presses leave twenty junk entries and <C-o> no longer walks
--- back to where the user actually was, and `:edit` additionally rewrites the alternate file, so
--- <C-^> points at whatever was previewed last.
---
--- 'eventignore' is deliberately NOT set around this: suppressing events would skip FileType and
--- kill syntax in the preview. The plugin's own FileType autocmd attaches the buffer, which is
--- intended -- it reuses the running client, and a re-preview is a no-op.
---
--- The line is clamped into the buffer: a frame or reference can name a line the buffer does not
--- have (a decompiled class numbered differently from its source, a placeholder still waiting on
--- the server, an adapter's `-1` for "unknown"), and nvim_win_set_cursor throws on any of them.
--- @param win integer
--- @param buf integer
--- @param lnum integer|nil 1-based
--- @param col integer|nil 1-based
--- @return integer|nil lnum the line the cursor landed on, or nil when nothing was shown
function M.show(win, buf, lnum, col)
  local landed
  local ok = pcall(vim.api.nvim_win_call, win, function()
    vim.cmd('keepjumps keepalt buffer ' .. buf)
    landed = math.max(math.min(lnum or 1, vim.api.nvim_buf_line_count(buf)), 1)
    vim.api.nvim_win_set_cursor(win, { landed, math.max((col or 1) - 1, 0) })
    vim.cmd('normal! zz')
  end)
  return ok and landed or nil
end

return M
