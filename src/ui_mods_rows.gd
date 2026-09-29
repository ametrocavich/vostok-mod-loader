## Installed mod rows: controls, host metadata, dependencies and author notes.
## ui_mods.gd owns the list and passes the current entries and callbacks.

# Column headers over the mod rows.
func _mods_build_header_row(list: VBoxContainer) -> void:
	var header_row := HBoxContainer.new()
	list.add_child(header_row)

	var h_on := Label.new()
	h_on.text = "On"
	h_on.add_theme_font_size_override("font_size", FS_META)
	h_on.add_theme_color_override("font_color", COL_TEXT_DIM)
	h_on.custom_minimum_size.x = 30
	header_row.add_child(h_on)

	# Spacer over the thumbnail column so "Mod" sits above the name text.
	var h_thumb := Control.new()
	h_thumb.custom_minimum_size.x = 96
	header_row.add_child(h_thumb)

	var h_name := Label.new()
	h_name.text = "Mod"
	h_name.add_theme_font_size_override("font_size", FS_META)
	h_name.add_theme_color_override("font_color", COL_TEXT_DIM)
	h_name.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header_row.add_child(h_name)

	var h_prio := Label.new()
	h_prio.text = "Load order"
	h_prio.add_theme_font_size_override("font_size", FS_META)
	h_prio.add_theme_color_override("font_color", COL_TEXT_DIM)
	h_prio.custom_minimum_size.x = 100
	h_prio.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	header_row.add_child(h_prio)

	# Spacer matching the per-row trash button so the header aligns.
	var h_tail := Control.new()
	h_tail.custom_minimum_size.x = 28
	header_row.add_child(h_tail)

	list.add_child(HSeparator.new())


# One mod row: checkbox, thumbnail and name column, load-order spinner,
# Remove button, and the handlers that write through to the live entry.
func _mods_build_row(list: VBoxContainer, entry: Dictionary, tabs: TabContainer, refresh_order: Callable,
		persisted_sources: Dictionary, dep_names_by_id: Dictionary, profile_editable: bool) -> void:
	var row := HBoxContainer.new()
	list.add_child(row)

	var check := CheckBox.new()
	check.button_pressed = entry["enabled"]
	check.custom_minimum_size.x = 30
	row.add_child(check)

	var name_parts := _mods_row_name_column(row, entry, persisted_sources)
	var name_col: VBoxContainer = name_parts["name_col"]
	var name_ctrl: Control = name_parts["name_ctrl"]
	_mods_row_dependency_lines(name_col, name_ctrl, entry, dep_names_by_id, profile_editable, tabs)
	_mods_row_notes(name_col, entry)

	var spin := SpinBox.new()
	spin.min_value = PRIORITY_MIN
	spin.max_value = PRIORITY_MAX
	spin.value = entry["priority"]
	spin.custom_minimum_size.x = 100
	spin.custom_minimum_size.y = CTRL_H
	row.add_child(spin)

	# Per-row Remove. Folder mods skip the file delete: recursive deletion of a
	# working directory is too risky to do casually.
	var remove_btn := Button.new()
	remove_btn.icon = _make_trashcan_icon()
	remove_btn.flat = true
	remove_btn.custom_minimum_size.x = 28
	remove_btn.disabled = entry["ext"] == "folder"
	if entry["ext"] == "folder":
		remove_btn.tooltip_text = "Use Open mods folder to remove dev folders"
	else:
		remove_btn.tooltip_text = "Permanently delete this mod"
	row.add_child(remove_btn)
	var captured_remove_entry := entry
	remove_btn.pressed.connect(func():
		_show_remove_mod_confirm(captured_remove_entry, tabs)
	)

	list.add_child(HSeparator.new())

	# Capture entry by reference (Dictionaries are reference types in GDScript)
	var e := entry
	check.toggled.connect(func(on: bool):
		# Disabling a mod that registers game content can stop an existing save
		# from loading; confirm first, and revert the checkbox on cancel.
		if not on and bool(e.get("has_registry", false)):
			var ok: bool = await _confirm_disable_content_mod(str(e.get("mod_name", "this mod")))
			if not ok:
				# An async rebuild may have freed this checkbox while the dialog was open.
				if is_instance_valid(check):
					check.set_pressed_no_signal(true)
				return
		# Write to the live entry: a mid-dialog rescan replaces _ui_mod_entries
		# with fresh dicts, and a confirmed disable must not be dropped.
		var live := _live_entry_for_profile_key(str(e.get("profile_key", "")), e)
		live["enabled"] = on
		# Full rebuild: dependency state on other rows changes with the enabled set.
		_after_dep_action(tabs)
	)
	spin.value_changed.connect(func(val: float):
		# Write through the live entry: a mid-drag rescan orphans the captured `e`.
		var live_spin := _live_entry_for_profile_key(str(e.get("profile_key", "")), e)
		live_spin["priority"] = int(val)
		# No rebuild here: value_changed fires per step while the arrows are held
		# and a rebuild would destroy the SpinBox under the cursor.
		refresh_order.call()
		# Debounce the disk save: a held arrow fires value_changed per step and
		# each _save_ui_config is a full ConfigFile load and rewrite.
		_schedule_priority_save()
	)


# Thumbnail cell plus the name column: a clickable name for hosted mods, a
# plain label otherwise, and the dev-folder marker. Returns {name_col, name_ctrl}.
func _mods_row_name_column(row: HBoxContainer, entry: Dictionary, persisted_sources: Dictionary) -> Dictionary:
	# Host info column: async thumbnail, author line and name click-through to
	# the detail dialog. Mods with no host keep the same-width cell so the name
	# column stays aligned.
	var row_ref := _entry_host_ref(entry, persisted_sources)
	var row_key := host_ref_key(row_ref)
	var row_browsable := row_key != "" and bool(host_caps(str(row_ref["provider"]))["browse"])
	var meta_holder: Dictionary = {}
	var thumb_ref: TextureRect = null
	# Every row gets a thumbnail cell. A hosted row reads "loading..." until
	# the meta fetch paints it or fails; a row with no host has nothing to fetch.
	var thumb_rect := _make_thumb_cell(row, Vector2(96, 54), true, true)
	if row_browsable:
		thumb_ref = thumb_rect
	else:
		_set_thumb_state(thumb_rect, "none")

	var name_col := VBoxContainer.new()
	name_col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	name_col.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(name_col)

	# name_ctrl: clickable for hosted mods, plain Label otherwise.
	var name_ctrl: Control
	if row_browsable:
		# Flat Button, not LinkButton, so clip_text keeps a long name from widening the row.
		var name_lnk := Button.new()
		name_lnk.flat = true
		name_lnk.text = entry["mod_name"]
		name_lnk.clip_text = true
		name_lnk.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		name_lnk.alignment = HORIZONTAL_ALIGNMENT_LEFT
		name_lnk.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		var row_host := host_display_name(str(row_ref["provider"]))
		name_lnk.tooltip_text = str(entry["mod_name"]) + "  --  click for " + row_host + " details"
		name_lnk.add_theme_color_override("font_color", COL_OK if entry["enabled"] else COL_TEXT_DIM)
		name_lnk.add_theme_color_override("font_hover_color", COL_TEXT_HI)
		name_col.add_child(name_lnk)
		name_lnk.pressed.connect(_open_mods_host_detail.bind(meta_holder, row_ref))
		# Register the row's live nodes before the meta load so paints resolve to
		# current nodes. Appended: several rows can share one host mod.
		var meta_rows: Array = _mods_meta_nodes.get(row_key, [])
		meta_rows.append({
			"thumb": thumb_ref,
			"name_col": name_col,
			"holder": meta_holder,
		})
		_mods_meta_nodes[row_key] = meta_rows
		_mods_load_host_meta(row_ref)
		name_ctrl = name_lnk
	else:
		var name_lbl := Label.new()
		name_lbl.text = entry["mod_name"]
		name_lbl.clip_text = true
		name_lbl.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		name_lbl.tooltip_text = str(entry["mod_name"])
		name_lbl.mouse_filter = Control.MOUSE_FILTER_PASS
		name_lbl.add_theme_color_override("font_color", COL_OK if entry["enabled"] else COL_TEXT_DIM)
		name_col.add_child(name_lbl)
		name_ctrl = name_lbl

	if entry["ext"] == "folder":
		var dev_lbl := Label.new()
		dev_lbl.text = "[dev folder]"
		dev_lbl.add_theme_color_override("font_color", COL_ERR)
		dev_lbl.add_theme_font_size_override("font_size", FS_BODY)
		name_col.add_child(dev_lbl)
	return {"name_col": name_col, "name_ctrl": name_ctrl}


# The dependency summary line, row warnings, and the blocked or
# check-disabled row with its quick actions.
func _mods_row_dependency_lines(name_col: VBoxContainer, name_ctrl: Control, entry: Dictionary,
		dep_names_by_id: Dictionary, profile_editable: bool, tabs: TabContainer) -> void:
	# Dependencies: one clipped line; the actionable blocked row renders below.
	var required_deps: Array = entry.get("required_dependencies", [])
	var optional_deps: Array = entry.get("optional_dependencies", [])
	var blockers_info: Array = entry.get("dependency_blockers_info", [])
	var dep_ignored := bool(entry.get("dependency_ignored", false))
	var dep_blocked: bool = entry["enabled"] \
			and not (entry.get("dependency_blockers", []) as Array).is_empty()
	if dep_blocked:
		# The green "enabled" tint would lie. This mod won't load.
		name_ctrl.add_theme_color_override("font_color", COL_WARN)
	if required_deps.size() > 0 or optional_deps.size() > 0:
		var named := PackedStringArray()
		for d in required_deps:
			named.append(_dependency_display_for_id(str(d), dep_names_by_id))
		var dep_line := ""
		if named.size() > 0:
			dep_line = "needs: " + ", ".join(named)
		if optional_deps.size() > 0:
			if dep_line != "":
				dep_line += "  (+%d optional)" % optional_deps.size()
			else:
				dep_line = "%d optional integration(s)" % optional_deps.size()
		var tip := PackedStringArray()
		for d in required_deps:
			tip.append("requires %s (%s)" % [_dependency_display_for_id(str(d), dep_names_by_id), str(d)])
		for d in optional_deps:
			tip.append("optional: %s (%s)" % [_dependency_display_for_id(str(d), dep_names_by_id), str(d)])
		name_col.add_child(_make_sub_label(dep_line, COL_TEXT_DIM, "\n".join(tip)))
	# Red: every entry warning is a mod that will not work as packaged.
	for warn_text: String in entry.get("warnings", []):
		name_col.add_child(_make_sub_label(warn_text, COL_ERR, warn_text))
	if _developer_mode:
		for note_text: String in entry.get("author_notes", []):
			name_col.add_child(_make_sub_label(note_text, COL_TEXT_DIM, note_text))
	for warn_text: String in entry.get("dependency_warnings", []):
		name_col.add_child(_make_sub_label(warn_text, COL_WARN, warn_text))

	# Blocked: one orange line naming the cause plus buttons that fix it.
	if dep_blocked and not blockers_info.is_empty():
		var block_row := HBoxContainer.new()
		block_row.add_theme_constant_override("separation", SP_M)
		name_col.add_child(block_row)
		var first: Dictionary = blockers_info[0]
		# display already reads "Name (id)"; a dash avoids a second paren.
		var why := "%s -- %s" % [str(first.get("display", "")),
				_dependency_status_label(str(first.get("status", "")))]
		if blockers_info.size() > 1:
			why += "  +%d more" % (blockers_info.size() - 1)
		var btip := PackedStringArray()
		for b in blockers_info:
			btip.append("%s -- %s" % [str(b.get("display", "")),
					_dependency_status_label(str(b.get("status", "")))])
			if str(b.get("status", "")) == "hidden_folder":
				btip.append("  (turn on Developer mode to load folder mods)")
		var bl := _make_sub_label("won't load -- needs " + why, COL_WARN, "\n".join(btip))
		bl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		block_row.add_child(bl)
		var fixable_count := 0
		for b in blockers_info:
			if bool(b.get("fixable", false)):
				fixable_count += 1
		var e_dep := entry
		if fixable_count > 0 and profile_editable:
			var fix_btn := _make_row_action(
					"Enable " + ("%d dependencies" % fixable_count \
							if fixable_count > 1 else "dependency"),
					COL_OK,
					"Turn on the required mod(s) -- installed, just disabled.")
			block_row.add_child(fix_btn)
			fix_btn.pressed.connect(func():
				_enable_required_deps(e_dep)
				_after_dep_action(tabs)
			)
		if profile_editable:
			var anyway_btn := _make_row_action("Load anyway", COL_TEXT_DIM,
					"Skip the dependency check for this mod in this profile.\nFor when a requirement is declared wrong or you know better.")
			block_row.add_child(anyway_btn)
			anyway_btn.pressed.connect(func():
				e_dep["dependency_ignored"] = true
				_after_dep_action(tabs)
			)
	elif dep_ignored and not blockers_info.is_empty():
		# Override active while requirements are unmet: show what is ignored and the way back.
		var ov_row := HBoxContainer.new()
		ov_row.add_theme_constant_override("separation", SP_M)
		name_col.add_child(ov_row)
		var missing_names := PackedStringArray()
		for b in blockers_info:
			missing_names.append(str(b.get("display", "")))
		var ov := _make_sub_label("dependency check off -- missing: " + ", ".join(missing_names),
				COL_TEXT_DIM,
				"This mod loads even though requirements are unmet\n(per-profile override). Re-check restores the normal rule.")
		ov.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		ov_row.add_child(ov)
		if profile_editable:
			var e_dep2 := entry
			var recheck_btn := _make_row_action("Re-check", COL_TEXT_DIM)
			ov_row.add_child(recheck_btn)
			recheck_btn.pressed.connect(func():
				e_dep2["dependency_ignored"] = false
				_after_dep_action(tabs)
			)


# Hidden-duplicate and version-change notes, and the scanner badge.
func _mods_row_notes(name_col: VBoxContainer, entry: Dictionary) -> void:
	# Older same-id archives the dedup pass hid; name the file to delete.
	for dup: Dictionary in entry.get("duplicates_hidden", []):
		var dup_v_raw: String = str(dup.get("version", ""))
		var dup_v: String = ("v" + dup_v_raw) if dup_v_raw != "" else "(unversioned)"
		var hide_text := "older version hidden: " + str(dup["file_name"]) + " (" + dup_v + ")"
		name_col.add_child(_make_sub_label(hide_text, COL_WARN, hide_text))

	# The profile was saved with another version of this mod; show that the
	# enabled/priority state was carried over rather than re-defaulted.
	var vm: Dictionary = entry.get("profile_version_mismatch", {})
	if not vm.is_empty():
		var stored_v: String = str(vm.get("stored", ""))
		var current_v: String = str(vm.get("current", ""))
		var stored_disp := stored_v if stored_v != "" else "(unset)"
		var current_disp := current_v if current_v != "" else "(unset)"
		var vm_text := "version changed: " + stored_disp + " -> " + current_disp
		name_col.add_child(_make_sub_label(vm_text, COL_ACCENT, vm_text))

	# Scanner indicator, red risk only: pattern combinations that are close
	# to diagnostic of malware. Elevated-API findings are logged but not
	# shown; most legitimate mods have one. Loading is never blocked.
	var risk: int = int(entry.get("risk_level", RISK_CLEAN))
	if risk == RISK_RED:
		var sec_btn := Button.new()
		sec_btn.text = "suspicious code"
		sec_btn.flat = true
		sec_btn.tooltip_text = "Show what the scanner flagged in this mod"
		sec_btn.add_theme_color_override("font_color", COL_ERR)
		# Flat buttons have no hover stylebox; the font shift is the hover cue.
		sec_btn.add_theme_color_override("font_hover_color", COL_ERR.lerp(COL_TEXT_HI, 0.35))
		sec_btn.add_theme_font_size_override("font_size", FS_BODY)
		sec_btn.alignment = HORIZONTAL_ALIGNMENT_LEFT
		sec_btn.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
		name_col.add_child(sec_btn)
		var captured_entry := entry
		sec_btn.pressed.connect(func(): _show_security_findings_dialog(captured_entry))
