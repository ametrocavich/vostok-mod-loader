# Modpacks: Your packs rows, the apply flow and its dialogs, and the Vostok Mods
# pack list that Browse shows under its Modpacks switch, on the Browse pager.

# Set while an Apply pairs ids with Vostok Mods before its confirm; a second click then is ignored.
var _modpack_pairing_busy: bool = false
# Set while the launcher builds Browse after the Modpacks tab scanned mods/.
var _packs_scan_fresh: bool = false

# The pack list outlives its widgets (pages, search, a Get in flight); a detail
# dialog's Get finds it here, and a new launcher window starts it over.
var _packs_state: Dictionary = {}

const _PACKS_SNAPSHOT := "vostokmods_packs"
const _UNLOAD_HINT := "Bring back the setup you had before this pack."

func _show_modpack_failure_dialog(downloaded: int, failures: Array, tabs: TabContainer) -> void:
	var d := AcceptDialog.new()
	d.title = "Modpack applied with issues"
	d.ok_button_text = "Close"
	d.min_size = _dialog_fit_size(Vector2i(540, 420))

	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", SP_M)
	d.add_child(box)
	box.add_child(_make_label("Downloaded %d mod(s), %d failed." % [downloaded, failures.size()]))

	var scroll := _make_scroll(box)
	scroll.custom_minimum_size = Vector2(d.min_size - Vector2i(20, 140))
	var list := _make_scroll_column(scroll, SP_S)

	for f: Dictionary in failures:
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", SP_M)
		list.add_child(row)

		var info_col := VBoxContainer.new()
		info_col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(info_col)

		var key := str(f["profile_key"])
		var name_lbl := _make_label(str(_pack_mod_names.get(key, key)))
		name_lbl.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		name_lbl.tooltip_text = key
		name_lbl.mouse_filter = Control.MOUSE_FILTER_PASS
		info_col.add_child(name_lbl)

		var err_lbl := _make_label(str(f["error"]), COL_ERR, FS_BODY)
		err_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		info_col.add_child(err_lbl)

		var f_ref: Dictionary = f["ref"]
		var page_url := host_mod_page_url(f_ref)
		if page_url != "":
			var open_btn := Button.new()
			open_btn.text = "Open page on " + host_display_name(str(f_ref["provider"]))
			open_btn.size_flags_vertical = Control.SIZE_SHRINK_CENTER
			row.add_child(open_btn)
			open_btn.pressed.connect(func(): OS.shell_open(page_url))

	if failures.any(func(f): return _modpack_ref_downloadable((f as Dictionary)["ref"])):
		var retry_btn := d.add_button("Retry failed", false, "")
		style_primary_button(retry_btn)
		retry_btn.pressed.connect(func():
			_close_dialog(d)
			_run_modpack_retry(failures, tabs)
		)

	_present_dialog(d)

# The progress dialog is exclusive and cannot be dismissed, so the launcher
# and `tabs` outlive the await.
func _run_modpack_retry(failures: Array, tabs: TabContainer) -> void:
	_modpack_apply_cancelled = false
	var progress_ui := _build_modpack_progress_dialog("", "Retrying failed downloads")
	var pd: AcceptDialog = progress_ui["dialog"]
	pd.popup_centered()

	var progress_cb := _modpack_progress_callback(progress_ui["status"], progress_ui["bar"], true)
	var result := await retry_failed_downloads(failures, progress_cb)
	pd.queue_free()
	_rebuild_mods_tab(tabs)

	var still_failed: Array = result["failures"]
	var dl: int = result["downloaded"]
	if still_failed.is_empty():
		_show_accept_dialog("Retry complete", "Downloaded %d mod(s) on retry." % dl, "Close")
	else:
		_show_modpack_failure_dialog(dl, still_failed, tabs)

func build_modpacks_tab(tabs: TabContainer) -> Control:
	var margin := _make_tab_margin()

	var container := VBoxContainer.new()
	container.add_theme_constant_override("separation", SP_M)
	margin.add_child(container)

	_modpack_entries = collect_modpack_metadata()
	_ui_modpacks_scroll = null
	if _modpack_entries.is_empty():
		var hint := _make_label("No packs yet. Get one under Browse > Modpacks and it shows up here, ready to Apply.",
				COL_TEXT_DIM, FS_BODY)
		hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		container.add_child(hint)
		return margin
	var scroll := _make_scroll(container)
	_ui_modpacks_scroll = scroll
	var list := _make_scroll_column(scroll, SP_S)
	var active_modpack := get_active_modpack()
	var index := _modpack_installed_index()
	for entry in _modpack_entries:
		list.add_child(_pack_row(entry, active_modpack, tabs, index))
		list.add_child(HSeparator.new())
	return margin

func _unload_modpack_with_feedback(tabs: TabContainer) -> void:
	var result := unload_modpack(tabs)
	if result.get("needs_force", false):
		_show_danger_confirm("Could not unload modpack", result["error"] + "\n\nKeep the pack's mods as a profile named \""
				+ result["profile"] + "\" and leave the pack?", "Keep as profile", func():
			var forced := force_unload_modpack(tabs)
			if not forced["ok"]:
				_show_error_dialog("Could not unload modpack", forced["error"])
			_rebuild_modpacks_tab(tabs))
		return
	if not result["ok"]:
		_show_error_dialog("Could not unload modpack", str(result["error"]))
	_rebuild_modpacks_tab(tabs)

func _modpack_active_state(entry: Dictionary, active_modpack: String) -> Dictionary:
	var sanitized: String = entry["sanitized_name"]
	return {
		"is_active": active_modpack != "" and active_modpack == sanitized,
		"another_active": active_modpack != "" and active_modpack != sanitized,
	}

# get_active_modpack() holds the sanitized id; players know the pack by its name.
func _another_active_text(active_modpack: String) -> String:
	var shown := active_modpack
	for e in _modpack_entries:
		if e["sanitized_name"] == active_modpack:
			shown = e["raw_name"]
	return "Unload \"" + shown + "\" before applying another modpack."

func _pack_row(entry: Dictionary, active_modpack: String, tabs: TabContainer, index: Dictionary) -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", SP_L)

	# Every row reserves the cover cell, so the names line up.
	_browse_load_thumbnail_async(_make_thumb_cell(row, Vector2(96, 54), true, true), _pack_cover(entry))
	var hosted: Dictionary = entry["hosted"]
	var is_hosted := str(hosted.get("slug", "")) != ""
	_pack_row_info(row, entry, is_hosted, _pack_stats(_modpack_read_profile(entry["file_path"]), 0, index))

	var active_state := _modpack_active_state(entry, active_modpack)
	var is_active: bool = active_state["is_active"]

	var details_btn := Button.new()
	details_btn.text = "Details"
	details_btn.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(details_btn)
	details_btn.pressed.connect(func(): _local_pack_dialog(entry, tabs))
	_wire_hint(details_btn, "Open the modpack's full mod list and description.")

	if is_hosted:
		var refresh_btn := Button.new()
		refresh_btn.text = "Refresh"
		refresh_btn.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		refresh_btn.disabled = is_active
		row.add_child(refresh_btn)
		_wire_hint(refresh_btn, "Unload this pack before refreshing it from Vostok Mods." if is_active \
				else "Get the pack's current mod list from Vostok Mods.")
		refresh_btn.pressed.connect(_refresh_pack.bind(entry, refresh_btn, tabs))

	if is_active:
		var active_lbl := _make_label("Active", COL_TEXT_HI, FS_META)
		active_lbl.add_theme_stylebox_override("normal", _make_badge_stylebox(COL_OK, COL_OK_DIM))
		active_lbl.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		row.add_child(active_lbl)

		var unload_btn := Button.new()
		unload_btn.text = "Unload"
		style_danger_button(unload_btn)
		unload_btn.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		row.add_child(unload_btn)
		unload_btn.pressed.connect(func(): _unload_modpack_with_feedback(tabs))
		_wire_hint(unload_btn, _UNLOAD_HINT)
	else:
		# Primary styling is kept for the detail dialog's Apply and the confirm OK.
		var apply_btn := Button.new()
		apply_btn.text = "Apply"
		apply_btn.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		apply_btn.disabled = active_state["another_active"]
		row.add_child(apply_btn)
		apply_btn.pressed.connect(func(): _apply_modpack_with_ui_flow(entry, tabs))
		if apply_btn.disabled:
			_wire_hint(apply_btn, _another_active_text(active_modpack))
	return row

func _refresh_pack(entry: Dictionary, btn: Button, tabs: TabContainer) -> void:
	btn.disabled = true
	btn.text = "Refreshing..."
	var r: Dictionary = await _hosted_refresh_pack(entry)
	if is_instance_valid(btn):
		btn.disabled = false
		btn.text = "Refresh"
	if _ui_window == null:
		return
	if not r["ok"]:
		_show_error_dialog("Could not refresh modpack", str(r["error"]))
	elif r["changed"]:
		if is_instance_valid(tabs):
			_rebuild_modpacks_tab(tabs)
		_show_accept_dialog("Modpack updated", "\"" + str(r["name"]) + "\" was updated from Vostok Mods. Apply it to get the changes. Edits you made to this pack are reset to the author's new setup.")
	else:
		_show_info_toast("\"" + str(r["name"]) + "\" is up to date with Vostok Mods.")

func _pack_row_info(row: HBoxContainer, entry: Dictionary, is_hosted: bool, stats: Dictionary) -> void:
	var info_col := VBoxContainer.new()
	info_col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	info_col.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(info_col)

	var name_row := HBoxContainer.new()
	name_row.add_theme_constant_override("separation", SP_M)
	info_col.add_child(name_row)

	# Clipped: the name comes from the zip and must not push the buttons out of view.
	var raw_name: String = entry["raw_name"]
	var name_lbl := _make_sub_label(raw_name, COL_TEXT_HI, raw_name, FS_HEAD)
	name_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	name_row.add_child(name_lbl)

	var author: String = entry["author"]
	if not author.is_empty():
		var author_lbl := _make_label("by " + author, COL_TEXT_DIM, FS_BODY)
		author_lbl.size_flags_vertical = Control.SIZE_SHRINK_END
		name_row.add_child(author_lbl)

	var description: String = entry["description"]
	if not description.is_empty():
		var desc_lbl := _make_label(description, COL_TEXT, FS_BODY)
		desc_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		info_col.add_child(desc_lbl)

	var dups: Array = entry.get("duplicates_hidden", [])
	if not dups.is_empty():
		var dup_names := PackedStringArray()
		for dup: Dictionary in dups:
			dup_names.append(dup["file_name"])
		var dup_lbl := _make_label("Duplicate file(s) hidden: " + ", ".join(dup_names), COL_WARN, FS_BODY)
		dup_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		info_col.add_child(dup_lbl)

	var meta_text := _pack_counts(stats)
	if is_hosted:
		meta_text = "from Vostok Mods - " + meta_text
	info_col.add_child(_make_sub_label(meta_text, COL_TEXT_DIM, meta_text, FS_META))

# What the pack lists and how much of it is installed, not what is on now.
func _pack_counts(stats: Dictionary) -> String:
	return "%d mods - %d installed" % [(stats["enabled_map"] as Dictionary).size(), stats["installed_count"]]

# The URL comes from the pack zip, which a player can edit.
func _pack_cover(entry: Dictionary) -> Dictionary:
	var url := _https_url(entry["thumbnail_url"])
	return host_image(url, _url_thumb_key(url))

func _apply_modpack_with_ui_flow(entry: Dictionary, tabs: TabContainer) -> void:
	if _modpack_pairing_busy:
		return
	var validation := _validate_modpack(entry)
	if not validation["ok"]:
		_show_error_dialog("Could not apply modpack", str(validation["error"]))
		return
	# Pair Vostok Mods slugs and UUIDs first, so the preview counts a pack mod
	# installed under its other id as installed.
	if not _modpack_apply_in_progress and not _modpack_unpaired_host_refs(entry).is_empty():
		_modpack_pairing_busy = true
		var busy_text := "Checking Vostok Mods for this pack's installed mods..."
		if is_instance_valid(_ui_hint_label):
			_ui_hint_label.text = busy_text
		await _modpack_learn_host_ids(entry, false)
		_modpack_pairing_busy = false
		if is_instance_valid(_ui_hint_label) and _ui_hint_label.text == busy_text:
			_ui_hint_label.text = _ui_hint_default
		if not is_instance_valid(tabs):
			return

	var name_str: String = entry["raw_name"]
	var preview_counts := _modpack_download_counts(_get_missing_mods_for_modpack(entry))
	var dl_count: int = preview_counts["download"]
	var cd := ConfirmationDialog.new()
	cd.title = "Apply modpack"
	cd.dialog_text = _apply_confirm_text(name_str, validation["enabled_count"],
			validation["total_count"], dl_count, preview_counts["blocked"])
	cd.ok_button_text = "Apply modpack"
	_attach_ui_dialog(cd)
	style_dialog_primary_button(cd.get_ok_button())
	var run := func():
		cd.queue_free()
		# No progress dialog when nothing downloads: a pop-and-vanish dialog looks broken.
		var pd_ui := {}
		if dl_count > 0:
			pd_ui = _build_modpack_progress_dialog(name_str)
			(pd_ui["dialog"] as AcceptDialog).popup_centered()
		var progress_cb := _modpack_progress_callback(pd_ui.get("status"), pd_ui.get("bar"), false)
		var result := await apply_modpack(entry, tabs, progress_cb)
		_apply_modpack_finish(result, pd_ui, tabs)
	_connect_dialog_exits(cd, run, func(): cd.queue_free())
	cd.popup_centered()

func _apply_confirm_text(name_str: String, apply_enabled: int, apply_total: int, dl_count: int,
		blocked_count: int) -> String:
	var msg := "Apply \"%s\"?\n\nActivates %d of %d mods and replaces your mod settings." % [name_str, apply_enabled, apply_total]
	if dl_count > 0:
		msg += "\nWill download %d mod(s)." % dl_count
	if blocked_count > 0:
		msg += "\n%d mod(s) cannot be downloaded and will be listed to install by hand." % blocked_count
	msg += "\n\nYour current state is backed up -- click Unload to restore."
	return msg

# `tabs` is untyped: with nothing to download no dialog blocks Launch, and a freed
# widget cannot pass a typed parameter. pd_ui is {} without a progress dialog.
func _apply_modpack_finish(result: Dictionary, pd_ui: Dictionary, tabs: Variant) -> void:
	var outcome := _modpack_apply_outcome(result)
	# Only a full success keeps the progress dialog; it becomes the result.
	var pd: Variant = pd_ui.get("dialog")
	if outcome != "applied" and is_instance_valid(pd):
		pd.queue_free()
	match outcome:
		"cancelled":
			_finish_cancelled(result, tabs)
		"failed":
			_finish_failed(result, tabs)
		"partial":
			_finish_partial(result, tabs)
		_:
			_finish_applied(result, pd_ui, tabs)

func _finish_cancelled(result: Dictionary, tabs: Variant) -> void:
	var dl: int = result["downloaded"]
	var dl_failed: int = result["failed_downloads"]
	if is_instance_valid(tabs):
		_rebuild_modpacks_tab(tabs)
		# Mods downloaded before the cancel stay on disk.
		if dl > 0:
			_rebuild_mods_tab(tabs)
	var cancel_msg := "Apply cancelled -- the modpack was not applied and your profiles are unchanged."
	if dl > 0:
		cancel_msg += "\n%d downloaded mod(s) remain in your mods folder." % dl
	if dl_failed > 0:
		cancel_msg += "\n%d download(s) had already failed before the cancel." % dl_failed
	_show_accept_dialog("Apply cancelled", cancel_msg)

func _finish_failed(result: Dictionary, tabs: Variant) -> void:
	var dl_failed: int = result["failed_downloads"]
	if result["downloaded"] > 0 and is_instance_valid(tabs):
		_rebuild_mods_tab(tabs)
	var fail_msg := str(result["error"])
	if dl_failed > 0:
		fail_msg += "\n\n%d mod download(s) had also failed." % dl_failed
	_show_error_dialog("Could not apply modpack", fail_msg)

func _finish_partial(result: Dictionary, tabs: Variant) -> void:
	if is_instance_valid(tabs):
		_rebuild_modpacks_tab(tabs)
		if _ui_window != null:
			_show_modpack_failure_dialog(result["downloaded"], result["failures"], tabs)

func _finish_applied(result: Dictionary, pd_ui: Dictionary, tabs: Variant) -> void:
	if is_instance_valid(tabs):
		_rebuild_modpacks_tab(tabs)
	var pd: Variant = pd_ui.get("dialog")
	if not is_instance_valid(pd):
		return
	var dialog: AcceptDialog = pd
	(pd_ui["bar"] as ProgressBar).value = 100
	(pd_ui["status"] as Label).text = "Modpack applied. Downloaded %d mod(s)." % result["downloaded"]
	(pd_ui["cancel"] as Button).visible = false
	dialog.dialog_close_on_escape = true
	dialog.get_ok_button().visible = true
	_wire_accept_dismiss(dialog)

func _build_modpack_progress_dialog(raw_name: String, title_override: String = "") -> Dictionary:
	var pd := AcceptDialog.new()
	pd.title = title_override if title_override != "" else "Applying modpack \"" + raw_name + "\""
	pd.min_size = Vector2i(520, 200)
	pd.ok_button_text = "Close"

	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", SP_M)
	pd.add_child(box)

	var status := _make_label("Preparing...")
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
	cancel_btn.pressed.connect(func():
		status.text = "Cancelling after current download..."
		cancel_btn.disabled = true
		cancel_btn.text = "Cancelling..."
		_modpack_apply_cancelled = true
	)

	# After the content, which _attach_ui_dialog reparents. Not dismissible: a hidden
	# dialog lifts the exclusive input block, and Launch would work mid-apply.
	_attach_ui_dialog(pd)
	pd.dialog_close_on_escape = false
	pd.get_ok_button().visible = false
	return {"dialog": pd, "bar": bar, "status": status, "cancel": cancel_btn}

const _PROGRESS_VERBS := {"skipped": "Skipping (install by hand)", "applying": "Applying modpack"}

# The retry pass calls every step "Retrying"; null labels (no progress dialog) make it a no-op.
func _modpack_progress_callback(status: Label, bar: ProgressBar, retry_pass: bool) -> Callable:
	return func(p: Dictionary):
		if not is_instance_valid(status):
			return
		var cur: int = p["current"]
		var tot: int = p["total"]
		if tot > 0:
			bar.value = float(cur) / float(tot) * 100.0
		var act: String = p["action"]
		if act == "rate_wait":
			status.text = _rate_wait_text(str(p["host"]), int(p["wait_s"]))
			return
		var prefix := "Retrying" if retry_pass else str(_PROGRESS_VERBS.get(act, "Downloading"))
		var nm: String = p["mod_name"]
		if nm != "":
			status.text = "%s %d of %d:\n%s" % [prefix, cur, tot, nm]
		else:
			status.text = "%s..." % prefix

# The body both pack details share: head, counts line, mod list and page button.
func _pack_dialog(title: String, head: Dictionary, meta_text: String, page_url: String) -> Dictionary:
	var shell := _new_scroll_dialog(title, _DETAIL_DIALOG_SIZE, SP_L)
	var d: AcceptDialog = shell["d"]
	var box: VBoxContainer = shell["box"]
	var view := {"d": d, "box": box, "desc": null, "banner": null, "dl_status": null, "is_active": false}
	_detail_head(view, shell["outer"], head, meta_text)
	var counts := _make_label("", COL_TEXT, FS_EMPH)
	counts.visible = false
	box.add_child(counts)
	box.add_child(HSeparator.new())
	box.add_child(_make_label("Mods", null, FS_HEAD))
	var mods_status := _make_label("Loading the mod list...", COL_TEXT_DIM, FS_BODY)
	mods_status.visible = false
	box.add_child(mods_status)
	var mods := VBoxContainer.new()
	box.add_child(mods)
	view.merge({"counts": counts, "mods": mods, "mods_status": mods_status})
	if _hosted_page_url_ok(page_url):
		var page_btn := d.add_button("Open page on Vostok Mods", false, "")
		page_btn.pressed.connect(func(): OS.shell_open(page_url))
	return view

func _local_pack_dialog(entry: Dictionary, tabs: TabContainer) -> Dictionary:
	var hosted: Dictionary = entry["hosted"]
	var head := host_empty_summary()
	head["thumbnail"] = _pack_cover(entry)
	head["short_description"] = entry["description"]
	var meta_text: String = entry["file_name"]
	if entry["author"] != "":
		meta_text = "by " + entry["author"] + "  -  " + meta_text
	var view := _pack_dialog(entry["raw_name"], head, meta_text, str(hosted.get("url", "")))
	var d: AcceptDialog = view["d"]
	var active_modpack := get_active_modpack()
	var active_state := _modpack_active_state(entry, active_modpack)
	view["is_active"] = active_state["is_active"]
	var stats := _modpack_detail_stats(entry)
	_fill_pack_mods(view, stats, {})
	if view["is_active"]:
		var unload_btn := d.add_button("Unload", true, "")
		style_danger_button(unload_btn)
		unload_btn.tooltip_text = _UNLOAD_HINT
		unload_btn.pressed.connect(func():
			_close_dialog(d)
			_unload_modpack_with_feedback(tabs)
		)
	else:
		var apply_btn := d.add_button("Apply", true, "")
		style_primary_button(apply_btn)
		apply_btn.disabled = active_state["another_active"]
		if apply_btn.disabled:
			apply_btn.tooltip_text = _another_active_text(active_modpack)
		apply_btn.pressed.connect(func():
			_close_dialog(d)
			_apply_modpack_with_ui_flow(entry, tabs)
		)
	var slug := str(hosted.get("slug", ""))
	if slug != "":
		_load_pack_manifest(view, _pack_manifest_url(hosted), stats)
		_load_pack_page(view, slug)
	_present_dialog(d)
	return view

func _listing_pack_dialog(summary: Dictionary) -> Dictionary:
	var state := _packs_record()
	var slug := str(summary["slug"])
	var meta_text := _browse_meta_text(summary, host_caps(HOST_VOSTOKMODS)["metrics"], _mod_count_label(summary))
	var view := _pack_dialog(str(summary["name"]), summary, meta_text, str(summary["page_url"]))
	(view["mods_status"] as Label).visible = true
	var get_btn := (view["d"] as AcceptDialog).add_button("Get", true, "")
	get_btn.set_meta(_BROWSE_META_DIALOG_STATUS, view["dl_status"])
	(state["detail_gets"] as Array).append([get_btn, slug])
	_paint_get(get_btn, slug, state)
	get_btn.pressed.connect(func(): _get_pack(state, summary, get_btn))
	_load_pack_manifest(view, _vmp_modpack_manifest_url(str(summary["manifest_url"])), {})
	_load_pack_page(view, slug)
	_present_dialog(view["d"])
	return view

# Not awaited: the dialog shows before the site answers. A local pack (local_stats
# not {}) keeps its own list and takes only the names; offline it shows its keys.
func _load_pack_manifest(view: Dictionary, url: String, local_stats: Dictionary) -> void:
	var res := await _vmp_fetch_modpack_manifest(url)
	if not is_instance_valid(view["mods"]):
		return
	var status: Label = view["mods_status"]
	if not res["ok"]:
		if local_stats.is_empty():
			status.text = _hosted_fetch_error_copy(res)
			status.add_theme_color_override("font_color", COL_ERR)
		return
	status.visible = false
	var manifest: Dictionary = res["data"]
	var stats := local_stats
	if stats.is_empty():
		stats = _pack_stats(_hosted_manifest_to_profile(manifest)["profile"], 0, _modpack_installed_index())
	_fill_pack_mods(view, stats, _manifest_names(manifest))

# Not awaited, like _load_pack_manifest; the description and banner are extras.
func _load_pack_page(view: Dictionary, slug: String) -> void:
	var res := await _vmp_modpack_detail(slug)
	if not res["ok"] or not is_instance_valid(view["d"]):
		return
	var detail: Dictionary = res["data"]
	_detail_description(view, str(detail["description"]))
	var banner: Dictionary = detail["banner"]
	if str(banner["url"]) != "" and view["banner"] != null:
		_browse_load_thumbnail_async(view["banner"], banner)

# names maps a pack key to the manifest's mod name; without one the row shows the key.
func _fill_pack_mods(view: Dictionary, stats: Dictionary, names: Dictionary) -> void:
	var enabled_map: Dictionary = stats["enabled_map"]
	var sources_map: Dictionary = stats["sources_map"]
	var unavailable_map: Dictionary = stats["unavailable_map"]
	var installed: Dictionary = stats["installed"]
	var is_active: bool = view["is_active"]
	var counts_parts := PackedStringArray([_pack_counts(stats)])
	if stats["zip_size"] > 0:
		counts_parts.append(_format_size(stats["zip_size"]))
	if is_active:
		counts_parts.append("active")
	var counts: Label = view["counts"]
	counts.text = " - ".join(counts_parts)
	counts.add_theme_color_override("font_color", COL_OK if is_active else COL_TEXT)
	counts.visible = true

	# Freed at once: a local pack refills the list when the manifest's names land.
	var mods: VBoxContainer = view["mods"]
	for c in mods.get_children():
		c.free()
	if enabled_map.is_empty():
		mods.add_child(_make_label("This modpack lists no mods.", COL_TEXT_DIM, FS_BODY))
		return
	var sorted_keys: Array = enabled_map.keys()
	sorted_keys.sort()
	for k_v in sorted_keys:
		var k: String = str(k_v)
		var has_source: bool = str(_normalize_source_record(sources_map.get(k_v))["provider"]) != ""
		_pack_detail_row(mods, k, _json_truthy(enabled_map[k_v]), installed[k], has_source,
				str(unavailable_map.get(k_v, "")), str(names.get(k, "")))

# An unreadable pack lists no mods.
func _modpack_detail_stats(entry: Dictionary) -> Dictionary:
	var file_path: String = entry["file_path"]
	var zip_size := 0
	if FileAccess.file_exists(file_path):
		var f := FileAccess.open(file_path, FileAccess.READ)
		if f != null:
			zip_size = f.get_length()
			f.close()
	return _pack_stats(_modpack_read_profile(file_path), zip_size, _modpack_installed_index())

# pd is a pack's profile.json, or a manifest converted to one before the pack is written.
func _pack_stats(pd: Variant, zip_size: int, index: Dictionary) -> Dictionary:
	var enabled_map := _pack_dict(pd, "enabled")
	var sources_map := _pack_dict(pd, "sources")
	var checksums_map := _pack_dict(pd, "checksums")
	var installed := {}
	var installed_count := 0
	for k_v in enabled_map.keys():
		var k := str(k_v)
		installed[k] = _modpack_key_installed(k, sources_map, checksums_map, index)
		if installed[k]:
			installed_count += 1
	return {
		"zip_size": zip_size,
		"enabled_map": enabled_map,
		"sources_map": sources_map,
		"unavailable_map": _pack_dict(pd, "unavailable"),
		"installed": installed,
		"installed_count": installed_count,
	}

func _pack_detail_row(box: VBoxContainer, k: String, en: bool, installed: bool, has_source: bool,
		unavailable_reason: String, mod_name: String) -> void:
	var mod_row := HBoxContainer.new()
	mod_row.add_theme_constant_override("separation", SP_M)
	box.add_child(mod_row)

	var en_lbl := _make_label("[on]" if en else "[off]", COL_OK if en else COL_TEXT_DIM, FS_BODY)
	en_lbl.custom_minimum_size.x = 40
	mod_row.add_child(en_lbl)

	# A hosted pack keys mods by slug; without a name, show the slug without the prefix.
	var key_lbl := _make_label(mod_name if mod_name != "" else k.trim_prefix(HOSTED_KEY_PREFIX))
	key_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	key_lbl.clip_text = true
	key_lbl.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	key_lbl.tooltip_text = k
	key_lbl.mouse_filter = Control.MOUSE_FILTER_PASS
	mod_row.add_child(key_lbl)

	var status_lbl: Label
	if installed:
		status_lbl = _make_label("Installed", COL_OK, FS_BODY)
	elif has_source:
		status_lbl = _make_label("Will download", COL_ACCENT, FS_BODY)
	elif unavailable_reason != "":
		status_lbl = _make_label("Not available", COL_ERR, FS_BODY)
		status_lbl.tooltip_text = _hosted_unavailable_copy(unavailable_reason)
		status_lbl.mouse_filter = Control.MOUSE_FILTER_PASS
	else:
		status_lbl = _make_label("Install by hand", COL_TEXT_DIM, FS_BODY)
	status_lbl.custom_minimum_size.x = 110
	mod_row.add_child(status_lbl)

func _hosted_page_url_ok(url: String) -> bool:
	return _vmp_is_site_url(url)

func _rebuild_modpacks_tab(tabs: TabContainer) -> void:
	_rebuild_tab_in_place(tabs, UI_TAB_MODPACKS, build_modpacks_tab, func(): return _ui_modpacks_scroll)

# The Vostok Mods pack list: every key the Browse pager and the pack pane read. The
# pager calls list_fn, row_fn, empty_fn and retry; the view lives under HOST_VOSTOKMODS.
func _packs_record() -> Dictionary:
	var win_id := _ui_window.get_instance_id() if _ui_window != null else 0
	if _packs_state.get("window_id", -1) == win_id:
		return _packs_state
	# Bound to the record itself, they would keep the old window's record alive.
	for k in ["list_fn", "row_fn", "empty_fn", "retry"]:
		_packs_state.erase(k)
	var view := {"query": "", "category_ref": "", "category_name": "", "cursor": "", "has_more": false,
			"loaded_rows": [], "total": -1, "cached_at": 0}
	_set_sort(view, _VM_PACK_SORTS[0])
	var state := {"window_id": win_id, "provider": HOST_VOSTOKMODS, "views": {HOST_VOSTOKMODS: view},
			# first_seq is the fetch_seq of a first page still in flight, else -1.
			"fetch_seq": 0, "first_seq": -1, "noun": "packs", "fail_status": "Could not load packs.",
			"busy": false, "busy_slug": "", "paste_text": "", "get_btns": {}, "detail_gets": [],
			"on_screen": false, "filled": false,
			"search_input": null, "sort_dropdown": null, "paste": null, "add_btn": null,
			"banner_slot": null, "status_lbl": null, "scroll": null, "list": null, "load_more_btn": null}
	state["list_fn"] = _list_packs.bind(state)
	state["row_fn"] = _listing_row.bind(state)
	state["empty_fn"] = _packs_empty_copy.bind(state)
	state["retry"] = _fetch_listing.bind(state, false)
	_packs_state = state
	return state

# The Modpacks controls go into the Browse toolbar and the list into area; the
# returned group is what the switch hides.
func _build_packs_pane(state: Dictionary, toolbar: HBoxContainer, area: VBoxContainer) -> HBoxContainer:
	var v := _browse_view(state)
	var group := HBoxContainer.new()
	group.add_theme_constant_override("separation", SP_M)
	group.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	toolbar.add_child(group)

	var search := LineEdit.new()
	search.placeholder_text = "Search Vostok Mods packs..."
	search.max_length = _VM_QUERY_MAX_LEN
	search.text = str(v["query"])
	search.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	search.custom_minimum_size = Vector2(160, CTRL_H)
	group.add_child(search)

	var sort_dropdown := OptionButton.new()
	for opt: Dictionary in _VM_PACK_SORTS:
		sort_dropdown.add_item(str(opt["label"]))
		sort_dropdown.set_item_metadata(sort_dropdown.item_count - 1, opt)
		if opt["key"] == v["sort_key"]:
			sort_dropdown.select(sort_dropdown.item_count - 1)
	sort_dropdown.custom_minimum_size.y = CTRL_H
	_style_option_popup(sort_dropdown)
	group.add_child(sort_dropdown)

	var paste := LineEdit.new()
	paste.placeholder_text = "Paste a pack link (vostokmods.net/modpack/...)"
	paste.text = state["paste_text"]
	paste.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	paste.custom_minimum_size = Vector2(160, CTRL_H)
	group.add_child(paste)
	var add_btn := Button.new()
	add_btn.text = "Get"
	add_btn.disabled = state["busy"]
	style_primary_button(add_btn)
	group.add_child(add_btn)
	_wire_hint(add_btn, "Get the pack at this link into Your packs.")

	state.merge({"search_input": search, "sort_dropdown": sort_dropdown, "paste": paste,
			"add_btn": add_btn, "get_btns": {}, "filled": false}, true)
	state.merge(_browse_build_list_area(area), true)
	_wire_search(state, area, state["retry"])
	sort_dropdown.item_selected.connect(func(idx: int):
		_set_sort(_browse_view(state), sort_dropdown.get_item_metadata(idx))
		_clear_list(state, "Loading...")
		_fetch_listing(state, false)
	)
	(state["load_more_btn"] as Button).pressed.connect(_fetch_listing.bind(state, true))
	paste.text_changed.connect(func(t: String): state["paste_text"] = t)
	add_btn.pressed.connect(_add_pasted_pack.bind(state))
	paste.text_submitted.connect(func(_t: String): _add_pasted_pack(state))
	return group

# The pack kind coming on screen. New widgets take the loaded pages, and an empty
# view (a failed page) fetches again; a first page in flight renders when it lands.
func _fill_packs_pane(state: Dictionary) -> void:
	var v := _browse_view(state)
	var rows: Array = v["loaded_rows"]
	var in_flight: bool = state["first_seq"] == state["fetch_seq"]
	if state["filled"] and (in_flight or not rows.is_empty()):
		return
	state["filled"] = true
	if not _packs_scan_fresh:
		_modpack_entries = collect_modpack_metadata()
	if in_flight:
		_set_status(state, "Loading...", COL_TEXT_DIM)
	elif rows.is_empty():
		_fetch_listing(state, false)
	else:
		_browse_render_rows(state, rows)
		_landing_banner(state, int(v["cached_at"]), false)
		var total := int(v["total"])
		_set_status(state, "%d of %d packs" % [rows.size(), total] if total >= 0 else "%d packs" % rows.size(), COL_TEXT_DIM)
		var more: Button = state["load_more_btn"]
		more.visible = v["has_more"]
		more.disabled = not v["has_more"]

# The unfiltered first page is the offline snapshot, its section titled with the sort,
# so cached rows never pose as search results or as another order.
func _list_packs(q: Dictionary, state: Dictionary) -> Dictionary:
	var seq := int(state["fetch_seq"])
	var first := str(q["cursor"]) == ""
	if first:
		state["first_seq"] = seq
	var res := await _vmp_list_modpacks({"query": q["query"], "sort": q["sort_key"], "cursor": q["cursor"]})
	if int(state["fetch_seq"]) != seq:
		return res
	if first:
		state["first_seq"] = -1
	var landing := first and str(q["query"]) == ""
	if res["ok"] and landing:
		# A copy: Load more appends to the page's rows.
		_store_landing(_PACKS_SNAPSHOT, [{"title": q["sort_key"], "rows": (res["data"]["rows"] as Array).duplicate()}])
	elif landing:
		var snap := _browse_landing_snapshot(_PACKS_SNAPSHOT)
		var sections: Array = snap.get("sections", [])
		if not sections.is_empty() and sections[0]["title"] == q["sort_key"]:
			var rows: Array = sections[0]["rows"]
			var page := host_page(rows, false, "", rows.size())
			page["cached_at"] = int(snap["saved_at_unix"])
			res = host_ok(page)
	var v := _browse_view(state)
	if res["ok"]:
		v["total"] = int(res["data"]["total"])
		v["cached_at"] = int(res["data"].get("cached_at", 0))
	elif first:
		v["loaded_rows"] = []
	return res

func _packs_empty_copy(state: Dictionary) -> String:
	if str(_browse_view(state)["query"]) != "":
		return "No pack matches that search."
	return "No packs on Vostok Mods yet."

func _mod_count_label(summary: Dictionary) -> String:
	var n := _host_count(summary["mod_count"])
	return "%d mods" % n if n >= 0 else ""

func _listing_row(summary: Dictionary, _install_map: Dictionary, state: Dictionary) -> Control:
	var slug := str(summary["slug"])
	var row := _row_frame(summary, _mod_count_label(summary), _listing_pack_dialog.bind(summary))
	var get_btn := Button.new()
	get_btn.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_paint_get(get_btn, slug, state)
	get_btn.pressed.connect(func(): _get_pack(state, summary, get_btn))
	row.add_child(get_btn)
	_wire_hint(get_btn, "Save this pack to Your packs; no mods download until you Apply it.")
	(state["get_btns"] as Dictionary)[slug] = get_btn
	return row

# Import lowercases the slug it keeps; the listing's may differ in case.
func _paint_get(btn: Button, slug: String, state: Dictionary) -> void:
	var added := false
	for e in _modpack_entries:
		if str((e["hosted"] as Dictionary).get("slug", "")).to_lower() == slug.to_lower():
			added = true
	if added:
		btn.text = "Added"
		btn.disabled = true
	elif state["busy"] and state["busy_slug"] == slug:
		btn.text = "Getting..."
		btn.disabled = true
	else:
		btn.text = "Get"
		btn.disabled = state["busy"]
		style_primary_button(btn)

func _get_pack(state: Dictionary, summary: Dictionary, btn: Button) -> void:
	await _import_pack(state, str(summary["manifest_url"]), str(summary["slug"]),
			"Getting \"" + str(summary["name"]) + "\"...", btn)

func _add_pasted_pack(state: Dictionary) -> void:
	var text := (state["paste"] as LineEdit).text.strip_edges()
	if text.is_empty():
		return
	if not await _import_pack(state, text, "", "Getting the pack...", null):
		return
	# The box stays editable during the Get; a link typed meanwhile is kept.
	var paste: Variant = state["paste"]
	var now: String = paste.text if is_instance_valid(paste) else state["paste_text"]
	if now.strip_edges() == text:
		state["paste_text"] = ""
		if is_instance_valid(paste):
			paste.text = ""

# Row Gets, a detail's Get and the paste Get share one busy flag; btn is the Get pressed.
func _import_pack(state: Dictionary, link: String, slug: String, busy_text: String, btn: Variant) -> bool:
	if state["busy"]:
		return false
	state["busy"] = true
	state["busy_slug"] = slug
	_paint_import(state)
	_set_status(state, busy_text, COL_TEXT_DIM, btn)
	# A launcher closed during a rate wait asks nothing and reports nothing.
	var r := {"ok": false, "error": ""}
	if await _wait_cooldown(state, HOST_VOSTOKMODS, btn, busy_text):
		r = await _hosted_pack_from_link(link)
	state["busy"] = false
	state["busy_slug"] = ""
	if r["ok"]:
		_modpack_entries = collect_modpack_metadata()
		_set_status(state, "Added \"" + str(r["name"]) + "\" to Your packs; Apply it on the Modpacks tab.", COL_OK, btn)
	elif r["error"] != "":
		_set_status(state, str(r["error"]), COL_ERR, btn)
	_paint_import(state)
	return r["ok"]

# Every Get on screen, a detail dialog's included, and the paste Get follow the busy flag.
func _paint_import(state: Dictionary) -> void:
	var get_btns: Dictionary = state["get_btns"]
	for s in get_btns:
		if is_instance_valid(get_btns[s]):
			_paint_get(get_btns[s], s, state)
	state["detail_gets"] = (state["detail_gets"] as Array).filter(func(p: Array): return is_instance_valid(p[0]))
	for p: Array in state["detail_gets"]:
		_paint_get(p[0], p[1], state)
	if is_instance_valid(state["add_btn"]):
		(state["add_btn"] as Button).disabled = state["busy"]
