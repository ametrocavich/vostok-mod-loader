# Launcher window, tab composition, scaling and launch controls. Closing the
# window takes the same path as Launch.

const UI_TAB_HINTS := {
	UI_TAB_MODS: "Higher number loads later and wins when mods share files.\n"
			+ "Required dependencies must be enabled or the mod won't load.",
	UI_TAB_BROWSE: "Download saves a mod into your mods folder; Get saves a pack to the Modpacks tab.\n"
			+ "Switch between Mods and Modpacks at the left; the source menu picks the mod site.",
	UI_TAB_MODPACKS: "Apply switches you to the pack's mods and settings; Unload brings your previous setup back.\n"
			+ "Find more packs under Browse > Modpacks.",
}

# Named for ModWorkshop, its first user; players' caches already live here.
const UI_CACHE_DIR := "user://mws_cache"

# Read from config on every call so a reopened launcher sees a change.
func _ui_scale_setting() -> float:
	var cfg := ConfigFile.new()
	if _ui_cfg_load(cfg) != OK:
		return 1.0
	return clampf(float(cfg.get_value("settings", "ui_scale", 1.0)), 1.0, 2.0)

func _apply_ui_scale(win: Window, ui_scale: float) -> void:
	win.content_scale_factor = ui_scale
	var want := Vector2i(roundi(960.0 * ui_scale), roundi(640.0 * ui_scale))
	var want_min := Vector2i(roundi(640.0 * ui_scale), roundi(420.0 * ui_scale))
	# Clamped to the area so the Launch bar stays on screen; min_size must not
	# exceed size or Godot rejects the pair.
	var area := _window_area(win).size
	if area.x > 0 and area.y > 0:
		want.x = mini(want.x, maxi(320, area.x - 40))
		want.y = mini(want.y, maxi(240, area.y - 40))
	want_min.x = mini(want_min.x, want.x)
	want_min.y = mini(want_min.y, want.y)
	# min_size goes first, or the old minimum clamps a shrink back up.
	win.min_size = Vector2i.ZERO
	win.size = want
	win.min_size = want_min
	# A resize grows from the top-left corner and can push the Launch bar off screen.
	if win.is_inside_tree():
		win.move_to_center()

# In the units of win.position: embedded, the root viewport (RTV's canvas_items
# stretch keeps it at a 1920x1080 base); as an OS window, the usable screen.
func _window_area(win: Window) -> Rect2i:
	if get_tree().root.gui_embed_subwindows:
		return Rect2i(Vector2i.ZERO, Vector2i(get_tree().root.get_visible_rect().size))
	return DisplayServer.screen_get_usable_rect(win.current_screen)

# The mouse in the same units: DisplayServer reports screen pixels, twice the
# viewport's units for an embedded window on a 4K screen.
func _pointer_pos(win: Window) -> Vector2:
	if get_tree().root.gui_embed_subwindows:
		return get_tree().root.get_mouse_position()
	return Vector2(DisplayServer.mouse_get_position())

# The sentinel makes the next launch skip the loader and _ready clears it. No
# _save_ui_config here: it would rewrite the active profile from memory.
func _launch_vanilla_once(win: Window) -> void:
	_log_info("[LaunchVanilla] User triggered one-shot vanilla launch")
	var sentinel := _static_exe_dir().path_join(DISABLED_ONCE_FILE)
	var f := FileAccess.open(sentinel, FileAccess.WRITE)
	if f == null:
		_log_warning("[LaunchVanilla] Could not write sentinel at %s -- aborting" % sentinel)
		_show_error_dialog("Could not launch vanilla",
			"Could not write " + sentinel + "\n\nCheck the game folder's permissions and try again.")
		return
	f.store_string("Launch Vanilla -- this file is auto-cleared on next launch")
	f.close()
	var log_lines := PackedStringArray()
	_static_force_vanilla_state("UI Launch Vanilla button", log_lines)
	for line in log_lines:
		_log_info(line)
	_mods_meta_sidecar_save()
	win.queue_free()
	_restart_into_pass_1()

func _make_tab_margin() -> MarginContainer:
	var m := MarginContainer.new()
	m.add_theme_constant_override("margin_left", 8)
	m.add_theme_constant_override("margin_right", 8)
	m.add_theme_constant_override("margin_top", 6)
	m.add_theme_constant_override("margin_bottom", 6)
	return m

func show_mod_ui() -> void:
	_crash_notice_cached = false
	var win := _ui_create_window()
	var root := _ui_window_root(win)
	var close_btn := _ui_build_header(root, win)

	var tabs := TabContainer.new()
	tabs.size_flags_vertical = Control.SIZE_EXPAND_FILL
	root.add_child(tabs)

	root.add_child(HSeparator.new())
	var launch_btn := _ui_build_bottom_bar(root, win)

	win.close_requested.connect(func(): launch_btn.pressed.emit())
	close_btn.pressed.connect(func(): launch_btn.pressed.emit())
	# After the bottom bar: _wire_hint needs _ui_hint_label.
	_wire_hint(close_btn, "Close the launcher and launch the game (same as Launch).")

	_check_modloader_update_async()

	_ui_add_tabs(tabs)
	refresh_launch_button_label()

	await launch_btn.pressed
	_mods_meta_sidecar_save()
	_ui_reset()
	win.queue_free()

func _ui_reset() -> void:
	_ui_window = null
	_ui_hint_label = null
	_ui_hint_default = ""
	_ui_launch_btn = null
	_ui_update_alert_btn = null
	_ui_mods_scroll = null
	_ui_modpacks_scroll = null
	# The response cache is per session; disk thumbnails have immutable keys and stay.
	_host_cache.clear()
	_mods_meta_nodes.clear()

func _ui_create_window() -> Window:
	var win := Window.new()
	win.title = "Road to Vostok -- Mod Loader"
	win.borderless = true
	# Separate OS windows would strand behind the always_on_top launcher.
	win.gui_embed_subwindows = true
	# Not scaled by screen DPI: RTV's canvas_items stretch already scales the
	# launcher, and a DPI factor on top is unusably large on 4K.
	_apply_ui_scale(win, _ui_scale_setting())
	win.always_on_top = true
	# Clicks beside the launcher could start the game from the main menu while the
	# loader waits; embedded windows get input before any canvas layer.
	var shield_layer := CanvasLayer.new()
	shield_layer.layer = 128
	var shield := Control.new()
	shield.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	shield.mouse_filter = Control.MOUSE_FILTER_STOP
	shield_layer.add_child(shield)
	get_tree().root.add_child(shield_layer)
	# At shutdown the root can free the layer first.
	win.tree_exiting.connect(func():
		if is_instance_valid(shield_layer):
			shield_layer.queue_free()
	)
	get_tree().root.add_child(win)
	win.popup_centered()
	_ui_window = win

	var win_style := _make_box(COL_BG)
	win.add_theme_stylebox_override("panel",                    win_style)
	win.add_theme_stylebox_override("embedded_border",          win_style.duplicate())
	win.add_theme_stylebox_override("embedded_unfocused_border", win_style.duplicate())

	var bg := Panel.new()
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	bg.add_theme_stylebox_override("panel", _make_box(Color(0.0, 0.0, 0.0, 1.0), COL_BORDER))
	win.add_child(bg)

	# On the Window itself so child Windows (popups, dialogs) inherit it.
	win.theme = make_dark_theme()
	return win

func _ui_window_root(win: Window) -> VBoxContainer:
	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", SP_L)
	margin.add_theme_constant_override("margin_right", SP_L)
	margin.add_theme_constant_override("margin_top", SP_M)
	margin.add_theme_constant_override("margin_bottom", SP_L)
	margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	margin.theme = win.theme
	win.add_child(margin)

	var root := VBoxContainer.new()
	root.add_theme_constant_override("separation", SP_M)
	margin.add_child(root)
	return root

func _ui_build_header(root: VBoxContainer, win: Window) -> Button:
	var header_row := _make_header_plate(root, "ROAD TO VOSTOK -- MOD LOADER", FS_TITLE)
	var header := header_row.get_parent() as PanelContainer

	var alert := LinkButton.new()
	alert.text = "v" + MODLOADER_VERSION
	alert.underline = LinkButton.UNDERLINE_MODE_ON_HOVER
	alert.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	alert.add_theme_font_size_override("font_size", FS_META)
	alert.add_theme_color_override("font_color", COL_TEXT_DIM)
	alert.add_theme_color_override("font_hover_color", COL_TEXT)
	alert.pressed.connect(func(): OS.shell_open(_modloader_release_page_url()))
	header_row.add_child(alert)
	_ui_update_alert_btn = alert

	var header_spacer := Control.new()
	header_spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	# A spacer that took mouse events would kill the header drag.
	header_spacer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	header_row.add_child(header_spacer)

	var close_btn := Button.new()
	close_btn.flat = true
	close_btn.icon = _make_close_icon(COL_TEXT_DIM)
	close_btn.custom_minimum_size = Vector2(ICON_BTN_W, ICON_BTN_W)
	close_btn.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	header_row.add_child(close_btn)

	# Absolute pointer positions: ev.relative self-cancels while the window moves.
	var drag := {"on": false, "grab": Vector2.ZERO}
	header.gui_input.connect(func(ev: InputEvent):
		if ev is InputEventMouseButton and ev.button_index == MOUSE_BUTTON_LEFT:
			drag["on"] = ev.pressed
			if ev.pressed:
				drag["grab"] = _pointer_pos(win) - Vector2(win.position)
		elif ev is InputEventMouseMotion and drag["on"]:
			var pos := Vector2i(_pointer_pos(win) - drag["grab"])
			var area := _window_area(win)
			var scale: float = maxf(win.content_scale_factor, 1.0)
			var grab_margin := mini(int(120 * scale), win.size.x)
			var header_height := mini(int(48 * scale), win.size.y)
			pos.x = clampi(pos.x, area.position.x - win.size.x + grab_margin, area.end.x - grab_margin)
			pos.y = clampi(pos.y, area.position.y, area.end.y - header_height)
			win.position = pos
	)
	return close_btn

func _ui_build_bottom_bar(root: VBoxContainer, win: Window) -> Button:
	var bottom := HBoxContainer.new()
	bottom.add_theme_constant_override("separation", SP_M)
	root.add_child(bottom)

	_ui_hint_default = UI_TAB_HINTS[UI_TAB_MODS]
	var hint := _make_label(_ui_hint_default, COL_TEXT_DIM, FS_BODY)
	hint.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	bottom.add_child(hint)
	_ui_hint_label = hint

	var launch_btn := Button.new()
	launch_btn.custom_minimum_size = Vector2(160, 36)
	style_primary_button(launch_btn)

	var bar_gap := Control.new()
	bar_gap.custom_minimum_size.x = SP_XL
	bottom.add_child(bar_gap)

	var vanilla_btn := Button.new()
	vanilla_btn.text = "Launch vanilla"
	vanilla_btn.custom_minimum_size = Vector2(90, 36)
	vanilla_btn.pressed.connect(func(): _launch_vanilla_once(win))
	bottom.add_child(vanilla_btn)
	_wire_hint(vanilla_btn, "Launch without mods for this session. Restarts the game.")

	bottom.add_child(launch_btn)
	_ui_launch_btn = launch_btn
	if _boot_complete:
		_wire_hint(launch_btn, "Back to the game. It restarts only when what loads has changed.")
	else:
		_wire_hint(launch_btn, "Launch the game with the active profile's mods. Restarts the game.")
	return launch_btn

# Each tab is found by its node name (UI_TAB_*): the in-place rebuilds and the
# tab_changed listener match on it, and a mismatch leaves the tab stale silently.
func _ui_add_tabs(tabs: TabContainer) -> void:
	var mods_tab := build_mods_tab(tabs)
	mods_tab.name = UI_TAB_MODS
	tabs.add_child(mods_tab)

	# Built first so a remembered Modpacks kind in Browse reuses its scan of mods/.
	var modpacks_tab := build_modpacks_tab(tabs)
	modpacks_tab.name = UI_TAB_MODPACKS
	_packs_scan_fresh = true
	var browse_tab := build_browse_tab(tabs)
	_packs_scan_fresh = false
	browse_tab.name = UI_TAB_BROWSE
	tabs.add_child(browse_tab)
	tabs.add_child(modpacks_tab)

	tabs.tab_changed.connect(func(idx: int):
		# A re-entrant tab_changed mid-rebuild would corrupt the tree.
		if _rebuilding_tab_in_place:
			return
		var ctrl := tabs.get_tab_control(idx)
		if ctrl == null:
			return
		_ui_hint_default = UI_TAB_HINTS[str(ctrl.name)]
		if is_instance_valid(_ui_hint_label):
			_ui_hint_label.text = _ui_hint_default
		if ctrl.name == UI_TAB_MODPACKS:
			_rebuild_modpacks_tab(tabs)
		elif ctrl.name == UI_TAB_BROWSE:
			_on_browse_selected(ctrl)
	)

func _rebuild_tab_in_place(tabs: TabContainer, tab_name: String, builder: Callable, scroll_of: Callable) -> bool:
	var old := tabs.get_node_or_null(tab_name)
	if old == null:
		return false
	_rebuilding_tab_in_place = true
	var saved_scroll := 0
	var old_scroll: Variant = scroll_of.call()
	if is_instance_valid(old_scroll):
		saved_scroll = (old_scroll as ScrollContainer).scroll_vertical
	var idx := old.get_index()
	var current_tab_name := str(tabs.get_tab_control(tabs.current_tab).name)
	tabs.remove_child(old)
	old.queue_free()
	var new_tab: Control = builder.call(tabs)
	new_tab.name = tab_name
	tabs.add_child(new_tab)
	tabs.move_child(new_tab, idx)
	for i in range(tabs.get_tab_count()):
		if tabs.get_tab_control(i).name == current_tab_name:
			tabs.current_tab = i
			break
	_rebuilding_tab_in_place = false
	if saved_scroll > 0:
		_restore_scroll_next_frame(scroll_of, saved_scroll)
	return true

# One frame later: scroll_vertical set before layout clamps to zero.
func _restore_scroll_next_frame(scroll_of: Callable, saved_scroll: int) -> void:
	await get_tree().process_frame
	var scroll: Variant = scroll_of.call()
	if is_instance_valid(scroll):
		(scroll as ScrollContainer).scroll_vertical = saved_scroll

func refresh_launch_button_label() -> void:
	if not is_instance_valid(_ui_launch_btn):
		return
	# Counts what will load, not what is checked: with everything blocked,
	# "Launch modded" would deliver vanilla.
	var pick := _loadable_enabled_entries()
	var loadable_count: int = (pick["loadable"] as Array).size()
	var enabled_count := int(pick["enabled_count"])
	if _boot_complete:
		# Reopened from the main menu: the game restarts only when what loads changed.
		_ui_launch_btn.text = "Apply and restart" if _post_boot_restart_needed() else "Back to game"
	elif loadable_count > 0:
		_ui_launch_btn.text = "Launch modded"
	elif enabled_count > 0:
		_ui_launch_btn.text = "Launch unmodded (%d blocked)" % enabled_count
	else:
		_ui_launch_btn.text = "Launch"
