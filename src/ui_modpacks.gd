## ----- ui_modpacks.gd -----
## The Modpacks tab: rows, the apply flow and its dialogs, hosted packs.

# Recursion guard for _rebuild_modpacks_tab: child moves fire tab_changed,
# whose listener calls _rebuild_modpacks_tab again.
var _rebuilding_modpacks_tab: bool = false

# Modpack-apply failure summary: per-failure rows with an open-page button
# when the host has one, and "Retry failed" for the failed downloads.
func _show_modpack_failure_dialog(downloaded: int, failures: Array, tabs: TabContainer) -> void:
	var d := AcceptDialog.new()
	d.title = "Modpack applied with issues"
	d.ok_button_text = "Close"
	d.min_size = _dialog_fit_size(Vector2i(540, 420))

	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", SP_M)
	d.add_child(box)

	var hdr := Label.new()
	hdr.text = "Downloaded %d mod(s), %d failed." % [downloaded, failures.size()]
	box.add_child(hdr)

	var scroll := ScrollContainer.new()
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

		var f_ref: Dictionary = f["ref"]
		var page_url := host_mod_page_url(f_ref)
		if page_url != "":
			var open_btn := Button.new()
			open_btn.text = "Open " + host_display_name(str(f_ref["provider"])) + " page"
			open_btn.size_flags_vertical = Control.SIZE_SHRINK_CENTER
			row.add_child(open_btn)
			open_btn.pressed.connect(func():
				OS.shell_open(page_url)
			)

	# Retry sits in the native button bar; omitted when nothing is downloadable.
	var retry_btn: Button = null
	var any_retryable := false
	for f_v in failures:
		if _modpack_ref_downloadable((f_v as Dictionary)["ref"]):
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


# Retry failed modpack downloads with a progress dialog, then re-show failures.
func _run_modpack_retry(failures: Array, tabs: TabContainer) -> void:
	# Reuses the apply progress dialog; Cancel sets _modpack_apply_cancelled.
	_modpack_apply_cancelled = false
	var progress_ui := _build_modpack_progress_dialog("", "Retrying failed downloads")
	var pd: AcceptDialog = progress_ui["dialog"]
	var pd_bar: ProgressBar = progress_ui["bar"]
	var status_lbl: Label = progress_ui["status"]
	var pd_cancel: Button = progress_ui["cancel"]
	pd_cancel.pressed.connect(func():
		if is_instance_valid(status_lbl):
			status_lbl.text = "Cancelling after current download..."
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
			status_lbl.text = "Rate limited by %s -- resuming in %ds" % [str(p.get("host", "the mod site")), int(p.get("wait_s", 0))]
			return
		if nm != "":
			status_lbl.text = "Retrying %d of %d:\n%s" % [cur, tot, nm]
		else:
			status_lbl.text = "Retrying..."

	var result := await retry_failed_downloads(failures, progress_cb)

	if is_instance_valid(pd):
		pd.queue_free()

	if is_instance_valid(tabs):
		_rebuild_mods_tab(tabs)

	var still_failed: Array = result.get("failures", [])
	var dl: int = int(result.get("downloaded", 0))
	if still_failed.is_empty():
		var ok_d := AcceptDialog.new()
		ok_d.title = "Retry complete"
		ok_d.dialog_text = "Downloaded %d mod(s) on retry." % dl
		ok_d.ok_button_text = "Close"
		_attach_ui_dialog(ok_d)
		_wire_accept_dismiss(ok_d)
		ok_d.popup_centered()
	else:
		_show_modpack_failure_dialog(dl, still_failed, tabs)

func build_modpacks_tab(tabs: TabContainer) -> Control:
	var margin := _make_tab_margin()

	var container := VBoxContainer.new()
	container.add_theme_constant_override("separation", SP_M)
	margin.add_child(container)

	_modpack_entries = collect_modpack_metadata()
	var active_modpack := get_active_modpack()

	var hdr_row := HBoxContainer.new()
	hdr_row.add_theme_constant_override("separation", SP_M)
	container.add_child(hdr_row)

	var hdr := Label.new()
	hdr.text = "Modpacks"
	hdr.add_theme_font_size_override("font_size", FS_HEAD)
	hdr.add_theme_color_override("font_color", COL_TEXT_HI)
	hdr.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hdr_row.add_child(hdr)

	var hosted_btn := Button.new()
	hosted_btn.text = "Get from VostokMods"
	hosted_btn.tooltip_text = "Browse the modpacks published on vostokmods.net, or paste a pack link."
	hdr_row.add_child(hosted_btn)
	hosted_btn.pressed.connect(func():
		_show_hosted_packs_dialog(tabs)
	)

	container.add_child(HSeparator.new())

	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	container.add_child(scroll)
	# Kept on self so _rebuild_modpacks_tab can carry the scroll position.
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
		var empty := Label.new()
		empty.text = "No modpacks yet.\n\nA modpack is a list of mods with their load order and settings in one small zip; applying it downloads the mods you are missing and switches you to that setup.\n\nModpacks come from VostokMods: click Get from VostokMods above."
		empty.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		empty.add_theme_color_override("font_color", COL_TEXT_DIM)
		list.add_child(empty)
		return margin

	for entry in _modpack_entries:
		list.add_child(_modpacks_render_row(entry, active_modpack, tabs))
		list.add_child(HSeparator.new())

	return margin


# Unload the active modpack, with an error dialog on failure; always rebuilds the tab.
func _unload_modpack_with_feedback(tabs: TabContainer) -> void:
	var result := unload_modpack(tabs)
	if not bool(result.get("ok", false)):
		_show_error_dialog("Could not unload modpack", str(result.get("error", "unknown")))
	_rebuild_modpacks_tab(tabs)

# One modpack row: name, meta, Apply or Active+Unload. Apply is disabled while another pack is active.
func _modpacks_render_row(entry: Dictionary, active_modpack: String, tabs: TabContainer) -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", SP_L)

	var hosted: Dictionary = entry.get("hosted", {}) if entry.get("hosted") is Dictionary else {}
	var is_hosted := str(hosted.get("slug", "")) != ""
	_modpacks_row_info(row, entry, is_hosted)

	var sanitized: String = str(entry.get("sanitized_name", ""))
	var is_active: bool = active_modpack != "" and active_modpack == sanitized
	var another_active: bool = active_modpack != "" and active_modpack != sanitized

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

	if is_hosted:
		_modpacks_row_refresh_button(row, entry, tabs, is_active)

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
		# Primary styling is reserved for the detail dialog's Apply and the confirm OK.
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


# Name, author, description, hidden-duplicate note and the meta line.
func _modpacks_row_info(row: HBoxContainer, entry: Dictionary, is_hosted: bool) -> void:
	var info_col := VBoxContainer.new()
	info_col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	info_col.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(info_col)

	var name_row := HBoxContainer.new()
	name_row.add_theme_constant_override("separation", SP_M)
	info_col.add_child(name_row)

	var name_lbl := Label.new()
	name_lbl.text = str(entry.get("raw_name", "?"))
	name_lbl.add_theme_font_size_override("font_size", FS_HEAD)
	name_lbl.add_theme_color_override("font_color", COL_TEXT_HI)
	# raw_name comes from the zip; clip it so it cannot push the buttons out of view.
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

	var description: String = str(entry.get("description", "")).strip_edges()
	if not description.is_empty():
		var desc_lbl := Label.new()
		desc_lbl.text = description
		desc_lbl.add_theme_font_size_override("font_size", FS_BODY)
		desc_lbl.add_theme_color_override("font_color", COL_TEXT)
		desc_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		info_col.add_child(desc_lbl)

	# Surface dedupe results so the user knows same-name zips exist but are hidden.
	var dups: Array = entry.get("duplicates_hidden", [])
	if not dups.is_empty():
		var dup_names := PackedStringArray()
		for d_v in dups:
			if d_v is Dictionary:
				dup_names.append(str((d_v as Dictionary).get("file_name", "?")))
		var dup_lbl := Label.new()
		dup_lbl.text = "Duplicate file(s) hidden: " + ", ".join(dup_names)
		dup_lbl.add_theme_color_override("font_color", COL_ACCENT)
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
	if is_hosted:
		meta_lbl.text = "from VostokMods - " + meta_lbl.text
	meta_lbl.add_theme_font_size_override("font_size", FS_META)
	meta_lbl.add_theme_color_override("font_color", COL_TEXT_DIM)
	meta_lbl.clip_text = true
	meta_lbl.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	meta_lbl.tooltip_text = meta_lbl.text
	meta_lbl.mouse_filter = Control.MOUSE_FILTER_PASS
	info_col.add_child(meta_lbl)


# Refresh for a pack that came from VostokMods; disabled while the pack is active.
func _modpacks_row_refresh_button(row: HBoxContainer, entry: Dictionary, tabs: TabContainer, is_active: bool) -> void:
	var refresh_btn := Button.new()
	refresh_btn.text = "Refresh"
	refresh_btn.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	refresh_btn.disabled = is_active
	row.add_child(refresh_btn)
	_wire_hint(refresh_btn, "Unload this pack before refreshing it from VostokMods." if is_active \
			else "Fetch the pack's current mod list from VostokMods.")
	var captured_hosted_entry := entry
	refresh_btn.pressed.connect(func():
		refresh_btn.disabled = true
		refresh_btn.text = "Refreshing..."
		var r: Dictionary = await _hosted_refresh_pack(captured_hosted_entry)
		if is_instance_valid(refresh_btn):
			refresh_btn.disabled = false
			refresh_btn.text = "Refresh"
		if not is_instance_valid(_ui_window):
			return
		if not bool(r.get("ok", false)):
			_show_error_dialog("Could not refresh modpack", str(r.get("error", "unknown")))
		elif bool(r.get("changed", false)):
			if is_instance_valid(tabs):
				_rebuild_modpacks_tab(tabs)
			_show_accept_dialog("Modpack updated", "\"" + str(r.get("name", "")) + "\" was updated from VostokMods. Apply it to get the changes.")
		else:
			_show_info_toast("\"" + str(r.get("name", "")) + "\" is up to date with VostokMods.")
	)


# Full modpack-apply flow: validate, confirm, progress, apply, rebuild, failure dialog.
func _apply_modpack_with_ui_flow(entry: Dictionary, tabs: TabContainer) -> void:
	# Validate up front so the confirm shows a real preview and a bad zip bails early.
	var validation := _validate_modpack(entry)
	if not bool(validation.get("ok", false)):
		_show_error_dialog("Cannot apply modpack", str(validation.get("error", "unknown")))
		return
	var apply_enabled := int(validation.get("enabled_count", 0))
	var apply_total := int(validation.get("total_count", 0))
	var name_str := str(entry.get("raw_name", "?"))
	var missing_preview := _get_missing_mods_for_modpack(entry)
	var dl_count := missing_preview.size()
	var msg := "Apply \"%s\"?\n\nActivates %d of %d mods and replaces your mod settings (MCM)." % [name_str, apply_enabled, apply_total]
	if dl_count > 0:
		msg += "\nWill download %d mod(s)." % dl_count
	msg += "\n\nYour current state is backed up -- click Unload to restore."
	var cd := ConfirmationDialog.new()
	cd.title = "Apply modpack"
	cd.dialog_text = msg
	cd.ok_button_text = "Apply modpack"
	_attach_ui_dialog(cd)
	style_dialog_primary_button(cd.get_ok_button())
	_connect_dialog_exits(cd,
		func():
			cd.queue_free()
			# No progress dialog when nothing downloads; a pop-and-vanish dialog looks broken.
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
					pd_cancel.disabled = true
					pd_cancel.text = "Cancelling..."
					_modpack_apply_cancelled = true
				)
				pd.popup_centered()

			var progress_cb := func(p: Dictionary):
				if not is_instance_valid(pd_status):
					return
				var cur := int(p.get("current", 0))
				var tot := int(p.get("total", 0))
				var nm := str(p.get("mod_name", ""))
				var act := str(p.get("action", ""))
				if is_instance_valid(pd_bar) and tot > 0:
					pd_bar.value = float(cur) / float(tot) * 100.0
				# Rate-limit pause: show the countdown so the dialog does not look hung.
				if act == "rate_wait":
					pd_status.text = "Rate limited by %s -- resuming in %ds" % [str(p.get("host", "the mod site")), int(p.get("wait_s", 0))]
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

			# Cancelled before any state mutation; say so rather than "Applied with Issues".
			if was_cancelled:
				if is_instance_valid(pd):
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
			# Partial: tear down progress, route to the failure dialog.
			if dl_failed > 0:
				if is_instance_valid(pd):
					pd.queue_free()
				if is_instance_valid(tabs):
					_rebuild_modpacks_tab(tabs)
				_show_modpack_failure_dialog(dl, failures, tabs)
				return
			if not bool(result.get("ok", false)):
				if is_instance_valid(pd):
					pd.queue_free()
				_show_error_dialog("Could not apply modpack", str(result.get("error", "unknown")))
				return
			if is_instance_valid(tabs):
				_rebuild_modpacks_tab(tabs)
			# Full success: leave the progress dialog in its completion state.
			if is_instance_valid(pd):
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


# Modpack-apply progress dialog: ProgressBar, status label and Cancel.
# Returns the dialog plus control references; title_override serves the retry pass.
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

	# Attach after content so _attach_ui_dialog reparents it. Non-dismissible
	# while running: a hidden dialog would lift the exclusive input block and
	# let the user Launch or switch profiles mid-apply. Cancel is the way out.
	_attach_ui_dialog(pd)
	pd.dialog_close_on_escape = false
	var pd_ok := pd.get_ok_button()
	if pd_ok != null:
		pd_ok.visible = false

	return {"dialog": pd, "bar": bar, "status": status, "cancel": cancel_btn}


# Read the modpack zip's profile.json into a Dictionary; {} on any failure.
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


# Detail modal for a Modpacks-tab row: size, counts, mod list with installed/missing marks.
func _show_modpack_detail_dialog(entry: Dictionary, active_modpack: String, tabs: TabContainer) -> void:
	var d := AcceptDialog.new()
	d.title = str(entry.get("raw_name", "?"))
	d.ok_button_text = "Close"
	d.min_size = _dialog_fit_size(Vector2i(660, 540))

	var scroll := ScrollContainer.new()
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
	# Hand-edited packs carry null/String values; _count_truthy type-checks each.
	var enabled_count := _count_truthy(enabled_map)
	var installed_count := 0
	var missing_count := 0

	var index := _modpack_installed_index()
	var installed_keys: Dictionary = index["keys"]
	var installed_refs: Dictionary = index["refs"]
	var unavailable_map: Dictionary = parsed.get("unavailable", {}) if parsed.get("unavailable") is Dictionary else {}
	var key_installed := func(k: String) -> bool:
		return installed_keys.has(k) or _modpack_source_installed(sources_map.get(k), installed_refs)

	for k_v in enabled_map.keys():
		if key_installed.call(str(k_v)):
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
			var en: bool = _json_truthy(enabled_map[k_v])
			var installed: bool = key_installed.call(k)
			var src_rec := _normalize_source_record(sources_map.get(k_v))
			var has_source: bool = str(src_rec["provider"]) != ""
			var unavailable_reason: String = str(unavailable_map.get(k_v, ""))
			_modpack_detail_mod_row(box, k, en, installed, has_source, unavailable_reason)

	_modpack_detail_buttons(d, entry, tabs, active_modpack, is_active, another_active)

	_attach_ui_dialog(d)
	_wire_accept_dismiss(d)
	d.popup_centered()


# One line of the pack's mod list: on/off, key, and install status.
func _modpack_detail_mod_row(box: VBoxContainer, k: String, en: bool, installed: bool, has_source: bool, unavailable_reason: String) -> void:
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
	# A hosted pack keys mods by slug; show the slug, not the prefix.
	key_lbl.text = k.trim_prefix(HOSTED_KEY_PREFIX)
	key_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	key_lbl.clip_text = true
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
		status_lbl.add_theme_color_override("font_color", COL_ACCENT)
	elif unavailable_reason != "":
		status_lbl.text = "Not available"
		status_lbl.tooltip_text = _hosted_unavailable_copy(unavailable_reason)
		status_lbl.mouse_filter = Control.MOUSE_FILTER_PASS
		status_lbl.add_theme_color_override("font_color", COL_ERR)
	else:
		status_lbl.text = "Manual install"
		status_lbl.add_theme_color_override("font_color", COL_ERR)
	status_lbl.add_theme_font_size_override("font_size", FS_BODY)
	status_lbl.custom_minimum_size.x = 110
	mod_row.add_child(status_lbl)


# Page, Unload or Apply on the dialog's button bar.
func _modpack_detail_buttons(d: AcceptDialog, entry: Dictionary, tabs: TabContainer, active_modpack: String, is_active: bool, another_active: bool) -> void:
	var hosted_d: Dictionary = entry.get("hosted", {}) if entry.get("hosted") is Dictionary else {}
	var page_url := str(hosted_d.get("url", ""))
	if page_url.begins_with("https://vostokmods.net/"):
		var page_btn := d.add_button("Open page on VostokMods", false, "")
		page_btn.pressed.connect(func():
			OS.shell_open(page_url)
		)
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


# Modpacks published on VostokMods: paste a pack link or search the list.
# "Get" writes the pack into mods/ as a local modpack zip.
func _show_hosted_packs_dialog(tabs: TabContainer) -> void:
	var d := AcceptDialog.new()
	d.title = "Modpacks on VostokMods"
	d.ok_button_text = "Close"
	d.min_size = _dialog_fit_size(Vector2i(680, 560))

	# Everything the handlers share: the dialog's widgets, the paging cursor
	# and the busy flag, in one record passed to every _hosted_* helper.
	var hp := _hosted_dialog_widgets(d, tabs)
	var search: LineEdit = hp["search"]

	var debounce := Timer.new()
	debounce.one_shot = true
	debounce.wait_time = 0.3
	d.add_child(debounce)
	debounce.timeout.connect(func(): _hosted_fetch(hp, false))
	search.text_changed.connect(func(_t: String):
		debounce.stop()
		debounce.start()
	)
	search.text_submitted.connect(func(_t: String):
		debounce.stop()
		_hosted_fetch(hp, false)
	)
	(hp["sort_dropdown"] as OptionButton).item_selected.connect(func(_i: int): _hosted_fetch(hp, false))
	(hp["load_more"] as Button).pressed.connect(func(): _hosted_fetch(hp, true))
	(hp["add_btn"] as Button).pressed.connect(func(): _hosted_add_from_paste(hp))
	(hp["paste"] as LineEdit).text_submitted.connect(func(_t: String): _hosted_add_from_paste(hp))

	_attach_ui_dialog(d)
	_wire_accept_dismiss(d)
	d.popup_centered()
	_hosted_fetch(hp, false)


# Paste row, status line, search and sort, the pack list and Load more.
# Returns the record the _hosted_* helpers share.
func _hosted_dialog_widgets(d: AcceptDialog, tabs: TabContainer) -> Dictionary:
	var outer := VBoxContainer.new()
	outer.add_theme_constant_override("separation", SP_M)
	d.add_child(outer)

	var paste_row := HBoxContainer.new()
	paste_row.add_theme_constant_override("separation", SP_M)
	outer.add_child(paste_row)
	var paste := LineEdit.new()
	paste.placeholder_text = "Paste a modpack link from vostokmods.net"
	paste.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	paste.custom_minimum_size.y = CTRL_H
	paste_row.add_child(paste)
	var add_btn := Button.new()
	add_btn.text = "Add"
	paste_row.add_child(add_btn)

	var status := Label.new()
	status.add_theme_font_size_override("font_size", FS_BODY)
	status.add_theme_color_override("font_color", COL_TEXT_DIM)
	status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	status.text = "Loading packs..."
	outer.add_child(status)

	var search_row := HBoxContainer.new()
	search_row.add_theme_constant_override("separation", SP_M)
	outer.add_child(search_row)
	var search := LineEdit.new()
	search.placeholder_text = "Search packs..."
	search.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	search.custom_minimum_size.y = CTRL_H
	search_row.add_child(search)
	var sort_dropdown := OptionButton.new()
	for opt in [["updated", "Recently updated"], ["newest", "Newest"], ["name", "Name"]]:
		sort_dropdown.add_item(str(opt[1]))
		sort_dropdown.set_item_metadata(sort_dropdown.item_count - 1, str(opt[0]))
	var sort_popup := sort_dropdown.get_popup()
	sort_popup.always_on_top = true
	sort_popup.transient = true
	search_row.add_child(sort_dropdown)

	var scroll := ScrollContainer.new()
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.custom_minimum_size = Vector2(0, 320)
	outer.add_child(scroll)
	var list := VBoxContainer.new()
	list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(list)

	var load_more := Button.new()
	load_more.text = "Load more"
	load_more.visible = false
	outer.add_child(load_more)
	return {
		"d": d, "tabs": tabs,
		"paste": paste, "add_btn": add_btn, "status": status, "search": search,
		"sort_dropdown": sort_dropdown, "list": list, "load_more": load_more,
		"cursor": "", "seq": 0, "busy": false,
	}


# Local hosted packs by slug, so a row can read "Added" instead of "Get".
func _hosted_local_by_slug() -> Dictionary:
	var out := {}
	for e in _modpack_entries:
		var h: Dictionary = e.get("hosted", {}) if e.get("hosted") is Dictionary else {}
		if str(h.get("slug", "")) != "":
			out[str(h.get("slug", ""))] = e
	return out


# Report an import result on the status line and refresh the Modpacks tab.
func _hosted_after_import(hp: Dictionary, r: Dictionary, get_btn: Button) -> void:
	var d = hp["d"]
	var tabs = hp["tabs"]
	var status = hp["status"]
	if not is_instance_valid(d):
		return
	if not bool(r.get("ok", false)):
		status.text = str(r.get("error", "unknown"))
		status.add_theme_color_override("font_color", COL_ERR)
		if is_instance_valid(get_btn):
			get_btn.disabled = false
			get_btn.text = "Get"
		return
	_modpack_entries = collect_modpack_metadata()
	if is_instance_valid(tabs):
		_rebuild_modpacks_tab(tabs)
	status.text = "Added \"" + str(r.get("name", "")) + "\" to your modpacks. Close this window and click Apply on it."
	status.add_theme_color_override("font_color", COL_OK)
	if is_instance_valid(get_btn):
		get_btn.text = "Added"
		get_btn.disabled = true


func _hosted_render_rows(hp: Dictionary, rows: Array, append: bool) -> void:
	var list = hp["list"]
	if not append:
		for c in list.get_children():
			c.queue_free()
	var local: Dictionary = _hosted_local_by_slug()
	for row_v in rows:
		_hosted_render_row(hp, row_v, local)


# One pack row: name, meta, summary, Page and Get.
func _hosted_render_row(hp: Dictionary, row_v: Variant, local: Dictionary) -> void:
	var d = hp["d"]
	var status = hp["status"]
	var list = hp["list"]
	var row: Dictionary = row_v
	var line := HBoxContainer.new()
	line.add_theme_constant_override("separation", SP_L)
	list.add_child(line)
	var col := VBoxContainer.new()
	col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	col.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	line.add_child(col)
	var name_lbl := Label.new()
	name_lbl.text = str(row["name"])
	name_lbl.add_theme_font_size_override("font_size", FS_EMPH)
	name_lbl.add_theme_color_override("font_color", COL_TEXT_HI)
	name_lbl.clip_text = true
	name_lbl.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	col.add_child(name_lbl)
	var parts := PackedStringArray()
	if str(row["author"]) != "":
		parts.append("by " + str(row["author"]))
	if int(row["mod_count"]) >= 0:
		parts.append("%d mods" % int(row["mod_count"]))
	var when := _format_iso_datetime(str(row["updated_at"]))
	if when != "":
		parts.append("updated " + when)
	col.add_child(_make_sub_label(" - ".join(parts), COL_TEXT_DIM, ""))
	if str(row["summary"]) != "":
		var sum_lbl := _make_sub_label(str(row["summary"]), COL_TEXT, "")
		sum_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		col.add_child(sum_lbl)
	var page_btn := Button.new()
	page_btn.text = "Page"
	page_btn.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	var captured_page := str(row["page_url"])
	page_btn.pressed.connect(func():
		if captured_page.begins_with("https://vostokmods.net/"):
			OS.shell_open(captured_page)
	)
	line.add_child(page_btn)
	var get_btn := Button.new()
	get_btn.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	var slug := str(row["slug"])
	if local.has(slug):
		get_btn.text = "Added"
		get_btn.disabled = true
	else:
		get_btn.text = "Get"
	line.add_child(get_btn)
	var captured_manifest := str(row["manifest_url"])
	get_btn.pressed.connect(func():
		if not is_instance_valid(get_btn):
			return
		get_btn.disabled = true
		get_btn.text = "Getting..."
		status.text = "Fetching \"" + str(row["name"]) + "\"..."
		status.add_theme_color_override("font_color", COL_TEXT_DIM)
		var r: Dictionary = await _hosted_pack_from_link(captured_manifest)
		_hosted_after_import(hp, r, get_btn)
	)
	list.add_child(HSeparator.new())


# One page of packs for the current search and sort.
func _hosted_fetch(hp: Dictionary, append: bool) -> void:
	var d = hp["d"]
	var status = hp["status"]
	var search = hp["search"]
	var sort_dropdown = hp["sort_dropdown"]
	var load_more = hp["load_more"]
	hp["seq"] = int(hp["seq"]) + 1
	var my_seq := int(hp["seq"])
	if not append:
		hp["cursor"] = ""
	load_more.disabled = true
	status.text = "Loading packs..." if not append else "Loading more..."
	status.add_theme_color_override("font_color", COL_TEXT_DIM)
	var md: Variant = sort_dropdown.get_item_metadata(sort_dropdown.selected)
	var res: Dictionary = await _vmp_list_modpacks({
		"query": search.text, "sort": str(md) if md != null else "", "cursor": str(hp["cursor"]),
	})
	if not is_instance_valid(d) or int(hp["seq"]) != my_seq:
		return
	if not res["ok"]:
		status.text = host_error_message(HOST_VOSTOKMODS, res)
		status.add_theme_color_override("font_color", COL_ERR)
		load_more.disabled = false
		return
	var page: Dictionary = res["data"]
	_hosted_render_rows(hp, page["rows"], append)
	hp["cursor"] = str(page["next_cursor"])
	load_more.visible = bool(page["has_more"])
	load_more.disabled = not bool(page["has_more"])
	var total := int(page["total"])
	if (page["rows"] as Array).is_empty() and not append:
		status.text = "No packs match." if search.text.strip_edges() != "" else "No modpacks on VostokMods yet."
	elif total >= 0:
		status.text = "%d pack(s) on VostokMods" % total
	else:
		status.text = ""


# Import the pack whose link was pasted, then refresh the list.
func _hosted_add_from_paste(hp: Dictionary) -> void:
	var paste = hp["paste"]
	var add_btn = hp["add_btn"]
	var status = hp["status"]
	if bool(hp["busy"]):
		return
	var text: String = paste.text.strip_edges()
	if text.is_empty():
		return
	hp["busy"] = true
	add_btn.disabled = true
	status.text = "Fetching the pack..."
	status.add_theme_color_override("font_color", COL_TEXT_DIM)
	var r: Dictionary = await _hosted_pack_from_link(text)
	hp["busy"] = false
	if is_instance_valid(add_btn):
		add_btn.disabled = false
	_hosted_after_import(hp, r, null)
	if bool(r.get("ok", false)) and is_instance_valid(paste):
		paste.text = ""
		_hosted_fetch(hp, false)


# Mirror of _rebuild_mods_tab. _rebuilding_modpacks_tab guards against
# recursion: remove_child and the current_tab restore both fire tab_changed.
func _rebuild_modpacks_tab(tabs: TabContainer) -> void:
	if _rebuilding_modpacks_tab:
		return
	_rebuilding_modpacks_tab = true
	var old := tabs.get_node_or_null(UI_TAB_MODPACKS)
	if old == null:
		_rebuilding_modpacks_tab = false
		return
	_rebuilding_tab_in_place = true
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

# Same one-frame-later restore as _restore_mods_scroll.
func _restore_modpacks_scroll(saved_scroll: int) -> void:
	await get_tree().process_frame
	if is_instance_valid(_ui_modpacks_scroll):
		_ui_modpacks_scroll.scroll_vertical = saved_scroll
