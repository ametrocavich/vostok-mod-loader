
# Shared tail for every dependency quick action: recompute status, persist,
# retruth the launch button, rebuild the tab -- deferred, so the control
# that's mid-signal isn't torn down under the cursor.
func _after_dep_action(tabs: TabContainer) -> void:
	_refresh_dependency_status()
	_save_ui_config()
	refresh_launch_button_label()
	(func(): _rebuild_mods_tab(tabs)).call_deferred()

# Runtime-generated 16x16 pencil icon. Monochrome outline in button-text
# gray so it matches the rest of the UI -- a colored pencil looks like an
func _mods_cached_summary_by_id(mod_id: int) -> Dictionary:
	if mod_id <= 0:
		return {}
	var data_v: Variant = mws_discover_snapshot().get("data")
	if not (data_v is Dictionary):
		return {}
	for key in ["popular", "latest"]:
		var arr_v: Variant = (data_v as Dictionary).get(key)
		if not (arr_v is Array):
			continue
		for row_v in (arr_v as Array):
			if row_v is Dictionary and int((row_v as Dictionary).get("id", 0)) == mod_id:
				return row_v
	return {}

# Persisted per-mod meta sidecar. Without it, every relaunch re-fetched
# /mods/{id} for each installed MWS mod (the memo is session-only, and the
# thumbnail disk cache is keyed by storage filename with no mod_id mapping to
# reach it). One JSON file, {"<mod_id>": {"mod": <mod object>, "saved_at":
# unix}}, storing the full fetched mod object so the detail dialog stays as
# rich offline as it was in the session that fetched it. Lives under
# user://mws_cache/ next to the thumbnail cache (already on modpacks.gd's
# override deny list, so packs can't poison it). Entries older than
# _MODS_META_REFRESH_SEC soft-refresh in the background so replaced
# thumbnails / renamed authors converge within a day.
const _MODS_META_SIDECAR_PATH := "user://mws_cache/mods_meta.json"
const _MODS_META_REFRESH_SEC := 86400

# Lazy one-time seed of the meta memo from the sidecar. Runs BEFORE the
# snapshot/network path consults the memo, so cached rows paint immediately
# and offline. Every field is shape-checked: a hand-edited or truncated file
# (wrong root type, non-dict entry, null/absent "mod", null/absent
# "saved_at") degrades to skipping that entry, never a crash -- .get()'s
# default only covers ABSENT keys, so present-but-null needs the `is` guards.
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
		var mod_id := str(key_v).to_int()
		if mod_id <= 0:
			continue
		var entry_v: Variant = (parsed as Dictionary)[key_v]
		if not (entry_v is Dictionary):
			continue
		var mod_v: Variant = (entry_v as Dictionary).get("mod")
		if not (mod_v is Dictionary) or (mod_v as Dictionary).is_empty():
			continue
		# saved_at arrives as a float after the JSON round-trip; int() it.
		var saved_v: Variant = (entry_v as Dictionary).get("saved_at", 0)
		if not (saved_v is int or saved_v is float) or int(saved_v) <= 0:
			continue
		# Never clobber fresher data a fetch already memoized this session.
		if not _mods_mws_meta_by_id.has(mod_id):
			_mods_mws_meta_by_id[mod_id] = mod_v
			_mods_mws_meta_saved_at[mod_id] = int(saved_v)

# Stamp mod_id as freshly fetched and rewrite the sidecar from the memo.
# Only ids with a saved_at stamp are persisted -- i.e. only entries that came
# from a real /mods/{id} fetch (this session or a prior one); snapshot-sourced
# memo entries stay session-only as before. Best-effort: a failed write just
# means a refetch next launch, never an error the user sees.
func _mods_meta_sidecar_store(mod_id: int) -> void:
	_mods_mws_meta_saved_at[mod_id] = int(Time.get_unix_time_from_system())
	var out := {}
	for id_v in _mods_mws_meta_saved_at:
		var d: Variant = _mods_mws_meta_by_id.get(id_v, {})
		if d is Dictionary and not (d as Dictionary).is_empty():
			out[str(id_v)] = {
				"mod": d,
				"saved_at": int(_mods_mws_meta_saved_at[id_v]),
			}
	DirAccess.make_dir_recursive_absolute(_MODS_META_SIDECAR_PATH.get_base_dir())
	var f := FileAccess.open(_MODS_META_SIDECAR_PATH, FileAccess.WRITE)
	if f == null:
		return
	f.store_string(JSON.stringify(out))
	f.close()

# Paint ModWorkshop meta onto the CURRENT Mods-tab row for mod_id, looked up
# via _mods_meta_nodes at paint time -- NOT via nodes captured when the fetch
# started, which a rebuild may have freed. No entry (row filtered out, tab
# rebuilt without it, launcher closed) means the data is memoized for the next
# build and nothing is painted. Idempotent per row: the author line is added
# once (node-name guard), and a repeat thumbnail load just re-resolves the
# same cache entry.
func _mods_apply_mws_meta(mod_id: int, data: Dictionary) -> void:
	# One workshop id can back several rows (e.g. a .vmz copy plus a dev-folder
	# copy of the same mod), so the mapping holds a LIST of row-node dicts.
	var rows_v: Variant = _mods_meta_nodes.get(mod_id)
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
			var thumb_record: Variant = data.get("thumbnail")
			if thumb_record is Dictionary:
				# Leave the caption in place: _set_thumb_ready clears it the
				# instant a texture actually lands, so the cell reads
				# "no thumbnail" while the fetch is in flight rather than
				# reverting to a bare gray panel that means nothing.
				_browse_load_thumbnail_async(thumb_rect, thumb_record)
			else:
				# Mod exists on MWS but has no thumbnail record -- say so
				# instead of leaving the cell an ambiguous forever-gray panel.
				_set_thumb_failed(thumb_rect, false)
		var col_v: Variant = nodes.get("name_col")
		if is_instance_valid(col_v) and col_v is VBoxContainer:
			var name_col: VBoxContainer = col_v
			if not name_col.has_node("MwsAuthorLabel"):
				var user_dict: Dictionary = data.get("user", {}) if data.get("user") is Dictionary else {}
				var author := str(user_dict.get("name", ""))
				if author != "":
					var author_lbl := _make_sub_label("by " + author, COL_TEXT_DIM, "")
					author_lbl.name = "MwsAuthorLabel"
					name_col.add_child(author_lbl)
					name_col.move_child(author_lbl, 1)  # right under the name

# Paint the "load failed" overlay onto every current Mods-tab row for mod_id
# when its meta fetch failed outright (offline, mod gone). Same paint-time
# _mods_meta_nodes lookup as _mods_apply_mws_meta, so a rebuild mid-fetch is
# safe. Without this the cell stayed a permanently ambiguous gray panel --
# indistinguishable from still-loading. Callers must only invoke this when no
# memoized data exists for the id (a failed soft refresh must not caption an
# already-painted texture).
func _mods_paint_meta_failed(mod_id: int) -> void:
	var rows_v: Variant = _mods_meta_nodes.get(mod_id)
	if not (rows_v is Array):
		return
	for nodes_v in (rows_v as Array):
		if not (nodes_v is Dictionary):
			continue
		var thumb_v: Variant = (nodes_v as Dictionary).get("thumb")
		if is_instance_valid(thumb_v) and thumb_v is TextureRect:
			_set_thumb_failed(thumb_v as TextureRect, true)

# Serialized background meta fetches (rate-budget guard). A first launch with
# an empty sidecar used to fire one parallel mws_get_mod per MWS-linked row at
# window open -- on top of the Browse landing's list + categories calls --
# which could drain the guest 90 req/min budget and arm the rate cooldown
# through no user action. Ids queue here instead; one drain loop fetches them
# sequentially and stops while a cooldown is armed (the per-id 60s retry
# window in _mods_load_mws_meta lets a later rebuild re-enqueue them).
var _mods_meta_fetch_queue: Array[int] = []
var _mods_meta_fetch_active := false

func _mods_meta_fetch_enqueue(mod_id: int) -> void:
	# No dedupe needed: enqueue points sit behind _mods_mws_meta_retry_at,
	# which is armed before the enqueue, so the same id can't queue twice
	# within its retry window.
	_mods_meta_fetch_queue.append(mod_id)
	if _mods_meta_fetch_active:
		return
	_mods_meta_fetch_active = true
	while not _mods_meta_fetch_queue.is_empty():
		if mws_rate_cooldown_seconds() > 0:
			# Don't spend the recovery window on background meta -- user-facing
			# surfaces (Browse, downloads) need the budget more.
			_mods_meta_fetch_queue.clear()
			break
		var next_id: int = int(_mods_meta_fetch_queue.pop_front())
		var fetched: Variant = await mws_get_mod(next_id)
		var fetch_ok := false
		if fetched is Dictionary:
			var obj: Variant = (fetched as Dictionary).get("data", fetched)
			if obj is Dictionary and not (obj as Dictionary).is_empty():
				fetch_ok = true
				_mods_mws_meta_by_id[next_id] = obj
				# Persist real fetches so the next launch renders without a
				# request.
				_mods_meta_sidecar_store(next_id)
				# Paint-time node lookup -- safe even if the row (or the whole
				# launcher) is gone by now; it just memoizes.
				_mods_apply_mws_meta(next_id, obj)
		if not fetch_ok:
			# Cold-path failure (no memo to fall back on): caption the cell
			# "load failed" instead of leaving it ambiguous gray. A failed
			# SOFT refresh keeps its already-painted memoized texture -- no
			# overlay there.
			var memo_v: Variant = _mods_mws_meta_by_id.get(next_id)
			if not (memo_v is Dictionary) or (memo_v as Dictionary).is_empty():
				_mods_paint_meta_failed(next_id)
	_mods_meta_fetch_active = false

# Populate an installed mod row's ModWorkshop thumbnail + author, and stash the
# mod object so the name link can open the Browse detail dialog (description +
# file history). Memo-first (seeded from the on-disk sidecar, so relaunches and
# offline render instantly), then the Browse snapshot, then a QUEUED by-id
# fetch only for mods neither covers. All async and best-effort: offline or a
# failed fetch just leaves the gray placeholder and the name link shows a
# gentle notice -- no error, no log spam. Painting goes through
# _mods_apply_mws_meta, which resolves the row's CURRENT nodes from
# _mods_meta_nodes at paint time, so a fetch that outlives a tab rebuild still
# lands on screen.
func _mods_load_mws_meta(mod_id: int) -> void:
	_mods_meta_sidecar_load()
	var data: Dictionary = _mods_mws_meta_by_id.get(mod_id, {})
	if not data.is_empty():
		# Memoized (this session, or seeded from the sidecar): paint the row
		# synchronously -- even when an earlier fetch for this id is still in
		# flight, the freshly built row must not sit gray waiting on it.
		_mods_apply_mws_meta(mod_id, data)
		# Soft refresh: a sidecar entry older than a day re-fetches in the
		# background so changed thumbnails/authors converge. Values in
		# _mods_mws_meta_saved_at are ints we wrote ourselves; 0 means the
		# entry is session-sourced (snapshot) and never soft-refreshes.
		var saved_at := int(_mods_mws_meta_saved_at.get(mod_id, 0))
		if saved_at <= 0 \
				or int(Time.get_unix_time_from_system()) - saved_at < _MODS_META_REFRESH_SEC:
			return
		# Same retry window as the cold path, so racing rebuilds share one
		# refresh request per mod per minute. The queue serializes the actual
		# fetch (memo + sidecar + repaint happen on completion there).
		if Time.get_ticks_msec() < int(_mods_mws_meta_retry_at.get(mod_id, 0)):
			return
		_mods_mws_meta_retry_at[mod_id] = Time.get_ticks_msec() + 60000
		_mods_meta_fetch_enqueue(mod_id)
		return
	# Skip if a recent attempt failed or is still queued/in flight. The retry
	# window is armed BEFORE the enqueue, so quick racing rebuilds don't each
	# queue a request; successes are memoed by the drain loop.
	if Time.get_ticks_msec() < int(_mods_mws_meta_retry_at.get(mod_id, 0)):
		return
	_mods_mws_meta_retry_at[mod_id] = Time.get_ticks_msec() + 60000
	data = _mods_cached_summary_by_id(mod_id)
	if data.is_empty():
		# Cold path: no memo, no snapshot. Queue the network fetch instead of
		# firing it inline -- N uncached rows used to spawn N parallel requests
		# in one build loop (see _mods_meta_fetch_enqueue). The queue memoizes,
		# persists to the sidecar, and paints on completion; snapshot hits
		# below stay session-only (the snapshot itself already persists).
		_mods_meta_fetch_enqueue(mod_id)
		return
	# Snapshot hit: memo for the session, exactly as before the sidecar.
	_mods_mws_meta_by_id[mod_id] = data
	_mods_apply_mws_meta(mod_id, data)

# Click handler for a Mods-row ModWorkshop name link. Opens the same detail
# dialog the Browse tab uses (banner/thumbnail + author + description + file
# history) once the async load has filled `holder`; until then (or offline) it
# says so instead of opening an empty dialog. Bound with the row's holder dict,
# which _mods_load_mws_meta fills in place.
func _open_mods_mws_detail(holder: Dictionary) -> void:
	if holder.has("data"):
		_show_browse_mod_detail_dialog(holder["data"], func(_d, _b): pass)
	else:
		_show_accept_dialog("ModWorkshop details",
				"Still loading this mod's ModWorkshop page (or it's unavailable offline). Try again in a moment.",
				"Close", 380)

func build_mods_tab(tabs: TabContainer) -> Control:
	_refresh_dependency_status()
	# Drop last build's row-node mapping; the row loop below re-registers each
	# visible MWS row. An async meta fetch still in flight from the previous
	# build then paints the row built HERE (or, for a now-filtered-out mod,
	# finds no entry and just memoizes).
	_mods_meta_nodes.clear()
	var outer := VBoxContainer.new()
	outer.size_flags_vertical = Control.SIZE_EXPAND_FILL

	# Active-modpack banner. When a modpack is applied, surface it loudly so
	# the user knows their mod selection isn't their own configuration -- and
	# can unload back to it with one click. Hidden when no modpack is active.
	var active_modpack := get_active_modpack()
	if active_modpack != "":
		var banner := _make_banner(
				"Modpack \"" + active_modpack + "\" is active. Changes here save to the modpack, not your profiles.",
				COL_AMBER)
		var unload_btn := Button.new()
		unload_btn.text = "Unload"
		style_danger_button(unload_btn)
		var banner_row: HBoxContainer = banner["row"]
		banner_row.add_child(unload_btn)
		unload_btn.pressed.connect(func(): _unload_modpack_with_feedback(tabs))
		outer.add_child(banner["panel"])

	# -- Toolbar (profile selector + folder shortcut + dev toggle) ------------
	# Single row: Open Mods Folder | Profile: [dropdown] [+] [pencil] [trash] | ... | Developer Mode

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

	# Small visual gap between folder button and profile controls.
	var pre_profile_gap := Control.new()
	pre_profile_gap.custom_minimum_size.x = SP_L
	toolbar.add_child(pre_profile_gap)

	var profile_lbl := Label.new()
	profile_lbl.text = "Profile:"
	toolbar.add_child(profile_lbl)

	var profile_opt := OptionButton.new()
	profile_opt.custom_minimum_size.x = 180
	toolbar.add_child(profile_opt)

	# The dropdown popup is a sub-Window. Our modloader Window is always_on_top,
	# which leaves the popup stranded behind it (invisible on click). Mark the
	# popup always_on_top and transient so it layers over us correctly. Theme
	# assignment is explicit -- theme lookup doesn't always cross Window boundaries.
	var profile_popup := profile_opt.get_popup()
	profile_popup.always_on_top = true
	profile_popup.transient = true
	if _ui_window != null and _ui_window.theme != null:
		profile_popup.theme = _ui_window.theme

	# Fresh install has no profile sections yet -- show Default as a placeholder
	# that gets materialized on the first _save_ui_config (Launch or any toggle).
	# Filter modpack-managed profiles ("modpack__*", "_before_modpack_*") so
	# they don't appear in the user-facing dropdown -- those are handled by
	# the Modpacks tab and are not user-named profiles.
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

	# When a modpack is active, the active profile is "modpack__X" which the
	# filter above hides -- so the dropdown's selection defaults back to
	# Vanilla which is misleading. Disable the dropdown (and replace its
	# label) so it's clear the user has to Unload the modpack via the banner
	# to interact with regular profiles.
	if active_modpack != "":
		profile_opt.clear()
		profile_opt.add_item("[Modpack: " + active_modpack + "]")
		profile_opt.selected = 0
		profile_opt.disabled = true

	# Profile-mutation buttons. Delete needs at least one other profile to
	# switch to. ALL profile mutations are disabled while a modpack is
	# active -- the active profile slot is modpack-managed (modpack__X) and
	# shouldn't be renamed/deleted/created-from.
	var modpack_locked := active_modpack != ""
	# Whether mod state in the active profile can be edited at all. Vanilla is
	# the all-off sentinel (no stored profile to write to) and a modpack-locked
	# slot is managed by the pack -- in both, the per-row dependency quick
	# actions (Enable dependency / Load anyway / Re-check) would mutate state
	# that _save_ui_config won't persist, so they're hidden. (Restores the
	# on_vanilla gate the Modpacks merge dropped, now also covering the lock.)
	var profile_editable := _active_profile != VANILLA_PROFILE and not modpack_locked

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

	# Share/save/load lives in the Modpacks tab.

	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	toolbar.add_child(spacer)

	# Launcher zoom, user-owned. Auto-detecting it from screen DPI compounded
	# with the game's own canvas_items stretch and blew the window up on
	# high-res displays (see _show_mod_ui), and no single formula fits every
	# monitor -- so this is an explicit choice that applies immediately.
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
		# Written straight through rather than via _save_ui_config: this is a
		# display preference, and the full save rewrites profile state we have
		# no reason to touch here.
		var scfg := ConfigFile.new()
		scfg.load(UI_CONFIG_PATH)
		scfg.set_value("settings", "ui_scale", sv)
		_persist_ui_cfg(scfg)
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
		# Persist the new developer_mode (load-affecting: it changes which
		# mods are eligible). The boot launcher is rescued by the Launch-time
		# save, but the post-boot reopen path has no closing save, so without
		# this the toggle silently reverts next launch.
		_save_ui_config()
		_rebuild_mods_tab(tabs)
	)

	outer.add_child(HSeparator.new())

	var split := HSplitContainer.new()
	split.split_offset = 560
	split.size_flags_vertical = Control.SIZE_EXPAND_FILL
	outer.add_child(split)

	# -- Left: filter bar + mod list ------------------------------------------

	# Sticky filter bar above the scroll so it stays in view while the user
	# scrolls a long mod list.
	var left_col := VBoxContainer.new()
	left_col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	left_col.size_flags_vertical = Control.SIZE_EXPAND_FILL
	split.add_child(left_col)

	# Filter bar (W2/W3): name search + All / None toggles + Hide disabled.
	# The All/None handlers respect the active filter so a search-narrowed
	# list only toggles the visible subset. Hide disabled is per-profile;
	# Vanilla disables the toggles since rows are forced off there anyway.
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

	# Check Updates: queries ModWorkshop for every installed mod with valid
	# [updates] modworkshop= + version. Populates _mod_updates_state so the
	# rows below show per-mod "update available" badges without users having
	# to switch to the Updates tab. The Updates tab stays around for the
	# bulk-status view.
	var check_btn := Button.new()
	# "Checking..." not "Checking for updates..." here: the filter bar is
	# space-constrained and a wide button squeezes the filter box mid-check.
	check_btn.text = "Check for updates"
	if _mod_updates_check_in_progress:
		check_btn.disabled = true
		check_btn.text = "Checking..."
	filter_bar.add_child(check_btn)
	_wire_hint(check_btn, "Check ModWorkshop for newer versions of your installed mods. Mods that don't list a ModWorkshop page are skipped.")
	check_btn.pressed.connect(func():
		if _mod_updates_check_in_progress:
			return
		check_btn.disabled = true
		check_btn.text = "Checking..."
		var summary := await _run_updates_check_for_mods()
		# A mid-check rebuild (filter keystroke, toggle) frees the original
		# button -- only skip the direct button touches then; the rebuild and
		# the toast must still run or the completed check's results are
		# silently dropped and the NEW button (created disabled while the
		# flag was up) strands at "Checking...".
		if is_instance_valid(check_btn):
			check_btn.disabled = false
			check_btn.text = "Check for updates"
		if is_instance_valid(tabs):
			_rebuild_mods_tab(tabs)
		# Surface a one-liner so the user knows something happened even when
		# nothing is out of date -- and be honest when checks ERRORED rather
		# than counting unreachable mods as "up to date".
		var n := int(summary.get("with_updates", 0))
		var ck := int(summary.get("checked", 0))
		var er := int(summary.get("errors", 0))
		var msg := ""
		if ck == 0:
			msg = "No installed mods have ModWorkshop update info, so there is nothing to check."
		elif er >= ck:
			msg = "Could not reach ModWorkshop. Check your connection and try again."
		elif n == 0:
			msg = "Everything is up to date. Checked %d mod(s)." % (ck - er)
			if er > 0:
				msg += " %d could not be checked." % er
		else:
			msg = "%d update(s) available." % n
			if er > 0:
				msg += " %d could not be checked." % er
		# Only toast while the launcher window still exists. If the user
		# clicked Launch (or closed the launcher) mid-check, _ui_window is
		# null and _attach_ui_dialog would parent an exclusive always-on-top
		# dialog to the game's root -- stealing input mid-game. The rebuild
		# above already covered the surviving-UI case.
		if is_instance_valid(_ui_window):
			_show_info_toast(msg)
	)

	# Debounce the filter rebuild: text_changed fires per keystroke, and every
	# _rebuild_mods_tab is a full tear-down with synchronous disk work (config
	# loads, modpack zip parse, thumbnail decodes) -- typing a word used to
	# cost one full rebuild per letter. Same pattern as the Browse search box:
	# keystrokes only store the text and restart the timer; the timeout does
	# the one rebuild. The timer lives in the tab, so a rebuild from another
	# surface frees it mid-wait -- harmless, since that rebuild already renders
	# the stored _mods_filter_text.
	var filter_debounce := Timer.new()
	filter_debounce.one_shot = true
	filter_debounce.wait_time = 0.25
	filter_bar.add_child(filter_debounce)
	filter_debounce.timeout.connect(func():
		# Restore focus after the rebuild so the user can keep typing.
		# Flag is consumed on the next build below.
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
		# Bulk None disables content mods too -- run the same save-compatibility
		# confirm the per-row checkbox uses, once for the whole batch.
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

	var left_scroll := ScrollContainer.new()
	left_scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	left_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	left_col.add_child(left_scroll)
	_ui_mods_scroll = left_scroll

	# Right padding keeps the load-order SpinBox arrows from sitting flush
	# against the vertical scrollbar -- users were hitting the spin arrows
	# while trying to drag the scrollbar handle.
	var list_pad := MarginContainer.new()
	list_pad.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	list_pad.add_theme_constant_override("margin_right", SP_XL)
	left_scroll.add_child(list_pad)

	var list := VBoxContainer.new()
	list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	list_pad.add_child(list)

	# -- Right: live load order preview ----------------------------------------

	var right := VBoxContainer.new()
	right.custom_minimum_size.x = 220
	split.add_child(right)

	var order_header := Label.new()
	order_header.text = "Load order"
	order_header.add_theme_font_size_override("font_size", FS_HEAD)
	order_header.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	right.add_child(order_header)
	right.add_child(HSeparator.new())

	# Dark panel behind the load order list for visual separation.
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
	# Belt-and-suspenders against the autowrap/scrollbar layout-oscillation bug
	# guarded below: pin the scrollbar to always-visible so it can't flip on/off
	# at the bistable height threshold. With this set, even if a future change
	# reintroduces autowrap on the order labels, the inner width stays constant
	# (no width oscillation -> no reshape feedback loop). See refresh_order.
	order_scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_SHOW_ALWAYS
	order_panel.add_child(order_scroll)

	var order_list := VBoxContainer.new()
	order_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	order_scroll.add_child(order_list)

	# Rebuilds the right-side order list from current entry state.
	var refresh_order := func():
		# _refresh_dependency_status already ran the full resolution pipeline
		# (priority sort + topological order + blocked-set fixpoint) and hands
		# back the same pick the loader itself uses -- the panel shows the
		# EFFECTIVE order, so what you see is what mounts. Reusing it matters
		# here: this closure fires per step while a load-order spin arrow is
		# held, and a second _loadable_enabled_entries call per tick doubled
		# the whole pipeline.
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
			# This panel is narrow: short lines with a MANUAL break
			# (deterministic -- never autowrap here, see the oscillation fix).
			order_list.add_child(_make_sub_label(
					"%d enabled, none will load\n(missing dependencies)" % enabled_count,
					COL_AMBER,
					"Every enabled mod is missing a required dependency.\nFix it from the orange row warnings, or use Load anyway."))
			return
		for i in loadable.size():
			var e: Dictionary = loadable[i]
			var lbl := Label.new()
			lbl.text = str(i + 1) + ".  " + e["mod_name"]
			lbl.add_theme_font_size_override("font_size", FS_EMPH)
			lbl.add_theme_color_override("font_color", COL_TEXT)
			# Previously AUTOWRAP_WORD_SMART. That combo (autowrap label inside
			# a fixed-width ScrollContainer) hits a Godot 4.6 layout-oscillation
			# bug: at certain (label count, text width) combinations the vertical
			# scrollbar's appearance shrinks the inner width by ~16px, which
			# triggers re-wrap, which changes total height, which flips scrollbar
			# visibility, etc. The oscillation floods the message queue with
			# deferred resize notifications and crashes with "Message queue out
			# of memory" + "Object was deleted while awaiting a callback" --
			# reproducible at 9 enabled mods with long names like
			# "RTVModLib Compatibility Layer". clip_text + tooltip preserves the
			# visual intent without engaging autowrap.
			lbl.clip_text = true
			lbl.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
			# Status-line hint, kept for the launcher's consistent hover-hint UX
			# (the old strand-behind-the-window tooltip bug is gone now that the
			# window embeds sub-windows). Full name shows in the bottom hint.
			lbl.mouse_filter = Control.MOUSE_FILTER_PASS
			order_list.add_child(lbl)
			_wire_hint(lbl, str(e["mod_name"]))
		if bool(pick["adjusted"]):
			var reorder_lbl := _make_sub_label("reordered for dependencies", COL_TEXT_DIM)
			order_list.add_child(reorder_lbl)
			_wire_hint(reorder_lbl, "A required mod was moved up so it loads before the mod that needs it. Your load-order numbers are unchanged.")
		var blocked_count := enabled_count - loadable.size()
		if blocked_count > 0:
			var blocked_lbl := _make_sub_label("%d blocked by dependencies" % blocked_count, COL_AMBER)
			order_list.add_child(blocked_lbl)
			_wire_hint(blocked_lbl, "Blocked mods stay checked but don't load. See the orange row warnings for fixes.")

	# -- Updates available ----------------------------------------------------
	# Compact triage list of mods with newer versions on ModWorkshop. Source
	# is _mod_updates_state which is populated by Check Updates in this tab
	# or in the Updates tab. Compact rows here so a long list (20+) stays
	# scannable; the regular mod rows below are unchanged (no bubbling, no
	# extra subsection) so this view doesn't compete with mod management.
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
		u_hdr.add_theme_color_override("font_color", COL_AMBER)
		# FS_HEAD to match the "Missing from this profile" header on this
		# same list (spec: section headings at FS_HEAD; color carries the
		# semantic difference).
		u_hdr.add_theme_font_size_override("font_size", FS_HEAD)
		u_hdr_row.add_child(u_hdr)
		# Count as an amber badge chip (the spec's one update-badge look).
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
			# Labels default to MOUSE_FILTER_IGNORE, which suppresses tooltips.
			u_name.mouse_filter = Control.MOUSE_FILTER_PASS
			upd_row.add_child(u_name)

			var u_ver := Label.new()
			u_ver.text = "v%s  ->  v%s" % [str(upd.get("current_version", "?")), str(upd.get("latest_version", "?"))]
			u_ver.add_theme_color_override("font_color", COL_TEXT)
			u_ver.add_theme_font_size_override("font_size", FS_BODY)
			u_ver.custom_minimum_size.x = 160
			# A long prerelease string must not widen the column and push the
			# Update button out of alignment.
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
			# If a download for this pk is already running (this row was rebuilt
			# mid-download), render the button inert instead of a fresh "Update".
			if _mod_update_in_flight.has(pk):
				u_btn.disabled = true
				u_btn.text = "Updating..."
			u_btn.pressed.connect(func():
				if not is_instance_valid(u_btn):
					return
				# Refuse a second concurrent download of the same mod.
				if _mod_update_in_flight.has(captured_pk):
					return
				_mod_update_in_flight[captured_pk] = true
				u_btn.disabled = true
				u_btn.text = "Updating..."
				var mw_id: int = int(captured_upd.get("mw_id", 0))
				# Re-resolve the path live: another surface (Updates tab) may have
				# updated/renamed this file since the badge row was built, which
				# would leave the captured path pointing at a file that no longer
				# exists (the repeatable "Update Failed").
				var full_path: String = _live_full_path(captured_pk, str(captured_upd.get("full_path", "")))
				var result: Dictionary = await download_and_replace_mod(full_path, mw_id)
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
						# A mid-download rebuild freed the original button and rendered
						# its replacement disabled at "Updating..." while the in-flight
						# flag was set. The flag is erased now, so rebuild so the fresh
						# row shows an actionable Update button again (same recovery the
						# Check-for-updates handler uses).
						_rebuild_mods_tab(tabs)
					# Error pattern: what happened + what to do next; never a
					# bare "unknown".
					var err_name := str(captured_upd.get("mod_name", "this mod"))
					var err_msg := "Could not download %s. Check your connection and try again." % err_name
					var err_detail := str(result.get("error", ""))
					if err_detail != "" and err_detail != "unknown":
						err_msg += "\n\nDetails: " + err_detail
					# Only surface the dialog if the launcher is still open. If the
					# user hit Launch mid-download, _ui_window is freed and
					# _attach_ui_dialog would parent an exclusive, always-on-top
					# dialog to the game root, stealing input mid-session (same
					# guard the check-updates toast uses).
					if is_instance_valid(_ui_window):
						_show_error_dialog("Update failed", err_msg)
			)
			list.add_child(HSeparator.new())

	# -- Missing from this profile --------------------------------------------
	# Mods the active profile references but that aren't on disk. Shown at the
	# top of the list so they get attention before the regular mod rows; each
	# has a Remove button to strip the orphaned keys from the profile. Future:
	# offer to download via modworkshop if an id is stored.
	var missing_files := _missing_mods_in_active_profile()
	if not missing_files.is_empty():
		# Header row: label on the left, "Remove all" on the right (W4) so a
		# user with a long migration trail can clear every orphan in one click
		# instead of hammering per-row Remove buttons.
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
		# Compute sources once per Mods-tab build, not per row. Covers
		# persisted cache (any profile) + active modpack zip overlay.
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

			# Download button when the active modpack carries source info for
			# this entry. Falls back to just Remove when no source is known --
			# e.g. user manually disabled a mod then deleted the file, or the
			# modpack zip is gone.
			var src_v: Variant = missing_sources.get(fn)
			var src_mws_id: int = 0
			var src_version: String = ""
			if src_v is Dictionary:
				var src: Dictionary = src_v
				src_mws_id = int(src.get("modworkshop_id", 0))
				src_version = str(src.get("version", ""))
			if src_mws_id > 0:
				var dl_btn := Button.new()
				dl_btn.text = "Download"
				dl_btn.tooltip_text = "Download this mod from ModWorkshop"
				miss_row.add_child(dl_btn)
				_wire_hint(dl_btn, "Download this mod from ModWorkshop.")
				var captured_mws_id := src_mws_id
				var captured_version := src_version
				# Reuse _mod_update_in_flight keyed by the missing entry's stored
				# profile key (can't collide with update rows -- a missing entry
				# has no installed row). Without this, a mid-download rebuild
				# recreates the row with a fresh enabled button and a second
				# click installs a duplicate archive via rename-on-collision.
				var captured_fn := fn
				if _mod_update_in_flight.has(fn):
					dl_btn.disabled = true
					dl_btn.text = "Downloading..."
				dl_btn.pressed.connect(func():
					if not is_instance_valid(dl_btn):
						return
					if _mod_update_in_flight.has(captured_fn):
						return
					_mod_update_in_flight[captured_fn] = true
					dl_btn.disabled = true
					dl_btn.text = "Downloading..."
					# allow_rename_on_collision=true: a different version may
					# already exist under the same filename. Dedup at scan time.
					var r: Dictionary = await download_new_mod(captured_mws_id, captured_version, true)
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
							# A mid-download rebuild freed the original button and
							# left its replacement disabled at "Downloading..."; the
							# flag is erased now, so rebuild to restore an actionable
							# button (same recovery as the Update handler).
							_rebuild_mods_tab(tabs)
						# Suppress the dialog if the launcher closed mid-download
						# (Launch pressed): _attach_ui_dialog would otherwise pop an
						# exclusive always-on-top window over the running game.
						if is_instance_valid(_ui_window):
							_show_error_dialog("Download failed", str(r.get("error", "Could not download this mod. Check your connection and try again.")))
				)
			else:
				# No source info -- name what's unavailable, not the data we
				# lack. Matches r2modman/Vortex pattern of action-clear
				# state strings. Label defaults to MOUSE_FILTER_IGNORE in
				# Godot 4, so explicit STOP is required for hover signals.
				var no_src_lbl := Label.new()
				no_src_lbl.text = "Download unavailable"
				no_src_lbl.add_theme_color_override("font_color", COL_TEXT_DIM)
				no_src_lbl.add_theme_font_size_override("font_size", FS_BODY)
				no_src_lbl.size_flags_vertical = Control.SIZE_SHRINK_CENTER
				no_src_lbl.mouse_filter = Control.MOUSE_FILTER_STOP
				miss_row.add_child(no_src_lbl)
				_wire_hint(no_src_lbl,
					"This mod is not linked to ModWorkshop, so it can't be downloaded automatically. Reinstall it manually.")

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

	# -- Column headers --------------------------------------------------------

	var header_row := HBoxContainer.new()
	list.add_child(header_row)

	var h_on := Label.new()
	h_on.text = "On"
	h_on.add_theme_font_size_override("font_size", FS_META)
	h_on.add_theme_color_override("font_color", COL_TEXT_DIM)
	h_on.custom_minimum_size.x = 30
	header_row.add_child(h_on)

	# Spacer over the per-row ModWorkshop thumbnail column so "Mod" stays above
	# the name text rather than the thumbnails.
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

	# Spacer matching the per-row trash button (28px) so the Load order
	# header sits over the SpinBox column instead of the trash column.
	var h_tail := Control.new()
	h_tail.custom_minimum_size.x = 28
	header_row.add_child(h_tail)

	list.add_child(HSeparator.new())

	# -- One row per mod -------------------------------------------------------

	if _ui_mod_entries.is_empty():
		var empty := Label.new()
		empty.text = "No mods found.\n\nPlace .vmz or .pck files in:\n" \
				+ ProjectSettings.globalize_path(_mods_dir)
		# No autowrap inside the mods ScrollContainer (layout-oscillation bug,
		# see the order-panel comment). Newlines still break lines; only the
		# long path line clips, with the full text on hover.
		empty.clip_text = true
		empty.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		empty.tooltip_text = empty.text
		empty.mouse_filter = Control.MOUSE_FILTER_PASS
		empty.add_theme_color_override("font_color", COL_TEXT_DIM)
		empty.add_theme_font_size_override("font_size", FS_EMPH)
		list.add_child(empty)

	# Track whether any row passed the filter so we can show a hint when a
	# search or hide-disabled toggle narrows the list to zero rows.
	var rendered_any := false
	# Hoisted once per build for _dependency_display_for_id: its fallback
	# rebuilds this whole map per call, and the row loop below calls it per
	# dependency for both the visible "needs:" line and the tooltip --
	# O(rows x deps x mods) rebuilds per keystroke without the hoist.
	var dep_names_by_id := _entries_by_mod_id(_ui_mod_entries)
	for entry in _ui_mod_entries:
		if not _mods_entry_visible(entry):
			continue
		rendered_any = true
		var row := HBoxContainer.new()
		list.add_child(row)

		var check := CheckBox.new()
		check.button_pressed = entry["enabled"]
		check.custom_minimum_size.x = 30
		row.add_child(check)

		# ModWorkshop info column, for mods that declare [updates] modworkshop=N.
		# Thumbnail (filled async) + author line + the name as a click-through to
		# the same detail dialog the Browse tab uses -- so a mod's page,
		# screenshots and description read in-app without hunting it down in
		# Browse. Non-MWS mods get a same-width spacer so the name column stays
		# aligned across every row.
		var row_cfg: ConfigFile = entry.get("cfg")
		var row_mws_id := 0
		if row_cfg != null and row_cfg.has_section_key("updates", "modworkshop"):
			row_mws_id = int(str(row_cfg.get_value("updates", "modworkshop", "0")))
		var mws_holder: Dictionary = {}
		var thumb_ref: TextureRect = null
		# EVERY row gets a real thumbnail cell, captioned "no thumbnail" from
		# the moment it is built. Previously a non-MWS mod got a bare invisible
		# spacer -- so a modlist of hand-installed mods showed nothing at all
		# where a thumbnail belongs -- and an MWS row sat as an unlabelled gray
		# panel until its meta fetch resolved, which is indistinguishable from
		# still-loading and never resolves at all while offline. A texture that
		# arrives later clears the caption (_set_thumb_ready).
		var thumb_rect := _make_thumb_cell(row, Vector2(96, 54), true, true)
		if row_mws_id > 0:
			thumb_ref = thumb_rect

		var name_col := VBoxContainer.new()
		name_col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		name_col.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		row.add_child(name_col)

		# name_ctrl is a LinkButton (MWS mods -> click for details) or a plain
		# Label; both take the enabled/blocked font-color overrides below.
		var name_ctrl: Control
		if row_mws_id > 0:
			# Flat Button (not LinkButton) so clip_text keeps a long name from
			# inflating the row's min width and forcing a horizontal scrollbar on
			# the whole list. Hover color is the click cue in place of underline.
			var name_lnk := Button.new()
			name_lnk.flat = true
			name_lnk.text = entry["mod_name"]
			name_lnk.clip_text = true
			name_lnk.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
			name_lnk.alignment = HORIZONTAL_ALIGNMENT_LEFT
			name_lnk.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			name_lnk.tooltip_text = str(entry["mod_name"]) + "  --  click for ModWorkshop details"
			name_lnk.add_theme_color_override("font_color", COL_OK if entry["enabled"] else COL_TEXT_DIM)
			name_lnk.add_theme_color_override("font_hover_color", COL_TEXT_HI)
			name_col.add_child(name_lnk)
			name_lnk.pressed.connect(_open_mods_mws_detail.bind(mws_holder))
			# Register the row's live nodes BEFORE kicking the meta load, so
			# both the synchronous memo-hit paint and any async completion
			# (including one from a fetch a PREVIOUS build started) resolve to
			# these current nodes instead of freed ones. Appended, not
			# assigned: several rows can share one workshop id.
			var meta_rows: Array = _mods_meta_nodes.get(row_mws_id, [])
			meta_rows.append({
				"thumb": thumb_ref,
				"name_col": name_col,
				"holder": mws_holder,
			})
			_mods_meta_nodes[row_mws_id] = meta_rows
			_mods_load_mws_meta(row_mws_id)
			name_ctrl = name_lnk
		else:
			var name_lbl := Label.new()
			name_lbl.text = entry["mod_name"]
			name_lbl.clip_text = true
			name_lbl.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
			name_lbl.tooltip_text = str(entry["mod_name"])
			# Labels default to MOUSE_FILTER_IGNORE, which suppresses tooltips.
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
		# -- Dependencies ------------------------------------------------------
		# One compact clipped line when the mod declares dependencies (names
		# over raw ids, full detail in the tooltip); the actionable blocked
		# row renders further down, after the generic warnings. No autowrap
		# anywhere in rows -- see the order-panel oscillation fix.
		var required_deps: Array = entry.get("required_dependencies", [])
		var optional_deps: Array = entry.get("optional_dependencies", [])
		var blockers_info: Array = entry.get("dependency_blockers_info", [])
		var dep_ignored := bool(entry.get("dependency_ignored", false))
		var dep_blocked: bool = entry["enabled"] \
				and not (entry.get("dependency_blockers", []) as Array).is_empty()
		if dep_blocked:
			# The green "enabled" tint would lie -- this mod won't load.
			name_ctrl.add_theme_color_override("font_color", COL_AMBER)
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
			name_col.add_child(_make_sub_label(warn_text, COL_AMBER, warn_text))
		for warn_text: String in entry.get("dependency_warnings", []):
			name_col.add_child(_make_sub_label(warn_text, COL_AMBER, warn_text))

		# Blocked: one orange line that says WHY + buttons that FIX it.
		# A warning the user can't act on is just decoration.
		if dep_blocked and not blockers_info.is_empty():
			var block_row := HBoxContainer.new()
			block_row.add_theme_constant_override("separation", SP_M)
			name_col.add_child(block_row)
			var first: Dictionary = blockers_info[0]
			# display already reads "Name (id)" for installed deps; a dash, not
			# another paren, so it doesn't render "...(id) (installed but...)".
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
			var bl := _make_sub_label("won't load -- needs " + why, COL_AMBER, "\n".join(btip))
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
			# Override active while requirements are still unmet: show what's
			# being ignored and the way back.
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

		# Older same-id archives the dedup pass hid. Surface the filename
		# so the user knows which one to delete from the mods/ folder.
		for dup: Dictionary in entry.get("duplicates_hidden", []):
			var dup_v_raw: String = str(dup.get("version", ""))
			var dup_v: String = ("v" + dup_v_raw) if dup_v_raw != "" else "(unversioned)"
			var hide_text := "older version hidden: " + str(dup["file_name"]) + " (" + dup_v + ")"
			name_col.add_child(_make_sub_label(hide_text, COL_AMBER, hide_text))

		# Profile was saved with a different version of this mod. Surface the
		# change so the user knows their enabled/priority state was carried
		# over across the upgrade/downgrade rather than silently re-defaulted.
		var vm: Dictionary = entry.get("profile_version_mismatch", {})
		if not vm.is_empty():
			var stored_v: String = str(vm.get("stored", ""))
			var current_v: String = str(vm.get("current", ""))
			var stored_disp := stored_v if stored_v != "" else "(unset)"
			var current_disp := current_v if current_v != "" else "(unset)"
			var vm_text := "version changed: " + stored_disp + " -> " + current_disp
			name_col.add_child(_make_sub_label(vm_text, COL_AMBER, vm_text))

		# Scanner indicator. Only renders for RED risk -- mods whose source
		# combines patterns that are nearly diagnostic of malware (dropper
		# trinity, anti-debug crash, ransomware setup). Yellow ("uses
		# notable APIs") is computed and logged but deliberately not shown
		# in the UI: most legit mods have at least one elevated API and
		# surfacing every one would just generate help-channel noise.
		# Loading is never blocked either way; the user judges.
		var risk: int = int(entry.get("risk_level", 0))
		if risk == 2:
			var sec_btn := Button.new()
			sec_btn.text = "suspicious code"
			sec_btn.flat = true
			sec_btn.tooltip_text = "Show what the scanner flagged in this mod"
			sec_btn.add_theme_color_override("font_color", COL_ERR)
			# Brightened on hover: flat buttons have no hover stylebox, so
			# the font shift is the only hover cue (matches _make_row_action).
			sec_btn.add_theme_color_override("font_hover_color", COL_ERR.lerp(COL_TEXT_HI, 0.35))
			sec_btn.add_theme_font_size_override("font_size", FS_BODY)
			sec_btn.alignment = HORIZONTAL_ALIGNMENT_LEFT
			sec_btn.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
			name_col.add_child(sec_btn)
			var captured_entry := entry
			sec_btn.pressed.connect(func(): _show_security_findings_dialog(captured_entry))

		var spin := SpinBox.new()
		spin.min_value = PRIORITY_MIN
		spin.max_value = PRIORITY_MAX
		spin.value = entry["priority"]
		spin.custom_minimum_size.x = 100
		spin.custom_minimum_size.y = CTRL_H
		row.add_child(spin)

		# Per-row Remove. Folder mods (dev) skip the file delete because
		# DirAccess.remove_absolute is for files only and recursive deletion
		# of a working directory is too risky to do casually -- the user
		# can use Open Mods Folder for those.
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
			# Disabling a mod that registers game content can stop an existing
			# save that uses it from loading (the content lives only in the
			# per-launch registry -- see Limitations). Confirm first; if the user
			# backs out, revert the checkbox without re-firing toggled.
			if not on and bool(e.get("has_registry", false)):
				var ok: bool = await _confirm_disable_content_mod(str(e.get("mod_name", "this mod")))
				if not ok:
					# An async rebuild (e.g. an updates check finishing) may
					# have freed this checkbox while the dialog was open; the
					# rebuilt row already renders from the unchanged entry.
					if is_instance_valid(check):
						check.set_pressed_no_signal(true)
					return
			# Apply to the LIVE entry dict regardless of whether the original
			# checkbox survived a mid-dialog rebuild. The captured dict stays
			# live across rebuilds, but a mid-dialog RESCAN (e.g. a Browse
			# download finishing) replaces _ui_mod_entries with fresh dicts --
			# re-resolve so a confirmed disable is never dropped.
			var live := _live_entry_for_profile_key(str(e.get("profile_key", "")), e)
			live["enabled"] = on
			# Full rebuild via the shared tail: dependency state on OTHER
			# rows changes with the new enabled set.
			_after_dep_action(tabs)
		)
		spin.value_changed.connect(func(val: float):
			# Write through the LIVE entry like the checkbox handler above: a
			# mid-drag rescan (e.g. a background download finishing) replaces
			# _ui_mod_entries with fresh dicts, orphaning the captured `e` --
			# later ticks written into it would never be saved.
			var live_spin := _live_entry_for_profile_key(str(e.get("profile_key", "")), e)
			live_spin["priority"] = int(val)
			# No rebuild here: value_changed fires per step while the arrows
			# are held, and rebuilding would destroy the SpinBox under the
			# cursor. refresh_order recomputes dependency status for the
			# order panel; per-row order warnings catch up on the next
			# rebuild (toggle, filter, profile switch, tab re-entry).
			refresh_order.call()
			# Debounce the disk save: holding/scrolling the arrow fires
			# value_changed per step (200+ over one drag), and each
			# _save_ui_config is a full ConfigFile load+rewrite. Coalesce to a
			# save shortly after activity settles; the launch-time save in
			# lifecycle catches the final value regardless.
			_schedule_priority_save()
		)

	# Filter narrowed every row out -- distinguish from "no mods installed"
	# (handled above by the _ui_mod_entries.is_empty() branch) so the user
	# knows the filter, not a missing folder, is the cause.
	if not _ui_mod_entries.is_empty() and not rendered_any:
		var no_match := Label.new()
		no_match.text = "No mods match. Try a shorter search or turn off Hide disabled."
		no_match.add_theme_color_override("font_color", COL_TEXT_DIM)
		no_match.add_theme_font_size_override("font_size", FS_EMPH)
		list.add_child(no_match)

	# Restore focus to the search input after a filter-driven rebuild.
	# Deferred so the new tab is in the tree before grab_focus runs.
	# Cleared on consume so unrelated rebuilds (profile switch, dev toggle)
	# don't steal focus from whatever the user is interacting with.
	if _mods_filter_focus_pending:
		_mods_filter_focus_pending = false
		filter_edit.call_deferred("grab_focus")
		# Setting LineEdit.text resets the caret to column 0 (Godot 4.6
		# LineEdit::_set_text), and FOCUS_ENTER doesn't move it -- so without
		# this every keystroke after the first inserts at the FRONT ("dep"
		# typed -> "ped"). Restore the caret to end-of-text after focus lands.
		filter_edit.call_deferred("set_caret_column", filter_edit.text.length())

	refresh_order.call()
	# Wrap in the shared tab margin like build_browse_tab / build_modpacks_tab /
	# build_updates_tab, so the Mods tab has the same content padding and the
	# view doesn't visibly shift when switching between tabs.
	var margin := _make_tab_margin()
	margin.add_child(outer)
	return margin

