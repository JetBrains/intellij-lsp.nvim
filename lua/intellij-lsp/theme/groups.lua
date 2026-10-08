--- Maps the Islands Dark palette onto Neovim highlight groups.
---
--- `build()` returns a plain table and sets nothing, so the mapping can be inspected in tests
--- without mutating global highlight state. theme.lua does the applying.
---
--- Three things about this file are deliberate and will look like bugs to a reader who expects a
--- conventional Neovim theme:
---
--- 1. Many groups are set to the plain text colour on purpose. IntelliJ's dark schemes leave class
---    names, interfaces, parameters, local variables and method *calls* at DEFAULT_IDENTIFIER, and
---    `DEFAULT_CLASS_REFERENCE` is explicitly #BCBEC4 rather than merely absent. Every such entry is
---    marked `plain by design`. Do not "fix" them; test/theme.lua asserts four of them.
---
--- 2. Those plain entries must be written out explicitly rather than omitted. Neovim ships default
---    links from `@lsp.type.*` to Treesitter captures (`@lsp.type.class` -> `@type`), and `hi clear`
---    does *not* remove them. An omission therefore leaves the group linked and coloured, which is
---    the exact opposite of the intent and is invisible unless you go looking.
---
--- 3. `@lsp.mod.*` entries carry attributes only, never a foreground. Neovim composes a token's
---    modifier groups underneath its type group, so a foreground here would win over the type and
---    flatten everything the modifier touches.

local M = {}

--- @param p table the palette (theme/palette.lua)
--- @return table<string, vim.api.keyset.highlight> group name -> `nvim_set_hl` options
function M.build(p)
  return {
    -- -----------------------------------------------------------------------
    -- Editor surface and chrome
    -- -----------------------------------------------------------------------
    Normal = { fg = p.fg, bg = p.bg },
    NormalNC = { fg = p.fg, bg = p.bg },
    NormalFloat = { fg = p.fg, bg = p.popup_bg },
    FloatBorder = { fg = p.popup_border, bg = p.popup_bg },
    FloatTitle = { fg = p.fg, bg = p.popup_bg },

    Cursor = { fg = p.bg, bg = p.caret },
    lCursor = { fg = p.bg, bg = p.caret },
    TermCursor = { fg = p.bg, bg = p.caret },
    CursorLine = { bg = p.caret_row },
    CursorColumn = { bg = p.caret_row },
    -- IntelliJ brightens the current line's number but does not embolden it.
    CursorLineNr = { fg = p.line_nr_caret },
    LineNr = { fg = p.line_nr },
    SignColumn = { bg = p.bg },
    FoldColumn = { fg = p.line_nr, bg = p.bg },
    Folded = { fg = p.folded_fg, bg = p.folded_bg },

    -- Inherited from Darcula, not present in IslandSchemeDark.xml. See palette.lua.
    Visual = { bg = p.selection },
    VisualNOS = { bg = p.selection_inactive },

    -- IntelliJ draws RIGHT_MARGIN_COLOR as a one-pixel rule; a tinted column is the nearest
    -- Neovim equivalent.
    ColorColumn = { bg = p.right_margin },
    Whitespace = { fg = p.whitespace },
    NonText = { fg = p.indent_guide },
    SpecialKey = { fg = p.whitespace },
    EndOfBuffer = { fg = p.bg },

    MatchParen = { bg = p.matched_brace, bold = true },

    Pmenu = { fg = p.fg, bg = p.popup_bg },
    PmenuSel = { bg = p.selection },
    PmenuSbar = { bg = p.popup_bg },
    PmenuThumb = { bg = p.separator },
    PmenuKind = { fg = p.field, bg = p.popup_bg },
    PmenuExtra = { fg = p.not_used, bg = p.popup_bg },
    WildMenu = { bg = p.selection },

    -- IntelliJ distinguishes the incremental match, the other matches, and a write-access match.
    Search = { bg = p.text_search_result },
    IncSearch = { bg = p.search_result },
    CurSearch = { bg = p.write_search_result },

    StatusLine = { fg = p.breadcrumb_current_fg, bg = p.breadcrumb_current_bg },
    StatusLineNC = { fg = p.breadcrumb_fg, bg = p.bg },
    TabLine = { fg = p.breadcrumb_fg, bg = p.breadcrumb_current_bg },
    TabLineSel = { fg = p.breadcrumb_current_fg, bg = p.bg },
    TabLineFill = { bg = p.bg },
    WinSeparator = { fg = p.separator },
    VertSplit = { fg = p.separator },

    Directory = { fg = p.link },
    Title = { fg = p.fg, bold = true },
    Question = { fg = p.string },
    MoreMsg = { fg = p.string },
    ModeMsg = { fg = p.fg, bold = true },
    ErrorMsg = { fg = p.error },
    WarningMsg = { fg = p.warn_stripe },
    MsgArea = { fg = p.fg },
    Conceal = { fg = p.not_used },

    -- -----------------------------------------------------------------------
    -- Legacy syntax groups
    -- -----------------------------------------------------------------------
    -- These carry real weight here: the plugin's README supports running with no Treesitter at all,
    -- on Java's built-in regex syntax, and the language server never sends keyword/string/comment
    -- tokens (see the @lsp section below).
    Comment = { fg = p.comment },

    Keyword = { fg = p.keyword },
    Statement = { link = 'Keyword' },
    Conditional = { link = 'Keyword' },
    Repeat = { link = 'Keyword' },
    Label = { link = 'Keyword' },
    Exception = { link = 'Keyword' },
    StorageClass = { link = 'Keyword' },
    Structure = { link = 'Keyword' },
    Boolean = { link = 'Keyword' },

    String = { fg = p.string },
    Character = { link = 'String' },
    Number = { fg = p.number },
    Float = { link = 'Number' },
    Constant = { fg = p.field, italic = true },

    -- Vim's regex syntax cannot tell a declaration from a call, and colouring declarations is the
    -- more useful half of IntelliJ's distinction.
    Function = { fg = p.fn_decl },

    Identifier = { fg = p.fg }, -- plain by design: DEFAULT_IDENTIFIER
    Type = { fg = p.fg }, -- plain by design: DEFAULT_CLASS_REFERENCE is explicitly #BCBEC4
    Operator = { fg = p.fg }, -- plain by design: DEFAULT_OPERATION_SIGN
    Delimiter = { fg = p.fg }, -- plain by design: DEFAULT_BRACES / COMMA / DOT / SEMICOLON
    Special = { fg = p.fg }, -- plain by design
    SpecialChar = { fg = p.string_escape },
    Tag = { fg = p.xml_tag },

    PreProc = { fg = p.annotation }, -- closest analogue to DEFAULT_METADATA
    Include = { link = 'Keyword' },
    Define = { link = 'PreProc' },
    Macro = { link = 'PreProc' },

    Todo = { fg = p.todo, italic = true },
    Error = { fg = p.error },
    Underlined = { fg = p.link, underline = true },
    Ignore = { fg = p.not_used },

    -- -----------------------------------------------------------------------
    -- Treesitter captures
    -- -----------------------------------------------------------------------
    -- Treesitter supplies everything the server does not: keywords, literals, comments and
    -- punctuation. For Java and Kotlin the @lsp groups below override these on any identifier the
    -- server resolved; for XML and Lua these are the only highlights there are.
    ['@comment'] = { fg = p.comment },
    ['@comment.documentation'] = { fg = p.doc_comment, italic = true },
    ['@comment.todo'] = { fg = p.todo, italic = true },
    ['@comment.note'] = { fg = p.todo, italic = true },
    ['@comment.warning'] = { fg = p.warn_stripe, italic = true },
    ['@comment.error'] = { fg = p.error, italic = true },

    ['@keyword'] = { fg = p.keyword },
    ['@keyword.function'] = { fg = p.keyword },
    ['@keyword.return'] = { fg = p.keyword },
    ['@keyword.operator'] = { fg = p.keyword },
    ['@keyword.import'] = { fg = p.keyword },
    ['@keyword.modifier'] = { fg = p.keyword },
    ['@keyword.exception'] = { fg = p.keyword },
    ['@keyword.conditional'] = { fg = p.keyword },
    ['@keyword.repeat'] = { fg = p.keyword },
    ['@keyword.coroutine'] = { fg = p.keyword },
    -- `class`, `interface`, `record`, `enum`. Set explicitly rather than relying on Neovim's default
    -- link to @keyword, since that default is not ours to depend on.
    ['@keyword.type'] = { fg = p.keyword },

    ['@string'] = { fg = p.string },
    ['@string.escape'] = { fg = p.string_escape },
    ['@string.documentation'] = { fg = p.string },
    ['@string.regexp'] = { fg = p.string },
    ['@character'] = { fg = p.string },
    ['@character.special'] = { fg = p.string_escape },
    ['@number'] = { fg = p.number },
    ['@number.float'] = { fg = p.number },
    ['@boolean'] = { fg = p.keyword },

    ['@constant'] = { fg = p.field, italic = true },
    ['@constant.builtin'] = { fg = p.keyword },
    ['@constant.macro'] = { fg = p.annotation },

    ['@function'] = { fg = p.fn_decl },
    ['@function.call'] = { fg = p.fg }, -- plain by design: DEFAULT_FUNCTION_CALL
    ['@function.method'] = { fg = p.fg }, -- plain by design
    ['@function.method.call'] = { fg = p.fg }, -- plain by design
    ['@function.builtin'] = { fg = p.fn_decl },
    ['@constructor'] = { fg = p.fg }, -- plain by design: a constructor is a class reference

    ['@variable'] = { fg = p.fg }, -- plain by design: DEFAULT_LOCAL_VARIABLE falls back to IDENTIFIER
    ['@variable.parameter'] = { fg = p.fg }, -- plain by design: DEFAULT_PARAMETER likewise
    ['@variable.builtin'] = { fg = p.keyword }, -- `this` / `super` lex as keywords
    ['@variable.member'] = { fg = p.field }, -- fields *are* coloured: DEFAULT_INSTANCE_FIELD
    ['@property'] = { fg = p.field },
    ['@field'] = { fg = p.field },

    ['@type'] = { fg = p.fg }, -- plain by design
    -- Java primitives are lexed as keywords by IntelliJ, so this is fidelity, not preference.
    ['@type.builtin'] = { fg = p.keyword },
    ['@type.definition'] = { fg = p.fg }, -- plain by design
    ['@type.qualifier'] = { fg = p.keyword },
    ['@module'] = { fg = p.fg }, -- plain by design: package names are not coloured
    ['@attribute'] = { fg = p.annotation }, -- annotations: DEFAULT_METADATA
    ['@label'] = { fg = p.kotlin_label },

    ['@operator'] = { fg = p.fg }, -- plain by design
    ['@punctuation.bracket'] = { fg = p.fg }, -- plain by design
    ['@punctuation.delimiter'] = { fg = p.fg }, -- plain by design
    ['@punctuation.special'] = { fg = p.keyword }, -- string-template `${}` markers

    -- XML and HTML. Note the asymmetry, which is easy to get backwards: tag names are gold, an
    -- attribute *name* is plain (XML_ATTRIBUTE_NAME #BCBEC4) and an attribute *value* is
    -- string-green (HTML_ATTRIBUTE_VALUE inherits DEFAULT_STRING).
    ['@tag'] = { fg = p.xml_tag },
    ['@tag.builtin'] = { fg = p.xml_tag },
    ['@tag.delimiter'] = { fg = p.fg }, -- plain by design
    ['@tag.attribute'] = { fg = p.fg }, -- plain by design
    ['@string.special'] = { fg = p.string },
    ['@string.special.url'] = { fg = p.doc_link, underline = true },

    ['@markup.heading'] = { fg = p.fg, bold = true },
    ['@markup.link'] = { fg = p.doc_link },
    ['@markup.link.url'] = { fg = p.doc_link, underline = true },
    ['@markup.raw'] = { fg = p.string },
    ['@markup.list'] = { fg = p.keyword },
    ['@markup.strong'] = { bold = true },
    ['@markup.italic'] = { italic = true },
    ['@markup.strikethrough'] = { strikethrough = true },

    ['@diff.plus'] = { fg = p.status_added },
    ['@diff.minus'] = { fg = p.status_unknown },
    ['@diff.delta'] = { fg = p.status_modified },

    -- -----------------------------------------------------------------------
    -- LSP semantic tokens
    -- -----------------------------------------------------------------------
    -- The IntelliJ server emits a narrow, well-defined set of token types; these groups are what
    -- make Java and Kotlin look like the IDE. It never sends keyword, string, comment, number,
    -- regexp, macro, event or modifier tokens for those languages, so nothing here needs to cover
    -- them -- Treesitter does, above.
    --
    -- Every "plain by design" entry below is load-bearing rather than redundant: Neovim links
    -- @lsp.type.class -> @type and @lsp.type.property -> @property by default, and `hi clear` keeps
    -- those links. Deleting a line here re-colours the token instead of leaving it alone.
    ['@lsp.type.class'] = { fg = p.fg }, -- plain by design
    ['@lsp.type.interface'] = { fg = p.fg }, -- plain by design
    ['@lsp.type.enum'] = { fg = p.fg }, -- plain by design
    ['@lsp.type.struct'] = { fg = p.fg }, -- plain by design: Java records, Kotlin data classes
    ['@lsp.type.type'] = { fg = p.fg }, -- plain by design: Kotlin objects and companions
    ['@lsp.type.namespace'] = { fg = p.fg }, -- plain by design: packages
    ['@lsp.type.parameter'] = { fg = p.fg }, -- plain by design
    ['@lsp.type.variable'] = { fg = p.fg }, -- plain by design: locals
    ['@lsp.type.operator'] = { fg = p.fg }, -- plain by design

    ['@lsp.type.property'] = { fg = p.field }, -- DEFAULT_INSTANCE_FIELD
    ['@lsp.type.enumMember'] = { fg = p.field, italic = true }, -- DEFAULT_CONSTANT
    ['@lsp.type.typeParameter'] = { fg = p.type_param }, -- TYPE_PARAMETER_NAME_ATTRIBUTES
    ['@lsp.type.decorator'] = { fg = p.annotation }, -- annotation types: DEFAULT_METADATA

    -- IntelliJ colours a method *declaration* (#56A8F5) but leaves a *call* plain, because
    -- DEFAULT_FUNCTION_CALL inherits DEFAULT_IDENTIFIER. The server's `declaration` modifier is
    -- exactly what makes that distinction expressible here.
    ['@lsp.type.method'] = { fg = p.fg }, -- plain by design: call sites
    ['@lsp.type.function'] = { fg = p.fg }, -- plain by design: call sites
    ['@lsp.typemod.method.declaration'] = { fg = p.method },
    ['@lsp.typemod.function.declaration'] = { fg = p.fn_decl },

    -- FONT_TYPE 2 on DEFAULT_STATIC_FIELD and DEFAULT_STATIC_METHOD is italic.
    ['@lsp.typemod.property.static'] = { fg = p.field, italic = true },
    ['@lsp.typemod.method.static'] = { fg = p.method, italic = true },
    ['@lsp.typemod.function.static'] = { fg = p.fn_decl, italic = true },
    ['@lsp.typemod.variable.static'] = { fg = p.field, italic = true },

    -- Attributes only, no foreground: see the header note on modifier composition.
    ['@lsp.mod.deprecated'] = { strikethrough = true }, -- DEPRECATED_ATTRIBUTES

    -- Left unset on purpose, each for a different reason:
    --
    --   @lsp.mod.modification  The server marks every *non-final* variable with this, not just the
    --                          ones actually reassigned. IntelliJ's own DEFAULT_REASSIGNED_LOCAL_VARIABLE
    --                          underline applies only to genuine reassignments, so styling this
    --                          modifier would underline nearly every `var` in a file -- louder than
    --                          the IDE, not more faithful.
    --   @lsp.mod.readonly      IntelliJ does not colour final/val distinctly.
    --   @lsp.mod.defaultLibrary  IntelliJ does not colour java.*/kotlin.* distinctly.
    --   @lsp.mod.static        Handled per type above; a bare rule would also italicise static
    --                          classes, which IntelliJ leaves alone.
    --   @lsp.mod.declaration   Likewise per type: only functions and methods change colour when
    --                          declared, so a blanket rule would over-apply.
    --   @lsp.mod.abstract, @lsp.mod.async  No distinct treatment in this scheme.

    -- -----------------------------------------------------------------------
    -- Diagnostics
    -- -----------------------------------------------------------------------
    -- EFFECT_TYPE 2 is IntelliJ's wavy underscore, hence `undercurl`. The wave colour goes to `sp`
    -- and the scrollbar-stripe colour is reused wherever Neovim needs a solid foreground, since
    -- there is no scrollbar to put it in.
    DiagnosticError = { fg = p.error_stripe },
    DiagnosticWarn = { fg = p.warn_stripe },
    DiagnosticInfo = { fg = p.weak_warn },
    DiagnosticHint = { fg = p.typo },
    DiagnosticOk = { fg = p.status_added },

    DiagnosticUnderlineError = { undercurl = true, sp = p.error_wave },
    DiagnosticUnderlineWarn = { undercurl = true, sp = p.warn_wave },
    DiagnosticUnderlineInfo = { undercurl = true, sp = p.weak_warn },
    DiagnosticUnderlineHint = { undercurl = true, sp = p.typo },
    DiagnosticUnderlineOk = { undercurl = true, sp = p.status_added },

    DiagnosticVirtualTextError = { fg = p.error_stripe },
    DiagnosticVirtualTextWarn = { fg = p.warn_stripe },
    DiagnosticVirtualTextInfo = { fg = p.weak_warn },
    DiagnosticVirtualTextHint = { fg = p.typo },

    DiagnosticFloatingError = { fg = p.error_stripe },
    DiagnosticFloatingWarn = { fg = p.warn_stripe },
    DiagnosticFloatingInfo = { fg = p.weak_warn },
    DiagnosticFloatingHint = { fg = p.typo },

    DiagnosticSignError = { fg = p.error_stripe },
    DiagnosticSignWarn = { fg = p.warn_stripe },
    DiagnosticSignInfo = { fg = p.weak_warn },
    DiagnosticSignHint = { fg = p.typo },

    -- NOT_USED_ELEMENT_ATTRIBUTES: IntelliJ dims unused code rather than marking it.
    DiagnosticUnnecessary = { fg = p.not_used },
    DiagnosticDeprecated = { strikethrough = true, sp = p.fg },

    SpellBad = { undercurl = true, sp = p.typo }, -- TYPO
    SpellCap = { undercurl = true, sp = p.weak_warn },
    SpellLocal = { undercurl = true, sp = p.weak_warn },
    SpellRare = { undercurl = true, sp = p.weak_warn },

    -- -----------------------------------------------------------------------
    -- Quickfix
    -- -----------------------------------------------------------------------
    -- syntax/qf.vim only `hi def link`s these when a quickfix window first opens, which is *after*
    -- `hi clear` has run -- which is why the scheme never coloured them. Setting them here works
    -- because `hi def` yields to an existing definition.
    --
    -- The names are easy to guess wrong: the separators are qfSeparator1 and qfSeparator2 (there is
    -- no `qfSeparator`), and `qfType` is a syntax *cluster*, not a highlight group -- do not add it.
    --
    -- QuickFixLine uses `selection` rather than `caret_row`: the selected row of a results list is a
    -- selection, which is what IntelliJ's Find Usages panel shows, and `selection` already backs
    -- Visual and PmenuSel.
    QuickFixLine = { bg = p.selection },
    qfFileName = { fg = p.link }, -- HYPERLINK: a quickfix file name is a link
    qfLineNr = { fg = p.line_nr },
    qfSeparator1 = { fg = p.separator },
    qfSeparator2 = { fg = p.separator },
    qfText = { fg = p.fg },
    qfError = { fg = p.error },
    qfWarning = { fg = p.warn_stripe },
    qfNote = { fg = p.typo },
    qfInfo = { fg = p.weak_warn },

    -- -----------------------------------------------------------------------
    -- LSP extras
    -- -----------------------------------------------------------------------
    -- IDENTIFIER_UNDER_CARET_ATTRIBUTES and its write-access variant. One of the more recognisable
    -- parts of the IDE feel, driven by vim.lsp.buf.document_highlight().
    LspReferenceText = { bg = p.identifier_under_caret },
    LspReferenceRead = { bg = p.identifier_under_caret },
    LspReferenceWrite = { bg = p.write_identifier_under_caret },
    LspReferenceTarget = { bg = p.identifier_under_caret },

    LspInlayHint = { fg = p.inlay_fg, bg = p.inlay_bg },
    LspCodeLens = { fg = p.inlay_fg },
    LspCodeLensSeparator = { fg = p.separator },
    LspSignatureActiveParameter = { fg = p.fg, bold = true },

    -- -----------------------------------------------------------------------
    -- Diff and VCS
    -- -----------------------------------------------------------------------
    -- The diff viewer's two levels: a soft tint on a changed line, the full colour on the changed
    -- words. IntelliJ does not embolden either.
    DiffAdd = { bg = p.diff_inserted_line },
    DiffChange = { bg = p.diff_modified_line },
    DiffDelete = { fg = p.diff_del },
    DiffText = { bg = p.diff_modified },
    DiffTextAdd = { bg = p.diff_inserted },

    -- The old pane of a two-pane diff. Neovim paints a line that only the old side has as DiffAdd,
    -- but IntelliJ paints a deletion grey. git/diff.lua remaps DiffAdd and DiffTextAdd to these
    -- groups in that window only.
    IntellijDiffDeleted = { bg = p.diff_deleted_line },
    IntellijDiffDeletedText = { bg = p.diff_deleted },
    -- The filler lines that keep the panes aligned. IntelliJ draws no text there, so the fill
    -- character stays dim.
    IntellijDiffFiller = { fg = p.separator },
    -- A fold of unchanged lines. IntelliJ draws it as a bar in DIFF_SEPARATORS_BACKGROUND.
    IntellijDiffFold = { fg = p.folded_fg, bg = p.diff_separator },
    -- The pane headers. The plain text is the revision and path, and the dimmed text is the
    -- `(read-only)` note.
    IntellijDiffTitle = { fg = p.fg, bg = p.breadcrumb_current_bg },
    IntellijDiffTitleMeta = { fg = p.not_used, bg = p.breadcrumb_current_bg },

    -- The `Added`/`Changed`/`Removed` trio is what gitsigns-style plugins pick up; IntelliJ's
    -- FILESTATUS_* colours are the right source for them.
    Added = { fg = p.status_added },
    Changed = { fg = p.status_modified },
    Removed = { fg = p.status_unknown },

    -- -----------------------------------------------------------------------
    -- Terminal
    -- -----------------------------------------------------------------------
    -- Console output colours, so :terminal and LSP log buffers stay in the same family.
    Terminal = { fg = p.fg, bg = p.bg },

    -- -----------------------------------------------------------------------
    -- Debugger
    -- -----------------------------------------------------------------------
    -- debugPC is Vim's traditional name for the current-execution-line background.
    -- nvim-dap's DapStopped sign uses it (linehl = 'debugPC') and only defines the sign
    -- if it is not already defined, so this entry wins over nvim-dap's own default.
    debugPC = { bg = p.execution_point },
    -- Used for a non-top frame selected in the call stack, when its source line is shown
    -- for reference rather than as the live execution point.
    DapStoppedFrame = { bg = p.not_top_frame },
    -- Line background for a breakpoint row, matched to the breakpoint sign's linehl.
    DapBreakpointLine = { bg = p.breakpoint },
    -- Foreground for the breakpoint sign glyph, matched to IntelliJ's error-stripe red.
    DapBreakpointSign = { fg = p.error_stripe },
    -- The debug tool panel's current-frame row (debug.lua's call-stack list).
    IntellijLspDebugCurrentFrame = { bg = p.execution_point },
  }
end

return M
