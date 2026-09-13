## ----- ui_updates.gd -----
## The Updates tab and the session state it restores on every show.

# Rebuild the Updates tab on show: it snapshots entries at build time, so a
# mod updated mid-session would leave rows whose Download targets a gone file.
func _rebuild_updates_tab(tabs: TabContainer) -> void:
	var old := tabs.get_node_or_null(UI_TAB_UPDATES)
	if old == null:
		return
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

# Same one-frame-later restore as _restore_mods_scroll.
func _restore_updates_scroll(saved_scroll: int) -> void:
	await get_tree().process_frame
	if is_instance_valid(_ui_updates_scroll):
		_ui_updates_scroll.scroll_vertical = saved_scroll


# -- Updates-tab session state -------------------------------------------------
# The Updates tab is torn down and rebuilt on every show, so the results of
# a completed check live at module scope, as _mod_updates_state does for the
# Mods-tab badges.
#   _updates_tab_status: profile_key -> {text, tooltip, color} for a row's
#     terminal Status text ("Up to date", "Check failed", ...). Rows with an
#     available update re-arm from _mod_updates_state instead, so a mod
#     updated from the Mods tab never shows a stale "Update: vX" here.
#   _updates_tab_log: timestamped Activity lines, re-rendered on build.
#   _updates_tab_dl_in_flight: this tab's row downloads still awaiting;
#     "Check for updates" re-enables only when it reaches zero.
var _updates_tab_status: Dictionary = {}
var _updates_tab_log: Array[String] = []
# Oldest lines drop off past this many; see add_log in build_updates_tab.
const _UPDATES_LOG_MAX := 200
var _updates_tab_dl_in_flight: int = 0
# Live references to the current build's list scroller and check button, so
# a rebuild carries scroll position and completions re-enable the current button.
var _ui_updates_scroll: ScrollContainer = null
var _ui_updates_check_btn: Button = null

# Arm an Updates-tab row for an available update: status, Download button
# and handler. Shared by the check and the on-show rebuild. State writes are
# unconditional; UI touches are guarded per node.
func _updates_arm_row_update(info: Dictionary, latest_v: String, add_log: Callable) -> void:
	var pre_entry: Dictionary = info.get("entry", {})
	var pk: String = str(pre_entry.get("profile_key", "")) if not pre_entry.is_empty() else ""
	# Surface state through _mod_updates_state so the Mods tab badge and the rebuild see it.
	if pk != "":
		_mod_updates_state[pk] = {
			"latest_version": latest_v,
			"current_version": str(info["version"]),
			"ref": info["ref"],
			"full_path": str(info["full_path"]),
			"mod_name": str(info["mod_name"]),
		}
		# An available update supersedes any stored terminal status.
		_updates_tab_status.erase(pk)
	var lbl: Label = info["label"]
	var dl_btn: Button = info["dl_btn"]
	if is_instance_valid(lbl):
		# Accent = the update signal; the tooltip carries the full text.
		lbl.text = "Update: v" + latest_v
		lbl.tooltip_text = lbl.text
		lbl.add_theme_color_override("font_color", COL_ACCENT)
	if not is_instance_valid(dl_btn):
		return
	dl_btn.modulate.a = 1.0
	dl_btn.disabled = false
	dl_btn.mouse_filter = Control.MOUSE_FILTER_STOP
	var full_path: String = str(info["full_path"])
	var ref: Dictionary = info["ref"]
	var mod_name: String = str(info["mod_name"])
	var new_ver: String = latest_v
	# Guard key for _mod_update_in_flight, shared with the Mods-tab badge path
	# because both surfaces target the same file and rollback paths.
	var guard_key: String = pk if pk != "" else full_path
	# Disconnect previous connections so repeated checks don't stack callbacks.
	for c in dl_btn.pressed.get_connections():
		dl_btn.pressed.disconnect(c["callable"])
	dl_btn.pressed.connect(func():
		# Refuse a second concurrent download of the same mod: two runs would
		# delete each other's temp and backup files and corrupt the rollback.
		if _mod_update_in_flight.has(guard_key):
			return
		_mod_update_in_flight[guard_key] = true
		_updates_tab_dl_in_flight += 1
		dl_btn.disabled = true
		dl_btn.text = "Downloading..."
		if is_instance_valid(lbl):
			lbl.text = "Downloading..."
			lbl.tooltip_text = lbl.text
			lbl.add_theme_color_override("font_color", COL_ACCENT)
		if is_instance_valid(_ui_updates_check_btn):
			_ui_updates_check_btn.disabled = true
		# Re-resolve live: the Mods-tab badge may have renamed this file since the build.
		var live_path: String = _live_full_path(pk, full_path)
		var result: Dictionary = await replace_mod_from_ref(live_path, ref)
		# State bookkeeping first, unconditionally: the on-show rebuild can free
		# every node this closure captured while the download is in flight. UI
		# touches are guarded individually below.
		_mod_update_in_flight.erase(guard_key)
		_updates_tab_dl_in_flight = maxi(0, _updates_tab_dl_in_flight - 1)
		# Re-enable the current check button only when no downloads remain.
		if _updates_tab_dl_in_flight == 0 and is_instance_valid(_ui_updates_check_btn):
			_ui_updates_check_btn.disabled = false
		if result.get("ok", false):
			# Update cached version so next Check won't re-flag this mod.
			info["version"] = new_ver
			# Reflect the on-disk rename in the live entry dict so the next discovery
			# pass and any rebuild point at the new archive.
			var new_path: String = str(result.get("new_path", full_path))
			var new_fn: String = str(result.get("new_file_name", full_path.get_file()))
			info["full_path"] = new_path
			var entry_ref: Dictionary = _live_entry_for_profile_key(pk, pre_entry)
			if not entry_ref.is_empty():
				entry_ref["full_path"] = new_path
				entry_ref["file_name"] = new_fn
			if pk != "":
				# Drop the shared badge state and persist the terminal status.
				_mod_updates_state.erase(pk)
				_updates_tab_status[pk] = {
					"text": "Updated -- restart to apply",
					"tooltip": "Updated -- restart to apply",
					"color": COL_OK,
				}
			# The badge state changed while the Mods tab may be off-screen.
			_mods_badges_dirty = true
			var rename_note: String = (" (renamed to " + new_fn + ")") if new_fn != full_path.get_file() else ""
			add_log.call(mod_name + " -- updated to v" + new_ver + rename_note + ". Restart game to apply.")
			if is_instance_valid(lbl):
				lbl.text = "Updated -- restart to apply"
				lbl.tooltip_text = lbl.text
				lbl.add_theme_color_override("font_color", COL_OK)
			if is_instance_valid(dl_btn):
				dl_btn.modulate.a = 0.0
				dl_btn.disabled = true
				dl_btn.mouse_filter = Control.MOUSE_FILTER_IGNORE
				dl_btn.text = "Update"
			var ver_lbl_v: Variant = info.get("ver_lbl")
			if ver_lbl_v is Label and is_instance_valid(ver_lbl_v):
				(ver_lbl_v as Label).text = "v" + new_ver
				(ver_lbl_v as Label).tooltip_text = "v" + new_ver
		else:
			# Surface the real failure cause (file collision, locked file, rate
			# limit) instead of blaming the connection.
			var err_detail := str(result.get("error", ""))
			var log_line := "Could not download " + mod_name + ". Check your connection and try again."
			if err_detail != "" and err_detail != "unknown":
				log_line = "Could not download " + mod_name + " -- " + err_detail
			if pk != "":
				_updates_tab_status[pk] = {"text": "Download failed", "tooltip": log_line, "color": COL_ERR}
			add_log.call(log_line)
			if is_instance_valid(lbl):
				lbl.text = "Download failed"
				lbl.tooltip_text = log_line
				lbl.add_theme_color_override("font_color", COL_ERR)
			if is_instance_valid(dl_btn):
				dl_btn.disabled = false
				dl_btn.text = "Retry"
	)

# Scroll the restored log to its newest line one frame later (no layout yet).
func _updates_scroll_log_to_bottom(sc: ScrollContainer) -> void:
	await get_tree().process_frame
	if is_instance_valid(sc):
		sc.scroll_vertical = 999999

func build_updates_tab() -> Control:
	var margin := _make_tab_margin()

	var container := VBoxContainer.new()
	container.add_theme_constant_override("separation", SP_M)
	margin.add_child(container)
	var check_btn := _updates_build_header(container)

	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	container.add_child(scroll)
	_ui_updates_scroll = scroll

	var list := VBoxContainer.new()
	list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(list)

	# file_name -> {label, ver_lbl, version, ref, dl_btn, full_path, mod_name, entry}
	# for every row that can be checked.
	var status_info: Dictionary = {}
	var persisted_sources := _get_persisted_mod_sources()
	for entry in _ui_mod_entries:
		var info := _updates_build_row(list, entry, persisted_sources)
		if not info.is_empty():
			status_info[entry["file_name"]] = info

	if list.get_child_count() == 0:
		var lbl := Label.new()
		lbl.text = "No mods to check yet.\nGet mods from the Browse tab, then check for updates here."
		lbl.add_theme_color_override("font_color", COL_TEXT_DIM)
		lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		list.add_child(lbl)

	var add_log := _updates_build_log(container)
	_updates_restore_rows(status_info, add_log)

	check_btn.pressed.connect(func():
		check_btn.disabled = true
		check_btn.text = "Checking for updates..."
		for fn in status_info:
			var info: Dictionary = status_info[fn]
			(info["label"] as Label).text = "Checking..."
			(info["label"] as Label).tooltip_text = "Checking..."
			(info["label"] as Label).add_theme_color_override("font_color", COL_TEXT_DIM)
			var btn: Button = info["dl_btn"]
			btn.modulate.a = 0.0
			btn.disabled = true
			btn.mouse_filter = Control.MOUSE_FILTER_IGNORE
			btn.text = "Update"
		await check_updates_for_ui(status_info, add_log, check_btn)
		# The launcher can close while the check is in flight; the button dies with it.
		if not is_instance_valid(check_btn):
			return
		check_btn.disabled = false
		check_btn.text = "Check for updates"
	)

	return margin


# Toolbar with the Check button, then the column headers. Returns the button.
func _updates_build_header(container: VBoxContainer) -> Button:
	var toolbar := HBoxContainer.new()
	toolbar.add_theme_constant_override("separation", SP_M)
	container.add_child(toolbar)

	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	toolbar.add_child(spacer)

	var check_btn := Button.new()
	check_btn.text = "Check for updates"
	style_primary_button(check_btn)
	# A tab rebuilt mid-download must not offer a check that would reset the row.
	if _updates_tab_dl_in_flight > 0:
		check_btn.disabled = true
	toolbar.add_child(check_btn)
	_ui_updates_check_btn = check_btn

	container.add_child(HSeparator.new())

	var header_row := HBoxContainer.new()
	container.add_child(header_row)

	var h_mod := Label.new()
	h_mod.text = "Mod"
	h_mod.add_theme_font_size_override("font_size", FS_META)
	h_mod.add_theme_color_override("font_color", COL_TEXT_DIM)
	h_mod.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header_row.add_child(h_mod)

	var h_ver := Label.new()
	h_ver.text = "Version"
	h_ver.add_theme_font_size_override("font_size", FS_META)
	h_ver.add_theme_color_override("font_color", COL_TEXT_DIM)
	h_ver.custom_minimum_size.x = 90
	header_row.add_child(h_ver)

	var h_status := Label.new()
	h_status.text = "Status"
	h_status.add_theme_font_size_override("font_size", FS_META)
	h_status.add_theme_color_override("font_color", COL_TEXT_DIM)
	h_status.custom_minimum_size.x = 160
	header_row.add_child(h_status)

	var h_action := Label.new()
	h_action.text = "Action"
	h_action.add_theme_font_size_override("font_size", FS_META)
	h_action.add_theme_color_override("font_color", COL_TEXT_DIM)
	h_action.custom_minimum_size.x = 90
	header_row.add_child(h_action)

	container.add_child(HSeparator.new())
	return check_btn


# One row: name and modified date, version, status, and a hidden Update
# button that _updates_arm_row_update reveals. Returns the status_info record
# for rows that can be checked, {} otherwise.
func _updates_build_row(list: VBoxContainer, entry: Dictionary, persisted_sources: Dictionary) -> Dictionary:
	var cfg: ConfigFile = entry["cfg"]
	if cfg == null:
		return {}
	var version := str(cfg.get_value("mod", "version", ""))
	var ref := _entry_host_ref(entry, persisted_sources)
	# Checkable means a host that can hand back a file.
	var checkable := not ref.is_empty() and bool(host_caps(str(ref["provider"]))["resolve_file"])

	var row := HBoxContainer.new()
	list.add_child(row)

	var name_col := VBoxContainer.new()
	name_col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(name_col)

	var name_lbl := Label.new()
	name_lbl.text = entry["mod_name"]
	name_lbl.clip_text = true
	name_lbl.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	name_lbl.tooltip_text = str(entry["mod_name"])
	# Labels default to MOUSE_FILTER_IGNORE, which suppresses tooltips.
	name_lbl.mouse_filter = Control.MOUSE_FILTER_PASS
	name_col.add_child(name_lbl)

	var mtime := FileAccess.get_modified_time(entry["full_path"])
	if mtime > 0:
		var dt := Time.get_datetime_dict_from_unix_time(mtime)
		var date_str := "%04d-%02d-%02d" % [dt["year"], dt["month"], dt["day"]]
		var mod_lbl := Label.new()
		mod_lbl.text = "modified " + date_str
		mod_lbl.add_theme_font_size_override("font_size", FS_META)
		mod_lbl.add_theme_color_override("font_color", COL_TEXT_DIM)
		name_col.add_child(mod_lbl)

	var ver_lbl := Label.new()
	ver_lbl.text = "v" + version if version != "" else "--"
	# A long prerelease string must not push the columns out of alignment.
	ver_lbl.clip_text = true
	ver_lbl.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	ver_lbl.tooltip_text = ver_lbl.text
	ver_lbl.mouse_filter = Control.MOUSE_FILTER_PASS
	ver_lbl.custom_minimum_size.x = 90
	row.add_child(ver_lbl)

	var status_lbl := Label.new()
	status_lbl.custom_minimum_size.x = 160
	# Status text can outgrow the column; trim it.
	status_lbl.clip_text = true
	status_lbl.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	status_lbl.add_theme_color_override("font_color", COL_TEXT_DIM)
	# PASS so the ellipsized status text gets a full-text tooltip.
	status_lbl.mouse_filter = Control.MOUSE_FILTER_PASS
	if entry["ext"] == "folder":
		# Dev folders cannot take a downloaded archive; say so instead of offering one.
		status_lbl.text = "Dev folder"
		status_lbl.tooltip_text = "Dev folders load straight from your mods folder, so there is nothing to download. Update downloads only apply to mods installed as archives."
	elif not ref.is_empty() and not checkable:
		status_lbl.text = "No update info"
		status_lbl.tooltip_text = host_display_name(str(ref["provider"])) + " does not provide downloads through the loader, so this mod cannot be checked."
	elif not checkable or version == "":
		# Say why this row cannot be checked.
		status_lbl.text = "No update info"
		status_lbl.tooltip_text = "This mod's mod.txt does not say where it came from ([updates] source= plus [mod] version=), so it cannot be checked. Add both fields to enable update checks."
	else:
		status_lbl.text = "--"
	row.add_child(status_lbl)

	# Always add dl_btn to preserve column width; modulate.a hides it.
	var dl_btn := Button.new()
	dl_btn.text = "Update"
	dl_btn.custom_minimum_size.x = 90
	dl_btn.modulate.a = 0.0
	dl_btn.disabled = true
	dl_btn.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(dl_btn)

	list.add_child(HSeparator.new())

	if checkable and version != "" and entry["ext"] != "folder":
		# Hold the underlying entry dict so the download callback can update
		# full_path and file_name in place when an update lands under a new name.
		return {
			"label": status_lbl, "ver_lbl": ver_lbl, "version": version, "ref": ref,
			"dl_btn": dl_btn, "full_path": entry["full_path"],
			"mod_name": entry["mod_name"], "entry": entry,
		}
	return {}


# The Activity log under the list, with earlier lines restored. Returns the
# add_log Callable the check and the row downloads report through.
func _updates_build_log(container: VBoxContainer) -> Callable:
	container.add_child(HSeparator.new())

	var log_hdr := Label.new()
	log_hdr.text = "Activity"
	log_hdr.add_theme_font_size_override("font_size", FS_BODY)
	log_hdr.add_theme_color_override("font_color", COL_TEXT_DIM)
	container.add_child(log_hdr)

	var log_bg := PanelContainer.new()
	log_bg.custom_minimum_size.y = 72
	var log_style := StyleBoxFlat.new()
	log_style.bg_color = COL_SURFACE_2
	log_style.content_margin_left = SP_M
	log_style.content_margin_right = SP_M
	log_style.content_margin_top = SP_S
	log_style.content_margin_bottom = SP_S
	log_bg.add_theme_stylebox_override("panel", log_style)
	container.add_child(log_bg)

	var log_scroll := ScrollContainer.new()
	log_bg.add_child(log_scroll)

	var log_list := VBoxContainer.new()
	log_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	log_scroll.add_child(log_list)

	var log_label := func(line: String) -> Label:
		var lbl := Label.new()
		lbl.text = line
		lbl.add_theme_font_size_override("font_size", FS_BODY)
		lbl.add_theme_color_override("font_color", COL_TEXT)
		lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		return lbl

	var add_log := func(msg: String):
		var t := Time.get_time_string_from_system()
		var line := "[" + t + "] " + msg
		# Persist first: a download can finish after this tab was rebuilt. Capped,
		# since every rebuild re-renders one Label per stored line.
		_updates_tab_log.append(line)
		while _updates_tab_log.size() > _UPDATES_LOG_MAX:
			_updates_tab_log.remove_at(0)
		if not is_instance_valid(log_list):
			return
		log_list.add_child(log_label.call(line))
		# Defer a frame: the new label has no layout yet.
		_updates_scroll_log_to_bottom(log_scroll)

	# Restore Activity lines from earlier checks this session, then scroll to
	# the newest line one frame later (the restored labels have no layout yet).
	for line in _updates_tab_log:
		log_list.add_child(log_label.call(line))
	if not _updates_tab_log.is_empty():
		_updates_scroll_log_to_bottom(log_scroll)
	return add_log


# Restore per-row results from earlier checks this session. Precedence: a
# download in flight renders the row inert (a live Update button would
# allow a second concurrent download); then an available update re-arms
# from _mod_updates_state; then any stored terminal status.
func _updates_restore_rows(status_info: Dictionary, add_log: Callable) -> void:
	for fn in status_info:
		var info: Dictionary = status_info[fn]
		var entry_d: Dictionary = info.get("entry", {})
		var pk := str(entry_d.get("profile_key", ""))
		if pk == "":
			continue
		var row_lbl: Label = info["label"]
		if _mod_update_in_flight.has(pk):
			row_lbl.text = "Downloading..."
			row_lbl.tooltip_text = row_lbl.text
			row_lbl.add_theme_color_override("font_color", COL_ACCENT)
			var b: Button = info["dl_btn"]
			b.modulate.a = 1.0
			b.disabled = true
			b.text = "Downloading..."
			continue
		if _mod_updates_state.has(pk):
			var upd: Dictionary = _mod_updates_state[pk]
			var latest_known := str(upd.get("latest_version", ""))
			# Re-verify against the row's current version. The file may have
			# been updated through another surface since the check ran.
			if latest_known != "" and compare_versions(str(info["version"]), latest_known) < 0:
				_updates_arm_row_update(info, latest_known, add_log)
				continue
		if _updates_tab_status.has(pk):
			var st: Dictionary = _updates_tab_status[pk]
			row_lbl.text = str(st.get("text", ""))
			row_lbl.tooltip_text = str(st.get("tooltip", row_lbl.text))
			var col_v: Variant = st.get("color")
			row_lbl.add_theme_color_override("font_color", col_v if col_v is Color else COL_TEXT_DIM)

# Update check for every installed mod with a downloadable host and a version.
# Populates _mod_updates_state. Returns {checked, with_updates, errors}.
func _run_updates_check_for_mods() -> Dictionary:
	if _mod_updates_check_in_progress:
		return {"checked": 0, "with_updates": 0, "errors": 0}
	_mod_updates_check_in_progress = true
	var summary := {"checked": 0, "with_updates": 0, "errors": 0}
	var pending: Array = []
	var persisted_sources := _get_persisted_mod_sources()
	for entry in _ui_mod_entries:
		var cfg: ConfigFile = entry.get("cfg")
		if cfg == null:
			continue
		# Dev folders cannot take a downloaded archive; never flag them.
		if str(entry.get("ext", "")) == "folder":
			continue
		var ref := _entry_host_ref(entry, persisted_sources)
		if ref.is_empty() or not bool(host_caps(str(ref["provider"]))["resolve_file"]):
			continue
		var version := str(cfg.get_value("mod", "version", "")).strip_edges()
		if version == "":
			continue
		pending.append({
			"profile_key": str(entry.get("profile_key", "")),
			"ref": ref,
			"version": version,
			"full_path": str(entry.get("full_path", "")),
			"mod_name": str(entry.get("mod_name", "?")),
		})
	if pending.is_empty():
		_mod_updates_check_in_progress = false
		return summary
	var refs: Array = []
	for p in pending:
		refs.append((p as Dictionary)["ref"])
	var latest := await fetch_latest_versions(refs)
	for p in pending:
		summary["checked"] += 1
		var info: Dictionary = p
		var raw = latest.get(host_ref_key(info["ref"]), null)
		if raw == null:
			summary["errors"] += 1
			continue
		var latest_v := str(raw)
		if latest_v.is_empty():
			continue
		var cmp := compare_versions(str(info["version"]), latest_v)
		if cmp >= 0:
			# Up to date -- drop any stale entry from a prior check.
			_mod_updates_state.erase(info["profile_key"])
			continue
		summary["with_updates"] += 1
		_mod_updates_state[info["profile_key"]] = {
			"latest_version": latest_v,
			"current_version": info["version"],
			"ref": info["ref"],
			"full_path": info["full_path"],
			"mod_name": info["mod_name"],
		}
	_mod_updates_check_in_progress = false
	return summary


func check_updates_for_ui(status_info: Dictionary, add_log: Callable, _check_btn: Button) -> void:
	var refs: Array = []
	for fn in status_info:
		refs.append(status_info[fn]["ref"])
	if refs.is_empty():
		# With only dev-folder or sourceless mods installed, say why nothing
		# happened (same copy as the Mods-tab toast).
		add_log.call("No installed mods say where they came from, so there is nothing to check.")
		return

	var latest := await fetch_latest_versions(refs)

	# The Mods tab is off-screen; flag it to rebuild its badges on the next show.
	_mods_badges_dirty = true

	# State bookkeeping must survive a mid-check tab rebuild (switching away
	# frees every node in status_info): persisted state is written
	# unconditionally, UI touches are guarded per node.
	for fn: String in status_info:
		var info: Dictionary = status_info[fn]
		var lbl: Label = info["label"]
		var pre_entry: Dictionary = info.get("entry", {})
		var pk: String = str(pre_entry.get("profile_key", "")) if not pre_entry.is_empty() else ""
		var latest_v = latest.get(host_ref_key(info["ref"]), null)
		if latest_v == null:
			# The rate-limit hint lives in the tooltip; the sentence would ellipsize here.
			var fail_tip := host_error_status(str((info["ref"] as Dictionary)["provider"]), "Check failed")
			if pk != "":
				_updates_tab_status[pk] = {"text": "Check failed", "tooltip": fail_tip, "color": COL_ERR}
			if is_instance_valid(lbl):
				lbl.text = "Check failed"
				lbl.tooltip_text = fail_tip
				lbl.add_theme_color_override("font_color", COL_ERR)
			continue

		var cmp := compare_versions(info["version"], str(latest_v))
		if cmp >= 0:
			# Local is same version or newer than what's on the server.
			if pk != "":
				_mod_updates_state.erase(pk)
				_updates_tab_status[pk] = {"text": "Up to date", "tooltip": "Up to date", "color": COL_TEXT_DIM}
			if is_instance_valid(lbl):
				lbl.text = "Up to date"
				lbl.tooltip_text = lbl.text
				lbl.add_theme_color_override("font_color", COL_TEXT_DIM)
		else:
			# Server has a newer version: arm the row through the shared helper.
			_updates_arm_row_update(info, str(latest_v), add_log)
