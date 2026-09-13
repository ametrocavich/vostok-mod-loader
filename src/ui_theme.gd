## ----- ui_theme.gd -----
## Launcher palette tokens, the Theme, the style_* voices and the code-drawn glyphs.

# -- Design tokens ------------------------------------------------------------
# Matches the VostokMods site palette: one accent green, one success green, one red.

# Base surfaces
const COL_BG         := Color("1b1d1d")  # window/panel floor -- VostokMods --ui-bg
const COL_SURFACE    := Color("2b2e2e")  # buttons, inputs, rows -- --ui-bg-muted
const COL_SURFACE_2  := Color("3b3e3e")  # hover, elevated rows
const COL_BORDER     := Color("434747")  # 1px structural borders -- --ui-border-accented
const COL_BORDER_DIM := Color("282929")  # disabled/unselected -- --ui-border

const COL_TEXT       := Color("d9d9d9")  # body -- --ui-text
const COL_TEXT_HI    := Color("f1f1f1")  # emphasis/hover -- --ui-text-highlighted
const COL_TEXT_DIM   := Color("a0a0a0")  # secondary/meta -- --ui-text-muted (70% over the ground)
const COL_TEXT_FAINT := Color("7a7b7b")  # disabled only -- --ui-text-dimmed (50%)

const COL_ACCENT     := Color("00b806")  # focus, selected, primary, progress, badges -- brand green 600
const COL_ACCENT_DIM := Color("008b07")  # accent borders/washes, banner edges -- brand green 700

const COL_OK         := Color("00e604")  # enabled, success -- brand green 500
const COL_OK_DIM     := Color("0b5c12")  # brand green 900
const COL_ERR        := Color("ef4444")  # errors, blocked, danger
const COL_ERR_DIM    := Color("7f1d1d")

# Type scale
const FS_META  := 11   # timestamps, counts, fine print
const FS_BODY  := 12   # default body, buttons, rows
const FS_EMPH  := 13   # emphasized row titles, dialog body
const FS_HEAD  := 14   # section headings, dialog titles
const FS_TITLE := 16   # the window header plate only

# Spacing scale
const SP_XS := 2   # hairline gaps (badge-to-label)
const SP_S  := 4   # intra-row gaps
const SP_M  := 8   # between controls in a group
const SP_L  := 12  # between groups; container padding
const SP_XL := 16  # dialog outer padding, tab content padding

# Control sizing
const CTRL_H := 26  # uniform min height for single-line inputs (LineEdit, SpinBox)

# -- Sub-label / row-action factories -----------------------------------------
# Ellipsis trim and working tooltips (Labels default to MOUSE_FILTER_IGNORE).
func _make_sub_label(text: String, color: Color, tip := "") -> Label:
	var lbl := Label.new()
	lbl.text = text
	lbl.add_theme_color_override("font_color", color)
	lbl.add_theme_font_size_override("font_size", FS_BODY)
	lbl.clip_text = true
	lbl.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	if tip != "":
		lbl.tooltip_text = tip
		lbl.mouse_filter = Control.MOUSE_FILTER_PASS
	return lbl

# Flat inline action button for row sub-lines (Enable dependency, Load anyway, Re-check).
func _make_row_action(text: String, color: Color, tip := "") -> Button:
	var btn := Button.new()
	btn.text = text
	btn.flat = true
	btn.add_theme_color_override("font_color", color)
	# Flat buttons draw no hover stylebox; the brightened font is the hover cue.
	btn.add_theme_color_override("font_hover_color", color.lerp(COL_TEXT_HI, 0.35))
	btn.add_theme_color_override("font_pressed_color", color)
	btn.add_theme_font_size_override("font_size", FS_BODY)
	btn.size_flags_horizontal = Control.SIZE_SHRINK_END
	if tip != "":
		btn.tooltip_text = tip
	return btn

# Runtime-generated 16x16 pencil icon, monochrome to match the UI.
func _make_pencil_icon() -> ImageTexture:
	var img := Image.create(16, 16, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))
	var line := Color(0.84, 0.84, 0.84)  # matches C_TEXT in make_dark_theme
	for x in range(1, 13):
		img.set_pixel(x, 5, line)
		img.set_pixel(x, 9, line)
	for y in range(5, 10):
		img.set_pixel(1, y, line)
		img.set_pixel(12, y, line)
	for y in range(5, 10):
		img.set_pixel(4, y, line)
	img.set_pixel(13, 6, line)
	img.set_pixel(13, 7, line)
	img.set_pixel(13, 8, line)
	img.set_pixel(14, 7, line)
	return ImageTexture.create_from_image(img)

# Runtime-generated 16x16 trashcan icon.
func _make_trashcan_icon() -> ImageTexture:
	var img := Image.create(16, 16, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))
	var line := Color(0.84, 0.84, 0.84)  # matches C_TEXT in make_dark_theme
	for x in range(6, 10):
		img.set_pixel(x, 2, line)
	for x in range(3, 13):
		img.set_pixel(x, 4, line)
	for y in range(5, 14):
		img.set_pixel(4, y, line)
		img.set_pixel(11, y, line)
	for x in range(5, 11):
		img.set_pixel(x, 13, line)
	for y in range(6, 12):
		img.set_pixel(6, y, line)
		img.set_pixel(8, y, line)
		img.set_pixel(10, y, line)
	return ImageTexture.create_from_image(img)

func make_dark_theme() -> Theme:
	var t := Theme.new()
	# Pin the default font size; the engine's 16px default would flatten the type scale.
	t.default_font_size = FS_BODY

	_theme_buttons(t)
	_theme_checkboxes_and_menus(t)
	_theme_panels_and_tabs(t)
	_theme_inputs(t)
	_theme_scrollbars(t)
	_theme_progress_tooltips_dialogs(t)
	return t


# Button and OptionButton (a separate theme type that reuses the same boxes).
func _theme_buttons(t: Theme) -> void:
	var bn := _make_button_stylebox(COL_SURFACE, COL_BORDER)
	var bh := _make_button_stylebox(COL_SURFACE_2, COL_TEXT_HI)
	var bp := _make_button_stylebox(COL_BG, COL_BORDER)
	var bd := _make_button_stylebox(COL_BG, COL_BORDER_DIM)
	t.set_stylebox("normal",   "Button", bn)
	t.set_stylebox("hover",    "Button", bh)
	t.set_stylebox("pressed",  "Button", bp)
	t.set_stylebox("disabled", "Button", bd)
	t.set_stylebox("focus",    "Button", _make_focus_stylebox())
	t.set_color("font_color",          "Button", COL_TEXT)
	t.set_color("font_hover_color",    "Button", COL_TEXT_HI)
	t.set_color("font_pressed_color",  "Button", COL_TEXT)
	t.set_color("font_focus_color",    "Button", COL_TEXT)
	t.set_color("font_disabled_color", "Button", COL_TEXT_FAINT)

	# -- OptionButton (separate theme type from Button, so re-set styles) ------
	t.set_stylebox("normal",   "OptionButton", bn.duplicate())
	t.set_stylebox("hover",    "OptionButton", bh.duplicate())
	t.set_stylebox("pressed",  "OptionButton", bp.duplicate())
	t.set_stylebox("disabled", "OptionButton", bd.duplicate())
	t.set_stylebox("focus",    "OptionButton", _make_focus_stylebox())
	t.set_color("font_color",         "OptionButton", COL_TEXT)
	t.set_color("font_hover_color",   "OptionButton", COL_TEXT_HI)
	t.set_color("font_pressed_color", "OptionButton", COL_TEXT)


# CheckBox and its radio variants, plus PopupMenu, which reuses the same glyphs.
func _theme_checkboxes_and_menus(t: Theme) -> void:
	t.set_color("font_color",       "CheckBox", COL_TEXT)
	t.set_color("font_hover_color", "CheckBox", COL_TEXT_HI)
	t.set_stylebox("focus", "CheckBox", _make_focus_stylebox())
	var cb_checked := _make_checkbox_icon(true, COL_BORDER, COL_ACCENT)
	var cb_unchecked := _make_checkbox_icon(false, COL_BORDER, COL_ACCENT)
	t.set_icon("checked",   "CheckBox", cb_checked)
	t.set_icon("unchecked", "CheckBox", cb_unchecked)
	t.set_icon("checked_disabled",   "CheckBox", _make_checkbox_icon(true, COL_BORDER_DIM, COL_TEXT_FAINT))
	t.set_icon("unchecked_disabled", "CheckBox", _make_checkbox_icon(false, COL_BORDER_DIM, COL_TEXT_FAINT))
	# Radio variants: CheckBox + ButtonGroup switches to the radio_* icons.
	var rb_checked := _make_radio_icon(true, COL_BORDER, COL_ACCENT)
	var rb_unchecked := _make_radio_icon(false, COL_BORDER, COL_ACCENT)
	t.set_icon("radio_checked",   "CheckBox", rb_checked)
	t.set_icon("radio_unchecked", "CheckBox", rb_unchecked)
	t.set_icon("radio_checked_disabled",   "CheckBox", _make_radio_icon(true, COL_BORDER_DIM, COL_TEXT_FAINT))
	t.set_icon("radio_unchecked_disabled", "CheckBox", _make_radio_icon(false, COL_BORDER_DIM, COL_TEXT_FAINT))

	# -- PopupMenu (OptionButton dropdown) -------------------------------------
	var pm_panel := StyleBoxFlat.new()
	pm_panel.bg_color = COL_SURFACE
	pm_panel.border_color = COL_BORDER
	_sb_border(pm_panel)
	pm_panel.content_margin_left = SP_S
	pm_panel.content_margin_right = SP_S
	pm_panel.content_margin_top = SP_S
	pm_panel.content_margin_bottom = SP_S
	t.set_stylebox("panel", "PopupMenu", pm_panel)
	var pm_hover := StyleBoxFlat.new()
	pm_hover.bg_color = COL_SURFACE_2
	t.set_stylebox("hover", "PopupMenu", pm_hover)
	var pm_sep := StyleBoxFlat.new()
	pm_sep.bg_color = COL_BORDER_DIM
	pm_sep.content_margin_top = 1; pm_sep.content_margin_bottom = 1
	t.set_stylebox("separator", "PopupMenu", pm_sep)
	t.set_color("font_color",           "PopupMenu", COL_TEXT)
	t.set_color("font_hover_color",     "PopupMenu", COL_TEXT_HI)
	t.set_color("font_disabled_color",  "PopupMenu", COL_TEXT_FAINT)
	t.set_color("font_separator_color", "PopupMenu", COL_TEXT_DIM)
	# Checked menu items reuse the checkbox glyphs (stock marks are light).
	t.set_icon("checked",         "PopupMenu", cb_checked)
	t.set_icon("unchecked",       "PopupMenu", cb_unchecked)
	t.set_icon("radio_checked",   "PopupMenu", rb_checked)
	t.set_icon("radio_unchecked", "PopupMenu", rb_unchecked)


# Label, Panel, TabContainer and HSeparator.
func _theme_panels_and_tabs(t: Theme) -> void:
	# -- Label -----------------------------------------------------------------
	t.set_color("font_color", "Label", COL_TEXT)

	# -- Panel / PanelContainer ------------------------------------------------
	var ps := StyleBoxFlat.new(); ps.bg_color = COL_BG
	t.set_stylebox("panel", "Panel",          ps)
	t.set_stylebox("panel", "PanelContainer", ps.duplicate())

	# -- TabContainer: the selected tab carries a 2px accent roofline; StyleBoxFlat
	# has one border color, so side borders go to 0.
	var ts := StyleBoxFlat.new()   # selected tab
	ts.bg_color = COL_BG
	ts.border_color = COL_ACCENT
	ts.border_width_top = 2; ts.border_width_left = 0; ts.border_width_right = 0
	ts.border_width_bottom = 0
	ts.content_margin_left = SP_L; ts.content_margin_right = SP_L
	ts.content_margin_top = 5;   ts.content_margin_bottom = 5
	var tu := StyleBoxFlat.new()   # unselected tab
	tu.bg_color = Color(0.02, 0.02, 0.02)  # a step below COL_BG so inactive tabs recede
	tu.border_color = COL_BORDER_DIM
	_sb_border(tu)
	tu.content_margin_left = SP_L; tu.content_margin_right = SP_L
	tu.content_margin_top = 5;   tu.content_margin_bottom = 5
	var tc_panel := StyleBoxFlat.new(); tc_panel.bg_color = COL_BG
	tc_panel.content_margin_left   = 10
	tc_panel.content_margin_right  = 10
	tc_panel.content_margin_top    = 8
	tc_panel.content_margin_bottom = 8
	t.set_stylebox("tab_selected",   "TabContainer", ts)
	t.set_stylebox("tab_unselected", "TabContainer", tu)
	t.set_stylebox("tab_hovered",    "TabContainer", tu.duplicate())
	t.set_stylebox("panel",          "TabContainer", tc_panel)
	t.set_color("font_selected_color",   "TabContainer", COL_TEXT_HI)
	t.set_color("font_unselected_color", "TabContainer", COL_TEXT_DIM)
	t.set_color("font_hovered_color",    "TabContainer", COL_TEXT)

	# -- HSeparator ------------------------------------------------------------
	var sep := StyleBoxFlat.new(); sep.bg_color = COL_BORDER_DIM
	t.set_stylebox("separator", "HSeparator", sep)
	t.set_constant("separation", "HSeparator", 1)


# LineEdit, TextEdit and the SpinBox arrows.
func _theme_inputs(t: Theme) -> void:
	# -- LineEdit (SpinBox uses this internally) --------------------------------
	var le := StyleBoxFlat.new()
	le.bg_color = COL_SURFACE
	le.border_color = COL_BORDER
	_sb_border(le)
	le.content_margin_left = 6
	le.content_margin_right = 6
	le.content_margin_top = 3
	le.content_margin_bottom = 3
	var le_focus: StyleBoxFlat = le.duplicate()
	le_focus.border_color = COL_ACCENT
	t.set_stylebox("normal", "LineEdit", le)
	t.set_stylebox("focus",  "LineEdit", le_focus)
	t.set_color("font_color", "LineEdit", COL_TEXT)

	# -- TextEdit (multi-line) -- mirror LineEdit so it matches the system.
	t.set_stylebox("normal", "TextEdit", le)
	t.set_stylebox("focus",  "TextEdit", le_focus)
	t.set_color("font_color", "TextEdit", COL_TEXT)

	# -- SpinBox arrows (stock glyph is light-theme) -----------------------------
	t.set_icon("updown", "SpinBox", _make_updown_icon(COL_TEXT_DIM))


# ScrollContainer and both scrollbars.
func _theme_scrollbars(t: Theme) -> void:
	# -- ScrollContainer (transparent, scrollbars inherit) ---------------------
	t.set_stylebox("panel", "ScrollContainer", StyleBoxEmpty.new())

	# -- ScrollBars: width comes from stylebox minimum sizes (track 2+2, grabber
	# 6+6 = 16px); along-axis margins keep the grabber a usable length.
	var track_v := StyleBoxFlat.new()
	track_v.bg_color = COL_BG
	track_v.border_color = COL_BORDER_DIM
	track_v.border_width_left = 1
	track_v.content_margin_left = 2
	track_v.content_margin_right = 2
	var grab_v := StyleBoxFlat.new()
	grab_v.bg_color = COL_BORDER
	grab_v.content_margin_left = 6
	grab_v.content_margin_right = 6
	grab_v.content_margin_top = 12
	grab_v.content_margin_bottom = 12
	var grab_v_hi: StyleBoxFlat = grab_v.duplicate()
	grab_v_hi.bg_color = COL_TEXT_DIM
	t.set_stylebox("scroll",            "VScrollBar", track_v)
	t.set_stylebox("grabber",           "VScrollBar", grab_v)
	t.set_stylebox("grabber_highlight", "VScrollBar", grab_v_hi)
	t.set_stylebox("grabber_pressed",   "VScrollBar", grab_v_hi.duplicate())
	var track_h := StyleBoxFlat.new()
	track_h.bg_color = COL_BG
	track_h.border_color = COL_BORDER_DIM
	track_h.border_width_top = 1
	track_h.content_margin_top = 2
	track_h.content_margin_bottom = 2
	var grab_h := StyleBoxFlat.new()
	grab_h.bg_color = COL_BORDER
	grab_h.content_margin_top = 6
	grab_h.content_margin_bottom = 6
	grab_h.content_margin_left = 12
	grab_h.content_margin_right = 12
	var grab_h_hi: StyleBoxFlat = grab_h.duplicate()
	grab_h_hi.bg_color = COL_TEXT_DIM
	t.set_stylebox("scroll",            "HScrollBar", track_h)
	t.set_stylebox("grabber",           "HScrollBar", grab_h)
	t.set_stylebox("grabber_highlight", "HScrollBar", grab_h_hi)
	t.set_stylebox("grabber_pressed",   "HScrollBar", grab_h_hi.duplicate())


# ProgressBar, tooltips, and the dialog and embedded-window borders.
func _theme_progress_tooltips_dialogs(t: Theme) -> void:
	# -- ProgressBar (modpack apply / download progress) -------------------------
	var pb_bg := StyleBoxFlat.new()
	pb_bg.bg_color = COL_SURFACE
	pb_bg.border_color = COL_BORDER
	_sb_border(pb_bg)
	var pb_fill := StyleBoxFlat.new()
	pb_fill.bg_color = COL_ACCENT_DIM
	pb_fill.border_color = COL_ACCENT
	_sb_border(pb_fill)
	t.set_stylebox("background", "ProgressBar", pb_bg)
	t.set_stylebox("fill",       "ProgressBar", pb_fill)
	t.set_font_size("font_size", "ProgressBar", FS_META)
	t.set_color("font_color",    "ProgressBar", COL_TEXT)

	# -- Tooltip -- without these, tooltips render in the default light theme.
	var tt_panel := StyleBoxFlat.new()
	tt_panel.bg_color = COL_SURFACE_2
	tt_panel.border_color = COL_BORDER
	_sb_border(tt_panel)
	tt_panel.content_margin_left = SP_M
	tt_panel.content_margin_right = SP_M
	tt_panel.content_margin_top = SP_S
	tt_panel.content_margin_bottom = SP_S
	t.set_stylebox("panel", "TooltipPanel", tt_panel)
	t.set_color("font_color", "TooltipLabel", COL_TEXT)
	t.set_font_size("font_size", "TooltipLabel", FS_META)

	# -- AcceptDialog / ConfirmationDialog -------------------------------------
	var dlg_panel := StyleBoxFlat.new()
	dlg_panel.bg_color = COL_SURFACE
	dlg_panel.border_color = COL_BORDER
	_sb_border(dlg_panel)
	# Same padding tokens as _make_dialog_panel_stylebox.
	dlg_panel.content_margin_left = SP_XL
	dlg_panel.content_margin_right = SP_XL
	dlg_panel.content_margin_top = SP_L
	dlg_panel.content_margin_bottom = SP_L
	t.set_stylebox("panel", "AcceptDialog", dlg_panel)
	t.set_stylebox("panel", "ConfirmationDialog", dlg_panel.duplicate())
	t.set_stylebox("embedded_border",           "Window", dlg_panel.duplicate())
	t.set_stylebox("embedded_unfocused_border", "Window", dlg_panel.duplicate())
	t.set_color("title_color", "Window", COL_TEXT_HI)

# -- Theme building blocks + component voices ---------------------------------
# Call sites opt into a voice via the style_* helpers; default buttons take the theme.

# Uniform 1px-border box with the theme's 10/4 button margins.
func _make_button_stylebox(bg: Color, border: Color) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = bg
	s.border_color = border
	_sb_border(s)
	s.content_margin_left = 10
	s.content_margin_right = 10
	s.content_margin_top = 4
	s.content_margin_bottom = 4
	return s

# Keyboard-focus ring: 1px accent border, no fill.
func _make_focus_stylebox() -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.draw_center = false
	s.border_color = COL_ACCENT
	_sb_border(s)
	return s

# Primary button voice: accent text and hover border. At most one per surface.
func style_primary_button(b: Button) -> void:
	_style_accent_button(b, COL_ACCENT)

# Danger button voice (Delete, Unload): red text + red hover border.
func style_danger_button(b: Button) -> void:
	_style_accent_button(b, COL_ERR)

# Accent voices for dialog action buttons. Kept on modulate: a theme
# font-color override on a dialog OK button does not take effect.
func style_dialog_primary_button(b: Button) -> void:
	b.modulate = COL_ACCENT

func style_dialog_danger_button(b: Button) -> void:
	b.modulate = COL_ERR

# Shared body of the two accent voices; everything else stays on the theme.
func _style_accent_button(b: Button, accent: Color) -> void:
	b.add_theme_color_override("font_color", accent)
	b.add_theme_color_override("font_hover_color", accent)
	b.add_theme_color_override("font_pressed_color", accent)
	# Keep the accent while keyboard-focused.
	b.add_theme_color_override("font_focus_color", accent)
	b.add_theme_font_size_override("font_size", FS_BODY)
	b.add_theme_stylebox_override("hover", _make_button_stylebox(COL_SURFACE_2, accent))

# Badge chip stylebox (update counts, dependency state). Defaults to the
# accent notice look; pass COL_ERR/COL_ERR_DIM for error badges.
func _make_badge_stylebox(border: Color = COL_ACCENT, bg: Color = COL_ACCENT_DIM) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = bg
	s.border_color = border
	_sb_border(s)
	s.content_margin_left = SP_S
	s.content_margin_right = SP_S
	s.content_margin_top = SP_XS
	s.content_margin_bottom = SP_XS
	return s

# Banner: a COL_SURFACE strip with a 3px colored left edge. Returns
# {"panel", "row", "label"} so callers can append action buttons.
func _make_banner(text: String, edge_color: Color) -> Dictionary:
	var panel := PanelContainer.new()
	var s := StyleBoxFlat.new()
	s.bg_color = COL_SURFACE
	s.border_color = edge_color
	s.border_width_left = 3
	s.content_margin_left = SP_L
	s.content_margin_right = SP_L
	s.content_margin_top = SP_M
	s.content_margin_bottom = SP_M
	panel.add_theme_stylebox_override("panel", s)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", SP_L)
	panel.add_child(row)
	var lbl := Label.new()
	lbl.text = text
	lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	lbl.add_theme_font_size_override("font_size", FS_BODY)
	row.add_child(lbl)
	return {"panel": panel, "row": row, "label": lbl}

# Runtime-generated 14x14 checkbox glyph; checked adds a 2px check stroke.
func _make_checkbox_icon(checked: bool, box_color: Color, mark_color: Color) -> ImageTexture:
	var img := Image.create(14, 14, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))
	for y in range(1, 13):
		for x in range(1, 13):
			img.set_pixel(x, y, COL_SURFACE)
	for i in range(1, 13):
		img.set_pixel(i, 1, box_color)
		img.set_pixel(i, 12, box_color)
		img.set_pixel(1, i, box_color)
		img.set_pixel(12, i, box_color)
	if checked:
		var pts := [
			Vector2i(3, 7), Vector2i(4, 8), Vector2i(5, 9),
			Vector2i(6, 8), Vector2i(7, 7), Vector2i(8, 6),
			Vector2i(9, 5), Vector2i(10, 4),
		]
		for p in pts:
			img.set_pixel(p.x, p.y, mark_color)
			img.set_pixel(p.x, p.y + 1, mark_color)
	return ImageTexture.create_from_image(img)

# Runtime-generated 14x14 radio glyph; distance-field ring, checked adds a dot.
func _make_radio_icon(checked: bool, ring_color: Color, mark_color: Color) -> ImageTexture:
	var img := Image.create(14, 14, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))
	var c := Vector2(6.5, 6.5)
	for y in range(14):
		for x in range(14):
			var d := Vector2(x + 0.5, y + 0.5).distance_to(c)
			if checked and d <= 2.2:
				img.set_pixel(x, y, mark_color)
			elif d <= 4.5:
				img.set_pixel(x, y, COL_SURFACE)
			elif d <= 5.5:
				img.set_pixel(x, y, ring_color)
	return ImageTexture.create_from_image(img)

# Runtime-generated 9x14 SpinBox arrows (the stock glyph is light-theme gray).
func _make_updown_icon(line: Color) -> ImageTexture:
	var img := Image.create(9, 14, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))
	for row in range(3):
		for x in range(4 - row, 5 + row):
			img.set_pixel(x, 2 + row, line)   # up triangle, apex on top
			img.set_pixel(x, 11 - row, line)  # down triangle, apex on bottom
	return ImageTexture.create_from_image(img)

# Runtime-generated 14x14 close glyph, two diagonals (keeps the source ASCII).
func _make_close_icon(line: Color) -> ImageTexture:
	var img := Image.create(14, 14, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))
	for i in range(14):
		for t in range(-1, 2):
			var a := i + t
			if a >= 0 and a < 14:
				img.set_pixel(a, i, line)
				img.set_pixel(a, 13 - i, line)
	return ImageTexture.create_from_image(img)
