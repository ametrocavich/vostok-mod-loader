extends Node

const MOD_DIR := "mods"
const TMP_DIR := "user://vmz_mount_cache"
const CONFLICT_REPORT_PATH := "user://modloader_conflicts.txt"
const UI_CONFIG_PATH := "user://mod_config.cfg"
const MODWORKSHOP_VERSIONS_URL := "https://api.modworkshop.net/mods/versions"
const MODWORKSHOP_DOWNLOAD_URL_TEMPLATE := "https://api.modworkshop.net/mods/%s/download"

const VANILLA_SCAN_DIRS: Array[String] = ["res://Scripts", "res://Scenes"]
const TRACKED_EXTENSIONS: Array[String] = ["gd", "tscn", "tres", "gdns", "gdnlib", "scn"]
const LIFECYCLE_METHODS: Array[String] = [
	"_ready", "_process", "_physics_process",
	"_input", "_unhandled_input", "_unhandled_key_input",
]

# ─── Tuning constants ────────────────────────────────────────────────────────

const OVERLAP_FILE_THRESHOLD := 5       # shared files to flag "Likely Incompatible"
const OVERLAP_VANILLA_THRESHOLD := 3    # shared vanilla files for critical severity
const MAX_DISPLAYED_FILENAMES := 6      # truncate file lists in conflict cards
const MODWORKSHOP_BATCH_SIZE := 100     # mod IDs per API request
const API_CHECK_TIMEOUT := 15.0         # seconds for version-check requests
const API_DOWNLOAD_TIMEOUT := 30.0      # seconds for mod download requests
const PRIORITY_MIN := -999
const PRIORITY_MAX := 999

# ─── State ────────────────────────────────────────────────────────────────────

var _vanilla_paths: Dictionary = {}
var _database_path: String = ""
var _database_replaced_by: String = ""
var _override_registry: Dictionary = {}
var _mod_script_analysis: Dictionary = {}
var _archive_file_sets: Dictionary = {}
var _bad_zips: Array[Dictionary] = []      # {mod_name, count, example}
var _report_lines: Array[String] = []
var _pending_autoloads: Array[Dictionary] = []
var _loaded_mod_ids: Dictionary = {}
var _registered_autoload_names: Dictionary = {}

# Populated before any mounting. Each entry:
# { file_name, full_path, ext, mod_name, mod_id, priority, enabled, cfg, has_mod_txt }
var _ui_mod_entries: Array[Dictionary] = []

var _developer_mode: bool = false
var _has_loaded: bool = false
var _mods_dir: String = ""

var _re_take_over: RegEx
var _re_extends: RegEx
var _re_extends_classname: RegEx
var _re_class_name: RegEx
var _re_func: RegEx
var _re_preload: RegEx


# ─── Entry point ──────────────────────────────────────────────────────────────

func _ready() -> void:
	if _has_loaded:
		return
	_has_loaded = true
	# Autoloads run while the scene tree is still setting up children.
	# Wait one frame so add_child() and DisplayServer queries work correctly.
	await get_tree().process_frame
	_log_info("Metro Mod Loader — exe: " + OS.get_executable_path()
			+ "  user: " + OS.get_user_data_dir())
	_compile_regex()
	_load_developer_mode_setting()
	_ui_mod_entries = _collect_mod_metadata()
	_load_ui_config()
	await _show_mod_ui()
	_save_ui_config()
	_load_all_mods()
	if _developer_mode:
		_preflight_compile_check()
	for entry in _pending_autoloads:
		_instantiate_autoload(entry["mod_name"], entry["name"], entry["path"])
	if _developer_mode:
		_log_override_timing_warnings()
		_print_conflict_summary()
		_write_conflict_report()
	# Reload so mounted resource overrides and take_over_path() apply to the scene.
	# Needed for ALL mods that replace files, not just those with autoloads.
	if not _archive_file_sets.is_empty() or _pending_autoloads.size() > 0:
		get_tree().reload_current_scene()
		# Wait for the reloaded scene to be ready before auditing override instances.
		# The modloader persists across reloads (it's an autoload), so this works.
		if _developer_mode:
			await get_tree().process_frame
			_audit_override_instances()


func _compile_regex() -> void:
	_re_take_over = RegEx.new()
	_re_take_over.compile('take_over_path\\s*\\(\\s*"(res://[^"]+)"')
	_re_extends = RegEx.new()
	_re_extends.compile('(?m)^extends\\s+"(res://[^"]+)"')
	_re_extends_classname = RegEx.new()
	_re_extends_classname.compile('(?m)^extends\\s+([A-Z]\\w+)\\s*$')
	_re_class_name = RegEx.new()
	_re_class_name.compile('(?m)^class_name\\s+(\\w+)')
	_re_func = RegEx.new()
	_re_func.compile('(?m)^(?:static\\s+)?func\\s+(\\w+)\\s*\\(')
	_re_preload = RegEx.new()
	_re_preload.compile('preload\\s*\\(\\s*"(res://[^"]+)"\\s*\\)')


# ─── Mod metadata collection (no mounting) ────────────────────────────────────

func _collect_mod_metadata() -> Array[Dictionary]:
	var entries: Array[Dictionary] = []
	_mods_dir = OS.get_executable_path().get_base_dir().path_join(MOD_DIR)
	_log_info("Scanning mods dir: " + _mods_dir)
	DirAccess.make_dir_recursive_absolute(_mods_dir)
	var dir := DirAccess.open(_mods_dir)
	if dir == null:
		_log_critical("Failed to open mods dir: " + _mods_dir
				+ " (error " + str(DirAccess.get_open_error()) + ")")
		return entries
	var seen: Dictionary = {}
	var skipped_files: Array[String] = []
	dir.list_dir_begin()
	while true:
		var entry_name := dir.get_next()
		if entry_name == "":
			break
		if dir.current_is_dir():
			if _developer_mode and not entry_name.begins_with("."):
				if not seen.has(entry_name):
					seen[entry_name] = true
					entries.append(_build_folder_entry(_mods_dir, entry_name))
			continue
		var ext := entry_name.get_extension().to_lower()
		if ext not in ["vmz", "zip", "pck"]:
			skipped_files.append(entry_name)
			continue
		if seen.has(entry_name):
			continue
		seen[entry_name] = true
		entries.append(_build_archive_entry(_mods_dir, entry_name, ext))
	dir.list_dir_end()
	if skipped_files.size() > 0:
		_log_warning("Skipped " + str(skipped_files.size()) + " non-mod file(s) in mods dir:")
		for sf in skipped_files:
			_log_warning("  " + sf + "  (not .zip/.vmz/.pck)")
	if entries.size() == 0:
		_log_warning("No mods found in: " + _mods_dir)
	else:
		_log_info("Found " + str(entries.size()) + " mod(s):")
		for e in entries:
			var tag := " [folder]" if e["ext"] == "folder" else ""
			_log_info("  " + e["file_name"] + " (" + e["mod_name"] + ")" + tag)
	return entries


func _build_archive_entry(mods_dir: String, file_name: String, ext: String) -> Dictionary:
	var full_path := mods_dir.path_join(file_name)
	var cfg: ConfigFile = _read_mod_config(full_path) if ext != "pck" else null
	return _entry_from_config(cfg, file_name, full_path, ext)


func _build_folder_entry(mods_dir: String, dir_name: String) -> Dictionary:
	var folder_path := mods_dir.path_join(dir_name)
	var cfg: ConfigFile = _read_mod_config_folder(folder_path)
	return _entry_from_config(cfg, dir_name, folder_path, "folder")


func _entry_from_config(cfg: ConfigFile, file_name: String, full_path: String, ext: String) -> Dictionary:
	var mod_name := file_name
	var mod_id   := file_name
	var priority := 0
	if cfg:
		mod_name = str(cfg.get_value("mod", "name", file_name))
		mod_id   = str(cfg.get_value("mod", "id",   file_name))
		if cfg.has_section_key("mod", "priority"):
			priority = int(str(cfg.get_value("mod", "priority")))
	return {
		"file_name": file_name, "full_path": full_path, "ext": ext,
		"mod_name": mod_name, "mod_id": mod_id,
		"priority": priority, "enabled": true,
		"cfg": cfg, "has_mod_txt": cfg != null,
	}


# ─── Config persistence ───────────────────────────────────────────────────────

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
		if cfg.has_section_key("priority", fn):
			entry["priority"] = int(str(cfg.get_value("priority", fn)))


func _save_ui_config() -> void:
	var cfg := ConfigFile.new()
	for entry in _ui_mod_entries:
		var fn: String = entry["file_name"]
		cfg.set_value("enabled", fn, entry["enabled"])
		cfg.set_value("priority", fn, entry["priority"])
	cfg.set_value("settings", "developer_mode", _developer_mode)
	cfg.save(UI_CONFIG_PATH)


# ─── UI ───────────────────────────────────────────────────────────────────────

func _show_mod_ui() -> void:
	var win := Window.new()
	win.title = "Road to Vostok — Mod Loader"
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
	margin.theme = _make_dark_theme()
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
	hint.text = "Higher priority = loads last = wins conflicts.  " \
			+ "Mods: " + ProjectSettings.globalize_path(_mods_dir) + "  (.zip / .vmz / .pck)"
	hint.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	hint.add_theme_font_size_override("font_size", 11)
	hint.modulate = Color(0.45, 0.45, 0.45)
	bottom.add_child(hint)

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
	var ls_h := ls_n.duplicate()
	ls_h.bg_color = Color(0.10, 0.10, 0.10)
	ls_h.border_color = Color(0.55, 0.55, 0.55)
	launch_btn.add_theme_stylebox_override("hover", ls_h)
	var ls_p := ls_n.duplicate()
	ls_p.bg_color = Color(0.03, 0.03, 0.03)
	launch_btn.add_theme_stylebox_override("pressed", ls_p)
	launch_btn.add_theme_color_override("font_color", Color(0.88, 0.88, 0.88))
	launch_btn.add_theme_color_override("font_hover_color", Color(1.0, 1.0, 1.0))
	bottom.add_child(launch_btn)

	# Closing the window with X should behave the same as clicking Launch.
	win.close_requested.connect(func(): launch_btn.pressed.emit())

	var mods_tab := _build_mods_tab()
	mods_tab.name = "Mods"
	tabs.add_child(mods_tab)

	var updates_tab := _build_updates_tab()
	updates_tab.name = "Updates"
	tabs.add_child(updates_tab)

	var compat_tab := _build_compat_tab()
	compat_tab.name = "Compatibility"
	tabs.add_child(compat_tab)
	var compat_idx := compat_tab.get_index()
	tabs.set_tab_hidden(compat_idx, not _developer_mode)

	var rebuild_mods_tab := func():
		_ui_mod_entries = _collect_mod_metadata()
		_load_ui_config()
		var old := tabs.get_node("Mods")
		var idx := old.get_index()
		tabs.remove_child(old)
		old.queue_free()
		var new_tab := _build_mods_tab()
		new_tab.name = "Mods"
		tabs.add_child(new_tab)
		tabs.move_child(new_tab, idx)
		tabs.current_tab = tabs.get_node("Settings").get_index()

	var settings_tab := _build_settings_tab(tabs, compat_idx, rebuild_mods_tab)
	settings_tab.name = "Settings"
	tabs.add_child(settings_tab)

	await launch_btn.pressed
	win.queue_free()


func _make_dark_theme() -> Theme:
	var t := Theme.new()

	const C_PANEL := Color(0.04, 0.04, 0.04)
	const C_BTN   := Color(0.07, 0.07, 0.07)
	const C_BORD  := Color(0.18, 0.18, 0.18)
	const C_HI    := Color(0.90, 0.90, 0.90)
	const C_TEXT  := Color(0.84, 0.84, 0.84)
	const C_DIM   := Color(0.42, 0.42, 0.42)

	# ── Button ────────────────────────────────────────────────────────────────
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

	# ── CheckBox (font only — box glyph needs texture to restyle) ─────────────
	t.set_color("font_color",       "CheckBox", C_TEXT)
	t.set_color("font_hover_color", "CheckBox", Color(1.0, 1.0, 1.0))

	# ── Label ─────────────────────────────────────────────────────────────────
	t.set_color("font_color", "Label", C_TEXT)

	# ── Panel / PanelContainer ────────────────────────────────────────────────
	var ps := StyleBoxFlat.new(); ps.bg_color = C_PANEL
	t.set_stylebox("panel", "Panel",          ps)
	t.set_stylebox("panel", "PanelContainer", ps.duplicate())

	# ── TabContainer ──────────────────────────────────────────────────────────
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

	# ── HSeparator ────────────────────────────────────────────────────────────
	var sep := StyleBoxFlat.new(); sep.bg_color = Color(0.14, 0.14, 0.14)
	t.set_stylebox("separator", "HSeparator", sep)
	t.set_constant("separation", "HSeparator", 1)

	# ── LineEdit (SpinBox uses this internally) ────────────────────────────────
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

	# ── ScrollContainer (transparent, scrollbars inherit) ─────────────────────
	t.set_stylebox("panel", "ScrollContainer", StyleBoxEmpty.new())

	return t


func _build_mods_tab() -> Control:
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

	outer.add_child(HSeparator.new())

	var split := HSplitContainer.new()
	split.split_offset = 560
	split.size_flags_vertical = Control.SIZE_EXPAND_FILL
	outer.add_child(split)

	# ── Left: mod list ────────────────────────────────────────────────────────

	var left_scroll := ScrollContainer.new()
	left_scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	left_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	split.add_child(left_scroll)

	var list := VBoxContainer.new()
	list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	left_scroll.add_child(list)

	# ── Right: live load order preview ────────────────────────────────────────

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
		sorted.sort_custom(func(a, b): return a["priority"] < b["priority"])
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

	# ── Column headers ────────────────────────────────────────────────────────

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
	h_prio.text = "Priority"
	h_prio.custom_minimum_size.x = 100
	h_prio.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	header_row.add_child(h_prio)

	list.add_child(HSeparator.new())

	# ── One row per mod ───────────────────────────────────────────────────────

	if _ui_mod_entries.is_empty():
		var empty := Label.new()
		empty.text = "No mods found.\n\nPlace .zip, .vmz, or .pck files in:\n" \
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
		if not entry["has_mod_txt"]:
			var warn := Label.new()
			warn.text = "no mod.txt — mount only"
			warn.modulate = Color(1.0, 0.6, 0.2)
			warn.add_theme_font_size_override("font_size", 11)
			name_col.add_child(warn)

		var spin := SpinBox.new()
		spin.min_value = PRIORITY_MIN
		spin.max_value = PRIORITY_MAX
		spin.value = entry["priority"]
		spin.custom_minimum_size.x = 100
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


func _build_compat_tab() -> Control:
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

	var info := Label.new()
	info.text = "Dry-scans enabled archives without mounting. Shows override conflicts, broken chains, and crash risks."
	info.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	info.add_theme_font_size_override("font_size", 12)
	info.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	toolbar.add_child(info)

	var scan_btn := Button.new()
	scan_btn.text = "Run Analysis"
	toolbar.add_child(scan_btn)

	container.add_child(HSeparator.new())

	# Split: issue list on the left, detail view on the right.
	# split_offset offsets from center when both sides have SIZE_EXPAND_FILL.
	# 94 = center(~470) + 94 = divider at ~564px → right panel gets ~40% of width.
	var split := HSplitContainer.new()
	split.size_flags_vertical = Control.SIZE_EXPAND_FILL
	split.split_offset = 94
	container.add_child(split)

	# ── Left: clickable issue list ────────────────────────────────────────────

	var list_scroll := ScrollContainer.new()
	list_scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	list_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	split.add_child(list_scroll)

	var issue_list := VBoxContainer.new()
	issue_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	issue_list.add_theme_constant_override("separation", 2)
	list_scroll.add_child(issue_list)

	var placeholder := Label.new()
	placeholder.text = "Click 'Run Analysis' to scan mods."
	placeholder.modulate = Color(0.6, 0.6, 0.6)
	issue_list.add_child(placeholder)

	# ── Right: issue detail panel ─────────────────────────────────────────────

	var detail_bg := PanelContainer.new()
	detail_bg.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var detail_style := StyleBoxFlat.new()
	detail_style.bg_color = Color(0.09, 0.09, 0.09)
	detail_style.content_margin_left = 12
	detail_style.content_margin_right = 12
	detail_style.content_margin_top = 10
	detail_style.content_margin_bottom = 10
	detail_bg.add_theme_stylebox_override("panel", detail_style)
	split.add_child(detail_bg)

	var detail_scroll := ScrollContainer.new()
	detail_bg.add_child(detail_scroll)

	var detail_vbox := VBoxContainer.new()
	detail_vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	detail_vbox.add_theme_constant_override("separation", 8)
	detail_scroll.add_child(detail_vbox)

	var detail_title := Label.new()
	detail_title.text = "Select an issue to see details."
	detail_title.modulate = Color(0.65, 0.65, 0.65)
	detail_title.add_theme_font_size_override("font_size", 14)
	detail_vbox.add_child(detail_title)

	var detail_what_hdr := Label.new()
	detail_what_hdr.text = "What's happening"
	detail_what_hdr.add_theme_font_size_override("font_size", 11)
	detail_what_hdr.modulate = Color(0.75, 0.75, 0.75)
	detail_what_hdr.visible = false
	detail_vbox.add_child(detail_what_hdr)

	var detail_what := Label.new()
	detail_what.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	detail_what.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	detail_what.visible = false
	detail_vbox.add_child(detail_what)

	var detail_fix_hdr := Label.new()
	detail_fix_hdr.text = "How to fix"
	detail_fix_hdr.add_theme_font_size_override("font_size", 11)
	detail_fix_hdr.modulate = Color(0.75, 0.75, 0.75)
	detail_fix_hdr.visible = false
	detail_vbox.add_child(detail_fix_hdr)

	var detail_fix := Label.new()
	detail_fix.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	detail_fix.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	detail_fix.visible = false
	detail_vbox.add_child(detail_fix)

	var detail_mods_hdr := Label.new()
	detail_mods_hdr.text = "Affected mods"
	detail_mods_hdr.add_theme_font_size_override("font_size", 11)
	detail_mods_hdr.modulate = Color(0.75, 0.75, 0.75)
	detail_mods_hdr.visible = false
	detail_vbox.add_child(detail_mods_hdr)

	var detail_mods_lbl := Label.new()
	detail_mods_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	detail_mods_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	detail_mods_lbl.visible = false
	detail_vbox.add_child(detail_mods_lbl)

	var detail_labels := [detail_what_hdr, detail_what, detail_fix_hdr,
			detail_fix, detail_mods_hdr, detail_mods_lbl]

	var show_detail := func(issue: Dictionary):
		detail_title.text = issue["title"]
		var sev: String = issue["severity"]
		detail_title.modulate = Color(0.85, 0.32, 0.32) if sev == "critical" \
				else (Color(0.85, 0.70, 0.28) if sev == "warning" else Color(0.80, 0.80, 0.80))
		detail_what.text = issue["what"]
		detail_fix.text = issue["fix"]
		detail_mods_lbl.text = ", ".join(issue["mods"])
		for lbl in detail_labels:
			lbl.visible = true

	var populate_issues := func(issues: Array[Dictionary]):
		for child in issue_list.get_children():
			child.queue_free()
		if issues.is_empty():
			var lbl := Label.new()
			lbl.text = "No issues detected."
			lbl.modulate = Color(0.80, 0.80, 0.80)
			issue_list.add_child(lbl)
			return
		for issue: Dictionary in issues:
			var sev: String = issue["severity"]
			var btn := Button.new()
			btn.text = issue["title"]
			btn.alignment = HORIZONTAL_ALIGNMENT_LEFT
			btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			btn.modulate = Color(0.85, 0.38, 0.38) if sev == "critical" \
					else (Color(0.85, 0.72, 0.30) if sev == "warning" else Color(0.72, 0.72, 0.72))
			var iss := issue
			btn.pressed.connect(func(): show_detail.call(iss))
			issue_list.add_child(btn)

	scan_btn.pressed.connect(func():
		scan_btn.disabled = true
		scan_btn.text = "Scanning..."
		_run_dry_compat_analysis(populate_issues)
		scan_btn.disabled = false
		scan_btn.text = "Run Analysis"
	)

	return margin


# Scans all enabled archives in load order without mounting anything, then
# calls the populate callback with structured issue data for the UI.
# The main _report_lines array is swapped out so dry-run noise doesn't
# pollute the real launch log.
#
# IMPORTANT: This calls _scan_and_register_archive_claims (read-only scan via
# ZIPReader) — NOT _process_mod_candidate (which mounts packs and queues
# autoloads). Calling _process_mod_candidate here would have side effects
# that corrupt the real launch. _load_all_mods() clears all state before the
# real load, so stale dry-analysis data does not leak.
func _run_dry_compat_analysis(populate_cb: Callable) -> void:
	_override_registry.clear()
	_mod_script_analysis.clear()
	_archive_file_sets.clear()
	_bad_zips.clear()
	_database_replaced_by = ""
	_database_path = ""
	_scan_vanilla_paths()
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(TMP_DIR))

	var sorted := _ui_mod_entries.filter(func(e): return e["enabled"])
	sorted.sort_custom(func(a, b): return a["priority"] < b["priority"])

	if sorted.is_empty():
		populate_cb.call([])
		return

	var saved_lines := _report_lines
	var dry_lines: Array[String] = []
	_report_lines = dry_lines

	for i in sorted.size():
		var entry: Dictionary = sorted[i]
		var scan_path: String = entry["full_path"]
		if entry["ext"] == "folder":
			scan_path = _zip_folder_to_temp(entry["full_path"])
			if scan_path == "":
				continue
		_scan_and_register_archive_claims(scan_path, entry["mod_name"], entry["file_name"], i)

	var issues := _collect_conflict_issues()
	_report_lines = saved_lines
	populate_cb.call(issues)


func _build_updates_tab() -> Control:
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
		ver_lbl.text = "v" + version if version != "" else "—"
		ver_lbl.custom_minimum_size.x = 90
		row.add_child(ver_lbl)

		var status_lbl := Label.new()
		status_lbl.custom_minimum_size.x = 160
		status_lbl.text = "no update info" if mw_id == 0 or version == "" else "—"
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

	# ── Activity log ──────────────────────────────────────────────────────────

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
		await _check_updates_for_ui(status_info, add_log, check_btn)
		check_btn.disabled = false
		check_btn.text = "Check for Updates"
	)

	return margin


func _build_settings_tab(tabs: TabContainer, compat_idx: int, rebuild_mods_tab: Callable) -> Control:
	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 8)
	margin.add_theme_constant_override("margin_right", 8)
	margin.add_theme_constant_override("margin_top", 6)
	margin.add_theme_constant_override("margin_bottom", 6)

	var container := VBoxContainer.new()
	container.add_theme_constant_override("separation", 8)
	margin.add_child(container)

	var hdr := Label.new()
	hdr.text = "Developer Mode"
	hdr.add_theme_font_size_override("font_size", 13)
	container.add_child(hdr)
	container.add_child(HSeparator.new())

	var dev_check := CheckBox.new()
	dev_check.text = "Enable Developer Mode"
	dev_check.button_pressed = _developer_mode
	container.add_child(dev_check)

	var desc := Label.new()
	desc.text = "Enables:\n" \
			+ "  - Compatibility tab (scan for override conflicts without launching)\n" \
			+ "  - Compile check (loads each override script to catch parse errors early)\n" \
			+ "  - Override audit (warns if overrideScript() targets have 0 live nodes)\n" \
			+ "  - Conflict report saved to modloader_conflicts.txt after each launch\n" \
			+ "  - Verbose [Debug] logging for load order, timing, and override state\n" \
			+ "  - Loose mod folders loaded from the mods directory\n" \
			+ "\nOff by default — adds ~1s to launch for scanning."
	desc.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	desc.add_theme_font_size_override("font_size", 11)
	desc.modulate = Color(0.5, 0.5, 0.5)
	desc.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	container.add_child(desc)

	dev_check.toggled.connect(func(on: bool):
		_developer_mode = on
		tabs.set_tab_hidden(compat_idx, not on)
		rebuild_mods_tab.call()
	)

	return margin


func _check_updates_for_ui(status_info: Dictionary, add_log: Callable, check_btn: Button) -> void:
	var ids: Array[int] = []
	for fn in status_info:
		ids.append(status_info[fn]["mw_id"])
	if ids.is_empty():
		return

	var latest := await _fetch_latest_modworkshop_versions(ids)

	for fn: String in status_info:
		var info: Dictionary = status_info[fn]
		var lbl: Label = info["label"]
		var dl_btn: Button = info["dl_btn"]
		var latest_v = latest.get(str(info["mw_id"]), null)
		if latest_v == null:
			lbl.text = "no data"
			lbl.modulate = Color(1.0, 1.0, 1.0)
			continue

		var cmp := _compare_versions(info["version"], str(latest_v))
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
				var ok := await _download_and_replace_mod(full_path, mw_id)
				check_btn.disabled = false
				if ok:
					lbl.text = "updated — restart to apply"
					lbl.modulate = Color(0.80, 0.80, 0.80)
					dl_btn.modulate.a = 0.0
					dl_btn.disabled = true
					dl_btn.mouse_filter = Control.MOUSE_FILTER_IGNORE
					dl_btn.text = "Download"
					# Update cached version so next Check won't re-flag this mod.
					info["version"] = new_ver
					(info["ver_lbl"] as Label).text = "v" + new_ver
					add_log.call(mod_name + " — updated to v" + new_ver + ". Restart game to apply.")
				else:
					lbl.text = "download failed"
					lbl.modulate = Color(1.0, 0.4, 0.4)
					dl_btn.disabled = false
					dl_btn.text = "Retry"
					add_log.call(mod_name + " — download failed.")
			)


# ─── Main load loop ───────────────────────────────────────────────────────────

func _load_all_mods() -> void:
	_pending_autoloads.clear()
	_loaded_mod_ids.clear()
	_registered_autoload_names.clear()
	_override_registry.clear()
	_report_lines.clear()
	_database_replaced_by = ""
	_mod_script_analysis.clear()
	_archive_file_sets.clear()
	_bad_zips.clear()

	if _developer_mode:
		_scan_vanilla_paths()
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(TMP_DIR))

	# Build the candidate list from UI-configured entries (already filtered and trusted).
	var candidates: Array[Dictionary] = []
	for entry in _ui_mod_entries:
		if not entry["enabled"]:
			continue
		candidates.append(entry.duplicate())
	candidates.sort_custom(func(a, b): return a["priority"] < b["priority"])

	if candidates.is_empty():
		_log_info("No mods enabled.")
		return

	_log_info("=== Load Order ===")
	for i in candidates.size():
		var c: Dictionary = candidates[i]
		var tag := " [priority=" + str(c["priority"]) + "]" if c["priority"] != 0 else ""
		_log_info("  [" + str(i + 1) + "] " + c["mod_name"] + " | " + c["file_name"] + tag)
	_log_info("==================")

	for load_index in candidates.size():
		_process_mod_candidate(candidates[load_index], load_index)


# Try to load() each .gd file from mounted archives that extends a vanilla script.
# Catches real Godot compile errors with zero false positives.
func _preflight_compile_check() -> void:
	var checked := 0
	var fail_count := 0
	for archive_name: String in _archive_file_sets:
		var file_set: Dictionary = _archive_file_sets[archive_name]
		for res_path: String in file_set:
			if not (res_path as String).ends_with(".gd"): continue
			# Look up which mod owns this file to get its extends_paths.
			if not _override_registry.has(res_path): continue
			var owner_name: String = (_override_registry[res_path][0] as Dictionary)["mod_name"]
			if not _mod_script_analysis.has(owner_name): continue
			var analysis: Dictionary = _mod_script_analysis[owner_name]
			# Only check scripts that extend another script (override scripts).
			if (analysis["extends_paths"] as Array).is_empty(): continue
			# Try to compile. Check both load() returning null AND whether
			# the script can actually be instantiated (catches broken but non-null scripts).
			checked += 1
			var script: Resource = load(res_path)
			var failed := script == null
			if not failed and script is GDScript:
				failed = not (script as GDScript).can_instantiate()
			if failed:
				fail_count += 1
				_log_critical("Pre-flight: " + owner_name + " — " + res_path
						+ " failed to compile. See error above.")
	if fail_count > 0:
		_log_warning("Pre-flight: " + str(fail_count) + " of " + str(checked)
				+ " override script(s) failed to compile.")
	elif checked > 0:
		_log_info("Pre-flight: " + str(checked) + " override script(s) compiled OK.")


func _process_mod_candidate(c: Dictionary, load_index: int) -> void:
	var file_name: String = c["file_name"]
	var full_path: String = c["full_path"]
	var ext:       String = c["ext"]
	var mod_name:  String = c["mod_name"]
	var mod_id:    String = c["mod_id"]
	var cfg               = c["cfg"]

	_log_info("--- [" + str(load_index + 1) + "] " + mod_name + " (" + file_name + ")")

	if ext != "pck" and _loaded_mod_ids.has(mod_id):
		_log_warning("Duplicate mod id '" + mod_id + "' — skipped: " + file_name)
		return

	var mount_path := full_path
	if ext == "folder":
		mount_path = _zip_folder_to_temp(full_path)
		if mount_path == "":
			_log_critical("Failed to zip folder: " + file_name)
			return

	if not _try_mount_pack(mount_path):
		_log_critical("Failed to mount: " + file_name + " (path: " + mount_path + ")")
		return

	_log_info("  Mounted OK")
	_log_debug("  Mount path: " + mount_path)

	if ext != "pck":
		var scan_path := mount_path if ext == "folder" else full_path
		_scan_and_register_archive_claims(scan_path, mod_name, file_name, load_index)
		# Verify mount actually worked — check if at least one file is accessible.
		# Debug-only: FileAccess/ResourceLoader checks are unreliable for mounted
		# archives on some systems, so this is diagnostic info, not an error.
		if _developer_mode and _archive_file_sets.has(file_name):
			var verified := false
			for res_path: String in _archive_file_sets[file_name]:
				if FileAccess.file_exists(res_path) or ResourceLoader.exists(res_path):
					verified = true
					break
			if not verified and _archive_file_sets[file_name].size() > 0:
				_log_debug("  Mount verification: no files accessible via FileAccess/ResourceLoader (may be normal)")
				_log_debug("  Will attempt load() directly when needed")

	if ext == "pck" or not c["has_mod_txt"]:
		if not c["has_mod_txt"] and ext != "pck":
			_log_warning("  No mod.txt — autoloads skipped")
		return

	_loaded_mod_ids[mod_id] = true

	if cfg == null or not cfg.has_section("autoload"):
		return

	var keys: PackedStringArray = cfg.get_section_keys("autoload")
	for key in keys:
		var autoload_name := str(key)
		var res_path := str(cfg.get_value("autoload", key)).lstrip("*").strip_edges()

		if res_path == "":
			_log_warning("  Empty autoload path for '" + autoload_name + "' — skipped")
			continue

		if _registered_autoload_names.has(autoload_name):
			_log_warning("Duplicate autoload name '" + autoload_name + "' — skipped")
			continue
		_registered_autoload_names[autoload_name] = true

		if _archive_file_sets.has(file_name) and not _archive_file_sets[file_name].has(res_path):
			_log_critical("  Autoload path not found in archive: " + res_path)
			_log_critical("    Declared in mod.txt but missing from: " + file_name)
			# Log similar paths to help mod authors diagnose typos / case mismatches.
			var similar: Array[String] = []
			var target_file := res_path.get_file().to_lower()
			for p: String in _archive_file_sets[file_name]:
				if p.get_file().to_lower() == target_file:
					similar.append(p)
			if similar.size() > 0:
				_log_critical("    Similar paths in archive: " + ", ".join(similar))
			continue

		_pending_autoloads.append({ "mod_name": mod_name, "name": autoload_name, "path": res_path })
		_log_info("  Autoload queued: " + autoload_name + " -> " + res_path)
		_register_claim(res_path, mod_name, file_name, load_index, "autoload")


# ─── Logging ──────────────────────────────────────────────────────────────────

func _log_info(msg: String) -> void:
	var line := "[ModLoader][Info] " + msg
	print(line)
	_report_lines.append(line)


func _log_warning(msg: String) -> void:
	var line := "[ModLoader][Warning] " + msg
	push_warning(line)
	_report_lines.append(line)


func _log_critical(msg: String) -> void:
	var line := "[ModLoader][Critical] " + msg
	push_error(line)
	_report_lines.append(line)


func _log_debug(msg: String) -> void:
	if not _developer_mode:
		return
	var line := "[ModLoader][Debug] " + msg
	print(line)
	_report_lines.append(line)


# ─── Override registry ────────────────────────────────────────────────────────

func _register_claim(res_path: String, mod_name: String, archive: String,
		load_index: int, claim_type: String, source_path: String = "") -> void:
	if not _override_registry.has(res_path):
		_override_registry[res_path] = []
	for existing in _override_registry[res_path]:
		if existing["mod_name"] == mod_name and existing["archive"] == archive:
			return
	_override_registry[res_path].append({
		"mod_name": mod_name, "archive": archive, "load_index": load_index,
		"claim_type": claim_type, "source_path": source_path,
	})

func _is_dangerous_path(res_path: String) -> bool:
	return _vanilla_paths.has(res_path)

func _classify_claim(res_path: String) -> String:
	var lower := res_path.to_lower()
	if lower.ends_with(".gd"):                               return "script"
	if lower.ends_with(".tscn") or lower.ends_with(".scn"):  return "scene"
	if lower.ends_with(".tres"):                             return "resource"
	return "file"


# ─── Vanilla path scan ────────────────────────────────────────────────────────

func _scan_vanilla_paths() -> void:
	_vanilla_paths.clear()
	_database_path = ""
	for dir_path in VANILLA_SCAN_DIRS:
		_scan_vanilla_dir(dir_path)
	for path: String in _vanilla_paths:
		if path.get_extension().to_lower() == "gd" \
				and path.get_file().get_basename().to_lower() == "database":
			_database_path = path
			_log_info("Vanilla scan: scene registry -> " + _database_path)
			break
	if _vanilla_paths.is_empty():
		_log_warning("Vanilla scan: 0 files found — falling back to filename heuristics.")
	else:
		_log_info("Vanilla scan: " + str(_vanilla_paths.size()) + " game files indexed")

func _scan_vanilla_dir(dir_path: String) -> void:
	var dir := DirAccess.open(dir_path)
	if dir == null:
		return
	dir.list_dir_begin()
	while true:
		var entry := dir.get_next()
		if entry == "":
			break
		if entry.begins_with("."):
			continue
		var full := dir_path.path_join(entry)
		if dir.current_is_dir():
			_scan_vanilla_dir(full)
		elif entry.get_extension().to_lower() in TRACKED_EXTENSIONS:
			_vanilla_paths[full] = true
	dir.list_dir_end()


# ─── Archive scanner ──────────────────────────────────────────────────────────

func _scan_and_register_archive_claims(archive_path: String, mod_name: String,
		archive_file: String, load_index: int) -> void:
	var zr := ZIPReader.new()
	if zr.open(archive_path) != OK:
		_log_warning("  Could not scan archive: " + archive_file)
		return

	var files := zr.get_files()

	# Archives repacked on Windows via ZipFile.CreateFromDirectory() write backslash
	# separators. Godot mounts the pack but can't resolve those paths.
	var backslash_count := 0
	var example_bad := ""
	for f: String in files:
		if "\\" in f:
			backslash_count += 1
			if example_bad == "":
				example_bad = f
	if backslash_count > 0:
		_bad_zips.append({"mod_name": mod_name, "count": backslash_count, "example": example_bad})
		_log_critical("  BAD ZIP: " + str(backslash_count) + " entries use Windows backslash paths.")
		_log_critical("    Re-pack with 7-Zip. Example bad entry: '" + example_bad + "'")

	var tracked_count := 0
	var dangerous_count := 0
	var path_set: Dictionary = {}
	var gd_analysis: Dictionary = {
		"take_over_literal_paths": [],
		"extends_paths":           [],
		"uses_dynamic_override":   false,
		"lifecycle_no_super":      [],
		"calls_update_tooltip":    false,
		"class_names":             [],
		"extends_class_names":     [],
		"override_methods":        {},   # extends_path -> Array[method_name]
		"preload_paths":           [],
		"calls_base":              false, # uses base() instead of super() — Godot 3 or removed method
		"total_gd_files":          0,
	}

	for f in files:
		if f.get_extension().to_lower() == "gd":
			gd_analysis["total_gd_files"] = gd_analysis["total_gd_files"] + 1
			if _developer_mode:
				_scan_gd_source(zr.read_file(f).get_string_from_utf8(), gd_analysis)

		var res_path := _normalize_to_res_path(f)
		if res_path == "":
			continue

		path_set[res_path] = true
		tracked_count += 1
		_register_claim(res_path, mod_name, archive_file, load_index, _classify_claim(res_path), f)

		var bare_name := res_path.get_file().get_basename().to_lower()
		var is_db_file := bare_name == "database" and res_path.get_extension().to_lower() == "gd"

		if (res_path == _database_path and _database_path != "") or (is_db_file and _database_path == ""):
			if _database_replaced_by == "":
				_database_replaced_by = mod_name
			_log_critical("  DATABASE OVERRIDE: " + mod_name + " replaces Database.gd")
			_log_warning("    All preload() paths in this file must exist or parsing will fail.")
		elif is_db_file:
			_log_warning("  DATABASE COPY: " + mod_name + " bundles a private Database.gd at " + res_path)
			_log_warning("    Hardcoded preload() paths may break if companion mods aren't present.")
		elif _is_dangerous_path(res_path):
			dangerous_count += 1

	zr.close()
	_mod_script_analysis[mod_name] = gd_analysis
	_archive_file_sets[archive_file] = path_set

	var summary := "  " + str(tracked_count) + " resource path(s)"
	if dangerous_count > 0:
		summary += " [" + str(dangerous_count) + " replace vanilla files]"
	_log_info(summary)

	if gd_analysis["total_gd_files"] > 0:
		var override_count: int = (gd_analysis["take_over_literal_paths"] as Array).size() \
				+ (gd_analysis["extends_paths"] as Array).size()
		var dynamic_tag := " [uses overrideScript()]" if gd_analysis["uses_dynamic_override"] else ""
		_log_info("  " + str(gd_analysis["total_gd_files"]) + " .gd file(s), "
				+ str(override_count) + " override target(s)" + dynamic_tag)


func _normalize_to_res_path(zip_path: String) -> String:
	var path := zip_path.replace("\\", "/")
	if path.begins_with("res://"):   return path
	if path.begins_with("/"):        return "res:/" + path
	if path.begins_with(".") or path == "mod.txt": return ""
	if path.get_extension().to_lower() in TRACKED_EXTENSIONS:
		return "res://" + path
	return ""


# ─── GDScript source analysis ─────────────────────────────────────────────────

func _scan_gd_source(text: String, analysis: Dictionary) -> void:
	for m in _re_take_over.search_all(text):
		var path := m.get_string(1)
		if path not in (analysis["take_over_literal_paths"] as Array):
			(analysis["take_over_literal_paths"] as Array).append(path)

	var m_ext := _re_extends.search(text)
	if m_ext:
		var path := m_ext.get_string(1)
		if path not in (analysis["extends_paths"] as Array):
			(analysis["extends_paths"] as Array).append(path)

	# Detect extends via class_name (e.g. "extends Weapon") — breaks override chains.
	var m_ext_cn := _re_extends_classname.search(text)
	if m_ext_cn:
		var cn := m_ext_cn.get_string(1)
		if cn not in (analysis["extends_class_names"] as Array):
			(analysis["extends_class_names"] as Array).append(cn)

	# Detect class_name declarations — Godot bug #83542: can only be overridden once.
	for m_cn in _re_class_name.search_all(text):
		var cn := m_cn.get_string(1)
		if cn not in (analysis["class_names"] as Array):
			(analysis["class_names"] as Array).append(cn)

	if not analysis["uses_dynamic_override"]:
		analysis["uses_dynamic_override"] = "get_base_script()" in text \
				or "take_over_path(parentScript" in text

	# UpdateTooltip() is inventory-UI only. World-item tooltips are written directly
	# by HUD._physics_process from gameData.tooltip — this override has no effect there.
	if not analysis["calls_update_tooltip"]:
		analysis["calls_update_tooltip"] = "UpdateTooltip" in text

	# Detect base() calls — Godot 3 pattern or removed parent method.
	if not analysis["calls_base"]:
		analysis["calls_base"] = "base(" in text

	# Collect preload() paths for stale-cache detection.
	for m_pl in _re_preload.search_all(text):
		var pl_path := m_pl.get_string(1)
		if pl_path not in (analysis["preload_paths"] as Array):
			(analysis["preload_paths"] as Array).append(pl_path)

	# Collect ALL method declarations. If this file extends a vanilla script,
	# track which methods it overrides — this is the key data for method-level
	# collision detection between mods.
	var func_matches := _re_func.search_all(text)

	# Determine the extends target for this file (if any).
	var ext_target := ""
	if m_ext:
		ext_target = m_ext.get_string(1)

	for i in func_matches.size():
		var func_name := func_matches[i].get_string(1)

		# Track method names per extends target for collision detection.
		if ext_target != "":
			if not (analysis["override_methods"] as Dictionary).has(ext_target):
				(analysis["override_methods"] as Dictionary)[ext_target] = []
			var method_list: Array = (analysis["override_methods"] as Dictionary)[ext_target]
			if func_name not in method_list:
				method_list.append(func_name)

		# Check lifecycle methods for super(). Missing it breaks the override chain.
		if func_name not in LIFECYCLE_METHODS:
			continue
		var body_start := func_matches[i].get_end()
		var body_end := text.length() if i + 1 >= func_matches.size() \
				else func_matches[i + 1].get_start()
		var body := text.substr(body_start, body_end - body_start)
		if "super(" not in body and "super." not in body:
			if func_name not in (analysis["lifecycle_no_super"] as Array):
				(analysis["lifecycle_no_super"] as Array).append(func_name)


func _analyze_script_conflicts() -> void:
	var issues := _collect_conflict_issues()
	for issue: Dictionary in issues:
		var sev: String = issue["severity"]
		var log_fn := _log_info if sev == "info" else (_log_critical if sev == "critical" else _log_warning)
		log_fn.call(issue["title"] + " — " + ", ".join(issue["mods"]))


func _find_database_affected_mods() -> Array[String]:
	var affected: Array[String] = []
	for res_path: String in _override_registry:
		if res_path == _database_path: continue
		var lower := res_path.to_lower()
		if not (lower.ends_with(".tscn") or lower.ends_with(".scn")): continue
		# Only count scene overrides that replace vanilla files. A mod shipping its
		# own scenes under mods/MyMod/ is not affected by Database preload caching.
		if not _is_dangerous_path(res_path): continue
		for claim in (_override_registry[res_path] as Array):
			var cn: String = claim["mod_name"]
			if cn != _database_replaced_by and cn not in affected:
				affected.append(cn)
	return affected


# Returns structured issue data for the compatibility tab UI. Operates on
# whatever state is currently in _mod_script_analysis and _override_registry
# (populated by _scan_and_register_archive_claims).
func _collect_conflict_issues() -> Array[Dictionary]:
	var issues: Array[Dictionary] = []

	# 1. Literal take_over_path() conflicts — only one version of that script can be active.
	var literal_claims: Dictionary = {}
	for mod_name: String in _mod_script_analysis:
		for path in (_mod_script_analysis[mod_name]["take_over_literal_paths"] as Array):
			if not literal_claims.has(path): literal_claims[path] = []
			if mod_name not in literal_claims[path]:
				(literal_claims[path] as Array).append(mod_name)

	for path: String in literal_claims:
		var mods: Array = literal_claims[path]
		if mods.size() <= 1: continue
		issues.append({
			"severity": "critical",
			"title": "Script Conflict: " + path.get_file(),
			"what": "Both mods call take_over_path() on the same script:\n  " + path
					+ "\n\nOnly the last-loaded version is active. The other mod's "
					+ "changes to this script are silently replaced.",
			"fix": "Use priority to control which mod wins (higher = loads last = wins).\n\n"
					+ "To fix: one mod should switch to the extends + super() pattern "
					+ "so both can coexist in a chain.",
			"mods": mods,
		})

	# 2. Dynamic overrideScript() chains — compose correctly only if all mods call super().
	var extends_claims: Dictionary = {}
	for mod_name: String in _mod_script_analysis:
		var analysis: Dictionary = _mod_script_analysis[mod_name]
		if not analysis["uses_dynamic_override"]: continue
		for path in (analysis["extends_paths"] as Array):
			if not extends_claims.has(path): extends_claims[path] = []
			if mod_name not in extends_claims[path]:
				(extends_claims[path] as Array).append(mod_name)

	for path: String in extends_claims:
		var claimants: Array = extends_claims[path]
		if claimants.size() <= 1: continue
		var bad_mods: Array = []
		for cmod: String in claimants:
			if not (_mod_script_analysis[cmod]["lifecycle_no_super"] as Array).is_empty():
				bad_mods.append(cmod)
		if bad_mods.is_empty():
			continue
		var bad_methods: Array[String] = []
		for bm: String in bad_mods:
			var methods: Array = _mod_script_analysis[bm]["lifecycle_no_super"]
			bad_methods.append(bm + " (" + ", ".join(methods) + ")")
		issues.append({
			"severity": "warning",
			"title": "Chain Broken: " + path.get_file(),
			"what": "These mods both override " + path.get_file() + " using extends, "
					+ "but " + ", ".join(bad_mods) + " is missing super() calls:\n  "
					+ "\n  ".join(bad_methods)
					+ "\n\nWithout super(), the override chain breaks — other mods' logic "
					+ "for those methods never runs.",
			"fix": "Workaround: give " + ", ".join(bad_mods)
					+ " a lower priority so it loads first (limits the damage).\n\n"
					+ "Fix: add super() at the start of each listed method.",
			"mods": claimants,
		})

	# 2b. Informational card for overrideScript() mods — even without chain conflicts,
	# mod authors need to understand the timing constraint.
	for mod_name: String in _mod_script_analysis:
		var analysis: Dictionary = _mod_script_analysis[mod_name]
		if not analysis["uses_dynamic_override"]:
			continue
		var targets: Array = analysis["extends_paths"]
		if targets.is_empty():
			continue
		# Skip if this mod already appeared in a chain conflict above.
		var already_flagged := false
		for iss in issues:
			if mod_name in (iss["mods"] as Array) and "Chain" in (iss["title"] as String):
				already_flagged = true
				break
		if already_flagged:
			continue
		var target_list := ", ".join(targets.map(func(p): return (p as String).get_file()))
		issues.append({
			"severity": "info",
			"title": "Uses overrideScript(): " + mod_name,
			"what": mod_name + " uses overrideScript() to extend:\n  " + target_list
					+ "\n\noverrideScript() only affects nodes instantiated after the "
					+ "override is registered. Nodes already in the scene tree at launch "
					+ "(e.g. containers, HUD elements) will keep the original script.",
			"fix": "This is expected behavior, not a bug. If the mod doesn't seem to "
					+ "work, check that its target nodes are spawned at runtime rather "
					+ "than placed in the scene at export time.\n\n"
					+ "Enable Developer Mode and check the conflict report for "
					+ "'Override registered but 0 matching nodes found' warnings.",
			"mods": [mod_name],
		})

	# 3. File overlap grouped by mod pair — one card per conflicting pair, not per file.
	# Build per-mod path sets from the override registry.
	var mod_paths: Dictionary = {}  # mod_name -> Dictionary of res_paths
	for res_path: String in _override_registry:
		var claims: Array = _override_registry[res_path]
		for claim in claims:
			var mn: String = claim["mod_name"]
			if not mod_paths.has(mn):
				mod_paths[mn] = {}
			(mod_paths[mn] as Dictionary)[res_path] = true

	# Compare every pair of mods for shared files.
	var mod_list: Array = mod_paths.keys()
	var seen_pairs: Dictionary = {}
	for i in mod_list.size():
		for j in range(i + 1, mod_list.size()):
			var mod_a: String = mod_list[i]
			var mod_b: String = mod_list[j]
			var pair_key := mod_a + "|" + mod_b
			if seen_pairs.has(pair_key): continue
			seen_pairs[pair_key] = true

			var shared: Array[String] = []
			var shared_vanilla: Array[String] = []
			for p: String in (mod_paths[mod_a] as Dictionary):
				if (mod_paths[mod_b] as Dictionary).has(p):
					shared.append(p)
					if _is_dangerous_path(p):
						shared_vanilla.append(p)

			if shared.is_empty(): continue

			# Build a readable list of conflicting filenames.
			var file_names: Array[String] = []
			for p in shared:
				var fname: String = p.get_file()
				if fname not in file_names:
					file_names.append(fname)
			file_names.sort()
			var file_list := ", ".join(file_names)
			if file_names.size() > MAX_DISPLAYED_FILENAMES:
				file_list = ", ".join(file_names.slice(0, MAX_DISPLAYED_FILENAMES)) + " + " \
						+ str(file_names.size() - MAX_DISPLAYED_FILENAMES) + " more"

			# Determine severity and wording based on overlap scale.
			var sev := "critical" if shared_vanilla.size() > 0 else "warning"
			var title := ""
			var what := ""
			var fix := ""

			if shared.size() >= OVERLAP_FILE_THRESHOLD and shared_vanilla.size() >= OVERLAP_VANILLA_THRESHOLD:
				title = "Likely Incompatible: " + mod_a + " + " + mod_b
				what = "Both mods change " + str(shared.size()) + " of the same game files (" \
						+ str(shared_vanilla.size()) + " core scripts):\n  " + file_list \
						+ "\n\nThis much overlap almost always means these mods will " \
						+ "break each other. One mod's changes will be lost."
				fix = "Disable one of these mods. Some overhaul mods already include " \
						+ "smaller mods — check the mod descriptions."
			else:
				title = "Overlap: " + mod_a + " + " + mod_b
				what = str(shared.size()) + " shared file(s):\n  " + file_list
				if shared_vanilla.size() > 0:
					what += "\n\n" + str(shared_vanilla.size()) + " of these are game files. " \
							+ "The mod with higher priority wins — the other mod's " \
							+ "version of these files is ignored."
				else:
					what += "\n\nBoth mods include these files. The mod with higher " \
							+ "priority wins for each shared file."
				fix = "Try changing the priority order on the Mods tab to see which " \
						+ "arrangement works best. If both mods need these files, " \
						+ "they can't be used together."

			issues.append({
				"severity": sev,
				"title": title,
				"what": what,
				"fix": fix,
				"mods": [mod_a, mod_b],
			})

	# 4. Database.gd replaced — preload() caches paths before resource overrides take effect.
	if _database_replaced_by != "":
		var affected := _find_database_affected_mods()
		if not affected.is_empty():
			var all_mods: Array[String] = [_database_replaced_by]
			all_mods.append_array(affected)
			issues.append({
				"severity": "critical",
				"title": "Database.gd Replaced",
				"what": _database_replaced_by + " replaces Database.gd, which preload()s all "
						+ "item and scene paths at parse time.\n\nScene overrides from other mods "
						+ "may not take effect because Database.gd caches the original paths "
						+ "before those mods mount.",
				"fix": "Potentially affected mods:\n  " + ", ".join(affected)
						+ "\n\nIf scenes or items are missing, the load order between "
						+ _database_replaced_by + " and scene-override mods may need adjusting.",
				"mods": all_mods,
			})

	# 5. class_name double override — Godot bug #83542, fatal crash at startup.
	# Only fires when 2+ mods with uses_dynamic_override both extend-by-class_name
	# on the same class AND that class_name is declared by a mod (not a Godot built-in).
	var declared_class_names: Dictionary = {}
	for mod_name: String in _mod_script_analysis:
		for cn in (_mod_script_analysis[mod_name]["class_names"] as Array):
			declared_class_names[cn] = true
	var cn_override_claims: Dictionary = {}  # class_name -> Array[mod_name]
	for mod_name: String in _mod_script_analysis:
		var cn_analysis: Dictionary = _mod_script_analysis[mod_name]
		if not cn_analysis["uses_dynamic_override"]: continue
		for cn in (cn_analysis["extends_class_names"] as Array):
			# Skip if no mod declares this class_name — it's a Godot built-in (Node,
			# Resource, Control, etc.) or a game class we can't verify. The bug only
			# matters for class_name scripts that get take_over_path'd by mods.
			if not declared_class_names.has(cn):
				continue
			if not cn_override_claims.has(cn): cn_override_claims[cn] = []
			if mod_name not in cn_override_claims[cn]:
				(cn_override_claims[cn] as Array).append(mod_name)
	for cn: String in cn_override_claims:
		var cn_mods: Array = cn_override_claims[cn]
		if cn_mods.size() <= 1: continue
		issues.append({
			"severity": "critical",
			"title": "class_name Crash: " + cn,
			"what": "These mods both override a script that uses class_name '" + cn + "'.\n\n"
					+ "Godot bug #83542: take_over_path() on class_name scripts can only "
					+ "succeed once. A second override causes a fatal engine crash at startup.",
			"fix": "Only one mod can override a class_name script. Disable all but one.\n\n"
					+ "To fix: mod authors should use extends \"res://path.gd\" instead of "
					+ "extends " + cn + " to avoid the class_name limitation.",
			"mods": cn_mods,
		})

	# 6. Broken extends paths — mod extends a script that doesn't exist anywhere.
	# Use FileAccess + ResourceLoader to check the live filesystem rather than
	# relying on directory scanning, which can miss paths outside Scripts/Scenes.
	for mod_name: String in _mod_script_analysis:
		for ext_path in (_mod_script_analysis[mod_name]["extends_paths"] as Array):
			var p: String = ext_path
			if FileAccess.file_exists(p) or ResourceLoader.exists(p):
				continue
			issues.append({
				"severity": "warning",
				"title": "Missing Script: " + p.get_file(),
				"what": mod_name + " extends a script that no longer exists:\n  " + p
						+ "\n\nThis override will silently fail — " + mod_name + "'s changes "
						+ "to this script won't apply. The game may have been updated "
						+ "and this script was renamed or moved.",
				"fix": mod_name + " needs an update for the current game version. "
						+ "The mod will still load but features that depend on this "
						+ "script won't work.",
				"mods": [mod_name],
			})

	# 7. base() calls — Godot 3 pattern or removed parent method. Will fail at runtime.
	for mod_name: String in _mod_script_analysis:
		if not _mod_script_analysis[mod_name]["calls_base"]: continue
		issues.append({
			"severity": "warning",
			"title": "Uses base(): " + mod_name,
			"what": mod_name + " calls base() which is not a GDScript 4 built-in.\n\n"
					+ "If this was meant to call the parent method, it should be super(). "
					+ "If base() was a method on the game script, it may have been "
					+ "removed or renamed in the current version.",
			"fix": "The mod author needs to replace base() with super() or update "
					+ "for the current game version.",
			"mods": [mod_name],
		})

	# 8. Method-level collisions — two mods override the same method on the same script.
	var method_claims: Dictionary = {}  # extends_path -> {method_name -> Array[mod_name]}
	for mod_name: String in _mod_script_analysis:
		var om: Dictionary = _mod_script_analysis[mod_name]["override_methods"]
		for ext_path: String in om:
			if not method_claims.has(ext_path):
				method_claims[ext_path] = {}
			for method_name in (om[ext_path] as Array):
				if not (method_claims[ext_path] as Dictionary).has(method_name):
					(method_claims[ext_path] as Dictionary)[method_name] = []
				var claimers: Array = (method_claims[ext_path] as Dictionary)[method_name]
				if mod_name not in claimers:
					claimers.append(mod_name)

	# Group shared methods by mod pair to avoid spamming one card per method.
	var method_pair_issues: Dictionary = {}  # "modA|modB" -> {script, methods}
	for ext_path: String in method_claims:
		for method_name: String in (method_claims[ext_path] as Dictionary):
			var method_mods: Array = (method_claims[ext_path] as Dictionary)[method_name]
			if method_mods.size() <= 1: continue
			for mi in method_mods.size():
				for mj in range(mi + 1, method_mods.size()):
					var mpk: String = str(method_mods[mi]) + "|" + str(method_mods[mj])
					if not method_pair_issues.has(mpk):
						method_pair_issues[mpk] = {
							"mod_a": method_mods[mi], "mod_b": method_mods[mj], "scripts": {}
						}
					var mp: Dictionary = method_pair_issues[mpk]
					if not (mp["scripts"] as Dictionary).has(ext_path):
						(mp["scripts"] as Dictionary)[ext_path] = []
					var ml: Array = (mp["scripts"] as Dictionary)[ext_path]
					if method_name not in ml:
						ml.append(method_name)

	for mpk: String in method_pair_issues:
		var mp_data: Dictionary = method_pair_issues[mpk]
		var mp_mod_a: String = mp_data["mod_a"]
		var mp_mod_b: String = mp_data["mod_b"]
		var mp_scripts: Dictionary = mp_data["scripts"]
		var detail_lines: Array[String] = []
		for sp: String in mp_scripts:
			detail_lines.append(sp.get_file() + ": " + ", ".join(mp_scripts[sp]))
		issues.append({
			"severity": "warning",
			"title": "Method Overlap: " + mp_mod_a + " + " + mp_mod_b,
			"what": "Both mods override the same method(s) on the same script(s):\n  "
					+ "\n  ".join(detail_lines)
					+ "\n\nEven with correct super() calls, both mods are modifying the same "
					+ "function. Changes may interfere depending on load order.",
			"fix": "Test with both priority orderings to find which works. If neither "
					+ "works, these mods need author coordination to split their changes "
					+ "across different methods.",
			"mods": [mp_mod_a, mp_mod_b],
		})

	# 9. Stale preload() — mod preloads a path that another mod overrides via file replacement.
	var all_override_paths: Dictionary = {}
	for res_path: String in _override_registry:
		var pl_claims: Array = _override_registry[res_path]
		if pl_claims.size() >= 1:
			all_override_paths[res_path] = (pl_claims[pl_claims.size() - 1] as Dictionary)["mod_name"]
	for mod_name: String in _mod_script_analysis:
		for pl_path in (_mod_script_analysis[mod_name]["preload_paths"] as Array):
			if not all_override_paths.has(pl_path): continue
			var overrider: String = all_override_paths[pl_path]
			if overrider == mod_name: continue
			issues.append({
				"severity": "warning",
				"title": "Stale preload(): " + (pl_path as String).get_file(),
				"what": mod_name + " uses preload(\"" + pl_path + "\") but " + overrider
						+ " replaces that file.\n\npreload() caches at compile time, before "
						+ "mods mount. " + mod_name + " will get the vanilla version, not "
						+ overrider + "'s replacement.",
				"fix": "Replace preload() with load() in " + mod_name + "'s script. "
						+ "load() runs at runtime and respects mounted mod files.",
				"mods": [mod_name, overrider],
			})

	# 10. BAD ZIP — Windows backslash paths in archive. Godot can't resolve them.
	for bz: Dictionary in _bad_zips:
		issues.append({
			"severity": "critical",
			"title": "Bad Archive: " + bz["mod_name"],
			"what": bz["mod_name"] + " has " + str(bz["count"])
					+ " entries with backslash (\\) path separators.\n\n"
					+ "Godot requires forward slashes. These files will silently fail "
					+ "to load.\n\nExample: " + bz["example"],
			"fix": "Re-pack with 7-Zip (which uses forward slashes). This typically "
					+ "happens when using Windows ZipFile.CreateFromDirectory().",
			"mods": [bz["mod_name"]],
		})

	return issues


# ─── Override diagnostics (developer mode) ───────────────────────────────────

# Logs a timing note for each mod that uses overrideScript(). Runs after
# autoloads have been instantiated — by this point the override is registered
# but the scene hasn't reloaded yet, so existing nodes still have the old script.
func _log_override_timing_warnings() -> void:
	for mod_name: String in _mod_script_analysis:
		var analysis: Dictionary = _mod_script_analysis[mod_name]
		if not analysis["uses_dynamic_override"]:
			continue
		var targets: Array = analysis["extends_paths"]
		if targets.is_empty():
			continue
		var target_list := ", ".join(targets.map(func(p): return (p as String).get_file()))
		_log_debug(mod_name + " uses overrideScript() on: " + target_list
				+ " — applies after scene reload")


# Walks the scene tree after reload and checks whether any live node's script
# matches a known override target. Logs a warning for targets with zero matching
# instances — the most common "mod does nothing" silent-failure case.
func _audit_override_instances() -> void:
	var override_targets: Dictionary = {}  # res_path -> mod_name
	for mod_name: String in _mod_script_analysis:
		var analysis: Dictionary = _mod_script_analysis[mod_name]
		for path in (analysis["take_over_literal_paths"] as Array):
			override_targets[path] = mod_name
		if analysis["uses_dynamic_override"]:
			for path in (analysis["extends_paths"] as Array):
				override_targets[path] = mod_name

	if override_targets.is_empty():
		return

	var live_script_paths: Dictionary = {}
	_collect_live_scripts(get_tree().root, live_script_paths)

	for target_path: String in override_targets:
		var mod_name: String = override_targets[target_path]
		if live_script_paths.has(target_path):
			_log_debug("Override applied: " + target_path.get_file()
					+ " — " + str(live_script_paths[target_path]) + " node(s) [" + mod_name + "]")
		else:
			_log_warning("Override registered but 0 nodes use " + target_path.get_file()
					+ " in current scene [" + mod_name + "]")
			_log_warning("  Target may be spawned later at runtime, or the path may be wrong.")


func _collect_live_scripts(root_node: Node, out: Dictionary) -> void:
	# Iterative traversal to avoid stack overflow on deeply nested scene trees.
	var stack: Array[Node] = [root_node]
	while not stack.is_empty():
		var node: Node = stack.pop_back()
		var script: Script = node.get_script() as Script
		if script:
			var path := script.resource_path
			if path != "":
				out[path] = (out.get(path, 0) as int) + 1
		stack.append_array(node.get_children())


# ─── Conflict summary ─────────────────────────────────────────────────────────

func _print_conflict_summary() -> void:
	_log_info("")
	_log_info("============================================")
	_log_info("=== ModLoader Compatibility Summary      ===")
	_log_info("============================================")
	_log_info("Mods loaded:  " + str(_loaded_mod_ids.size()))

	var conflicted_paths: Array[String] = []
	var critical_conflicts: Array[String] = []
	for res_path: String in _override_registry:
		var claims: Array = _override_registry[res_path]
		if claims.size() > 1:
			conflicted_paths.append(res_path)
			if _is_dangerous_path(res_path) or res_path == _database_path:
				critical_conflicts.append(res_path)

	_log_info("Conflicting resource paths: " + str(conflicted_paths.size()))
	_log_info("Critical conflicts:         " + str(critical_conflicts.size()))

	if conflicted_paths.is_empty():
		_log_info("No resource path conflicts — all mods appear compatible.")
	else:
		_log_info("")
		_log_info("--- Conflicted Paths (last loader wins) ---")
		for res_path in conflicted_paths:
			var claims: Array = _override_registry[res_path]
			var winner: Dictionary = claims[claims.size() - 1]
			_log_warning("CONFLICT: " + res_path)
			for claim in claims:
				var marker := " <-- wins" if claim == winner else ""
				_log_info("    [" + str(claim["load_index"] + 1) + "] "
						+ claim["mod_name"] + " via " + claim["archive"] + marker)

	if _database_replaced_by != "":
		var affected := _find_database_affected_mods()
		if not affected.is_empty():
			_log_warning("DATABASE: " + _database_replaced_by + " replaced Database.gd.")
			_log_warning("  Scene overrides from [" + ", ".join(affected) + "] may not take effect.")

	_analyze_script_conflicts()

	_log_info("============================================")
	_log_info("")


func _write_conflict_report() -> void:
	var f := FileAccess.open(CONFLICT_REPORT_PATH, FileAccess.WRITE)
	if f == null:
		_log_warning("Could not write report to: " + CONFLICT_REPORT_PATH)
		return
	for line in _report_lines:
		f.store_line(line)
	f.close()
	_log_info("Conflict report written to: " + CONFLICT_REPORT_PATH)


# ─── Autoload instantiation ───────────────────────────────────────────────────

func _instantiate_autoload(mod_name: String, autoload_name: String, res_path: String) -> void:
	# Neither FileAccess.file_exists() nor ResourceLoader.exists() is reliable for
	# files in mounted archives across all systems. Try load() directly and use the
	# existence checks only for diagnostics when load() fails.
	var resource: Resource = load(res_path)
	if resource == null:
		var fa := FileAccess.file_exists(res_path)
		var rl := ResourceLoader.exists(res_path)
		_log_critical("Autoload failed: " + autoload_name + " -> " + res_path + " [" + mod_name + "]")
		_log_critical("  FileAccess.file_exists=" + str(fa) + "  ResourceLoader.exists=" + str(rl))
		if not fa and not rl:
			_log_critical("  File not accessible after mounting. Possible causes:")
			_log_critical("    - Windows backslash paths in zip (re-pack with 7-Zip)")
			_log_critical("    - Archive failed to mount (check for earlier errors)")
			_log_critical("    - Path in mod.txt doesn't match actual file path in archive")
		else:
			_log_critical("  File exists but failed to parse. Check the Godot log above.")
		return

	# Add to root so mods can find autoloads at /root/<name>, matching real autoload behavior.
	if get_tree().root.has_node(autoload_name):
		_log_warning("Autoload name '" + autoload_name + "' conflicts with existing node at /root/"
				+ autoload_name + " — Godot will rename it. [" + mod_name + "]")

	if resource is PackedScene:
		var instance: Node = (resource as PackedScene).instantiate()
		instance.name = autoload_name
		get_tree().root.call_deferred("add_child", instance)
		_log_info("Autoload instantiated (scene): " + autoload_name + " [" + mod_name + "]")
		return

	if resource is GDScript:
		var gdscript := resource as GDScript
		if not gdscript.can_instantiate():
			_log_critical("Autoload script failed to compile: " + autoload_name
					+ " -> " + res_path + " [" + mod_name + "]")
			_log_critical("  can_instantiate() returned false. Check the Godot log above for parse errors.")
			return
		var inst: Variant = gdscript.new()
		if inst == null:
			_log_warning("Autoload script returned null: " + autoload_name)
			return
		if inst is Node:
			(inst as Node).name = autoload_name
			get_tree().root.call_deferred("add_child", inst as Node)
			_log_info("Autoload instantiated (script): " + autoload_name + " [" + mod_name + "]")
			return
		_log_warning("Autoload is not a Node — not added to tree: " + autoload_name)


# ─── Mount helper ─────────────────────────────────────────────────────────────

func _try_mount_pack(path: String) -> bool:
	if ProjectSettings.load_resource_pack(path):
		return true
	if path.get_extension().to_lower() != "vmz":
		return false
	# VMZ files are renamed zips — copy to a real .zip path so Godot can open them.
	var temp_zip := ProjectSettings.globalize_path(TMP_DIR).path_join(
			path.get_file().get_basename() + ".zip")
	var data := FileAccess.get_file_as_bytes(path)
	if data.size() == 0:
		return false
	var out := FileAccess.open(temp_zip, FileAccess.WRITE)
	if out == null:
		return false
	out.store_buffer(data)
	out.close()
	return ProjectSettings.load_resource_pack(temp_zip)


# ─── mod.txt parser ───────────────────────────────────────────────────────────

func _read_mod_config(path: String) -> ConfigFile:
	var zr := ZIPReader.new()
	if zr.open(path) != OK:
		return null
	if not zr.file_exists("mod.txt"):
		zr.close()
		return null
	var text := zr.read_file("mod.txt").get_string_from_utf8()
	zr.close()
	return _parse_mod_txt(text)


func _read_mod_config_folder(folder_path: String) -> ConfigFile:
	var mod_txt_path := folder_path.path_join("mod.txt")
	if not FileAccess.file_exists(mod_txt_path):
		return null
	var f := FileAccess.open(mod_txt_path, FileAccess.READ)
	if f == null:
		return null
	var text := f.get_as_text()
	f.close()
	return _parse_mod_txt(text)


func _parse_mod_txt(text: String) -> ConfigFile:
	if text.begins_with("\uFEFF"):
		text = text.substr(1)
	var cfg := ConfigFile.new()
	if cfg.parse(text) != OK:
		return null
	return cfg


# ─── Folder → temp zip (developer mode) ──────────────────────────────────────

func _zip_folder_to_temp(folder_path: String) -> String:
	var folder_name := folder_path.get_file()
	var tmp_zip_path := ProjectSettings.globalize_path(TMP_DIR).path_join(
			folder_name + "_dev.zip")
	var zp := ZIPPacker.new()
	if zp.open(tmp_zip_path) != OK:
		_log_critical("Failed to create temp zip: " + tmp_zip_path)
		return ""
	# Zip contents without a top-level wrapper — the folder's internal structure
	# already mirrors the res:// paths the mod expects.
	_zip_folder_recursive(zp, folder_path, "")
	zp.close()
	return tmp_zip_path


func _zip_folder_recursive(zp: ZIPPacker, disk_path: String, archive_prefix: String) -> void:
	var dir := DirAccess.open(disk_path)
	if dir == null:
		return
	dir.list_dir_begin()
	while true:
		var entry := dir.get_next()
		if entry == "":
			break
		if entry.begins_with("."):
			continue
		var full := disk_path.path_join(entry)
		var arc_path := entry if archive_prefix == "" else archive_prefix.path_join(entry)
		if dir.current_is_dir():
			_zip_folder_recursive(zp, full, arc_path)
		else:
			var data := FileAccess.get_file_as_bytes(full)
			zp.start_file(arc_path)
			zp.write_file(data)
			zp.close_file()
	dir.list_dir_end()


# ─── Update fetch helpers ─────────────────────────────────────────────────────

# Compares two dotted version strings. Returns -1 if a < b, 0 if equal, 1 if a > b.
# "0.0.2" vs "0.0.1" → 1 (local is newer, no update needed).
func _compare_versions(a: String, b: String) -> int:
	var pa := a.lstrip("vV").split(".")
	var pb := b.lstrip("vV").split(".")
	var n := max(pa.size(), pb.size())
	for i in n:
		var va := int(pa[i]) if i < pa.size() else 0
		var vb := int(pb[i]) if i < pb.size() else 0
		if va < vb: return -1
		if va > vb: return 1
	return 0


func _fetch_latest_modworkshop_versions(ids: Array[int]) -> Dictionary:
	var latest_versions := {}
	for chunk_ids in _chunk_int_array(ids, MODWORKSHOP_BATCH_SIZE):
		var req := HTTPRequest.new()
		req.timeout = API_CHECK_TIMEOUT
		add_child(req)
		var err := req.request(MODWORKSHOP_VERSIONS_URL,
			PackedStringArray(["Content-Type: application/json", "Accept: application/json"]),
			HTTPClient.METHOD_GET, JSON.stringify({"mod_ids": chunk_ids}))
		if err != OK:
			req.queue_free()
			continue
		# request_completed → [result, http_code, headers, body]
		var res: Array = await req.request_completed
		req.queue_free()
		if res[0] != HTTPRequest.RESULT_SUCCESS or res[1] < 200 or res[1] >= 300:
			continue
		var parsed = JSON.parse_string((res[3] as PackedByteArray).get_string_from_utf8())
		if parsed is Dictionary:
			latest_versions.merge(parsed, true)
	return latest_versions


func _download_and_replace_mod(target_path: String, modworkshop_id: int) -> bool:
	var req := HTTPRequest.new()
	req.timeout = API_DOWNLOAD_TIMEOUT
	add_child(req)
	var err := req.request(MODWORKSHOP_DOWNLOAD_URL_TEMPLATE % str(modworkshop_id))
	if err != OK:
		req.queue_free()
		return false
	# request_completed → [result, http_code, headers, body]
	var res: Array = await req.request_completed
	req.queue_free()

	if res[0] != HTTPRequest.RESULT_SUCCESS or res[1] < 200 or res[1] >= 300:
		return false
	var response_body: PackedByteArray = res[3]
	if response_body.is_empty():
		return false

	var temp_path   := target_path + ".download"
	var backup_path := target_path + ".bak"
	if FileAccess.file_exists(temp_path):   DirAccess.remove_absolute(temp_path)
	if FileAccess.file_exists(backup_path): DirAccess.remove_absolute(backup_path)

	var out := FileAccess.open(temp_path, FileAccess.WRITE)
	if out == null:
		return false
	out.store_buffer(response_body)
	out.close()

	if _read_mod_config(temp_path) == null:
		DirAccess.remove_absolute(temp_path)
		return false

	var dir_access := DirAccess.open(target_path.get_base_dir())
	if dir_access == null:
		DirAccess.remove_absolute(temp_path)
		return false

	if FileAccess.file_exists(target_path):
		if dir_access.rename(target_path.get_file(), backup_path.get_file()) != OK:
			DirAccess.remove_absolute(temp_path)
			return false

	if dir_access.rename(temp_path.get_file(), target_path.get_file()) != OK:
		if FileAccess.file_exists(backup_path):
			dir_access.rename(backup_path.get_file(), target_path.get_file())
		DirAccess.remove_absolute(temp_path)
		return false

	if FileAccess.file_exists(backup_path):
		DirAccess.remove_absolute(backup_path)
	return true


func _chunk_int_array(arr: Array[int], chunk_size: int) -> Array:
	var result: Array = []
	for i in range(0, arr.size(), chunk_size):
		result.append(arr.slice(i, i + chunk_size))
	return result
