--- Two-pane diff of the current file against the index or a revision.
---
--- Distinct from the panel's preview, which renders unified `git diff` text. This uses Neovim's own
--- 'diff' mode, so the two panes scroll together, changed regions are highlighted per-line, and `]c`
--- / `[c` / `do` / `dp` all work -- the closest thing Neovim has to the IDE's side-by-side viewer.
---
--- The revision side is a scratch buffer holding `git show`'s output, never a file on disk: writing a
--- temp file would leave it behind and make the pane look editable when writing to it is meaningless.
--- 'modifiable' is off for the same reason, and `dp` (diff put) into a read-only buffer fails loudly
--- rather than silently discarding work.

local cmd = require('intellij-lsp.git.cmd')

local M = {}

--- Explains why a write into the revision pane cannot work, in place of `E21`.
---
--- Neovim's diff mode offers two symmetric transfers, but only one of them means anything here:
---
---   * `do` ("diff obtain") pulls the revision's version of a hunk into the working file. Against the
---     index that *is* "revert this hunk", which is the operation wanted almost every time.
---   * `dp` ("diff put") would write into a `git show` snapshot. There is nothing to write to -- the
---     buffer is a rendering of an object that already exists -- so it is off.
---
--- Left to itself that asymmetry surfaces as a bare `E21: Cannot make changes, 'modifiable' is off`
--- on a pane that looks exactly like the other one, which reads as the diff view being broken. The
--- same applies to `do` pressed *in* the revision pane, where the target is the read-only side.
---
--- Staging a single hunk -- the direction `dp` looks like it should serve -- is deliberately not
--- mapped to something approximate. It writes to the index rather than to either buffer, so it needs a
--- synthesized patch through `git apply --cached`; that is Phase 2 work and doing it badly corrupts
--- the index.
--- @param what string the key the user pressed
local function explain_readonly(what)
  vim.notify(
    ('IntelliJ git: `%s` would write to the %s pane, which is a read-only snapshot. '
      .. 'Use `do` in the working-tree pane to take the other side of a hunk; staging individual '
      .. 'hunks is not implemented yet.'):format(what, 'revision'),
    vim.log.levels.WARN
  )
end

--- Maps the diff-transfer keys in both panes so neither direction fails with a bare `E21`.
---
--- Buffer-local, so diff mode elsewhere (a `:diffsplit` of two ordinary files, where `dp` is perfectly
--- valid) keeps its normal behaviour.
--- @param work_buf integer the working-tree buffer
--- @param rev_buf integer the read-only revision buffer
local function map_transfer_keys(work_buf, rev_buf)
  -- Working pane: `do` is genuinely useful and left alone; only `dp` is intercepted.
  vim.keymap.set('n', 'dp', function() explain_readonly('dp') end, {
    buffer = work_buf,
    desc = 'IntelliJ git: diff put is unavailable (revision pane is read-only)',
  })

  -- Revision pane: both directions target the read-only buffer, so both are intercepted.
  for _, key in ipairs({ 'do', 'dp' }) do
    vim.keymap.set('n', key, function() explain_readonly(key) end, {
      buffer = rev_buf,
      desc = 'IntelliJ git: this pane is a read-only snapshot',
    })
  end
end

--- Path of `bufnr` relative to the repository root.
---
--- git needs a repo-relative path for `show <rev>:<path>`, and `--show-prefix` is the only correct way
--- to get one: subtracting the root prefix by hand breaks when the buffer is reached through a symlink
--- (on macOS, any file under /tmp) because the buffer name and the root resolve differently.
--- @param root string
--- @param bufnr integer
--- @return string|nil
function M.relative_path(root, bufnr)
  local name = vim.api.nvim_buf_get_name(bufnr)
  if name == '' then return nil end

  local res = cmd.run_sync({ 'ls-files', '--full-name', '--', name }, { cwd = vim.fs.dirname(name) })
  local rel = res.ok and vim.split(res.stdout, '\n', { trimempty = true })[1] or nil
  if rel and rel ~= '' then return rel end

  -- Not tracked (a new file): fall back to a prefix subtraction, which is correct for the common case
  -- of a file opened by a path already under the root.
  local normalized = vim.fs.normalize(name)
  if normalized:sub(1, #root + 1) == root .. '/' then
    return normalized:sub(#root + 2)
  end
  return nil
end

--- Opens a diff of the current file against `rev`.
---
--- `rev` is a git revision or the empty string for the index -- `git show :path` reads the staged
--- copy, which is what "diff against index" means and is not the same as HEAD once something is
--- staged.
--- @param rev string|nil defaults to the index
function M.open(rev)
  local bufnr = vim.api.nvim_get_current_buf()
  local root = cmd.root()
  if not root then
    vim.notify('IntelliJ git: not inside a git repository.', vim.log.levels.WARN)
    return
  end

  local rel = M.relative_path(root, bufnr)
  if not rel then
    vim.notify('IntelliJ git: the current buffer has no file in this repository.', vim.log.levels.WARN)
    return
  end

  -- `:<path>` is the index; `<rev>:<path>` is a commit. The empty-string default keeps the common case
  -- ("what have I changed?") a bare `:IntellijGitDiff`.
  local spec = (rev and rev ~= '' and rev or '') .. ':' .. rel
  local label = (rev and rev ~= '' and rev or 'index')

  cmd.run({ 'show', spec }, { cwd = root }, function(res)
    if not res.ok then
      vim.notify(
        ('IntelliJ git: cannot read %s (%s)'):format(spec, cmd.error_message(res)),
        vim.log.levels.ERROR
      )
      return
    end

    -- Guard against the buffer having gone away while git ran.
    if not vim.api.nvim_buf_is_valid(bufnr) then return end

    local lines = vim.split(res.stdout, '\n', { plain = true })
    -- git's output ends with a newline, which would otherwise show as a spurious trailing blank line
    -- and register as a difference against a file that has none.
    if lines[#lines] == '' then table.remove(lines) end

    local scratch = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(scratch, 0, -1, false, lines)
    vim.bo[scratch].buftype = 'nofile'
    vim.bo[scratch].swapfile = false
    vim.bo[scratch].bufhidden = 'wipe'
    vim.bo[scratch].modifiable = false
    -- Syntax highlighting in the revision pane: copied from the working-tree buffer rather than
    -- re-detected, because detection runs on the *name*, and this buffer's name is a git spec. Applied
    -- without sourcing ftplugins -- see `session.set_scratch_filetype` for why that matters on Java.
    require('intellij-lsp.git.session').set_scratch_filetype(scratch, vim.bo[bufnr].filetype)
    vim.api.nvim_buf_set_name(scratch, ('intellij-git://%s/%s'):format(label, rel))

    -- The working-tree pane is the current window, so diff mode is entered there first and the
    -- revision opens to its left -- older on the left, matching every other diff tool.
    vim.cmd('diffthis')
    vim.cmd('leftabove vsplit')
    local win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(win, scratch)
    vim.cmd('diffthis')

    -- Leaves the cursor in the working-tree pane: that is the side the user can edit, and landing in
    -- a read-only pane makes the first keystroke fail for no visible reason.
    vim.cmd('wincmd p')

    -- `]c` / `[c` / `do` need nothing from us -- they are diff mode's own. Only the transfers that
    -- would target the read-only pane are intercepted, so they explain themselves instead of raising
    -- E21 on a pane that looks identical to the writable one.
    map_transfer_keys(bufnr, scratch)

    -- `:diffoff!` on wipe, so closing the revision pane does not leave the working-tree buffer stuck
    -- in diff mode with 'foldmethod=diff' and its window options rewritten.
    vim.api.nvim_create_autocmd({ 'BufWipeout', 'BufUnload' }, {
      buffer = scratch,
      once = true,
      desc = 'IntelliJ git: leave diff mode when the revision pane closes',
      callback = function()
        for _, w in ipairs(vim.api.nvim_list_wins()) do
          if vim.api.nvim_win_get_buf(w) == bufnr then
            pcall(vim.api.nvim_win_call, w, function() vim.cmd('diffoff') end)
          end
        end
      end,
    })
  end)
end

--- Builds a read-only scratch buffer holding one revision of a file.
--- @param name string buffer name
--- @param lines string[]
--- @param filetype string
--- @return integer
local function revision_buf(name, lines, filetype)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].buftype = 'nofile'
  vim.bo[buf].swapfile = false
  vim.bo[buf].bufhidden = 'wipe'
  vim.bo[buf].modifiable = false
  require('intellij-lsp.git.session').set_scratch_filetype(buf, filetype)
  -- A name collision would make the second `nvim_buf_set_name` fail and leave the pane unnamed, which
  -- matters because two panes here often show the same path at different revisions.
  pcall(vim.api.nvim_buf_set_name, buf, name)
  return buf
end

--- Filetype for a path, without needing a real file.
---
--- `filetype.match` on the name alone: the content is a scratch buffer, and running full detection
--- would need the buffer to exist first. Falls back to no filetype rather than guessing wrong.
--- @param path string
--- @return string
function M.filetype_for(path)
  return vim.filetype.match({ filename = path }) or ''
end

--- Reads a file at a revision. Missing is not an error: it is how added and deleted files look.
---
--- Exported because the commit detail view renders the same two sides live as you step through files,
--- and duplicating the "absent means empty side" rule is how the two would come to disagree about
--- added and deleted files.
--- @param root string
--- @param spec string `<rev>:<path>`
--- @param on_done fun(lines: string[]|nil)
function M.read_revision(root, spec, on_done)
  cmd.run({ 'show', spec }, { cwd = root }, function(res)
    if not res.ok then
      -- The file did not exist at that revision -- an addition or a deletion. An empty side is exactly
      -- right for the diff, so this is not reported as a failure.
      on_done(nil)
      return
    end
    local lines = vim.split(res.stdout, '\n', { plain = true })
    if lines[#lines] == '' then table.remove(lines) end
    on_done(lines)
  end)
end

--- Opens a two-pane diff of one file as changed by a single commit.
---
--- The side-by-side equivalent of `:IntellijGitDiff`, but for history: parent on the left, commit on
--- the right, both read-only because neither is a thing you can edit. `]c`, `[c` and the rest of
--- `:h diff` work as they do anywhere else.
---
--- Both `dp` and `do` are intercepted here, unlike in the working-tree diff where `do` is the useful
--- "revert this hunk". Neither pane is writable, so both would raise `E21` on panes that look
--- identical to the editable ones elsewhere in the plugin.
---
--- A merge commit is diffed against its *first* parent. `<hash>^!` would give the combined diff, which
--- has no single "before" side to put in a pane; first-parent is the conventional reading of "what did
--- this merge bring in".
--- @param root string
--- @param hash string
--- @param file table { path, origin?, code }
function M.open_commit_file(root, hash, file)
  local path = file.path
  -- A rename must read the *old* path on the parent side, or the left pane comes up empty and a pure
  -- move renders as a whole-file addition.
  local parent_path = file.origin or path
  local short = hash:sub(1, 7)

  M.read_revision(root, hash .. '^:' .. parent_path, function(before)
    M.read_revision(root, hash .. ':' .. path, function(after)
      if before == nil and after == nil then
        vim.notify(
          ('IntelliJ git: %s is not readable at %s (binary, or a merge resolution).')
            :format(path, short),
          vim.log.levels.WARN
        )
        return
      end

      local ft = M.filetype_for(path)
      -- An empty table, not nil: a deleted file's "after" side must be an empty pane so the diff shows
      -- every line as removed, rather than no pane at all.
      local lbuf = revision_buf(
        ('intellij-git://%s^/%s'):format(short, parent_path), before or {}, ft)
      local rbuf = revision_buf(('intellij-git://%s/%s'):format(short, path), after or {}, ft)

      -- Opened in a new tab so the diff does not fight the log and detail panels for space, and so
      -- `:tabclose` disposes of the whole thing in one keystroke.
      vim.cmd('tabnew')
      local rwin = vim.api.nvim_get_current_win()
      vim.api.nvim_win_set_buf(rwin, rbuf)
      vim.cmd('diffthis')

      vim.cmd('leftabove vsplit')
      local lwin = vim.api.nvim_get_current_win()
      vim.api.nvim_win_set_buf(lwin, lbuf)
      vim.cmd('diffthis')

      -- Cursor on the right: that is the commit itself, the thing being looked at. Left is context.
      vim.api.nvim_set_current_win(rwin)
      -- First hunk, so the view opens on the change rather than at line 1 of an unchanged preamble.
      pcall(function() vim.cmd('normal! gg]c') end)

      for _, buf in ipairs({ lbuf, rbuf }) do
        for _, key in ipairs({ 'do', 'dp' }) do
          vim.keymap.set('n', key, function()
            vim.notify(
              ('IntelliJ git: both panes are historical revisions of %s and cannot be edited. '
                .. 'Use :IntellijGitDiff on the working tree to change a file.'):format(path),
              vim.log.levels.WARN
            )
          end, { buffer = buf, desc = 'IntelliJ git: historical revisions are read-only' })
        end
        vim.keymap.set('n', 'q', '<Cmd>tabclose<CR>',
          { buffer = buf, nowait = true, desc = 'IntelliJ git: close the diff' })
      end
    end)
  end)
end

M._map_transfer_keys = map_transfer_keys

return M
