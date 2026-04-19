## ----- ui.gd -----
## The launcher window shown before the game starts: mods tab (list +
## checkboxes + priority), updates tab (ModWorkshop version checking +
## downloads), theme, and the reset-to-vanilla action. Closing the window
## (or clicking Launch Game) hands control back to _run_pass_1.

func _load_developer_mode_setting() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(UI_CONFIG_PATH) != OK:
		return
	_developer_mode = bool(cfg.get_value("settings", "developer_mode", false))
	if _developer_mode:
		_log_info("Developer mode: ON")

func _load_ui_config() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(UI_CONFIG_PATH) != OK:
		return
	for entry in _ui_mod_entries:
		var fn: String = entry["file_name"]
		entry["enabled"] = bool(cfg.get_value("enabled", fn, true))
		if entry["ext"] == "zip":
			entry["enabled"] = false
		if cfg.has_section_key("priority", fn):
			entry["priority"] = int(str(cfg.get_value("priority", fn)))

func _save_ui_config() -> void:
	var cfg := ConfigFile.new()
	# Load existing to preserve any custom [settings] keys (e.g. test flags).
	cfg.load(UI_CONFIG_PATH)
	# Clear mod-specific sections so removed mods don't linger.
	if cfg.has_section("enabled"):
		cfg.erase_section("enabled")
	if cfg.has_section("priority"):
		cfg.erase_section("priority")
	for entry in _ui_mod_entries:
		var fn: String = entry["file_name"]
		cfg.set_value("enabled", fn, entry["enabled"])
		cfg.set_value("priority", fn, entry["priority"])
	cfg.set_value("settings", "developer_mode", _developer_mode)
	cfg.save(UI_CONFIG_PATH)

# UI Reset-to-Vanilla action: wipe all persistent mod state and restart. Used
# by the "Reset to Vanilla" button. Uncheck all mods in memory so mod_config.cfg
# loses the enabled flags, then call the shared static cleanup helper. Restart
# the game so the clean slate actually takes effect.

func _reset_to_vanilla_and_restart(win: Window) -> void:
	_log_info("[Reset] User triggered Reset to Vanilla")
	for entry in _ui_mod_entries:
		entry["enabled"] = false
	_save_ui_config()
	var log_lines := PackedStringArray()
	_static_force_vanilla_state("UI reset button", log_lines)
	for line in log_lines:
		_log_info(line)
	if is_instance_valid(win):
		win.queue_free()
	# Strip --modloader-restart so the relaunch is a clean Pass 1, not a Pass 2
	# that would expect pass state we just deleted.
	var restart_args: Array = []
	for a in OS.get_cmdline_args():
		if a != "--modloader-restart":
			restart_args.append(a)
	OS.set_restart_on_exit(true, restart_args)
	get_tree().quit()

# UI

func show_mod_ui() -> void:
	var win := Window.new()
	win.title = "Road to Vostok -- Mod Loader"
	win.size = Vector2i(960, 640)
	win.min_size = Vector2i(640, 420)
	win.wrap_controls = false
	win.always_on_top = true
	win.transparent = true
	win.transparent_bg = true
	get_tree().root.add_child(win)
	win.popup_centered()

	# Kill the default Godot gray on the Window itself (embedded_border is the
	# stylebox that paints the window's own background area).
	var win_style := StyleBoxFlat.new()
	win_style.bg_color = Color(0.0, 0.0, 0.0)
	win.add_theme_stylebox_override("panel",                    win_style)
	win.add_theme_stylebox_override("embedded_border",          win_style.duplicate())
	win.add_theme_stylebox_override("embedded_unfocused_border", win_style.duplicate())

	# Solid dark background so Godot's default gray theme doesn't show through.
	var bg := Panel.new()
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var bg_s := StyleBoxFlat.new()
	bg_s.bg_color = Color(0.0, 0.0, 0.0, 0.6)
	bg_s.border_color = Color(1.0, 1.0, 1.0)
	bg_s.border_width_top    = 1
	bg_s.border_width_bottom = 1
	bg_s.border_width_left   = 1
	bg_s.border_width_right  = 1
	bg.add_theme_stylebox_override("panel", bg_s)
	win.add_child(bg)

	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 10)
	margin.add_theme_constant_override("margin_right", 10)
	margin.add_theme_constant_override("margin_top", 8)
	margin.add_theme_constant_override("margin_bottom", 10)
	margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	margin.theme = make_dark_theme()
	win.add_child(margin)

	var root := VBoxContainer.new()
	root.add_theme_constant_override("separation", 6)
	margin.add_child(root)

	var tabs := TabContainer.new()
	tabs.size_flags_vertical = Control.SIZE_EXPAND_FILL
	root.add_child(tabs)

	root.add_child(HSeparator.new())

	# Bottom bar: instructions + launch button
	var bottom := HBoxContainer.new()
	bottom.add_theme_constant_override("separation", 10)
	root.add_child(bottom)

	var hint := Label.new()
	hint.text = "Higher number loads later and wins when mods share files.\n" \
			+ "Developer Mode: verbose logging, conflict report, and loose folder loading."
	hint.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	hint.add_theme_font_size_override("font_size", 11)
	hint.modulate = Color(0.45, 0.45, 0.45)
	bottom.add_child(hint)

	var reset_btn := Button.new()
	reset_btn.text = "  Reset to Vanilla  "
	reset_btn.custom_minimum_size = Vector2(150, 36)
	reset_btn.tooltip_text = "Wipe all mod state (hook pack, override.cfg, cached archives) and restart the game clean. Use this when mods are stuck or you want a guaranteed vanilla launch."
	var launch_btn := Button.new()
	launch_btn.text = "  Launch Game  "
	launch_btn.custom_minimum_size = Vector2(130, 36)
	var ls_n := StyleBoxFlat.new()
	ls_n.bg_color = Color(0.05, 0.05, 0.05)
	ls_n.border_color = Color(0.28, 0.28, 0.28)
	ls_n.border_width_top = 1; ls_n.border_width_bottom = 1
	ls_n.border_width_left = 1; ls_n.border_width_right = 1
	ls_n.content_margin_left = 10; ls_n.content_margin_right = 10
	launch_btn.add_theme_stylebox_override("normal", ls_n)
	reset_btn.add_theme_stylebox_override("normal", ls_n.duplicate())
	var ls_h := ls_n.duplicate()
	ls_h.bg_color = Color(0.10, 0.10, 0.10)
	ls_h.border_color = Color(0.55, 0.55, 0.55)
	launch_btn.add_theme_stylebox_override("hover", ls_h)
	reset_btn.add_theme_stylebox_override("hover", ls_h.duplicate())
	var ls_p := ls_n.duplicate()
	ls_p.bg_color = Color(0.03, 0.03, 0.03)
	launch_btn.add_theme_stylebox_override("pressed", ls_p)
	reset_btn.add_theme_stylebox_override("pressed", ls_p.duplicate())
	launch_btn.add_theme_color_override("font_color", Color(0.88, 0.88, 0.88))
	launch_btn.add_theme_color_override("font_hover_color", Color(1.0, 1.0, 1.0))
	reset_btn.add_theme_color_override("font_color", Color(0.70, 0.55, 0.55))
	reset_btn.add_theme_color_override("font_hover_color", Color(1.0, 0.70, 0.70))
	bottom.add_child(reset_btn)
	bottom.add_child(launch_btn)

	reset_btn.pressed.connect(func(): _reset_to_vanilla_and_restart(win))

	# Closing the window with X should behave the same as clicking Launch.
	win.close_requested.connect(func(): launch_btn.pressed.emit())

	var mods_tab := build_mods_tab(tabs)
	mods_tab.name = "Mods"
	tabs.add_child(mods_tab)

	var updates_tab := build_updates_tab()
	updates_tab.name = "Updates"
	tabs.add_child(updates_tab)

	await launch_btn.pressed
	win.queue_free()

func make_dark_theme() -> Theme:
	var t := Theme.new()

	const C_PANEL := Color(0.04, 0.04, 0.04)
	const C_BTN   := Color(0.07, 0.07, 0.07)
	const C_BORD  := Color(0.18, 0.18, 0.18)
	const C_HI    := Color(0.90, 0.90, 0.90)
	const C_TEXT  := Color(0.84, 0.84, 0.84)
	const C_DIM   := Color(0.42, 0.42, 0.42)

	# -- Button ----------------------------------------------------------------
	var bn := StyleBoxFlat.new()
	bn.bg_color = C_BTN
	bn.border_color = C_BORD
	bn.border_width_top = 1; bn.border_width_bottom = 1
	bn.border_width_left = 1; bn.border_width_right = 1
	bn.content_margin_left = 8; bn.content_margin_right = 8
	bn.content_margin_top = 3; bn.content_margin_bottom = 3
	var bh := bn.duplicate()
	bh.bg_color = Color(0.10, 0.10, 0.10); bh.border_color = C_HI
	var bp := bn.duplicate(); bp.bg_color = Color(0.03, 0.03, 0.03)
	var bd := bn.duplicate()
	bd.bg_color = Color(0.04, 0.04, 0.04); bd.border_color = Color(0.12, 0.12, 0.12)
	t.set_stylebox("normal",   "Button", bn)
	t.set_stylebox("hover",    "Button", bh)
	t.set_stylebox("pressed",  "Button", bp)
	t.set_stylebox("disabled", "Button", bd)
	t.set_stylebox("focus",    "Button", StyleBoxEmpty.new())
	t.set_color("font_color",          "Button", C_TEXT)
	t.set_color("font_hover_color",    "Button", Color(1.0, 1.0, 1.0))
	t.set_color("font_pressed_color",  "Button", C_TEXT)
	t.set_color("font_disabled_color", "Button", C_DIM)

	# -- CheckBox (font only -- box glyph needs texture to restyle) -------------
	t.set_color("font_color",       "CheckBox", C_TEXT)
	t.set_color("font_hover_color", "CheckBox", Color(1.0, 1.0, 1.0))

	# -- Label -----------------------------------------------------------------
	t.set_color("font_color", "Label", C_TEXT)

	# -- Panel / PanelContainer ------------------------------------------------
	var ps := StyleBoxFlat.new(); ps.bg_color = C_PANEL
	t.set_stylebox("panel", "Panel",          ps)
	t.set_stylebox("panel", "PanelContainer", ps.duplicate())

	# -- TabContainer ----------------------------------------------------------
	var ts := StyleBoxFlat.new()   # selected tab
	ts.bg_color = C_PANEL
	ts.border_color = C_BORD
	ts.border_width_top = 1; ts.border_width_left = 1; ts.border_width_right = 1
	ts.border_width_bottom = 0
	ts.content_margin_left = 12; ts.content_margin_right = 12
	ts.content_margin_top = 5;   ts.content_margin_bottom = 5
	var tu := ts.duplicate()      # unselected tab
	tu.bg_color = Color(0.02, 0.02, 0.02)
	tu.border_color = Color(0.12, 0.12, 0.12)
	tu.border_width_bottom = 1
	var tc_panel := StyleBoxFlat.new(); tc_panel.bg_color = C_PANEL
	tc_panel.content_margin_left   = 10
	tc_panel.content_margin_right  = 10
	tc_panel.content_margin_top    = 8
	tc_panel.content_margin_bottom = 8
	t.set_stylebox("tab_selected",   "TabContainer", ts)
	t.set_stylebox("tab_unselected", "TabContainer", tu)
	t.set_stylebox("tab_hovered",    "TabContainer", tu.duplicate())
	t.set_stylebox("panel",          "TabContainer", tc_panel)
	t.set_color("font_selected_color",   "TabContainer", C_HI)
	t.set_color("font_unselected_color", "TabContainer", C_DIM)
	t.set_color("font_hovered_color",    "TabContainer", C_TEXT)

	# -- HSeparator ------------------------------------------------------------
	var sep := StyleBoxFlat.new(); sep.bg_color = Color(0.14, 0.14, 0.14)
	t.set_stylebox("separator", "HSeparator", sep)
	t.set_constant("separation", "HSeparator", 1)

	# -- LineEdit (SpinBox uses this internally) --------------------------------
	var le := StyleBoxFlat.new()
	le.bg_color = Color(0.04, 0.04, 0.04)
	le.border_color = C_BORD
	le.border_width_top = 1; le.border_width_bottom = 1
	le.border_width_left = 1; le.border_width_right = 1
	le.content_margin_left = 6; le.content_margin_right = 6
	le.content_margin_top = 3; le.content_margin_bottom = 3
	t.set_stylebox("normal", "LineEdit", le)
	t.set_stylebox("focus",  "LineEdit", le.duplicate())
	t.set_color("font_color", "LineEdit", C_TEXT)

	# -- ScrollContainer (transparent, scrollbars inherit) ---------------------
	t.set_stylebox("panel", "ScrollContainer", StyleBoxEmpty.new())

	return t

func build_mods_tab(tabs: TabContainer) -> Control:
	var outer := VBoxContainer.new()
	outer.size_flags_vertical = Control.SIZE_EXPAND_FILL

	var toolbar := HBoxContainer.new()
	toolbar.add_theme_constant_override("separation", 8)
	outer.add_child(toolbar)

	var open_btn := Button.new()
	open_btn.text = "Open Mods Folder"
	toolbar.add_child(open_btn)
	open_btn.pressed.connect(func():
		OS.shell_open(ProjectSettings.globalize_path(_mods_dir))
	)

	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	toolbar.add_child(spacer)

	var dev_check := CheckBox.new()
	dev_check.text = "Developer Mode"
	dev_check.tooltip_text = "Enables verbose logging, conflict report, and loose folder loading"
	dev_check.button_pressed = _developer_mode
	dev_check.add_theme_font_size_override("font_size", 11)
	dev_check.modulate = Color(0.45, 0.45, 0.45)
	toolbar.add_child(dev_check)

	dev_check.toggled.connect(func(on: bool):
		_developer_mode = on
		_ui_mod_entries = collect_mod_metadata()
		_load_ui_config()
		var old := tabs.get_node("Mods")
		var idx := old.get_index()
		tabs.remove_child(old)
		old.queue_free()
		var new_tab := build_mods_tab(tabs)
		new_tab.name = "Mods"
		tabs.add_child(new_tab)
		tabs.move_child(new_tab, idx)
		tabs.current_tab = idx
	)

	outer.add_child(HSeparator.new())

	var split := HSplitContainer.new()
	split.split_offset = 560
	split.size_flags_vertical = Control.SIZE_EXPAND_FILL
	outer.add_child(split)

	# -- Left: mod list --------------------------------------------------------

	var left_scroll := ScrollContainer.new()
	left_scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	left_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	split.add_child(left_scroll)

	var list := VBoxContainer.new()
	list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	left_scroll.add_child(list)

	# -- Right: live load order preview ----------------------------------------

	var right := VBoxContainer.new()
	right.custom_minimum_size.x = 220
	split.add_child(right)

	var order_header := Label.new()
	order_header.text = "Load Order"
	order_header.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	right.add_child(order_header)
	right.add_child(HSeparator.new())

	# Dark panel behind the load order list for visual separation.
	var order_panel := PanelContainer.new()
	order_panel.size_flags_vertical = Control.SIZE_EXPAND_FILL
	var panel_style := StyleBoxFlat.new()
	panel_style.bg_color = Color(0.09, 0.09, 0.09)
	panel_style.content_margin_left = 8
	panel_style.content_margin_right = 8
	panel_style.content_margin_top = 6
	panel_style.content_margin_bottom = 6
	order_panel.add_theme_stylebox_override("panel", panel_style)
	right.add_child(order_panel)

	var order_scroll := ScrollContainer.new()
	order_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	order_panel.add_child(order_scroll)

	var order_list := VBoxContainer.new()
	order_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	order_scroll.add_child(order_list)

	# Rebuilds the right-side order list from current entry state.
	var refresh_order := func():
		for child in order_list.get_children():
			child.queue_free()
		var sorted := _ui_mod_entries.filter(func(e): return e["enabled"])
		sorted.sort_custom(_compare_load_order)
		if sorted.is_empty():
			var lbl := Label.new()
			lbl.text = "(none enabled)"
			lbl.modulate = Color(0.5, 0.5, 0.5)
			order_list.add_child(lbl)
			return
		for i in sorted.size():
			var e: Dictionary = sorted[i]
			var lbl := Label.new()
			lbl.text = str(i + 1) + ".  " + e["mod_name"]
			lbl.add_theme_font_size_override("font_size", 12)
			lbl.modulate = Color(0.80, 0.80, 0.80)
			lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
			order_list.add_child(lbl)

	# -- Column headers --------------------------------------------------------

	var header_row := HBoxContainer.new()
	list.add_child(header_row)

	var h_on := Label.new()
	h_on.text = "On"
	h_on.custom_minimum_size.x = 30
	header_row.add_child(h_on)

	var h_name := Label.new()
	h_name.text = "Mod"
	h_name.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header_row.add_child(h_name)

	var h_prio := Label.new()
	h_prio.text = "Load Order"
	h_prio.custom_minimum_size.x = 100
	h_prio.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	header_row.add_child(h_prio)

	list.add_child(HSeparator.new())

	# -- One row per mod -------------------------------------------------------

	if _ui_mod_entries.is_empty():
		var empty := Label.new()
		empty.text = "No mods found.\n\nPlace .vmz or .pck files in:\n" \
				+ ProjectSettings.globalize_path(_mods_dir)
		empty.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		empty.modulate = Color(0.5, 0.5, 0.5)
		empty.add_theme_font_size_override("font_size", 12)
		list.add_child(empty)

	for entry in _ui_mod_entries:
		var row := HBoxContainer.new()
		list.add_child(row)

		var check := CheckBox.new()
		check.button_pressed = entry["enabled"]
		check.custom_minimum_size.x = 30
		row.add_child(check)

		var name_col := VBoxContainer.new()
		name_col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(name_col)

		var name_lbl := Label.new()
		name_lbl.text = entry["mod_name"]
		name_lbl.clip_text = true
		name_lbl.modulate = Color(0.58, 0.82, 0.38) if entry["enabled"] else Color(0.5, 0.5, 0.5)
		name_col.add_child(name_lbl)

		if entry["ext"] == "folder":
			var dev_lbl := Label.new()
			dev_lbl.text = "[dev folder]"
			dev_lbl.modulate = Color(0.9, 0.3, 0.3)
			dev_lbl.add_theme_font_size_override("font_size", 11)
			name_col.add_child(dev_lbl)
		for warn_text: String in entry.get("warnings", []):
			var warn := Label.new()
			warn.text = warn_text
			warn.modulate = Color(1.0, 0.6, 0.2)
			warn.add_theme_font_size_override("font_size", 11)
			name_col.add_child(warn)

		if entry["ext"] == "zip":
			check.disabled = true

		var spin := SpinBox.new()
		spin.min_value = PRIORITY_MIN
		spin.max_value = PRIORITY_MAX
		spin.value = entry["priority"]
		spin.custom_minimum_size.x = 100
		if entry["ext"] == "zip":
			spin.editable = false
		row.add_child(spin)

		list.add_child(HSeparator.new())

		# Capture entry by reference (Dictionaries are reference types in GDScript)
		var e := entry
		var nlbl := name_lbl
		check.toggled.connect(func(on: bool):
			e["enabled"] = on
			nlbl.modulate = Color(0.58, 0.82, 0.38) if on else Color(0.5, 0.5, 0.5)
			refresh_order.call()
		)
		spin.value_changed.connect(func(val: float):
			e["priority"] = int(val)
			refresh_order.call()
		)

	refresh_order.call()
	return outer

func build_updates_tab() -> Control:
	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 8)
	margin.add_theme_constant_override("margin_right", 8)
	margin.add_theme_constant_override("margin_top", 6)
	margin.add_theme_constant_override("margin_bottom", 6)

	var container := VBoxContainer.new()
	container.add_theme_constant_override("separation", 6)
	margin.add_child(container)

	var toolbar := HBoxContainer.new()
	toolbar.add_theme_constant_override("separation", 8)
	container.add_child(toolbar)

	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	toolbar.add_child(spacer)

	var check_btn := Button.new()
	check_btn.text = "Check for Updates"
	toolbar.add_child(check_btn)

	container.add_child(HSeparator.new())

	# Column headers
	var header_row := HBoxContainer.new()
	container.add_child(header_row)

	var h_mod := Label.new()
	h_mod.text = "Mod"
	h_mod.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header_row.add_child(h_mod)

	var h_ver := Label.new()
	h_ver.text = "Version"
	h_ver.custom_minimum_size.x = 90
	header_row.add_child(h_ver)

	var h_status := Label.new()
	h_status.text = "Status"
	h_status.custom_minimum_size.x = 160
	header_row.add_child(h_status)

	var h_action := Label.new()
	h_action.text = "Action"
	h_action.custom_minimum_size.x = 90
	header_row.add_child(h_action)

	container.add_child(HSeparator.new())

	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	container.add_child(scroll)

	var list := VBoxContainer.new()
	list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(list)

	# { label, version, mw_id, dl_btn, full_path, mod_name }
	var status_info: Dictionary = {}

	for entry in _ui_mod_entries:
		var cfg: ConfigFile = entry["cfg"]
		if cfg == null:
			continue
		var version := str(cfg.get_value("mod", "version", ""))
		var mw_id := 0
		if cfg.has_section_key("updates", "modworkshop"):
			mw_id = int(str(cfg.get_value("updates", "modworkshop", "")))

		var row := HBoxContainer.new()
		list.add_child(row)

		# Name column: mod name + last-modified date sub-label.
		var name_col := VBoxContainer.new()
		name_col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(name_col)

		var name_lbl := Label.new()
		name_lbl.text = entry["mod_name"]
		name_lbl.clip_text = true
		name_col.add_child(name_lbl)

		var mtime := FileAccess.get_modified_time(entry["full_path"])
		if mtime > 0:
			var dt := Time.get_datetime_dict_from_unix_time(mtime)
			var date_str := "%04d-%02d-%02d" % [dt["year"], dt["month"], dt["day"]]
			var mod_lbl := Label.new()
			mod_lbl.text = "modified " + date_str
			mod_lbl.add_theme_font_size_override("font_size", 11)
			mod_lbl.modulate = Color(0.5, 0.5, 0.5)
			name_col.add_child(mod_lbl)

		var ver_lbl := Label.new()
		ver_lbl.text = "v" + version if version != "" else "--"
		ver_lbl.custom_minimum_size.x = 90
		row.add_child(ver_lbl)

		var status_lbl := Label.new()
		status_lbl.custom_minimum_size.x = 160
		status_lbl.text = "no update info" if mw_id == 0 or version == "" else "--"
		row.add_child(status_lbl)

		# Always add dl_btn to preserve column width. Use modulate.a to
		# hide it visually without collapsing its layout slot.
		var dl_btn := Button.new()
		dl_btn.text = "Download"
		dl_btn.custom_minimum_size.x = 90
		dl_btn.modulate.a = 0.0
		dl_btn.disabled = true
		dl_btn.mouse_filter = Control.MOUSE_FILTER_IGNORE
		row.add_child(dl_btn)

		list.add_child(HSeparator.new())

		if mw_id > 0 and version != "":
			status_info[entry["file_name"]] = {
				"label": status_lbl, "ver_lbl": ver_lbl, "version": version, "mw_id": mw_id,
				"dl_btn": dl_btn, "full_path": entry["full_path"],
				"mod_name": entry["mod_name"],
			}

	if list.get_child_count() == 0:
		var lbl := Label.new()
		lbl.text = "No mods with update information found.\nAdd [updates] modworkshop=<id> and version=<x.y.z> to mod.txt to enable this."
		lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		list.add_child(lbl)

	# -- Activity log ----------------------------------------------------------

	container.add_child(HSeparator.new())

	var log_hdr := Label.new()
	log_hdr.text = "Activity"
	log_hdr.add_theme_font_size_override("font_size", 11)
	log_hdr.modulate = Color(0.65, 0.65, 0.65)
	container.add_child(log_hdr)

	var log_bg := PanelContainer.new()
	log_bg.custom_minimum_size.y = 72
	var log_style := StyleBoxFlat.new()
	log_style.bg_color = Color(0.09, 0.09, 0.09)
	log_style.content_margin_left = 6
	log_style.content_margin_right = 6
	log_style.content_margin_top = 4
	log_style.content_margin_bottom = 4
	log_bg.add_theme_stylebox_override("panel", log_style)
	container.add_child(log_bg)

	var log_scroll := ScrollContainer.new()
	log_bg.add_child(log_scroll)

	var log_list := VBoxContainer.new()
	log_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	log_scroll.add_child(log_list)

	var add_log := func(msg: String):
		var t := Time.get_time_string_from_system()
		var lbl := Label.new()
		lbl.text = "[" + t + "] " + msg
		lbl.add_theme_font_size_override("font_size", 11)
		lbl.modulate = Color(0.8, 0.8, 0.8)
		lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		log_list.add_child(lbl)
		log_scroll.scroll_vertical = 999999

	check_btn.pressed.connect(func():
		check_btn.disabled = true
		check_btn.text = "Checking..."
		for fn in status_info:
			var info: Dictionary = status_info[fn]
			(info["label"] as Label).text = "checking..."
			(info["label"] as Label).modulate = Color(1.0, 1.0, 1.0)
			var btn: Button = info["dl_btn"]
			btn.modulate.a = 0.0
			btn.disabled = true
			btn.mouse_filter = Control.MOUSE_FILTER_IGNORE
			btn.text = "Download"
		await check_updates_for_ui(status_info, add_log, check_btn)
		check_btn.disabled = false
		check_btn.text = "Check for Updates"
	)

	return margin

func check_updates_for_ui(status_info: Dictionary, add_log: Callable, check_btn: Button) -> void:
	var ids: Array[int] = []
	for fn in status_info:
		ids.append(status_info[fn]["mw_id"])
	if ids.is_empty():
		return

	var latest := await fetch_latest_modworkshop_versions(ids)

	if not is_instance_valid(check_btn):
		return

	for fn: String in status_info:
		var info: Dictionary = status_info[fn]
		var lbl: Label = info["label"]
		var dl_btn: Button = info["dl_btn"]
		var latest_v = latest.get(str(info["mw_id"]), null)
		if latest_v == null:
			lbl.text = "no data"
			lbl.modulate = Color(1.0, 1.0, 1.0)
			continue

		var cmp := compare_versions(info["version"], str(latest_v))
		if cmp >= 0:
			# Local is same version or newer than what's on the server.
			lbl.text = "up to date"
			lbl.modulate = Color(0.6, 0.6, 0.6)
		else:
			# Server has a newer version.
			lbl.text = "update: v" + str(latest_v)
			lbl.modulate = Color(0.90, 0.90, 0.90)
			dl_btn.modulate.a = 1.0
			dl_btn.disabled = false
			dl_btn.mouse_filter = Control.MOUSE_FILTER_STOP
			var full_path: String = info["full_path"]
			var mw_id: int = info["mw_id"]
			var mod_name: String = info["mod_name"]
			var new_ver: String = str(latest_v)
			# Disconnect previous connections so repeated checks don't stack callbacks.
			for c in dl_btn.pressed.get_connections():
				dl_btn.pressed.disconnect(c["callable"])
			dl_btn.pressed.connect(func():
				dl_btn.disabled = true
				dl_btn.text = "Downloading..."
				lbl.text = "downloading..."
				check_btn.disabled = true
				var ok := await download_and_replace_mod(full_path, mw_id)
				if not is_instance_valid(check_btn):
					return
				if not is_instance_valid(dl_btn):
					return
				check_btn.disabled = false
				if ok:
					lbl.text = "updated -- restart to apply"
					lbl.modulate = Color(0.80, 0.80, 0.80)
					dl_btn.modulate.a = 0.0
					dl_btn.disabled = true
					dl_btn.mouse_filter = Control.MOUSE_FILTER_IGNORE
					dl_btn.text = "Download"
					# Update cached version so next Check won't re-flag this mod.
					info["version"] = new_ver
					(info["ver_lbl"] as Label).text = "v" + new_ver
					add_log.call(mod_name + " -- updated to v" + new_ver + ". Restart game to apply.")
				else:
					lbl.text = "download failed"
					lbl.modulate = Color(1.0, 0.4, 0.4)
					dl_btn.disabled = false
					dl_btn.text = "Retry"
					add_log.call(mod_name + " -- download failed.")
			)
