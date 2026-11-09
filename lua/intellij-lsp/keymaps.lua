-- The prefix every plugin keymap hangs off (`<leader>rr`, `<leader>ts`, `<leader>b`, ...).
--
-- One place decides it, so `keymaps = { prefix = '<localleader>' }` moves all of them at once and
-- `keymaps = false` drops all of them at once. `vim.keymap.set` expands `<leader>`/`<localleader>`
-- when the map is created, so the prefix is a plain string concatenated in front of the suffix.

local M = {}

M.DEFAULT_PREFIX = '<leader>'

--- The prefix to map under, or nil when the user turned the keymaps off.
--- @param cfg table|nil the plugin config; nil reads the one `setup()` stored
--- @return string|nil
function M.prefix(cfg)
  if cfg == nil then
    local ok, plugin = pcall(require, 'intellij-lsp')
    cfg = ok and plugin.config or {}
  end
  local k = cfg.keymaps
  if k == false then return nil end
  if type(k) == 'table' and type(k.prefix) == 'string' then return k.prefix end
  return M.DEFAULT_PREFIX
end

--- How to name a keymap in a message: `<leader>rd`, or nil when the keymaps are off.
--- @param suffix string
--- @param cfg table|nil
--- @return string|nil
function M.lhs(suffix, cfg)
  local p = M.prefix(cfg)
  return p and (p .. suffix) or nil
end

--- @param value any the `keymaps` option
--- @return string|nil problem
function M.validate(value)
  if value == nil or type(value) == 'boolean' then return nil end
  if type(value) ~= 'table' then
    return ('keymaps: expected true, false or { prefix = "<localleader>" }, got %s'):format(vim.inspect(value))
  end
  if value.prefix ~= nil and (type(value.prefix) ~= 'string' or value.prefix == '') then
    return ('keymaps.prefix: expected a non-empty string like "<localleader>", got %s'):format(vim.inspect(value.prefix))
  end
  return nil
end

return M
