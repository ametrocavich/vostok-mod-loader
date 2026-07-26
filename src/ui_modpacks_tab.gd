func _show_modpack_failure_dialog(downloaded: int, failures: Array, tabs: TabContainer) -> void:
	var d := AcceptDialog.new()
	d.title = "Modpack applied with issues"
	d.ok_button_text = "Close"
	# Clamped to the launcher: at the 640x420 window minimum a fixed
	# 540x420 dialog was clipped by the embedder (button bar cut off).
	d.min_size = _dialog_fit_size(Vector2i(540, 420))

	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", SP_M)
	d.add_child(box)

	var hdr := Label.new()
	hdr.text = "Downloaded %d mod(s), %d failed." % [downloaded, failures.size()]
	box.add_child(hdr)

	var scroll := ScrollContainer.new()
	# Track the (possibly clamped) dialog size, keeping the original
	# 20x140 chrome allowance (540x420 dialog held a 520x280 scroll).
	scroll.custom_minimum_size = Vector2(d.min_size - Vector2i(20, 140))
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	box.add_child(scroll)

	var list_wrap := MarginContainer.new()
	list_wrap.add_theme_constant_override("margin_right", SP_XL)
	list_wrap.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(list_wrap)

	var list := VBoxContainer.new()
	list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	list.add_theme_constant_override("separation", SP_S)
	list_wrap.add_child(list)

	for f_v in failures:
		if not (f_v is Dictionary):
			continue
		var f: Dictionary = f_v
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", SP_M)
		list.add_child(row)

		var info_col := VBoxContainer.new()
		info_col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(info_col)

		var name_lbl := Label.new()
		name_lbl.text = str(f.get("profile_key", "?"))
		name_lbl.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		name_lbl.tooltip_text = name_lbl.text
		name_lbl.mouse_filter = Control.MOUSE_FILTER_PASS
		info_col.add_child(name_lbl)

		var err_lbl := Label.new()
		err_lbl.text = str(f.get("error", "unknown"))
		err_lbl.add_theme_font_size_override("font_size", FS_BODY)
		err_lbl.add_theme_color_override("font_color", COL_ERR)
		err_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		info_col.add_child(err_lbl)

		var mws_id: int = int(f.get("mws_id", 0))
		if mws_id > 0:
			var open_btn := Button.new()
			open_btn.text = "Open ModWorkshop page"
			open_btn.size_flags_vertical = Control.SIZE_SHRINK_CENTER
			row.add_child(open_btn)
			open_btn.pressed.connect(func():
				OS.shell_open(MODWORKSHOP_PAGE_URL_TEMPLATE % str(mws_id))
			)

	# Footer: Retry button via add_button so it sits in the dialog's native
	# button bar alongside the Close button. Disabled if there's no failure
	# with a known mws_id (nothing to retry).
	var retry_btn: Button = null
	var any_retryable := false
	for f_v in failures:
		if f_v is Dictionary and int((f_v as Dictionary).get("mws_id", 0)) > 0:
			any_retryable = true
			break
	if any_retryable:
		retry_btn = d.add_button("Retry failed", false, "")
		style_primary_button(retry_btn)
		var captured_failures := failures
		retry_btn.pressed.connect(func():
			d.queue_free()
			_run_modpack_retry(captured_failures, tabs)
		)

	_attach_ui_dialog(d)
	_wire_accept_dismiss(d)
	d.popup_centered()


# Run a retry pass on previously-failed modpack downloads. Shows a progress
# dialog during, then re-shows the failure dialog if anything still failed
# (with one fewer entry typically -- successfully retried mods drop off).
func _run_modpack_retry(failures: Array, tabs: TabContainer) -> void:
	# Reuse the apply progress dialog so the retry pass gets the same
	# ProgressBar + Cancel affordance. The old hand-rolled dialog swallowed
	# ESC (correctly -- a hidden exclusive dialog lifts the input block) but
	# offered NO cancel control, trapping the user for the whole sequential
	# download run (up to 300s per item on a bad connection). Cancel sets
	# the shared _modpack_apply_cancelled flag, which
	# retry_failed_downloads checks at each loop top.
	_modpack_apply_cancelled = false
	var progress_ui := _build_modpack_progress_dialog("", "Retrying failed downloads")
	var pd: AcceptDialog = progress_ui["dialog"]
	var pd_bar: ProgressBar = progress_ui["bar"]
	var status_lbl: Label = progress_ui["status"]
	var pd_cancel: Button = progress_ui["cancel"]
	pd_cancel.pressed.connect(func():
		if is_instance_valid(status_lbl):
			status_lbl.text = "Cancelling after current download..."
		if is_instance_valid(pd_cancel):
			pd_cancel.disabled = true
			pd_cancel.text = "Cancelling..."
		_modpack_apply_cancelled = true
	)
	pd.popup_centered()

	var progress_cb := func(p: Dictionary):
		if not is_instance_valid(status_lbl):
			return
		var cur := int(p.get("current", 0))
		var tot := int(p.get("total", 0))
		var nm := str(p.get("mod_name", ""))
		var act := str(p.get("action", ""))
		if is_instance_valid(pd_bar) and tot > 0:
			pd_bar.value = float(cur) / float(tot) * 100.0
		if act == "rate_wait":
			status_lbl.text = "Rate limited by ModWorkshop -- resuming in %ds" % int(p.get("wait_s", 0))
			return
		if nm != "":
			status_lbl.text = "Retrying %d of %d:\n%s" % [cur, tot, nm]
		else:
			status_lbl.text = "Retrying..."

	var result := await retry_failed_downloads(failures, progress_cb)

	if is_instance_valid(pd):
		pd.queue_free()

	# Refresh Mods tab so newly-downloaded mods aren't stuck in the
	# missing-mod stub list.
	if is_instance_valid(tabs):
		_rebuild_mods_tab(tabs)

	var still_failed: Array = result.get("failures", [])
	var dl: int = int(result.get("downloaded", 0))
	if still_failed.is_empty():
		# Everything recovered -- short success dialog instead of the
		# error-styled failure one.
		var ok_d := AcceptDialog.new()
		ok_d.title = "Retry complete"
		ok_d.dialog_text = "Downloaded %d mod(s) on retry." % dl
		ok_d.ok_button_text = "Close"
		_attach_ui_dialog(ok_d)
		_wire_accept_dismiss(ok_d)
		ok_d.popup_centered()
	else:
		_show_modpack_failure_dialog(dl, still_failed, tabs)


# Build and show a borderless accept dialog with a single dismiss button.
# Backs _show_error_dialog / _show_info_toast, which differ only in title,
# button text, and minimum width.
func _make_tab_margin() -> MarginContainer:
	var m := MarginContainer.new()
	m.add_theme_constant_override("margin_left", 8)
	m.add_theme_constant_override("margin_right", 8)
	m.add_theme_constant_override("margin_top", 6)
	m.add_theme_constant_override("margin_bottom", 6)
	return m

# Restore-point picker: lists the automatic pre-apply snapshots (newest first)
# and, after a confirm, restores the chosen one over live state -- a full revert
# of mod_config.cfg + MCM + saved override files to how things were before that
# apply. Re-reads state from the restored cfg and rebuilds the tabs.
func _show_restore_snapshot_dialog(tabs: TabContainer) -> void:
	# Restore points are always captured while NO pack is active, so restoring
	# one while a pack IS active would rewrite cfg to a no-pack state and leave
	# the active pack's override files live with nothing tracking them (and the
	# user's originals stranded in the backup slot). Require a clean unload
	# first -- its manifest-driven revert is the correct path out.
	var active_pack := get_active_modpack()
	if active_pack != "":
		_show_error_dialog("Modpack active",
				"Unload the active modpack (\"" + active_pack + "\") before restoring a backup. Unload reverts the pack's files first; restoring on top of an active pack would leave its files behind.")
		return
	var snaps := _list_apply_snapshots()
	if snaps.is_empty():
		_show_error_dialog("No restore points",
				"No automatic restore points have been saved yet. One is created before each modpack apply.")
		return

	var d := ConfirmationDialog.new()
	d.title = "Restore backup"
	d.ok_button_text = "Restore backup"
	d.dialog_hide_on_ok = false

	var form := VBoxContainer.new()
	form.custom_minimum_size = Vector2(440, 0)
	form.add_theme_constant_override("separation", SP_M)
	d.add_child(form)

	var prompt := Label.new()
	prompt.text = "Restore your mod state to a point saved automatically before a modpack was applied. This overwrites your current profiles, mod settings (MCM), and any files a modpack replaced."
	prompt.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	form.add_child(prompt)

	var picker := OptionButton.new()
	for s: Dictionary in snaps:
		var created: String = str(s.get("created", ""))
		var label: String = str(s.get("pack", "modpack"))
		if created != "":
			label += "   (" + created + ")"
		picker.add_item(label)
	if picker.item_count > 0:
		picker.select(0)
	form.add_child(picker)

	_attach_ui_dialog(d)
	style_dialog_primary_button(d.get_ok_button())
	_connect_dialog_exits(d,
		func():
			var idx := picker.selected
			if idx < 0 or idx >= snaps.size():
				d.queue_free()
				return
			var chosen: Dictionary = snaps[idx]
			var result := _restore_apply_snapshot(str(chosen["path"]))
			d.queue_free()
			if not bool(result.get("ok", false)):
				_show_error_dialog("Could not restore backup", str(result.get("error", "unknown")))
				return
			# Re-read state from the restored cfg and rebuild the UI.
			var rcfg := ConfigFile.new()
			rcfg.load(UI_CONFIG_PATH)
			_active_profile = str(rcfg.get_value("settings", "active_profile", _active_profile))
			_reload_entries_for_active_profile()
			_rebuild_mods_tab(tabs)
			_rebuild_modpacks_tab(tabs)
			# The restore rewrote cfg + MCM on disk; a post-boot session must
			# restart into it or the running game keeps the old mods live
			# against the restored config (same convention as _switch_profile).
			if _boot_complete:
				_dirty_since_boot = true
			_show_accept_dialog("Backup restored", "Your mod state was restored from the selected backup."),
		func():
			d.queue_free())
	d.popup_centered()

func build_modpacks_tab(tabs: TabContainer) -> Control:
	var margin := _make_tab_margin()

	var container := VBoxContainer.new()
	container.add_theme_constant_override("separation", SP_M)
	margin.add_child(container)

	# Refresh discovery up-front so the toolbar header (which queries
	# active_modpack to decide whether Save is enabled) has fresh state.
	# Cheap -- one DirAccess scan + one ZIPReader open per zip.
	_modpack_entries = collect_modpack_metadata()
	var active_modpack := get_active_modpack()

	var hdr_row := HBoxContainer.new()
	hdr_row.add_theme_constant_override("separation", SP_M)
	container.add_child(hdr_row)

	var hdr := Label.new()
	hdr.text = "Modpacks in your mods folder"
	hdr.add_theme_font_size_override("font_size", FS_HEAD)
	hdr.add_theme_color_override("font_color", COL_TEXT_HI)
	hdr.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hdr_row.add_child(hdr)

	# Export current profile as a modpack zip in <game>/mods/. Filename is
	# the sanitized profile name. Disabled when a modpack is active (the
	# active profile is "modpack__X" -- saving it would write a confusingly-
	# named zip; user should unload first).
	var save_modpack_btn := Button.new()
	save_modpack_btn.text = "Save current profile as modpack"
	save_modpack_btn.tooltip_text = "Save your currently-enabled mods as one shareable modpack file. Anyone you send it to gets this exact setup in one click."
	var save_disabled_reason := ""
	if active_modpack != "":
		save_disabled_reason = "Unload the active modpack first"
	save_modpack_btn.disabled = save_disabled_reason != ""
	if save_disabled_reason != "":
		save_modpack_btn.tooltip_text = save_disabled_reason
	hdr_row.add_child(save_modpack_btn)
	save_modpack_btn.pressed.connect(func():
		var profile_to_save := _active_profile
		var orphans := _enabled_mods_without_modworkshop_id()
		_show_save_modpack_dialog(profile_to_save, orphans, tabs)
	)

	var open_folder_btn := Button.new()
	open_folder_btn.text = "Open mods folder"
	open_folder_btn.tooltip_text = "Drop modpack zips into this folder -- they appear in the list next time you open this tab."
	hdr_row.add_child(open_folder_btn)
	open_folder_btn.pressed.connect(func():
		OS.shell_open(ProjectSettings.globalize_path(_mods_dir))
	)

	# Restore from an automatic pre-apply snapshot. Disabled until at least one
	# exists (one is written before every modpack apply).
	var restore_btn := Button.new()
	restore_btn.text = "Restore backup"
	var apply_snaps := _list_apply_snapshots()
	restore_btn.disabled = apply_snaps.is_empty()
	restore_btn.tooltip_text = ("No restore points yet -- one is saved automatically before each modpack apply" \
			if apply_snaps.is_empty() \
			else "Roll back profiles, mod settings, and overwritten files to a point saved before a modpack was applied")
	hdr_row.add_child(restore_btn)
	restore_btn.pressed.connect(func():
		_show_restore_snapshot_dialog(tabs)
	)

	container.add_child(HSeparator.new())

	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	container.add_child(scroll)
	# Kept on self so _rebuild_modpacks_tab can carry the scroll position
	# across teardown (same pattern as _ui_mods_scroll).
	_ui_modpacks_scroll = scroll

	var list_wrap := MarginContainer.new()
	list_wrap.add_theme_constant_override("margin_right", SP_XL)
	list_wrap.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(list_wrap)

	var list := VBoxContainer.new()
	list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	list.add_theme_constant_override("separation", SP_S)
	list_wrap.add_child(list)

	if _modpack_entries.is_empty():
		# First thing a new user sees here, so teach the concept, not just the
		# mechanics: what a modpack is, then the two ways to get one.
		var empty := Label.new()
		empty.text = "No modpacks yet.\n\nA modpack is a shareable list of mods -- one small file that gives someone your exact setup in one click (the mods download from ModWorkshop when they apply it).\n\nSave your current profile as a modpack above, or drop someone else's modpack zip into your mods folder."
		empty.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		empty.add_theme_color_override("font_color", COL_TEXT_DIM)
		list.add_child(empty)
		return margin

	for entry in _modpack_entries:
		list.add_child(_modpacks_render_row(entry, active_modpack, tabs))
		list.add_child(HSeparator.new())

	return margin


# Unload the active modpack and surface the outcome: error dialog on failure,
# and always rebuild the Modpacks tab -- on success to remove the ACTIVE row
# state, on error to correct the stale view that likely triggered the click.
func _unload_modpack_with_feedback(tabs: TabContainer) -> void:
	var result := unload_modpack(tabs)
	if not bool(result.get("ok", false)):
		_show_error_dialog("Could not unload modpack", str(result.get("error", "unknown")))
	_rebuild_modpacks_tab(tabs)

# Render one modpack row: name + filename/mod-count meta + Apply or
# Active+Unload button. Apply is disabled when ANOTHER modpack is active
# (single-slot constraint -- user has to unload first).
func _modpacks_render_row(entry: Dictionary, active_modpack: String, tabs: TabContainer) -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", SP_L)

	var info_col := VBoxContainer.new()
	info_col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	info_col.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(info_col)

	# Name is a heading. Author (if any) appears next to it as "by X" in a
	# dimmer tone. The Details button in the action area is the canonical
	# way to open the modal -- a chevron on the name didn't read as
	# interactive in testing.
	var name_row := HBoxContainer.new()
	name_row.add_theme_constant_override("separation", SP_M)
	info_col.add_child(name_row)

	var name_lbl := Label.new()
	name_lbl.text = str(entry.get("raw_name", "?"))
	name_lbl.add_theme_font_size_override("font_size", FS_HEAD)
	name_lbl.add_theme_color_override("font_color", COL_TEXT_HI)
	# raw_name comes straight from the modpack zip, so it can be arbitrarily
	# long. Clip it instead of letting it inflate the row's min width and push
	# the Details/Apply/Unload buttons out of the scroll viewport.
	name_lbl.clip_text = true
	name_lbl.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	name_lbl.tooltip_text = name_lbl.text
	name_lbl.mouse_filter = Control.MOUSE_FILTER_PASS
	name_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	name_row.add_child(name_lbl)

	var author: String = str(entry.get("author", "")).strip_edges()
	if not author.is_empty():
		var author_lbl := Label.new()
		author_lbl.text = "by " + author
		author_lbl.add_theme_font_size_override("font_size", FS_BODY)
		author_lbl.add_theme_color_override("font_color", COL_TEXT_DIM)
		author_lbl.size_flags_vertical = Control.SIZE_SHRINK_END
		name_row.add_child(author_lbl)

	# Description, if set at save time. Wraps to fit the available row
	# width. Empty when modpack pre-dates the description field or the
	# author left it blank.
	var description: String = str(entry.get("description", "")).strip_edges()
	if not description.is_empty():
		var desc_lbl := Label.new()
		desc_lbl.text = description
		desc_lbl.add_theme_font_size_override("font_size", FS_BODY)
		desc_lbl.add_theme_color_override("font_color", COL_TEXT)
		desc_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		info_col.add_child(desc_lbl)

	# Surface dedupe results so the user knows other same-name zips exist
	# in /mods/ but aren't shown. Without this they'd wonder where the
	# other file went and we'd risk both rows tagging as ACTIVE.
	var dups: Array = entry.get("duplicates_hidden", [])
	if not dups.is_empty():
		var dup_names := PackedStringArray()
		for d_v in dups:
			if d_v is Dictionary:
				dup_names.append(str((d_v as Dictionary).get("file_name", "?")))
		var dup_lbl := Label.new()
		dup_lbl.text = "Duplicate file(s) hidden: " + ", ".join(dup_names)
		dup_lbl.add_theme_color_override("font_color", COL_AMBER)
		dup_lbl.add_theme_font_size_override("font_size", FS_BODY)
		dup_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		info_col.add_child(dup_lbl)

	var enabled_count: int = int(entry.get("enabled_count", 0))
	var total_count: int = int(entry.get("total_count", 0))
	var meta_lbl := Label.new()
	if total_count > 0:
		meta_lbl.text = "%d of %d mods enabled - %s" % [enabled_count, total_count, str(entry.get("file_name", ""))]
	else:
		meta_lbl.text = str(entry.get("file_name", ""))
	meta_lbl.add_theme_font_size_override("font_size", FS_META)
	meta_lbl.add_theme_color_override("font_color", COL_TEXT_DIM)
	meta_lbl.clip_text = true
	# Ellipsis + hover tooltip instead of a hard mid-word cut (Labels default
	# to MOUSE_FILTER_IGNORE, which silently suppresses tooltips).
	meta_lbl.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	meta_lbl.tooltip_text = meta_lbl.text
	meta_lbl.mouse_filter = Control.MOUSE_FILTER_PASS
	info_col.add_child(meta_lbl)

	var sanitized: String = str(entry.get("sanitized_name", ""))
	var is_active: bool = active_modpack != "" and active_modpack == sanitized
	var another_active: bool = active_modpack != "" and active_modpack != sanitized

	# Details button always visible, before the Apply/Unload action so it
	# reads as the discoverable "tell me more" affordance.
	var details_btn := Button.new()
	details_btn.text = "Details"
	details_btn.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(details_btn)
	var captured_entry_for_detail := entry
	var captured_active := active_modpack
	details_btn.pressed.connect(func():
		_show_modpack_detail_dialog(captured_entry_for_detail, captured_active, tabs)
	)
	_wire_hint(details_btn, "Open the modpack's full mod list and description.")

	if is_active:
		var active_lbl := Label.new()
		active_lbl.text = "Active"
		active_lbl.add_theme_font_size_override("font_size", FS_META)
		active_lbl.add_theme_color_override("font_color", COL_TEXT_HI)
		active_lbl.add_theme_stylebox_override("normal", _make_badge_stylebox(COL_OK, COL_OK_DIM))
		active_lbl.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		row.add_child(active_lbl)

		var unload_btn := Button.new()
		unload_btn.text = "Unload"
		style_danger_button(unload_btn)
		unload_btn.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		row.add_child(unload_btn)
		unload_btn.pressed.connect(func(): _unload_modpack_with_feedback(tabs))
	else:
		var apply_btn := Button.new()
		apply_btn.text = "Apply"
		# Bare theme voice: N modpack rows would mean N amber buttons on one
		# surface (spec caps primary at one per surface, same call as Browse
		# row Download buttons). Primary lives on the detail dialog's Apply
		# and the apply-confirm OK.
		apply_btn.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		apply_btn.disabled = another_active
		if another_active:
			apply_btn.tooltip_text = "Unload \"" + active_modpack + "\" before applying another modpack"
		row.add_child(apply_btn)
		var captured_entry := entry
		apply_btn.pressed.connect(func():
			_apply_modpack_with_ui_flow(captured_entry, tabs)
		)

	return row


# Run the full modpack-apply UX: validate -> preview-confirm -> progress
# dialog -> apply -> rebuild tab -> failure dialog if any download failed.
# Extracted from the row's apply lambda so the detail modal can reuse the
# same flow without duplicating the logic.
func _apply_modpack_with_ui_flow(entry: Dictionary, tabs: TabContainer) -> void:
	# Validate the zip up front so the confirmation dialog can show a real
	# preview ("Apply 38-mod modpack?") and bail early if the zip is
	# malformed -- before the user commits.
	var validation := _validate_modpack(entry)
	if not bool(validation.get("ok", false)):
		_show_error_dialog("Cannot apply modpack", str(validation.get("error", "unknown")))
		return
	var apply_enabled := int(validation.get("enabled_count", 0))
	var apply_total := int(validation.get("total_count", 0))
	var name_str := str(entry.get("raw_name", "?"))
	# Preview download count so the user knows up-front whether this is a
	# "click and go" (everything already installed) or a long download op.
	var missing_preview := _get_missing_mods_for_modpack(entry)
	var dl_count := missing_preview.size()
	var msg := "Apply \"%s\"?\n\nActivates %d of %d mods and replaces your mod settings (MCM)." % [name_str, apply_enabled, apply_total]
	if dl_count > 0:
		msg += "\nWill download %d mod(s) from ModWorkshop." % dl_count
	msg += "\n\nYour current state is backed up -- click Unload to restore."
	msg += "\nA restore point is also saved automatically (Restore backup) in case anything goes wrong."
	var cd := ConfirmationDialog.new()
	cd.title = "Apply modpack"
	cd.dialog_text = msg
	cd.ok_button_text = "Apply modpack"
	_attach_ui_dialog(cd)
	style_dialog_primary_button(cd.get_ok_button())
	_connect_dialog_exits(cd,
		func():
			cd.queue_free()
			# Skip the progress dialog entirely when there's nothing to
			# download -- the apply is a near-instant cfg flip and a
			# pop-and-vanish dialog looks broken. Failure dialog still
			# opens at the end if anything fails.
			var needs_progress := dl_count > 0
			var pd: AcceptDialog = null
			var pd_bar: ProgressBar = null
			var pd_status: Label = null
			var pd_cancel: Button = null
			if needs_progress:
				var progress_ui := _build_modpack_progress_dialog(name_str)
				pd = progress_ui["dialog"]
				pd_bar = progress_ui["bar"]
				pd_status = progress_ui["status"]
				pd_cancel = progress_ui["cancel"]
				pd_cancel.pressed.connect(func():
					if is_instance_valid(pd_status):
						pd_status.text = "Cancelling after current download..."
					if is_instance_valid(pd_cancel):
						pd_cancel.disabled = true
						pd_cancel.text = "Cancelling..."
					_modpack_apply_cancelled = true
				)
				pd.popup_centered()

			var progress_cb := func(p: Dictionary):
				if pd_status == null or not is_instance_valid(pd_status):
					return
				var cur := int(p.get("current", 0))
				var tot := int(p.get("total", 0))
				var nm := str(p.get("mod_name", ""))
				var act := str(p.get("action", ""))
				if is_instance_valid(pd_bar) and tot > 0:
					pd_bar.value = float(cur) / float(tot) * 100.0
				# Rate-limit pause: the apply loop is waiting out the MWS
				# cooldown, not downloading -- show the live countdown so
				# the dialog doesn't look hung. Cancel stays available.
				if act == "rate_wait":
					pd_status.text = "Rate limited by ModWorkshop -- resuming in %ds" % int(p.get("wait_s", 0))
					return
				var prefix := "Downloading"
				if act == "skipped": prefix = "Skipping (manual install)"
				elif act == "applying": prefix = "Applying modpack"
				elif act == "retrying": prefix = "Retrying"
				if nm != "":
					pd_status.text = "%s %d of %d:\n%s" % [prefix, cur, tot, nm]
				else:
					pd_status.text = "%s..." % prefix

			var result := await apply_modpack(entry, tabs, progress_cb)
			var was_cancelled: bool = bool(result.get("cancelled", false))
			var dl: int = int(result.get("downloaded", 0))
			var dl_failed: int = int(result.get("failed_downloads", 0))
			var failures: Array = result.get("failures", [])

			# Cancelled: the apply aborted BEFORE any state mutation -- the pack
			# was NOT applied. Say exactly that instead of routing to the
			# "Applied with Issues" dialog, which would claim the opposite.
			if was_cancelled:
				if pd != null and is_instance_valid(pd):
					pd.queue_free()
				if is_instance_valid(tabs):
					_rebuild_modpacks_tab(tabs)
				var cancel_msg := "Apply cancelled -- the modpack was not applied and your profiles are unchanged."
				if dl > 0:
					cancel_msg += "\n%d downloaded mod(s) remain in your mods folder." % dl
				if dl_failed > 0:
					cancel_msg += "\n%d download(s) had already failed before the cancel." % dl_failed
				_show_accept_dialog("Apply cancelled", cancel_msg)
				return
			# Partial: tear down progress, route to failure dialog which has
			# its own dismiss-on-OK flow.
			if dl_failed > 0:
				if pd != null and is_instance_valid(pd):
					pd.queue_free()
				if is_instance_valid(tabs):
					_rebuild_modpacks_tab(tabs)
				_show_modpack_failure_dialog(dl, failures, tabs)
				return
			if not bool(result.get("ok", false)):
				if pd != null and is_instance_valid(pd):
					pd.queue_free()
				_show_error_dialog("Could not apply modpack", str(result.get("error", "unknown")))
				return
			if is_instance_valid(tabs):
				_rebuild_modpacks_tab(tabs)
			# Full success. If a progress dialog was shown, switch it to
			# completion state (filled bar, summary line, OK button) so
			# the user dismisses on their own time. With no downloads
			# there was no dialog to begin with -- silent apply.
			if pd != null and is_instance_valid(pd):
				if is_instance_valid(pd_bar):
					pd_bar.value = 100
				if is_instance_valid(pd_status):
					pd_status.text = "Modpack applied. Downloaded %d mod(s)." % dl
				if is_instance_valid(pd_cancel):
					pd_cancel.visible = false
				pd.dialog_close_on_escape = true
				var pd_ok := pd.get_ok_button()
				if pd_ok != null:
					pd_ok.visible = true
				pd.confirmed.connect(func():
					if is_instance_valid(pd):
						pd.queue_free()
				)
				pd.close_requested.connect(func():
					if is_instance_valid(pd):
						pd.queue_free()
				),
		func(): cd.queue_free())
	cd.popup_centered()


# Construct the modpack-apply progress dialog: ProgressBar + status label +
# Cancel button. Returns the dialog plus references to the controls so
# callers can wire signals + update them. Build content BEFORE _attach_ui_dialog
# so the helper's reparent-children step folds them into the root VBox.
# title_override lets the retry pass reuse the same dialog (same Cancel
# affordance) under its own title.
func _build_modpack_progress_dialog(raw_name: String, title_override: String = "") -> Dictionary:
	var pd := AcceptDialog.new()
	pd.title = title_override if title_override != "" else "Applying modpack \"" + raw_name + "\""
	pd.min_size = Vector2i(520, 200)
	pd.ok_button_text = "Close"

	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", SP_M)
	pd.add_child(box)

	var status := Label.new()
	status.text = "Preparing..."
	status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	status.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	box.add_child(status)

	var bar := ProgressBar.new()
	bar.min_value = 0
	bar.max_value = 100
	bar.value = 0
	bar.custom_minimum_size = Vector2(500, 18)
	bar.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	box.add_child(bar)

	var btn_row := HBoxContainer.new()
	btn_row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	box.add_child(btn_row)
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	btn_row.add_child(spacer)
	var cancel_btn := Button.new()
	cancel_btn.text = "Cancel"
	btn_row.add_child(cancel_btn)

	# Attach AFTER content so _attach_ui_dialog's reparent step picks up
	# the box and folds it into the root VBox with the injected title.
	# Progress is non-dismissible while running; hide the native OK until
	# the caller flips it on at completion, and swallow ESC too -- a hidden
	# (not cancelled) dialog would lift the exclusive input block and let the
	# user Launch / switch profiles mid-apply. Cancel is the only way out.
	_attach_ui_dialog(pd)
	pd.dialog_close_on_escape = false
	var pd_ok := pd.get_ok_button()
	if pd_ok != null:
		pd_ok.visible = false

	return {"dialog": pd, "bar": bar, "status": status, "cancel": cancel_btn}


# Read the modpack zip's profile.json into a parsed Dictionary. Empty dict
# on any failure (missing zip, corrupt zip, missing profile.json, bad JSON).
func _read_modpack_profile_json(entry: Dictionary) -> Dictionary:
	var file_path: String = str(entry.get("file_path", ""))
	if file_path.is_empty() or not FileAccess.file_exists(file_path):
		return {}
	var reader := ZIPReader.new()
	if reader.open(file_path) != OK:
		return {}
	var bytes := reader.read_file("profile.json")
	reader.close()
	if bytes.is_empty():
		return {}
	var parsed: Variant = JSON.parse_string(bytes.get_string_from_utf8())
	return parsed if parsed is Dictionary else {}


# Detail modal for a Modpacks-tab row. Shows zip size, mod counts, and the
# full mod list with installed/missing/downloadable indicators. The Apply
# (or Unload) button mirrors the row's inline button via the shared apply
# flow helper so behavior stays in sync.
func _show_modpack_detail_dialog(entry: Dictionary, active_modpack: String, tabs: TabContainer) -> void:
	var d := AcceptDialog.new()
	d.title = str(entry.get("raw_name", "?"))
	d.ok_button_text = "Close"
	# Clamped to the launcher: the fixed 660x540 exceeded the launcher's
	# 640x420 minimum in BOTH axes and got clipped by the embedder.
	d.min_size = _dialog_fit_size(Vector2i(660, 540))

	var scroll := ScrollContainer.new()
	# Track the (possibly clamped) dialog size, keeping the original
	# 20x60 chrome allowance (660x540 dialog held a 640x480 scroll).
	scroll.custom_minimum_size = Vector2(d.min_size - Vector2i(20, 60))
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	d.add_child(scroll)

	var inner_wrap := MarginContainer.new()
	inner_wrap.add_theme_constant_override("margin_right", SP_XL)
	inner_wrap.add_theme_constant_override("margin_left", SP_S)
	inner_wrap.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(inner_wrap)

	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", SP_M)
	box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	inner_wrap.add_child(box)

	# Meta header
	var file_path: String = str(entry.get("file_path", ""))
	var author: String = str(entry.get("author", "")).strip_edges()
	var file_lbl := Label.new()
	var file_text := str(entry.get("file_name", "?"))
	if not author.is_empty():
		file_text = "by " + author + "  -  " + file_text
	file_lbl.text = file_text
	file_lbl.add_theme_color_override("font_color", COL_TEXT_DIM)
	file_lbl.add_theme_font_size_override("font_size", FS_META)
	file_lbl.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	file_lbl.tooltip_text = file_text
	file_lbl.mouse_filter = Control.MOUSE_FILTER_PASS
	box.add_child(file_lbl)

	# Description -- prominent if present, omitted otherwise to keep the
	# modal compact for modpacks that pre-date the field.
	var description: String = str(entry.get("description", "")).strip_edges()
	if not description.is_empty():
		var desc_lbl := Label.new()
		desc_lbl.text = description
		desc_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		desc_lbl.add_theme_font_size_override("font_size", FS_EMPH)
		desc_lbl.add_theme_color_override("font_color", COL_TEXT)
		box.add_child(desc_lbl)

	var zip_size := 0
	if FileAccess.file_exists(file_path):
		var f := FileAccess.open(file_path, FileAccess.READ)
		if f != null:
			zip_size = f.get_length()
			f.close()

	var sanitized: String = str(entry.get("sanitized_name", ""))
	var is_active: bool = active_modpack != "" and active_modpack == sanitized
	var another_active: bool = active_modpack != "" and active_modpack != sanitized

	var parsed := _read_modpack_profile_json(entry)
	var enabled_map: Dictionary = parsed.get("enabled", {}) if parsed.get("enabled") is Dictionary else {}
	var sources_map: Dictionary = parsed.get("sources", {}) if parsed.get("sources") is Dictionary else {}
	var total := enabled_map.size()
	var enabled_count := 0
	var installed_count := 0
	var missing_count := 0

	var installed_keys: Dictionary = {}
	for ient in _ui_mod_entries:
		installed_keys[str(ient.get("profile_key", ""))] = true

	for k_v in enabled_map.keys():
		if bool(enabled_map[k_v]):
			enabled_count += 1
		if installed_keys.has(str(k_v)):
			installed_count += 1
		else:
			missing_count += 1

	var counts_lbl := Label.new()
	var counts_parts := PackedStringArray()
	counts_parts.append("%d mods" % total)
	counts_parts.append("%d enabled" % enabled_count)
	counts_parts.append("%d installed" % installed_count)
	if missing_count > 0:
		counts_parts.append("%d missing" % missing_count)
	if zip_size > 0:
		counts_parts.append(_format_size(zip_size))
	if is_active:
		counts_parts.append("active")
	counts_lbl.text = " - ".join(counts_parts)
	counts_lbl.add_theme_color_override("font_color", COL_OK if is_active else COL_TEXT)
	counts_lbl.add_theme_font_size_override("font_size", FS_EMPH)
	box.add_child(counts_lbl)

	box.add_child(HSeparator.new())

	var list_hdr := Label.new()
	list_hdr.text = "Mods"
	list_hdr.add_theme_font_size_override("font_size", FS_HEAD)
	box.add_child(list_hdr)

	if enabled_map.is_empty():
		var empty := Label.new()
		empty.text = "This modpack lists no mods."
		empty.add_theme_color_override("font_color", COL_TEXT_DIM)
		empty.add_theme_font_size_override("font_size", FS_BODY)
		box.add_child(empty)
	else:
		var sorted_keys: Array = enabled_map.keys()
		sorted_keys.sort()
		for k_v in sorted_keys:
			var k: String = str(k_v)
			var en: bool = bool(enabled_map[k_v])
			var installed: bool = installed_keys.has(k)
			var src_data: Dictionary = sources_map.get(k_v, {}) if sources_map.get(k_v) is Dictionary else {}
			var has_source: bool = int(src_data.get("modworkshop_id", 0)) > 0

			var mod_row := HBoxContainer.new()
			mod_row.add_theme_constant_override("separation", SP_M)
			box.add_child(mod_row)

			var en_lbl := Label.new()
			en_lbl.text = "[on]" if en else "[off]"
			en_lbl.add_theme_font_size_override("font_size", FS_BODY)
			en_lbl.add_theme_color_override("font_color", COL_OK if en else COL_TEXT_DIM)
			en_lbl.custom_minimum_size.x = 40
			mod_row.add_child(en_lbl)

			var key_lbl := Label.new()
			key_lbl.text = k
			key_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			key_lbl.clip_text = true
			# Ellipsis + hover tooltip instead of a hard mid-word cut (Labels
			# default to MOUSE_FILTER_IGNORE, which suppresses tooltips).
			key_lbl.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
			key_lbl.tooltip_text = k
			key_lbl.mouse_filter = Control.MOUSE_FILTER_PASS
			mod_row.add_child(key_lbl)

			var status_lbl := Label.new()
			if installed:
				status_lbl.text = "Installed"
				status_lbl.add_theme_color_override("font_color", COL_OK)
			elif has_source:
				status_lbl.text = "Will download"
				status_lbl.add_theme_color_override("font_color", COL_AMBER)
			else:
				status_lbl.text = "Manual install"
				status_lbl.add_theme_color_override("font_color", COL_ERR)
			status_lbl.add_theme_font_size_override("font_size", FS_BODY)
			status_lbl.custom_minimum_size.x = 110
			mod_row.add_child(status_lbl)

	# Action button on the dialog's native button bar.
	if is_active:
		var unload_btn := d.add_button("Unload", true, "")
		style_danger_button(unload_btn)
		unload_btn.pressed.connect(func():
			d.queue_free()
			_unload_modpack_with_feedback(tabs)
		)
	else:
		var apply_btn_d := d.add_button("Apply", true, "")
		style_primary_button(apply_btn_d)
		apply_btn_d.disabled = another_active
		if another_active:
			apply_btn_d.tooltip_text = "Unload \"" + active_modpack + "\" first"
		var captured_entry := entry
		apply_btn_d.pressed.connect(func():
			d.queue_free()
			_apply_modpack_with_ui_flow(captured_entry, tabs)
		)

	_attach_ui_dialog(d)
	_wire_accept_dismiss(d)
	d.popup_centered()


# Mirror of _rebuild_mods_tab. Replaces the Modpacks tab control in place
# preserving current_tab so the user doesn't get yanked to a different tab
# during the swap. _rebuilding_modpacks_tab guards against recursion: the
# remove_child shifts current_tab to a sibling which fires tab_changed,
# whose listener calls back here -- the flag short-circuits the second
# call. Also breaks recursion when we explicitly restore current_tab at
# the end (fires another tab_changed).
func _rebuild_modpacks_tab(tabs: TabContainer) -> void:
	if _rebuilding_modpacks_tab:
		return
	_rebuilding_modpacks_tab = true
	var old := tabs.get_node_or_null(UI_TAB_MODPACKS)
	if old == null:
		_rebuilding_modpacks_tab = false
		return
	_rebuilding_tab_in_place = true
	# Carry the list scroll position across the teardown -- a row action
	# halfway down a long modpack list must not snap the view to the top.
	var saved_scroll := 0
	if is_instance_valid(_ui_modpacks_scroll):
		saved_scroll = _ui_modpacks_scroll.scroll_vertical
	var idx := old.get_index()
	var was_current := tabs.current_tab == idx
	tabs.remove_child(old)
	old.queue_free()
	var new_tab := build_modpacks_tab(tabs)
	new_tab.name = UI_TAB_MODPACKS
	tabs.add_child(new_tab)
	tabs.move_child(new_tab, idx)
	if was_current:
		tabs.current_tab = idx
	_rebuilding_tab_in_place = false
	_rebuilding_modpacks_tab = false
	if saved_scroll > 0:
		_restore_modpacks_scroll(saved_scroll)

# Restore one frame later: the fresh rows haven't been laid out yet when
# _rebuild_modpacks_tab returns, so setting scroll_vertical immediately
# clamps against a zero-height list and lands back at the top (mirror of
# _restore_mods_scroll).
func _restore_modpacks_scroll(saved_scroll: int) -> void:
	await get_tree().process_frame
	if is_instance_valid(_ui_modpacks_scroll):
		_ui_modpacks_scroll.scroll_vertical = saved_scroll

# Delete-profile confirmation. The trash button is already disabled when the
# active profile is Vanilla or the last remaining user profile; the guard in
# _delete_active_profile is belt-and-suspenders.
