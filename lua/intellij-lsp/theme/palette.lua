--- Colors of IntelliJ's "Islands Dark" editor scheme.
---
--- Transcribed from the platform's own "Islands Dark" scheme definition, which is the only source
--- of truth.
---
--- That scheme declares `parent_scheme="Darcula"`, so keys it omits fall back to Darcula and then
--- to the platform's `Default` scheme. Two inherited values are used below and cannot be found by
--- searching the Islands scheme: `selection` and `selection_inactive`.
---
--- The scheme also carries `deuteranopia=`/`protanopia=` sibling attributes on many colors. Those
--- are colorblind-adjusted alternates that IntelliJ swaps in at runtime; this palette takes the
--- default-vision `value=` only.
---
--- This module is data. Nothing here reads or writes highlight state -- see theme/groups.lua for
--- the mapping onto Neovim groups and theme.lua for applying it.

local M = {}

-- ---------------------------------------------------------------------------
-- Editor surface and chrome
-- ---------------------------------------------------------------------------

--- TEXT
M.fg = '#BCBEC4'
M.bg = '#191A1C'

--- CARET_COLOR / CARET_ROW_COLOR
M.caret = '#CED0D6'
M.caret_row = '#1F2024'

--- LINE_NUMBERS_COLOR / LINE_NUMBER_ON_CARET_ROW_COLOR
M.line_nr = '#4B5059'
M.line_nr_caret = '#A1A3AB'

--- INDENT_GUIDE / SELECTED_INDENT_GUIDE / VISUAL_INDENT_GUIDE
M.indent_guide = '#323438'
M.selected_indent_guide = '#4E5157'
M.visual_indent_guide = '#2B2D30'

--- RIGHT_MARGIN_COLOR / WHITESPACES
M.right_margin = '#323438'
M.whitespace = '#6F737A'

--- Inherited from Darcula: Islands Dark never redefines SELECTION_BACKGROUND, so the New UI
--- selection colour is still the classic Darcula blue.
M.selection = '#214283'
M.selection_inactive = '#4C4F56'

--- LOOKUP_COLOR / DOCUMENTATION_COLOR (both #27282B) and HINT_BORDER
M.popup_bg = '#27282B'
M.popup_border = '#393B40'

--- METHOD_SEPARATORS_COLOR, also used for CODE_LENS_BORDER_COLOR
M.separator = '#43454A'

--- FOLDED_TEXT_ATTRIBUTES
M.folded_fg = '#868991'
M.folded_bg = '#393B40'

--- MATCHED_BRACE_ATTRIBUTES (background; the scheme adds FONT_TYPE 1 = bold)
M.matched_brace = '#43454A'

--- UNMATCHED_BRACE_ATTRIBUTES
M.unmatched_brace = '#F75464'

--- IDENTIFIER_UNDER_CARET_ATTRIBUTES / WRITE_IDENTIFIER_UNDER_CARET_ATTRIBUTES
M.identifier_under_caret = '#373B39'
M.write_identifier_under_caret = '#402F33'

--- SEARCH_RESULT_ATTRIBUTES / TEXT_SEARCH_RESULT_ATTRIBUTES / WRITE_SEARCH_RESULT_ATTRIBUTES
M.search_result = '#2D543F'
M.text_search_result = '#114957'
M.write_search_result = '#66313F'

--- INLAY_DEFAULT and INLINE_PARAMETER_HINT
M.inlay_fg = '#868A91'
M.inlay_bg = '#393B40'
M.hint_fg = '#858A94'

--- NOT_USED_ELEMENT_ATTRIBUTES -- IntelliJ's dimmed "unused" grey
M.not_used = '#6F737A'

--- HYPERLINK_ATTRIBUTES / CTRL_CLICKABLE and FOLLOWED_HYPERLINK_ATTRIBUTES
M.link = '#548AF7'
M.link_visited = '#B189F5'

--- BREADCRUMBS_DEFAULT / BREADCRUMBS_CURRENT
M.breadcrumb_fg = '#9DA0A8'
M.breadcrumb_current_fg = '#DFE1E5'
M.breadcrumb_current_bg = '#2B2D30'

--- NOTIFICATION_BACKGROUND
M.notification_bg = '#25324D'

-- ---------------------------------------------------------------------------
-- Syntax
-- ---------------------------------------------------------------------------

--- DEFAULT_KEYWORD
M.keyword = '#CF8E6D'

--- DEFAULT_STRING
M.string = '#6AAB73'

--- DEFAULT_VALID_STRING_ESCAPE (keyword-coloured in this scheme)
M.string_escape = '#CF8E6D'

--- DEFAULT_LINE_COMMENT / DEFAULT_BLOCK_COMMENT
M.comment = '#7A7E85'

--- DEFAULT_DOC_COMMENT (italic) and its tag/markup/link colours
M.doc_comment = '#5F826B'
M.doc_tag = '#67A37C'
M.doc_tag_value = '#ABADB3'
M.doc_markup = '#68A67E'
M.doc_link = '#3887A1'

--- DEFAULT_NUMBER
M.number = '#2AACB8'

--- DEFAULT_FUNCTION_DECLARATION and DEFAULT_INSTANCE_METHOD / DEFAULT_STATIC_METHOD.
--- Note the two are one shade apart in the scheme, not a mistake in transcription.
M.fn_decl = '#56A8F5'
M.method = '#57AAF7'

--- DEFAULT_INSTANCE_FIELD / DEFAULT_STATIC_FIELD / DEFAULT_CONSTANT (the latter two italic)
M.field = '#C77DBB'

--- DEFAULT_METADATA -- annotations
M.annotation = '#B3AE60'

--- TYPE_PARAMETER_NAME_ATTRIBUTES
M.type_param = '#16BAAC'

--- DEFAULT_REASSIGNED_LOCAL_VARIABLE / DEFAULT_REASSIGNED_PARAMETER underline colour. IntelliJ
--- keeps the text itself at `fg` and only adds this underline.
M.reassigned = '#84868C'

--- Kotlin-specific keys
M.kotlin_label = '#32B8AF'
M.kotlin_named_arg = '#56C1D6'
M.kotlin_smart_cast = '#1A3B2D'

--- XML_TAG / XML_TAG_NAME / XML_PROLOGUE, XML_CUSTOM_TAG_NAME, XML_ENTITY_REFERENCE
M.xml_tag = '#D5B778'
M.xml_custom_tag = '#2FBAA3'
M.xml_entity = '#56A8F5'

-- ---------------------------------------------------------------------------
-- Diagnostics
-- ---------------------------------------------------------------------------
-- IntelliJ splits each severity in two: EFFECT_COLOR paints the squiggle under the code, and
-- ERROR_STRIPE_COLOR paints the marker in the scrollbar. Neovim has no scrollbar, so groups.lua
-- uses the wave colour for `sp` and the stripe colour wherever a solid foreground is needed
-- (virtual text, sign column).

--- ERRORS_ATTRIBUTES, plus WRONG_REFERENCES_ATTRIBUTES / BAD_CHARACTER for solid red text
M.error_wave = '#FA6675'
M.error_stripe = '#D64D5B'
M.error = '#F75464'

--- WARNING_ATTRIBUTES
M.warn_wave = '#F2C55C'
M.warn_stripe = '#C29E4A'

--- INFO_ATTRIBUTES -- IntelliJ's "weak warning"
M.weak_warn = '#857042'

--- TYPO
M.typo = '#7EC482'

--- TODO_DEFAULT_ATTRIBUTES (italic in the scheme)
M.todo = '#8BB33D'
M.todo_stripe = '#73AD2B'

--- "Unresolved reference access" -- dimmer and dotted, distinct from WRONG_REFERENCES_ATTRIBUTES
M.unresolved = '#757A85'

-- ---------------------------------------------------------------------------
-- VCS, diff and console
-- ---------------------------------------------------------------------------

--- ADDED_LINES_COLOR / MODIFIED_LINES_COLOR / DELETED_LINES_COLOR
M.diff_add = '#549159'
M.diff_mod = '#375FAD'
M.diff_del = '#868A91'

--- DIFF_SEPARATORS_BACKGROUND
M.diff_separator = '#2B2D30'

--- DIFF_INSERTED / DIFF_MODIFIED / DIFF_DELETED, inherited from Darcula. These are the diff viewer's
--- colours. The *_LINES_COLOR values above are the gutter stripes, which are too loud for a whole line.
M.diff_inserted = '#294436'
M.diff_modified = '#385570'
M.diff_deleted = '#484A4A'

--- The line tints of the diff viewer. IntelliJ paints a changed line with
--- `ColorUtil.mix(colour, bg, 0.6)` and keeps the full colour for the changed words inside it
--- (TextDiffTypeFactory.getIgnoredColor). Computed here against `bg`.
M.diff_inserted_line = '#1F2B26'
M.diff_modified_line = '#25323E'
M.diff_deleted_line = '#2C2D2E'

--- FILESTATUS_* -- the colours IntelliJ uses for file names in trees and tabs
M.status_added = '#73BD79'
M.status_modified = '#70AEFF'
M.status_deleted = '#6F737A'
M.status_merged = '#CF84CF'
M.status_unknown = '#E88F89'
M.status_ignored = '#D69A6B'
M.status_conflict = '#DE6A66'

--- Console output and log levels
M.console_error = '#F75464'
M.console_info = '#E0BB65'
M.console_verbose = '#56A8F5'

--- Debugger line highlights
M.execution_point = '#2A5091'
M.not_top_frame = '#273552'
M.breakpoint = '#40252B'

return M
