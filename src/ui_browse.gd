# The Browse tab: the Mods/Modpacks switch, per-host listings, offline landing
# snapshots, the mod detail dialog, and the one-at-a-time download queue.

const _BROWSE_META_REF_KEY := "browse_ref_key"
const _BROWSE_META_ON_TOGGLE := "browse_on_toggle"
const _BROWSE_META_DIALOG_STATUS := "browse_dialog_status"
const _BROWSE_META_DL_STATE := "browse_dl_state"

# Installed mods under every ref key they answer to, so a row keyed by a
# Vostok Mods slug finds a mod whose mod.txt carries the UUID.
func _browse_install_map() -> Dictionary:
	var out: Dictionary = {}
	var persisted: Dictionary = _get_persisted_mod_sources()
	for entry in _ui_mod_entries:
		for key in _entry_ref_keys(entry, persisted):
			out[key] = entry
	return out


# The last complete landing per host, in memory and on disk, so a first
# launch offline still shows something.
var _browse_landing_snapshots: Dictionary = {}

func _browse_landing_snapshot_path(provider: String) -> String:
	return UI_CACHE_DIR.path_join("landing_" + provider.validate_filename() + ".json")

func _store_landing(provider: String, sections: Array) -> void:
	# A landing served from the list cache is not a refresh; keep its stamp.
	if _browse_landing_snapshots.has(provider) \
			and JSON.stringify(_browse_landing_snapshots[provider]["sections"]) == JSON.stringify(sections):
		return
	var snap := {"sections": sections, "saved_at_unix": int(Time.get_unix_time_from_system())}
	_browse_landing_snapshots[provider] = snap
	DirAccess.make_dir_recursive_absolute(UI_CACHE_DIR)
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
	# The file may come from an older build: rows missing a field, or the
	# loader's own listing, are dropped.
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
			if row_v is Dictionary and _mods_meta_record_complete(row_v) and not _host_is_own_listing(provider, row_v):
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

	# One shared Dictionary because lambdas capture locals by value. Views are
	# per host, so a sort or category chosen on one host does not leak.
	var providers: PackedStringArray = host_browse_providers()
	var initial_provider := providers[0]
	var remembered := str(_get_ui_cfg_value("settings", "browse_source", ""))
	if providers.has(remembered):
		initial_provider = remembered
	var kind := str(_get_ui_cfg_value("settings", "browse_kind", "mods"))
	if kind != "modpacks":
		kind = "mods"
	var state := {
		"tabs": tabs,
		"providers": providers,
		"provider": initial_provider,
		"views": {},
		"fetch_seq": 0,  # a completion with a stale seq does not render
		"downloading_key": "",  # downloads run one at a time
		"download_queue": [],
		"batch": {"failures": [], "done_total": 0, "any_success": false},
		"packs": _packs_record(),
	}
	state["on_get"] = _on_get.bind(state)
	state["on_toggle"] = _on_toggle.bind(state)
	# The shared pager and banner read these; a missing row_fn means _mod_row.
	state["list_fn"] = func(q: Dictionary) -> Dictionary:
		return await host_list_mods(str(state["provider"]), q)
	state["empty_fn"] = _empty_copy.bind(state)
	state["noun"] = "mods"
	state["retry"] = func():
		_load_categories(state)
		_route(state)

	var toolbar := HBoxContainer.new()
	toolbar.add_theme_constant_override("separation", SP_M)
	container.add_child(toolbar)
	var kinds := ButtonGroup.new()
	var seg := HBoxContainer.new()
	seg.add_theme_constant_override("separation", 0)
	toolbar.add_child(seg)
	var check := _make_check_icon(COL_TEXT_HI)
	for k in [["mods", "Mods", "Browse single mods."], ["modpacks", "Modpacks", "Browse modpacks on Vostok Mods."]]:
		var btn := Button.new()
		btn.text = k[1]
		btn.toggle_mode = true
		btn.button_group = kinds
		btn.button_pressed = k[0] == kind
		btn.icon = check if btn.button_pressed else null
		btn.custom_minimum_size.y = CTRL_H
		style_segment(btn, k[0] == "mods")
		seg.add_child(btn)
		_wire_hint(btn, k[2])
		btn.toggled.connect(func(on: bool):
			btn.icon = check if on else null
			if on:
				_set_ui_cfg_value("settings", "browse_kind", k[0])
				_show_kind(state, k[0])
		)
	state.merge(_browse_build_toolbar(state, toolbar))
	container.add_child(HSeparator.new())
	var mods_area := _kind_area(container)
	state.merge(_browse_build_list_area(mods_area))
	var packs_area := _kind_area(container)
	var packs_group := _build_packs_pane(state["packs"], toolbar, packs_area)
	state["kind_nodes"] = {"mods": [state["mods_group"], mods_area], "modpacks": [packs_group, packs_area]}

	_wire_search(state, container, _route.bind(state))
	(state["sort_dropdown"] as OptionButton).item_selected.connect(_on_sort.bind(state))
	(state["category_dropdown"] as OptionButton).item_selected.connect(_on_category.bind(state))
	(state["provider_dropdown"] as OptionButton).item_selected.connect(_on_provider.bind(state))
	(state["load_more_btn"] as Button).pressed.connect(_fetch_listing.bind(state, true))

	_browse_apply_provider_controls(state, str(state["provider"]))
	_load_categories(state)
	_route(state)
	_show_kind(state, kind)

	return margin


func _kind_area(container: VBoxContainer) -> VBoxContainer:
	var area := VBoxContainer.new()
	area.add_theme_constant_override("separation", SP_M)
	area.size_flags_vertical = Control.SIZE_EXPAND_FILL
	container.add_child(area)
	return area


# Each kind keeps its rows and scroll.
func _show_kind(state: Dictionary, kind: String) -> void:
	var nodes: Dictionary = state["kind_nodes"]
	for k in nodes:
		for n: Control in nodes[k]:
			n.visible = k == kind
	var packs: Dictionary = state["packs"]
	packs["on_screen"] = kind == "modpacks"
	if packs["on_screen"]:
		_fill_packs_pane(packs)


# Browse rows bake profile and pack state when rendered; sync them in place.
func _on_browse_selected(tab: Control) -> void:
	_refresh_browse_installed_rows(tab)
	if not (_packs_state["get_btns"] as Dictionary).is_empty():
		_modpack_entries = collect_modpack_metadata()
		_paint_import(_packs_state)
	if _packs_state["on_screen"]:
		_fill_packs_pane(_packs_state)


# Typing writes the view's query and fires after 0.3 s; Enter fires at once.
func _wire_search(state: Dictionary, holder: Node, on_submit: Callable) -> void:
	var debounce := Timer.new()
	debounce.one_shot = true
	debounce.wait_time = 0.3
	holder.add_child(debounce)
	debounce.timeout.connect(on_submit)
	var search_input: LineEdit = state["search_input"]
	search_input.text_changed.connect(func(new_text: String):
		_browse_view(state)["query"] = new_text.strip_edges()
		debounce.start()
	)
	search_input.text_submitted.connect(func(_t: String):
		debounce.stop()
		on_submit.call()
	)


func _browse_build_toolbar(state: Dictionary, container: Container) -> Dictionary:
	var providers: PackedStringArray = state["providers"]
	var initial_provider := str(state["provider"])
	var toolbar := HBoxContainer.new()
	toolbar.add_theme_constant_override("separation", SP_M)
	toolbar.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	container.add_child(toolbar)

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
	_reset_categories(category_dropdown)
	toolbar.add_child(category_dropdown)

	_style_option_popup(provider_dropdown)
	_style_option_popup(sort_dropdown)
	_style_option_popup(category_dropdown)
	return {
		"mods_group": toolbar,
		"provider_dropdown": provider_dropdown,
		"search_input": search_input,
		"sort_dropdown": sort_dropdown,
		"category_dropdown": category_dropdown,
	}


func _browse_build_list_area(container: VBoxContainer) -> Dictionary:
	var banner_slot := VBoxContainer.new()
	banner_slot.visible = false
	container.add_child(banner_slot)

	var status_lbl := _make_label("", COL_TEXT_DIM, FS_BODY)
	container.add_child(status_lbl)

	var scroll := _make_scroll(container)
	var list := _make_scroll_column(scroll)

	var load_more_btn := Button.new()
	load_more_btn.text = "Load more"
	load_more_btn.visible = false
	container.add_child(load_more_btn)
	return {
		"banner_slot": banner_slot,
		"status_lbl": status_lbl,
		"scroll": scroll,
		"list": list,
		"load_more_btn": load_more_btn,
	}


func _browse_make_view(provider: String) -> Dictionary:
	var has_sections := not host_sections(provider).is_empty()
	var v := {
		"query": "",
		# The sort menu rests on the curated landing; with no query and no
		# category the next fetch goes to the landing.
		"featured": has_sections,
		"category_ref": "",
		"category_name": "",
		"cursor": "",
		"has_more": false,
		"loaded_rows": [],
		"categories_loaded": false,
		"categories_loading": false,
	}
	_set_sort(v, _first_sort(provider))
	return v


func _first_sort(provider: String) -> Dictionary:
	var sorts: Array = host_sorts(provider)
	return sorts[0] if not sorts.is_empty() else {"key": "", "row_field": "", "label": ""}


func _set_sort(v: Dictionary, opt: Dictionary) -> void:
	v["sort_key"] = str(opt["key"])
	v["sort_field"] = str(opt.get("row_field", ""))
	v["sort_label"] = str(opt["label"])


func _browse_view(state: Dictionary) -> Dictionary:
	var p := str(state["provider"])
	var views: Dictionary = state["views"]
	if not views.has(p):
		views[p] = _browse_make_view(p)
	return views[p]


func _browse_apply_provider_controls(state: Dictionary, provider: String) -> void:
	var search_input: LineEdit = state["search_input"]
	var sort_dropdown: OptionButton = state["sort_dropdown"]
	var category_dropdown: OptionButton = state["category_dropdown"]
	var caps: Dictionary = host_caps(provider)
	var v: Dictionary = _browse_view(state)
	search_input.visible = bool(caps["search"])
	search_input.max_length = host_limit(provider, "query_max_len", 150)
	search_input.placeholder_text = "Search " + host_display_name(provider) + "..."
	search_input.text = str(v["query"])
	sort_dropdown.clear()
	if not host_sections(provider).is_empty():
		# Item 0 is the curated landing, not a sort; its key is "".
		sort_dropdown.add_item("Featured")
		sort_dropdown.set_item_metadata(0, {"key": "", "row_field": "", "label": ""})
	for opt in host_sorts(provider):
		sort_dropdown.add_item(str(opt["label"]))
		sort_dropdown.set_item_metadata(sort_dropdown.item_count - 1, opt)
	sort_dropdown.visible = sort_dropdown.item_count > 0
	var sel := 0
	if not bool(v["featured"]):
		for i in sort_dropdown.item_count:
			var key := str(sort_dropdown.get_item_metadata(i)["key"])
			if key != "" and key == str(v["sort_key"]):
				sel = i
				break
	if sort_dropdown.item_count > 0:
		sort_dropdown.select(sel)
	_reset_categories(category_dropdown)
	category_dropdown.visible = bool(caps["categories"])


func _reset_categories(dropdown: OptionButton) -> void:
	dropdown.clear()
	dropdown.add_item("All categories")
	dropdown.set_item_metadata(0, "")


# The tab's widgets are freed with the launcher; code resuming after an await
# checks this first, since a typed read of a freed widget is an engine error.
func _browse_alive(state: Dictionary) -> bool:
	return is_instance_valid(state["list"])


# The tab's status line, and the detail dialog's when get_btn came from there.
func _set_status(state: Dictionary, text: String, color: Color, get_btn: Variant = null) -> void:
	if _browse_alive(state):
		var status_lbl: Label = state["status_lbl"]
		status_lbl.text = text
		status_lbl.add_theme_color_override("font_color", color)
	_set_dl_status(get_btn, text, color)


# The detail dialog covers the tab's status line, so it has its own.
func _set_dl_status(get_btn: Variant, text: String, color: Color) -> void:
	if not is_instance_valid(get_btn) or not get_btn.has_meta(_BROWSE_META_DIALOG_STATUS):
		return
	var lbl: Variant = get_btn.get_meta(_BROWSE_META_DIALOG_STATUS)
	if is_instance_valid(lbl):
		lbl.visible = true
		lbl.text = text
		lbl.tooltip_text = text
		lbl.add_theme_color_override("font_color", color)


func _rate_wait_text(host: String, wait_s: int) -> String:
	return "Rate limited by %s -- resuming in %ds" % [host, wait_s]


func _fail_reason(state: Dictionary) -> String:
	var p := str(state["provider"])
	return host_error_status(p, host_display_name(p) + " is unreachable.")


func _clear_banner(state: Dictionary) -> void:
	if not _browse_alive(state):
		return
	var banner_slot: VBoxContainer = state["banner_slot"]
	_clear_children(banner_slot)
	banner_slot.visible = false


func _show_banner(state: Dictionary, text: String, saved_at_unix: int, edge_color: Color) -> void:
	if not _browse_alive(state):
		return
	_clear_banner(state)
	var banner_slot: VBoxContainer = state["banner_slot"]
	var banner := _make_banner(text, edge_color)
	var banner_row: HBoxContainer = banner["row"]
	if saved_at_unix > 0:
		banner_row.add_child(_make_label("Last refreshed " + _format_age(saved_at_unix), COL_TEXT_DIM, FS_META))
	var retry_btn := Button.new()
	retry_btn.text = "Retry"
	banner_row.add_child(retry_btn)
	retry_btn.pressed.connect(state["retry"])
	banner_slot.add_child(banner["panel"])
	banner_slot.visible = true


# A view change empties the list at once, so the old host's rows never sit
# under the new toolbar. Typing keeps results until the search lands.
func _clear_list(state: Dictionary, label: String) -> void:
	if not _browse_alive(state):
		return
	var load_more_btn: Button = state["load_more_btn"]
	_clear_children(state["list"])
	load_more_btn.visible = false
	_set_status(state, label, COL_TEXT_DIM)


func _on_toggle(ref_key: String, enabled: bool, check: CheckBox, state: Dictionary) -> void:
	var tabs: TabContainer = state["tabs"]
	var install := _browse_install_map()
	if not install.has(ref_key):
		return
	var entry: Dictionary = install[ref_key]
	var live_entry := entry
	if not enabled and bool(entry["has_registry"]):
		var ok: bool = await _confirm_disable_content_mod(str(entry["mod_name"]))
		if not ok:
			if is_instance_valid(check):
				check.set_pressed_no_signal(true)
			return
		# A rescan during the dialog replaces _ui_mod_entries.
		live_entry = _live_entry_for_profile_key(str(entry["profile_key"]), entry)
	live_entry["enabled"] = enabled
	_save_ui_config()
	_rebuild_mods_tab(tabs)
	# The landing can list one mod in two sections.
	if _browse_alive(state):
		_refresh_browse_installed_rows(state["scroll"])
	var verb := "Enabled " if enabled else "Disabled "
	_set_status(state, verb + str(live_entry["mod_name"]) + " in profile " + _active_profile_label(), COL_TEXT_DIM)


func _download_next(state: Dictionary, item: Dictionary) -> void:
	var mod_data: Dictionary = item["mod_data"]
	var get_btn: Variant = item["get_btn"]
	var ref: Dictionary = mod_data["ref"]
	var mod_name := str(mod_data["name"])
	state["downloading_key"] = host_ref_key(ref)
	if is_instance_valid(get_btn):
		get_btn.disabled = true
		get_btn.text = "Downloading..."
		get_btn.set_meta(_BROWSE_META_DL_STATE, "downloading")
	var queue: Array = state["download_queue"]
	var qsuffix := (" (" + str(queue.size()) + " queued)") if not queue.is_empty() else ""
	var busy_text := "Downloading " + mod_name + "..."
	_set_status(state, "Downloading " + mod_name + qsuffix + "...", COL_ACCENT)
	_set_dl_status(get_btn, busy_text, COL_ACCENT)

	var still_open: bool = await _wait_cooldown(state, str(ref["provider"]), get_btn, busy_text)
	if not still_open:
		state["downloading_key"] = ""
		return

	var result: Dictionary = await download_mod_from_ref(ref)
	state["downloading_key"] = ""

	# The launcher closed during the download. The mod list still has to learn
	# about the file, or the next launcher offers it again and refuses it.
	if not _browse_alive(state):
		if result["ok"]:
			_reload_entries_for_active_profile()
			refresh_launch_button_label()
		return

	_paint_result(state, get_btn, mod_name, result)

	# Drain before re-rendering, which frees the queued button refs.
	var remaining: Array = state["download_queue"]
	if not remaining.is_empty():
		_download_next(state, remaining.pop_front())
		return
	_finish_batch(state)


# Once a 429 arms the cooldown every queued item would fail fast, so wait it out.
func _wait_cooldown(state: Dictionary, provider: String, get_btn: Variant, busy_text: String) -> bool:
	var host := host_display_name(provider)
	var rate_waited := false
	while host_rate_cooldown_seconds(provider) > 0:
		rate_waited = true
		if not _browse_alive(state) or get_tree() == null:
			return false
		_set_status(state, _rate_wait_text(host, host_rate_cooldown_seconds(provider)), COL_ACCENT, get_btn)
		await get_tree().create_timer(1.0).timeout
	if rate_waited and _browse_alive(state):
		_set_status(state, busy_text, COL_ACCENT, get_btn)
	return true


func _paint_result(state: Dictionary, get_btn: Variant, mod_name: String, result: Dictionary) -> void:
	var batch: Dictionary = state["batch"]
	batch["done_total"] = int(batch["done_total"]) + 1
	if result["ok"]:
		batch["any_success"] = true
		if is_instance_valid(get_btn):
			get_btn.text = "Installed"
			get_btn.disabled = true
			get_btn.set_meta(_BROWSE_META_DL_STATE, "installed")
		_set_status(state, "Installed " + str(result["file_name"]), COL_OK, get_btn)
		return
	if is_instance_valid(get_btn):
		get_btn.disabled = false
		get_btn.text = "Download"
		get_btn.remove_meta(_BROWSE_META_DL_STATE)
	var err_detail := str(result["error"]).strip_edges()
	if err_detail.is_empty():
		err_detail = "Check your connection and try again."
	_set_status(state, "Could not download " + mod_name + ". " + err_detail, COL_ERR, get_btn)
	# The queue overwrites the status line; the batch summary is the report.
	(batch["failures"] as Array).append(mod_name + " (" + err_detail + ")")


func _finish_batch(state: Dictionary) -> void:
	var tabs: TabContainer = state["tabs"]
	var scroll: ScrollContainer = state["scroll"]
	var batch: Dictionary = state["batch"]
	var any_success := bool(batch["any_success"])
	var failures: Array = batch["failures"]
	var batch_total := int(batch["done_total"])
	batch["any_success"] = false
	batch["failures"] = []
	batch["done_total"] = 0

	if any_success:
		_reload_entries_for_active_profile()
		if is_instance_valid(tabs):
			_rebuild_mods_tab(tabs)

	# Sync rows in place: a refetch would drop the loaded pages and the status.
	if any_success and is_instance_valid(scroll):
		_refresh_browse_installed_rows(scroll)
	if failures.is_empty():
		return
	if batch_total > 1:
		var fail_strs := PackedStringArray()
		for f_v in failures:
			fail_strs.append(str(f_v))
		_set_status(state, "%d of %d downloads failed: %s" % [failures.size(), batch_total, ", ".join(fail_strs)], COL_ERR)


func _on_get(mod_data: Dictionary, get_btn: Button, state: Dictionary) -> void:
	var key := host_ref_key(mod_data["ref"])
	if str(state["downloading_key"]) != "":
		if str(state["downloading_key"]) == key:
			_set_status(state, "Already downloading this mod", COL_TEXT_DIM, get_btn)
			return
		var queue: Array = state["download_queue"]
		for q in queue:
			if host_ref_key(q["mod_data"]["ref"]) == key:
				_set_status(state, "Already queued", COL_TEXT_DIM, get_btn)
				return
		queue.append({"mod_data": mod_data, "get_btn": get_btn})
		get_btn.disabled = true
		get_btn.text = "Queued"
		get_btn.set_meta(_BROWSE_META_DL_STATE, "queued")
		_set_status(state, "Queued " + str(mod_data["name"]) + " (" + str(queue.size()) + " in queue)",
				COL_TEXT_DIM, get_btn)
		return
	_download_next(state, {"mod_data": mod_data, "get_btn": get_btn})


# Point at the other source, so a thin catalog does not read as broken.
func _empty_copy(state: Dictionary) -> String:
	var providers: PackedStringArray = state["providers"]
	var v: Dictionary = _browse_view(state)
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


func _browse_render_rows(state: Dictionary, rows: Array) -> void:
	var sort_dropdown: OptionButton = state["sort_dropdown"]
	var list: VBoxContainer = state["list"]
	var v: Dictionary = _browse_view(state)
	_clear_children(list)
	var sort_label := str(v["sort_label"]).strip_edges() if sort_dropdown.visible else ""
	var q := str(v["query"]).strip_edges()
	var hdr_text: String = ("Results for \"" + q + "\"") if not q.is_empty() \
			else (sort_label if not sort_label.is_empty() else "All " + str(state["noun"]))
	var cat := str(v["category_name"]).strip_edges()
	if not cat.is_empty():
		hdr_text += " in " + cat
	list.add_child(_make_sub_label(hdr_text, COL_TEXT, hdr_text, FS_HEAD))
	list.add_child(HSeparator.new())
	_append_rows(state, rows, _browse_install_map())


# A state without row_fn draws mod rows.
func _append_rows(state: Dictionary, rows: Array, install_map: Dictionary) -> void:
	var list: VBoxContainer = state["list"]
	var row_fn: Callable = state.get("row_fn", _mod_row.bind(state))
	for row in rows:
		list.add_child(row_fn.call(row, install_map))
		list.add_child(HSeparator.new())


func _fetch_landing(state: Dictionary) -> void:
	var sort_dropdown: OptionButton = state["sort_dropdown"]
	var load_more_btn: Button = state["load_more_btn"]
	var provider := str(state["provider"])
	var v: Dictionary = _browse_view(state)
	var sections: Array = host_sections(provider)
	state["fetch_seq"] = int(state["fetch_seq"]) + 1
	var my_seq := int(state["fetch_seq"])
	v["featured"] = true
	if sort_dropdown.visible and sort_dropdown.selected != 0:
		sort_dropdown.select(0)
	v["cursor"] = ""
	v["has_more"] = false
	v["loaded_rows"] = []
	load_more_btn.visible = false
	load_more_btn.disabled = true
	_set_status(state, "Loading...", COL_TEXT_DIM)

	var results: Array = []
	var ok_count := 0
	for sec in sections:
		var limit := int(sec["limit"])
		var res := await host_list_mods(provider, {"sort_key": str(sec["sort_key"]), "cursor": "", "limit": limit})
		if int(state["fetch_seq"]) != my_seq:
			return
		if not res["ok"]:
			continue
		ok_count += 1
		var rows: Array = (res["data"] as Dictionary)["rows"]
		if limit > 0 and rows.size() > limit:
			rows = rows.slice(0, limit)
		results.append({"title": str(sec["title"]), "rows": rows})
	if not _browse_alive(state):
		return

	var cached_at := 0
	if ok_count == 0:
		var snap := _browse_landing_snapshot(provider)
		if snap.is_empty():
			_set_status(state, host_display_name(provider) + ": could not load mods. Check your connection and try again.", COL_ERR)
			_show_banner(state, _fail_reason(state), 0, COL_ERR)
			return
		results = snap["sections"]
		cached_at = int(snap["saved_at_unix"])
	elif ok_count == sections.size():
		_store_landing(provider, results)

	var total := _render_landing(state, results)
	_landing_banner(state, cached_at, ok_count < sections.size())
	if cached_at == 0:
		# A live fetch proves connectivity: retry a category menu that failed.
		_load_categories(state)
	if total == 0:
		_set_status(state, _empty_copy(state), COL_TEXT_DIM)
	else:
		_set_status(state, "%d mods" % total, COL_TEXT_DIM)


func _render_landing(state: Dictionary, results: Array) -> int:
	var list: VBoxContainer = state["list"]
	_clear_children(list)
	var install_map: Dictionary = _browse_install_map()
	var total := 0
	for sec in results:
		var rows: Array = sec["rows"]
		if rows.is_empty():
			continue
		if total > 0:
			var spacer := Control.new()
			spacer.custom_minimum_size.y = SP_M
			list.add_child(spacer)
		list.add_child(_make_head_label(str(sec["title"])))
		list.add_child(HSeparator.new())
		_append_rows(state, rows, install_map)
		total += rows.size()
	return total


func _landing_banner(state: Dictionary, cached_at: int, partial: bool) -> void:
	if cached_at > 0:
		_show_banner(state, "Showing cached results. " + _fail_reason(state), cached_at, COL_WARN)
	elif partial:
		# The host answered, so only a running cooldown is worth naming.
		var text := "Part of this page could not be loaded."
		if host_rate_cooldown_seconds(str(state["provider"])) > 0:
			text += " " + _fail_reason(state)
		_show_banner(state, text, 0, COL_WARN)
	else:
		_clear_banner(state)


func _fetch_listing(state: Dictionary, append: bool) -> void:
	var load_more_btn: Button = state["load_more_btn"]
	var provider := str(state["provider"])
	var caps: Dictionary = host_caps(provider)
	var v: Dictionary = _browse_view(state)
	state["fetch_seq"] = int(state["fetch_seq"]) + 1
	var my_seq := int(state["fetch_seq"])
	var cursor := str(v["cursor"]) if append else ""
	if not append:
		v["cursor"] = ""
		v["has_more"] = false
		load_more_btn.visible = false
	load_more_btn.disabled = true
	_set_status(state, "Loading..." if not append else "Loading more...", COL_TEXT_DIM)

	var res: Dictionary = await (state["list_fn"] as Callable).call({
		"query": str(v["query"]),
		"sort_key": str(v["sort_key"]),
		"category_ref": str(v["category_ref"]),
		"cursor": cursor,
	})
	if int(state["fetch_seq"]) != my_seq:
		return
	if not _browse_alive(state):
		return
	# A rebuild during the await replaced the widgets read above.
	load_more_btn = state["load_more_btn"]
	var scroll: ScrollContainer = state["scroll"]
	if not res["ok"]:
		# Only the landing has a snapshot. A failed page keeps the pages
		# already shown; Load more is its retry. The banner carries the reason.
		if append:
			_set_status(state, host_error_message(provider, res), COL_ERR)
		else:
			_set_status(state, state.get("fail_status", host_error_message(provider, res)), COL_ERR)
			_show_banner(state, _fail_reason(state), 0, COL_ERR)
		load_more_btn.disabled = not bool(v["has_more"])
		return
	var page: Dictionary = res["data"]
	var rows: Array = page["rows"]
	# Keep every page, deduped by ref, so the sort runs on the full set.
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
	# Some hosts ignore the sort when there is a query; sort on the row field.
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
	# A list_fn that fell back to its snapshot stamps the page with cached_at.
	_landing_banner(state, int(page.get("cached_at", 0)), false)
	if state.has("category_dropdown"):
		_load_categories(state)
	# Load more re-renders the whole list; keep the player where they were.
	var my_restore := int(scroll.scroll_vertical) if append else -1
	_browse_render_rows(state, rows)
	var total := int(page["total"])
	var noun := str(state["noun"])
	if rows.is_empty():
		_set_status(state, (state["empty_fn"] as Callable).call(), COL_TEXT_DIM)
	elif bool(caps["total_count"]) and total >= 0:
		_set_status(state, "%d of %d %s" % [rows.size(), total, noun], COL_TEXT_DIM)
	else:
		_set_status(state, "%d %s" % [rows.size(), noun], COL_TEXT_DIM)
	load_more_btn.visible = bool(v["has_more"])
	load_more_btn.disabled = not bool(v["has_more"])
	if my_restore >= 0:
		await get_tree().process_frame
		if int(state["fetch_seq"]) == my_seq and _browse_alive(state):
			(state["scroll"] as ScrollContainer).scroll_vertical = my_restore


func _route(state: Dictionary) -> void:
	var v: Dictionary = _browse_view(state)
	if str(v["query"]) == "" and str(v["category_ref"]) == "" and bool(v["featured"]) \
			and not host_sections(str(state["provider"])).is_empty():
		_fetch_landing(state)
	else:
		_fetch_listing(state, false)


func _on_sort(idx: int, state: Dictionary) -> void:
	var sort_dropdown: OptionButton = state["sort_dropdown"]
	var v: Dictionary = _browse_view(state)
	var opt: Dictionary = sort_dropdown.get_item_metadata(idx)
	var featured := str(opt["key"]) == ""
	v["featured"] = featured
	# Back on Featured, a typed query sorts by the host's first sort.
	_set_sort(v, _first_sort(str(state["provider"])) if featured else opt)
	_clear_list(state, "Loading...")
	_route(state)


func _on_category(idx: int, state: Dictionary) -> void:
	var category_dropdown: OptionButton = state["category_dropdown"]
	var v: Dictionary = _browse_view(state)
	v["category_ref"] = str(category_dropdown.get_item_metadata(idx))
	v["category_name"] = category_dropdown.get_item_text(idx) if idx > 0 else ""
	_clear_list(state, "Loading...")
	_route(state)


func _on_provider(idx: int, state: Dictionary) -> void:
	var provider_dropdown: OptionButton = state["provider_dropdown"]
	var p := str(provider_dropdown.get_item_metadata(idx))
	if p == str(state["provider"]):
		return
	state["provider"] = p
	_set_ui_cfg_value("settings", "browse_source", p)
	var v: Dictionary = _browse_view(state)
	# Categories are per host and the menu is about to be cleared.
	v["categories_loaded"] = false
	_browse_apply_provider_controls(state, p)
	_clear_banner(state)
	_clear_list(state, "Loading " + host_display_name(p) + "...")
	_load_categories(state)
	_route(state)


# Re-run by the banner's Retry and every successful fetch until it lands;
# the two flags keep the calls from stacking.
func _load_categories(state: Dictionary) -> void:
	var category_dropdown: OptionButton = state["category_dropdown"]
	var provider := str(state["provider"])
	var v: Dictionary = _browse_view(state)
	if not bool(host_caps(provider)["categories"]):
		return
	if bool(v["categories_loaded"]) or bool(v["categories_loading"]):
		return
	v["categories_loading"] = true
	var res := await host_list_categories(provider)
	v["categories_loading"] = false
	if not is_instance_valid(category_dropdown):
		return
	if str(state["provider"]) != provider:
		return
	if not res["ok"]:
		return
	var cats: Array = res["data"]
	var ids := {}
	for c in cats:
		ids[str((c as Dictionary)["id"])] = true
	_reset_categories(category_dropdown)
	for c in cats:
		var cd: Dictionary = c
		# A hierarchical host shows its top level only; a flat host's group
		# names are not ids, so every entry shows.
		if str(cd["parent_id"]) != "" and ids.has(str(cd["parent_id"])):
			continue
		if str(cd["name"]) == "":
			continue
		category_dropdown.add_item(str(cd["name"]))
		var idx: int = category_dropdown.item_count - 1
		category_dropdown.set_item_metadata(idx, str(cd["id"]))
		if str(cd["id"]) == str(v["category_ref"]):
			category_dropdown.select(idx)
	v["categories_loaded"] = true


# Rows bake install state at render time; sync them in place so search text,
# caret, scroll and loaded pages survive.
func _refresh_browse_installed_rows(root: Node) -> void:
	var by_key: Dictionary = _browse_install_map()
	var stack: Array = [root]
	while not stack.is_empty():
		var node: Node = stack.pop_back()
		for child in node.get_children():
			stack.push_back(child)
		if not node.has_meta(_BROWSE_META_REF_KEY):
			continue
		var entry_v: Variant = by_key.get(str(node.get_meta(_BROWSE_META_REF_KEY)))
		if node is CheckBox:
			var cb := node as CheckBox
			if entry_v is Dictionary:
				cb.disabled = false
				cb.text = "Enabled in " + _active_profile_label()
				cb.tooltip_text = "Toggle this mod in profile: " + _active_profile_label() + "."
				cb.set_pressed_no_signal(bool(entry_v["enabled"]))
			else:
				# Uninstalled behind the tab's back: keep the row, make it inert.
				cb.set_pressed_no_signal(false)
				cb.disabled = true
				cb.text = "Removed"
				cb.tooltip_text = "This mod is no longer installed. Click its name and use Download to install it again."
		elif node is Button and entry_v is Dictionary:
			var btn := node as Button
			# Queued and downloading buttons still belong to the download loop.
			if btn.disabled and str(btn.get_meta(_BROWSE_META_DL_STATE, "")) != "installed":
				continue
			var check := _enable_checkbox(str(btn.get_meta(_BROWSE_META_REF_KEY)), entry_v,
					btn.get_meta(_BROWSE_META_ON_TOGGLE))
			var parent := btn.get_parent()
			var index := btn.get_index()
			parent.remove_child(btn)
			parent.add_child(check)
			parent.move_child(check, index)
			btn.queue_free()


func _enable_checkbox(ref_key: String, entry: Dictionary, on_toggle: Callable) -> CheckBox:
	var check := CheckBox.new()
	check.text = "Enabled in " + _active_profile_label()
	check.button_pressed = bool(entry["enabled"])
	check.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	check.set_meta(_BROWSE_META_REF_KEY, ref_key)
	check.toggled.connect(func(on: bool):
		on_toggle.call(ref_key, on, check)
	)
	_wire_hint(check, "Toggle this mod in profile: " + _active_profile_label() + ".")
	return check


func _mod_row(summary: Dictionary, install_map: Dictionary, state: Dictionary) -> Control:
	var on_get: Callable = state["on_get"]
	var on_toggle: Callable = state["on_toggle"]
	var ref: Dictionary = summary["ref"]
	var provider := str(ref["provider"])
	var caps: Dictionary = host_caps(provider)
	var ref_key := host_ref_key(ref)
	var install_entry: Variant = install_map.get(ref_key)
	var row := _row_frame(summary, "", func():
		_show_browse_mod_detail_dialog(summary, on_get)
	)

	# A host with no file gets a quiet label: a disabled Download here always
	# means in flight or installed.
	if install_entry is Dictionary:
		row.add_child(_enable_checkbox(ref_key, install_entry, on_toggle))
	elif _browse_can_download(summary, caps):
		var get_btn := Button.new()
		get_btn.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		get_btn.text = "Download"
		get_btn.set_meta(_BROWSE_META_REF_KEY, ref_key)
		get_btn.set_meta(_BROWSE_META_ON_TOGGLE, on_toggle)
		get_btn.pressed.connect(func():
			on_get.call(summary, get_btn)
		)
		row.add_child(get_btn)
		_wire_hint(get_btn, "Download this mod from " + host_display_name(provider) + ".")
	else:
		var no_dl := _make_label("No file yet", COL_TEXT_DIM, FS_META)
		no_dl.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		no_dl.mouse_filter = Control.MOUSE_FILTER_PASS
		row.add_child(no_dl)
		_wire_hint(no_dl, host_display_name(provider) + " has no downloadable file for this mod yet (it may still be scanning).")

	return row


# Thumbnail, name link and meta line; the caller appends its action cell.
func _row_frame(summary: Dictionary, count_label: String, on_name: Callable) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", SP_L)

	var thumb_rect := _make_thumb_cell(row, Vector2(96, 54))
	_browse_load_thumbnail_async(thumb_rect, summary["thumbnail"])

	var info_col := VBoxContainer.new()
	info_col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	info_col.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(info_col)

	# A flat Button, since a LinkButton cannot clip and a long name pushed
	# Download out of view.
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
	name_lnk.pressed.connect(on_name)
	info_col.add_child(name_lnk)

	var metrics: PackedStringArray = host_caps(str(summary["ref"]["provider"]))["metrics"]
	var meta_text := _browse_meta_text(summary, metrics, count_label)
	info_col.add_child(_make_sub_label(meta_text, COL_TEXT_DIM, meta_text, FS_META))
	return row


# On a host that lists downloadability, default_file_id "" means no clean file yet.
func _browse_can_download(summary: Dictionary, caps: Dictionary) -> bool:
	return bool(caps["resolve_file"]) \
			and (not bool(caps["lists_downloadable"]) or str(summary["default_file_id"]) != "")


# A metric shows only when reported (-1 is not reported); zero likes and
# views are hidden, zero downloads is shown.
func _browse_meta_text(summary: Dictionary, metrics: PackedStringArray, count_label := "") -> String:
	var parts := PackedStringArray()
	if str(summary["author_name"]) != "":
		parts.append("by " + str(summary["author_name"]))
	if count_label != "":
		parts.append(count_label)
	if str(summary["version"]) != "":
		parts.append("v" + str(summary["version"]))
	var downloads := _host_count(summary["downloads"])
	if metrics.has("downloads") and downloads >= 0:
		parts.append(str(downloads) + " downloads")
	var likes := _host_count(summary["likes"])
	if metrics.has("likes") and likes > 0:
		parts.append(str(likes) + " likes")
	var views := _host_count(summary["views"])
	if metrics.has("views") and views > 0:
		parts.append(str(views) + " views")
	if str(summary["category_name"]) != "":
		parts.append(str(summary["category_name"]))
	var updated_short := _format_iso_datetime(str(summary["updated_at"]))
	if updated_short != "":
		parts.append("updated " + updated_short)
	return " - ".join(parts)


func _show_browse_mod_detail_dialog(summary: Dictionary, on_get: Callable) -> void:
	var ref: Dictionary = summary["ref"]
	var caps: Dictionary = host_caps(str(ref["provider"]))
	var shell := _new_scroll_dialog(str(summary["name"]), _DETAIL_DIALOG_SIZE, SP_L)
	var view := {"d": shell["d"], "box": shell["box"], "on_get": on_get, "dl_status": null, "banner": null,
			"desc": null, "installed": false, "get_btn": null, "files_status": null, "files_list": null}
	_detail_head(view, shell["outer"], summary, _browse_meta_text(summary, caps["metrics"]))
	if bool(caps["file_history"]):
		var box: VBoxContainer = view["box"]
		box.add_child(HSeparator.new())
		box.add_child(_make_head_label("Files"))
		view["files_status"] = _make_label("Loading file list...", COL_TEXT_DIM, FS_BODY)
		box.add_child(view["files_status"])
		var files_list := VBoxContainer.new()
		files_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		box.add_child(files_list)
		view["files_list"] = files_list
	_detail_buttons(view, summary, caps)
	_detail_load(view, ref, caps)
	_detail_files(view, ref, summary)
	_present_dialog(shell["d"])


# Status, banner, meta line and short text; view needs box and desc (null).
func _detail_head(view: Dictionary, outer: VBoxContainer, summary: Dictionary, meta_text: String) -> void:
	var box: VBoxContainer = view["box"]
	# Pinned below the scroll so download feedback stays visible.
	var dl_status := _make_sub_label("", COL_TEXT_DIM)
	dl_status.visible = false
	dl_status.mouse_filter = Control.MOUSE_FILTER_PASS
	outer.add_child(dl_status)
	view["dl_status"] = dl_status

	# The thumbnail now; the detail repaints it with the banner.
	var thumb: Dictionary = summary["thumbnail"]
	if str(thumb["url"]) != "":
		view["banner"] = _make_thumb_cell(box, Vector2(0, 220), false)
		_browse_load_thumbnail_async(view["banner"], thumb)

	var meta := _make_label(meta_text, COL_TEXT_DIM, FS_META)
	meta.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(meta)

	# The short text now, the full one once the detail lands.
	_detail_description(view, _markdown_to_bbcode(str(summary["short_description"])))


func _detail_description(view: Dictionary, bbcode: String) -> void:
	if bbcode.strip_edges().is_empty():
		return
	if view["desc"] == null:
		view["desc"] = _browse_detail_description(view["box"])
	(view["desc"] as RichTextLabel).text = bbcode


# The button bar keeps Page and Download visible at any scroll.
func _detail_buttons(view: Dictionary, summary: Dictionary, caps: Dictionary) -> void:
	var d: AcceptDialog = view["d"]
	var ref: Dictionary = summary["ref"]
	var page_url := host_mod_page_url(ref)
	if page_url != "":
		var page_btn := d.add_button("Open mod page in browser", false, "")
		page_btn.pressed.connect(func():
			OS.shell_open(page_url)
		)
	view["installed"] = _browse_install_map().has(host_ref_key(ref))
	if view["installed"]:
		var installed_btn := d.add_button("Installed", true, "")
		installed_btn.disabled = true
	elif _browse_can_download(summary, caps):
		_detail_download_button(view, summary)


func _detail_download_button(view: Dictionary, record: Dictionary) -> void:
	var d: AcceptDialog = view["d"]
	var on_get: Callable = view["on_get"]
	var get_btn := d.add_button("Download", true, "")
	style_primary_button(get_btn)
	get_btn.set_meta(_BROWSE_META_DIALOG_STATUS, view["dl_status"])
	get_btn.pressed.connect(func():
		on_get.call(record, get_btn)
	)
	view["get_btn"] = get_btn


# Not awaited, so the dialog shows before the host answers. Any failure
# leaves the summary view standing.
func _detail_load(view: Dictionary, ref: Dictionary, caps: Dictionary) -> void:
	var res := await host_get_mod(ref)
	if not res["ok"]:
		return
	if not is_instance_valid(view["d"]):
		return
	var detail: Dictionary = res["data"]
	_detail_description(view, str(detail["description"]))
	var banner: Dictionary = detail["banner"]
	if str(banner["url"]) != "" and view["banner"] != null:
		_browse_load_thumbnail_async(view["banner"], banner)
	if view["get_btn"] == null and not view["installed"] and _browse_can_download(detail, caps):
		_detail_download_button(view, detail)


func _browse_detail_description(box: VBoxContainer) -> RichTextLabel:
	var desc_hdr := _make_head_label("Description")
	var desc_rt := RichTextLabel.new()
	desc_rt.bbcode_enabled = true
	desc_rt.fit_content = true
	desc_rt.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	desc_rt.selection_enabled = true
	desc_rt.meta_underlined = true
	desc_rt.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	desc_rt.add_theme_color_override("default_color", COL_TEXT)
	# Web schemes only: the URL comes from an untrusted description, and
	# OS.shell_open is ShellExecute on Windows.
	desc_rt.meta_clicked.connect(func(meta_v):
		var u := str(meta_v).strip_edges()
		if u.to_lower().begins_with("http://") or u.to_lower().begins_with("https://"):
			OS.shell_open(u)
	)
	box.add_child(HSeparator.new())
	box.add_child(desc_hdr)
	box.add_child(desc_rt)
	return desc_rt


# Not awaited, like _detail_load; files_status is null for hosts without file history.
func _detail_files(view: Dictionary, ref: Dictionary, summary: Dictionary) -> void:
	if view["files_status"] == null:
		return
	var files_status: Label = view["files_status"]
	var res := await host_list_files(ref)
	if not is_instance_valid(files_status):
		return
	if not res["ok"]:
		files_status.text = host_error_message(str(ref["provider"]), res)
		files_status.add_theme_color_override("font_color", COL_ERR)
		return
	var files: Array = res["data"]
	if files.is_empty():
		files_status.text = "No downloadable files yet."
		return
	files_status.queue_free()
	var files_list: VBoxContainer = view["files_list"]
	var primary_id := str(summary["default_file_id"])
	for fd in files:
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

		var size := _host_count(fd["size"])
		var size_lbl := _make_label(_format_size(size) if size >= 0 else "", COL_TEXT_DIM)
		size_lbl.custom_minimum_size.x = 80
		f_row.add_child(size_lbl)

		var date_str := str(fd["created_at"])
		if date_str.contains("T"):
			date_str = date_str.split("T")[0]
		f_row.add_child(_make_label(date_str, COL_TEXT_DIM))
