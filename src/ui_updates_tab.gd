# -- Updates-tab session state -------------------------------------------------
# The Updates tab is torn down and rebuilt on every show (tab_changed ->
# _rebuild_updates_tab), which used to wipe a completed check's per-row
# statuses, the Activity log, and the scroll position -- forcing the user to
# re-run the check (spending rate budget) just to see results again. This
# state survives rebuilds at module scope, same as _mod_updates_state does for
# the Mods-tab badges.
#   _updates_tab_status: profile_key -> {text, tooltip, color} snapshot of a
#     row's TERMINAL Status text ("Up to date", "Check failed", "Updated --
#     restart to apply", "Download failed"). Rows with an update AVAILABLE are
#     not stored here -- they re-arm from _mod_updates_state so a mod updated
#     from the Mods tab never shows a stale "Update: vX" here.
#   _updates_tab_log: already-timestamped Activity lines, re-rendered on build.
#   _updates_tab_dl_in_flight: count of this tab's row downloads currently
#     awaiting; "Check for updates" only re-enables when it reaches zero (a
#     single completion used to re-enable it while a second download was still
#     running, letting a fresh check reset the downloading row).
var _updates_tab_status: Dictionary = {}
var _updates_tab_log: Array[String] = []
# Oldest lines drop off past this many; see add_log in build_updates_tab.
const _UPDATES_LOG_MAX := 200
var _updates_tab_dl_in_flight: int = 0
# Live references to the current build's list scroller / check button so the
# rebuild can carry scroll position and download completions can re-enable the
# CURRENT check button even after the one they captured was freed. Cleared on
# launcher close with the other _ui_* node refs.
var _ui_updates_scroll: ScrollContainer = null
var _ui_updates_check_btn: Button = null

# Arm an Updates-tab row for an available update: amber status, visible
# Download button, wired download handler. Shared by check_updates_for_ui (a
# fresh check result) and build_updates_tab (re-arming from _mod_updates_state
# after the on-show rebuild). State writes happen unconditionally; UI touches
# are guarded per node because the row may have been freed by a mid-check
# rebuild.
func _updates_arm_row_update(info: Dictionary, latest_v: String, add_log: Callable) -> void:
	var pre_entry: Dictionary = info.get("entry", {})
	var pk: String = str(pre_entry.get("profile_key", "")) if not pre_entry.is_empty() else ""
	# Surface state via _mod_updates_state so the Mods tab can show the
	# per-row badge without re-querying, and so the on-show rebuild of this
	# tab re-arms the row instead of wiping the result.
	if pk != "":
		_mod_updates_state[pk] = {
			"latest_version": latest_v,
			"current_version": str(info["version"]),
			"mw_id": int(info["mw_id"]),
			"full_path": str(info["full_path"]),
			"mod_name": str(info["mod_name"]),
		}
		# An available update supersedes any stored terminal status.
		_updates_tab_status.erase(pk)
	var lbl: Label = info["label"]
	var dl_btn: Button = info["dl_btn"]
	if is_instance_valid(lbl):
		# Amber = the update signal. Tooltip mirrors the text: long prerelease
		# strings ellipsize in the 160px column (label is MOUSE_FILTER_PASS at
		# creation).
		lbl.text = "Update: v" + latest_v
		lbl.tooltip_text = lbl.text
		lbl.add_theme_color_override("font_color", COL_AMBER)
	if not is_instance_valid(dl_btn):
		return
	dl_btn.modulate.a = 1.0
	dl_btn.disabled = false
	dl_btn.mouse_filter = Control.MOUSE_FILTER_STOP
	var full_path: String = str(info["full_path"])
	var mw_id: int = int(info["mw_id"])
	var mod_name: String = str(info["mod_name"])
	var new_ver: String = latest_v
	# Guard key for _mod_update_in_flight -- the SAME dictionary the Mods-tab
	# badge path uses, because both surfaces target the same mod file (and the
	# same .download temp / .bak rollback paths). Path fallback only for the
	# unexpected entry-less row.
	var guard_key: String = pk if pk != "" else full_path
	# Disconnect previous connections so repeated checks don't stack callbacks.
	for c in dl_btn.pressed.get_connections():
		dl_btn.pressed.disconnect(c["callable"])
	dl_btn.pressed.connect(func():
		# Refuse a second concurrent download of the same mod: the Mods-tab
		# badge, or this same row on a pre-rebuild Updates tab, may already be
		# running one -- two concurrent runs delete each other's temp/backup
		# files mid-flight and corrupt the rollback.
		if _mod_update_in_flight.has(guard_key):
			return
		_mod_update_in_flight[guard_key] = true
		_updates_tab_dl_in_flight += 1
		dl_btn.disabled = true
		dl_btn.text = "Downloading..."
		if is_instance_valid(lbl):
			lbl.text = "Downloading..."
			lbl.tooltip_text = lbl.text
			lbl.add_theme_color_override("font_color", COL_AMBER)
		if is_instance_valid(_ui_updates_check_btn):
			_ui_updates_check_btn.disabled = true
		# Re-resolve live: the Mods-tab badge may have updated/renamed this
		# file since the Updates tab was built, orphaning the captured path.
		var live_path: String = _live_full_path(pk, full_path)
		var result: Dictionary = await download_and_replace_mod(live_path, mw_id)
		# -- State bookkeeping FIRST, unconditionally. The on-show rebuild can
		# free every node this closure captured while the download is in
		# flight; an early return on node validity here used to silently drop
		# ALL of it, leaving the tab offering an update that was already
		# installed (whose retry then hits the file-collision error until a
		# rescan). UI touches are guarded individually below instead.
		_mod_update_in_flight.erase(guard_key)
		_updates_tab_dl_in_flight = maxi(0, _updates_tab_dl_in_flight - 1)
		# Only re-enable the (current) check button when NO downloads remain --
		# the first of two completions used to re-enable it mid-download.
		if _updates_tab_dl_in_flight == 0 and is_instance_valid(_ui_updates_check_btn):
			_ui_updates_check_btn.disabled = false
		if result.get("ok", false):
			# Update cached version so next Check won't re-flag this mod.
			info["version"] = new_ver
			# Reflect the on-disk rename in the in-memory entry so the next
			# discovery pass (and any subsequent UI rebuild before relaunch)
			# point at the right archive instead of the old filename that no
			# longer exists. Write through the LIVE entry dict: a rescan may
			# have replaced _ui_mod_entries since this row was built.
			var new_path: String = str(result.get("new_path", full_path))
			var new_fn: String = str(result.get("new_file_name", full_path.get_file()))
			info["full_path"] = new_path
			var entry_ref: Dictionary = _live_entry_for_profile_key(pk, pre_entry)
			if not entry_ref.is_empty():
				entry_ref["full_path"] = new_path
				entry_ref["file_name"] = new_fn
			if pk != "":
				# Drop the shared badge state so the Mods tab stops offering an
				# update that was just installed, and persist the terminal
				# status so a rebuilt tab shows the outcome.
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
			# Surface the REAL failure cause ("A different file named X is
			# already in the mods folder", "file may be locked", rate-limit
			# copy) instead of always blaming the connection -- retrying a
			# non-network problem forever is the trap the old copy set.
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

# Scroll the restored Activity log to its newest line one frame later -- the
# fresh labels have no layout on the build frame, so an immediate
# scroll_vertical set clamps against a zero content height.
func _updates_scroll_log_to_bottom(sc: ScrollContainer) -> void:
	await get_tree().process_frame
	if is_instance_valid(sc):
		sc.scroll_vertical = 999999

func build_updates_tab() -> Control:
	var margin := _make_tab_margin()

	var container := VBoxContainer.new()
	container.add_theme_constant_override("separation", SP_M)
	margin.add_child(container)

	var toolbar := HBoxContainer.new()
	toolbar.add_theme_constant_override("separation", SP_M)
	container.add_child(toolbar)

	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	toolbar.add_child(spacer)

	# The tab's one primary action.
	var check_btn := Button.new()
	check_btn.text = "Check for updates"
	style_primary_button(check_btn)
	# A tab rebuilt mid-download must not offer a check that would reset the
	# downloading row; the last completing download re-enables this via the
	# _ui_updates_check_btn member.
	if _updates_tab_dl_in_flight > 0:
		check_btn.disabled = true
	toolbar.add_child(check_btn)
	_ui_updates_check_btn = check_btn

	container.add_child(HSeparator.new())

	# Column headers: quiet meta labels over the list.
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

	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	container.add_child(scroll)
	_ui_updates_scroll = scroll

	var list := VBoxContainer.new()
	list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(list)

	# { label, version, mw_id, dl_btn, full_path, mod_name }
	var status_info: Dictionary = {}

	for entry in _ui_mod_entries:
		var cfg: ConfigFile = entry["cfg"]
		if cfg == null:
			continue
		var version := str(cfg.get_value("mod", "version", ""))
		var mw_id := 0
		if cfg.has_section_key("updates", "modworkshop"):
			mw_id = int(str(cfg.get_value("updates", "modworkshop", "")))

		var row := HBoxContainer.new()
		list.add_child(row)

		# Name column: mod name + last-modified date sub-label.
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
		# A long prerelease string ("v2026.1.0-beta.3") must not push the
		# Status/Action columns out of alignment -- trim it to the column.
		ver_lbl.clip_text = true
		ver_lbl.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		ver_lbl.tooltip_text = ver_lbl.text
		ver_lbl.mouse_filter = Control.MOUSE_FILTER_PASS
		ver_lbl.custom_minimum_size.x = 90
		row.add_child(ver_lbl)

		var status_lbl := Label.new()
		status_lbl.custom_minimum_size.x = 160
		# Status text is state-driven ("Update: v...") and can outgrow the
		# column with long version strings; trim instead of shoving the
		# Action column sideways.
		status_lbl.clip_text = true
		status_lbl.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		status_lbl.add_theme_color_override("font_color", COL_TEXT_DIM)
		# PASS unconditionally: labels default to MOUSE_FILTER_IGNORE which
		# silently suppresses tooltips, and the check flow writes long state
		# text ("Update: v...") whose ellipsis needs a full-text tooltip.
		status_lbl.mouse_filter = Control.MOUSE_FILTER_PASS
		if entry["ext"] == "folder":
			# Dev folders are the user's working copy on disk; downloading an
			# archive would land a duplicate next to the folder. Explain why
			# there is no Download button instead of offering one that misfires.
			status_lbl.text = "Dev folder"
			status_lbl.tooltip_text = "Dev folders load straight from your mods folder, so there is nothing to download. Update downloads only apply to mods installed as archives."
		elif mw_id == 0 or version == "":
			# Explain WHY this row cannot be checked (the adjacent Dev-folder
			# state already explains itself; this one used to sit unexplained).
			status_lbl.text = "No update info"
			status_lbl.tooltip_text = "This mod's mod.txt has no ModWorkshop update info ([updates] modworkshop= plus [mod] version=), so it cannot be checked. Add both fields to enable update checks."
		else:
			status_lbl.text = "--"
		row.add_child(status_lbl)

		# Always add dl_btn to preserve column width. Use modulate.a to
		# hide it visually without collapsing its layout slot.
		var dl_btn := Button.new()
		dl_btn.text = "Update"
		dl_btn.custom_minimum_size.x = 90
		dl_btn.modulate.a = 0.0
		dl_btn.disabled = true
		dl_btn.mouse_filter = Control.MOUSE_FILTER_IGNORE
		row.add_child(dl_btn)

		list.add_child(HSeparator.new())

		if mw_id > 0 and version != "" and entry["ext"] != "folder":
			# Hold a reference to the underlying _ui_mod_entries dict so the
			# download callback can update full_path / file_name in place
			# when a successful update lands the archive under a new name.
			# GDScript dicts are reference-typed, so writing through here
			# mutates the canonical entry the next discovery pass sees.
			status_info[entry["file_name"]] = {
				"label": status_lbl, "ver_lbl": ver_lbl, "version": version, "mw_id": mw_id,
				"dl_btn": dl_btn, "full_path": entry["full_path"],
				"mod_name": entry["mod_name"], "entry": entry,
			}

	if list.get_child_count() == 0:
		var lbl := Label.new()
		lbl.text = "No mods to check yet.\nGet mods from the Browse tab, then check for updates here."
		lbl.add_theme_color_override("font_color", COL_TEXT_DIM)
		lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		list.add_child(lbl)

	# -- Activity log ----------------------------------------------------------

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
		# Persist FIRST: a download can finish after this tab was rebuilt
		# (freeing log_list); the line must survive into the restored log.
		# Capped: the log now survives every rebuild, and each rebuild
		# re-renders one Label per stored line, so an unbounded array would
		# make repeated checks/downloads cost more on every tab switch.
		_updates_tab_log.append(line)
		while _updates_tab_log.size() > _UPDATES_LOG_MAX:
			_updates_tab_log.remove_at(0)
		if not is_instance_valid(log_list):
			return
		log_list.add_child(log_label.call(line))
		# Defer by a frame: the label just added has no layout yet, so an
		# immediate set clamps against the pre-append content height and the
		# view lags one message behind.
		_updates_scroll_log_to_bottom(log_scroll)

	# Restore Activity lines from earlier checks/downloads this session -- the
	# tab is rebuilt on every show and used to wipe the log. Scroll to the
	# newest line one frame later: the restored labels have no layout yet, so
	# an immediate set would clamp to 0.
	for line in _updates_tab_log:
		log_list.add_child(log_label.call(line))
	if not _updates_tab_log.is_empty():
		_updates_scroll_log_to_bottom(log_scroll)

	# Restore per-row results from earlier checks this session (the rebuild
	# used to reset every row to "--", forcing a re-check -- and a re-spend of
	# rate budget -- just to re-see results). Precedence: a download in flight
	# renders the row inert (a fresh live Update button here would allow a
	# second concurrent download of the same file); then an available update
	# re-arms from _mod_updates_state; then any stored terminal status.
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
			row_lbl.add_theme_color_override("font_color", COL_AMBER)
			var b: Button = info["dl_btn"]
			b.modulate.a = 1.0
			b.disabled = true
			b.text = "Downloading..."
			continue
		if _mod_updates_state.has(pk):
			var upd: Dictionary = _mod_updates_state[pk]
			var latest_known := str(upd.get("latest_version", ""))
			# Re-verify against the row's CURRENT version -- the file may have
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
		# The launcher can close (Launch clicked) while the check is in
		# flight; the button is freed with it. Mirrors the Mods-tab guard.
		if not is_instance_valid(check_btn):
			return
		check_btn.disabled = false
		check_btn.text = "Check for updates"
	)

	return margin

# Run an update check against every installed mod with valid [updates]
# modworkshop=N + version=. Populates the module-scope _mod_updates_state
# with entries for mods that have a newer version available. Returns a
# summary dict {checked, with_updates, errors}. Safe to call from any tab.
func _run_updates_check_for_mods() -> Dictionary:
	if _mod_updates_check_in_progress:
		return {"checked": 0, "with_updates": 0, "errors": 0}
	_mod_updates_check_in_progress = true
	var summary := {"checked": 0, "with_updates": 0, "errors": 0}
	# Build a list of mods worth checking: must have both modworkshop= and version=.
	var pending: Array = []
	for entry in _ui_mod_entries:
		var cfg: ConfigFile = entry.get("cfg")
		if cfg == null:
			continue
		# Dev folders cannot take a downloaded archive (it would land as a
		# duplicate beside the folder), so never flag them for updates.
		if str(entry.get("ext", "")) == "folder":
			continue
		if not cfg.has_section_key("updates", "modworkshop"):
			continue
		var mw_id := int(str(cfg.get_value("updates", "modworkshop", "0")))
		if mw_id <= 0:
			continue
		var version := str(cfg.get_value("mod", "version", "")).strip_edges()
		if version == "":
			continue
		pending.append({
			"profile_key": str(entry.get("profile_key", "")),
			"mw_id": mw_id,
			"version": version,
			"full_path": str(entry.get("full_path", "")),
			"mod_name": str(entry.get("mod_name", "?")),
		})
	if pending.is_empty():
		_mod_updates_check_in_progress = false
		return summary
	# Batched fetch through the existing helper (handles batching, retry,
	# user-agent, etc.).
	var ids: Array[int] = []
	for p in pending:
		ids.append(int((p as Dictionary)["mw_id"]))
	var latest := await fetch_latest_modworkshop_versions(ids)
	for p in pending:
		summary["checked"] += 1
		var info: Dictionary = p
		var raw = latest.get(str(info["mw_id"]), null)
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
			"mw_id": info["mw_id"],
			"full_path": info["full_path"],
			"mod_name": info["mod_name"],
		}
	_mod_updates_check_in_progress = false
	return summary


func check_updates_for_ui(status_info: Dictionary, add_log: Callable, _check_btn: Button) -> void:
	var ids: Array[int] = []
	for fn in status_info:
		ids.append(status_info[fn]["mw_id"])
	if ids.is_empty():
		# With only dev-folder or id-less mods installed the button used to
		# flash "Checking for updates..." and revert with zero feedback; say
		# why nothing happened (same copy as the Mods-tab toast).
		add_log.call("No installed mods have ModWorkshop update info, so there is nothing to check.")
		return

	var latest := await fetch_latest_modworkshop_versions(ids)

	# A check just ran, so _mod_updates_state may have gained or lost entries.
	# This function runs from the Updates tab, where the Mods tab isn't visible
	# to refresh its own badges -- flag it so a later switch to the Mods tab
	# rebuilds and shows the promised per-row update badges.
	_mods_badges_dirty = true

	# State bookkeeping below must survive a mid-check tab rebuild (switching
	# away and back frees every node captured in status_info): persisted state
	# is written unconditionally, UI touches are guarded per node. The old
	# whole-function bail on a freed button silently dropped the completed
	# check's results; the rebuilt tab now re-renders them from
	# _mod_updates_state / _updates_tab_status.
	for fn: String in status_info:
		var info: Dictionary = status_info[fn]
		var lbl: Label = info["label"]
		var pre_entry: Dictionary = info.get("entry", {})
		var pk: String = str(pre_entry.get("profile_key", "")) if not pre_entry.is_empty() else ""
		var latest_v = latest.get(str(info["mw_id"]), null)
		if latest_v == null:
			# Rate-limit hint (spec section 7: what happened + what to do)
			# lives in the tooltip -- the full sentence would ellipsize in
			# this narrow column. Falls back to the plain text when no MWS
			# cooldown is armed.
			var fail_tip := mws_error_status("Check failed")
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
			# Server has a newer version -- paint the row and wire its Download
			# button through the shared helper (also used by the on-show
			# rebuild to re-arm rows from _mod_updates_state).
			_updates_arm_row_update(info, str(latest_v), add_log)

# ----- modloader self-update check ----------------------------------------

# Fire-and-forget from show_mod_ui. Hits the ModWorkshop versions API for
# our own mod id, compares the result against MODLOADER_VERSION, and on a
# newer release: recolors the always-visible launch-row version LinkButton
# (and rewrites its text), and pops a one-shot
# dialog the first session each new version is detected. All UI mutations
# guard on is_instance_valid because the launcher may close before the
# HTTP request returns.
func _check_modloader_update_async() -> void:
	if MODLOADER_MODWORKSHOP_ID <= 0:
		return
	var ids: Array[int] = [MODLOADER_MODWORKSHOP_ID]
	var latest_map: Dictionary = await fetch_latest_modworkshop_versions(ids)
	var raw = latest_map.get(str(MODLOADER_MODWORKSHOP_ID), null)
	if raw == null:
		return
	var latest := str(raw)
	if latest.is_empty():
		return
	_modloader_latest_version = latest
	# Exact match first: when ModWorkshop publishes the very version we are
	# running (including a prerelease like "3.3.0-beta.1"), there is nothing
	# to update to -- without this the base-version compare below would flag
	# our own version as an update every session.
	if latest == MODLOADER_VERSION:
		return
	# Prerelease-aware gate. compare_versions() mis-parses "3.3.0-beta.1" as
	# 3.3.0.1, which ranks it ABOVE the eventual "3.3.0" stable (muting the
	# prompt forever) AND above an older "3.3.0-beta.2" install (offering a
	# downgrade). Semver rule: a prerelease precedes its release. So compare
	# base versions first, then break equal-base ties on the prerelease tails:
	# a stable supersedes any same-base prerelease; between two prereleases,
	# only a strictly higher one is an update. Dormant on stable builds (no
	# "-" in MODLOADER_VERSION -> installed_pre empty -> identical behavior).
	var installed_base := MODLOADER_VERSION.split("-")[0]
	var latest_base := latest.split("-")[0]
	var base_cmp := compare_versions(latest_base, installed_base)
	if base_cmp < 0:
		return  # installed base is newer
	if base_cmp == 0:
		# Same base version -- decide on the prerelease suffixes. compare_versions
		# can't do this: it parses "3.3.0-beta.1" as 3.3.0.1 (the "-beta" segment
		# reads as 0), which would rank ANY same-base prerelease above the base
		# and even flag an OLDER prerelease as an update (a downgrade prompt).
		var installed_pre := MODLOADER_VERSION.substr(installed_base.length()).lstrip("-")
		var latest_pre := latest.substr(latest_base.length()).lstrip("-")
		if installed_pre == "":
			return  # installed is the stable base; a same-base prerelease is not an upgrade
		if latest_pre == "":
			pass  # latest is the stable release of our prerelease -> offer it
		elif _compare_prerelease(latest_pre, installed_pre) <= 0:
			return  # latest prerelease is the same as or older than installed

	if is_instance_valid(_ui_update_alert_btn):
		_ui_update_alert_btn.text = "v%s available -- click to open ModWorkshop" % latest
		# Amber is the update signal (spec: the one accent); an available
		# update is a notice, not an error, so no red here.
		_ui_update_alert_btn.add_theme_color_override("font_color", COL_AMBER)
		_ui_update_alert_btn.add_theme_color_override("font_hover_color", COL_TEXT_HI)

	# Pop the dialog only the first session this specific new version is
	# seen. Stays quiet on subsequent launches until ModWorkshop ships a
	# newer one. The launch-row alert remains visible regardless.
	var last_seen := _modloader_update_last_seen_version()
	if last_seen != latest:
		_show_modloader_update_dialog(latest)

func _modloader_update_last_seen_version() -> String:
	return str(_get_ui_cfg_value("modloader_update", "last_seen_version", ""))

func _modloader_update_mark_seen(latest: String) -> void:
	_set_ui_cfg_value("modloader_update", "last_seen_version", latest)

# One-shot popup the first session each new modloader version is detected.
# "Open Page" launches the ModWorkshop browser tab; either action writes the
# latest version into mod_config.cfg so the dialog stays quiet on subsequent
# launches until ModWorkshop ships another version.
func _show_modloader_update_dialog(latest: String) -> void:
	if not is_instance_valid(_ui_window):
		return
	var d := ConfirmationDialog.new()
	d.title = "Mod Loader update available"
	d.ok_button_text = "Open page"
	d.cancel_button_text = "Dismiss"
	d.dialog_autowrap = true
	d.min_size = Vector2(440, 120)
	d.dialog_text = "A newer version of the Mod Loader is available on ModWorkshop.\n\n" \
			+ "    Installed: v%s\n    Available: v%s\n\n" % [MODLOADER_VERSION, latest] \
			+ "Open the ModWorkshop page to download?"
	_attach_ui_dialog(d)
	d.exclusive = true
	d.always_on_top = true
	_connect_dialog_exits(d,
		func():
			OS.shell_open(MODWORKSHOP_PAGE_URL_TEMPLATE % str(MODLOADER_MODWORKSHOP_ID))
			_modloader_update_mark_seen(latest)
			d.queue_free(),
		func():
			_modloader_update_mark_seen(latest)
			d.queue_free()
	)
	d.popup_centered()
