--- Standard LSP features the server offers and Neovim implements but does not switch on.
---
--- Every entry point here is the same shape as inlay hints and code lenses in client.lua: both
--- sides have the feature, and nothing in between ever asks for it. Neovim ships
--- `vim.lsp.buf.document_highlight`, `signature_help`, `typehierarchy`, `incoming_calls`,
--- `format` and `workspace_symbol`, but installs no autocmd, keymap or command that calls them,
--- so out of the box they are reachable only by name from the command line.
---
--- Everything is gated on the matching server capability, buffer-local, and wired from
--- `on_attach`, so a filetype this server does not serve is untouched.

local M = {}

--- Name of the client this module serves; kept here so `format` can address it by name without
--- pulling in client.lua (which requires this module).
local CLIENT_NAME = 'intellij'

-- ---------------------------------------------------------------------------
-- Document highlight
-- ---------------------------------------------------------------------------

--- Highlights every occurrence of the identifier under the cursor, IntelliJ's
--- IDENTIFIER_UNDER_CARET_ATTRIBUTES.
---
--- The colorscheme already defines the `LspReference*` groups the highlight lands on; this is the
--- half that requests them. CursorHold rather than CursorMoved so that scrolling through a file
--- does not fire a request per line: the server answers only after 'updatetime' of stillness.
--- Clearing on CursorMoved is what keeps a stale highlight from lagging behind the cursor.
--- @param client vim.lsp.Client
--- @param bufnr integer
--- @param cfg table
function M.setup_document_highlight(client, bufnr, cfg)
  if cfg.document_highlight == false then return end
  if not client:supports_method('textDocument/documentHighlight') then return end

  local group = vim.api.nvim_create_augroup('IntellijLspDocumentHighlight' .. bufnr, { clear = true })
  vim.api.nvim_create_autocmd({ 'CursorHold', 'CursorHoldI' }, {
    group = group,
    buffer = bufnr,
    desc = 'IntelliJ: highlight the identifier under the cursor',
    callback = function()
      -- pcall: the client may have stopped between the autocmd firing and the request going out.
      pcall(vim.lsp.buf.document_highlight)
    end,
  })
  vim.api.nvim_create_autocmd({ 'CursorMoved', 'CursorMovedI', 'BufLeave' }, {
    group = group,
    buffer = bufnr,
    desc = 'IntelliJ: clear the identifier highlight',
    callback = function()
      pcall(vim.lsp.buf.clear_references)
    end,
  })
end

-- ---------------------------------------------------------------------------
-- Signature help
-- ---------------------------------------------------------------------------

--- Fallback trigger set, used only when the server advertises signature help without naming its
--- trigger characters. The real server names exactly these.
local SIGNATURE_TRIGGERS = { '(', ',' }

--- Opens the parameter popup as you type a call, on the server's own trigger characters.
---
--- The server advertises `(` and `,` as triggers and `,` as a retrigger; Neovim reads none of that
--- and maps only `<C-S>` in insert mode. Same InsertCharPre pattern as `setup_word_triggers` in
--- client.lua: the autocmd runs before the character lands in the buffer, so the request is
--- scheduled to run after it, or the server would see the position before the parenthesis.
---
--- Skipped while the completion menu is up: the two floats fight over the same screen space and
--- the menu is the one the user is looking at.
--- @param client vim.lsp.Client
--- @param bufnr integer
--- @param cfg table
function M.setup_signature_help(client, bufnr, cfg)
  if cfg.signature_help == false then return end
  local provider = client.server_capabilities and client.server_capabilities.signatureHelpProvider
  if not provider then return end

  local triggers = {}
  local names = provider.triggerCharacters
  if type(names) ~= 'table' or #names == 0 then names = SIGNATURE_TRIGGERS end
  for _, c in ipairs(names) do triggers[c] = true end
  for _, c in ipairs(provider.retriggerCharacters or {}) do triggers[c] = true end

  vim.api.nvim_create_autocmd('InsertCharPre', {
    group = vim.api.nvim_create_augroup('IntellijLspSignatureHelp' .. bufnr, { clear = true }),
    buffer = bufnr,
    desc = 'IntelliJ: show parameter hints while typing a call',
    callback = function()
      if not triggers[vim.v.char] then return end
      if vim.fn.pumvisible() ~= 0 then return end
      vim.schedule(function()
        -- No insert-mode check: the schedule runs in the same tick as the insertion, and a popup in
        -- normal mode after an unlucky <Esc> is harmless, while a check here would be untestable.
        if vim.api.nvim_get_current_buf() ~= bufnr then return end
        pcall(vim.lsp.buf.signature_help)
      end)
    end,
  })
end

-- ---------------------------------------------------------------------------
-- Type and call hierarchy
-- ---------------------------------------------------------------------------

--- Directions `:IntellijLspTypeHierarchy` accepts, in the words the LSP methods use.
M.TYPE_HIERARCHY_KINDS = { 'subtypes', 'supertypes' }

--- Directions `:IntellijLspCallHierarchy` accepts.
M.CALL_HIERARCHY_KINDS = { 'incoming', 'outgoing' }

--- Opens the type hierarchy in the requested direction.
--- @param kind string 'subtypes' (default) or 'supertypes'
function M.type_hierarchy(kind)
  kind = (kind == nil or kind == '') and 'subtypes' or kind
  if not vim.tbl_contains(M.TYPE_HIERARCHY_KINDS, kind) then
    vim.notify('IntelliJ LSP: type hierarchy direction must be subtypes or supertypes', vim.log.levels.ERROR)
    return
  end
  vim.lsp.buf.typehierarchy(kind)
end

--- Opens the call hierarchy in the requested direction.
--- @param kind string 'incoming' (default) or 'outgoing'
function M.call_hierarchy(kind)
  kind = (kind == nil or kind == '') and 'incoming' or kind
  if kind == 'incoming' then
    vim.lsp.buf.incoming_calls()
  elseif kind == 'outgoing' then
    vim.lsp.buf.outgoing_calls()
  else
    vim.notify('IntelliJ LSP: call hierarchy direction must be incoming or outgoing', vim.log.levels.ERROR)
  end
end

--- Buffer-local keymaps for the hierarchies and the symbol search.
---
--- `<leader>` maps, like `<leader>rr`: there is no built-in mapping to shadow here, so a bare
--- two-letter sequence would claim space in the user's own namespace. The letters follow the
--- feature: `t` type hierarchy, `c` call hierarchy, `w` workspace.
--- @param client vim.lsp.Client
--- @param bufnr integer
--- @param cfg table
function M.setup_keymaps(client, bufnr, cfg)
  if cfg.keymaps == false then return end
  local function map(lhs, rhs, desc)
    vim.keymap.set('n', lhs, rhs, { buffer = bufnr, desc = 'IntelliJ: ' .. desc })
  end

  if client:supports_method('textDocument/prepareTypeHierarchy') then
    map('<leader>ts', function() M.type_hierarchy('subtypes') end, 'type hierarchy, subtypes')
    map('<leader>tu', function() M.type_hierarchy('supertypes') end, 'type hierarchy, supertypes')
  end
  if client:supports_method('textDocument/prepareCallHierarchy') then
    map('<leader>ci', function() M.call_hierarchy('incoming') end, 'call hierarchy, incoming calls')
    map('<leader>co', function() M.call_hierarchy('outgoing') end, 'call hierarchy, outgoing calls')
  end
  if client:supports_method('workspace/symbol') then
    map('<leader>ws', function() M.workspace_symbol() end, 'search workspace symbols')
  end
end

-- ---------------------------------------------------------------------------
-- Formatting
-- ---------------------------------------------------------------------------

--- Timeout for a synchronous format, as `format_on_save` has to be: BufWritePre cannot wait
--- asynchronously for the edit to land before the write goes ahead.
M.FORMAT_TIMEOUT_MS = 5000

--- Formats the buffer, or the given line range, with this server only.
---
--- `name` pins the request to our client: a buffer with a second formatter attached (an
--- efm-style tool, say) should not be formatted twice from a command that carries our name.
--- @param opts { bufnr: integer|nil, line1: integer|nil, line2: integer|nil, async: boolean|nil }
function M.format(opts)
  opts = opts or {}
  local bufnr = opts.bufnr or vim.api.nvim_get_current_buf()
  local range
  if opts.line1 and opts.line2 then
    range = {
      ['start'] = { opts.line1, 0 },
      ['end'] = { opts.line2, #(vim.api.nvim_buf_get_lines(bufnr, opts.line2 - 1, opts.line2, false)[1] or '') },
    }
  end
  vim.lsp.buf.format({
    bufnr = bufnr,
    name = CLIENT_NAME,
    range = range,
    async = opts.async,
    timeout_ms = M.FORMAT_TIMEOUT_MS,
  })
end

--- Formats the whole buffer on every write. Off by default: IntelliJ's formatter rewrites more than
--- the lines you touched, which is a surprise in a repository that does not already run it.
--- @param client vim.lsp.Client
--- @param bufnr integer
--- @param cfg table
function M.setup_format_on_save(client, bufnr, cfg)
  if cfg.format_on_save ~= true then return end
  if not client:supports_method('textDocument/formatting') then return end

  vim.api.nvim_create_autocmd('BufWritePre', {
    group = vim.api.nvim_create_augroup('IntellijLspFormatOnSave' .. bufnr, { clear = true }),
    buffer = bufnr,
    desc = 'IntelliJ: format before writing',
    callback = function()
      -- Synchronous on purpose: the write must see the formatted text. pcall so a slow or
      -- stopped server never blocks saving.
      pcall(M.format, { bufnr = bufnr, async = false })
    end,
  })
end

-- ---------------------------------------------------------------------------
-- Workspace symbols
-- ---------------------------------------------------------------------------

--- Searches classes, methods and fields across the project. With no query, prompts for one.
---
--- The server advertises `workDoneProgress` for this request, so a search over a large index shows
--- in the progress line without any work here.
--- @param query string|nil
function M.workspace_symbol(query)
  if query == nil or query == '' then
    vim.lsp.buf.workspace_symbol()
  else
    vim.lsp.buf.workspace_symbol(query)
  end
end

-- ---------------------------------------------------------------------------
-- Wiring
-- ---------------------------------------------------------------------------

--- Everything above that belongs to a buffer. Called from client.lua's `on_attach`.
--- @param client vim.lsp.Client
--- @param bufnr integer
--- @param cfg table
function M.on_attach(client, bufnr, cfg)
  M.setup_document_highlight(client, bufnr, cfg)
  M.setup_signature_help(client, bufnr, cfg)
  M.setup_keymaps(client, bufnr, cfg)
  M.setup_format_on_save(client, bufnr, cfg)
end

--- The user commands. Registered once from `setup()`, not per buffer: they are global by nature
--- and answer with "no server" rather than not existing when nothing is attached.
function M.register_commands()
  vim.api.nvim_create_user_command('IntellijLspTypeHierarchy', function(cmd)
    M.type_hierarchy(cmd.args)
  end, {
    nargs = '?',
    complete = function() return M.TYPE_HIERARCHY_KINDS end,
    desc = 'Type hierarchy of the symbol at the cursor: subtypes (default) or supertypes',
  })
  vim.api.nvim_create_user_command('IntellijLspCallHierarchy', function(cmd)
    M.call_hierarchy(cmd.args)
  end, {
    nargs = '?',
    complete = function() return M.CALL_HIERARCHY_KINDS end,
    desc = 'Call hierarchy of the method at the cursor: incoming (default) or outgoing',
  })
  vim.api.nvim_create_user_command('IntellijLspFormat', function(cmd)
    if cmd.range > 0 then
      M.format({ line1 = cmd.line1, line2 = cmd.line2 })
    else
      M.format({})
    end
  end, {
    range = true,
    desc = 'Format the buffer, or the given range, with the IntelliJ formatter',
  })
  vim.api.nvim_create_user_command('IntellijLspSymbols', function(cmd)
    M.workspace_symbol(cmd.args)
  end, {
    nargs = '?',
    desc = 'Search workspace symbols (classes, methods, fields); prompts without a query',
  })
end

return M
