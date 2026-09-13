## ----- ui_mods.gd -----
## The Mods tab: toolbar, mod rows, host meta sidecar, security findings.

var _mods_filter_focus_pending: bool = false

# Mods-tab host meta memo, keyed by host_ref_key. The seam caches only
# successful responses, so failed refs would refetch on every rebuild; memo
# successes for the session and gate failures behind a retry window (one
# attempt per mod per minute).
var _mods_meta_by_key: Dictionary = {}       # ref_key -> ModSummary or ModDetail (successes only)
var _mods_meta_retry_at: Dictionary = {}     # ref_key -> ticks_msec before which not to refetch

# Sidecar bookkeeping: ref_key -> unix time of the last real detail fetch.
# Only keys here reach the on-disk sidecar; a stale stamp triggers the
# background soft refresh. _mods_meta_sidecar_loaded gates the lazy read.
var _mods_meta_saved_at: Dictionary = {}
var _mods_meta_sidecar_loaded: bool = false

# Tear down and rebuild the Mods tab in place. Preserves the current tab so
# a Browse-row toggle does not yank the user onto the Mods tab.
func _rebuild_mods_tab(tabs: TabContainer) -> void:
	var old := tabs.get_node_or_null(UI_TAB_MODS)
	if old == null:
		return
	_rebuilding_tab_in_place = true
	var saved_scroll := 0
	if is_instance_valid(_ui_mods_scroll):
		saved_scroll = _ui_mods_scroll.scroll_vertical
	var idx := old.get_index()
	# Capture the current tab by name: remove_child shifts sibling indices.
	var current_tab_node := tabs.get_tab_control(tabs.current_tab) if tabs.get_tab_count() > 0 else null
	var current_tab_name := str(current_tab_node.name) if current_tab_node != null else ""
	tabs.remove_child(old)
	old.queue_free()
	var new_tab := build_mods_tab(tabs)
	new_tab.name = UI_TAB_MODS
	tabs.add_child(new_tab)
	tabs.move_child(new_tab, idx)
	# Restore by name; if the previous tab was Mods, land on the rebuilt one.
	for i in range(tabs.get_tab_count()):
		var ctrl := tabs.get_tab_control(i)
		if ctrl != null and ctrl.name == current_tab_name:
			tabs.current_tab = i
			break
	_rebuilding_tab_in_place = false
	# Profile/dev-mode changes bypass the per-row checkbox handler.
	refresh_launch_button_label()
	if saved_scroll > 0:
		_restore_mods_scroll(saved_scroll)

# One frame later: scroll_vertical set before layout clamps to zero.
func _restore_mods_scroll(saved_scroll: int) -> void:
	await get_tree().process_frame
	if is_instance_valid(_ui_mods_scroll):
		_ui_mods_scroll.scroll_vertical = saved_scroll

## Whether the scanner could not read part of this mod. Distinct from a risk
## verdict; both otherwise render identically to the user.
func _entry_has_unscannable_code(entry: Dictionary) -> bool:
	var findings: Variant = entry.get("security_findings")
	if not (findings is Array):
		return false
	for f in (findings as Array):
		if f is Dictionary and str((f as Dictionary).get("rule", "")) == "compiled_script":
			return true
	return false


func _show_security_findings_dialog(entry: Dictionary) -> void:
	var findings: Array = entry.get("security_findings", [])
	if findings.is_empty():
		return
	var d := AcceptDialog.new()
	var mod_name := str(entry.get("mod_name", "?"))
	# Calling compiled-only mods suspicious would accuse legitimate builds.
	var accusing := int(entry.get("risk_level", 0)) == 2
	d.title = ("Suspicious code in " if accusing else "Not fully scanned: ") + mod_name
	d.ok_button_text = "Close"
	d.min_size = Vector2(580, 420)

	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size = Vector2(560, 380)
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	d.add_child(scroll)

	var body := VBoxContainer.new()
	body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	body.add_theme_constant_override("separation", SP_L)
	scroll.add_child(body)

	var intro := Label.new()
	if accusing:
		intro.text = "The scanner found patterns in this mod's code that are commonly used by malware " \
				+ "(obfuscated string decoding combined with process spawning, anti-debug calls, etc.). " \
				+ "If you don't trust this mod, do not enable it."
	else:
		intro.text = "The scanner did not find anything dangerous, but it could not read part of " \
				+ "this mod -- compiled scripts are opaque to it. This is not an accusation: " \
				+ "plenty of legitimate mods ship compiled code. It only means the check below " \
				+ "is incomplete, so judge this mod by whether you trust its author."
	intro.add_theme_color_override("font_color", COL_ERR if accusing else COL_TEXT_DIM)
	intro.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	intro.add_theme_font_size_override("font_size", FS_BODY)
	body.add_child(intro)

	body.add_child(HSeparator.new())

	for f: Dictionary in findings:
		var card := VBoxContainer.new()
		card.add_theme_constant_override("separation", SP_S)
		body.add_child(card)

		var rule_lbl := Label.new()
		rule_lbl.text = str(f.get("rule", "?"))
		rule_lbl.add_theme_color_override("font_color", COL_ERR)
		rule_lbl.add_theme_font_size_override("font_size", FS_HEAD)
		card.add_child(rule_lbl)

		var desc_lbl := Label.new()
		desc_lbl.text = str(f.get("description", ""))
		desc_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		desc_lbl.add_theme_font_size_override("font_size", FS_BODY)
		card.add_child(desc_lbl)

		var loc := str(f.get("file", "?"))
		if int(f.get("line", 0)) > 0:
			loc += ":" + str(f.get("line"))
		var loc_lbl := Label.new()
		loc_lbl.text = loc
		loc_lbl.add_theme_color_override("font_color", COL_TEXT_DIM)
		loc_lbl.add_theme_font_size_override("font_size", FS_META)
		card.add_child(loc_lbl)

		var preview := str(f.get("preview", ""))
		if not preview.is_empty():
			var pre_lbl := Label.new()
			pre_lbl.text = "  " + preview
			pre_lbl.add_theme_color_override("font_color", COL_OK)
			pre_lbl.add_theme_font_size_override("font_size", FS_BODY)
			pre_lbl.autowrap_mode = TextServer.AUTOWRAP_OFF
			pre_lbl.clip_text = true
			pre_lbl.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
			pre_lbl.tooltip_text = preview
			pre_lbl.mouse_filter = Control.MOUSE_FILTER_PASS
			card.add_child(pre_lbl)

		body.add_child(HSeparator.new())

	_attach_ui_dialog(d)
	_wire_accept_dismiss(d)
	d.popup_centered()


# Per-row Remove confirmation, then delete, strip profile state, re-scan and rebuild.
func _show_remove_mod_confirm(entry: Dictionary, tabs: TabContainer) -> void:
	var d := ConfirmationDialog.new()
	d.title = "Remove mod"
	var size_line := ""
	var path: String = str(entry.get("full_path", ""))
	if FileAccess.file_exists(path):
		var f := FileAccess.open(path, FileAccess.READ)
		if f != null:
			size_line = "\nSize: " + _format_size(f.get_length())
			f.close()
	d.dialog_text = "Permanently delete \"%s\"?\n\nFile: %s%s\n\nThis will:\n  - Delete the file from disk\n  - Remove the mod from EVERY profile, not just \"%s\"\n\nThis cannot be undone." % [
		str(entry.get("mod_name", "?")),
		str(entry.get("file_name", "?")),
		size_line,
		_active_profile,
	]
	d.ok_button_text = "Delete mod"
	style_dialog_danger_button(d.get_ok_button())
	_attach_ui_dialog(d)
	_connect_dialog_exits(d,
		func():
			d.queue_free()
			if _delete_mod_file_and_cleanup(entry):
				_reload_entries_for_active_profile()
				_rebuild_mods_tab(tabs)
			else:
				_show_error_dialog("Could not delete mod", "Could not remove %s. If this mod is enabled, its archive is mounted and the file stays locked while the game is open -- disable it, relaunch the game, then delete." % str(entry.get("file_name", "the mod"))),
		func(): d.queue_free())
	d.popup_centered()

# Shared tail for dependency quick actions: recompute, persist, refresh.
# Rebuild is deferred so the mid-signal control isn't torn down.
func _after_dep_action(tabs: TabContainer) -> void:
	_refresh_dependency_status()
	_save_ui_config()
	refresh_launch_button_label()
	(func(): _rebuild_mods_tab(tabs)).call_deferred()

# Cached summary for a mod from its host's Browse landing snapshot: an
# instant thumbnail and author with no network. {} when not cached.
func _mods_cached_summary(ref: Dictionary) -> Dictionary:
	var key := host_ref_key(ref)
	if key == "":
		return {}
	var snap := _browse_landing_snapshot(str(ref["provider"]))
	if snap.is_empty():
		return {}
	for sec_v in (snap["sections"] as Array):
		if not (sec_v is Dictionary):
			continue
		var rows_v: Variant = (sec_v as Dictionary).get("rows")
		if not (rows_v is Array):
			continue
		for row_v in (rows_v as Array):
			if not (row_v is Dictionary):
				continue
			var row: Dictionary = row_v
			if row.get("ref") is Dictionary and host_ref_key(row["ref"]) == key:
				return row
	return {}

# Persisted per-mod meta sidecar so relaunches do not re-fetch every mod's
# detail: {"<ref_key>": {"mod": <ModDetail>, "saved_at": unix}} under
# user://mws_cache/ (deny-listed for modpack overrides). Stale entries soft-refresh.
const _MODS_META_SIDECAR_PATH := "user://mws_cache/mods_meta_v2.json"
const _MODS_META_REFRESH_SEC := 86400

# True when a record has every field the detail dialog indexes directly.
func _mods_meta_record_complete(mod: Dictionary) -> bool:
	for k in host_empty_summary():
		if not mod.has(k):
			return false
	return mod["ref"] is Dictionary and mod["thumbnail"] is Dictionary and host_ref_valid(mod["ref"])

# Lazy one-time seed of the meta memo from the sidecar. Every field is
# shape-checked so a hand-edited file skips entries rather than crash.
func _mods_meta_sidecar_load() -> void:
	if _mods_meta_sidecar_loaded:
		return
	_mods_meta_sidecar_loaded = true
	if not FileAccess.file_exists(_MODS_META_SIDECAR_PATH):
		return
	var f := FileAccess.open(_MODS_META_SIDECAR_PATH, FileAccess.READ)
	if f == null:
		return
	var parsed: Variant = JSON.parse_string(f.get_as_text())
	f.close()
	if not (parsed is Dictionary):
		return
	for key_v in (parsed as Dictionary):
		var key := str(key_v)
		if host_ref_from_key(key).is_empty():
			continue
		var entry_v: Variant = (parsed as Dictionary)[key_v]
		if not (entry_v is Dictionary):
			continue
		var mod_v: Variant = (entry_v as Dictionary).get("mod")
		if not (mod_v is Dictionary) or not _mods_meta_record_complete(mod_v):
			continue
		# saved_at arrives as a float after the JSON round-trip; int() it.
		var saved_v: Variant = (entry_v as Dictionary).get("saved_at", 0)
		if not (saved_v is int or saved_v is float) or int(saved_v) <= 0:
			continue
		# Never clobber fresher data a fetch already memoized this session.
		if not _mods_meta_by_key.has(key):
			_mods_meta_by_key[key] = mod_v
			_mods_meta_saved_at[key] = int(saved_v)

# Stamp `key` as freshly fetched and rewrite the sidecar from the memo. Only
# keys with a saved_at stamp persist; snapshot-sourced entries stay session-only.
func _mods_meta_sidecar_store(key: String) -> void:
	_mods_meta_saved_at[key] = int(Time.get_unix_time_from_system())
	var out := {}
	for k in _mods_meta_saved_at:
		var d: Variant = _mods_meta_by_key.get(k, {})
		if d is Dictionary and not (d as Dictionary).is_empty():
			out[str(k)] = {
				"mod": d,
				"saved_at": int(_mods_meta_saved_at[k]),
			}
	DirAccess.make_dir_recursive_absolute(_MODS_META_SIDECAR_PATH.get_base_dir())
	var f := FileAccess.open(_MODS_META_SIDECAR_PATH, FileAccess.WRITE)
	if f == null:
		return
	f.store_string(JSON.stringify(out))
	f.close()

# Paint host meta onto the current Mods-tab rows for `key`, resolved through
# _mods_meta_nodes at paint time. No entry = memoize only. Idempotent per row.
func _mods_apply_host_meta(key: String, data: Dictionary) -> void:
	# One host mod can back several rows (.vmz copy plus dev-folder copy).
	var rows_v: Variant = _mods_meta_nodes.get(key)
	if not (rows_v is Array):
		return
	for nodes_v in (rows_v as Array):
		if not (nodes_v is Dictionary):
			continue
		var nodes: Dictionary = nodes_v
		var holder_v: Variant = nodes.get("holder")
		if holder_v is Dictionary:
			(holder_v as Dictionary)["data"] = data
		var thumb_v: Variant = nodes.get("thumb")
		if is_instance_valid(thumb_v) and thumb_v is TextureRect:
			var thumb_rect: TextureRect = thumb_v
			var image_v: Variant = data.get("thumbnail")
			if image_v is Dictionary and str((image_v as Dictionary).get("url", "")) != "":
				# The caption stays until _set_thumb_ready clears it.
				_browse_load_thumbnail_async(thumb_rect, image_v)
			else:
				_set_thumb_failed(thumb_rect, false)
		var col_v: Variant = nodes.get("name_col")
		if is_instance_valid(col_v) and col_v is VBoxContainer:
			var name_col: VBoxContainer = col_v
			if not name_col.has_node("HostAuthorLabel"):
				var author := str(data.get("author_name", ""))
				if author != "":
					var author_lbl := _make_sub_label("by " + author, COL_TEXT_DIM, "")
					author_lbl.name = "HostAuthorLabel"
					name_col.add_child(author_lbl)
					name_col.move_child(author_lbl, 1)  # right under the name

# Paint the "load failed" overlay for a mod whose meta fetch failed. Only
# for keys with no memoized data; a failed soft refresh keeps its texture.
func _mods_paint_meta_failed(key: String) -> void:
	var rows_v: Variant = _mods_meta_nodes.get(key)
	if not (rows_v is Array):
		return
	for nodes_v in (rows_v as Array):
		if not (nodes_v is Dictionary):
			continue
		var thumb_v: Variant = (nodes_v as Dictionary).get("thumb")
		if is_instance_valid(thumb_v) and thumb_v is TextureRect:
			_set_thumb_failed(thumb_v as TextureRect, true)

# Serialized background meta fetches: parallel per-row detail calls could
# drain a host's rate budget. One drain loop; a host in cooldown is skipped.
var _mods_meta_fetch_queue: Array[Dictionary] = []
var _mods_meta_fetch_active := false

func _mods_meta_fetch_enqueue(ref: Dictionary) -> void:
	# No dedupe needed: the retry window is armed before the enqueue.
	_mods_meta_fetch_queue.append(ref)
	if _mods_meta_fetch_active:
		return
	_mods_meta_fetch_active = true
	while not _mods_meta_fetch_queue.is_empty():
		var next: Dictionary = _mods_meta_fetch_queue.pop_front()
		var provider := str(next["provider"])
		if host_rate_cooldown_seconds(provider) > 0:
			continue
		var key := host_ref_key(next)
		var res := await host_get_mod(next)
		var fetch_ok := false
		if res["ok"] and res["data"] is Dictionary and _mods_meta_record_complete(res["data"]):
			fetch_ok = true
			_mods_meta_by_key[key] = res["data"]
			_mods_meta_sidecar_store(key)
			_mods_apply_host_meta(key, res["data"])
		if not fetch_ok:
			# Cold-path failure: caption "load failed"; a failed soft refresh keeps its texture.
			var memo_v: Variant = _mods_meta_by_key.get(key)
			if not (memo_v is Dictionary) or (memo_v as Dictionary).is_empty():
				_mods_paint_meta_failed(key)
	_mods_meta_fetch_active = false

# Populate an installed row's host thumbnail and author and stash the record
# for the detail dialog: memo first, then the Browse snapshot, then a queued fetch.
func _mods_load_host_meta(ref: Dictionary) -> void:
	var key := host_ref_key(ref)
	if key == "":
		return
	_mods_meta_sidecar_load()
	var data: Dictionary = _mods_meta_by_key.get(key, {})
	if not data.is_empty():
		# Memoized: paint synchronously so the row does not sit gray.
		_mods_apply_host_meta(key, data)
		# Soft refresh: a sidecar entry older than a day re-fetches in the
		# background; saved_at == 0 means snapshot-sourced, never refreshed.
		var saved_at := int(_mods_meta_saved_at.get(key, 0))
		if saved_at <= 0 \
				or int(Time.get_unix_time_from_system()) - saved_at < _MODS_META_REFRESH_SEC:
			return
		if Time.get_ticks_msec() < int(_mods_meta_retry_at.get(key, 0)):
			return
		_mods_meta_retry_at[key] = Time.get_ticks_msec() + 60000
		_mods_meta_fetch_enqueue(ref)
		return
	# Skip if a recent attempt failed or is still queued; racing rebuilds share one request.
	if Time.get_ticks_msec() < int(_mods_meta_retry_at.get(key, 0)):
		return
	_mods_meta_retry_at[key] = Time.get_ticks_msec() + 60000
	data = _mods_cached_summary(ref)
	if data.is_empty():
		# Cold path: queue the network fetch.
		_mods_meta_fetch_enqueue(ref)
		return
	# Snapshot hit: memo for the session only.
	_mods_meta_by_key[key] = data
	_mods_apply_host_meta(key, data)

# Click handler for a Mods-row name link: opens the detail dialog once the
# async load has filled `holder`; until then it says so.
func _open_mods_host_detail(holder: Dictionary, ref: Dictionary) -> void:
	var data_v: Variant = holder.get("data")
	if data_v is Dictionary and _mods_meta_record_complete(data_v):
		_show_browse_mod_detail_dialog(data_v, func(_d, _b): pass)
	else:
		var host := host_display_name(str(ref.get("provider", "")))
		_show_accept_dialog(host + " details",
				"Still loading this mod's " + host + " page (or it's unavailable offline). Try again in a moment.",
				"Close", 380)

func build_mods_tab(tabs: TabContainer) -> Control:
	_refresh_dependency_status()
	# Drop last build's row-node mapping; the row loop re-registers each row.
	_mods_meta_nodes.clear()
	var outer := VBoxContainer.new()
	outer.size_flags_vertical = Control.SIZE_EXPAND_FILL
	var active_modpack := get_active_modpack()
	_mods_build_banners(outer, tabs, active_modpack)
	_mods_build_toolbar(outer, tabs, active_modpack)

	outer.add_child(HSeparator.new())

	var split := HSplitContainer.new()
	split.split_offset = 560
	split.size_flags_vertical = Control.SIZE_EXPAND_FILL
	outer.add_child(split)

	# -- Left: sticky filter bar + mod list -----------------------------------
	var left_col := VBoxContainer.new()
	left_col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	left_col.size_flags_vertical = Control.SIZE_EXPAND_FILL
	split.add_child(left_col)
	var filter_edit := _mods_build_filter_bar(left_col, tabs)
	var list := _mods_build_list(left_col)
	var refresh_order := _mods_build_order_panel(split)
	_mods_build_updates_section(list, tabs)
	_mods_build_missing_section(list, tabs)
	_mods_build_header_row(list)

	# -- One row per mod -------------------------------------------------------

	if _ui_mod_entries.is_empty():
		var empty := Label.new()
		empty.text = "No mods found.\n\nPlace .vmz or .pck files in:\n" \
				+ ProjectSettings.globalize_path(_mods_dir)
		# No autowrap inside the ScrollContainer (oscillation bug); newlines still break.
		empty.clip_text = true
		empty.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		empty.tooltip_text = empty.text
		empty.mouse_filter = Control.MOUSE_FILTER_PASS
		empty.add_theme_color_override("font_color", COL_TEXT_DIM)
		empty.add_theme_font_size_override("font_size", FS_EMPH)
		list.add_child(empty)


	var rendered_any := false
	# Per-build state every row reads; lambdas capture by value, so it travels
	# as one record. dep_names_by_id is hoisted once per build because the
	# display-name fallback rebuilds the map per call.
	var row_ctx := {
		"dep_names_by_id": _entries_by_mod_id(_ui_mod_entries),
		"persisted_sources": _get_persisted_mod_sources(),
		"profile_editable": _active_profile != VANILLA_PROFILE and active_modpack == "",
		"refresh_order": refresh_order,
	}
	for entry in _ui_mod_entries:
		if not _mods_entry_visible(entry):
			continue
		rendered_any = true
		_mods_build_row(list, entry, row_ctx, tabs)

	# The filter narrowed every row out; say so, distinct from no mods installed.
	if not _ui_mod_entries.is_empty() and not rendered_any:
		var no_match := Label.new()
		no_match.text = "No mods match. Try a shorter search or turn off Hide disabled."
		no_match.add_theme_color_override("font_color", COL_TEXT_DIM)
		no_match.add_theme_font_size_override("font_size", FS_EMPH)
		list.add_child(no_match)

	# Restore focus to the search input after a filter-driven rebuild, deferred
	# so the new tab is in the tree. Cleared on consume so other rebuilds do not steal focus.
	if _mods_filter_focus_pending:
		_mods_filter_focus_pending = false
		filter_edit.call_deferred("grab_focus")
		# Setting LineEdit.text resets the caret to column 0 and FOCUS_ENTER does
		# not move it; restore the caret to end-of-text after focus lands.
		filter_edit.call_deferred("set_caret_column", filter_edit.text.length())

	refresh_order.call()
	# Wrap in the shared tab margin so the view does not shift between tabs.
	var margin := _make_tab_margin()
	margin.add_child(outer)
	return margin


# The hook-health and active-modpack banners at the top of the Mods tab.
func _mods_build_banners(outer: VBoxContainer, tabs: TabContainer, active_modpack: String) -> void:
	# Hook health from the previous session: generation runs after this window
	# closes, so this is where a player learns a game update broke the rewriter.
	var hook_problem := _hook_status_problem()
	if not hook_problem.is_empty():
		var is_error := str(hook_problem.get("severity", "")) == "error"
		var hook_banner := _make_banner(str(hook_problem.get("text", "")), COL_ERR if is_error else COL_ACCENT)
		var update_btn := Button.new()
		update_btn.text = "Check for loader update"
		var hook_banner_row: HBoxContainer = hook_banner["row"]
		hook_banner_row.add_child(update_btn)
		update_btn.pressed.connect(func():
			OS.shell_open(_modloader_release_page_url())
		)
		_wire_hint(update_btn, "Open the loader's release page in your browser.")
		outer.add_child(hook_banner["panel"])

	# Active-modpack banner with a one-click Unload.
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


# Mods folder, profile controls, UI scale and Developer Mode.
func _mods_build_toolbar(outer: VBoxContainer, tabs: TabContainer, active_modpack: String) -> void:
	var toolbar := HBoxContainer.new()
	toolbar.add_theme_constant_override("separation", SP_M)
	outer.add_child(toolbar)

	var open_btn := Button.new()
	open_btn.text = "Open mods folder"
	toolbar.add_child(open_btn)
	open_btn.pressed.connect(func():
		OS.shell_open(ProjectSettings.globalize_path(_mods_dir))
	)
	_wire_hint(open_btn, "Open the game's mods folder in your file manager.")

	var pre_profile_gap := Control.new()
	pre_profile_gap.custom_minimum_size.x = SP_L
	toolbar.add_child(pre_profile_gap)

	var profile_lbl := Label.new()
	profile_lbl.text = "Profile:"
	toolbar.add_child(profile_lbl)

	var profile_opt := OptionButton.new()
	profile_opt.custom_minimum_size.x = 180
	toolbar.add_child(profile_opt)

	# The dropdown popup is a sub-Window: always_on_top and transient so it is
	# not stranded behind the launcher; theme lookup does not cross Window boundaries.
	var profile_popup := profile_opt.get_popup()
	profile_popup.always_on_top = true
	profile_popup.transient = true
	if _ui_window != null and _ui_window.theme != null:
		profile_popup.theme = _ui_window.theme

	# Fresh install: Default is a placeholder, materialized on first save.
	# Modpack-managed profiles are filtered out of the dropdown.
	var profiles := _list_profiles().filter(func(n: String): return not _is_modpack_managed_profile(n))
	if profiles.is_empty():
		profiles = ["Default"]
	var active_idx := 0  # fall back to first user profile if no match
	for name: String in profiles:
		profile_opt.add_item(name)
		var idx := profile_opt.item_count - 1
		profile_opt.set_item_metadata(idx, name)
		if name == _active_profile:
			active_idx = idx
	profile_opt.selected = active_idx

	# With a modpack active the active profile is a hidden managed slot:
	# disable the dropdown and label it with the pack.
	if active_modpack != "":
		profile_opt.clear()
		profile_opt.add_item("[Modpack: " + active_modpack + "]")
		profile_opt.selected = 0
		profile_opt.disabled = true

	# All profile mutations are disabled while a modpack is active.
	var modpack_locked := active_modpack != ""
	var new_profile_btn := Button.new()
	new_profile_btn.text = "+"
	new_profile_btn.tooltip_text = "Create a new profile" if not modpack_locked else "Unload the active modpack first"
	new_profile_btn.disabled = modpack_locked
	new_profile_btn.custom_minimum_size.x = 28
	toolbar.add_child(new_profile_btn)
	_wire_hint(new_profile_btn, "New profile from current mod selection.")

	var rename_btn := Button.new()
	rename_btn.icon = _make_pencil_icon()
	rename_btn.tooltip_text = "Rename the active profile" if not modpack_locked else "Unload the active modpack first"
	rename_btn.disabled = modpack_locked
	rename_btn.custom_minimum_size.x = 28
	toolbar.add_child(rename_btn)
	_wire_hint(rename_btn, "Rename the active profile.")

	# Delete needs at least one other profile to switch to.
	var del_profile_btn := Button.new()
	del_profile_btn.icon = _make_trashcan_icon()
	del_profile_btn.tooltip_text = "Delete the active profile" if not modpack_locked else "Unload the active modpack first"
	del_profile_btn.disabled = profiles.size() <= 1 or modpack_locked
	del_profile_btn.custom_minimum_size.x = 28
	toolbar.add_child(del_profile_btn)
	_wire_hint(del_profile_btn, "Delete the active profile.")

	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	toolbar.add_child(spacer)

	# Launcher zoom, user-owned; never DPI-derived (see show_mod_ui).
	var scale_lbl := Label.new()
	scale_lbl.text = "UI scale"
	scale_lbl.add_theme_font_size_override("font_size", FS_BODY)
	scale_lbl.add_theme_color_override("font_color", COL_TEXT_DIM)
	toolbar.add_child(scale_lbl)

	var scale_values := [1.0, 1.25, 1.5, 1.75, 2.0]
	var scale_opt := OptionButton.new()
	for sv: float in scale_values:
		scale_opt.add_item("%d%%" % int(round(sv * 100.0)))
	var cur_scale_idx := scale_values.find(_ui_scale_setting())
	scale_opt.select(cur_scale_idx if cur_scale_idx >= 0 else 0)
	scale_opt.custom_minimum_size.y = CTRL_H
	scale_opt.add_theme_font_size_override("font_size", FS_BODY)
	toolbar.add_child(scale_opt)
	_wire_hint(scale_opt, "Scale the launcher window. Applies immediately.")

	scale_opt.item_selected.connect(func(idx: int):
		var sv: float = scale_values[idx] if idx >= 0 and idx < scale_values.size() else 1.0
		# Written straight through: a display preference must not rewrite profile state.
		var scfg := _load_ui_cfg_for_write()
		if scfg != null:
			scfg.set_value("settings", "ui_scale", sv)
			_persist_ui_cfg(scfg)
		# Apply even if the save was refused.
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

	profile_opt.item_selected.connect(func(idx: int):
		var meta = profile_opt.get_item_metadata(idx)
		_switch_profile(str(meta))
		_rebuild_mods_tab(tabs)
	)
	new_profile_btn.pressed.connect(func(): _show_new_profile_dialog(tabs))
	rename_btn.pressed.connect(func(): _show_rename_profile_dialog(tabs))
	del_profile_btn.pressed.connect(func(): _show_delete_confirm(tabs))

	dev_check.toggled.connect(func(on: bool):
		_developer_mode = on
		_ui_mod_entries = collect_mod_metadata()
		_load_ui_config()
		# Persist now: the post-boot reopen path has no closing save.
		_save_ui_config()
		_rebuild_mods_tab(tabs)
	)


# Filter text, Enable all / Disable all, Hide disabled and Check for updates.
# Returns the filter LineEdit so the caller can restore focus to it.
func _mods_build_filter_bar(left_col: VBoxContainer, tabs: TabContainer) -> LineEdit:
	# Filter bar. All/None respect the active filter, toggling only the visible subset.
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
	_wire_hint(all_btn, "Enable every visible mod (respects the search filter).")

	var none_btn := Button.new()
	none_btn.text = "Disable all"
	none_btn.tooltip_text = "Disable every visible mod"
	filter_bar.add_child(none_btn)
	_wire_hint(none_btn, "Disable every visible mod (respects the search filter).")

	var hide_check := CheckBox.new()
	hide_check.text = "Hide disabled"
	hide_check.tooltip_text = "Hide rows for mods that are disabled in this profile"
	hide_check.button_pressed = _mods_hide_disabled
	hide_check.add_theme_font_size_override("font_size", FS_BODY)
	filter_bar.add_child(hide_check)
	_wire_hint(hide_check, "Hide rows for mods that are disabled in this profile.")

	# Check Updates populates _mod_updates_state so rows show update badges.
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
		# A mid-check rebuild frees the original button: skip only the button
		# touches; the rebuild and toast must still run.
		if is_instance_valid(check_btn):
			check_btn.disabled = false
			check_btn.text = "Check for updates"
		if is_instance_valid(tabs):
			_rebuild_mods_tab(tabs)
		# Errored checks are reported, not counted as up to date.
		var n := int(summary.get("with_updates", 0))
		var ck := int(summary.get("checked", 0))
		var er := int(summary.get("errors", 0))
		var msg := ""
		if ck == 0:
			msg = "No installed mods say where they came from, so there is nothing to check."
		elif er >= ck:
			msg = "Could not check any mods. Check your connection and try again."
		elif n == 0:
			msg = "Everything is up to date. Checked %d mod(s)." % (ck - er)
			if er > 0:
				msg += " %d could not be checked." % er
		else:
			msg = "%d update(s) available." % n
			if er > 0:
				msg += " %d could not be checked." % er
		# Only toast while the launcher exists: with _ui_window null the dialog
		# would parent to the game's root and steal input mid-game.
		if is_instance_valid(_ui_window):
			_show_info_toast(msg)
	)

	# Debounce the filter rebuild: each _rebuild_mods_tab is a full tear-down
	# with disk work, so keystrokes only store text and restart the timer.
	var filter_debounce := Timer.new()
	filter_debounce.one_shot = true
	filter_debounce.wait_time = 0.25
	filter_bar.add_child(filter_debounce)
	filter_debounce.timeout.connect(func():
		# Restore focus after the rebuild so the user can keep typing.
		_mods_filter_focus_pending = true
		if is_instance_valid(tabs):
			_rebuild_mods_tab(tabs)
	)
	filter_edit.text_changed.connect(func(t: String):
		_mods_filter_text = t
		filter_debounce.stop()
		filter_debounce.start()
	)
	all_btn.pressed.connect(func():
		for entry in _ui_mod_entries:
			if _mods_entry_visible(entry):
				entry["enabled"] = true
		_save_ui_config()
		_rebuild_mods_tab(tabs)
	)
	none_btn.pressed.connect(func():
		# Bulk None disables content mods too; confirm once for the batch.
		var content_count := 0
		var content_name := ""
		for entry in _ui_mod_entries:
			if _mods_entry_visible(entry) and bool(entry.get("enabled", false)) \
					and bool(entry.get("has_registry", false)):
				content_count += 1
				if content_name == "":
					content_name = str(entry.get("mod_name", "this mod"))
		if content_count > 0:
			var ok: bool = await _confirm_disable_content_mod(content_name, content_count)
			if not ok:
				return
		for entry in _ui_mod_entries:
			if _mods_entry_visible(entry):
				entry["enabled"] = false
		_save_ui_config()
		if is_instance_valid(tabs):
			_rebuild_mods_tab(tabs)
	)
	hide_check.toggled.connect(func(on: bool):
		_mods_hide_disabled = on
		_save_per_profile_setting("hide_disabled", on)
		_rebuild_mods_tab(tabs)
	)
	return filter_edit


# The scrolling mod list under the filter bar.
func _mods_build_list(left_col: VBoxContainer) -> VBoxContainer:
	var left_scroll := ScrollContainer.new()
	left_scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	left_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	left_col.add_child(left_scroll)
	_ui_mods_scroll = left_scroll

	# Right padding keeps the load-order SpinBox arrows off the scrollbar.
	var list_pad := MarginContainer.new()
	list_pad.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	list_pad.add_theme_constant_override("margin_right", SP_XL)
	left_scroll.add_child(list_pad)

	var list := VBoxContainer.new()
	list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	list_pad.add_child(list)
	return list


# The live load-order preview on the right. Returns the Callable that
# re-renders it; rows call it when a priority changes.
func _mods_build_order_panel(split: HSplitContainer) -> Callable:
	var right := VBoxContainer.new()
	right.custom_minimum_size.x = 220
	split.add_child(right)

	var order_header := Label.new()
	order_header.text = "Load order"
	order_header.add_theme_font_size_override("font_size", FS_HEAD)
	order_header.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	right.add_child(order_header)
	right.add_child(HSeparator.new())

	var order_panel := PanelContainer.new()
	order_panel.size_flags_vertical = Control.SIZE_EXPAND_FILL
	var panel_style := StyleBoxFlat.new()
	panel_style.bg_color = COL_SURFACE_2
	panel_style.content_margin_left = SP_M
	panel_style.content_margin_right = SP_M
	panel_style.content_margin_top = SP_M
	panel_style.content_margin_bottom = SP_M
	order_panel.add_theme_stylebox_override("panel", panel_style)
	right.add_child(order_panel)

	var order_scroll := ScrollContainer.new()
	order_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	# Scrollbar always visible so it cannot flip and re-trigger the autowrap oscillation bug.
	order_scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_SHOW_ALWAYS
	order_panel.add_child(order_scroll)

	var order_list := VBoxContainer.new()
	order_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	order_scroll.add_child(order_list)

	var refresh_order := func():
		# _refresh_dependency_status returns the loader's own pick. Reuse it: this
		# fires per step while a spin arrow is held.
		var pick: Dictionary = _refresh_dependency_status()
		for child in order_list.get_children():
			child.queue_free()
		var loadable: Array = pick["loadable"]
		var enabled_count := int(pick["enabled_count"])
		if enabled_count == 0:
			var lbl := Label.new()
			lbl.text = "No mods enabled"
			lbl.add_theme_color_override("font_color", COL_TEXT_DIM)
			order_list.add_child(lbl)
			return
		if loadable.is_empty():
			# Manual line break; never autowrap here (see below).
			order_list.add_child(_make_sub_label(
					"%d enabled, none will load\n(missing dependencies)" % enabled_count,
					COL_ACCENT,
					"Every enabled mod is missing a required dependency.\nFix it from the orange row warnings, or use Load anyway."))
			return
		for i in loadable.size():
			var e: Dictionary = loadable[i]
			var lbl := Label.new()
			lbl.text = str(i + 1) + ".  " + e["mod_name"]
			lbl.add_theme_font_size_override("font_size", FS_EMPH)
			lbl.add_theme_color_override("font_color", COL_TEXT)
			# No autowrap: an autowrap label in a fixed-width ScrollContainer hits a
			# Godot 4.6 layout-oscillation bug (scrollbar appears, width shrinks, re-wrap,
			# repeat) that floods the message queue and crashes.
			lbl.clip_text = true
			lbl.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
			# Full name shows in the bottom status-line hint.
			lbl.mouse_filter = Control.MOUSE_FILTER_PASS
			order_list.add_child(lbl)
			_wire_hint(lbl, str(e["mod_name"]))
		if bool(pick["adjusted"]):
			var reorder_lbl := _make_sub_label("reordered for dependencies", COL_TEXT_DIM)
			order_list.add_child(reorder_lbl)
			_wire_hint(reorder_lbl, "A required mod was moved up so it loads before the mod that needs it. Your load-order numbers are unchanged.")
		var blocked_count := enabled_count - loadable.size()
		if blocked_count > 0:
			var blocked_lbl := _make_sub_label("%d blocked by dependencies" % blocked_count, COL_ACCENT)
			order_list.add_child(blocked_lbl)
			_wire_hint(blocked_lbl, "Blocked mods stay checked but don't load. See the orange row warnings for fixes.")
	return refresh_order


# Mods with a newer version known from the last update check.
func _mods_build_updates_section(list: VBoxContainer, tabs: TabContainer) -> void:
	var update_keys: Array = []
	for entry_v in _ui_mod_entries:
		var pk_check: String = str(entry_v.get("profile_key", ""))
		if _mod_updates_state.has(pk_check):
			update_keys.append(pk_check)
	if not update_keys.is_empty():
		var u_hdr_row := HBoxContainer.new()
		u_hdr_row.add_theme_constant_override("separation", SP_S)
		list.add_child(u_hdr_row)
		var u_hdr := Label.new()
		u_hdr.text = "Updates available"
		u_hdr.add_theme_color_override("font_color", COL_ACCENT)
		u_hdr.add_theme_font_size_override("font_size", FS_HEAD)
		u_hdr_row.add_child(u_hdr)
		var u_badge := Label.new()
		u_badge.text = str(update_keys.size())
		u_badge.add_theme_stylebox_override("normal", _make_badge_stylebox())
		u_badge.add_theme_font_size_override("font_size", FS_META)
		u_badge.add_theme_color_override("font_color", COL_TEXT_HI)
		u_badge.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		u_hdr_row.add_child(u_badge)
		list.add_child(HSeparator.new())

		for pk: String in update_keys:
			var upd: Dictionary = _mod_updates_state[pk]
			var upd_row := HBoxContainer.new()
			upd_row.add_theme_constant_override("separation", SP_L)
			list.add_child(upd_row)

			var u_name := Label.new()
			u_name.text = str(upd.get("mod_name", "?"))
			u_name.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			u_name.clip_text = true
			u_name.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
			u_name.tooltip_text = str(upd.get("mod_name", "?"))
			u_name.mouse_filter = Control.MOUSE_FILTER_PASS
			upd_row.add_child(u_name)

			var u_ver := Label.new()
			u_ver.text = "v%s  ->  v%s" % [str(upd.get("current_version", "?")), str(upd.get("latest_version", "?"))]
			u_ver.add_theme_color_override("font_color", COL_TEXT)
			u_ver.add_theme_font_size_override("font_size", FS_BODY)
			u_ver.custom_minimum_size.x = 160
			# A long prerelease string must not widen the column.
			u_ver.clip_text = true
			u_ver.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
			u_ver.tooltip_text = u_ver.text
			u_ver.mouse_filter = Control.MOUSE_FILTER_PASS
			upd_row.add_child(u_ver)

			var u_btn := Button.new()
			u_btn.text = "Update"
			upd_row.add_child(u_btn)
			_wire_hint(u_btn, "Download the latest version and replace the installed one.")
			var captured_pk := pk
			var captured_upd := upd
			# Row rebuilt mid-download: render the button inert.
			if _mod_update_in_flight.has(pk):
				u_btn.disabled = true
				u_btn.text = "Updating..."
			u_btn.pressed.connect(func():
				# Refuse a second concurrent download of the same mod.
				if _mod_update_in_flight.has(captured_pk):
					return
				_mod_update_in_flight[captured_pk] = true
				u_btn.disabled = true
				u_btn.text = "Updating..."
				var upd_ref: Dictionary = captured_upd.get("ref", {}) if captured_upd.get("ref") is Dictionary else {}
				# Re-resolve the path live: another surface may have renamed the file.
				var full_path: String = _live_full_path(captured_pk, str(captured_upd.get("full_path", "")))
				var result: Dictionary = await replace_mod_from_ref(full_path, upd_ref)
				_mod_update_in_flight.erase(captured_pk)
				if bool(result.get("ok", false)):
					_mod_updates_state.erase(captured_pk)
					_reload_entries_for_active_profile()
					if is_instance_valid(tabs):
						_rebuild_mods_tab(tabs)
				else:
					if is_instance_valid(u_btn):
						u_btn.disabled = false
						u_btn.text = "Update"
					elif is_instance_valid(tabs):
						# A mid-download rebuild left a replacement button stuck; rebuild now the flag is clear.
						_rebuild_mods_tab(tabs)
					var err_name := str(captured_upd.get("mod_name", "this mod"))
					var err_msg := "Could not download %s. Check your connection and try again." % err_name
					var err_detail := str(result.get("error", ""))
					if err_detail != "" and err_detail != "unknown":
						err_msg += "\n\nDetails: " + err_detail
					if is_instance_valid(_ui_window):
						_show_error_dialog("Update failed", err_msg)
			)
			list.add_child(HSeparator.new())


# Profile entries whose mod is not on disk: Remove, and Download when a
# source is known.
func _mods_build_missing_section(list: VBoxContainer, tabs: TabContainer) -> void:
	var missing_files := _missing_mods_in_active_profile()
	if not missing_files.is_empty():
		var missing_hdr_row := HBoxContainer.new()
		list.add_child(missing_hdr_row)
		var missing_hdr := Label.new()
		missing_hdr.text = "Missing from this profile"
		missing_hdr.add_theme_color_override("font_color", COL_ERR)
		missing_hdr.add_theme_font_size_override("font_size", FS_HEAD)
		missing_hdr.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		missing_hdr_row.add_child(missing_hdr)
		var remove_all_btn := Button.new()
		remove_all_btn.text = "Remove all"
		remove_all_btn.tooltip_text = "Remove all missing mods from this profile"
		missing_hdr_row.add_child(remove_all_btn)
		_wire_hint(remove_all_btn, "Remove every missing mod from the active profile.")
		remove_all_btn.pressed.connect(func():
			var n := missing_files.size()
			var d := ConfirmationDialog.new()
			d.title = "Remove missing-mod entries"
			d.dialog_text = "Remove %d missing-mod entr%s from \"%s\"?\n\nOnly the active profile is affected -- other profiles still list these mods." % [
				n, ("y" if n == 1 else "ies"), _active_profile,
			]
			d.ok_button_text = "Remove"
			_attach_ui_dialog(d)
			style_dialog_danger_button(d.get_ok_button())
			_connect_dialog_exits(d,
				func():
					d.queue_free()
					_remove_all_missing_entries_from_profile()
					_rebuild_mods_tab(tabs),
				func(): d.queue_free())
			d.popup_centered()
		)
		list.add_child(HSeparator.new())
		# Compute sources once per build, not per row.
		var missing_sources := _missing_mod_sources_combined()
		for fn: String in missing_files:
			var miss_row := HBoxContainer.new()
			list.add_child(miss_row)
			var miss_lbl := Label.new()
			var display := fn.trim_prefix("zip:")
			miss_lbl.text = display + "  --  not installed"
			miss_lbl.add_theme_color_override("font_color", COL_ERR)
			miss_lbl.clip_text = true
			miss_lbl.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
			miss_lbl.tooltip_text = miss_lbl.text
			miss_lbl.mouse_filter = Control.MOUSE_FILTER_PASS
			miss_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			miss_row.add_child(miss_lbl)

			# Download button when source info is known; otherwise Remove only.
			var src_v: Variant = missing_sources.get(fn)
			var src_ref: Dictionary = {}
			var src_version: String = ""
			if src_v is Dictionary:
				# Already canonical; _normalize_source_record handled the untrusted JSON.
				# This runs on the pass-1 path, where a crash would block the main menu.
				var src: Dictionary = src_v
				src_ref = _source_host_ref(src)
				src_version = str(src.get("version", ""))
			if _modpack_ref_downloadable(src_ref):
				var src_host := host_display_name(str(src_ref["provider"]))
				var dl_btn := Button.new()
				dl_btn.text = "Download"
				dl_btn.tooltip_text = "Download this mod from " + src_host
				miss_row.add_child(dl_btn)
				_wire_hint(dl_btn, "Download this mod from " + src_host + ".")
				var captured_ref := src_ref
				var captured_version := src_version
				# Reuse _mod_update_in_flight keyed by the stored profile key, or a
				# mid-download rebuild re-enables the button and a second click duplicates.
				var captured_fn := fn
				if _mod_update_in_flight.has(fn):
					dl_btn.disabled = true
					dl_btn.text = "Downloading..."
				dl_btn.pressed.connect(func():
					if _mod_update_in_flight.has(captured_fn):
						return
					_mod_update_in_flight[captured_fn] = true
					dl_btn.disabled = true
					dl_btn.text = "Downloading..."
					# allow_rename_on_collision: dedup happens at scan time.
					var r: Dictionary = await download_mod_from_ref(captured_ref, captured_version, true)
					_mod_update_in_flight.erase(captured_fn)
					if bool(r.get("ok", false)):
						_reload_entries_for_active_profile()
						if is_instance_valid(tabs):
							_rebuild_mods_tab(tabs)
					else:
						if is_instance_valid(dl_btn):
							dl_btn.disabled = false
							dl_btn.text = "Download"
						elif is_instance_valid(tabs):
							_rebuild_mods_tab(tabs)
						if is_instance_valid(_ui_window):
							_show_error_dialog("Download failed", str(r.get("error", "Could not download this mod. Check your connection and try again.")))
				)
			else:
				# No source info: name what is unavailable. STOP so the label gets hover signals.
				var no_src_lbl := Label.new()
				no_src_lbl.text = "Download unavailable"
				no_src_lbl.add_theme_color_override("font_color", COL_TEXT_DIM)
				no_src_lbl.add_theme_font_size_override("font_size", FS_BODY)
				no_src_lbl.size_flags_vertical = Control.SIZE_SHRINK_CENTER
				no_src_lbl.mouse_filter = Control.MOUSE_FILTER_STOP
				miss_row.add_child(no_src_lbl)
				_wire_hint(no_src_lbl,
					"This mod does not say which site it came from, so it can't be downloaded automatically. Reinstall it manually.")

			var remove_btn := Button.new()
			remove_btn.text = "Remove"
			remove_btn.tooltip_text = "Remove this missing mod from this profile"
			miss_row.add_child(remove_btn)
			_wire_hint(remove_btn, "Remove this mod from the active profile.")
			var captured := fn
			remove_btn.pressed.connect(func():
				_remove_missing_entry_from_profile(captured)
				_rebuild_mods_tab(tabs)
			)
			list.add_child(HSeparator.new())


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
func _mods_build_row(list: VBoxContainer, entry: Dictionary, row_ctx: Dictionary, tabs: TabContainer) -> void:
	var refresh_order: Callable = row_ctx["refresh_order"]
	var row := HBoxContainer.new()
	list.add_child(row)

	var check := CheckBox.new()
	check.button_pressed = entry["enabled"]
	check.custom_minimum_size.x = 30
	row.add_child(check)

	var name_parts := _mods_row_name_column(row, entry, row_ctx["persisted_sources"])
	var name_col: VBoxContainer = name_parts["name_col"]
	var name_ctrl: Control = name_parts["name_ctrl"]
	_mods_row_dependency_lines(name_col, name_ctrl, entry, row_ctx, tabs)
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
	# the detail dialog. A link-out host opens the mod page instead. Mods with
	# no host keep the same-width cell so the name column stays aligned.
	var row_ref := _entry_host_ref(entry, persisted_sources)
	var row_key := host_ref_key(row_ref)
	var row_browsable := row_key != "" and bool(host_caps(str(row_ref["provider"]))["browse"])
	var row_page_url := host_mod_page_url(row_ref) if row_key != "" else ""
	var meta_holder: Dictionary = {}
	var thumb_ref: TextureRect = null
	# Every row gets a thumbnail cell captioned "no thumbnail"; a texture clears it.
	var thumb_rect := _make_thumb_cell(row, Vector2(96, 54), true, true)
	if row_browsable:
		thumb_ref = thumb_rect

	var name_col := VBoxContainer.new()
	name_col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	name_col.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(name_col)

	# name_ctrl: clickable for hosted mods, plain Label otherwise.
	var name_ctrl: Control
	if row_browsable or row_page_url != "":
		# Flat Button, not LinkButton, so clip_text keeps a long name from widening the row.
		var name_lnk := Button.new()
		name_lnk.flat = true
		name_lnk.text = entry["mod_name"]
		name_lnk.clip_text = true
		name_lnk.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		name_lnk.alignment = HORIZONTAL_ALIGNMENT_LEFT
		name_lnk.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		var row_host := host_display_name(str(row_ref["provider"]))
		name_lnk.tooltip_text = str(entry["mod_name"]) + ("  --  click for " + row_host + " details" if row_browsable \
				else "  --  click to open the " + row_host + " page in your browser")
		name_lnk.add_theme_color_override("font_color", COL_OK if entry["enabled"] else COL_TEXT_DIM)
		name_lnk.add_theme_color_override("font_hover_color", COL_TEXT_HI)
		name_col.add_child(name_lnk)
		if row_browsable:
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
		else:
			var captured_page := row_page_url
			name_lnk.pressed.connect(func():
				OS.shell_open(captured_page)
			)
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
func _mods_row_dependency_lines(name_col: VBoxContainer, name_ctrl: Control, entry: Dictionary, row_ctx: Dictionary, tabs: TabContainer) -> void:
	var dep_names_by_id: Dictionary = row_ctx["dep_names_by_id"]
	var profile_editable: bool = row_ctx["profile_editable"]
	# Dependencies: one clipped line; the actionable blocked row renders below.
	var required_deps: Array = entry.get("required_dependencies", [])
	var optional_deps: Array = entry.get("optional_dependencies", [])
	var blockers_info: Array = entry.get("dependency_blockers_info", [])
	var dep_ignored := bool(entry.get("dependency_ignored", false))
	var dep_blocked: bool = entry["enabled"] \
			and not (entry.get("dependency_blockers", []) as Array).is_empty()
	if dep_blocked:
		# The green "enabled" tint would lie. This mod won't load.
		name_ctrl.add_theme_color_override("font_color", COL_ACCENT)
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
	for warn_text: String in entry.get("warnings", []):
		name_col.add_child(_make_sub_label(warn_text, COL_ACCENT, warn_text))
	for warn_text: String in entry.get("dependency_warnings", []):
		name_col.add_child(_make_sub_label(warn_text, COL_ACCENT, warn_text))

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
		var bl := _make_sub_label("won't load -- needs " + why, COL_ACCENT, "\n".join(btip))
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
		name_col.add_child(_make_sub_label(hide_text, COL_ACCENT, hide_text))

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
	var risk: int = int(entry.get("risk_level", 0))
	if risk == 2:
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
	elif _entry_has_unscannable_code(entry):
		# Not a risk verdict: the scanner could not read this mod's compiled
		# bytecode, and no badge would read as "checked, nothing found". Dim, not
		# red: shipping compiled code is not an accusation.
		var unscanned_btn := Button.new()
		unscanned_btn.text = "not scanned"
		unscanned_btn.flat = true
		unscanned_btn.tooltip_text = "This mod ships compiled code the scanner cannot read. Nothing was checked."
		unscanned_btn.add_theme_color_override("font_color", COL_TEXT_DIM)
		unscanned_btn.add_theme_color_override("font_hover_color", COL_TEXT_HI)
		unscanned_btn.add_theme_font_size_override("font_size", FS_BODY)
		unscanned_btn.alignment = HORIZONTAL_ALIGNMENT_LEFT
		unscanned_btn.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
		name_col.add_child(unscanned_btn)
		var captured_unscanned := entry
		unscanned_btn.pressed.connect(func(): _show_security_findings_dialog(captured_unscanned))


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
