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
		# Without this the button just looks dead: the window stays open and
		# nothing else changes.
		_show_error_dialog("Could not launch vanilla",
			"Could not write " + sentinel + "\n\nCheck the game folder's permissions and try again.")
		return
	var log_lines := PackedStringArray()
	_static_force_vanilla_state("UI Launch Vanilla button", log_lines)
	for line in log_lines:
		_log_info(line)
	if is_instance_valid(win):
		win.queue_free()
	# Strip --modloader-restart so the relaunch is a clean Pass 1, not a Pass 2
	# that would expect pass state we just deleted.
	_modloader_restart(true)

# Tear down and rebuild the Mods tab in place. Called whenever profile state
# changes (switch, create, delete) or Developer Mode toggles, so rows and the
# profile bar reflect fresh _ui_mod_entries + _active_profile state.
# Preserves the user's current tab so a Browse-row enable toggle doesn't
# yank them onto the Mods tab mid-flow.
func _rebuild_mods_tab(tabs: TabContainer) -> void:
	var old := tabs.get_node_or_null(UI_TAB_MODS)
	if old == null:
		return
	_rebuilding_tab_in_place = true
	# Carry the list scroll position across the teardown -- a rebuild from a
	# checkbox halfway down a long list must not snap the view to the top.
	var saved_scroll := 0
	if is_instance_valid(_ui_mods_scroll):
		saved_scroll = _ui_mods_scroll.scroll_vertical
	var idx := old.get_index()
	# Capture which tab the user was on by NAME, since remove_child below
	# shifts sibling indices and tabs.current_tab can drift in the meantime.
	var current_tab_node := tabs.get_tab_control(tabs.current_tab) if tabs.get_tab_count() > 0 else null
	var current_tab_name := str(current_tab_node.name) if current_tab_node != null else ""
	tabs.remove_child(old)
	old.queue_free()
	var new_tab := build_mods_tab(tabs)
	new_tab.name = UI_TAB_MODS
	tabs.add_child(new_tab)
	tabs.move_child(new_tab, idx)
	# Restore by name. If the previous tab was Mods itself, we land back on
	# the rebuilt one. If it was Browse/Modpacks/Updates, the user stays
	# where they were.
	for i in range(tabs.get_tab_count()):
		var ctrl := tabs.get_tab_control(i)
		if ctrl != null and ctrl.name == current_tab_name:
			tabs.current_tab = i
			break
	_rebuilding_tab_in_place = false
	# Profile switches / dev-mode toggles change enable state without
	# hitting the per-row checkbox handler.
	refresh_launch_button_label()
	if saved_scroll > 0:
		_restore_mods_scroll(saved_scroll)

# Restore one frame later: the fresh rows haven't been laid out yet when
# _rebuild_mods_tab returns, so setting scroll_vertical immediately clamps
# against a zero-height list and lands back at the top.
func _restore_mods_scroll(saved_scroll: int) -> void:
	await get_tree().process_frame
	if is_instance_valid(_ui_mods_scroll):
		_ui_mods_scroll.scroll_vertical = saved_scroll

# Swap the Updates tab for a freshly built one. build_updates_tab snapshots
# _ui_mod_entries at build time and never updates in place, so a mod updated via
# the Mods-tab badge (renamed archive -> new version-embedding profile_key) or
# installed mid-session (Browse Get / modpack apply) leaves this tab showing
# stale rows: a wrong "update available" flag whose Download then targets a
# vanished file. Rebuilding on tab-show re-reads live entries. Mirrors
# _rebuild_mods_tab's tab-swap and preserves the user's current tab by name.
func _rebuild_updates_tab(tabs: TabContainer) -> void:
	var old := tabs.get_node_or_null(UI_TAB_UPDATES)
	if old == null:
		return
	# Carry the list scroll across the teardown (same pattern as
	# _rebuild_mods_tab) -- without this, switching away and back snapped a
	# long list back to the top.
	var saved_scroll := 0
	if is_instance_valid(_ui_updates_scroll):
		saved_scroll = _ui_updates_scroll.scroll_vertical
	_rebuilding_tab_in_place = true
	var idx := old.get_index()
	var current_tab_node := tabs.get_tab_control(tabs.current_tab) if tabs.get_tab_count() > 0 else null
	var current_tab_name := str(current_tab_node.name) if current_tab_node != null else ""
	tabs.remove_child(old)
	old.queue_free()
	var new_tab := build_updates_tab()
	new_tab.name = UI_TAB_UPDATES
	tabs.add_child(new_tab)
	tabs.move_child(new_tab, idx)
	for i in range(tabs.get_tab_count()):
		var ctrl := tabs.get_tab_control(i)
		if ctrl != null and ctrl.name == current_tab_name:
			tabs.current_tab = i
			break
	_rebuilding_tab_in_place = false
	if saved_scroll > 0:
		_restore_updates_scroll(saved_scroll)

# Restore one frame later: the fresh rows haven't been laid out yet when
# _rebuild_updates_tab returns, so setting scroll_vertical immediately clamps
# against a zero-height list and lands back at the top (same as
# _restore_mods_scroll).
func _restore_updates_scroll(saved_scroll: int) -> void:
	await get_tree().process_frame
	if is_instance_valid(_ui_updates_scroll):
		_ui_updates_scroll.scroll_vertical = saved_scroll

# Modpack-apply failure summary with per-mod rows. Each failure shows the
# profile_key + reason + an "Open MWS page" button (when an mws_id is
# known, which is every case except sourceless legacy modpacks). The
# bottom bar has a "Retry failed" button that re-runs only the failed
# downloads, plus the auto-OK Close. Replaces the simple text dialog
# that handled this before -- a flat string can't fit 30+ lines and
# offers no recovery action.
func show_mod_ui() -> void:
	var win := Window.new()
	win.title = "Road to Vostok -- Mod Loader"
	# Borderless: drop Godot's native title bar, which duplicated the in-panel
	# header plate ("ROAD TO VOSTOK -- MOD LOADER") and stacked a second title +
	# close X above it. The plate below carries the title, and the close X moves
	# into the plate (built there). Header drag is added by hand since a
	# borderless Window has no bar to grab. Title string kept for taskbar/alt-tab.
	win.borderless = true
	# Embed sub-windows (tooltips, dropdowns, dialogs) INSIDE this window's
	# viewport instead of as separate OS windows. Separate windows aren't
	# always_on_top, so they stranded behind this always_on_top launcher -- the
	# tooltip-behind-window bug, and the reason dropdowns needed always_on_top
	# hacks. Embedded, they render on top of the launcher content and can't fall
	# behind it, fixing every tooltip at once.
	win.gui_embed_subwindows = true
	# UI scale. Do NOT derive this from screen DPI. The launcher is a subwindow
	# of the game's root viewport, and RTV's project.godot sets
	# stretch/mode="canvas_items" against a 1920x1080 base -- so the root
	# ALREADY scales everything we draw by (window size / 1920x1080). A
	# DPI-derived factor multiplies on top of that: a 4K display gave roughly
	# 2x from the root and another 1.7x from DPI, and the launcher came out
	# unusably large. Deriving it from DPI also can't be right for both a dense
	# 1080p laptop and a 4K desktop, because the root scale differs between
	# them in the opposite direction.
	#
	# So: 1.0 by default (identical to 3.3.0 proportions), with an explicit
	# user setting for anyone who wants it bigger. Readability at 1.0 is the
	# job of the type scale and the scrollbar metrics, not of a global zoom.
	_apply_ui_scale(win, _ui_scale_setting())
	win.wrap_controls = false
	win.always_on_top = true
	win.transparent = true
	win.transparent_bg = true
	get_tree().root.add_child(win)
	win.popup_centered()
	# Stash for dialogs triggered by profile-bar controls. Cleared on close.
	_ui_window = win

	# Kill the default Godot gray on the Window itself (embedded_border is the
	# stylebox that paints the window's own background area).
	var win_style := StyleBoxFlat.new()
	win_style.bg_color = COL_BG
	win.add_theme_stylebox_override("panel",                    win_style)
	win.add_theme_stylebox_override("embedded_border",          win_style.duplicate())
	win.add_theme_stylebox_override("embedded_unfocused_border", win_style.duplicate())

	# Solid dark background so Godot's default gray theme doesn't show through.
	# The 0.92-alpha black is a near-opaque scrim over the window floor, not a
	# surface token; the outline snaps to COL_BORDER (was pure white glare).
	# Was 0.6, but at 40% game bleed-through the text got hard to read over
	# bright scenes -- 0.92 keeps only a faint hint of the game behind and is
	# easier on OLED (less bright content under static UI).
	var bg := Panel.new()
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var bg_s := StyleBoxFlat.new()
	bg_s.bg_color = Color(0.0, 0.0, 0.0, 0.92)
	bg_s.border_color = COL_BORDER
	_sb_border(bg_s)
	bg.add_theme_stylebox_override("panel", bg_s)
	win.add_child(bg)

	# Assign the dark theme on the Window itself so child Windows (OptionButton
	# popup + dialogs spawned from the profile bar) inherit it via the scene
	# tree. Setting it only on the MarginContainer misses sub-Windows.
	var dark_theme := make_dark_theme()
	win.theme = dark_theme

	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", SP_L)
	margin.add_theme_constant_override("margin_right", SP_L)
	margin.add_theme_constant_override("margin_top", SP_M)
	margin.add_theme_constant_override("margin_bottom", SP_L)
	margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	margin.theme = dark_theme
	win.add_child(margin)

	var root := VBoxContainer.new()
	root.add_theme_constant_override("separation", SP_M)
	margin.add_child(root)

	# Equipment plate header: ALL-CAPS title with the version beside it on a
	# COL_SURFACE strip with a 1px amber-dim bottom border. The one FS_TITLE
	# use in the UI (spec section 6).
	var header := PanelContainer.new()
	var header_s := StyleBoxFlat.new()
	header_s.bg_color = COL_SURFACE
	header_s.border_color = COL_AMBER_DIM
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

	# Version / self-update alert beside the title. Default state shows the
	# installed version in dim meta text; the _check_modloader_update_async
	# coroutine flips it amber and rewrites the text when ModWorkshop reports
	# a newer release. Click opens the mod page in the system browser
	# regardless of state.
	var alert := LinkButton.new()
	alert.text = "v" + MODLOADER_VERSION
	alert.underline = LinkButton.UNDERLINE_MODE_ON_HOVER
	alert.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	alert.add_theme_font_size_override("font_size", FS_META)
	alert.add_theme_color_override("font_color", COL_TEXT_DIM)
	alert.add_theme_color_override("font_hover_color", COL_TEXT)
	alert.pressed.connect(func():
		OS.shell_open(MODWORKSHOP_PAGE_URL_TEMPLATE % str(MODLOADER_MODWORKSHOP_ID))
	)
	header_row.add_child(alert)
	_ui_update_alert_btn = alert

	# Push the close control to the far right of the plate.
	var header_spacer := Control.new()
	header_spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	# Pure layout -- must not swallow mouse events, or it kills header drag over
	# the widest stretch of the plate (plain Control defaults to STOP).
	header_spacer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	header_row.add_child(header_spacer)

	# Close (X) lives in the plate now the window is borderless. Wired below to
	# the same path as the old native close (X == Launch, by design), after
	# launch_btn is built.
	var close_btn := Button.new()
	close_btn.flat = true
	close_btn.icon = _make_close_icon(COL_TEXT_DIM)
	close_btn.custom_minimum_size = Vector2(28, 28)
	close_btn.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	header_row.add_child(close_btn)

	# Borderless windows have no bar to grab, so let the header plate drag the
	# whole window. Labels + the expanding spacer ignore mouse input so events
	# fall through to the header; the version link and close button keep clicks.
	# Anchor the grab offset and track ABSOLUTE mouse position: using ev.relative
	# would self-cancel (moving the window shifts local coords back) and trail
	# the cursor at half speed with jitter.
	var drag := {"on": false, "grab": Vector2i.ZERO}
	header.gui_input.connect(func(ev: InputEvent):
		if ev is InputEventMouseButton and ev.button_index == MOUSE_BUTTON_LEFT:
			drag["on"] = ev.pressed
			if ev.pressed:
				drag["grab"] = Vector2i(ev.global_position)
		elif ev is InputEventMouseMotion and drag["on"]:
			win.position = DisplayServer.mouse_get_position() - drag["grab"]
	)

	var tabs := TabContainer.new()
	tabs.size_flags_vertical = Control.SIZE_EXPAND_FILL
	root.add_child(tabs)

	root.add_child(HSeparator.new())

	# Bottom bar: instructions + launch button
	var bottom := HBoxContainer.new()
	bottom.add_theme_constant_override("separation", SP_M)
	root.add_child(bottom)

	var hint := Label.new()
	hint.text = "Higher number loads later and wins when mods share files.\n" \
			+ "Required dependencies must be enabled or the mod won't load."
	hint.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	hint.add_theme_font_size_override("font_size", FS_BODY)
	hint.add_theme_color_override("font_color", COL_TEXT_DIM)
	bottom.add_child(hint)
	# Expose for _wire_hint so toolbar/dropdown hovers can temporarily repurpose
	# this label as a status-line substitute for broken Godot tooltips.
	_ui_hint_label = hint

	var launch_btn := Button.new()
	# Text is set by refresh_launch_button_label below (called after tabs
	# build), which picks "Launch modded" or "Launch" based on enabled
	# state. Starting empty avoids a one-frame placeholder flash.
	launch_btn.text = ""
	launch_btn.custom_minimum_size = Vector2(160, 36)
	# PRIMARY voice: the one amber-emphasis action on this surface. Boxes,
	# margins and the focus ring come from the theme.
	style_primary_button(launch_btn)

	# The version/self-update alert lives in the header plate (built above);
	# the bottom bar keeps only the hint and the action cluster.

	# Visual separator between the informational hint and the action cluster
	# (Launch vanilla + Launch) so the eye keeps the grouping.
	var bar_gap := Control.new()
	bar_gap.custom_minimum_size.x = SP_XL
	bottom.add_child(bar_gap)

	# Vanilla: one-shot bypass via sentinel + restart. Bare theme voice and
	# sized smaller than the primary Launch button so the visual hierarchy
	# reads correctly -- Launch is the common action, vanilla is the
	# diagnostic one. Hover hint communicates the restart.
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

	# Closing the window with X should behave the same as clicking Launch.
	win.close_requested.connect(func(): launch_btn.pressed.emit())
	# The in-plate X does exactly what the old native title-bar X did.
	close_btn.pressed.connect(func(): launch_btn.pressed.emit())
	# Status-line hint, kept for the launcher's consistent hover-hint UX.
	# (Historically raw tooltips stranded behind this always_on_top window;
	# win.gui_embed_subwindows now embeds tooltips so that's fixed -- the hint is
	# a deliberate style choice, not a workaround.) _wire_hint needs
	# _ui_hint_label, which the bottom bar sets above -- so wire it here, after.
	_wire_hint(close_btn, "Close the launcher and launch the game (same as Launch).")

	# Fire-and-forget self-update check. Updates _ui_update_alert_btn and may
	# pop the one-shot dialog when the API returns. Guards on
	# is_instance_valid so a launcher close mid-flight is harmless.
	_check_modloader_update_async()

	# --- Tab contract ---------------------------------------------------
	# Each tab is built by a build_*_tab(tabs) -> Control function and added
	# here under a stable node name (UI_TAB_*). That name is load-bearing:
	# TabContainer shows it as the tab title, the in-place rebuild helpers
	# (_rebuild_mods_tab, _rebuild_modpacks_tab) find the tab via
	# get_node_or_null(name), and the tab_changed listener below matches on
	# it. (_rebuild_mods_tab also restores the user's current tab by name;
	# _rebuild_modpacks_tab restores it by index.)
	# To add a tab: (1) write build_x_tab(tabs) returning its root Control,
	# (2) add + name it below, (3) if other surfaces can change its state,
	# add a _rebuild_x_tab helper (copy the recursion-guard pattern from
	# _rebuild_modpacks_tab) and/or an on-show refresh via the tab_changed
	# listener below. build_updates_tab takes no tabs arg only because it
	# never rebuilds in place; prefer the (tabs) signature for new tabs.

	var mods_tab := build_mods_tab(tabs)
	mods_tab.name = UI_TAB_MODS
	tabs.add_child(mods_tab)

	var browse_tab := build_browse_tab(tabs)
	browse_tab.name = UI_TAB_BROWSE
	tabs.add_child(browse_tab)

	var modpacks_tab := build_modpacks_tab(tabs)
	modpacks_tab.name = UI_TAB_MODPACKS
	tabs.add_child(modpacks_tab)

	var updates_tab := build_updates_tab()
	updates_tab.name = UI_TAB_UPDATES
	tabs.add_child(updates_tab)

	# Refresh the Modpacks tab whenever the user switches to it. State can
	# change behind the tab's back -- e.g. banner Unload from Mods tab --
	# and without this listener the Modpacks tab keeps showing stale
	# ACTIVE/Apply state until UI close/reopen. _rebuild_modpacks_tab now
	# preserves current_tab and short-circuits recursion via the
	# _rebuilding_modpacks_tab flag, so the rebuild-during-tab-show that
	# broke things in the earlier revision no longer applies.
	tabs.tab_changed.connect(func(idx: int):
		# Bail on re-entrant tab_changed fired mid-rebuild. An in-place rebuild
		# does remove_child/add_child/move_child, each of which re-fires
		# tab_changed while the TabContainer is busy; dispatching another rebuild
		# here corrupts the tree (nodes freed mid-op -> tabs vanish).
		if _rebuilding_tab_in_place:
			return
		var ctrl := tabs.get_tab_control(idx)
		if ctrl != null and ctrl.name == UI_TAB_MODPACKS:
			_rebuild_modpacks_tab(tabs)
		# Browse rows bake profile name + enabled state at render time and
		# the tab never rebuilds, so sync them in place on show (profile
		# switch / modpack apply / Mods-tab edits happen behind its back).
		elif ctrl != null and ctrl.name == UI_TAB_BROWSE:
			_refresh_browse_installed_rows(ctrl)
		# The Updates tab is a build-time snapshot of the mod list; rebuild it
		# on show so mid-session updates/installs aren't shown as stale rows.
		elif ctrl != null and ctrl.name == UI_TAB_UPDATES:
			_rebuild_updates_tab(tabs)
		# An Updates-tab check may have changed the badge state while the Mods
		# tab was off-screen; rebuild once so the per-row badges appear.
		elif ctrl != null and ctrl.name == UI_TAB_MODS and _mods_badges_dirty:
			_mods_badges_dirty = false
			_rebuild_mods_tab(tabs)
	)

	refresh_launch_button_label()

	# Launch loop. If any enabled mod has the scanner's RED risk_level,
	# show a confirmation dialog before proceeding. Cancel returns the
	# user to the launcher so they can disable the flagged mod or
	# reconsider; confirm proceeds. No gate when no red mods are enabled.
	while true:
		await launch_btn.pressed
		var red_mods := _enabled_red_mods()
		if red_mods.is_empty():
			break
		var proceed: bool = await _confirm_red_launch(red_mods)
		if proceed:
			break
		# else: loop and wait for Launch again
	_ui_window = null
	_ui_hint_label = null
	_ui_launch_btn = null
	_ui_update_alert_btn = null
	_ui_mods_scroll = null
	_ui_modpacks_scroll = null
	_ui_updates_scroll = null
	_ui_updates_check_btn = null
	# Drop the Browse-tab API response cache. It's a session optimization,
	# not durable state -- the modloader autoload survives across launcher
	# open/close (rare in practice) and we don't want the dict to accumulate
	# across sessions. Disk-cached thumbnails stay (immutable storage keys
	# are valid indefinitely; they're how we make repeat browsing snappy).
	# In-flight HTTPRequests (list + thumbnail fetches) are parented to self
	# and self-queue_free on completion, so no node-leak cleanup is needed.
	_mws_cache.clear()
	# Mods-tab row nodes die with the window; drop the mapping so a meta fetch
	# resolving after close paints nothing (it still memoizes + persists).
	_mods_meta_nodes.clear()
	win.queue_free()

# Launch button label reflects whether anything will load. Both this and
# the bottom-bar Launch Vanilla button restart the game, so the "(Restart)"
# suffix added no signal -- dropped to avoid noise.
func refresh_launch_button_label() -> void:
	if not is_instance_valid(_ui_launch_btn):
		return
	# Count what will actually LOAD, not what's checked -- with every enabled
	# mod dependency-blocked, "Launch modded" would promise a modded
	# session and deliver vanilla.
	var pick := _loadable_enabled_entries()
	var loadable_count: int = (pick["loadable"] as Array).size()
	var enabled_count := int(pick["enabled_count"])
	if loadable_count > 0:
		_ui_launch_btn.text = "Launch modded"
	elif enabled_count > 0:
		_ui_launch_btn.text = "Launch unmodded (%d blocked)" % enabled_count
	else:
		_ui_launch_btn.text = "Launch"

