## Mods tab: banners, toolbar, filter bar, the update and missing sections and the
## load-order preview. Rows are in ui_mods_rows.gd, host details in ui_mods_metadata.gd.

var _mods_filter_focus_pending: bool = false


# Rebuilds in place so a Browse-row toggle does not switch tabs. A Variant, because
# a caller resuming after an await may hold a freed TabContainer.
func _rebuild_mods_tab(tabs: Variant) -> void:
	if not is_instance_valid(tabs):
		return
	if not _rebuild_tab_in_place(tabs, UI_TAB_MODS, build_mods_tab, func(): return _ui_mods_scroll):
		return
	# Profile and developer-mode changes bypass the per-row checkbox handler.
	refresh_launch_button_label()

# Deferred so the control whose signal is running is not torn down.
func _after_dep_action(tabs: TabContainer) -> void:
	_refresh_dependency_status()
	_save_ui_config()
	refresh_launch_button_label()
	(func(): _rebuild_mods_tab(tabs)).call_deferred()

func build_mods_tab(tabs: TabContainer) -> Control:
	_refresh_dependency_status()
	# The row loop re-registers every row it builds.
	_mods_meta_nodes.clear()
	var outer := VBoxContainer.new()
	outer.size_flags_vertical = Control.SIZE_EXPAND_FILL
	var active_modpack := get_active_modpack()
	_build_banners(outer, tabs, active_modpack)
	_build_mods_toolbar(outer, tabs, active_modpack)
	outer.add_child(HSeparator.new())

	var split := HSplitContainer.new()
	split.split_offset = 560
	split.size_flags_vertical = Control.SIZE_EXPAND_FILL
	outer.add_child(split)

	var left_col := VBoxContainer.new()
	left_col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	left_col.size_flags_vertical = Control.SIZE_EXPAND_FILL
	split.add_child(left_col)
	var filter_edit := _build_filter_bar(left_col, tabs)
	var scroll := _make_scroll(left_col)
	_ui_mods_scroll = scroll
	# The column's right margin keeps the load-order SpinBox arrows off the scrollbar.
	var list := _make_scroll_column(scroll)
	var refresh_order := _build_order_panel(split)
	_build_updates(list, tabs)
	_build_missing(list, tabs)

	var header_row := HBoxContainer.new()
	list.add_child(header_row)
	_column_title(header_row, "On", _MODS_COL_CHECK_W)
	var h_thumb := Control.new()
	h_thumb.custom_minimum_size.x = _MODS_COL_THUMB_W
	header_row.add_child(h_thumb)
	var h_name := _column_title(header_row, "Mod", 0)
	h_name.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var h_prio := _column_title(header_row, "Load order", _MODS_COL_PRIO_W)
	h_prio.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	var h_tail := Control.new()
	h_tail.custom_minimum_size.x = ICON_BTN_W
	header_row.add_child(h_tail)
	list.add_child(HSeparator.new())

	if _ui_mod_entries.is_empty():
		var empty_text := "No mods installed yet.\n\nOpen the Browse tab to download mods,\nor place .vmz, .zip or .pck files in:\n" \
				+ ProjectSettings.globalize_path(_mods_dir)
		list.add_child(_make_sub_label(empty_text, COL_TEXT_DIM, empty_text, FS_EMPH))

	# Built once here: the display-name fallback would rebuild this map per call.
	var dep_names_by_id := _entries_by_mod_id(_ui_mod_entries)
	var persisted_sources := _get_persisted_mod_sources()
	var profile_editable := active_modpack == ""
	var rendered_any := false
	for entry in _ui_mod_entries:
		if _mods_entry_visible(entry):
			rendered_any = true
			_build_row(list, entry, tabs, refresh_order, persisted_sources, dep_names_by_id, profile_editable)

	if not _ui_mod_entries.is_empty() and not rendered_any:
		list.add_child(_make_label("No mods match. Try a shorter search or turn off Hide disabled.", COL_TEXT_DIM, FS_EMPH))

	# Deferred so the new tab is in the tree; cleared so other rebuilds do not steal focus.
	if _mods_filter_focus_pending:
		_mods_filter_focus_pending = false
		filter_edit.call_deferred("grab_focus")
		# Setting LineEdit.text moves the caret to column 0 and focusing does not move it back.
		filter_edit.call_deferred("set_caret_column", filter_edit.text.length())

	refresh_order.call()
	var margin := _make_tab_margin()
	margin.add_child(outer)
	return margin


func _column_title(row: HBoxContainer, text: String, min_w: int) -> Label:
	var lbl := _make_label(text, COL_TEXT_DIM, FS_META)
	lbl.custom_minimum_size.x = min_w
	row.add_child(lbl)
	return lbl


func _build_banners(outer: VBoxContainer, tabs: TabContainer, active_modpack: String) -> void:
	# Hooks are generated after this window closes, so this is where a player
	# learns that a game update broke the rewriter.
	var hook_problem := _hook_status_problem()
	if not hook_problem.is_empty():
		var hook_error: bool = hook_problem["severity"] == "error"
		var hook_banner := _make_banner(hook_problem["text"], COL_ERR if hook_error else COL_ACCENT)
		if hook_error:
			var update_btn := Button.new()
			update_btn.text = "Check for loader update"
			var hook_banner_row: HBoxContainer = hook_banner["row"]
			hook_banner_row.add_child(update_btn)
			update_btn.pressed.connect(func(): OS.shell_open(_modloader_release_page_url()))
			_wire_hint(update_btn, "Open the loader's release page in your browser.")
		outer.add_child(hook_banner["panel"])

	# Read once per launcher window; this runs on every rebuild.
	if not _crash_notice_cached:
		_crash_notice_cache = _crash_notice_problem(true)
		_crash_notice_cached = true
	if not _crash_notice_cache.is_empty():
		var crash_banner := _make_banner(_crash_notice_cache["text"],
				COL_ERR if _crash_notice_cache["severity"] == "error" else COL_ACCENT)
		outer.add_child(crash_banner["panel"])

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


func _build_mods_toolbar(outer: VBoxContainer, tabs: TabContainer, active_modpack: String) -> void:
	var toolbar := HBoxContainer.new()
	toolbar.add_theme_constant_override("separation", SP_M)
	outer.add_child(toolbar)

	var open_btn := Button.new()
	open_btn.text = "Open mods folder"
	toolbar.add_child(open_btn)
	open_btn.pressed.connect(func(): OS.shell_open(ProjectSettings.globalize_path(_mods_dir)))
	_wire_hint(open_btn, "Open the game's mods folder in your file manager.")

	var gap := Control.new()
	gap.custom_minimum_size.x = SP_L
	toolbar.add_child(gap)
	_profile_controls(toolbar, tabs, active_modpack)
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	toolbar.add_child(spacer)

	toolbar.add_child(_make_label("UI scale", COL_TEXT_DIM, FS_BODY))
	var scale_values := [1.0, 1.25, 1.5, 1.75, 2.0]
	var scale_opt := OptionButton.new()
	for sv: float in scale_values:
		scale_opt.add_item("%d%%" % int(round(sv * 100.0)))
	var cur_idx := scale_values.find(_ui_scale_setting())
	scale_opt.select(cur_idx if cur_idx >= 0 else 0)
	scale_opt.custom_minimum_size.y = CTRL_H
	scale_opt.add_theme_font_size_override("font_size", FS_BODY)
	toolbar.add_child(scale_opt)
	_wire_hint(scale_opt, "Scale the launcher window. Applies immediately.")
	_style_option_popup(scale_opt)
	scale_opt.item_selected.connect(func(idx: int):
		var sv: float = scale_values[idx]
		# Written straight to the file: a display preference must not rewrite profile state.
		var cfg := _load_ui_cfg_for_write()
		if cfg != null:
			cfg.set_value("settings", "ui_scale", sv)
			_persist_ui_cfg(cfg)
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
	# Connected after button_pressed is set, so building the toolbar does not toggle it.
	dev_check.toggled.connect(func(on: bool):
		_developer_mode = on
		# Folder mods are scanned only in developer mode.
		_reload_entries_for_active_profile()
		# The post-boot reopen path has no closing save.
		_save_ui_config()
		_rebuild_mods_tab(tabs)
	)


func _profile_controls(toolbar: HBoxContainer, tabs: TabContainer, active_modpack: String) -> void:
	toolbar.add_child(_make_label("Profile:"))

	var profile_opt := OptionButton.new()
	profile_opt.custom_minimum_size.x = 180
	toolbar.add_child(profile_opt)
	_style_option_popup(profile_opt)

	# On a fresh install Default is a placeholder, written on the first save.
	var profiles := _list_profiles().filter(func(n: String): return not _is_modpack_managed_profile(n))
	if profiles.is_empty():
		profiles = ["Default"]
	# A modpack's hidden managed profile is active; nothing here may change it.
	var modpack_locked := active_modpack != ""
	if modpack_locked:
		profile_opt.add_item("[Modpack: " + active_modpack + "]")
		profile_opt.selected = 0
		profile_opt.disabled = true
	else:
		var active_idx := 0
		for name: String in profiles:
			profile_opt.add_item(name)
			if name == _active_profile:
				active_idx = profile_opt.item_count - 1
		profile_opt.selected = active_idx

	var new_profile_btn := _profile_button(toolbar, null, "+", "Create a new profile",
			"Create a new profile: empty, everything enabled, or a copy of the current selection.", modpack_locked)
	var rename_btn := _profile_button(toolbar, _make_pencil_icon(), "", "Rename the active profile",
			"Rename the active profile.", modpack_locked)
	var del_profile_btn := _profile_button(toolbar, _make_trashcan_icon(), "", "Delete the active profile",
			"Delete the active profile.", modpack_locked)
	# Delete needs another profile to switch to.
	if profiles.size() <= 1:
		del_profile_btn.disabled = true

	profile_opt.item_selected.connect(func(idx: int):
		_switch_profile(profile_opt.get_item_text(idx))
		_rebuild_mods_tab(tabs)
	)
	new_profile_btn.pressed.connect(func(): _show_new_profile_dialog(tabs))
	rename_btn.pressed.connect(func(): _show_rename_profile_dialog(tabs))
	del_profile_btn.pressed.connect(func():
		_show_danger_confirm("Delete profile",
				"Delete profile \"" + _active_profile + "\"?\n\nThe mod selection stored in this profile will be discarded. Your other profiles are not affected.",
				"Delete profile",
				func():
					_delete_active_profile()
					_rebuild_mods_tab(tabs)
		)
	)


func _profile_button(toolbar: HBoxContainer, icon: Texture2D, text: String, tip: String,
		hint: String, locked: bool) -> Button:
	var btn := Button.new()
	btn.text = text
	btn.icon = icon
	btn.tooltip_text = tip if not locked else "Unload the active modpack first"
	btn.disabled = locked
	btn.custom_minimum_size.x = ICON_BTN_W
	toolbar.add_child(btn)
	_wire_hint(btn, hint)
	return btn


func _build_filter_bar(left_col: VBoxContainer, tabs: TabContainer) -> LineEdit:
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
	_wire_hint(all_btn, all_btn.tooltip_text + " (respects the search filter).")

	var none_btn := Button.new()
	none_btn.text = "Disable all"
	none_btn.tooltip_text = "Disable every visible mod"
	filter_bar.add_child(none_btn)
	_wire_hint(none_btn, none_btn.tooltip_text + " (respects the search filter).")

	var hide_check := CheckBox.new()
	hide_check.text = "Hide disabled"
	hide_check.tooltip_text = "Hide rows for mods that are disabled in this profile"
	hide_check.button_pressed = _mods_hide_disabled
	hide_check.add_theme_font_size_override("font_size", FS_BODY)
	filter_bar.add_child(hide_check)
	_wire_hint(hide_check, hide_check.tooltip_text + ".")

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
		# A rebuild during the check frees this button; the rebuild and toast still run.
		if is_instance_valid(check_btn):
			check_btn.disabled = false
			check_btn.text = "Check for updates"
		_rebuild_mods_tab(tabs)
		# With the launcher closed the dialog would parent to the game's root and take input.
		if _ui_window != null:
			_show_info_toast(_updates_check_message(summary))
	)

	# Each rebuild is a full tear-down with disk work, so keystrokes only restart the timer.
	var filter_debounce := Timer.new()
	filter_debounce.one_shot = true
	filter_debounce.wait_time = 0.25
	filter_bar.add_child(filter_debounce)
	filter_debounce.timeout.connect(func():
		_mods_filter_focus_pending = true
		_rebuild_mods_tab(tabs)
	)
	filter_edit.text_changed.connect(func(t: String):
		_mods_filter_text = t
		filter_debounce.stop()
		filter_debounce.start()
	)
	all_btn.pressed.connect(func():
		# With Hide disabled on, the visible rows are exactly the enabled ones and
		# the button would do nothing; Enable all means every filtered row.
		var hide_was := _mods_hide_disabled
		_mods_hide_disabled = false
		for entry in _ui_mod_entries:
			if _mods_entry_visible(entry):
				entry["enabled"] = true
		_mods_hide_disabled = hide_was
		_save_ui_config()
		_rebuild_mods_tab(tabs)
	)
	none_btn.pressed.connect(func():
		# Content mods are among them: confirm once for the batch.
		var content_count := 0
		var content_name := ""
		for entry in _ui_mod_entries:
			if _mods_entry_visible(entry) and entry["enabled"] and entry["has_registry"]:
				content_count += 1
				if content_name == "":
					content_name = entry["mod_name"]
		if content_count > 0:
			var ok: bool = await _confirm_disable_content_mod(content_name, content_count)
			if not ok:
				return
		for entry in _ui_mod_entries:
			if _mods_entry_visible(entry):
				entry["enabled"] = false
		_save_ui_config()
		_rebuild_mods_tab(tabs)
	)
	hide_check.toggled.connect(func(on: bool):
		_mods_hide_disabled = on
		_save_per_profile_setting("hide_disabled", on)
		_rebuild_mods_tab(tabs)
	)
	return filter_edit


func _build_order_panel(split: HSplitContainer) -> Callable:
	var right := VBoxContainer.new()
	right.custom_minimum_size.x = 220
	split.add_child(right)

	var order_header := _make_head_label("Load order")
	order_header.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	right.add_child(order_header)
	right.add_child(HSeparator.new())

	var order_panel := PanelContainer.new()
	order_panel.size_flags_vertical = Control.SIZE_EXPAND_FILL
	order_panel.add_theme_stylebox_override("panel", _make_box(COL_SURFACE_2, NO_BORDER, SP_M, SP_M))
	right.add_child(order_panel)

	# No autowrap and an always-on scrollbar: an autowrap label in a fixed-width ScrollContainer
	# hits a Godot 4.6 layout-oscillation bug that floods the message queue and crashes.
	var order_scroll := ScrollContainer.new()
	order_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	order_scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_SHOW_ALWAYS
	order_panel.add_child(order_scroll)

	var order_list := VBoxContainer.new()
	order_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	order_scroll.add_child(order_list)

	var refresh_order := func():
		# Reuse the loader's own pick: this runs per step while a spin arrow is held.
		var pick: Dictionary = _refresh_dependency_status()
		_clear_children(order_list)
		var loadable: Array = pick["loadable"]
		var enabled_count := int(pick["enabled_count"])
		if enabled_count == 0:
			order_list.add_child(_make_label("No mods enabled", COL_TEXT_DIM))
			return
		if loadable.is_empty():
			order_list.add_child(_make_sub_label(
					"%d enabled, none will load\n(missing dependencies)" % enabled_count,
					COL_WARN,
					"Every enabled mod is missing a required dependency.\nFix it from the orange row warnings, or use Load anyway."))
			return
		for i in loadable.size():
			var e: Dictionary = loadable[i]
			var lbl := _make_sub_label(str(i + 1) + ".  " + str(e["mod_name"]), COL_TEXT, "", FS_EMPH)
			# The full name shows in the status-line hint.
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


func _build_updates(list: VBoxContainer, tabs: TabContainer) -> void:
	var update_keys: Array[String] = []
	for entry in _ui_mod_entries:
		if _mod_updates_state.has(entry["profile_key"]):
			update_keys.append(entry["profile_key"])
	if update_keys.is_empty():
		return
	var hdr_row := HBoxContainer.new()
	hdr_row.add_theme_constant_override("separation", SP_S)
	list.add_child(hdr_row)
	hdr_row.add_child(_make_head_label("Updates available", COL_ACCENT))
	var badge := Label.new()
	badge.text = str(update_keys.size())
	badge.add_theme_stylebox_override("normal", _make_badge_stylebox())
	badge.add_theme_font_size_override("font_size", FS_META)
	badge.add_theme_color_override("font_color", COL_TEXT_HI)
	badge.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	hdr_row.add_child(badge)
	list.add_child(HSeparator.new())

	for pk in update_keys:
		var upd: Dictionary = _mod_updates_state[pk]
		var upd_row := HBoxContainer.new()
		upd_row.add_theme_constant_override("separation", SP_L)
		list.add_child(upd_row)
		var name_lbl := _make_sub_label(str(upd["mod_name"]), COL_TEXT, str(upd["mod_name"]))
		name_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		upd_row.add_child(name_lbl)
		var ver_text := "v%s  ->  v%s" % [upd["current_version"], upd["latest_version"]]
		# Clipped: a long prerelease string must not widen the column.
		var ver_lbl := _make_sub_label(ver_text, COL_TEXT, ver_text)
		ver_lbl.custom_minimum_size.x = 160
		upd_row.add_child(ver_lbl)
		var u_btn := Button.new()
		u_btn.text = "Update"
		upd_row.add_child(u_btn)
		_wire_hint(u_btn, "Download the latest version and replace the installed one.")
		_wire_download_button(u_btn, pk, _DL_TEXTS_UPDATE, tabs,
				_run_mod_update.bind(pk, upd), _after_mod_update.bind(pk))
		list.add_child(HSeparator.new())


# Re-resolves the path live: another surface may have renamed the file.
func _run_mod_update(pk: String, upd: Dictionary) -> Dictionary:
	var r: Dictionary = await replace_mod_from_ref(_live_full_path(pk, upd["full_path"]), upd["ref"])
	if r["ok"]:
		return r
	var detail := str(r["error"])
	var msg := "Could not download %s. Check your connection and try again." % upd["mod_name"]
	if r["local"]:
		msg = "Could not update %s." % upd["mod_name"]
	if detail != "" and detail != "unknown":
		msg += "\n\nDetails: " + detail
	return {"ok": false, "error": msg}


func _after_mod_update(pk: String) -> void:
	_mod_updates_state.erase(pk)
	_reload_entries_for_active_profile()


# The button text per state; "failed" titles the error dialog.
const _DL_TEXTS_UPDATE := {"idle": "Update", "busy": "Updating...", "failed": "Update failed"}
const _DL_TEXTS_MISSING := {"idle": "Download", "busy": "Downloading...", "failed": "Download failed"}

# One download per key at a time: a row rebuilt mid-download shows it busy and a
# second click is refused. `work` returns {ok, error}; on_ok runs before the rebuild.
func _wire_download_button(btn: Button, key: String, texts: Dictionary, tabs: TabContainer,
		work: Callable, on_ok: Callable) -> void:
	if _mod_update_in_flight.has(key):
		btn.disabled = true
		btn.text = texts["busy"]
	btn.pressed.connect(func():
		if _mod_update_in_flight.has(key):
			return
		_mod_update_in_flight[key] = true
		btn.disabled = true
		btn.text = texts["busy"]
		var result: Dictionary = await work.call()
		_mod_update_in_flight.erase(key)
		if result["ok"]:
			on_ok.call()
			_rebuild_mods_tab(tabs)
			return
		if is_instance_valid(btn):
			btn.disabled = false
			btn.text = texts["idle"]
		else:
			# A rebuild mid-download left the replacement button busy; rebuild now the flag is clear.
			_rebuild_mods_tab(tabs)
		# With the launcher closed the dialog would parent to the game's root.
		if _ui_window != null:
			_show_error_dialog(texts["failed"], result["error"])
	)


func _build_missing(list: VBoxContainer, tabs: TabContainer) -> void:
	var missing_files := _missing_mods_in_active_profile()
	if missing_files.is_empty():
		return
	var hdr_row := HBoxContainer.new()
	list.add_child(hdr_row)
	var hdr := _make_head_label("Missing from this profile", COL_ERR)
	hdr.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hdr_row.add_child(hdr)
	var remove_all_btn := Button.new()
	remove_all_btn.text = "Remove all"
	remove_all_btn.tooltip_text = "Remove all missing mods from this profile"
	hdr_row.add_child(remove_all_btn)
	_wire_hint(remove_all_btn, "Remove every missing mod from the active profile.")
	remove_all_btn.pressed.connect(func():
		var n := missing_files.size()
		_show_danger_confirm("Remove missing-mod entries",
				"Remove %d missing-mod entr%s from \"%s\"?\n\nOnly the active profile is affected -- other profiles still list these mods." % [
					n, ("y" if n == 1 else "ies"), _active_profile_label(),
				],
				"Remove",
				func():
					_remove_missing_entries_from_profile(_missing_mods_in_active_profile())
					_rebuild_mods_tab(tabs)
		)
	)
	list.add_child(HSeparator.new())

	var missing_sources := _missing_mod_sources_combined()
	for fn: String in missing_files:
		_missing_row(list, fn, missing_sources, tabs)
		list.add_child(HSeparator.new())


func _missing_row(list: VBoxContainer, fn: String, missing_sources: Dictionary, tabs: TabContainer) -> void:
	var miss_row := HBoxContainer.new()
	list.add_child(miss_row)
	var miss_text := fn.trim_prefix("zip:").trim_prefix(HOSTED_KEY_PREFIX) + "  --  not installed"
	var miss_lbl := _make_sub_label(miss_text, COL_ERR, miss_text)
	miss_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	miss_row.add_child(miss_lbl)

	# The records are normalized already; this runs in pass 1, where a crash blocks the main menu.
	var src_ref := {}
	var src_version := ""
	if missing_sources.has(fn):
		src_ref = _source_host_ref(missing_sources[fn])
		src_version = str(missing_sources[fn]["version"])
	if _modpack_ref_downloadable(src_ref):
		var src_host := host_display_name(str(src_ref["provider"]))
		var dl_btn := Button.new()
		dl_btn.text = "Download"
		dl_btn.tooltip_text = "Download this mod from " + src_host
		miss_row.add_child(dl_btn)
		_wire_hint(dl_btn, "Download this mod from " + src_host + ".")
		# Keyed by the stored profile key, so a rebuild mid-download keeps the new button busy.
		_wire_download_button(dl_btn, fn, _DL_TEXTS_MISSING, tabs,
				_run_missing_download.bind(src_ref, src_version), _after_missing_download)
	else:
		var no_src_lbl := _make_label("Download unavailable", COL_TEXT_DIM, FS_BODY)
		no_src_lbl.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		# STOP so the label gets the hover signals.
		no_src_lbl.mouse_filter = Control.MOUSE_FILTER_STOP
		miss_row.add_child(no_src_lbl)
		_wire_hint(no_src_lbl,
			"This mod does not say which site it came from, so it can't be downloaded automatically. Reinstall it manually.")

	var remove_btn := Button.new()
	remove_btn.text = "Remove"
	remove_btn.tooltip_text = "Remove this missing mod from this profile"
	miss_row.add_child(remove_btn)
	_wire_hint(remove_btn, "Remove this mod from the active profile.")
	remove_btn.pressed.connect(func():
		_remove_missing_entries_from_profile([fn])
		_rebuild_mods_tab(tabs)
	)


func _run_missing_download(src_ref: Dictionary, src_version: String) -> Dictionary:
	# allow_rename_on_collision: dedup happens at scan time.
	var r: Dictionary = await download_mod_from_ref(src_ref, src_version, true)
	# Authors delete old files. A pack's row keeps its pin; a profile's own
	# missing mod takes the site's current file instead of a dead end.
	if not r["ok"] and src_version != "" and get_active_modpack() == "" \
			and str(r.get("code", "")) == HOST_ERR_VERSION_NOT_FOUND:
		r = await download_mod_from_ref(src_ref, "", true)
	return r


func _after_missing_download() -> void:
	_reload_entries_for_active_profile()
	# A pack's missing row is keyed by the pack; move it to the key the mod landed under.
	_modpack_reconcile_active()
