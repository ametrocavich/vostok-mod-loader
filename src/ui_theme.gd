# Launcher tokens (the Vostok Mods site palette), the Theme, the style_* voices
# and the code-drawn glyphs.

const COL_BG         := Color("1b1d1d")
const COL_SURFACE    := Color("2b2e2e")
const COL_SURFACE_2  := Color("3b3e3e")
const COL_BORDER     := Color("434747")
const COL_BORDER_DIM := Color("282929")

const COL_TEXT       := Color("d9d9d9")
const COL_TEXT_HI    := Color("f1f1f1")
const COL_TEXT_DIM   := Color("a0a0a0")
const COL_TEXT_FAINT := Color("7a7b7b")

const COL_ACCENT     := Color("00b806")
const COL_ACCENT_DIM := Color("008b07")

const COL_OK         := Color("00e604")
const COL_OK_DIM     := Color("0b5c12")
const COL_ERR        := Color("ef4444")
const COL_WARN       := Color("f59e0b")  # amber, "orange" in player copy

const FS_META  := 11
const FS_BODY  := 12
const FS_EMPH  := 13
const FS_HEAD  := 14
const FS_TITLE := 16

const SP_XS := 2
const SP_S  := 4
const SP_M  := 8
const SP_L  := 12
const SP_XL := 16

const CTRL_H := 26
const ICON_BTN_W := 28

# A transparent border color: _make_box draws no border with it.
const NO_BORDER := Color(0, 0, 0, 0)

# A Label with optional color and size overrides (null and 0 leave the theme's).
func _make_label(text: String, color: Variant = null, font_size := 0) -> Label:
	var lbl := Label.new()
	lbl.text = text
	if color != null:
		lbl.add_theme_color_override("font_color", color)
	if font_size > 0:
		lbl.add_theme_font_size_override("font_size", font_size)
	return lbl

# Ellipsis-trimmed label; a tip switches mouse_filter to PASS because Labels
# default to IGNORE and would never show it.
func _make_sub_label(text: String, color: Color, tip := "", font_size: int = 0) -> Label:
	var lbl := _make_label(text, color, font_size if font_size > 0 else FS_BODY)
	lbl.clip_text = true
	lbl.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	if tip != "":
		lbl.tooltip_text = tip
		lbl.mouse_filter = Control.MOUSE_FILTER_PASS
	return lbl

func _make_head_label(text: String, color: Color = COL_TEXT) -> Label:
	return _make_label(text, color, FS_HEAD)

func _make_scroll(parent: Node) -> ScrollContainer:
	var scroll := ScrollContainer.new()
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	parent.add_child(scroll)
	return scroll

# The column a scroll holds. Its right margin clears the overlay scrollbar,
# which would hide each row's right edge; a separation below 0 keeps the theme's.
func _make_scroll_column(scroll: ScrollContainer, separation: int = -1, margin_left: int = 0) -> VBoxContainer:
	var wrap := MarginContainer.new()
	wrap.add_theme_constant_override("margin_right", SP_XL)
	if margin_left > 0:
		wrap.add_theme_constant_override("margin_left", margin_left)
	wrap.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(wrap)
	var column := VBoxContainer.new()
	column.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	if separation >= 0:
		column.add_theme_constant_override("separation", separation)
	wrap.add_child(column)
	return column

func _clear_children(node: Node) -> void:
	for child in node.get_children():
		child.queue_free()

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

# Axis-aligned 1px segments [x0, y0, x1, y1], both ends inclusive.
func _segment_icon(w: int, h: int, color: Color, segments: Array) -> ImageTexture:
	var img := Image.create(w, h, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))
	for s in segments:
		for y in range(s[1], s[3] + 1):
			for x in range(s[0], s[2] + 1):
				img.set_pixel(x, y, color)
	return ImageTexture.create_from_image(img)

func _make_pencil_icon() -> ImageTexture:
	return _segment_icon(16, 16, Color(0.84, 0.84, 0.84), [[1, 5, 12, 5], [1, 9, 12, 9],
			[1, 5, 1, 9], [12, 5, 12, 9], [4, 5, 4, 9], [13, 6, 13, 8], [14, 7, 14, 7]])

func _make_trashcan_icon() -> ImageTexture:
	return _segment_icon(16, 16, Color(0.84, 0.84, 0.84), [[6, 2, 9, 2], [3, 4, 12, 4],
			[4, 5, 4, 13], [11, 5, 11, 13], [5, 13, 10, 13], [6, 6, 6, 11], [8, 6, 8, 11], [10, 6, 10, 11]])

func make_dark_theme() -> Theme:
	var t := Theme.new()
	# The engine's 16px default would flatten the type scale.
	t.default_font_size = FS_BODY

	var bn := _make_button_stylebox(COL_SURFACE, COL_BORDER)
	var bh := _make_button_stylebox(COL_SURFACE_2, COL_TEXT_HI)
	var bp := _make_button_stylebox(COL_BG, COL_BORDER)
	var bd := _make_button_stylebox(COL_BG, COL_BORDER_DIM)
	for type: String in ["Button", "OptionButton"]:
		t.set_stylebox("normal",   type, bn)
		t.set_stylebox("hover",    type, bh)
		t.set_stylebox("pressed",  type, bp)
		t.set_stylebox("disabled", type, bd)
		t.set_stylebox("focus",    type, _make_focus_stylebox())
		t.set_color("font_color",         type, COL_TEXT)
		t.set_color("font_hover_color",   type, COL_TEXT_HI)
		t.set_color("font_pressed_color", type, COL_TEXT)
	# OptionButton keeps the engine's focus and disabled font colors.
	t.set_color("font_focus_color",    "Button", COL_TEXT)
	t.set_color("font_disabled_color", "Button", COL_TEXT_FAINT)

	t.set_color("font_color",       "CheckBox", COL_TEXT)
	t.set_color("font_hover_color", "CheckBox", COL_TEXT_HI)
	t.set_stylebox("focus", "CheckBox", _make_focus_stylebox())
	# CheckBox + ButtonGroup switches to the radio_* icons.
	for prefix: String in ["", "radio_"]:
		var glyph: Callable = _make_radio_icon if prefix == "radio_" else _make_checkbox_icon
		for checked: bool in [true, false]:
			var icon_name := prefix + ("checked" if checked else "unchecked")
			t.set_icon(icon_name, "CheckBox", glyph.call(checked, COL_BORDER, COL_ACCENT))
			t.set_icon(icon_name + "_disabled", "CheckBox", glyph.call(checked, COL_BORDER_DIM, COL_TEXT_FAINT))

	t.set_stylebox("panel", "PopupMenu", _make_box(COL_SURFACE, COL_BORDER, SP_S, SP_S))
	t.set_stylebox("hover", "PopupMenu", _make_box(COL_SURFACE_2))
	t.set_stylebox("separator", "PopupMenu", _make_box(COL_BORDER_DIM, NO_BORDER, 0, 1))
	t.set_color("font_color",           "PopupMenu", COL_TEXT)
	t.set_color("font_hover_color",     "PopupMenu", COL_TEXT_HI)
	t.set_color("font_disabled_color",  "PopupMenu", COL_TEXT_FAINT)
	t.set_color("font_separator_color", "PopupMenu", COL_TEXT_DIM)
	# The stock check marks are light-theme; menus reuse the checkbox glyphs.
	for icon_name: String in ["checked", "unchecked", "radio_checked", "radio_unchecked"]:
		t.set_icon(icon_name, "PopupMenu", t.get_icon(icon_name, "CheckBox"))

	t.set_color("font_color", "Label", COL_TEXT)

	var ps := _make_box(COL_BG)
	t.set_stylebox("panel", "Panel",          ps)
	t.set_stylebox("panel", "PanelContainer", ps)

	# The selected tab has a 2px accent roofline; StyleBoxFlat has one border
	# color, so its side borders go to 0.
	var ts := _make_box(COL_BG, COL_ACCENT, SP_L, 5, 0)
	ts.border_width_top = 2
	var tu := _make_box(Color(0.02, 0.02, 0.02), COL_BORDER_DIM, SP_L, 5)
	t.set_stylebox("tab_selected",   "TabContainer", ts)
	t.set_stylebox("tab_unselected", "TabContainer", tu)
	t.set_stylebox("tab_hovered",    "TabContainer", tu)
	t.set_stylebox("panel",          "TabContainer", _make_box(COL_BG, NO_BORDER, 10, 8))
	t.set_color("font_selected_color",   "TabContainer", COL_TEXT_HI)
	t.set_color("font_unselected_color", "TabContainer", COL_TEXT_DIM)
	t.set_color("font_hovered_color",    "TabContainer", COL_TEXT)

	t.set_stylebox("separator", "HSeparator", _make_box(COL_BORDER_DIM))
	t.set_constant("separation", "HSeparator", 1)

	var le := _make_box(COL_SURFACE, COL_BORDER, 6, 3)
	var le_focus: StyleBoxFlat = le.duplicate()
	le_focus.border_color = COL_ACCENT
	t.set_stylebox("normal", "LineEdit", le)
	t.set_stylebox("focus",  "LineEdit", le_focus)
	t.set_color("font_color", "LineEdit", COL_TEXT)

	# The stock SpinBox arrows are light-theme gray.
	t.set_icon("updown", "SpinBox", _segment_icon(9, 14, COL_TEXT_DIM, [[4, 2, 4, 2], [3, 3, 5, 3],
			[2, 4, 6, 4], [4, 11, 4, 11], [3, 10, 5, 10], [2, 9, 6, 9]]))

	t.set_stylebox("panel", "ScrollContainer", StyleBoxEmpty.new())
	_theme_scrollbar(t, "VScrollBar", true)
	_theme_scrollbar(t, "HScrollBar", false)

	t.set_stylebox("background", "ProgressBar", _make_box(COL_SURFACE, COL_BORDER))
	t.set_stylebox("fill",       "ProgressBar", _make_box(COL_ACCENT_DIM, COL_ACCENT))
	t.set_font_size("font_size", "ProgressBar", FS_META)
	t.set_color("font_color",    "ProgressBar", COL_TEXT)

	# Without these, tooltips render in the default light theme.
	t.set_stylebox("panel", "TooltipPanel", _make_box(COL_SURFACE_2, COL_BORDER, SP_M, SP_S))
	t.set_color("font_color", "TooltipLabel", COL_TEXT)
	t.set_font_size("font_size", "TooltipLabel", FS_META)

	var dlg_panel := _make_dialog_panel_stylebox()
	t.set_stylebox("embedded_border",           "Window", dlg_panel)
	t.set_stylebox("embedded_unfocused_border", "Window", dlg_panel)
	t.set_color("title_color", "Window", COL_TEXT_HI)
	return t

# Width comes from the stylebox minimum sizes (track 2+2, grabber 6+6 = 16px);
# the along-axis margins keep the grabber a usable length.
func _theme_scrollbar(t: Theme, type: String, vertical: bool) -> void:
	var track := _make_box(COL_BG, COL_BORDER_DIM, 2 if vertical else 0, 0 if vertical else 2, 0)
	if vertical:
		track.border_width_left = 1
	else:
		track.border_width_top = 1
	var grab := _make_box(COL_BORDER, NO_BORDER, 6 if vertical else 12, 12 if vertical else 6)
	var grab_hi: StyleBoxFlat = grab.duplicate()
	grab_hi.bg_color = COL_TEXT_DIM
	t.set_stylebox("scroll",            type, track)
	t.set_stylebox("grabber",           type, grab)
	t.set_stylebox("grabber_highlight", type, grab_hi)
	t.set_stylebox("grabber_pressed",   type, grab_hi)

# A fill, a uniform border of border_w pixels and content margins (mx sides,
# my top and bottom). A margin of 0 stays unset: StyleBoxFlat then uses the border width.
func _make_box(bg: Color, border: Color = NO_BORDER, mx: int = 0, my: int = 0,
		border_w: int = 1) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = bg
	if border.a > 0.0:
		s.border_color = border
		s.border_width_top = border_w
		s.border_width_bottom = border_w
		s.border_width_left = border_w
		s.border_width_right = border_w
	if mx != 0:
		s.content_margin_left = mx
		s.content_margin_right = mx
	if my != 0:
		s.content_margin_top = my
		s.content_margin_bottom = my
	return s

func _make_button_stylebox(bg: Color, border: Color) -> StyleBoxFlat:
	return _make_box(bg, border, 10, 4)

# One segment of a view switch: joined to its neighbour, the pressed one filled
# with the accent and marked with a check, so the active view reads without color.
func style_segment(b: Button, first: bool) -> void:
	var off := _make_box(COL_SURFACE, COL_BORDER, 10, 4)
	var on := _make_box(COL_ACCENT_DIM, COL_ACCENT, 10, 4)
	var hover := _make_box(COL_SURFACE_2, COL_TEXT_HI, 10, 4)
	for s: StyleBoxFlat in [off, on, hover]:
		s.corner_radius_top_left = 4 if first else 0
		s.corner_radius_bottom_left = 4 if first else 0
		s.corner_radius_top_right = 0 if first else 4
		s.corner_radius_bottom_right = 0 if first else 4
		if not first:
			s.border_width_left = 0
	b.add_theme_stylebox_override("normal", off)
	b.add_theme_stylebox_override("hover", hover)
	b.add_theme_stylebox_override("pressed", on)
	b.add_theme_stylebox_override("hover_pressed", on)
	b.add_theme_color_override("font_color", COL_TEXT_DIM)
	b.add_theme_color_override("font_pressed_color", COL_TEXT_HI)
	b.add_theme_color_override("font_hover_pressed_color", COL_TEXT_HI)
	b.custom_minimum_size.x = 104

func _make_check_icon(color: Color) -> ImageTexture:
	var img := Image.create(12, 12, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))
	for x in range(2, 11):
		var y := x + 3 if x <= 5 else 13 - x
		img.set_pixel(x, y, color)
		img.set_pixel(x, y + 1, color)
	return ImageTexture.create_from_image(img)

func _make_dialog_panel_stylebox() -> StyleBoxFlat:
	return _make_box(COL_SURFACE, COL_BORDER, SP_XL, SP_L)

# Not _make_box: the focus ring keeps the default bg_color and draws no center.
func _make_focus_stylebox() -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.draw_center = false
	s.border_color = COL_ACCENT
	s.border_width_top = 1
	s.border_width_bottom = 1
	s.border_width_left = 1
	s.border_width_right = 1
	return s

func style_primary_button(b: Button) -> void:
	_style_accent_button(b, COL_ACCENT)

func style_danger_button(b: Button) -> void:
	_style_accent_button(b, COL_ERR)

# Modulate, because a font-color override on a dialog OK button does not take effect.
func style_dialog_primary_button(b: Button) -> void:
	b.modulate = COL_ACCENT

func style_dialog_danger_button(b: Button) -> void:
	b.modulate = COL_ERR

func _style_accent_button(b: Button, accent: Color) -> void:
	b.add_theme_color_override("font_color", accent)
	b.add_theme_color_override("font_hover_color", accent)
	b.add_theme_color_override("font_pressed_color", accent)
	b.add_theme_color_override("font_focus_color", accent)
	b.add_theme_font_size_override("font_size", FS_BODY)
	b.add_theme_stylebox_override("hover", _make_button_stylebox(COL_SURFACE_2, accent))

func _make_badge_stylebox(border: Color = COL_ACCENT, bg: Color = COL_ACCENT_DIM) -> StyleBoxFlat:
	return _make_box(bg, border, SP_S, SP_XS)

# A COL_SURFACE strip with an accent rule under it and the title. Returns the
# row callers append to; the plate is the row's parent.
func _make_header_plate(root: Control, title: String, font_size: int) -> HBoxContainer:
	var header := PanelContainer.new()
	var header_s := _make_box(COL_SURFACE, COL_ACCENT_DIM, SP_L, SP_M, 0)
	header_s.border_width_bottom = 1
	header.add_theme_stylebox_override("panel", header_s)
	root.add_child(header)
	var header_row := HBoxContainer.new()
	header_row.add_theme_constant_override("separation", SP_M)
	header.add_child(header_row)
	header_row.add_child(_make_label(title, COL_TEXT_HI, font_size))
	return header_row

# A COL_SURFACE strip with a 3px colored left edge. Returns {"panel", "row"}.
func _make_banner(text: String, edge_color: Color) -> Dictionary:
	var panel := PanelContainer.new()
	var s := _make_box(COL_SURFACE, edge_color, SP_L, SP_M, 0)
	s.border_width_left = 3
	panel.add_theme_stylebox_override("panel", s)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", SP_L)
	panel.add_child(row)
	var lbl := _make_label(text, null, FS_BODY)
	lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	# Without autowrap the minimum width is the whole sentence, which widens
	# every ancestor past the window edge.
	lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	row.add_child(lbl)
	return {"panel": panel, "row": row}

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
		for p in [Vector2i(3, 7), Vector2i(4, 8), Vector2i(5, 9), Vector2i(6, 8),
				Vector2i(7, 7), Vector2i(8, 6), Vector2i(9, 5), Vector2i(10, 4)]:
			img.set_pixel(p.x, p.y, mark_color)
			img.set_pixel(p.x, p.y + 1, mark_color)
	return ImageTexture.create_from_image(img)

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

# Two 3px diagonals, drawn so the source stays ASCII.
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
