## Mods-tab host detail cache and background fetch queue.
## Updates the current row controls through _mods_meta_nodes.

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
# user://mws_cache/. Stale entries soft-refresh.
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
				_set_thumb_state(thumb_rect, "none")
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
			_set_thumb_state(thumb_v as TextureRect, "failed")

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
		var key := host_ref_key(next)
		if host_rate_cooldown_seconds(provider) > 0:
			# Skipped, not fetched: the row still has to stop saying "loading...".
			_mods_meta_fetch_failed(key)
			continue
		var res := await host_get_mod(next)
		var fetch_ok := false
		if res["ok"] and res["data"] is Dictionary and _mods_meta_record_complete(res["data"]):
			fetch_ok = true
			_mods_meta_by_key[key] = res["data"]
			_mods_meta_sidecar_store(key)
			_mods_apply_host_meta(key, res["data"])
		if not fetch_ok:
			_mods_meta_fetch_failed(key)
	_mods_meta_fetch_active = false

# A row with no memoized record is captioned "load failed"; a failed soft
# refresh keeps the record and texture it already shows.
func _mods_meta_fetch_failed(key: String) -> void:
	var memo_v: Variant = _mods_meta_by_key.get(key)
	if not (memo_v is Dictionary) or (memo_v as Dictionary).is_empty():
		_mods_paint_meta_failed(key)

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
