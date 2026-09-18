## Launcher window, tab composition, scaling and launch controls.
## Closing the window follows the same path as Launch.
## Profile persistence is in profiles.gd; tab behavior is in ui_<tab>.gd.

# Bottom-bar hint for each tab; _wire_hint swaps it out while a control is hovered.
const UI_HINT_MODS := "Higher number loads later and wins when mods share files.\n" \
		+ "Required dependencies must be enabled or the mod won't load."
const UI_HINT_BROWSE := "Download saves a mod into your mods folder. Tick its box to enable it in the active profile.\n" \
		+ "Use the source menu to switch between VostokMods and ModWorkshop."
const UI_HINT_MODPACKS := "Apply switches you to the pack's mods and settings and downloads what is missing.\n" \
		+ "Unload brings your previous setup back."


# Launcher zoom, read from config each call so the reopen path sees changes.
func _ui_scale_setting() -> float:
	var cfg := ConfigFile.new()
	if cfg.load(UI_CONFIG_PATH) != OK:
		return 1.0
	return clampf(float(cfg.get_value("settings", "ui_scale", 1.0)), 1.0, 2.0)

# Apply a launcher zoom: content scale plus matching window size. min_size
# is dropped first so shrinking is not clamped back up by the old minimum.
func _apply_ui_scale(win: Window, ui_scale: float) -> void:
	if not is_instance_valid(win):
		return
	win.content_scale_factor = ui_scale
	var want := Vector2i(roundi(960.0 * ui_scale), roundi(640.0 * ui_scale))
	var want_min := Vector2i(roundi(640.0 * ui_scale), roundi(420.0 * ui_scale))
	# Clamp to the usable display area so the Launch bar stays on-screen;
	# keep min_size <= size or Godot rejects the pair.
	var usable := DisplayServer.screen_get_usable_rect(win.current_screen).size
	if usable.x > 0 and usable.y > 0:
		want.x = mini(want.x, maxi(320, usable.x - 40))
		want.y = mini(want.y, maxi(240, usable.y - 40))
	want_min.x = mini(want_min.x, want.x)
	want_min.y = mini(want_min.y, want.y)
	win.min_size = Vector2i.ZERO
	win.size = want
	win.min_size = want_min

# One-shot vanilla boot: writes DISABLED_ONCE_FILE so the next launch skips
# the loader; _ready clears the sentinel. No _save_ui_config here, which
# would rewrite the active profile's sections from in-memory state.

func _launch_vanilla_once(win: Window) -> void:
	_log_info("[LaunchVanilla] User triggered one-shot vanilla launch")
	var exe_dir := OS.get_executable_path().get_base_dir()
	var sentinel := exe_dir.path_join(DISABLED_ONCE_FILE)
	var f := FileAccess.open(sentinel, FileAccess.WRITE)
	if f != null:
		f.store_string("Launch Vanilla -- this file is auto-cleared on next launch")
		f.close()
	else:
		_log_warning("[LaunchVanilla] Could not write sentinel at %s -- aborting" % sentinel)
		_show_error_dialog("Could not launch vanilla",
			"Could not write " + sentinel + "\n\nCheck the game folder's permissions and try again.")
		return
	var log_lines := PackedStringArray()
	_static_force_vanilla_state("UI Launch Vanilla button", log_lines)
	for line in log_lines:
		_log_info(line)
	if is_instance_valid(win):
		win.queue_free()
	# Strip --modloader-restart so the relaunch is a clean Pass 1.
	_modloader_restart(true)

# The standard 8/8/6/6 outer margin shared by all top-level tab builders.
func _make_tab_margin() -> MarginContainer:
	var m := MarginContainer.new()
	m.add_theme_constant_override("margin_left", 8)
	m.add_theme_constant_override("margin_right", 8)
	m.add_theme_constant_override("margin_top", 6)
	m.add_theme_constant_override("margin_bottom", 6)
	return m



func show_mod_ui() -> void:
	var win := _ui_create_window()
	var root := _ui_window_root(win)
	var close_btn := _ui_build_header(root, win)

	var tabs := TabContainer.new()
	tabs.size_flags_vertical = Control.SIZE_EXPAND_FILL
	root.add_child(tabs)

	root.add_child(HSeparator.new())
	var launch_btn := _ui_build_bottom_bar(root, win)

	# Closing the window with X should behave the same as clicking Launch.
	win.close_requested.connect(func(): launch_btn.pressed.emit())
	close_btn.pressed.connect(func(): launch_btn.pressed.emit())
	# _wire_hint needs _ui_hint_label, which the bottom bar set above.
	_wire_hint(close_btn, "Close the launcher and launch the game (same as Launch).")

	# Fire-and-forget self-update check; guards on is_instance_valid after the await.
	_check_modloader_update_async()

	_ui_add_tabs(tabs)
	refresh_launch_button_label()

	await launch_btn.pressed
	_ui_window = null
	_ui_hint_label = null
	_ui_hint_default = ""
	_ui_launch_btn = null
	_ui_update_alert_btn = null
	_ui_mods_scroll = null
	_ui_modpacks_scroll = null
	# Drop the host API response cache (session-only). Disk-cached thumbnails
	# stay: immutable storage keys are valid indefinitely.
	_host_cache.clear()
	# Row nodes die with the window; a meta fetch resolving after close paints nothing.
	_mods_meta_nodes.clear()
	win.queue_free()


# The borderless, always-on-top launcher Window with its scrim and theme.
func _ui_create_window() -> Window:
	var win := Window.new()
	win.title = "Road to Vostok -- Mod Loader"
	# Borderless: the header plate carries the title, close X and drag. Title kept for alt-tab.
	win.borderless = true
	# Embed sub-windows; separate OS windows strand behind the always_on_top launcher.
	win.gui_embed_subwindows = true
	# UI scale is never derived from screen DPI: RTV's stretch/mode=canvas_items
	# against a 1920x1080 base already scales the launcher with window size, and
	# a DPI factor on top is unusably large on 4K.
	_apply_ui_scale(win, _ui_scale_setting())
	win.wrap_controls = false
	win.always_on_top = true
	get_tree().root.add_child(win)
	win.popup_centered()
	# Stash for dialogs triggered by profile-bar controls. Cleared on close.
	_ui_window = win

	var win_style := StyleBoxFlat.new()
	win_style.bg_color = COL_BG
	win.add_theme_stylebox_override("panel",                    win_style)
	win.add_theme_stylebox_override("embedded_border",          win_style.duplicate())
	win.add_theme_stylebox_override("embedded_unfocused_border", win_style.duplicate())

	# Black floor under the panels, fully opaque: the game showing through only
	# made the text harder to read.
	var bg := Panel.new()
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var bg_s := StyleBoxFlat.new()
	bg_s.bg_color = Color(0.0, 0.0, 0.0, 1.0)
	bg_s.border_color = COL_BORDER
	_sb_border(bg_s)
	bg.add_theme_stylebox_override("panel", bg_s)
	win.add_child(bg)

	# Theme on the Window itself so child Windows (popups, dialogs) inherit it.
	var dark_theme := make_dark_theme()
	win.theme = dark_theme
	return win


# The padded root VBox every launcher section hangs off.
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


# Header plate: title, version link, close button and window drag. Returns
# the close button so the caller can wire it to Launch.
func _ui_build_header(root: VBoxContainer, win: Window) -> Button:
	# Equipment plate header; the one FS_TITLE use in the UI.
	var header := PanelContainer.new()
	var header_s := StyleBoxFlat.new()
	header_s.bg_color = COL_SURFACE
	header_s.border_color = COL_ACCENT_DIM
	header_s.border_width_bottom = 1
	header_s.content_margin_left = SP_L
	header_s.content_margin_right = SP_L
	header_s.content_margin_top = SP_M
	header_s.content_margin_bottom = SP_M
	header.add_theme_stylebox_override("panel", header_s)
	root.add_child(header)
	var header_row := HBoxContainer.new()
	header_row.add_theme_constant_override("separation", SP_M)
	header.add_child(header_row)
	var plate_title := Label.new()
	plate_title.text = "ROAD TO VOSTOK -- MOD LOADER"
	plate_title.add_theme_font_size_override("font_size", FS_TITLE)
	plate_title.add_theme_color_override("font_color", COL_TEXT_HI)
	header_row.add_child(plate_title)

	# Version / self-update alert; _check_modloader_update_async flips it to the
	# accent color when a newer release exists. Click opens the release page.
	var alert := LinkButton.new()
	alert.text = "v" + MODLOADER_VERSION
	alert.underline = LinkButton.UNDERLINE_MODE_ON_HOVER
	alert.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	alert.add_theme_font_size_override("font_size", FS_META)
	alert.add_theme_color_override("font_color", COL_TEXT_DIM)
	alert.add_theme_color_override("font_hover_color", COL_TEXT)
	alert.pressed.connect(func():
		OS.shell_open(_modloader_release_page_url())
	)
	header_row.add_child(alert)
	_ui_update_alert_btn = alert

	var header_spacer := Control.new()
	header_spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	# Must not swallow mouse events or it kills header drag.
	header_spacer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	header_row.add_child(header_spacer)

	# In-plate close (X); wired below to the Launch path (X == Launch).
	var close_btn := Button.new()
	close_btn.flat = true
	close_btn.icon = _make_close_icon(COL_TEXT_DIM)
	close_btn.custom_minimum_size = Vector2(28, 28)
	close_btn.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	header_row.add_child(close_btn)

	# Header plate drags the window. Track absolute mouse position: ev.relative
	# would self-cancel as the window moves and trail the cursor at half speed.
	var drag := {"on": false, "grab": Vector2i.ZERO}
	header.gui_input.connect(func(ev: InputEvent):
		if ev is InputEventMouseButton and ev.button_index == MOUSE_BUTTON_LEFT:
			drag["on"] = ev.pressed
			if ev.pressed:
				# ev.global_position is in Control space (shrunk by content_scale_factor);
				# mouse_get_position() is raw screen pixels.
				drag["grab"] = Vector2i(ev.global_position * win.content_scale_factor)
		elif ev is InputEventMouseMotion and drag["on"]:
			win.position = DisplayServer.mouse_get_position() - drag["grab"]
	)
	return close_btn


# Hint line, Launch vanilla and Launch. Returns the Launch button, which the
# caller awaits.
func _ui_build_bottom_bar(root: VBoxContainer, win: Window) -> Button:
	var bottom := HBoxContainer.new()
	bottom.add_theme_constant_override("separation", SP_M)
	root.add_child(bottom)

	var hint := Label.new()
	hint.text = UI_HINT_MODS
	hint.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	hint.add_theme_font_size_override("font_size", FS_BODY)
	hint.add_theme_color_override("font_color", COL_TEXT_DIM)
	bottom.add_child(hint)
	# Exposed for _wire_hint's hover-hint mechanic.
	_ui_hint_label = hint
	_ui_hint_default = UI_HINT_MODS

	var launch_btn := Button.new()
	# Text set by refresh_launch_button_label after the tabs build; empty avoids a flash.
	launch_btn.text = ""
	launch_btn.custom_minimum_size = Vector2(160, 36)
	style_primary_button(launch_btn)

	var bar_gap := Control.new()
	bar_gap.custom_minimum_size.x = SP_XL
	bottom.add_child(bar_gap)

	# Vanilla: one-shot bypass via sentinel and restart; smaller than Launch.
	var vanilla_btn := Button.new()
	vanilla_btn.text = "Launch vanilla"
	vanilla_btn.custom_minimum_size = Vector2(90, 36)
	var win_for_vanilla := win
	vanilla_btn.pressed.connect(func(): _launch_vanilla_once(win_for_vanilla))
	bottom.add_child(vanilla_btn)
	_wire_hint(vanilla_btn, "Launch without mods for this session. Restarts the game.")

	bottom.add_child(launch_btn)
	_ui_launch_btn = launch_btn
	_wire_hint(launch_btn, "Launch the game with the active profile's mods. Restarts the game.")
	return launch_btn


	# --- Tab contract ---
	# Each tab is built by a build_*_tab(tabs) -> Control function and added
	# under a stable node name (UI_TAB_*). TabContainer shows the name as the
	# tab title, the in-place rebuild helpers find the tab through
	# get_node_or_null(name), and the tab_changed listener below matches on
	# it. To add a tab: build_x_tab(tabs) + a UI_TAB_X const (constants.gd),
	# add and name it below, and add a rebuild or on-show refresh if other
	# surfaces can change its state. A name mismatch fails silently: the
	# rebuild helpers skip and the tab goes stale.
func _ui_add_tabs(tabs: TabContainer) -> void:
	var mods_tab := build_mods_tab(tabs)
	mods_tab.name = UI_TAB_MODS
	tabs.add_child(mods_tab)

	var browse_tab := build_browse_tab(tabs)
	browse_tab.name = UI_TAB_BROWSE
	tabs.add_child(browse_tab)

	var modpacks_tab := build_modpacks_tab(tabs)
	modpacks_tab.name = UI_TAB_MODPACKS
	tabs.add_child(modpacks_tab)

	# Refresh tabs on show: state can change behind a tab's back.
	tabs.tab_changed.connect(func(idx: int):
		# Re-entrant tab_changed fired mid-rebuild; another rebuild here corrupts the tree.
		if _rebuilding_tab_in_place:
			return
		var ctrl := tabs.get_tab_control(idx)
		if ctrl == null:
			return
		# The bottom-bar hint describes the tab on screen.
		_ui_hint_default = UI_HINT_MODS
		if ctrl.name == UI_TAB_BROWSE:
			_ui_hint_default = UI_HINT_BROWSE
		elif ctrl.name == UI_TAB_MODPACKS:
			_ui_hint_default = UI_HINT_MODPACKS
		if is_instance_valid(_ui_hint_label):
			_ui_hint_label.text = _ui_hint_default
		if ctrl.name == UI_TAB_MODPACKS:
			_rebuild_modpacks_tab(tabs)
		# Browse rows bake profile state at render time and never rebuild; sync in place.
		elif ctrl.name == UI_TAB_BROWSE:
			_refresh_browse_installed_rows(ctrl)
	)

# Launch button label reflects whether anything will load.
func refresh_launch_button_label() -> void:
	if not is_instance_valid(_ui_launch_btn):
		return
	# Count what will actually load, not what's checked: with everything
	# dependency-blocked, "Launch modded" would deliver vanilla.
	var pick := _loadable_enabled_entries()
	var loadable_count: int = (pick["loadable"] as Array).size()
	var enabled_count := int(pick["enabled_count"])
	if loadable_count > 0:
		_ui_launch_btn.text = "Launch modded"
	elif enabled_count > 0:
		_ui_launch_btn.text = "Launch unmodded (%d blocked)" % enabled_count
	else:
		_ui_launch_btn.text = "Launch"
