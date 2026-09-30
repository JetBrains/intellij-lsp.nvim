--- File templates for new `.java` and `.kt` files, interpolated by the server.
---
--- IntelliJ's "New Class" fills a file with the package line and a class skeleton derived from the
--- file's place in the source tree. The server exposes that engine as the `interpolateFileTemplate`
--- executeCommand: `[documentUri, templateText]` in, the interpolated text out (or null when the
--- file is not in a project it knows). The template language is IntelliJ's own (Velocity), with
--- `${NAME}`, `${PACKAGE_NAME}` and friends.
---
--- The client owns the template text, so the picker below is what the IDE's "Kind" dropdown is:
--- one entry per template of the buffer's language. A `|` in the text marks where the cursor ends.
---
--- One constraint shapes the flow: the server resolves the URI through its virtual file system, so
--- the file has to exist on disk before the request. A new buffer in Neovim has no file until it is
--- written, which is why the empty file is written first, right after the user picks a template,
--- and never before: dismissing the picker leaves an unsaved empty buffer and no stray file.

local M = {}

local COMMAND = 'interpolateFileTemplate'

--- The default templates, keyed by filetype then by name.
M.DEFAULTS = {
  java = {
    ['Class'] = '#if (${PACKAGE_NAME} && ${PACKAGE_NAME} != "")package ${PACKAGE_NAME};\n\n#end\npublic class ${NAME} {\n\t|\n}',
    ['Interface'] = '#if (${PACKAGE_NAME} && ${PACKAGE_NAME} != "")package ${PACKAGE_NAME};\n\n#end\npublic interface ${NAME} {\n\t|\n}',
    ['Record'] = '#if (${PACKAGE_NAME} && ${PACKAGE_NAME} != "")package ${PACKAGE_NAME};\n\n#end\npublic record ${NAME}(|) {\n}',
    ['Enum'] = '#if (${PACKAGE_NAME} && ${PACKAGE_NAME} != "")package ${PACKAGE_NAME};\n\n#end\npublic enum ${NAME} {\n\t|\n}',
    ['Annotation'] = '#if (${PACKAGE_NAME} && ${PACKAGE_NAME} != "")package ${PACKAGE_NAME};\n\n#end\npublic @interface ${NAME} {\n\t|\n}',
    ['Exception'] = '#if (${PACKAGE_NAME} && ${PACKAGE_NAME} != "")package ${PACKAGE_NAME};\n\n#end\npublic class ${NAME} extends RuntimeException {\n    public ${NAME}(String message) {\n        super(message);\n    }\n}',
  },
  kotlin = {
    ['Class'] = '#if (${PACKAGE_NAME} && ${PACKAGE_NAME} != "")package ${PACKAGE_NAME}\n\n#end\nclass ${NAME} {\n\t|\n}',
    ['File'] = '#if (${PACKAGE_NAME} && ${PACKAGE_NAME} != "")package ${PACKAGE_NAME}\n\n#end\n|',
    ['Interface'] = '#if (${PACKAGE_NAME} && ${PACKAGE_NAME} != "")package ${PACKAGE_NAME}\n\n#end\ninterface ${NAME} {\n\t|\n}',
    ['Data Class'] = '#if (${PACKAGE_NAME} && ${PACKAGE_NAME} != "")package ${PACKAGE_NAME}\n\n#end\ndata class ${NAME}(|)\n',
    ['Enum'] = '#if (${PACKAGE_NAME} && ${PACKAGE_NAME} != "")package ${PACKAGE_NAME}\n\n#end\nenum class ${NAME} {\n\t|\n}',
    ['Annotation'] = '#if (${PACKAGE_NAME} && ${PACKAGE_NAME} != "")package ${PACKAGE_NAME}\n\n#end\nannotation class ${NAME}(|)',
    ['Object'] = '#if (${PACKAGE_NAME} && ${PACKAGE_NAME} != "")package ${PACKAGE_NAME}\n\n#end\nobject ${NAME} {\n\t|\n}',
  },
}

--- Picker order: the common kinds first, then the rest alphabetically.
local ORDER = { 'Class', 'Interface', 'Record', 'Enum', 'Data Class', 'Object', 'File', 'Annotation', 'Exception' }

--- The templates for a filetype, with user overrides merged over the defaults.
---
--- `file_templates` may be `true` (defaults), a table `{ java = { Name = text }, kotlin = ... }`
--- merged over them, or `false` (off; handled by the caller). A user entry set to `false` removes a
--- default of that name.
--- @param cfg table
--- @param filetype string
--- @return { name: string, text: string }[]
function M.templates_for(cfg, filetype)
  local merged = vim.deepcopy(M.DEFAULTS[filetype] or {})
  local user = type(cfg.file_templates) == 'table' and cfg.file_templates[filetype] or nil
  for name, text in pairs(user or {}) do
    merged[name] = text or nil
  end
  local rank = {}
  for i, n in ipairs(ORDER) do rank[n] = i end
  local names = vim.tbl_keys(merged)
  table.sort(names, function(a, b)
    local ra, rb = rank[a] or math.huge, rank[b] or math.huge
    if ra ~= rb then return ra < rb end
    return a < b
  end)
  local out = {}
  for _, n in ipairs(names) do out[#out + 1] = { name = n, text = merged[n] } end
  return out
end

--- Splits the interpolated text at its cursor marker into lines and a (row, col) for the cursor.
---
--- The first `|` is the marker.
--- Without one the cursor lands on the last line.
--- @param text string
--- @return string[] lines
--- @return integer row 1-based
--- @return integer col 0-based byte column
function M.split_marker(text)
  text = text:gsub('\r\n', '\n')
  local at = text:find('|', 1, true)
  if at then text = text:sub(1, at - 1) .. text:sub(at + 1) end
  local lines = vim.split(text, '\n', { plain = true })
  if not at then return lines, #lines, #(lines[#lines] or '') end
  local before = text:sub(1, at - 1)
  local _, newlines = before:gsub('\n', '')
  local row = newlines + 1
  local last_nl = before:match('.*()\n')
  local col = last_nl and (#before - last_nl) or #before
  return lines, row, col
end

--- Puts the interpolated text into the buffer and parks the cursor at the marker, in insert mode.
--- @param bufnr integer
--- @param text string
function M.insert(bufnr, text)
  local lines, row, col = M.split_marker(text)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  if vim.api.nvim_get_current_buf() == bufnr then
    pcall(vim.api.nvim_win_set_cursor, 0, { row, col })
    vim.cmd('startinsert')
  end
end

--- Asks the server to interpolate `template` for the buffer's file and inserts the result.
---
--- The empty file is written first, because the server resolves the URI through its VFS and a
--- buffer that was never written has no file there; `interpolateFileTemplate` answers null for it.
--- `:write` here is what the IDE's "New Class" does too, which creates the file before opening it.
--- @param client vim.lsp.Client
--- @param bufnr integer
--- @param template { name: string, text: string }
function M.apply(client, bufnr, template)
  local path = vim.api.nvim_buf_get_name(bufnr)
  if path == '' then return end
  if vim.fn.filereadable(path) ~= 1 then
    vim.fn.mkdir(vim.fs.dirname(path), 'p')
    local ok = pcall(vim.api.nvim_buf_call, bufnr, function() vim.cmd('silent write') end)
    if not ok then
      vim.notify('IntelliJ LSP: could not create ' .. path, vim.log.levels.ERROR)
      return
    end
  end

  -- A direct `workspace/executeCommand` rather than `client:exec_cmd`: the latter refuses any
  -- command the server did not list in `executeCommandProvider.commands`, and this one is known to
  -- exist whether or not it is listed.
  client:request('workspace/executeCommand',
    { command = COMMAND, arguments = { vim.uri_from_bufnr(bufnr), template.text } },
    function(err, result)
      if err then
        vim.notify('IntelliJ LSP: file template failed: ' .. tostring(err.message or err), vim.log.levels.ERROR)
        return
      end
      if type(result) ~= 'string' then
        -- Null: the file is outside any project the server imported, so there is no package to
        -- derive. Nothing sensible to insert; leave the buffer as the user made it.
        return
      end
      if not vim.api.nvim_buf_is_valid(bufnr) then return end
      -- The user may have started typing while the request was out; do not overwrite that.
      local current = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
      if #current > 1 or (current[1] or '') ~= '' then return end
      M.insert(bufnr, result)
    end, bufnr)
end

--- Offers the templates for the buffer's filetype and applies the pick.
--- @param client vim.lsp.Client
--- @param bufnr integer
--- @param cfg table
function M.prompt(client, bufnr, cfg)
  local templates = M.templates_for(cfg, vim.bo[bufnr].filetype)
  if #templates == 0 then return end
  if #templates == 1 then
    M.apply(client, bufnr, templates[1])
    return
  end
  vim.ui.select(templates, {
    prompt = 'IntelliJ: file template for ' .. vim.fs.basename(vim.api.nvim_buf_get_name(bufnr)),
    format_item = function(t) return t.name end,
  }, function(choice)
    if choice then M.apply(client, bufnr, choice) end
  end)
end

--- Whether the buffer is a new file with nothing in it yet.
--- @param bufnr integer
--- @return boolean
function M.is_empty_new_file(bufnr)
  if not vim.b[bufnr].intellij_lsp_new_file then return false end
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  return #lines <= 1 and (lines[1] or '') == ''
end

--- Called from `on_attach`: a buffer that BufNewFile flagged, still empty, gets the picker.
---
--- Runs from `on_attach` rather than BufNewFile because the request needs an attached client, and
--- BufNewFile fires before FileType, which is what starts the server. The flag is cleared so a
--- reattach (a server restart) does not ask again.
--- @param client vim.lsp.Client
--- @param bufnr integer
--- @param cfg table
function M.on_attach(client, bufnr, cfg)
  if not M.is_empty_new_file(bufnr) then return end
  vim.b[bufnr].intellij_lsp_new_file = nil
  -- Deferred past the attach: the picker on top of a buffer that is still being drawn reads as a
  -- glitch, and the server has not seen `didOpen` yet at this point.
  vim.schedule(function()
    if vim.api.nvim_buf_is_valid(bufnr) and vim.api.nvim_get_current_buf() == bufnr then
      M.prompt(client, bufnr, cfg)
    end
  end)
end

--- Marks new files so `on_attach` can tell them from existing ones. Registered once from `setup()`.
--- @param group integer augroup
--- @param filetypes string[]
function M.setup_autocmd(group, filetypes)
  local patterns = {}
  for _, ft in ipairs(filetypes) do
    patterns[#patterns + 1] = ft == 'kotlin' and '*.kt' or ('*.' .. ft)
  end
  vim.api.nvim_create_autocmd('BufNewFile', {
    group = group,
    pattern = patterns,
    desc = 'IntelliJ: remember that this buffer is a new file',
    callback = function(args) vim.b[args.buf].intellij_lsp_new_file = true end,
  })
end

--- `:IntellijLspFileTemplate`: the picker on demand, for a file created some other way.
function M.command()
  local bufnr = vim.api.nvim_get_current_buf()
  local client = vim.lsp.get_clients({ bufnr = bufnr, name = 'intellij' })[1]
  if not client then
    vim.notify('IntelliJ LSP: no server attached to this buffer.', vim.log.levels.WARN)
    return
  end
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  if #lines > 1 or (lines[1] or '') ~= '' then
    vim.notify('IntelliJ LSP: the buffer is not empty; templates only fill empty files.', vim.log.levels.WARN)
    return
  end
  M.prompt(client, bufnr, require('intellij-lsp').config)
end

return M
