-- Highlight checks for the bundled islands-dark colorscheme. No server required.
--
--   nvim --headless -u NONE -l test/theme.lua
vim.opt.runtimepath:prepend(vim.fs.dirname(vim.fs.dirname(debug.getinfo(1, 'S').source:sub(2))))

-- Every assertion below compares 24-bit hex, which nvim_get_hl only reports when termguicolors is
-- on; without it the checks would all fail for the wrong reason.
vim.opt.termguicolors = true

local failures = 0
local function check(name, cond, detail)
  if cond then
    print('ok   ' .. name)
  else
    failures = failures + 1
    print('FAIL ' .. name .. (detail and ('  -> ' .. tostring(detail)) or ''))
  end
end

vim.cmd.colorscheme('islands-dark')

--- Resolved attributes of a highlight group. `link = false` follows links, so this reports the
--- effective colour whether the group was set directly or linked to one that was.
local function hl(group)
  return vim.api.nvim_get_hl(0, { name = group, link = false })
end

local function hex(value)
  return value and string.format('#%06X', value) or nil
end

local function fg(group) return hex(hl(group).fg) end
local function bg(group) return hex(hl(group).bg) end
local function sp(group) return hex(hl(group).sp) end

-- scheme bookkeeping
check('colors_name is set', vim.g.colors_name == 'islands-dark', vim.g.colors_name)
check('background forced dark', vim.o.background == 'dark', vim.o.background)

-- editor surface: the darker Islands background is what distinguishes this scheme from "Dark"
check('Normal fg', fg('Normal') == '#BCBEC4', fg('Normal'))
check('Normal bg', bg('Normal') == '#191A1C', bg('Normal'))
check('CursorLine bg', bg('CursorLine') == '#1F2024', bg('CursorLine'))
check('LineNr fg', fg('LineNr') == '#4B5059', fg('LineNr'))
-- Inherited from Darcula; absent from IslandSchemeDark.xml.
check('Visual bg inherits Darcula', bg('Visual') == '#214283', bg('Visual'))

-- syntax the server never sends, so these come from Treesitter or vim syntax
check('keyword', fg('@keyword') == '#CF8E6D', fg('@keyword'))
check('string', fg('@string') == '#6AAB73', fg('@string'))
check('number', fg('@number') == '#2AACB8', fg('@number'))
check('comment', fg('Comment') == '#7A7E85', fg('Comment'))
check('doc comment italic', hl('@comment.documentation').italic == true)
-- Java primitives lex as keywords in IntelliJ.
check('builtin type is keyword-coloured', fg('@type.builtin') == '#CF8E6D', fg('@type.builtin'))
-- `class` / `record` / `interface`; set explicitly rather than left to Neovim's default link.
check('keyword.type is set explicitly',
  vim.api.nvim_get_hl(0, { name = '@keyword.type', link = true }).link == nil,
  vim.inspect(vim.api.nvim_get_hl(0, { name = '@keyword.type', link = true })))
check('keyword.type colour', fg('@keyword.type') == '#CF8E6D', fg('@keyword.type'))

-- The fidelity flattenings. A conventional Neovim theme colours all of these; IntelliJ does not.
check('class is plain', fg('@lsp.type.class') == '#BCBEC4', fg('@lsp.type.class'))
check('interface is plain', fg('@lsp.type.interface') == '#BCBEC4', fg('@lsp.type.interface'))
check('parameter is plain', fg('@lsp.type.parameter') == '#BCBEC4', fg('@lsp.type.parameter'))
check('local variable is plain', fg('@lsp.type.variable') == '#BCBEC4', fg('@lsp.type.variable'))
check('method call is plain', fg('@lsp.type.method') == '#BCBEC4', fg('@lsp.type.method'))
check('Type group is plain', fg('Type') == '#BCBEC4', fg('Type'))

-- ...and the things IntelliJ does colour.
check('method declaration', fg('@lsp.typemod.method.declaration') == '#57AAF7',
  fg('@lsp.typemod.method.declaration'))
check('function declaration', fg('@lsp.typemod.function.declaration') == '#56A8F5',
  fg('@lsp.typemod.function.declaration'))
check('instance field', fg('@lsp.type.property') == '#C77DBB', fg('@lsp.type.property'))
check('static field is italic', hl('@lsp.typemod.property.static').italic == true)
check('static field colour', fg('@lsp.typemod.property.static') == '#C77DBB',
  fg('@lsp.typemod.property.static'))
check('type parameter', fg('@lsp.type.typeParameter') == '#16BAAC', fg('@lsp.type.typeParameter'))
check('annotation', fg('@lsp.type.decorator') == '#B3AE60', fg('@lsp.type.decorator'))
check('enum member is italic', hl('@lsp.type.enumMember').italic == true)

-- Regression guard for the trap that motivated the explicit plain entries: Neovim links
-- @lsp.type.class to @type by default and `hi clear` does not remove that link, so omitting the
-- group in theme/groups.lua would silently restore Treesitter's class colour.
check('class is set, not left linked',
  vim.api.nvim_get_hl(0, { name = '@lsp.type.class', link = true }).link == nil,
  vim.inspect(vim.api.nvim_get_hl(0, { name = '@lsp.type.class', link = true })))
check('property is set, not left linked',
  vim.api.nvim_get_hl(0, { name = '@lsp.type.property', link = true }).link == nil)

-- The server marks every non-final variable `modification`, not just reassigned ones, so styling it
-- would underline nearly every `var` in a file. Must stay empty.
check('modification unstyled', vim.tbl_isempty(hl('@lsp.mod.modification')),
  vim.inspect(hl('@lsp.mod.modification')))
check('readonly unstyled', vim.tbl_isempty(hl('@lsp.mod.readonly')))
check('defaultLibrary unstyled', vim.tbl_isempty(hl('@lsp.mod.defaultLibrary')))

-- deprecated carries an attribute but no foreground, so it composes under the type group instead of
-- flattening it.
check('deprecated strikethrough', hl('@lsp.mod.deprecated').strikethrough == true)
check('deprecated has no fg', hl('@lsp.mod.deprecated').fg == nil, fg('@lsp.mod.deprecated'))

-- diagnostics: EFFECT_TYPE 2 is IntelliJ's wavy underscore
check('error undercurl', hl('DiagnosticUnderlineError').undercurl == true)
check('error wave colour', sp('DiagnosticUnderlineError') == '#FA6675',
  sp('DiagnosticUnderlineError'))
check('warn wave colour', sp('DiagnosticUnderlineWarn') == '#F2C55C', sp('DiagnosticUnderlineWarn'))
check('unused is dimmed', fg('DiagnosticUnnecessary') == '#6F737A', fg('DiagnosticUnnecessary'))

-- XML: tag names gold, attribute names plain, attribute values string-green
check('xml tag', fg('@tag') == '#D5B778', fg('@tag'))
check('xml attribute name is plain', fg('@tag.attribute') == '#BCBEC4', fg('@tag.attribute'))
check('xml attribute value is string', fg('@string.special') == '#6AAB73', fg('@string.special'))

-- identifier-under-caret, one of the more recognisable IDE behaviours
check('reference highlight', bg('LspReferenceText') == '#373B39', bg('LspReferenceText'))
check('write reference highlight', bg('LspReferenceWrite') == '#402F33', bg('LspReferenceWrite'))

-- quickfix: the results list `grr` browses. Opening a window first is load-bearing -- syntax/qf.vim
-- only links the qf* groups on the first quickfix window, and it does that *after* `hi clear`.
vim.fn.setqflist({ { filename = '/tmp/A.java', lnum = 1, col = 1, text = 'class A' } }, 'r')
vim.cmd('copen')
check('QuickFixLine is the selection colour', bg('QuickFixLine') == '#214283', bg('QuickFixLine'))
check('qfFileName is link-coloured', fg('qfFileName') == '#548AF7', fg('qfFileName'))
check('qfLineNr', fg('qfLineNr') == '#4B5059', fg('qfLineNr'))
-- The names are qfSeparator1/2; a `qfSeparator` entry would be a silent no-op.
check('qfSeparator1', fg('qfSeparator1') == '#43454A', fg('qfSeparator1'))
check('qfSeparator2', fg('qfSeparator2') == '#43454A', fg('qfSeparator2'))
check('qfText', fg('qfText') == '#BCBEC4', fg('qfText'))

-- Same class of trap as the @lsp.type.class guard above: syntax/qf.vim `hi def link`s qfFileName to
-- Directory, and `hi def` losing to our explicit set is the only reason the entry above takes effect.
check('qfFileName is set, not left linked to Directory',
  vim.api.nvim_get_hl(0, { name = 'qfFileName', link = true }).link == nil,
  vim.inspect(vim.api.nvim_get_hl(0, { name = 'qfFileName', link = true })))
vim.cmd('cclose')

-- Diff mode uses the diff viewer's DIFF_* colours: a tint on the line, the full colour on the words.
-- The *_LINES_COLOR gutter stripes (#549159, #375FAD) were here before and painted far too loud.
check('DiffAdd is the inserted line tint', bg('DiffAdd') == '#1F2B26', bg('DiffAdd'))
check('DiffChange is the modified line tint', bg('DiffChange') == '#25323E', bg('DiffChange'))
check('DiffText is DIFF_MODIFIED', bg('DiffText') == '#385570', bg('DiffText'))
check('DiffText is not bold', hl('DiffText').bold == nil, vim.inspect(hl('DiffText')))
check('DiffTextAdd is DIFF_INSERTED', bg('DiffTextAdd') == '#294436', bg('DiffTextAdd'))
check('old-pane deleted line is grey', bg('IntellijDiffDeleted') == '#2C2D2E', bg('IntellijDiffDeleted'))
check('old-pane deleted word is DIFF_DELETED',
  bg('IntellijDiffDeletedText') == '#484A4A', bg('IntellijDiffDeletedText'))
check('diff filler is dim', fg('IntellijDiffFiller') == '#43454A', fg('IntellijDiffFiller'))
check('diff fold is DIFF_SEPARATORS_BACKGROUND', bg('IntellijDiffFold') == '#2B2D30',
  bg('IntellijDiffFold'))
-- Neovim's own WinBar is near black under this scheme, so the pane header sets its own colour.
check('diff header background', bg('IntellijDiffTitle') == '#2B2D30', bg('IntellijDiffTitle'))
check('diff header text', fg('IntellijDiffTitle') == '#BCBEC4', fg('IntellijDiffTitle'))
check('diff header note is dimmed', fg('IntellijDiffTitleMeta') == '#6F737A',
  fg('IntellijDiffTitleMeta'))
-- The unified preview links to the two-pane tints, through git/highlights.lua.
require('intellij-lsp.git.highlights').setup()
check('unified inserted line', bg('IntellijDiffInsertedLine') == '#1F2B26',
  bg('IntellijDiffInsertedLine'))
check('unified deleted line', bg('IntellijDiffDeletedLine') == '#2C2D2E',
  bg('IntellijDiffDeletedLine'))

-- The feature's own groups, which live in references.lua rather than the scheme so they degrade for
-- users who never opted in. Under islands-dark they resolve to IntelliJ's Find-Usages greens.
require('intellij-lsp.references')
check('ReferenceMatch resolves under islands-dark',
  bg('IntellijLspReferenceMatch') == '#2D543F', bg('IntellijLspReferenceMatch'))
check('ReferencePreview resolves under islands-dark',
  bg('IntellijLspReferencePreview') == '#114957', bg('IntellijLspReferencePreview'))

-- The degradation requirement: still legible with no colorscheme opt-in at all. Also covers the
-- ColorScheme autocmd, since `hi clear` drops `default` links.
vim.cmd.colorscheme('default')
check('ReferenceMatch survives a colorscheme change',
  bg('IntellijLspReferenceMatch') ~= nil, vim.inspect(hl('IntellijLspReferenceMatch')))
vim.cmd.colorscheme('islands-dark')

print(failures == 0 and '\nALL THEME CHECKS PASSED' or ('\n' .. failures .. ' THEME CHECK(S) FAILED'))
vim.cmd(failures == 0 and 'qa!' or 'cq!')
