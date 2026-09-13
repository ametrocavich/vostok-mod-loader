
# ----- Browse: source-neutral helpers ---------------------------------------

# Installed mods keyed by host_ref_key. Last wins on duplicates.
func _browse_install_map() -> Dictionary:
	var out: Dictionary = {}
	var persisted: Dictionary = _get_persisted_mod_sources()
	for entry in _ui_mod_entries:
		var key := host_ref_key(_entry_host_ref(entry, persisted))
		if key != "":
			out[key] = entry
	return out


# Counter off a ModSummary that may have been through a JSON round trip (ints come back as floats).
func _browse_metric(row: Dictionary, key: String) -> int:
	var v: Variant = row.get(key, -1)
	if v is int:
		return v
	if v is float:
		return int(v)
	return -1


# Offline grace for the Browse landing, per host: the last fully populated
# landing, in memory and on disk, so a first launch offline still shows
# something. Lives under user://mws_cache/, deny-listed for pack overrides.
var _browse_landing_snapshots: Dictionary = {}
const _BROWSE_LANDING_CACHE_DIR := "user://mws_cache"

func _browse_landing_snapshot_path(provider: String) -> String:
	return _BROWSE_LANDING_CACHE_DIR.path_join("landing_" + provider.validate_filename() + ".json")

func _browse_landing_snapshot_store(provider: String, sections: Array) -> void:
	# A landing served from the list cache is not a refresh; do not restamp it.
	var prev_v: Variant = _browse_landing_snapshots.get(provider)
	if prev_v is Dictionary and JSON.stringify((prev_v as Dictionary).get("sections")) == JSON.stringify(sections):
		return
	var snap := {"sections": sections, "saved_at_unix": int(Time.get_unix_time_from_system())}
	_browse_landing_snapshots[provider] = snap
	DirAccess.make_dir_recursive_absolute(_BROWSE_LANDING_CACHE_DIR)
	var path := _browse_landing_snapshot_path(provider)
	# Write-then-rename so a crash mid-write cannot truncate the live copy.
	var tmp := path + ".tmp"
	var f := FileAccess.open(tmp, FileAccess.WRITE)
	if f == null:
		return
	var wrote := f.store_string(JSON.stringify(snap))
	var werr := f.get_error()
	f.close()
	if not wrote or werr != OK:
		DirAccess.remove_absolute(tmp)
		return
	DirAccess.rename_absolute(tmp, path)

func _browse_landing_snapshot(provider: String) -> Dictionary:
	if _browse_landing_snapshots.has(provider):
		return _browse_landing_snapshots[provider]
	var path := _browse_landing_snapshot_path(provider)
	if not FileAccess.file_exists(path):
		return {}
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return {}
	var parsed: Variant = JSON.parse_string(f.get_as_text())
	f.close()
	if not (parsed is Dictionary):
		return {}
	var snap: Dictionary = parsed
	if not (snap.get("sections") is Array):
		return {}
	var saved_v: Variant = snap.get("saved_at_unix", 0)
	if not (saved_v is int or saved_v is float) or int(saved_v) <= 0:
		return {}
	# A row from an older build that lacks a field is dropped, not crashed on.
	var sections: Array = []
	for sec_v in (snap["sections"] as Array):
		if not (sec_v is Dictionary):
			continue
		var sec: Dictionary = sec_v
		var rows_v: Variant = sec.get("rows")
		if not (rows_v is Array):
			continue
		var rows: Array = []
		for row_v in (rows_v as Array):
			if row_v is Dictionary and _mods_meta_record_complete(row_v):
				rows.append(row_v)
		sections.append({"title": str(sec.get("title", "")), "rows": rows})
	snap["sections"] = sections
	_browse_landing_snapshots[provider] = snap
	return snap


func build_browse_tab(tabs: TabContainer) -> Control:
	var margin := _make_tab_margin()

	var container := VBoxContainer.new()
	container.add_theme_constant_override("separation", SP_M)
	margin.add_child(container)

	# Shared mutable state: lambdas capture locals by value, so the closures
	# below read and write through this Dictionary. Per-host view records live
	# under "views", so a sort or category chosen on one host cannot leak.
	var providers: PackedStringArray = host_browse_providers()
	# Open on the source used last time; the first browsable host otherwise.
	var initial_provider := providers[0] if providers.size() > 0 else HOST_MODWORKSHOP
	var remembered := str(_get_ui_cfg_value("settings", "browse_source", ""))
	if providers.has(remembered):
		initial_provider = remembered
	var state := {
		"provider": initial_provider,
		"views": {},
		# Monotonic per fetch; a completion whose seq is stale must not render.
		"fetch_seq": 0,
		# host_ref_key of the download in flight; downloads run one at a time.
		"downloading_key": "",
		"download_queue": [],
		"queue_failures": [],
		"queue_done_total": 0,
		"queue_any_success": false,
	}

	var make_view := func(provider: String) -> Dictionary:
		var sorts: Array = host_sorts(provider)
		var first: Dictionary = sorts[0] if not sorts.is_empty() else {}
		var has_sections := not host_sections(provider).is_empty()
		return {
			"mode": "discover" if has_sections else "filter",
			"query": "",
			"sort_key": str(first.get("key", "")),
			"sort_field": str(first.get("row_field", "")),
			"sort_label": str(first.get("label", "")),
			# true while the sort menu rests on the curated landing item.
			"featured": has_sections,
			"category_ref": "",
			"category_name": "",
			"cursor": "",
			"has_more": false,
			"loaded_rows": [],
			"shown_count": 0,
			"categories_loaded": false,
			"categories_loading": false,
		}
	var view := func() -> Dictionary:
		var p := str(state["provider"])
		var views: Dictionary = state["views"]
		if not views.has(p):
			views[p] = make_view.call(p)
		return views[p]

	# -- Toolbar: source, search, sort, category --
	var toolbar := HBoxContainer.new()
	toolbar.add_theme_constant_override("separation", SP_M)
	container.add_child(toolbar)

	# The source switcher scopes everything to its right. Built from
	# host_browse_providers(): a link-out host must not appear in a listing control.
	var provider_dropdown := OptionButton.new()
	for p in providers:
		provider_dropdown.add_item(host_display_name(p))
		provider_dropdown.set_item_metadata(provider_dropdown.item_count - 1, p)
		if p == initial_provider:
			provider_dropdown.select(provider_dropdown.item_count - 1)
	provider_dropdown.visible = providers.size() > 1
	provider_dropdown.custom_minimum_size.y = CTRL_H
	toolbar.add_child(provider_dropdown)
	_wire_hint(provider_dropdown, "Which mod site to browse.")

	var search_input := LineEdit.new()
	search_input.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	search_input.custom_minimum_size.x = 200
	search_input.custom_minimum_size.y = CTRL_H
	toolbar.add_child(search_input)

	var sort_dropdown := OptionButton.new()
	toolbar.add_child(sort_dropdown)

	var category_dropdown := OptionButton.new()
	category_dropdown.add_item("All categories")
	category_dropdown.set_item_metadata(0, "")
	toolbar.add_child(category_dropdown)

	# OptionButton popups are sub-Windows: raise them above the always_on_top
	# launcher and set the theme explicitly. Unfolded because iterating an Array
	# literal makes the loop variable untyped and get_popup() fails inference.
	var provider_popup := provider_dropdown.get_popup()
	provider_popup.always_on_top = true
	provider_popup.transient = true
	if _ui_window != null and _ui_window.theme != null:
		provider_popup.theme = _ui_window.theme

	var sort_popup := sort_dropdown.get_popup()
	sort_popup.always_on_top = true
	sort_popup.transient = true
	if _ui_window != null and _ui_window.theme != null:
		sort_popup.theme = _ui_window.theme

	var cat_popup := category_dropdown.get_popup()
	cat_popup.always_on_top = true
	cat_popup.transient = true
	if _ui_window != null and _ui_window.theme != null:
		cat_popup.theme = _ui_window.theme

	# Controls are built once; switching hosts toggles visibility and repopulates
	# items. Capabilities that are off hide their control rather than disable it.
	var apply_provider_controls := func(provider: String):
		var caps: Dictionary = host_caps(provider)
		var v: Dictionary = view.call()
		search_input.visible = bool(caps["search"])
		search_input.max_length = host_limit(provider, "query_max_len", 150)
		search_input.placeholder_text = "Search " + host_display_name(provider) + "..."
		search_input.text = str(v["query"])
		sort_dropdown.clear()
		var has_sections := not host_sections(provider).is_empty()
		if has_sections:
			# Item 0 is the curated landing, not a sort; its metadata key is "".
			sort_dropdown.add_item("Featured")
			sort_dropdown.set_item_metadata(0, {"key": "", "row_field": "", "label": ""})
		for opt_v in host_sorts(provider):
			var opt: Dictionary = opt_v
			sort_dropdown.add_item(str(opt.get("label", "")))
			sort_dropdown.set_item_metadata(sort_dropdown.item_count - 1, opt)
		sort_dropdown.visible = sort_dropdown.item_count > 0
		var sel := 0
		if not bool(v["featured"]):
			for i in sort_dropdown.item_count:
				var md: Variant = sort_dropdown.get_item_metadata(i)
				if md is Dictionary and str((md as Dictionary).get("key", "")) != "" \
						and str((md as Dictionary).get("key", "")) == str(v["sort_key"]):
					sel = i
					break
		if sort_dropdown.item_count > 0:
			sort_dropdown.select(sel)
		category_dropdown.clear()
		category_dropdown.add_item("All categories")
		category_dropdown.set_item_metadata(0, "")
		category_dropdown.visible = bool(caps["categories"])

	container.add_child(HSeparator.new())

	# Offline-grace banner slot, a sibling above the list so it never covers rows.
	var banner_slot := VBoxContainer.new()
	banner_slot.visible = false
	container.add_child(banner_slot)

	var status_lbl := Label.new()
	status_lbl.add_theme_font_size_override("font_size", FS_BODY)
	status_lbl.add_theme_color_override("font_color", COL_TEXT_DIM)
	container.add_child(status_lbl)

	# Every Browse state change routes through here so color matches message.
	var set_status := func(text: String, color: Color):
		if not is_instance_valid(status_lbl):
			return
		status_lbl.text = text
		status_lbl.add_theme_color_override("font_color", color)

	# Mirror of set_status for downloads started from the detail dialog, which
	# covers the tab's status label (meta "browse_dialog_status" on the button).
	var set_dl_status := func(get_btn: Variant, text: String, color: Color):
		if not is_instance_valid(get_btn):
			return
		var btn := get_btn as Button
		if btn == null or not btn.has_meta("browse_dialog_status"):
			return
		var lbl_v: Variant = btn.get_meta("browse_dialog_status")
		if is_instance_valid(lbl_v) and lbl_v is Label:
			var lbl := lbl_v as Label
			lbl.visible = true
			lbl.text = text
			lbl.tooltip_text = text
			lbl.add_theme_color_override("font_color", color)

	var cooldown_seconds := func(provider: String) -> int:
		return host_rate_cooldown_seconds(provider)

	# Failure reason for the banner: the cooldown owns the copy while armed.
	var browse_fail_reason := func() -> String:
		var p := str(state["provider"])
		var secs: int = cooldown_seconds.call(p)
		if secs > 0:
			return "%s rate limit reached. Try again in %ds." % [host_display_name(p), secs]
		return host_display_name(p) + " is unreachable."

	var clear_browse_banner := func():
		if not is_instance_valid(banner_slot):
			return
		for child in banner_slot.get_children():
			child.queue_free()
		banner_slot.visible = false

	# Banner with a Retry action. Retry goes through `state` because this lambda
	# is created before the fetch lambdas are assigned.
	var show_browse_banner := func(text: String, saved_at_unix: int, edge_color: Color):
		if not is_instance_valid(banner_slot):
			return
		for child in banner_slot.get_children():
			child.queue_free()
		var banner := _make_banner(text, edge_color)
		var banner_row: HBoxContainer = banner["row"]
		if saved_at_unix > 0:
			var age_lbl := Label.new()
			age_lbl.text = "Last refreshed " + _format_age(saved_at_unix)
			age_lbl.add_theme_font_size_override("font_size", FS_META)
			age_lbl.add_theme_color_override("font_color", COL_TEXT_DIM)
			banner_row.add_child(age_lbl)
		var retry_btn := Button.new()
		retry_btn.text = "Retry"
		banner_row.add_child(retry_btn)
		retry_btn.pressed.connect(func():
			(state["fn_populate_categories"] as Callable).call()
			(state["fn_route"] as Callable).call()
		)
		banner_slot.add_child(banner["panel"])
		banner_slot.visible = true

	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	container.add_child(scroll)

	# Right margin clears the overlay scrollbar, which would hide each row's right edge.
	var list_wrap := MarginContainer.new()
	list_wrap.add_theme_constant_override("margin_right", SP_XL)
	list_wrap.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(list_wrap)

	var list := VBoxContainer.new()
	list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	list_wrap.add_child(list)

	var load_more_btn := Button.new()
	load_more_btn.text = "Load more"
	load_more_btn.visible = false
	container.add_child(load_more_btn)

	# Empty the list the moment the view changes, or the previous host's rows
	# sit under a toolbar that says otherwise until the fetch renders. Search
	# text is the exception: results stay while typing.
	var clear_list_now := func(label: String):
		if not is_instance_valid(list):
			return
		for child in list.get_children():
			child.queue_free()
		load_more_btn.visible = false
		set_status.call(label, COL_TEXT_DIM)

	# Enable/disable toggle from a Browse row; mutates the live entry, saves, rebuilds Mods.
	var on_toggle := func(ref_key: String, enabled: bool, check: CheckBox):
		var entry_v: Variant = _browse_install_map().get(ref_key)
		if not (entry_v is Dictionary):
			return
		var entry: Dictionary = entry_v
		# Content mods need the save-compatibility confirm; revert the box on cancel.
		var live_entry: Dictionary = entry
		if not enabled and bool(entry.get("has_registry", false)):
			var ok: bool = await _confirm_disable_content_mod(str(entry.get("mod_name", "this mod")))
			if not ok:
				if is_instance_valid(check):
					check.set_pressed_no_signal(true)
				return
			# A rescan during the dialog replaces _ui_mod_entries; write to the live entry.
			live_entry = _live_entry_for_profile_key(str(entry.get("profile_key", "")), entry)
		live_entry["enabled"] = enabled
		_save_ui_config()
		if is_instance_valid(tabs):
			_rebuild_mods_tab(tabs)
		set_status.call(("Enabled " if enabled else "Disabled ") + str(live_entry.get("mod_name", "?")) + " in profile " + _active_profile, COL_TEXT_DIM)

	var perform_download_for_item: Callable
	perform_download_for_item = func(item: Dictionary):
		var mod_data: Dictionary = item["mod_data"]
		var get_btn = item.get("get_btn")
		var ref: Dictionary = mod_data["ref"]
		var provider := str(ref["provider"])
		var host := host_display_name(provider)
		var key := host_ref_key(ref)
		state["downloading_key"] = key
		if is_instance_valid(get_btn):
			get_btn.disabled = true
			get_btn.text = "Downloading..."
		var queue: Array = state["download_queue"]
		var qsuffix := (" (" + str(queue.size()) + " queued)") if not queue.is_empty() else ""
		set_status.call("Downloading " + str(mod_data["name"]) + qsuffix + "...", COL_ACCENT)
		set_dl_status.call(get_btn, "Downloading " + str(mod_data["name"]) + "...", COL_ACCENT)

		# Rate-limit pause: once a 429 arms the cooldown every queued item would
		# fail fast. Wait it out with a countdown; bail if the launcher closes.
		var rate_waited := false
		while int(cooldown_seconds.call(provider)) > 0:
			rate_waited = true
			if not is_instance_valid(status_lbl) or get_tree() == null:
				state["downloading_key"] = ""
				return
			var wait_s: int = cooldown_seconds.call(provider)
			set_status.call("Rate limited by %s -- resuming in %ds" % [host, wait_s], COL_ACCENT)
			set_dl_status.call(get_btn, "Rate limited by %s -- resuming in %ds" % [host, wait_s], COL_ACCENT)
			await get_tree().create_timer(1.0).timeout
		if rate_waited and is_instance_valid(status_lbl):
			set_status.call("Downloading " + str(mod_data["name"]) + "...", COL_ACCENT)
			set_dl_status.call(get_btn, "Downloading " + str(mod_data["name"]) + "...", COL_ACCENT)

		var result: Dictionary = await download_mod_from_ref(ref)
		state["downloading_key"] = ""

		# The launcher can close during a download; the file is on disk, so stop touching nodes.
		if not is_instance_valid(status_lbl):
			return

		state["queue_done_total"] = int(state.get("queue_done_total", 0)) + 1

		if bool(result.get("ok", false)):
			state["queue_any_success"] = true
			if is_instance_valid(get_btn):
				get_btn.text = "Installed"
				get_btn.disabled = true
			set_status.call("Installed " + str(result.get("file_name", "")), COL_OK)
			set_dl_status.call(get_btn, "Installed " + str(result.get("file_name", "")), COL_OK)
		else:
			if is_instance_valid(get_btn):
				get_btn.disabled = false
				get_btn.text = "Download"
			var err_detail := str(result.get("error", "")).strip_edges()
			if err_detail.is_empty():
				err_detail = "Check your connection and try again."
			var fail_line := "Could not download " + str(mod_data["name"]) + ". " + err_detail
			set_status.call(fail_line, COL_ERR)
			set_dl_status.call(get_btn, fail_line, COL_ERR)
			# The status line is overwritten as the queue drains; the batch summary is the report.
			(state["queue_failures"] as Array).append(str(mod_data["name"]) + " (" + err_detail + ")")

		# Drain the queue before re-rendering, which frees the queued button refs.
		var remaining: Array = state["download_queue"]
		if not remaining.is_empty():
			var next_item: Dictionary = remaining.pop_front()
			(state["fn_perform_download"] as Callable).call(next_item)
			return

		var any_success := bool(state.get("queue_any_success", false))
		var failures: Array = state["queue_failures"]
		var batch_total := int(state.get("queue_done_total", 0))
		state["queue_any_success"] = false
		state["queue_failures"] = []
		state["queue_done_total"] = 0

		# One rescan + Mods-tab rebuild for the whole batch.
		if any_success:
			_reload_entries_for_active_profile()
			if is_instance_valid(tabs):
				_rebuild_mods_tab(tabs)

		if failures.is_empty():
			if any_success:
				# Re-render so duplicate rows flip to Installed, keeping the scroll position.
				if is_instance_valid(scroll):
					state["restore_scroll"] = int(scroll.scroll_vertical)
				(state["fn_route"] as Callable).call()
			return

		# At least one failure: keep the report on screen, sync rows in place.
		if any_success and is_instance_valid(scroll):
			_refresh_browse_installed_rows(scroll)
		if batch_total > 1:
			var fail_strs := PackedStringArray()
			for f_v in failures:
				fail_strs.append(str(f_v))
			set_status.call("%d of %d downloads failed: %s" % [failures.size(), batch_total, ", ".join(fail_strs)], COL_ERR)

	var on_get: Callable
	on_get = func(mod_data: Dictionary, get_btn: Button):
		var key := host_ref_key(mod_data["ref"])
		if str(state["downloading_key"]) != "":
			if str(state["downloading_key"]) == key:
				set_status.call("Already downloading this mod", COL_TEXT_DIM)
				set_dl_status.call(get_btn, "Already downloading this mod", COL_TEXT_DIM)
				return
			var queue: Array = state["download_queue"]
			for q_v in queue:
				var q_data: Dictionary = (q_v as Dictionary).get("mod_data", {})
				if q_data.has("ref") and host_ref_key(q_data["ref"]) == key:
					set_status.call("Already queued", COL_TEXT_DIM)
					set_dl_status.call(get_btn, "Already queued", COL_TEXT_DIM)
					return
			queue.append({"mod_data": mod_data, "get_btn": get_btn})
			if is_instance_valid(get_btn):
				get_btn.disabled = true
				get_btn.text = "Queued"
			var queued_line := "Queued " + str(mod_data["name"]) + " (" + str(queue.size()) + " in queue)"
			set_status.call(queued_line, COL_TEXT_DIM)
			set_dl_status.call(get_btn, queued_line, COL_TEXT_DIM)
			return
		perform_download_for_item.call({"mod_data": mod_data, "get_btn": get_btn})

	# Empty-state copy points at the other source so a thin catalog does not read as broken.
	var empty_copy := func() -> String:
		var v: Dictionary = view.call()
		if str(v["query"]) != "" or str(v["category_ref"]) != "":
			return "No results. Try a different search or category."
		var p := str(state["provider"])
		if providers.size() > 1:
			var other := ""
			for q in providers:
				if q != p:
					other = host_display_name(q)
					break
			return "No mods on %s yet. Pick %s in the source menu to browse there." % [host_display_name(p), other]
		return "No mods on " + host_display_name(p) + " yet."

	var render_mod_rows := func(rows: Array, append: bool):
		var v: Dictionary = view.call()
		if not append:
			for child in list.get_children():
				child.queue_free()
			var hdr := Label.new()
			# Every filtered list is sorted by sort_key; the header names that sort.
			var sort_label := str(v["sort_label"]) if sort_dropdown.visible else ""
			hdr.text = _browse_results_header_text(str(v["query"]), sort_label, str(v["category_name"]))
			hdr.add_theme_font_size_override("font_size", FS_HEAD)
			hdr.add_theme_color_override("font_color", COL_TEXT)
			hdr.clip_text = true
			hdr.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
			hdr.tooltip_text = hdr.text
			hdr.mouse_filter = Control.MOUSE_FILTER_PASS
			list.add_child(hdr)
			list.add_child(HSeparator.new())
		var install_map: Dictionary = _browse_install_map()
		for row_v in rows:
			if not (row_v is Dictionary):
				continue
			var row: Dictionary = row_v
			list.add_child(_browse_render_mod_row(row, install_map.get(host_ref_key(row["ref"])), on_get, on_toggle))
			list.add_child(HSeparator.new())

	var do_discover_fetch: Callable
	var do_filter_fetch: Callable

	# The curated landing: one list query per section the host declares.
	# Hosts without sections never come here.
	do_discover_fetch = func():
		var provider := str(state["provider"])
		var v: Dictionary = view.call()
		var sections: Array = host_sections(provider)
		if sections.is_empty():
			(state["fn_filter_fetch"] as Callable).call(false)
			return
		state["fetch_seq"] = int(state["fetch_seq"]) + 1
		var my_seq := int(state["fetch_seq"])
		var my_restore := -1
		if state.has("restore_scroll"):
			my_restore = int(state["restore_scroll"])
			state.erase("restore_scroll")
		v["mode"] = "discover"
		v["featured"] = true
		if sort_dropdown.visible and sort_dropdown.selected != 0:
			sort_dropdown.select(0)
		v["cursor"] = ""
		v["has_more"] = false
		v["loaded_rows"] = []
		load_more_btn.visible = false
		load_more_btn.disabled = true
		set_status.call("Loading...", COL_TEXT_DIM)

		var results: Array = []
		var ok_count := 0
		for sec_v in sections:
			var sec: Dictionary = sec_v
			var limit := int(sec.get("limit", 10))
			var res := await host_list_mods(provider, {"sort_key": str(sec.get("sort_key", "")), "cursor": "", "limit": limit})
			if int(state["fetch_seq"]) != my_seq:
				return
			if not res["ok"]:
				continue
			ok_count += 1
			var rows: Array = (res["data"] as Dictionary)["rows"]
			if limit > 0 and rows.size() > limit:
				rows = rows.slice(0, limit)
			results.append({"title": str(sec.get("title", "")), "rows": rows})
		if not is_instance_valid(status_lbl):
			return

		var cached_at := 0
		if ok_count == 0:
			var snap := _browse_landing_snapshot(provider)
			if snap.is_empty():
				set_status.call(host_display_name(provider) + ": could not load mods. Check your connection and try again.", COL_ERR)
				show_browse_banner.call(browse_fail_reason.call(), 0, COL_ERR)
				return
			results = snap["sections"]
			cached_at = int(snap["saved_at_unix"])
		elif ok_count == sections.size():
			# Only a complete landing is worth remembering.
			_browse_landing_snapshot_store(provider, results)

		for child in list.get_children():
			child.queue_free()
		var install_map: Dictionary = _browse_install_map()
		var total := 0
		var first_section := true
		for sec_v in results:
			var sec: Dictionary = sec_v
			var rows: Array = sec.get("rows", [])
			if rows.is_empty():
				continue
			if not first_section:
				var spacer := Control.new()
				spacer.custom_minimum_size.y = SP_M
				list.add_child(spacer)
			first_section = false
			var hdr := Label.new()
			hdr.text = str(sec.get("title", ""))
			hdr.add_theme_font_size_override("font_size", FS_HEAD)
			hdr.add_theme_color_override("font_color", COL_TEXT)
			list.add_child(hdr)
			list.add_child(HSeparator.new())
			for row_v in rows:
				if not (row_v is Dictionary):
					continue
				var row: Dictionary = row_v
				list.add_child(_browse_render_mod_row(row, install_map.get(host_ref_key(row["ref"])), on_get, on_toggle))
				list.add_child(HSeparator.new())
				total += 1
		if cached_at > 0:
			show_browse_banner.call("Showing cached results. " + str(browse_fail_reason.call()), cached_at, COL_ACCENT)
		else:
			clear_browse_banner.call()
			# A live fetch proves connectivity: recover a category menu that failed to populate.
			(state["fn_populate_categories"] as Callable).call()
		if total == 0:
			set_status.call(empty_copy.call(), COL_TEXT_DIM)
		else:
			set_status.call("%d mods" % total, COL_TEXT_DIM)
		if my_restore >= 0:
			await get_tree().process_frame
			if int(state["fetch_seq"]) == my_seq and is_instance_valid(scroll):
				scroll.scroll_vertical = my_restore

	do_filter_fetch = func(append: bool):
		var provider := str(state["provider"])
		var caps: Dictionary = host_caps(provider)
		var v: Dictionary = view.call()
		state["fetch_seq"] = int(state["fetch_seq"]) + 1
		var my_seq := int(state["fetch_seq"])
		var my_restore := -1
		if state.has("restore_scroll"):
			my_restore = int(state["restore_scroll"])
			state.erase("restore_scroll")
		v["mode"] = "filter"
		var cursor := str(v["cursor"]) if append else ""
		if not append:
			v["cursor"] = ""
			v["has_more"] = false
			load_more_btn.visible = false
		load_more_btn.disabled = true
		set_status.call("Loading..." if not append else "Loading more...", COL_TEXT_DIM)

		var res := await host_list_mods(provider, {
			"query": str(v["query"]),
			"sort_key": str(v["sort_key"]),
			"category_ref": str(v["category_ref"]),
			"cursor": cursor,
		})
		if int(state["fetch_seq"]) != my_seq:
			return
		if not is_instance_valid(status_lbl):
			return
		if not res["ok"]:
			set_status.call(host_error_message(provider, res), COL_ERR)
			# Only the landing has an offline snapshot; a failed search gets the Retry
			# banner. Append failures keep the rendered pages; Load more is the retry.
			if not append:
				show_browse_banner.call(browse_fail_reason.call(), 0, COL_ERR)
			load_more_btn.disabled = not bool(v["has_more"])
			return
		var page: Dictionary = res["data"]
		var rows: Array = page["rows"]
		# Accumulate every page so the sort runs on the full set; dedup by ref.
		if append:
			var acc: Array = v["loaded_rows"]
			var seen := {}
			for r in acc:
				seen[host_ref_key((r as Dictionary)["ref"])] = true
			for r in rows:
				if not seen.has(host_ref_key((r as Dictionary)["ref"])):
					acc.append(r)
			rows = acc
		v["loaded_rows"] = rows
		# Some hosts ignore `sort` with a query; re-sort client-side on the adapter's field.
		if bool(caps["sort_ignored_with_query"]) and str(v["query"]) != "" and str(v["sort_field"]) != "":
			var field := str(v["sort_field"])
			rows.sort_custom(func(a, b):
				var av: Variant = (a as Dictionary).get(field)
				var bv: Variant = (b as Dictionary).get(field)
				if (av is int or av is float) and (bv is int or bv is float):
					return int(av) > int(bv)
				return str(av) > str(bv)
			)
		v["cursor"] = str(page["next_cursor"])
		v["has_more"] = bool(page["has_more"])
		clear_browse_banner.call()
		(state["fn_populate_categories"] as Callable).call()
		if append and my_restore < 0 and is_instance_valid(scroll):
			my_restore = int(scroll.scroll_vertical)
		render_mod_rows.call(rows, false)
		# Count from the data: queue_free() is deferred, so freed rows still count this frame.
		v["shown_count"] = rows.size()
		var total := int(page["total"])
		if rows.is_empty():
			set_status.call(empty_copy.call(), COL_TEXT_DIM)
		elif bool(caps["total_count"]) and total >= 0:
			set_status.call("%d of %d mods" % [rows.size(), total], COL_TEXT_DIM)
		else:
			set_status.call("%d mods" % rows.size(), COL_TEXT_DIM)
		load_more_btn.visible = bool(v["has_more"])
		load_more_btn.disabled = not bool(v["has_more"])
		if my_restore >= 0:
			await get_tree().process_frame
			if int(state["fetch_seq"]) == my_seq and is_instance_valid(scroll):
				scroll.scroll_vertical = my_restore

	# One definition of "show the landing or the listing?" for every handler.
	var wants_discover := func() -> bool:
		var v: Dictionary = view.call()
		return str(v["query"]) == "" and str(v["category_ref"]) == "" and bool(v["featured"]) \
				and not host_sections(str(state["provider"])).is_empty()
	var route := func():
		if wants_discover.call():
			(state["fn_discover_fetch"] as Callable).call()
		else:
			(state["fn_filter_fetch"] as Callable).call(false)

	# Debounce: text_changed fires per keystroke; only the timeout queries.
	var search_debounce := Timer.new()
	search_debounce.one_shot = true
	search_debounce.wait_time = 0.3
	container.add_child(search_debounce)
	search_debounce.timeout.connect(func():
		route.call()
	)
	search_input.text_changed.connect(func(new_text: String):
		var v: Dictionary = view.call()
		v["query"] = new_text.strip_edges()
		search_debounce.stop()
		search_debounce.start()
	)
	search_input.text_submitted.connect(func(_t: String):
		search_debounce.stop()
		route.call()
	)

	sort_dropdown.item_selected.connect(func(idx: int):
		var v: Dictionary = view.call()
		var md: Variant = sort_dropdown.get_item_metadata(idx)
		var opt: Dictionary = md if md is Dictionary else {}
		var key := str(opt.get("key", ""))
		v["featured"] = key == ""
		if key != "":
			v["sort_key"] = key
			v["sort_field"] = str(opt.get("row_field", ""))
			v["sort_label"] = str(opt.get("label", ""))
		else:
			# Back on Featured, a typed query sorts by the host's first sort.
			var sorts: Array = host_sorts(str(state["provider"]))
			var first: Dictionary = sorts[0] if not sorts.is_empty() else {}
			v["sort_key"] = str(first.get("key", ""))
			v["sort_field"] = str(first.get("row_field", ""))
			v["sort_label"] = str(first.get("label", ""))
		clear_list_now.call("Loading...")
		route.call()
	)

	category_dropdown.item_selected.connect(func(idx: int):
		var v: Dictionary = view.call()
		var md: Variant = category_dropdown.get_item_metadata(idx)
		v["category_ref"] = str(md) if md != null else ""
		v["category_name"] = category_dropdown.get_item_text(idx) if idx > 0 else ""
		clear_list_now.call("Loading...")
		route.call()
	)

	provider_dropdown.item_selected.connect(func(idx: int):
		var p := str(provider_dropdown.get_item_metadata(idx))
		if p == str(state["provider"]):
			return
		state["provider"] = p
		_set_ui_cfg_value("settings", "browse_source", p)
		var v: Dictionary = view.call()
		# Categories are per host and the menu was just cleared; refetch.
		v["categories_loaded"] = false
		apply_provider_controls.call(p)
		clear_browse_banner.call()
		clear_list_now.call("Loading " + host_display_name(p) + "...")
		(state["fn_populate_categories"] as Callable).call()
		route.call()
	)

	load_more_btn.pressed.connect(func():
		do_filter_fetch.call(true)
	)

	# Category menu, per host. Re-invoked by the banner Retry and every
	# successful list fetch until it lands; the two flags prevent stacking.
	var populate_categories := func():
		var provider := str(state["provider"])
		var v: Dictionary = view.call()
		if not bool(host_caps(provider)["categories"]):
			return
		if bool(v["categories_loaded"]) or bool(v["categories_loading"]):
			return
		v["categories_loading"] = true
		var res := await host_list_categories(provider)
		v["categories_loading"] = false
		if not is_instance_valid(category_dropdown):
			return
		# The user switched hosts mid-flight; these are not the menu's items.
		if str(state["provider"]) != provider:
			return
		if not res["ok"]:
			return
		var cats: Array = res["data"]
		var ids := {}
		for c in cats:
			ids[str((c as Dictionary)["id"])] = true
		category_dropdown.clear()
		category_dropdown.add_item("All categories")
		category_dropdown.set_item_metadata(0, "")
		for c in cats:
			var cd: Dictionary = c
			# A hierarchical host lists only its top level here; a flat host's group
			# names are not ids, so every entry shows.
			if str(cd["parent_id"]) != "" and ids.has(str(cd["parent_id"])):
				continue
			if str(cd["name"]) == "":
				continue
			category_dropdown.add_item(str(cd["name"]))
			var idx := category_dropdown.item_count - 1
			category_dropdown.set_item_metadata(idx, str(cd["id"]))
			if str(cd["id"]) == str(v["category_ref"]):
				category_dropdown.select(idx)
		v["categories_loaded"] = true

	# Bind the forward-referenced lambdas onto `state` for closures created earlier.
	state["fn_perform_download"] = perform_download_for_item
	state["fn_discover_fetch"] = do_discover_fetch
	state["fn_filter_fetch"] = do_filter_fetch
	state["fn_populate_categories"] = populate_categories
	state["fn_route"] = route

	apply_provider_controls.call(str(state["provider"]))
	populate_categories.call()
	route.call()

	return margin


# Refresh the baked-at-render-time state of Browse rows in place, so search
# text, caret, scroll and loaded pages survive. Rows are found through the
# browse_ref_key meta tag set at render time.
func _refresh_browse_installed_rows(root: Node) -> void:
	if root == null or not is_instance_valid(root):
		return
	var by_key: Dictionary = _browse_install_map()
	var stack: Array = [root]
	while not stack.is_empty():
		var node: Node = stack.pop_back()
		for child in node.get_children():
			stack.push_back(child)
		if not node.has_meta("browse_ref_key"):
			continue
		var entry_v: Variant = by_key.get(str(node.get_meta("browse_ref_key")))
		if node is CheckBox:
			var cb := node as CheckBox
			if entry_v is Dictionary:
				cb.disabled = false
				cb.text = "Enabled in " + _active_profile
				cb.tooltip_text = "Toggle this mod in profile: " + _active_profile + "."
				# Display sync, not a user toggle: no signal, no profile save.
				cb.set_pressed_no_signal(bool((entry_v as Dictionary).get("enabled", false)))
			else:
				# Uninstalled behind the tab's back: keep the row, make it inert.
				cb.set_pressed_no_signal(false)
				cb.disabled = true
				cb.text = "Removed"
				cb.tooltip_text = "This mod is no longer installed. Click its name and use Download to install it again."
		elif node is Button and entry_v is Dictionary:
			# A Download button whose mod arrived some other way; skip in-flight buttons.
			var btn := node as Button
			if not btn.disabled:
				btn.text = "Installed"
				btn.disabled = true


# Title for a filtered, searched or category view, so "no results" still says
# what was searched. sort_label "" means the standing "All mods" listing.
func _browse_results_header_text(query: String, sort_label: String, category_name: String) -> String:
	var q := query.strip_edges()
	var head: String = ("Results for \"" + q + "\"") if not q.is_empty() \
			else (sort_label.strip_edges() if not sort_label.strip_edges().is_empty() else "All mods")
	var cat := category_name.strip_edges()
	if not cat.is_empty():
		head += " in " + cat
	return head


# Render one Browse row from a ModSummary; every field is present by contract
# (host_types.gd). The thumbnail loads asynchronously.
func _browse_render_mod_row(summary: Dictionary, install_entry: Variant, on_get: Callable, on_toggle: Callable) -> Control:
	var ref: Dictionary = summary["ref"]
	var provider := str(ref["provider"])
	var caps: Dictionary = host_caps(provider)
	var ref_key := host_ref_key(ref)

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", SP_L)

	# Same cell the Mods tab builds, so a mod with no image reads "no thumbnail".
	var thumb_rect := _make_thumb_cell(row, Vector2(96, 54))
	_browse_load_thumbnail_async(thumb_rect, summary["thumbnail"])

	var info_col := VBoxContainer.new()
	info_col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	info_col.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(info_col)

	# Flat Button, not LinkButton: LinkButton cannot clip, and a long name pushed Download out of view.
	var name_lnk := Button.new()
	name_lnk.flat = true
	name_lnk.text = str(summary["name"])
	name_lnk.clip_text = true
	name_lnk.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	name_lnk.alignment = HORIZONTAL_ALIGNMENT_LEFT
	name_lnk.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	name_lnk.add_theme_font_size_override("font_size", FS_EMPH)
	name_lnk.add_theme_color_override("font_color", COL_TEXT)
	name_lnk.add_theme_color_override("font_hover_color", COL_TEXT_HI)
	name_lnk.tooltip_text = name_lnk.text
	var captured_summary := summary
	name_lnk.pressed.connect(func():
		_show_browse_mod_detail_dialog(captured_summary, on_get)
	)
	info_col.add_child(name_lnk)

	# A metric chip renders only when reported: -1 means not reported, 0 is a real zero.
	var metrics: PackedStringArray = caps["metrics"]
	var meta_parts := PackedStringArray()
	if str(summary["author_name"]) != "":
		meta_parts.append("by " + str(summary["author_name"]))
	if str(summary["version"]) != "":
		meta_parts.append("v" + str(summary["version"]))
	var downloads := _browse_metric(summary, "downloads")
	if metrics.has("downloads") and downloads >= 0:
		meta_parts.append(str(downloads) + " downloads")
	var likes := _browse_metric(summary, "likes")
	if metrics.has("likes") and likes > 0:
		meta_parts.append(str(likes) + " likes")
	var views := _browse_metric(summary, "views")
	if metrics.has("views") and views > 0:
		meta_parts.append(str(views) + " views")
	if str(summary["category_name"]) != "":
		meta_parts.append(str(summary["category_name"]))
	var updated_short := _format_iso_datetime(str(summary["updated_at"]))
	if updated_short != "":
		meta_parts.append("updated " + updated_short)

	var meta_lbl := Label.new()
	meta_lbl.text = " - ".join(meta_parts)
	meta_lbl.add_theme_font_size_override("font_size", FS_META)
	meta_lbl.add_theme_color_override("font_color", COL_TEXT_DIM)
	meta_lbl.clip_text = true
	meta_lbl.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	meta_lbl.tooltip_text = meta_lbl.text
	meta_lbl.mouse_filter = Control.MOUSE_FILTER_PASS
	info_col.add_child(meta_lbl)

	# Installed mods get an enable toggle; others get Download when the host can
	# serve a file, and a quiet label when it cannot, since every other disabled
	# Download here means in flight or installed. default_file_id "" means no clean file yet.
	var can_download := bool(caps["resolve_file"]) \
			and (not bool(caps["lists_downloadable"]) or str(summary["default_file_id"]) != "")
	if install_entry is Dictionary:
		var entry: Dictionary = install_entry as Dictionary
		var enable_check := CheckBox.new()
		enable_check.text = "Enabled in " + _active_profile
		enable_check.button_pressed = bool(entry.get("enabled", false))
		enable_check.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		enable_check.set_meta("browse_ref_key", ref_key)
		var captured_key := ref_key
		var captured_check := enable_check
		enable_check.toggled.connect(func(on: bool):
			on_toggle.call(captured_key, on, captured_check)
		)
		row.add_child(enable_check)
		_wire_hint(enable_check, "Toggle this mod in profile: " + _active_profile + ".")
	elif can_download:
		var get_btn := Button.new()
		get_btn.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		get_btn.text = "Download"
		get_btn.set_meta("browse_ref_key", ref_key)
		var captured := summary
		var captured_btn := get_btn
		get_btn.pressed.connect(func():
			on_get.call(captured, captured_btn)
		)
		row.add_child(get_btn)
		_wire_hint(get_btn, "Download this mod from " + host_display_name(provider) + ".")
	else:
		var no_dl := Label.new()
		no_dl.text = "No file yet" if bool(caps["resolve_file"]) else "Browse only"
		no_dl.add_theme_font_size_override("font_size", FS_META)
		no_dl.add_theme_color_override("font_color", COL_TEXT_DIM)
		no_dl.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		no_dl.mouse_filter = Control.MOUSE_FILTER_PASS
		row.add_child(no_dl)
		if bool(caps["resolve_file"]):
			_wire_hint(no_dl, host_display_name(provider) + " has no downloadable file for this mod yet (it may still be scanning).")
		else:
			_wire_hint(no_dl, host_display_name(provider) + " does not provide downloads through the loader.")

	return row

# Detail modal for a Browse row: opens on the ModSummary and async-loads the
# detail and file history. Get forwards to the rows' on_get callback.
func _show_browse_mod_detail_dialog(summary: Dictionary, on_get: Callable) -> void:
	var ref: Dictionary = summary["ref"]
	var provider := str(ref["provider"])
	var caps: Dictionary = host_caps(provider)
	var ref_key := host_ref_key(ref)

	var d := AcceptDialog.new()
	d.title = str(summary["name"])
	d.ok_button_text = "Close"
	d.min_size = _dialog_fit_size(Vector2i(660, 540))

	# Scroll on top, a download status line pinned below so feedback stays visible.
	var outer := VBoxContainer.new()
	outer.add_theme_constant_override("separation", SP_S)
	d.add_child(outer)

	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size = Vector2(d.min_size - Vector2i(20, 60))
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	outer.add_child(scroll)

	# In-dialog download status: the modal covers the tab's status label;
	# set_dl_status finds this through the Download button's meta.
	var dl_status := Label.new()
	dl_status.visible = false
	dl_status.add_theme_font_size_override("font_size", FS_BODY)
	dl_status.add_theme_color_override("font_color", COL_TEXT_DIM)
	dl_status.clip_text = true
	dl_status.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	dl_status.mouse_filter = Control.MOUSE_FILTER_PASS
	outer.add_child(dl_status)

	var inner_wrap := MarginContainer.new()
	inner_wrap.add_theme_constant_override("margin_right", SP_XL)
	inner_wrap.add_theme_constant_override("margin_left", SP_S)
	inner_wrap.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(inner_wrap)

	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", SP_L)
	box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	inner_wrap.add_child(box)

	# Image band from the thumbnail now; the detail fetch repaints it with the
	# banner. Built only when there is an image.
	var banner_rect: TextureRect = null
	var thumb: Dictionary = summary["thumbnail"]
	if str(thumb["url"]) != "":
		banner_rect = _make_thumb_cell(box, Vector2(0, 220), false)
		_browse_load_thumbnail_async(banner_rect, thumb)

	var metrics: PackedStringArray = caps["metrics"]
	var meta := Label.new()
	var parts := PackedStringArray()
	if str(summary["author_name"]) != "":
		parts.append("by " + str(summary["author_name"]))
	if str(summary["version"]) != "":
		parts.append("v" + str(summary["version"]))
	var downloads := _browse_metric(summary, "downloads")
	if metrics.has("downloads") and downloads >= 0:
		parts.append(str(downloads) + " downloads")
	var likes := _browse_metric(summary, "likes")
	if metrics.has("likes") and likes >= 0:
		parts.append(str(likes) + " likes")
	var views := _browse_metric(summary, "views")
	if metrics.has("views") and views >= 0:
		parts.append(str(views) + " views")
	if str(summary["category_name"]) != "":
		parts.append(str(summary["category_name"]))
	var updated_short := _format_iso_datetime(str(summary["updated_at"]))
	if updated_short != "":
		parts.append("updated " + updated_short)
	meta.text = " - ".join(parts)
	meta.add_theme_font_size_override("font_size", FS_META)
	meta.add_theme_color_override("font_color", COL_TEXT_DIM)
	meta.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(meta)

	var can_download := bool(caps["resolve_file"]) \
			and (not bool(caps["lists_downloadable"]) or str(summary["default_file_id"]) != "")
	if not bool(caps["resolve_file"]):
		var note := Label.new()
		note.text = host_display_name(provider) + " does not provide downloads through the loader."
		note.add_theme_font_size_override("font_size", FS_META)
		note.add_theme_color_override("font_color", COL_TEXT_DIM)
		box.add_child(note)

	# Description: the short text now, the full one once the detail lands. Adapters deliver BBCode.
	var desc_hdr := Label.new()
	desc_hdr.text = "Description"
	desc_hdr.add_theme_font_size_override("font_size", FS_HEAD)
	desc_hdr.add_theme_color_override("font_color", COL_TEXT)
	var desc_rt := RichTextLabel.new()
	desc_rt.bbcode_enabled = true
	desc_rt.fit_content = true
	desc_rt.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	desc_rt.selection_enabled = true
	desc_rt.meta_underlined = true
	desc_rt.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	desc_rt.add_theme_color_override("default_color", COL_TEXT)
	# Links open in the system browser, web schemes only: the URL comes from
	# an untrusted description, and OS.shell_open is ShellExecute on Windows.
	desc_rt.meta_clicked.connect(func(meta_v):
		var u := str(meta_v).strip_edges()
		if u.to_lower().begins_with("http://") or u.to_lower().begins_with("https://"):
			OS.shell_open(u)
	)
	var desc_sep := HSeparator.new()
	var show_description := func(bbcode: String):
		if not is_instance_valid(desc_rt):
			return
		if bbcode.strip_edges().is_empty():
			return
		if desc_rt.get_parent() == null:
			box.add_child(desc_sep)
			box.add_child(desc_hdr)
			box.add_child(desc_rt)
		desc_rt.text = bbcode
	show_description.call(_markdown_to_bbcode(str(summary["short_description"])))

	# Files section only for hosts that expose version history.
	var files_status: Label = null
	var files_list: VBoxContainer = null
	if bool(caps["file_history"]):
		box.add_child(HSeparator.new())
		var files_hdr := Label.new()
		files_hdr.text = "Files"
		files_hdr.add_theme_font_size_override("font_size", FS_HEAD)
		files_hdr.add_theme_color_override("font_color", COL_TEXT)
		box.add_child(files_hdr)
		files_status = Label.new()
		files_status.text = "Loading file list..."
		files_status.add_theme_font_size_override("font_size", FS_BODY)
		files_status.add_theme_color_override("font_color", COL_TEXT_DIM)
		box.add_child(files_status)
		files_list = VBoxContainer.new()
		files_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		box.add_child(files_list)

	# Page and Download sit in the dialog's button bar so they stay visible.
	var page_url := host_mod_page_url(ref)
	if page_url != "":
		var page_btn := d.add_button("Open mod page in browser", false, "")
		page_btn.pressed.connect(func():
			OS.shell_open(page_url)
		)
	var already_installed := _browse_install_map().has(ref_key)
	# A Dictionary slot so the async detail can add the button late (lambdas capture by value).
	var action := {"get_btn": null}
	var add_download_button := func(record: Dictionary):
		var get_btn := d.add_button("Download", true, "")
		style_primary_button(get_btn)
		get_btn.set_meta("browse_dialog_status", dl_status)
		get_btn.pressed.connect(func():
			on_get.call(record, get_btn)
		)
		action["get_btn"] = get_btn
	if already_installed:
		var installed_btn := d.add_button("Installed", true, "")
		installed_btn.disabled = true
	elif can_download:
		add_download_button.call(summary)

	# Async detail: full description, banner, and a Download button when the
	# host now has a file. Any failure leaves the summary view standing.
	var load_detail := func():
		var res := await host_get_mod(ref)
		if not res["ok"]:
			return
		if not is_instance_valid(d):
			return
		var detail: Dictionary = res["data"]
		show_description.call(str(detail["description"]))
		var banner: Dictionary = detail["banner"]
		if str(banner["url"]) != "" and banner_rect != null and is_instance_valid(banner_rect):
			_browse_load_thumbnail_async(banner_rect, banner)
		if action["get_btn"] == null and not already_installed and bool(caps["resolve_file"]) \
				and str(detail["default_file_id"]) != "":
			add_download_button.call(detail)
	load_detail.call()

	var load_files := func():
		if files_status == null:
			return
		var res := await host_list_files(ref)
		if not is_instance_valid(files_status):
			return
		if not res["ok"]:
			files_status.text = host_error_message(provider, res)
			files_status.add_theme_color_override("font_color", COL_ERR)
			return
		var files: Array = res["data"]
		if files.is_empty():
			files_status.text = "No downloadable files yet."
			return
		files_status.queue_free()
		var primary_id := str(summary["default_file_id"])
		for file_v in files:
			var fd: Dictionary = file_v
			var f_row := HBoxContainer.new()
			f_row.add_theme_constant_override("separation", SP_L)
			files_list.add_child(f_row)

			var v_lbl := Label.new()
			var v_str: String = "v" + str(fd["version"])
			if primary_id != "" and str(fd["id"]) == primary_id:
				v_str += " (primary)"
			v_lbl.text = v_str
			v_lbl.custom_minimum_size.x = 140
			v_lbl.clip_text = true
			v_lbl.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
			v_lbl.tooltip_text = v_lbl.text
			v_lbl.mouse_filter = Control.MOUSE_FILTER_PASS
			f_row.add_child(v_lbl)

			var size_lbl := Label.new()
			var size := _browse_metric(fd, "size")
			size_lbl.text = _format_size(size) if size >= 0 else ""
			size_lbl.custom_minimum_size.x = 80
			size_lbl.add_theme_color_override("font_color", COL_TEXT_DIM)
			f_row.add_child(size_lbl)

			var date_str := str(fd["created_at"])
			if date_str.contains("T"):
				date_str = date_str.split("T")[0]
			var date_lbl := Label.new()
			date_lbl.text = date_str
			date_lbl.add_theme_color_override("font_color", COL_TEXT_DIM)
			f_row.add_child(date_lbl)
	load_files.call()

	_attach_ui_dialog(d)
	_wire_accept_dismiss(d)
	d.popup_centered()
