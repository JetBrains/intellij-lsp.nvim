--- Sign-in pages in the browser, and the sign-in for machines whose browser cannot reach back.
---
--- A JetBrains Account sign-in (`jba/login`), and a license server that wants one, open their page
--- through `window/showDocument` with `external = true`. Neovim's default handler would call
--- `vim.ui.open` and nothing more; on a machine without an opener, or one where the browser opens
--- behind the editor, the user never sees where to go. This handler opens the page, shows its URL in
--- a float, copies it to the clipboard, and keeps a spinner going until the request that asked for
--- the page replies. It answers `success = true` either way, so the server keeps waiting: the user
--- can still open the URL by hand.
---
--- The browser sign-in ends in a redirect to a listener on the server's machine. From an SSH
--- session, or a Linux box without a display, the browser runs elsewhere and the redirect has nowhere
--- to go, so that sign-in is not offered there. The server's CLI has a sign-in that needs no
--- redirect: `license login --code` prints the URL and reads back the code the page shows. It runs
--- in a terminal split, writes the license store, and every running server picks the license up
--- from the store within about a second, no restart.

local M = {}

local INFO, WARN = vim.log.levels.INFO, vim.log.levels.WARN

local function notify(text, level)
  vim.notify('IntelliJ LSP: ' .. text, level or INFO)
end

--- Whether a browser started from here cannot reach back to a listener on this machine: an SSH
--- session, or Linux (and the BSDs) without a display. The server's CLI decides the same way which
--- `license login` to run.
--- @param env table|nil environment to read; `vim.env` when nil
--- @param sysname string|nil `vim.uv.os_uname().sysname` when nil
--- @return boolean
function M.remote(env, sysname)
  env = env or vim.env
  local function set(name) return env[name] ~= nil and env[name] ~= '' end
  if set('SSH_CONNECTION') or set('SSH_TTY') then return true end
  sysname = sysname or vim.uv.os_uname().sysname
  if sysname == 'Darwin' or sysname:match('^Windows') then return false end
  return not set('DISPLAY') and not set('WAYLAND_DISPLAY')
end

--- Copies text to the `+` register when a clipboard provider exists (over SSH, Neovim's OSC 52
--- provider carries it to the local terminal).
--- @param text string
--- @return boolean copied
function M._copy(text)
  if vim.fn.has('clipboard') ~= 1 then return false end
  return (pcall(vim.fn.setreg, '+', text))
end

--- Opens a URL in the browser; false when there is no opener.
--- @param uri string
--- @return boolean
function M._open(uri)
  local ok, cmd = pcall(vim.ui.open, uri)
  return ok and cmd ~= nil
end

-- ---------------------------------------------------------------------------
-- The sign-in page float
-- ---------------------------------------------------------------------------

local SPINNER = { '⠋', '⠙', '⠹', '⠸', '⠼', '⠴', '⠦', '⠧', '⠇', '⠏' }
local WAITING = 'Waiting for the sign-in in your browser…'

--- The float on screen: its window, the spinner's timer, the client whose request it waits on.
--- @type { win: integer, buf: integer, timer: uv.uv_timer_t, client_id: integer, closing: boolean }|nil
local page = nil

local event_group = vim.api.nvim_create_augroup('intellij-lsp.signin', { clear = true })

--- Closes the sign-in float, if any, without cancelling what it waits on. Called when the request
--- that opened the page replies, and when its server exits.
function M.close()
  local current = page
  if not current then return end
  page = nil
  current.closing = true
  current.timer:stop()
  current.timer:close()
  pcall(vim.api.nvim_win_close, current.win, true)
end

--- The float's lines, before the spinner line.
--- @param uri string
--- @param opened boolean
--- @param copied boolean
--- @return string[]
function M._lines(uri, opened, copied)
  local lines = {
    opened and ' Opened the sign-in page in your browser. If it is not there, open this link:'
      or ' Open this link in a browser to sign in:',
    '',
    ' ' .. uri,
    '',
  }
  if copied then lines[#lines + 1] = ' Copied to the clipboard.' end
  return lines
end

--- Shows the sign-in page: opens it in the browser (not from a remote session, where that browser
--- would be on the wrong machine), copies the URL, and keeps a float with the URL and a spinner up
--- until `M.close`. `<Esc>`, `q` or closing the float cancels a pending JetBrains Account sign-in; a
--- license server's sign-in has no cancel request, so there it only hides the float.
--- @param uri string
--- @param client_id integer
--- @return integer win
function M.show_page(uri, client_id)
  M.close()
  local opened = not M.remote() and M._open(uri)
  local copied = M._copy(uri)

  local lines = M._lines(uri, opened, copied)
  table.insert(lines, ' ' .. SPINNER[1] .. ' ' .. WAITING)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = 'wipe'
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false

  -- Same width and title as the other licensing floats. Required here, not at the top: activation.lua
  -- requires this module.
  local activation = require('intellij-lsp.activation')
  local width = activation.width()
  local win = vim.api.nvim_open_win(buf, true, {
    relative = 'editor', row = 0, col = 0, width = width, height = #lines,
    style = 'minimal', border = 'rounded', zindex = 200,
    title = ' ' .. activation.title('Sign in') .. ' ', title_pos = 'center',
    footer = ' y  copy    o  open    <Esc>  cancel ', footer_pos = 'center',
  })
  vim.wo[win].wrap = true
  local height = math.min(vim.api.nvim_win_text_height(win, {}).all, vim.o.lines - 4)
  vim.api.nvim_win_set_config(win, {
    relative = 'editor', height = height,
    row = math.floor((vim.o.lines - height) / 2) - 1,
    col = math.floor((vim.o.columns - width) / 2),
  })

  local current = { win = win, buf = buf, timer = vim.uv.new_timer(), client_id = client_id, closing = false }
  page = current

  local frame = 1
  current.timer:start(100, 100, vim.schedule_wrap(function()
    if page ~= current or not vim.api.nvim_buf_is_valid(buf) then return end
    frame = frame % #SPINNER + 1
    vim.bo[buf].modifiable = true
    vim.api.nvim_buf_set_lines(buf, -2, -1, false, { ' ' .. SPINNER[frame] .. ' ' .. WAITING })
    vim.bo[buf].modifiable = false
  end))

  local function cancel()
    if current.closing then return end
    M.close()
    if activation.login_pending() then activation.cancel_login() end
  end
  local map_opts = { buffer = buf, nowait = true }
  vim.keymap.set('n', '<Esc>', cancel, map_opts)
  vim.keymap.set('n', 'q', cancel, map_opts)
  vim.keymap.set('n', 'y', function()
    if M._copy(uri) then notify('copied the sign-in link to the clipboard.') end
  end, map_opts)
  vim.keymap.set('n', 'o', function() M._open(uri) end, map_opts)
  vim.api.nvim_create_autocmd('WinClosed', {
    group = event_group,
    pattern = tostring(win),
    once = true,
    callback = function() vim.schedule(cancel) end,
  })
  return win
end

-- Nobody is left to answer the page once its server exits.
vim.api.nvim_create_autocmd('User', {
  group = event_group,
  pattern = require('intellij-lsp.licensing').EVENT,
  callback = function(ev)
    if page and ev.data and ev.data.view == nil and ev.data.client_id == page.client_id then M.close() end
  end,
})

--- `window/showDocument`: external pages go to `M.show_page`, everything else to Neovim's handler.
--- @type lsp.Handler
function M.show_document(err, params, ctx, config)
  if params and params.external then
    M.show_page(params.uri, ctx.client_id)
    return { success = true }
  end
  return vim.lsp.handlers['window/showDocument'](err, params, ctx, config)
end

--- Handlers to merge into the client's own.
--- @return table<string, function>
function M.handlers()
  return { ['window/showDocument'] = M.show_document }
end

-- ---------------------------------------------------------------------------
-- Paste-code sign-in through the CLI
-- ---------------------------------------------------------------------------

--- The CLI sign-in: the paste-code one with `code`, otherwise the one the CLI picks for this
--- machine (paste-code from a remote session, the browser with its redirect elsewhere).
--- @param launcher string `bin/intellij-server`
--- @param code boolean
--- @return string[]
function M.login_cmd(launcher, code)
  local cmd = { launcher, 'license', 'login' }
  if code then table.insert(cmd, '--code') end
  return cmd
end

--- The server CLI's output without its terminal color codes.
--- @param text string
--- @return string
function M.strip_ansi(text)
  return (text:gsub('\27%[[%d;?]*%a', ''))
end

--- The sign-in URL in the CLI's output so far, once its line is complete. The CLI prints the URL as
--- it is, query spaces included, so they are encoded here to make a link a browser takes whole.
--- @param output string
--- @return string|nil
function M._sign_in_url(output)
  local url = M.strip_ansi(output):match('Sign in to JetBrains Account: (https://[^\r\n]-)%s*[\r\n]')
  return url and (url:gsub(' ', '%%20')) or nil
end

--- Runs `license login` in a terminal split, `--code` unless `opts.code` is false. The paste-code
--- sign-in prints the URL (copied to the clipboard here, and opened in the browser when that browser
--- is on this machine) and asks for the code the page shows once signed in; the CLI's browser
--- sign-in opens the page itself. A successful sign-in closes the split; a failed one leaves it open
--- with the CLI's reason.
--- @param launcher string `bin/intellij-server`
--- @param env table<string, string>|nil the server's full environment (license dir, region)
--- @param opts { code: boolean|nil }|nil
--- @return integer|nil job
function M.terminal_login(launcher, env, opts)
  local code = not (opts and opts.code == false)
  vim.cmd('botright 12new')
  local win, buf = vim.api.nvim_get_current_win(), vim.api.nvim_get_current_buf()
  vim.bo[buf].bufhidden = 'wipe'

  local output, url = '', nil
  local job = vim.fn.jobstart(M.login_cmd(launcher, code), {
    term = true,
    env = env,
    clear_env = env ~= nil,
    on_stdout = function(_, data)
      if url then return end
      output = output .. table.concat(data, '\n')
      url = M._sign_in_url(output)
      if not url then return end
      vim.schedule(function()
        if code and not M.remote() then M._open(url) end
        if M._copy(url) then notify('copied the sign-in link to the clipboard.') end
      end)
    end,
    on_exit = function(_, code)
      vim.schedule(function()
        if not vim.api.nvim_buf_is_valid(buf) then return end -- closed by the user
        if code == 0 then
          pcall(vim.api.nvim_win_close, win, true)
          notify('signed in. Every running server picks up the license within seconds.')
        else
          notify('the sign-in did not complete; the terminal says why.', WARN)
        end
      end)
    end,
  })
  if job <= 0 then
    pcall(vim.api.nvim_win_close, win, true)
    notify('could not run ' .. launcher .. '.', WARN)
    return nil
  end
  vim.cmd('startinsert')
  return job
end

--- Forgets the float, for tests.
function M._reset()
  M.close()
end

return M
