--- Document-version translation for the edits the server sends back.
---
--- Works around a server bug. The server ignores the `version` a client puts on
--- `textDocument/didChange` and keeps a counter of its own instead: `didOpen` seeds it with the
--- version the client sent, every `didChange` notification adds exactly one, `didClose` drops it.
--- Every versioned edit it later returns --
--- rename, file rename, extract, inline -- is stamped with that counter.
---
--- Neovim numbers documents differently. It sends `b:changedtick`, which starts above zero when a
--- file loads and grows by one per buffer mutation, and one `didChange` routinely carries several
--- mutations: a reformat applies its text edits one by one, a rename touches every usage, and the
--- 150ms debounce batches keystrokes. So after the very first edit the server's number is behind
--- Neovim's, and `vim.lsp.util.apply_text_document_edit` rejects the edit as stale ("Buffer ...
--- newer than edits."). Rename works exactly once per buffer, until the first edit.
---
--- VS Code never sees this: its document version grows by exactly one per `didChange`, so the
--- server's counter stays in lock-step by coincidence.
---
--- Rather than switch the staleness check off, this module keeps the server's counter and Neovim's
--- ticks side by side. Every notification the client sends is recorded, so for each value the
--- server's counter can take, the tick Neovim had at that moment is known. A version in a response
--- is then rewritten to that tick, and Neovim's own check compares like with like: an edit computed
--- before a later `didChange` is still rejected, one computed against the current text passes.
---
--- Three cases fall outside the ledger and are decided in this order:
---
---   1. The counter value is known: translate. This comes first because the server's counter can
---      coincide with a tick Neovim sent earlier (five single-keystroke changes after a tick of 5),
---      and the counter reading is the one that describes the server as it is today.
---   2. The value is a tick this client sent: pass it through. A server that stores the client's
---      version, which is what the fix looks like, answers with exactly these, and the workaround
---      then does nothing. Retire this module once such a bundle is the minimum the plugin runs.
---   3. Anything else: `vim.NIL`, which is the spec's "no version" and skips the check. This also
---      covers edits the server sends with no version at all. Neovim reads a missing key as Lua
---      `nil`, compares it with `> 0`, and raises -- so normalising it is a fix in its own right.
---
--- Installed per client from `on_init`, before any buffer attaches, by wrapping `notify` (to feed the
--- ledger) and `request` (to rewrite results) on that client instance. Server-initiated
--- `workspace/applyEdit` requests have no request to wrap and are handled by the handler in
--- `client.lua`.

local M = {}

--- Counter values older than this many notifications are forgotten. A response referring to one is
--- treated as stale, which it is.
local KEEP = 512

--- @class intellij-lsp.versions.Ledger
--- @field latest integer      the server's counter as of the last notification
--- @field oldest integer      the smallest counter value still mapped
--- @field ticks table<integer, integer>  server counter -> Neovim tick sent with that notification
--- @field sent table<integer, true>      every tick this client has sent for the document

--- @type table<integer, table<string, intellij-lsp.versions.Ledger>>  client id -> uri -> ledger
local ledgers = {}

--- @param client_id integer
--- @param uri string
--- @return intellij-lsp.versions.Ledger|nil
local function ledger(client_id, uri)
  local by_uri = ledgers[client_id]
  return by_uri and by_uri[uri] or nil
end

--- Records a notification the client is about to send.
--- @param client_id integer
--- @param method string
--- @param params table
function M.on_notify(client_id, method, params)
  local td = params and params.textDocument
  if not td or type(td.uri) ~= 'string' then return end

  if method == 'textDocument/didOpen' then
    local version = type(td.version) == 'number' and td.version or 0
    ledgers[client_id] = ledgers[client_id] or {}
    ledgers[client_id][td.uri] = {
      latest = version,
      oldest = version,
      ticks = { [version] = version },
      sent = { [version] = true },
    }
  elseif method == 'textDocument/didChange' then
    local l = ledger(client_id, td.uri)
    if not l or type(td.version) ~= 'number' then return end
    l.latest = l.latest + 1
    l.ticks[l.latest] = td.version
    l.sent[td.version] = true
    while l.latest - l.oldest >= KEEP do
      l.sent[l.ticks[l.oldest]] = nil
      l.ticks[l.oldest] = nil
      l.oldest = l.oldest + 1
    end
  elseif method == 'textDocument/didClose' then
    local by_uri = ledgers[client_id]
    if by_uri then by_uri[td.uri] = nil end
  end
end

--- The version Neovim should compare against, for a version the server put on an edit.
--- @param client_id integer
--- @param uri string
--- @param version any  what the server sent: a number, `vim.NIL`, or nil when the key was absent
--- @return integer|vim.NIL
function M.translate(client_id, uri, version)
  if version == nil then return vim.NIL end
  if type(version) ~= 'number' or version <= 0 then return version end
  local l = ledger(client_id, uri)
  if not l then return version end
  local tick = l.ticks[version]
  if tick then return tick end
  if l.sent[version] then return version end
  -- Older than the ledger remembers: stale by any reading, so answer with a tick that fails the check.
  if version < l.oldest then return l.ticks[l.oldest] end
  return vim.NIL
end

--- Rewrites the versions inside a `WorkspaceEdit` in place.
--- @param client_id integer
--- @param edit table|nil
function M.fix_workspace_edit(client_id, edit)
  if type(edit) ~= 'table' or type(edit.documentChanges) ~= 'table' then return end
  for _, change in ipairs(edit.documentChanges) do
    local td = not change.kind and change.textDocument
    if td and type(td.uri) == 'string' then
      td.version = M.translate(client_id, td.uri, td.version)
    end
  end
end

--- Rewrites the versions inside a response, for the methods whose result carries edits.
--- @param client_id integer
--- @param method string
--- @param result any
function M.fix_result(client_id, method, result)
  if type(result) ~= 'table' then return end
  if method == 'textDocument/rename' or method == 'workspace/willRenameFiles' then
    M.fix_workspace_edit(client_id, result)
  elseif method == 'codeAction/resolve' then
    M.fix_workspace_edit(client_id, result.edit)
  elseif method == 'textDocument/codeAction' then
    for _, action in ipairs(result) do
      if type(action) == 'table' then M.fix_workspace_edit(client_id, action.edit) end
    end
  end
end

--- The client-to-server requests whose results `fix_result` rewrites.
local FIXED_METHODS = {
  ['textDocument/rename'] = true,
  ['workspace/willRenameFiles'] = true,
  ['textDocument/codeAction'] = true,
  ['codeAction/resolve'] = true,
}

--- Wraps `notify` and `request` on one client instance. Instance fields shadow the `vim.lsp.Client`
--- methods, and every caller in Neovim -- change tracking, `vim.lsp.buf.*`, `request_sync` -- goes
--- through `client:notify` / `client:request`, so this sees all of them.
--- @param client table  a `vim.lsp.Client`, or anything with `id`, `notify`, `request`, `handlers`
function M.install(client)
  local orig_notify, orig_request = client.notify, client.request

  client.notify = function(self, method, params, ...)
    M.on_notify(self.id, method, params)
    return orig_notify(self, method, params, ...)
  end

  client.request = function(self, method, params, handler, ...)
    if not FIXED_METHODS[method] then
      return orig_request(self, method, params, handler, ...)
    end
    -- `vim.lsp.buf.code_action` passes its own callbacks and applies the edits itself, so a handler
    -- table entry never sees them. Wrapping the callback here is the one place that catches every
    -- path. A nil handler is resolved the way `Client:request` would, so behaviour is unchanged.
    local h = handler or (self.handlers and self.handlers[method]) or vim.lsp.handlers[method]
    if not h then
      -- Let `Client:request` raise its own "no handler" error rather than a nil call from here.
      return orig_request(self, method, params, handler, ...)
    end
    return orig_request(self, method, params, function(err, result, ...)
      M.fix_result(self.id, method, result)
      return h(err, result, ...)
    end, ...)
  end
end

--- Forgets everything recorded for a client, once it has exited.
--- @param client_id integer
function M.reset(client_id)
  ledgers[client_id] = nil
end

return M
