--- Custom protocol extensions gated behind the `intellijExtensions` opt-in.
---
--- These are deliberately kept out of progress.lua, whose notifications arrive whether or not the
--- client opts in. Everything here is the opposite: the server only sends it because
--- `initializationOptions.intellijExtensions` said the client could handle it, so the handlers and
--- the flag have to ship together.
---
--- What the opt-in actually buys is quick fixes, not new UI. A `ModCommand` that copies to the
--- clipboard or asks the user to pick a variant maps to null without the flag, and the server
--- turns a null part into a null whole, so the surrounding fix disappears from `gra` entirely
--- rather than degrading.
---
--- Four messages, in the order the server grew them:
---
---   * `intellij/copyToClipboard`  notification. `{content}`.
---   * `intellij/chooseAction`     notification. Two shapes, see `choose_action` below.
---   * `intellij/runEditorCommand` notification. `{command, arguments, uri?}`: an editor action
---                                 the client must perform itself, after the edit was applied.
---   * `intellij/showConflicts`    *request*. `{title, conflicts[], continueLabel, cancelLabel,
---                                 revealLabel, documentChangedLabel}` -> `{decision}`. Unhandled,
---                                 Neovim answers MethodNotFound, the server reads that as cancel,
---                                 and the fix does nothing and says nothing.

local M = {}

local COPY_TO_CLIPBOARD = 'intellij/copyToClipboard'
local CHOOSE_ACTION = 'intellij/chooseAction'
local RUN_EDITOR_COMMAND = 'intellij/runEditorCommand'
local SHOW_CONFLICTS = 'intellij/showConflicts'

--- Command the *old* server exposes to receive the answer to `intellij/chooseAction`.
local CHOOSE_ACTION_REPLY = 'chooseModCommandAction'

-- ---------------------------------------------------------------------------
-- Editor commands
-- ---------------------------------------------------------------------------

--- The VS Code command ids the server asks the client to run, and what they mean here.
---
--- These are VS Code's command names, which the server uses as-is; they carry no
--- arguments in any current use. `rename` follows "introduce variable" and "extract method": the
--- server first sends `window/showDocument` selecting the new name, then asks for a rename so the
--- user can type over it. The other two follow a completion that inserted a call: reopen the
--- completion menu, or show the parameter popup.
M.EDITOR_COMMANDS = {
  ['editor.action.rename'] = function() vim.lsp.buf.rename() end,
  ['editor.action.triggerSuggest'] = function()
    -- The menu only makes sense in insert mode; after a normal-mode edit there is nothing to feed.
    if vim.fn.mode():sub(1, 1) == 'i' then vim.lsp.completion.get() end
  end,
  ['editor.action.triggerParameterHints'] = function() vim.lsp.buf.signature_help() end,
}

--- Runs one editor command, if it is one we know and it targets the current buffer.
---
--- `uri` is the document the command is meant for. The server documents the race: by the time
--- the notification arrives the user may have moved to another buffer, and a rename started there
--- would rename the wrong symbol. So the command is dropped unless the URI is the current buffer.
--- Unknown commands are ignored silently, as the server adds names faster than clients ship.
--- @param command string
--- @param uri string|nil
--- @return boolean ran
function M.run_editor_command(command, uri)
  local fn = M.EDITOR_COMMANDS[command]
  if not fn then return false end
  if uri and vim.uri_to_bufnr(uri) ~= vim.api.nvim_get_current_buf() then return false end
  fn()
  return true
end

--- Client-side commands, for the same names arriving on a `CompletionItem.command`.
---
--- With the extensions on, a completion that needs a follow-up (a snippet that ends on a name to
--- rename, a call whose parameters should be shown) carries one of these as a plain LSP `Command`
--- instead of a `runEditorCommand` notification. Neovim dispatches `item.command` through
--- `client:exec_cmd`, which runs a client-side command when one is registered under that name and
--- otherwise forwards it to the server, which does not know it. Registering them on the client
--- keeps the dispatch local. Same shape as `vim.lsp.commands`: `fn(command, ctx)`.
--- @return table<string, fun(command: lsp.Command, ctx: table)>
function M.commands()
  local cmds = {}
  for name in pairs(M.EDITOR_COMMANDS) do
    cmds[name] = function(_, ctx)
      -- A completion command runs in the buffer that completed; `bufnr` is that buffer.
      local uri = ctx and ctx.bufnr and vim.uri_from_bufnr(ctx.bufnr) or nil
      M.run_editor_command(name, uri)
    end
  end
  return cmds
end

-- ---------------------------------------------------------------------------
-- Choose action
-- ---------------------------------------------------------------------------

--- @param client_id integer
--- @param session_id any
--- @param index any
local function reply_with_choice(client_id, session_id, index)
  local client = vim.lsp.get_client_by_id(client_id)
  if not client then return end
  -- Argument order matches what the server expects: session first, then the index carried by the
  -- chosen entry (not its position in the list, which may differ).
  client:exec_cmd({ command = CHOOSE_ACTION_REPLY, arguments = { session_id, index } })
end

--- Presents the server's variants and runs, or reports, the one picked.
---
--- Two payload shapes, told apart by the entry:
---
---   * Bundle 263.4702.0 and earlier: `{sessionId, title?, entries[{index, name}]}`. The choice is
---     reported back through the `chooseModCommandAction` executeCommand, with the session and the
---     entry's own index. A dismissed picker still has to answer: the server keeps the session
---     cached until it hears back, so returning nothing would leak it for the life of the process.
---   * Later server builds: `{title, entries[{name, command}]}`. Each entry
---     carries a complete LSP `Command` (in practice `applyModCommand` with a lazy-action handle),
---     and picking one means executing it. Nothing is reported for a dismissal; there is no session.
---
--- Re-entrant on purpose: picking an entry can produce another ModCommand that chooses again, so
--- this must tolerate being called while a previous pick is still settling.
--- @param result table
--- @param client_id integer
function M.choose_action(result, client_id)
  local entries = result and result.entries
  if type(entries) ~= 'table' or #entries == 0 then return end

  local prompt = result.title and result.title ~= '' and result.title or 'IntelliJ: choose an action'
  vim.ui.select(entries, {
    prompt = prompt,
    format_item = function(entry) return entry.name or tostring(entry.index) end,
  }, function(choice)
    if choice and choice.command then
      local client = vim.lsp.get_client_by_id(client_id)
      if client then
        client:exec_cmd(choice.command, { bufnr = vim.api.nvim_get_current_buf() })
      end
      return
    end
    if result.sessionId ~= nil then
      reply_with_choice(client_id, result.sessionId, choice and choice.index or vim.NIL)
    end
  end)
end

-- ---------------------------------------------------------------------------
-- Show conflicts
-- ---------------------------------------------------------------------------

--- One picker row per conflict: where, then what. The label is `File.java:12` and the detail is
--- the messages.
--- @param conflict table
--- @return string
function M._conflict_label(conflict)
  local where = '-'
  local loc = conflict.location
  if loc and loc.uri then
    local name = vim.fs.basename(vim.uri_to_fname(loc.uri))
    local line = loc.range and loc.range.start and loc.range.start.line
    where = line and ('%s:%d'):format(name, line + 1) or name
  end
  local messages = conflict.messages
  local text = type(messages) == 'table' and table.concat(messages, ' ') or tostring(messages or '')
  return where .. '  ' .. text
end

--- Answers `intellij/showConflicts`.
---
--- The server found usages the refactoring would break (a rename that shadows a field, a move
--- that loses visibility) and asks whether to go ahead. The list shows every conflict, then the
--- two decisions. Picking a conflict jumps to it and asks again, so the user can look before
--- deciding; picking a decision, or dismissing, answers. Dismissal is `cancel`: the server treats a
--- non-answer as cancel too, so this only makes the implicit explicit.
---
--- The request's handler must produce a reply, and Neovim runs server-to-client request handlers
--- inside a coroutine precisely so they can wait on the UI: yield here, resume from the picker's
--- callback, and the response goes out when the coroutine finishes. This is the same pattern as
--- Neovim's own `window/showMessageRequest` handler. Outside a coroutine (a direct call from a
--- test) the picker is still shown and the first decision is returned synchronously if the picker
--- answered inline, else `cancel`.
---
--- A buffer edit while the question is open answers `cancel` as well: the server compares document
--- versions after the reply and aborts on a change anyway, and answering early is what stops a
--- `continue` from landing on a document the user has already moved on from.
--- @param params table
--- @return { decision: string }
function M.show_conflicts(params)
  params = params or {}
  local conflicts = type(params.conflicts) == 'table' and params.conflicts or {}
  local continue_label = params.continueLabel or 'Continue'
  local cancel_label = params.cancelLabel or 'Cancel'

  local co, is_main = coroutine.running()
  local in_coroutine = co and not is_main

  local answered, yielded = false, false
  local decision --- @type string|nil
  local function answer(d)
    if answered then return end
    answered = true
    decision = d
    -- Only a handler that actually yielded needs resuming: a synchronous picker answers before
    -- the yield below is reached, and that path simply falls through. Scheduled so that an
    -- asynchronous picker answering from a timer or another event never resumes mid-callback.
    if yielded then
      vim.schedule(function() coroutine.resume(co) end)
    end
  end

  -- Editing anything while the question is open is a cancel.
  local group = vim.api.nvim_create_augroup('IntellijLspShowConflicts', { clear = true })
  vim.api.nvim_create_autocmd({ 'TextChanged', 'TextChangedI' }, {
    group = group,
    desc = 'IntelliJ: a document changed while conflicts were shown',
    callback = function()
      if not answered then
        vim.notify(params.documentChangedLabel or 'IntelliJ LSP: the document changed; refactoring cancelled',
          vim.log.levels.WARN)
        answer('cancel')
      end
    end,
  })

  local function ask()
    if answered then return end
    local items = {}
    for _, c in ipairs(conflicts) do
      items[#items + 1] = { kind = 'conflict', conflict = c, label = M._conflict_label(c) }
    end
    items[#items + 1] = { kind = 'continue', label = continue_label }
    items[#items + 1] = { kind = 'cancel', label = cancel_label }

    vim.ui.select(items, {
      prompt = params.title or 'IntelliJ: conflicts found',
      format_item = function(item) return item.label end,
    }, function(choice)
      if answered then return end
      if not choice or choice.kind == 'cancel' then
        answer('cancel')
      elseif choice.kind == 'continue' then
        answer('continue')
      else
        -- Reveal, then ask again. Jumping does not edit, so the TextChanged guard stays quiet.
        local loc = choice.conflict.location
        if loc and loc.uri then
          pcall(vim.lsp.util.show_document, loc, 'utf-16', { focus = true })
        end
        vim.schedule(ask)
      end
    end)
  end
  ask()

  if in_coroutine and not answered then
    yielded = true
    coroutine.yield()
  end
  pcall(vim.api.nvim_del_augroup_by_id, group)
  return { decision = decision or 'cancel' }
end

-- ---------------------------------------------------------------------------
-- Handlers
-- ---------------------------------------------------------------------------

--- LSP handlers for the opt-in messages.
--- @return table<string, function>
function M.handlers()
  return {
    [COPY_TO_CLIPBOARD] = function(_, result, _)
      local content = result and result.content
      if type(content) ~= 'string' then return end
      -- Both registers, so the fix behaves the same whether or not the user runs with
      -- `clipboard=unnamedplus`.
      vim.fn.setreg('+', content)
      vim.fn.setreg('*', content)
    end,

    [CHOOSE_ACTION] = function(_, result, ctx)
      M.choose_action(result, ctx.client_id)
    end,

    [RUN_EDITOR_COMMAND] = function(_, result, _)
      if type(result) ~= 'table' or type(result.command) ~= 'string' then return end
      -- The edit this follows was applied from the same message stream a moment ago, and the
      -- `showDocument` that selects the target may still be settling; run after both.
      vim.schedule(function()
        pcall(M.run_editor_command, result.command, result.uri)
      end)
    end,

    [SHOW_CONFLICTS] = function(_, params, _)
      return M.show_conflicts(params)
    end,
  }
end

return M
