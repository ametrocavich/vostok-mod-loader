## ----- ui_mods.gd -----
## Mods-tab composition, filters, toolbar and action dialogs.
## Row rendering is in ui_mods_rows.gd; host details in ui_mods_metadata.gd.
## Update selection and result state are in mod_updates.gd.

var _mods_filter_focus_pending: bool = false


# Tear down and rebuild the Mods tab in place. Preserves the current tab so
# a Browse-row toggle does not yank the user onto the Mods tab.
func _rebuild_mods_tab(tabs: TabContainer) -> void:
	var old := tabs.get_node_or_null(UI_TAB_MODS)
	if old == null:
		return
	_rebuilding_tab_in_place = true
	var saved_scroll := 0
	if is_instance_valid(_ui_mods_scroll):
		saved_scroll = _ui_mods_scroll.scroll_vertical
	var idx := old.get_index()
	# Capture the current tab by name: remove_child shifts sibling indices.
	var current_tab_node := tabs.get_tab_control(tabs.current_tab) if tabs.get_tab_count() > 0 else null
	var current_tab_name := str(current_tab_node.name) if current_tab_node != null else ""
	tabs.remove_child(old)
	old.queue_free()
	var new_tab := build_mods_tab(tabs)
	new_tab.name = UI_TAB_MODS
	tabs.add_child(new_tab)
	tabs.move_child(new_tab, idx)
	# Restore by name; if the previous tab was Mods, land on the rebuilt one.
	for i in range(tabs.get_tab_count()):
		var ctrl := tabs.get_tab_control(i)
		if ctrl != null and ctrl.name == current_tab_name:
			tabs.current_tab = i
			break
	_rebuilding_tab_in_place = false
	# Profile/dev-mode changes bypass the per-row checkbox handler.
	refresh_launch_button_label()
	if saved_scroll > 0:
		_restore_mods_scroll(saved_scroll)

# One frame later: scroll_vertical set before layout clamps to zero.
func _restore_mods_scroll(saved_scroll: int) -> void:
	await get_tree().process_frame
	if is_instance_valid(_ui_mods_scroll):
		_ui_mods_scroll.scroll_vertical = saved_scroll

func _show_security_findings_dialog(entry: Dictionary) -> void:
	var findings: Array = entry.get("security_findings", [])
	if findings.is_empty():
		return
	var d := AcceptDialog.new()
	var mod_name := str(entry.get("mod_name", "?"))
	d.title = "Suspicious code in " + mod_name
	d.ok_button_text = "Close"
	d.min_size = Vector2(580, 420)

	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size = Vector2(560, 380)
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	d.add_child(scroll)

	var body := VBoxContainer.new()
	body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	body.add_theme_constant_override("separation", SP_L)
	scroll.add_child(body)

	var intro := Label.new()
	intro.text = "The scanner found patterns in this mod's code that are commonly used by malware " \
			+ "(obfuscated string decoding combined with process spawning, anti-debug calls, etc.). " \
			+ "If you don't trust this mod, do not enable it."
	intro.add_theme_color_override("font_color", COL_ERR)
	intro.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	intro.add_theme_font_size_override("font_size", FS_BODY)
	body.add_child(intro)

	body.add_child(HSeparator.new())

	for f: Dictionary in findings:
		var card := VBoxContainer.new()
		card.add_theme_constant_override("separation", SP_S)
		body.add_child(card)

		var rule_lbl := Label.new()
		rule_lbl.text = str(f.get("rule", "?"))
		rule_lbl.add_theme_color_override("font_color", COL_ERR)
		rule_lbl.add_theme_font_size_override("font_size", FS_HEAD)
		card.add_child(rule_lbl)

		var desc_lbl := Label.new()
		desc_lbl.text = str(f.get("description", ""))
		desc_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		desc_lbl.add_theme_font_size_override("font_size", FS_BODY)
		card.add_child(desc_lbl)

		var loc := str(f.get("file", "?"))
		if int(f.get("line", 0)) > 0:
			loc += ":" + str(f.get("line"))
		var loc_lbl := Label.new()
		loc_lbl.text = loc
		loc_lbl.add_theme_color_override("font_color", COL_TEXT_DIM)
		loc_lbl.add_theme_font_size_override("font_size", FS_META)
		card.add_child(loc_lbl)

		var preview := str(f.get("preview", ""))
		if not preview.is_empty():
			var pre_lbl := Label.new()
			pre_lbl.text = "  " + preview
			pre_lbl.add_theme_color_override("font_color", COL_OK)
			pre_lbl.add_theme_font_size_override("font_size", FS_BODY)
			pre_lbl.autowrap_mode = TextServer.AUTOWRAP_OFF
			pre_lbl.clip_text = true
			pre_lbl.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
			pre_lbl.tooltip_text = preview
			pre_lbl.mouse_filter = Control.MOUSE_FILTER_PASS
			card.add_child(pre_lbl)

		body.add_child(HSeparator.new())

	_attach_ui_dialog(d)
	_wire_accept_dismiss(d)
	d.popup_centered()


# Per-row Remove confirmation, then delete, strip profile state, re-scan and rebuild.
func _show_remove_mod_confirm(entry: Dictionary, tabs: TabContainer) -> void:
	var d := ConfirmationDialog.new()
	d.title = "Remove mod"
	var size_line := ""
	var path: String = str(entry.get("full_path", ""))
	if FileAccess.file_exists(path):
		var f := FileAccess.open(path, FileAccess.READ)
		if f != null:
			size_line = "\nSize: " + _format_size(f.get_length())
			f.close()
	d.dialog_text = "Permanently delete \"%s\"?\n\nFile: %s%s\n\nThis will:\n  - Delete the file from disk\n  - Remove the mod from EVERY profile, not just \"%s\"\n\nThis cannot be undone." % [
		str(entry.get("mod_name", "?")),
		str(entry.get("file_name", "?")),
		size_line,
		_active_profile_label(),
	]
	d.ok_button_text = "Delete mod"
	style_dialog_danger_button(d.get_ok_button())
	_attach_ui_dialog(d)
	_connect_dialog_exits(d,
		func():
			d.queue_free()
			if _delete_mod_file_and_cleanup(entry):
				_reload_entries_for_active_profile()
				_rebuild_mods_tab(tabs)
			else:
				_show_error_dialog("Could not delete mod", "Could not remove %s. If this mod is enabled, its archive is mounted and the file stays locked while the game is open -- disable it, relaunch the game, then delete." % str(entry.get("file_name", "the mod"))),
		func(): d.queue_free())
	d.popup_centered()

# Shared tail for dependency quick actions: recompute, persist, refresh.
# Rebuild is deferred so the mid-signal control isn't torn down.
func _after_dep_action(tabs: TabContainer) -> void:
	_refresh_dependency_status()
	_save_ui_config()
	refresh_launch_button_label()
	(func(): _rebuild_mods_tab(tabs)).call_deferred()

func build_mods_tab(tabs: TabContainer) -> Control:
	_refresh_dependency_status()
	# Drop last build's row-node mapping; the row loop re-registers each row.
	_mods_meta_nodes.clear()
	var outer := VBoxContainer.new()
	outer.size_flags_vertical = Control.SIZE_EXPAND_FILL
	var active_modpack := get_active_modpack()
	_mods_build_banners(outer, tabs, active_modpack)
	_mods_build_toolbar(outer, tabs, active_modpack)

	outer.add_child(HSeparator.new())

	var split := HSplitContainer.new()
	split.split_offset = 560
	split.size_flags_vertical = Control.SIZE_EXPAND_FILL
	outer.add_child(split)

	# -- Left: sticky filter bar + mod list -----------------------------------
	var left_col := VBoxContainer.new()
	left_col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	left_col.size_flags_vertical = Control.SIZE_EXPAND_FILL
	split.add_child(left_col)
	var filter_edit := _mods_build_filter_bar(left_col, tabs)
	var list := _mods_build_list(left_col)
	var refresh_order := _mods_build_order_panel(split)
	_mods_build_updates_section(list, tabs)
	_mods_build_missing_section(list, tabs)
	_mods_build_header_row(list)

	# -- One row per mod -------------------------------------------------------

	if _ui_mod_entries.is_empty():
		var empty := Label.new()
		empty.text = "No mods installed yet.\n\nOpen the Browse tab to download mods,\nor place .vmz, .zip or .pck files in:\n" \
				+ ProjectSettings.globalize_path(_mods_dir)
		# No autowrap inside the ScrollContainer (oscillation bug); newlines still break.
		empty.clip_text = true
		empty.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		empty.tooltip_text = empty.text
		empty.mouse_filter = Control.MOUSE_FILTER_PASS
		empty.add_theme_color_override("font_color", COL_TEXT_DIM)
		empty.add_theme_font_size_override("font_size", FS_EMPH)
		list.add_child(empty)


	var rendered_any := false
	# Per-build state every row reads. dep_names_by_id is built once here
	# because the display-name fallback rebuilds the map per call.
	var dep_names_by_id := _entries_by_mod_id(_ui_mod_entries)
	var persisted_sources := _get_persisted_mod_sources()
	var profile_editable := _active_profile != VANILLA_PROFILE and active_modpack == ""
	for entry in _ui_mod_entries:
		if not _mods_entry_visible(entry):
			continue
		rendered_any = true
		_mods_build_row(list, entry, tabs, refresh_order, persisted_sources, dep_names_by_id, profile_editable)

	# The filter narrowed every row out; say so, distinct from no mods installed.
	if not _ui_mod_entries.is_empty() and not rendered_any:
		var no_match := Label.new()
		no_match.text = "No mods match. Try a shorter search or turn off Hide disabled."
		no_match.add_theme_color_override("font_color", COL_TEXT_DIM)
		no_match.add_theme_font_size_override("font_size", FS_EMPH)
		list.add_child(no_match)

	# Restore focus to the search input after a filter-driven rebuild, deferred
	# so the new tab is in the tree. Cleared on consume so other rebuilds do not steal focus.
	if _mods_filter_focus_pending:
		_mods_filter_focus_pending = false
		filter_edit.call_deferred("grab_focus")
		# Setting LineEdit.text resets the caret to column 0 and FOCUS_ENTER does
		# not move it; restore the caret to end-of-text after focus lands.
		filter_edit.call_deferred("set_caret_column", filter_edit.text.length())

	refresh_order.call()
	# Wrap in the shared tab margin so the view does not shift between tabs.
	var margin := _make_tab_margin()
	margin.add_child(outer)
	return margin


# The hook-health and active-modpack banners at the top of the Mods tab.
func _mods_build_banners(outer: VBoxContainer, tabs: TabContainer, active_modpack: String) -> void:
	# Hook health from the previous session: generation runs after this window
	# closes, so this is where a player learns a game update broke the rewriter.
	var hook_problem := _hook_status_problem()
	if not hook_problem.is_empty():
		var hook_banner := _make_banner(str(hook_problem.get("text", "")), COL_ERR)
		var update_btn := Button.new()
		update_btn.text = "Check for loader update"
		var hook_banner_row: HBoxContainer = hook_banner["row"]
		hook_banner_row.add_child(update_btn)
		update_btn.pressed.connect(func():
			OS.shell_open(_modloader_release_page_url())
		)
		_wire_hint(update_btn, "Open the loader's release page in your browser.")
		outer.add_child(hook_banner["panel"])

	# Active-modpack banner with a one-click Unload.
	if active_modpack != "":
		var banner := _make_banner(
				"Modpack \"" + active_modpack + "\" is active. Changes here save to the modpack, not your profiles.",
				COL_ACCENT)
		var unload_btn := Button.new()
		unload_btn.text = "Unload"
		style_danger_button(unload_btn)
		var banner_row: HBoxContainer = banner["row"]
		banner_row.add_child(unload_btn)
		unload_btn.pressed.connect(func(): _unload_modpack_with_feedback(tabs))
		outer.add_child(banner["panel"])


# Mods folder, profile controls, UI scale and Developer Mode.
func _mods_build_toolbar(outer: VBoxContainer, tabs: TabContainer, active_modpack: String) -> void:
	var toolbar := HBoxContainer.new()
	toolbar.add_theme_constant_override("separation", SP_M)
	outer.add_child(toolbar)

	var open_btn := Button.new()
	open_btn.text = "Open mods folder"
	toolbar.add_child(open_btn)
	open_btn.pressed.connect(func():
		OS.shell_open(ProjectSettings.globalize_path(_mods_dir))
	)
	_wire_hint(open_btn, "Open the game's mods folder in your file manager.")

	var pre_profile_gap := Control.new()
	pre_profile_gap.custom_minimum_size.x = SP_L
	toolbar.add_child(pre_profile_gap)

	var profile_lbl := Label.new()
	profile_lbl.text = "Profile:"
	toolbar.add_child(profile_lbl)

	var profile_opt := OptionButton.new()
	profile_opt.custom_minimum_size.x = 180
	toolbar.add_child(profile_opt)

	# The dropdown popup is a sub-Window: always_on_top and transient so it is
	# not stranded behind the launcher; theme lookup does not cross Window boundaries.
	var profile_popup := profile_opt.get_popup()
	profile_popup.always_on_top = true
	profile_popup.transient = true
	if _ui_window != null and _ui_window.theme != null:
		profile_popup.theme = _ui_window.theme

	# Fresh install: Default is a placeholder, materialized on first save.
	# Modpack-managed profiles are filtered out of the dropdown.
	var profiles := _list_profiles().filter(func(n: String): return not _is_modpack_managed_profile(n))
	if profiles.is_empty():
		profiles = ["Default"]
	var active_idx := 0  # fall back to first user profile if no match
	for name: String in profiles:
		profile_opt.add_item(name)
		var idx := profile_opt.item_count - 1
		profile_opt.set_item_metadata(idx, name)
		if name == _active_profile:
			active_idx = idx
	profile_opt.selected = active_idx

	# With a modpack active the active profile is a hidden managed slot:
	# disable the dropdown and label it with the pack.
	if active_modpack != "":
		profile_opt.clear()
		profile_opt.add_item("[Modpack: " + active_modpack + "]")
		profile_opt.selected = 0
		profile_opt.disabled = true

	# All profile mutations are disabled while a modpack is active.
	var modpack_locked := active_modpack != ""
	var new_profile_btn := Button.new()
	new_profile_btn.text = "+"
	new_profile_btn.tooltip_text = "Create a new profile" if not modpack_locked else "Unload the active modpack first"
	new_profile_btn.disabled = modpack_locked
	new_profile_btn.custom_minimum_size.x = 28
	toolbar.add_child(new_profile_btn)
	_wire_hint(new_profile_btn, "New profile from current mod selection.")

	var rename_btn := Button.new()
	rename_btn.icon = _make_pencil_icon()
	rename_btn.tooltip_text = "Rename the active profile" if not modpack_locked else "Unload the active modpack first"
	rename_btn.disabled = modpack_locked
	rename_btn.custom_minimum_size.x = 28
	toolbar.add_child(rename_btn)
	_wire_hint(rename_btn, "Rename the active profile.")

	# Delete needs at least one other profile to switch to.
	var del_profile_btn := Button.new()
	del_profile_btn.icon = _make_trashcan_icon()
	del_profile_btn.tooltip_text = "Delete the active profile" if not modpack_locked else "Unload the active modpack first"
	del_profile_btn.disabled = profiles.size() <= 1 or modpack_locked
	del_profile_btn.custom_minimum_size.x = 28
	toolbar.add_child(del_profile_btn)
	_wire_hint(del_profile_btn, "Delete the active profile.")

	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	toolbar.add_child(spacer)

	# Launcher zoom, user-owned; never DPI-derived (see show_mod_ui).
	var scale_lbl := Label.new()
	scale_lbl.text = "UI scale"
	scale_lbl.add_theme_font_size_override("font_size", FS_BODY)
	scale_lbl.add_theme_color_override("font_color", COL_TEXT_DIM)
	toolbar.add_child(scale_lbl)

	var scale_values := [1.0, 1.25, 1.5, 1.75, 2.0]
	var scale_opt := OptionButton.new()
	for sv: float in scale_values:
		scale_opt.add_item("%d%%" % int(round(sv * 100.0)))
	var cur_scale_idx := scale_values.find(_ui_scale_setting())
	scale_opt.select(cur_scale_idx if cur_scale_idx >= 0 else 0)
	scale_opt.custom_minimum_size.y = CTRL_H
	scale_opt.add_theme_font_size_override("font_size", FS_BODY)
	toolbar.add_child(scale_opt)
	_wire_hint(scale_opt, "Scale the launcher window. Applies immediately.")
	# Same popup setup as the profile dropdown: without it the list opens
	# stranded behind the always_on_top launcher and unthemed.
	var scale_popup := scale_opt.get_popup()
	scale_popup.always_on_top = true
	scale_popup.transient = true
	if _ui_window != null and _ui_window.theme != null:
		scale_popup.theme = _ui_window.theme

	scale_opt.item_selected.connect(func(idx: int):
		var sv: float = scale_values[idx] if idx >= 0 and idx < scale_values.size() else 1.0
		# Written straight through: a display preference must not rewrite profile state.
		var scfg := _load_ui_cfg_for_write()
		if scfg != null:
			scfg.set_value("settings", "ui_scale", sv)
			_persist_ui_cfg(scfg)
		# Apply even if the save was refused.
		_apply_ui_scale(_ui_window, sv)
	)

	var dev_check := CheckBox.new()
	dev_check.text = "Developer mode"
	dev_check.tooltip_text = "Enables verbose logging, conflict report, and loose folder loading"
	dev_check.button_pressed = _developer_mode
	dev_check.add_theme_font_size_override("font_size", FS_BODY)
	dev_check.add_theme_color_override("font_color", COL_TEXT_DIM)
	toolbar.add_child(dev_check)
	_wire_hint(dev_check, "Developer mode: verbose logging, conflict report, and loose folder loading.")

	profile_opt.item_selected.connect(func(idx: int):
		var meta = profile_opt.get_item_metadata(idx)
		_switch_profile(str(meta))
		_rebuild_mods_tab(tabs)
	)
	new_profile_btn.pressed.connect(func(): _show_new_profile_dialog(tabs))
	rename_btn.pressed.connect(func(): _show_rename_profile_dialog(tabs))
	del_profile_btn.pressed.connect(func(): _show_delete_confirm(tabs))

	dev_check.toggled.connect(func(on: bool):
		_developer_mode = on
		# Folder mods are scanned only in developer mode, so rescan and re-apply
		# the active profile to the new entry list. The profile stays selected.
		_reload_entries_for_active_profile()
		# Persist now: the post-boot reopen path has no closing save.
		_save_ui_config()
		_rebuild_mods_tab(tabs)
	)


# Filter text, Enable all / Disable all, Hide disabled and Check for updates.
# Returns the filter LineEdit so the caller can restore focus to it.
func _mods_build_filter_bar(left_col: VBoxContainer, tabs: TabContainer) -> LineEdit:
	# Filter bar. All/None respect the active filter, toggling only the visible subset.
	var filter_bar := HBoxContainer.new()
	filter_bar.add_theme_constant_override("separation", SP_M)
	left_col.add_child(filter_bar)

	var filter_edit := LineEdit.new()
	filter_edit.placeholder_text = "Filter mods..."
	filter_edit.text = _mods_filter_text
	filter_edit.custom_minimum_size.y = CTRL_H
	filter_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	filter_bar.add_child(filter_edit)

	var all_btn := Button.new()
	all_btn.text = "Enable all"
	all_btn.tooltip_text = "Enable every visible mod"
	filter_bar.add_child(all_btn)
	_wire_hint(all_btn, "Enable every visible mod (respects the search filter).")

	var none_btn := Button.new()
	none_btn.text = "Disable all"
	none_btn.tooltip_text = "Disable every visible mod"
	filter_bar.add_child(none_btn)
	_wire_hint(none_btn, "Disable every visible mod (respects the search filter).")

	var hide_check := CheckBox.new()
	hide_check.text = "Hide disabled"
	hide_check.tooltip_text = "Hide rows for mods that are disabled in this profile"
	hide_check.button_pressed = _mods_hide_disabled
	hide_check.add_theme_font_size_override("font_size", FS_BODY)
	filter_bar.add_child(hide_check)
	_wire_hint(hide_check, "Hide rows for mods that are disabled in this profile.")

	# Check Updates populates _mod_updates_state so rows show update badges.
	var check_btn := Button.new()
	check_btn.text = "Check for updates"
	if _mod_updates_check_in_progress:
		check_btn.disabled = true
		check_btn.text = "Checking..."
	filter_bar.add_child(check_btn)
	_wire_hint(check_btn, "Check each mod's site for a newer version. Mods that don't say where they came from are skipped.")
	check_btn.pressed.connect(func():
		if _mod_updates_check_in_progress:
			return
		check_btn.disabled = true
		check_btn.text = "Checking..."
		var summary := await _run_updates_check_for_mods()
		# A mid-check rebuild frees the original button: skip only the button
		# touches; the rebuild and toast must still run.
		if is_instance_valid(check_btn):
			check_btn.disabled = false
			check_btn.text = "Check for updates"
		if is_instance_valid(tabs):
			_rebuild_mods_tab(tabs)
		# Only toast while the launcher exists: with _ui_window null the dialog
		# would parent to the game's root and steal input mid-game.
		if is_instance_valid(_ui_window):
			_show_info_toast(_updates_check_message(summary, summary.get("providers", [])))
	)

	# Debounce the filter rebuild: each _rebuild_mods_tab is a full tear-down
	# with disk work, so keystrokes only store text and restart the timer.
	var filter_debounce := Timer.new()
	filter_debounce.one_shot = true
	filter_debounce.wait_time = 0.25
	filter_bar.add_child(filter_debounce)
	filter_debounce.timeout.connect(func():
		# Restore focus after the rebuild so the user can keep typing.
		_mods_filter_focus_pending = true
		if is_instance_valid(tabs):
			_rebuild_mods_tab(tabs)
	)
	filter_edit.text_changed.connect(func(t: String):
		_mods_filter_text = t
		filter_debounce.stop()
		filter_debounce.start()
	)
	all_btn.pressed.connect(func():
		for entry in _ui_mod_entries:
			if _mods_entry_visible(entry):
				entry["enabled"] = true
		_save_ui_config()
		_rebuild_mods_tab(tabs)
	)
	none_btn.pressed.connect(func():
		# Bulk None disables content mods too; confirm once for the batch.
		var content_count := 0
		var content_name := ""
		for entry in _ui_mod_entries:
			if _mods_entry_visible(entry) and bool(entry.get("enabled", false)) \
					and bool(entry.get("has_registry", false)):
				content_count += 1
				if content_name == "":
					content_name = str(entry.get("mod_name", "this mod"))
		if content_count > 0:
			var ok: bool = await _confirm_disable_content_mod(content_name, content_count)
			if not ok:
				return
		for entry in _ui_mod_entries:
			if _mods_entry_visible(entry):
				entry["enabled"] = false
		_save_ui_config()
		if is_instance_valid(tabs):
			_rebuild_mods_tab(tabs)
	)
	hide_check.toggled.connect(func(on: bool):
		_mods_hide_disabled = on
		_save_per_profile_setting("hide_disabled", on)
		_rebuild_mods_tab(tabs)
	)
	return filter_edit


# The scrolling mod list under the filter bar.
func _mods_build_list(left_col: VBoxContainer) -> VBoxContainer:
	var left_scroll := ScrollContainer.new()
	left_scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	left_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	left_col.add_child(left_scroll)
	_ui_mods_scroll = left_scroll

	# Right padding keeps the load-order SpinBox arrows off the scrollbar.
	var list_pad := MarginContainer.new()
	list_pad.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	list_pad.add_theme_constant_override("margin_right", SP_XL)
	left_scroll.add_child(list_pad)

	var list := VBoxContainer.new()
	list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	list_pad.add_child(list)
	return list


# The live load-order preview on the right. Returns the Callable that
# re-renders it; rows call it when a priority changes.
func _mods_build_order_panel(split: HSplitContainer) -> Callable:
	var right := VBoxContainer.new()
	right.custom_minimum_size.x = 220
	split.add_child(right)

	var order_header := Label.new()
	order_header.text = "Load order"
	order_header.add_theme_font_size_override("font_size", FS_HEAD)
	order_header.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	right.add_child(order_header)
	right.add_child(HSeparator.new())

	var order_panel := PanelContainer.new()
	order_panel.size_flags_vertical = Control.SIZE_EXPAND_FILL
	var panel_style := StyleBoxFlat.new()
	panel_style.bg_color = COL_SURFACE_2
	panel_style.content_margin_left = SP_M
	panel_style.content_margin_right = SP_M
	panel_style.content_margin_top = SP_M
	panel_style.content_margin_bottom = SP_M
	order_panel.add_theme_stylebox_override("panel", panel_style)
	right.add_child(order_panel)

	var order_scroll := ScrollContainer.new()
	order_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	# Scrollbar always visible so it cannot flip and re-trigger the autowrap oscillation bug.
	order_scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_SHOW_ALWAYS
	order_panel.add_child(order_scroll)

	var order_list := VBoxContainer.new()
	order_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	order_scroll.add_child(order_list)

	var refresh_order := func():
		# _refresh_dependency_status returns the loader's own pick. Reuse it: this
		# fires per step while a spin arrow is held.
		var pick: Dictionary = _refresh_dependency_status()
		for child in order_list.get_children():
			child.queue_free()
		var loadable: Array = pick["loadable"]
		var enabled_count := int(pick["enabled_count"])
		if enabled_count == 0:
			var lbl := Label.new()
			lbl.text = "No mods enabled"
			lbl.add_theme_color_override("font_color", COL_TEXT_DIM)
			order_list.add_child(lbl)
			return
		if loadable.is_empty():
			# Manual line break; never autowrap here (see below).
			order_list.add_child(_make_sub_label(
					"%d enabled, none will load\n(missing dependencies)" % enabled_count,
					COL_WARN,
					"Every enabled mod is missing a required dependency.\nFix it from the orange row warnings, or use Load anyway."))
			return
		for i in loadable.size():
			var e: Dictionary = loadable[i]
			var lbl := Label.new()
			lbl.text = str(i + 1) + ".  " + e["mod_name"]
			lbl.add_theme_font_size_override("font_size", FS_EMPH)
			lbl.add_theme_color_override("font_color", COL_TEXT)
			# No autowrap: an autowrap label in a fixed-width ScrollContainer hits a
			# Godot 4.6 layout-oscillation bug (scrollbar appears, width shrinks, re-wrap,
			# repeat) that floods the message queue and crashes.
			lbl.clip_text = true
			lbl.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
			# Full name shows in the bottom status-line hint.
			lbl.mouse_filter = Control.MOUSE_FILTER_PASS
			order_list.add_child(lbl)
			_wire_hint(lbl, str(e["mod_name"]))
		if bool(pick["adjusted"]):
			var reorder_lbl := _make_sub_label("reordered for dependencies", COL_TEXT_DIM)
			order_list.add_child(reorder_lbl)
			_wire_hint(reorder_lbl, "A required mod was moved up so it loads before the mod that needs it. Your load-order numbers are unchanged.")
		var blocked_count := enabled_count - loadable.size()
		if blocked_count > 0:
			var blocked_lbl := _make_sub_label("%d blocked by dependencies" % blocked_count, COL_WARN)
			order_list.add_child(blocked_lbl)
			_wire_hint(blocked_lbl, "Blocked mods stay checked but don't load. See the orange row warnings for fixes.")
	return refresh_order


# Mods with a newer version known from the last update check.
func _mods_build_updates_section(list: VBoxContainer, tabs: TabContainer) -> void:
	var update_keys: Array = []
	for entry_v in _ui_mod_entries:
		var pk_check: String = str(entry_v.get("profile_key", ""))
		if _mod_updates_state.has(pk_check):
			update_keys.append(pk_check)
	if not update_keys.is_empty():
		var u_hdr_row := HBoxContainer.new()
		u_hdr_row.add_theme_constant_override("separation", SP_S)
		list.add_child(u_hdr_row)
		var u_hdr := Label.new()
		u_hdr.text = "Updates available"
		u_hdr.add_theme_color_override("font_color", COL_ACCENT)
		u_hdr.add_theme_font_size_override("font_size", FS_HEAD)
		u_hdr_row.add_child(u_hdr)
		var u_badge := Label.new()
		u_badge.text = str(update_keys.size())
		u_badge.add_theme_stylebox_override("normal", _make_badge_stylebox())
		u_badge.add_theme_font_size_override("font_size", FS_META)
		u_badge.add_theme_color_override("font_color", COL_TEXT_HI)
		u_badge.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		u_hdr_row.add_child(u_badge)
		list.add_child(HSeparator.new())

		for pk: String in update_keys:
			var upd: Dictionary = _mod_updates_state[pk]
			var upd_row := HBoxContainer.new()
			upd_row.add_theme_constant_override("separation", SP_L)
			list.add_child(upd_row)

			var u_name := Label.new()
			u_name.text = str(upd.get("mod_name", "?"))
			u_name.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			u_name.clip_text = true
			u_name.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
			u_name.tooltip_text = str(upd.get("mod_name", "?"))
			u_name.mouse_filter = Control.MOUSE_FILTER_PASS
			upd_row.add_child(u_name)

			var u_ver := Label.new()
			u_ver.text = "v%s  ->  v%s" % [str(upd.get("current_version", "?")), str(upd.get("latest_version", "?"))]
			u_ver.add_theme_color_override("font_color", COL_TEXT)
			u_ver.add_theme_font_size_override("font_size", FS_BODY)
			u_ver.custom_minimum_size.x = 160
			# A long prerelease string must not widen the column.
			u_ver.clip_text = true
			u_ver.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
			u_ver.tooltip_text = u_ver.text
			u_ver.mouse_filter = Control.MOUSE_FILTER_PASS
			upd_row.add_child(u_ver)

			var u_btn := Button.new()
			u_btn.text = "Update"
			upd_row.add_child(u_btn)
			_wire_hint(u_btn, "Download the latest version and replace the installed one.")
			var captured_pk := pk
			var captured_upd := upd
			# Row rebuilt mid-download: render the button inert.
			if _mod_update_in_flight.has(pk):
				u_btn.disabled = true
				u_btn.text = "Updating..."
			u_btn.pressed.connect(func():
				# Refuse a second concurrent download of the same mod.
				if _mod_update_in_flight.has(captured_pk):
					return
				_mod_update_in_flight[captured_pk] = true
				u_btn.disabled = true
				u_btn.text = "Updating..."
				var upd_ref: Dictionary = captured_upd.get("ref", {}) if captured_upd.get("ref") is Dictionary else {}
				# Re-resolve the path live: another surface may have renamed the file.
				var full_path: String = _live_full_path(captured_pk, str(captured_upd.get("full_path", "")))
				var result: Dictionary = await replace_mod_from_ref(full_path, upd_ref)
				_mod_update_in_flight.erase(captured_pk)
				if bool(result.get("ok", false)):
					_mod_updates_state.erase(captured_pk)
					_reload_entries_for_active_profile()
					if is_instance_valid(tabs):
						_rebuild_mods_tab(tabs)
				else:
					if is_instance_valid(u_btn):
						u_btn.disabled = false
						u_btn.text = "Update"
					elif is_instance_valid(tabs):
						# A mid-download rebuild left a replacement button stuck; rebuild now the flag is clear.
						_rebuild_mods_tab(tabs)
					var err_name := str(captured_upd.get("mod_name", "this mod"))
					var err_msg := "Could not download %s. Check your connection and try again." % err_name
					var err_detail := str(result.get("error", ""))
					if err_detail != "" and err_detail != "unknown":
						err_msg += "\n\nDetails: " + err_detail
					if is_instance_valid(_ui_window):
						_show_error_dialog("Update failed", err_msg)
			)
			list.add_child(HSeparator.new())


# Profile entries whose mod is not on disk: Remove, and Download when a
# source is known.
func _mods_build_missing_section(list: VBoxContainer, tabs: TabContainer) -> void:
	var missing_files := _missing_mods_in_active_profile()
	if not missing_files.is_empty():
		var missing_hdr_row := HBoxContainer.new()
		list.add_child(missing_hdr_row)
		var missing_hdr := Label.new()
		missing_hdr.text = "Missing from this profile"
		missing_hdr.add_theme_color_override("font_color", COL_ERR)
		missing_hdr.add_theme_font_size_override("font_size", FS_HEAD)
		missing_hdr.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		missing_hdr_row.add_child(missing_hdr)
		var remove_all_btn := Button.new()
		remove_all_btn.text = "Remove all"
		remove_all_btn.tooltip_text = "Remove all missing mods from this profile"
		missing_hdr_row.add_child(remove_all_btn)
		_wire_hint(remove_all_btn, "Remove every missing mod from the active profile.")
		remove_all_btn.pressed.connect(func():
			var n := missing_files.size()
			var d := ConfirmationDialog.new()
			d.title = "Remove missing-mod entries"
			d.dialog_text = "Remove %d missing-mod entr%s from \"%s\"?\n\nOnly the active profile is affected -- other profiles still list these mods." % [
				n, ("y" if n == 1 else "ies"), _active_profile_label(),
			]
			d.ok_button_text = "Remove"
			_attach_ui_dialog(d)
			style_dialog_danger_button(d.get_ok_button())
			_connect_dialog_exits(d,
				func():
					d.queue_free()
					_remove_all_missing_entries_from_profile()
					_rebuild_mods_tab(tabs),
				func(): d.queue_free())
			d.popup_centered()
		)
		list.add_child(HSeparator.new())
		# Compute sources once per build, not per row.
		var missing_sources := _missing_mod_sources_combined()
		for fn: String in missing_files:
			var miss_row := HBoxContainer.new()
			list.add_child(miss_row)
			var miss_lbl := Label.new()
			var display := fn.trim_prefix("zip:")
			miss_lbl.text = display + "  --  not installed"
			miss_lbl.add_theme_color_override("font_color", COL_ERR)
			miss_lbl.clip_text = true
			miss_lbl.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
			miss_lbl.tooltip_text = miss_lbl.text
			miss_lbl.mouse_filter = Control.MOUSE_FILTER_PASS
			miss_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			miss_row.add_child(miss_lbl)

			# Download button when source info is known; otherwise Remove only.
			var src_v: Variant = missing_sources.get(fn)
			var src_ref: Dictionary = {}
			var src_version: String = ""
			if src_v is Dictionary:
				# Already canonical; _normalize_source_record handled the untrusted JSON.
				# This runs on the pass-1 path, where a crash would block the main menu.
				var src: Dictionary = src_v
				src_ref = _source_host_ref(src)
				src_version = str(src.get("version", ""))
			if _modpack_ref_downloadable(src_ref):
				var src_host := host_display_name(str(src_ref["provider"]))
				var dl_btn := Button.new()
				dl_btn.text = "Download"
				dl_btn.tooltip_text = "Download this mod from " + src_host
				miss_row.add_child(dl_btn)
				_wire_hint(dl_btn, "Download this mod from " + src_host + ".")
				var captured_ref := src_ref
				var captured_version := src_version
				# Reuse _mod_update_in_flight keyed by the stored profile key, or a
				# mid-download rebuild re-enables the button and a second click duplicates.
				var captured_fn := fn
				if _mod_update_in_flight.has(fn):
					dl_btn.disabled = true
					dl_btn.text = "Downloading..."
				dl_btn.pressed.connect(func():
					if _mod_update_in_flight.has(captured_fn):
						return
					_mod_update_in_flight[captured_fn] = true
					dl_btn.disabled = true
					dl_btn.text = "Downloading..."
					# allow_rename_on_collision: dedup happens at scan time.
					var r: Dictionary = await download_mod_from_ref(captured_ref, captured_version, true)
					_mod_update_in_flight.erase(captured_fn)
					if bool(r.get("ok", false)):
						_reload_entries_for_active_profile()
						# A pack's missing row is keyed by the pack; move it to the key the mod landed under.
						_modpack_reconcile_active()
						if is_instance_valid(tabs):
							_rebuild_mods_tab(tabs)
					else:
						if is_instance_valid(dl_btn):
							dl_btn.disabled = false
							dl_btn.text = "Download"
						elif is_instance_valid(tabs):
							_rebuild_mods_tab(tabs)
						if is_instance_valid(_ui_window):
							_show_error_dialog("Download failed", str(r.get("error", "Could not download this mod. Check your connection and try again.")))
				)
			else:
				# No source info: name what is unavailable. STOP so the label gets hover signals.
				var no_src_lbl := Label.new()
				no_src_lbl.text = "Download unavailable"
				no_src_lbl.add_theme_color_override("font_color", COL_TEXT_DIM)
				no_src_lbl.add_theme_font_size_override("font_size", FS_BODY)
				no_src_lbl.size_flags_vertical = Control.SIZE_SHRINK_CENTER
				no_src_lbl.mouse_filter = Control.MOUSE_FILTER_STOP
				miss_row.add_child(no_src_lbl)
				_wire_hint(no_src_lbl,
					"This mod does not say which site it came from, so it can't be downloaded automatically. Reinstall it manually.")

			var remove_btn := Button.new()
			remove_btn.text = "Remove"
			remove_btn.tooltip_text = "Remove this missing mod from this profile"
			miss_row.add_child(remove_btn)
			_wire_hint(remove_btn, "Remove this mod from the active profile.")
			var captured := fn
			remove_btn.pressed.connect(func():
				_remove_missing_entry_from_profile(captured)
				_rebuild_mods_tab(tabs)
			)
			list.add_child(HSeparator.new())
