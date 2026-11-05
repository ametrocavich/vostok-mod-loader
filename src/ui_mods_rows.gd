## Installed mod rows: checkbox, thumbnail and name, dependency lines, load order
## and Remove. ui_mods.gd builds the list around them.

# The trash column is ICON_BTN_W.
const _MODS_COL_CHECK_W := 30
const _MODS_COL_THUMB_W := 96
const _MODS_COL_PRIO_W := 100

func _build_row(list: VBoxContainer, entry: Dictionary, tabs: TabContainer, refresh_order: Callable,
		persisted_sources: Dictionary, dep_names_by_id: Dictionary, profile_editable: bool) -> void:
	var row := HBoxContainer.new()
	list.add_child(row)

	var check := CheckBox.new()
	check.button_pressed = entry["enabled"]
	check.custom_minimum_size.x = _MODS_COL_CHECK_W
	row.add_child(check)

	var blocked: bool = entry["enabled"] and not (entry["dependency_blockers"] as Array).is_empty()
	var name_col := _row_name_column(row, entry, persisted_sources, blocked)
	_row_details(name_col, entry, blocked, dep_names_by_id, profile_editable, tabs)

	var spin := SpinBox.new()
	spin.min_value = PRIORITY_MIN
	spin.max_value = PRIORITY_MAX
	spin.value = entry["priority"]
	spin.custom_minimum_size.x = _MODS_COL_PRIO_W
	spin.custom_minimum_size.y = CTRL_H
	row.add_child(spin)

	# Folder mods skip the file delete: recursively deleting a working directory is too risky.
	var remove_btn := Button.new()
	remove_btn.icon = _make_trashcan_icon()
	remove_btn.flat = true
	remove_btn.custom_minimum_size.x = ICON_BTN_W
	remove_btn.disabled = entry["ext"] == "folder"
	if entry["ext"] == "folder":
		remove_btn.tooltip_text = "Use Open mods folder to remove dev folders"
	else:
		remove_btn.tooltip_text = "Permanently delete this mod"
	row.add_child(remove_btn)
	remove_btn.pressed.connect(func():
		var size_line := ""
		var path: String = entry["full_path"]
		if FileAccess.file_exists(path):
			var f := FileAccess.open(path, FileAccess.READ)
			if f != null:
				size_line = "\nSize: " + _format_size(f.get_length())
				f.close()
		var text := "Permanently delete \"%s\"?\n\nFile: %s%s\n\nThis will:\n  - Delete the file from disk\n  - Remove the mod from EVERY profile, not just \"%s\"\n\nThis cannot be undone." % [
			entry["mod_name"], entry["file_name"], size_line, _active_profile_label()]
		_show_danger_confirm("Remove mod", text, "Delete mod", func():
			if _delete_mod_file_and_cleanup(entry):
				_reload_entries_for_active_profile()
				_rebuild_mods_tab(tabs)
			else:
				_show_error_dialog("Could not delete mod", "Could not remove %s. If this mod is enabled, its archive is mounted and the file stays locked while the game is open -- disable it, relaunch the game, then delete." % entry["file_name"])
		)
	)

	list.add_child(HSeparator.new())

	check.toggled.connect(func(on: bool):
		# Disabling a mod that registers game content can stop an existing save from loading.
		if not on and entry["has_registry"]:
			var ok: bool = await _confirm_disable_content_mod(entry["mod_name"])
			if not ok:
				# A rebuild while the dialog was open may have freed this checkbox.
				if is_instance_valid(check):
					check.set_pressed_no_signal(true)
				return
		# A rescan while the dialog was open replaces _ui_mod_entries with fresh dicts.
		var live := _live_entry_for_profile_key(entry["profile_key"], entry)
		live["enabled"] = on
		# Full rebuild: the enabled set changes dependency state on other rows.
		_after_dep_action(tabs)
	)
	spin.value_changed.connect(func(val: float):
		var live := _live_entry_for_profile_key(entry["profile_key"], entry)
		live["priority"] = int(val)
		# value_changed fires per step while an arrow is held: a rebuild would free
		# the SpinBox under the cursor, and each save rewrites the whole config.
		refresh_order.call()
		_schedule_priority_save()
		refresh_launch_button_label()
	)


func _row_name_column(row: HBoxContainer, entry: Dictionary, persisted_sources: Dictionary,
		blocked: bool) -> VBoxContainer:
	var ref := _entry_host_ref(entry, persisted_sources)
	var key := host_ref_key(ref)
	var browsable := key != "" and bool(host_caps(str(ref["provider"]))["browse"])
	# Every row gets the cell so the names line up; a hosted row says "loading..." until painted.
	var thumb := _make_thumb_cell(row, Vector2(_MODS_COL_THUMB_W, 54), true, true)
	if not browsable:
		_set_thumb_state(thumb, "none")

	var name_col := VBoxContainer.new()
	name_col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	name_col.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(name_col)

	# A blocked mod won't load, so the green "enabled" tint would lie.
	var color := COL_WARN if blocked else (COL_OK if entry["enabled"] else COL_TEXT_DIM)
	if browsable:
		# Flat Button, not LinkButton, so clip_text keeps a long name from widening the row.
		var link := Button.new()
		link.flat = true
		link.text = entry["mod_name"]
		link.clip_text = true
		link.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		link.alignment = HORIZONTAL_ALIGNMENT_LEFT
		link.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		var host := host_display_name(str(ref["provider"]))
		link.tooltip_text = str(entry["mod_name"]) + "  --  click for " + host + " details"
		link.add_theme_color_override("font_color", color)
		link.add_theme_color_override("font_hover_color", COL_TEXT_HI)
		name_col.add_child(link)
		link.pressed.connect(_open_host_detail.bind(ref))
		# Registered before the meta load so a paint finds this row; several rows can share one mod.
		var meta_rows: Array = _mods_meta_nodes.get(key, [])
		meta_rows.append({"thumb": thumb, "name_col": name_col})
		_mods_meta_nodes[key] = meta_rows
		_load_host_meta(ref)
	else:
		name_col.add_child(_make_sub_label(str(entry["mod_name"]), color, str(entry["mod_name"])))

	if entry["ext"] == "folder":
		name_col.add_child(_make_label("[dev folder]", COL_ERR, FS_BODY))
	return name_col


# Under the name: dependencies, warnings, the dependency check, hidden duplicates, version change.
func _row_details(name_col: VBoxContainer, entry: Dictionary, blocked: bool, dep_names_by_id: Dictionary,
		profile_editable: bool, tabs: TabContainer) -> void:
	var required: Array = entry["required_dependencies"]
	var optional: Array = entry["optional_dependencies"]
	if not (required.is_empty() and optional.is_empty()):
		var named := PackedStringArray()
		var tip := PackedStringArray()
		for d in required:
			var shown := _dependency_display_for_id(str(d), dep_names_by_id)
			named.append(shown)
			tip.append("requires %s (%s)" % [shown, str(d)])
		for d in optional:
			tip.append("optional: %s (%s)" % [_dependency_display_for_id(str(d), dep_names_by_id), str(d)])
		var dep_line := "%d optional integration(s)" % optional.size()
		if not named.is_empty():
			dep_line = "needs: " + ", ".join(named)
			if not optional.is_empty():
				dep_line += "  (+%d optional)" % optional.size()
		name_col.add_child(_make_sub_label(dep_line, COL_TEXT_DIM, "\n".join(tip)))

	for text: String in entry["warnings"]:
		name_col.add_child(_make_sub_label(text, COL_ERR, text))
	if _developer_mode:
		for text: String in entry["author_notes"]:
			name_col.add_child(_make_sub_label(text, COL_TEXT_DIM, text))
	for text: String in entry["dependency_warnings"]:
		name_col.add_child(_make_sub_label(text, COL_WARN, text))

	var blockers_info: Array = entry["dependency_blockers_info"]
	if blocked and not blockers_info.is_empty():
		_row_blocked(name_col, entry, blockers_info, profile_editable, tabs)
	elif entry["dependency_ignored"] and not blockers_info.is_empty():
		var ov_row := HBoxContainer.new()
		ov_row.add_theme_constant_override("separation", SP_M)
		name_col.add_child(ov_row)
		var missing := PackedStringArray()
		for b: Dictionary in blockers_info:
			missing.append(str(b["display"]))
		var ov := _make_sub_label("dependency check off -- missing: " + ", ".join(missing),
				COL_TEXT_DIM,
				"This mod loads even though requirements are unmet\n(per-profile override). Re-check restores the normal rule.")
		ov.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		ov_row.add_child(ov)
		if profile_editable:
			var recheck_btn := _make_row_action("Re-check", COL_TEXT_DIM)
			ov_row.add_child(recheck_btn)
			recheck_btn.pressed.connect(func():
				entry["dependency_ignored"] = false
				_after_dep_action(tabs)
			)

	for dup: Dictionary in entry.get("duplicates_hidden", []):
		var hide_text := "older version hidden: " + str(dup["file_name"]) + " (" + _version_label(dup["version"]) + ")"
		name_col.add_child(_make_sub_label(hide_text, COL_WARN, hide_text))

	# The profile was saved with another version: its enabled and priority state carried over.
	var vm: Dictionary = entry.get("profile_version_mismatch", {})
	if not vm.is_empty():
		var stored := str(vm["stored"])
		var current := str(vm["current"])
		var vm_text := "version changed: " + (stored if stored != "" else "(unset)") \
				+ " -> " + (current if current != "" else "(unset)")
		name_col.add_child(_make_sub_label(vm_text, COL_ACCENT, vm_text))


func _row_blocked(name_col: VBoxContainer, entry: Dictionary, blockers_info: Array,
		profile_editable: bool, tabs: TabContainer) -> void:
	var block_row := HBoxContainer.new()
	block_row.add_theme_constant_override("separation", SP_M)
	name_col.add_child(block_row)
	var tips := PackedStringArray()
	var fixable := 0
	for b: Dictionary in blockers_info:
		# display already reads "Name (id)"; a dash avoids a second paren.
		tips.append("%s -- %s" % [str(b["display"]), _dependency_status_label(str(b["status"]))])
		if b["status"] == "hidden_folder":
			tips.append("  (turn on Developer mode to load folder mods)")
		if b["fixable"]:
			fixable += 1
	var why := tips[0]
	if blockers_info.size() > 1:
		why += "  +%d more" % (blockers_info.size() - 1)
	var bl := _make_sub_label("won't load -- needs " + why, COL_WARN, "\n".join(tips))
	bl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	block_row.add_child(bl)
	if fixable > 0 and profile_editable:
		var fix_btn := _make_row_action(
				"Enable " + ("%d dependencies" % fixable if fixable > 1 else "dependency"),
				COL_OK,
				"Turn on the required mod(s) -- installed, just disabled.")
		block_row.add_child(fix_btn)
		fix_btn.pressed.connect(func():
			_enable_required_deps(entry)
			_after_dep_action(tabs)
		)
	if profile_editable:
		var anyway_btn := _make_row_action("Load anyway", COL_TEXT_DIM,
				"Skip the dependency check for this mod in this profile.\nFor when a requirement is declared wrong or you know better.")
		block_row.add_child(anyway_btn)
		anyway_btn.pressed.connect(func():
			entry["dependency_ignored"] = true
			_after_dep_action(tabs)
		)
