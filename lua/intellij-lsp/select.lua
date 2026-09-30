--- Single-keypress answers to the server's numbered prompts.
---
--- Neovim's stock `vim.ui.select` builds a numbered list and calls `inputlist()`, which is a
--- *line* prompt: it reads until <CR>, so answering a two-item list costs "1<CR>". Every prompt
--- this plugin raises is a short numbered menu, and the IDE equivalents all accept a bare digit.
---
--- The interception is deliberately narrow. `vim.ui.select` is a shared, user-overridable entry
--- point -- plugins like dressing.nvim and snacks.nvim replace it wholesale, and those replacements
--- are *better* than this one. So this wraps rather than assigns: the previous implementation is
--- captured and called for anything this module does not want to handle, which means
---
---   * a list longer than `MAX_SINGLE_KEY` entries, where a single digit cannot express "12", and
---   * any prompt raised while this is already waiting on a key.
---
--- If a fancier picker is installed *after* setup, it wins for the same reason -- it overwrites
--- `vim.ui.select` and this wrapper is no longer on the path.

local M = {}

--- Above this many entries a single digit is ambiguous ("1" could start "12"), so the prompt falls
--- back to the line-based picker rather than guessing at a timeout.
local MAX_SINGLE_KEY = 9

--- Keys that dismiss the prompt: <Esc>, <C-c>, q.
local CANCEL = { [27] = true, [3] = true, [113] = true }

--- The `vim.ui.select` this module wrapped, called for anything it declines to handle.
--- @type fun(items: any[], opts: table, on_choice: fun(item: any?, idx: integer?))|nil
local fallback = nil

--- True while a single-key prompt is on screen.
---
--- `intellij/chooseAction` is re-entrant -- answering one prompt can raise the next -- and a nested
--- `getchar()` would read the key meant for the outer prompt. The inner prompt uses the line-based
--- picker instead, which is visibly different but correct.
local waiting = false

--- Renders the menu and reads one key.
---
--- @param items any[]
--- @param opts table
--- @return integer|nil idx nil when dismissed
local function ask(items, opts)
  local format_item = opts.format_item or tostring

  -- Each entry is a `{text}` chunk, which is the shape nvim_echo wants; flattening this into bare
  -- strings makes it throw.
  local chunks = { { (opts.prompt or 'Select one of:') .. '\n' } }
  for i, item in ipairs(items) do
    chunks[#chunks + 1] = { ('%d: %s\n'):format(i, format_item(item)) }
  end
  vim.api.nvim_echo(chunks, false, {})

  local ok, c = pcall(vim.fn.getchar)
  -- <C-c> surfaces as an error from getchar rather than a keycode, so a failed pcall is a dismissal
  -- and not something to report.
  if not ok then return nil end

  -- Special keys (arrows, mouse) arrive as strings, where nr2char would produce nonsense.
  if type(c) ~= 'number' then return nil end
  if CANCEL[c] then return nil end

  local idx = tonumber(vim.fn.nr2char(c))
  if not idx or idx < 1 or idx > #items then return nil end
  return idx
end

--- Clears the menu from the message area.
---
--- Without this the prompt stays on screen after the pick, and on a multi-line menu it also leaves
--- the "Press ENTER" hit-enter prompt -- exactly the confirmation this module exists to remove.
local function clear()
  vim.api.nvim_echo({ { '' } }, false, {})
  vim.cmd('redraw')
end

--- `vim.ui.select` with single-key answers for short lists.
--- @param items any[]
--- @param opts table
--- @param on_choice fun(item: any?, idx: integer?)
function M.select(items, opts, on_choice)
  opts = opts or {}

  local declined = waiting or type(items) ~= 'table' or #items == 0 or #items > MAX_SINGLE_KEY
  if declined then
    return (fallback or vim.ui.select)(items, opts, on_choice)
  end

  waiting = true
  -- pcall so a `getchar` interrupt cannot leave `waiting` stuck true for the rest of the session,
  -- which would silently downgrade every later prompt to the line-based picker. A genuine error is
  -- re-reported rather than swallowed: treating it as a dismissal turns a broken prompt into one
  -- that merely looks unresponsive, which is how a shape bug in the echo call hid here once.
  local ok, idx = pcall(ask, items, opts)
  waiting = false
  clear()

  if not ok then
    vim.notify('IntelliJ LSP: select prompt failed: ' .. tostring(idx), vim.log.levels.ERROR)
    idx = nil
  end
  -- The contract is that on_choice is always called, including on dismissal: extensions.lua has to
  -- answer the server either way or it leaks the cached session.
  if idx then
    on_choice(items[idx], idx)
  else
    on_choice(nil, nil)
  end
end

--- Installs the wrapper, keeping whatever `vim.ui.select` is currently in place as the fallback.
--- Safe to call more than once; it will not wrap itself.
function M.setup()
  if vim.ui.select == M.select then return end
  fallback = vim.ui.select
  vim.ui.select = M.select
end

--- Restores the previous `vim.ui.select`, for a re-`setup()` that turns this off.
function M.teardown()
  if vim.ui.select ~= M.select then return end
  if fallback then vim.ui.select = fallback end
  fallback = nil
end

M._MAX_SINGLE_KEY = MAX_SINGLE_KEY

return M
