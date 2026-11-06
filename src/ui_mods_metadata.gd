## Host thumbnails and authors on the Mods-tab rows.

# The host seam caches only successes, so failures would refetch on every rebuild:
# successes stay for the session, failures wait out a retry window.
var _mods_meta_by_key: Dictionary = {}
var _mods_meta_retry_at: Dictionary = {}
const _MODS_META_RETRY_MS := 60000

# ref_key -> unix time of the last real fetch. Only these keys reach the sidecar;
# snapshot-sourced records stay session-only and are never refreshed.
var _mods_meta_saved_at: Dictionary = {}
var _mods_meta_sidecar_loaded: bool = false
var _mods_meta_unsaved := false

# {"<ref_key>": {"mod": <ModDetail>, "saved_at": unix}}; older than a day soft-refreshes.
const _MODS_META_SIDECAR_PATH := UI_CACHE_DIR + "/mods_meta_v2.json"
const _MODS_META_REFRESH_SEC := 86400

# Parallel per-row fetches could drain a host's rate budget, so one loop drains the queue.
var _mods_meta_fetch_queue: Array[Dictionary] = []
var _mods_meta_fetch_active := false

func _mods_meta_record_complete(mod: Dictionary) -> bool:
	for k in host_empty_summary():
		if not mod.has(k):
			return false
	return mod["ref"] is Dictionary and mod["thumbnail"] is Dictionary and host_ref_valid(mod["ref"])

# Seeds the memo from the sidecar once. A hand-edited file loses the bad entries, not the launcher.
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
		# JSON brings saved_at back as a float.
		var saved_v: Variant = (entry_v as Dictionary).get("saved_at", 0)
		if not (saved_v is int or saved_v is float) or int(saved_v) <= 0:
			continue
		# A fetch this session may already have memoized fresher data.
		if not _mods_meta_by_key.has(key):
			_mods_meta_by_key[key] = mod_v
			_mods_meta_saved_at[key] = int(saved_v)

# Paints every current row of `key`; one host mod can back several rows.
func _paint_host_meta(key: String, data: Dictionary) -> void:
	for nodes: Dictionary in _mods_meta_nodes.get(key, []):
		var thumb: TextureRect = nodes["thumb"]
		var image: Dictionary = data["thumbnail"]
		if str(image.get("url", "")) != "":
			_browse_load_thumbnail_async(thumb, image)
		else:
			_set_thumb_state(thumb, "none")
		var name_col: VBoxContainer = nodes["name_col"]
		var author := str(data["author_name"])
		if not name_col.has_node("HostAuthorLabel") and author != "":
			var author_lbl := _make_sub_label("by " + author, COL_TEXT_DIM, "")
			author_lbl.name = "HostAuthorLabel"
			name_col.add_child(author_lbl)
			name_col.move_child(author_lbl, 1)

# A failed soft refresh keeps the record and texture the row already shows.
func _paint_meta_failed(key: String) -> void:
	if _mods_meta_by_key.has(key):
		return
	for nodes: Dictionary in _mods_meta_nodes.get(key, []):
		_set_thumb_state(nodes["thumb"], "failed")

# Queues ref; the first caller becomes the drain loop and later ones only append.
# The retry window is armed before the call, so the queue needs no dedupe.
func _fetch_meta_queued(ref: Dictionary) -> void:
	_mods_meta_fetch_queue.append(ref)
	if _mods_meta_fetch_active:
		return
	_mods_meta_fetch_active = true
	while not _mods_meta_fetch_queue.is_empty():
		var next: Dictionary = _mods_meta_fetch_queue.pop_front()
		var key := host_ref_key(next)
		if host_rate_cooldown_seconds(str(next["provider"])) > 0:
			# Skipped, not fetched: the row still has to stop saying "loading...".
			_paint_meta_failed(key)
			continue
		var res := await host_get_mod(next)
		if not (res["ok"] and _mods_meta_record_complete(res["data"])):
			_paint_meta_failed(key)
			continue
		_mods_meta_by_key[key] = res["data"]
		_mods_meta_saved_at[key] = int(Time.get_unix_time_from_system())
		_mods_meta_unsaved = true
		_paint_host_meta(key, res["data"])
	_mods_meta_fetch_active = false
	_mods_meta_sidecar_save()

# Also called as the launcher closes: a Launch that restarts the game cuts the queue short.
func _mods_meta_sidecar_save() -> void:
	if not _mods_meta_unsaved:
		return
	_mods_meta_unsaved = false
	var out := {}
	for k in _mods_meta_saved_at:
		out[k] = {"mod": _mods_meta_by_key[k], "saved_at": _mods_meta_saved_at[k]}
	DirAccess.make_dir_recursive_absolute(_MODS_META_SIDECAR_PATH.get_base_dir())
	var f := FileAccess.open(_MODS_META_SIDECAR_PATH, FileAccess.WRITE)
	if f != null:
		f.store_string(JSON.stringify(out))
		f.close()

# False while an earlier attempt's window is open, so racing rebuilds share one request.
func _arm_meta_retry(key: String) -> bool:
	if Time.get_ticks_msec() < int(_mods_meta_retry_at.get(key, 0)):
		return false
	_mods_meta_retry_at[key] = Time.get_ticks_msec() + _MODS_META_RETRY_MS
	return true

func _load_host_meta(ref: Dictionary) -> void:
	var key := host_ref_key(ref)
	_mods_meta_sidecar_load()
	if _mods_meta_by_key.has(key):
		_paint_host_meta(key, _mods_meta_by_key[key])
		var saved_at := int(_mods_meta_saved_at.get(key, 0))
		if saved_at <= 0 or int(Time.get_unix_time_from_system()) - saved_at < _MODS_META_REFRESH_SEC:
			return
		if _arm_meta_retry(key):
			_fetch_meta_queued(ref)
		return
	if not _arm_meta_retry(key):
		return
	var snap := _browse_landing_snapshot(str(ref["provider"]))
	for sec: Dictionary in snap.get("sections", []):
		for row: Dictionary in sec["rows"]:
			if host_ref_key(row["ref"]) == key:
				_mods_meta_by_key[key] = row
				_paint_host_meta(key, row)
				return
	_fetch_meta_queued(ref)

# A row's memo record is painted the moment it lands, so the memo is what the row shows.
func _open_host_detail(ref: Dictionary) -> void:
	var key := host_ref_key(ref)
	if _mods_meta_by_key.has(key):
		# The mod is installed, so the dialog shows Installed and never calls on_get.
		_show_browse_mod_detail_dialog(_mods_meta_by_key[key], func(_d, _b): pass)
		return
	var host := host_display_name(str(ref["provider"]))
	_show_accept_dialog(host + " details",
			"Still loading this mod's " + host + " page (or it's unavailable offline). Try again in a moment.",
			"Close", 380)
