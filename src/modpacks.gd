## Modpacks: a mods/*.zip with profile.json at its root, applied as its own profile slot.

const MODPACK_PROFILE_PREFIX := "modpack__"
const MODPACK_BACKUP_PREFIX := "_before_modpack_"

## Serializes apply and retry, which race on cfg writes and the backup slot.
var _modpack_apply_in_progress: bool = false
var _modpack_host_ids_asked: Dictionary = {}
## Stamped with mtime and size: a pack check can hash the same 100 MB file many times.
var _modpack_sha256_cache: Dictionary = {}
## {path: {stamp, is_pack, profile}}: launcher tabs rescan mods/ often, and most zips never change.
var _modpack_zip_memo: Dictionary = {}

func _is_modpack_managed_profile(profile_name: String) -> bool:
	return profile_name.begins_with(MODPACK_PROFILE_PREFIX) \
			or profile_name.begins_with(MODPACK_BACKUP_PREFIX)

func _count_truthy(d: Dictionary) -> int:
	var count := 0
	for k in d:
		if _json_truthy(d[k]):
			count += 1
	return count

func _pack_dict(d: Variant, field: String) -> Dictionary:
	if not (d is Dictionary):
		return {}
	var v: Variant = d.get(field)
	return v if v is Dictionary else {}

func _parse_profile_bytes(bytes: PackedByteArray) -> Variant:
	if bytes.is_empty():
		return null
	var parsed: Variant = JSON.parse_string(bytes.get_string_from_utf8())
	return parsed if parsed is Dictionary else null

func _modpack_read_profile(file_path: String) -> Variant:
	if not FileAccess.file_exists(file_path):
		return null
	var profile: Variant = _modpack_zip_info(file_path)["profile"]
	return profile.duplicate(true) if profile is Dictionary else null

# Stamped with mtime and size, like _cached_sha256.
func _modpack_zip_info(file_path: String) -> Dictionary:
	var stamp := "%d:%d" % [FileAccess.get_modified_time(file_path), FileAccess.get_size(file_path)]
	var memo: Dictionary = _modpack_zip_memo.get(file_path, {})
	if memo.get("stamp", "") == stamp:
		return memo
	memo = {"stamp": stamp, "is_pack": false, "profile": null}
	var reader := ZIPReader.new()
	if reader.open(file_path) == OK:
		memo["is_pack"] = reader.get_files().has("profile.json")
		if memo["is_pack"]:
			memo["profile"] = _parse_profile_bytes(reader.read_file("profile.json"))
		reader.close()
	_modpack_zip_memo[file_path] = memo
	return memo

func _validate_modpack(entry: Dictionary) -> Dictionary:
	var file_path: String = str(entry.get("file_path", ""))
	if file_path.is_empty():
		return {"ok": false, "error": "Modpack has no file path"}
	if not FileAccess.file_exists(file_path):
		return {"ok": false, "error": "Modpack file no longer exists at:\n" + file_path}
	var reader := ZIPReader.new()
	if reader.open(file_path) != OK:
		return {"ok": false, "error": "Cannot open modpack zip (corrupt or in use)"}
	if not ("profile.json" in reader.get_files()):
		reader.close()
		return {"ok": false, "error": "This file is not a valid modpack (no mod list inside). Get a fresh copy of the modpack and try again."}
	var bytes := reader.read_file("profile.json")
	reader.close()
	if bytes.is_empty():
		return {"ok": false, "error": "This modpack file is damaged (its mod list is empty). Get a fresh copy and try again."}
	var parsed: Variant = _parse_profile_bytes(bytes)
	if parsed == null:
		return {"ok": false, "error": "This modpack file is damaged (its mod list is unreadable). Get a fresh copy and try again."}
	var pd: Dictionary = parsed
	# Present but null in a hand-edited pack; int(null) is a constructor error.
	var mp_raw: Variant = pd.get("metroprofile", 0)
	var mp_ver: int = int(mp_raw) if (mp_raw is int or mp_raw is float) else 0
	if mp_ver < 1:
		return {"ok": false, "error": "This modpack file is damaged (it has no format version). Get a fresh copy and try again."}
	if mp_ver != 1:
		return {"ok": false, "error": "This modpack was made for a newer version of the mod loader -- update the mod loader and try again"}
	if not (pd.get("name") is String):
		return {"ok": false, "error": "This modpack file is damaged (it has no name). Get a fresh copy and try again."}
	if not (pd.get("enabled") is Dictionary):
		return {"ok": false, "error": "This modpack file is damaged (its mod list is missing). Get a fresh copy and try again."}
	var enabled: Dictionary = pd["enabled"]
	return {"ok": true, "error": "", "enabled_count": _count_truthy(enabled), "total_count": enabled.size()}

func _is_modpack_zip(file_path: String) -> bool:
	return _modpack_zip_info(file_path)["is_pack"]

func _build_modpack_entry(file_path: String) -> Dictionary:
	var pd: Variant = _modpack_read_profile(file_path)
	if pd == null:
		return {}
	var raw_name := _host_str(pd.get("name")).strip_edges()
	if raw_name == "":
		raw_name = file_path.get_file().get_basename()
	var enabled := _pack_dict(pd, "enabled")
	var hosted := _pack_dict(pd, "hosted")
	return {
		"file_path": file_path,
		"file_name": file_path.get_file(),
		"raw_name": raw_name,
		"description": str(pd.get("description", "")).strip_edges(),
		"author": str(pd.get("author", "")).strip_edges(),
		"sanitized_name": _sanitize_profile_name(raw_name),
		"enabled_count": _count_truthy(enabled),
		"total_count": enabled.size(),
		"hosted": hosted,
		"thumbnail_url": _host_str(hosted.get("thumbnail_url")),
	}

func collect_modpack_metadata() -> Array[Dictionary]:
	var entries: Array[Dictionary] = []
	var mods_dir := _mods_dir_path()
	var dir := DirAccess.open(mods_dir)
	if dir == null:
		return entries
	dir.list_dir_begin()
	while true:
		var name := dir.get_next()
		if name == "":
			break
		var full := mods_dir.path_join(name)
		if dir.current_is_dir() or name.get_extension().to_lower() != "zip" or not _is_modpack_zip(full):
			continue
		var entry := _build_modpack_entry(full)
		if not entry.is_empty():
			entries.append(entry)
	dir.list_dir_end()
	if entries.size() < 2:
		return entries

	# Same-named hosted packs: all but the smallest slug get the slug in their slot name.
	var slugs_by_name: Dictionary = {}
	for e in entries:
		var slug := str(e["hosted"].get("slug", ""))
		if slug != "":
			(slugs_by_name.get_or_add(e["sanitized_name"], {}) as Dictionary)[slug] = true
	for e in entries:
		var slug := str(e["hosted"].get("slug", ""))
		var group: Dictionary = slugs_by_name.get(e["sanitized_name"], {})
		if slug == "" or group.size() <= 1:
			continue
		var slugs := group.keys()
		slugs.sort()
		if slug != str(slugs[0]):
			e["sanitized_name"] = _sanitize_profile_name(str(e["raw_name"]) + " " + slug)

	# One sanitized_name for two zips would render both active: the newest by mtime wins.
	var by_sanitized: Dictionary = {}
	for e in entries:
		if e["sanitized_name"] != "":
			(by_sanitized.get_or_add(e["sanitized_name"], []) as Array).append(e)
	var deduped: Array[Dictionary] = []
	for bucket: Array in by_sanitized.values():
		var kept: Dictionary = bucket[0]
		if bucket.size() > 1:
			bucket.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
				return FileAccess.get_modified_time(a["file_path"]) > FileAccess.get_modified_time(b["file_path"])
			)
			kept = bucket[0]
			var dups: Array = []
			for i in range(1, bucket.size()):
				dups.append({"file_name": bucket[i]["file_name"], "file_path": bucket[i]["file_path"]})
			kept["duplicates_hidden"] = dups
		deduped.append(kept)
	return deduped

func get_active_modpack() -> String:
	var cfg := ConfigFile.new()
	if _ui_cfg_load(cfg) != OK:
		return ""
	return str(cfg.get_value("settings", "active_modpack", ""))

func _get_missing_mods_for_modpack(entry: Dictionary) -> Array:
	var missing: Array = []
	var pd: Variant = _modpack_read_profile(entry["file_path"])
	if pd == null:
		return missing
	var sources := _pack_dict(pd, "sources")
	var unavailable := _pack_dict(pd, "unavailable")
	var checksums := _pack_dict(pd, "checksums")
	var index := _modpack_installed_index(true)
	var sourced_ids := _pack_sourced_ids(sources)
	# Enabled keys and sources both, so a mod missing from `sources` surfaces as a failure.
	var seen: Dictionary = {}
	for k_v in _pack_dict(pd, "enabled").keys() + sources.keys():
		var key := str(k_v)
		if key == "" or seen.has(key):
			continue
		seen[key] = true
		if _modpack_key_installed(key, sources, checksums, index):
			continue
		if unavailable.has(key):
			# The key still names the mod, so its Mods-tab row can offer Download later; no ref.
			missing.append({"profile_key": key, "ref": {}, "version": "",
					"source": _normalize_source_record(_pack_key_source(key)),
					"unreachable": true, "unreachable_reason": _hosted_unavailable_copy(str(unavailable[key]))})
			continue
		var src_data: Variant = sources.get(key)
		var no_source: bool = not (src_data is Dictionary) or (src_data as Dictionary).is_empty()
		# A pack can pair a stale enabled key with a live sources key for the same mod.
		if no_source and sourced_ids.has(_profile_key_id(key)):
			continue
		missing.append(_missing_mod_item(key, src_data, no_source, str(checksums.get(key, ""))))
	return missing

func _pack_sourced_ids(sources: Dictionary) -> Dictionary:
	var ids: Dictionary = {}
	for k_v in sources:
		var sid := _profile_key_id(str(k_v))
		if sid != "" and str(_normalize_source_record(sources[k_v])["provider"]) != "":
			ids[sid] = true
	return ids

func _missing_mod_item(key: String, src_data: Variant, no_source: bool, sha256: String) -> Dictionary:
	# Version from the record only; one from the key would strict-pin old packs.
	var rec := _normalize_source_record(src_data)
	var ref := _source_host_ref(rec)
	var item := {"profile_key": key, "ref": ref, "version": str(rec["version"]), "source": rec, "sha256": sha256}
	if not _modpack_ref_downloadable(ref):
		item["unreachable"] = true
		if no_source:
			item["unreachable_reason"] = "the modpack has no download info for this mod -- install it manually"
		else:
			item["unreachable_reason"] = "the modpack does not say where this mod is hosted -- install it manually"
	return item

## An old local pack (no sources, "<id>@<version>" keys) matches any installed version of the id.
func _modpack_key_installed(key: String, sources: Dictionary, checksums: Dictionary, index: Dictionary) -> bool:
	if _resolve_pack_key(key, sources.get(key), str(checksums.get(key, "")), index) != "":
		return true
	return _normalize_source_record(sources.get(key))["provider"] == "" \
			and _normalize_source_record(_pack_key_source(key))["provider"] == "" \
			and index["ids"].has(_profile_key_id(key))

func _resolve_pack_key(key: String, src_data: Variant, sha256: String, index: Dictionary) -> String:
	if index["keys"].has(key):
		return key
	var by_id_ver: String = index["id_ver"].get(_profile_key_id(key) + "@" + _version_from_profile_key(key), "")
	if by_id_ver != "":
		return by_id_ver
	var rec := _normalize_source_record(src_data)
	if rec["provider"] == "":
		# A hosted pack writes no source for a mod the site cannot serve; the key names it.
		rec = _normalize_source_record(_pack_key_source(key))
	var rk := host_ref_key(_source_host_ref(rec))
	for cand: Dictionary in index["by_ref"].get(rk, []):
		if _modpack_source_installed(rec, {rk: [cand["version"]]}) \
				or _pinned_bytes_match(cand["path"], sha256, index):
			return cand["key"]
	return _match_unsourced_mod(rec, sha256, index)

# An index built without hashing (row counts) trusts any copy when the pack pins bytes.
func _pinned_bytes_match(path: String, sha256: String, index: Dictionary) -> bool:
	return sha256 != "" and (not index["hash"] or _cached_sha256(path) == sha256.to_lower())

func _match_unsourced_mod(rec: Dictionary, sha256: String, index: Dictionary) -> String:
	var id_l := str(rec["id"]).strip_edges().to_lower()
	if id_l == "":
		return ""
	var want := str(rec["version"]).strip_edges().lstrip("vV")
	var sha := sha256.strip_edges().to_lower()
	for cand: Dictionary in index["by_id"].get(id_l, []):
		if want == "" or str(cand["version"]).strip_edges().lstrip("vV") == want:
			return cand["key"]
		if _pinned_bytes_match(cand["path"], sha, index):
			return cand["key"]
	return ""

func _modpack_reconcile_profile_keys(profile_name: String, sources: Dictionary, checksums: Dictionary = {}) -> int:
	var cfg := _load_ui_cfg_for_write()
	if cfg == null:
		return 0
	var index := _modpack_installed_index(true)
	var changed := 0
	for suffix: String in STATE_SUFFIXES:
		var sec := _profile_sec(profile_name, suffix)
		if not cfg.has_section(sec):
			continue
		for pack_key: String in cfg.get_section_keys(sec):
			var target := _resolve_pack_key(pack_key, sources.get(pack_key), str(checksums.get(pack_key, "")), index)
			if target == "" or target == pack_key:
				continue
			var value: Variant = cfg.get_value(sec, pack_key)
			cfg.erase_section_key(sec, pack_key)
			if not cfg.has_section_key(sec, target):
				cfg.set_value(sec, target, value)
			changed += 1
	if changed > 0:
		_log_info("[Modpack] reconciled %d profile key(s) with the installed mods" % changed)
		_persist_ui_cfg(cfg)
	return changed

func _modpack_download_counts(missing: Array) -> Dictionary:
	var blocked := 0
	for item: Dictionary in missing:
		if item.get("unreachable", false):
			blocked += 1
	return {"download": missing.size() - blocked, "blocked": blocked}

func _modpack_forget_slot(sanitized: String) -> bool:
	if sanitized.is_empty() or get_active_modpack() == sanitized:
		return false
	var cfg := _load_ui_cfg_for_write()
	if cfg == null:
		return false
	var slot := MODPACK_PROFILE_PREFIX + sanitized
	var erased := _erase_profile_sections(cfg, slot)
	if erased:
		_persist_ui_cfg(cfg)
	var had_snapshot := DirAccess.dir_exists_absolute(MCM_SNAPSHOT_BASE.path_join(slot))
	_delete_mcm_snapshot(slot)
	return erased or had_snapshot

func _modpack_reconcile_active() -> int:
	var active := get_active_modpack()
	if active == "":
		return 0
	if _modpack_entries.is_empty():
		_modpack_entries = collect_modpack_metadata()
	for mp in _modpack_entries:
		if mp["sanitized_name"] != active:
			continue
		var changed := _modpack_reconcile_profile_keys(MODPACK_PROFILE_PREFIX + active, _modpack_sources(mp), _modpack_checksums(mp))
		if changed > 0:
			var cfg := ConfigFile.new()
			if _ui_cfg_load(cfg) == OK:
				_apply_profile_to_entries(cfg, _active_profile)
		return changed
	return 0

func _modpack_sources(entry: Dictionary) -> Dictionary:
	return _pack_dict(_modpack_read_profile(entry["file_path"]), "sources")

func _modpack_checksums(entry: Dictionary) -> Dictionary:
	return _pack_dict(_modpack_read_profile(entry["file_path"]), "checksums")

func _missing_mod_sources_combined() -> Dictionary:
	var out: Dictionary = _get_persisted_mod_sources()
	var active := get_active_modpack()
	if active.is_empty():
		return out
	for entry in _modpack_entries:
		if entry["sanitized_name"] != active:
			continue
		var sources := _modpack_sources(entry)
		for k in sources:
			var rec := _normalize_source_record(sources[k])
			if rec["provider"] != "":
				out[str(k)] = rec
		return out
	return out

## `hash_pins` lets a pinned checksum hash archives; only checks that decide a download set it.
func _modpack_installed_index(hash_pins := false) -> Dictionary:
	var keys: Dictionary = {}
	var id_ver: Dictionary = {}
	var by_ref: Dictionary = {}
	var by_id: Dictionary = {}
	var ids: Dictionary = {}
	var persisted := _get_persisted_mod_sources()
	for installed_entry in _ui_mod_entries:
		var pk := str(installed_entry.get("profile_key", ""))
		if pk != "":
			keys[pk] = true
		var inst_id_l := str(installed_entry.get("mod_id", "")).to_lower()
		var inst_ver := str(installed_entry.get("version", ""))
		var inst_path := str(installed_entry.get("full_path", ""))
		if inst_id_l != "":
			id_ver.get_or_add(inst_id_l + "@" + inst_ver, pk)
			ids[inst_id_l] = true
		var ref_keys := _entry_ref_keys(installed_entry, persisted)
		if ref_keys.is_empty() and inst_id_l != "":
			(by_id.get_or_add(inst_id_l, []) as Array).append({"key": pk, "version": inst_ver, "path": inst_path})
		# The site's served version can run ahead of mod.txt's; a pin at it counts too.
		var served := ""
		var stored := _normalize_source_record(persisted.get(pk))
		if _source_record_names_ref(stored, _entry_host_ref(installed_entry, persisted)) \
				and stored["version"] != "" and stored["version"] != inst_ver:
			served = stored["version"]
		for rk in ref_keys:
			var cands: Array = by_ref.get_or_add(rk, [])
			cands.append({"key": pk, "version": inst_ver, "path": inst_path})
			if served != "":
				cands.append({"key": pk, "version": served, "path": inst_path})
	return {"keys": keys, "id_ver": id_ver, "by_ref": by_ref, "by_id": by_id, "ids": ids,
			"hash": hash_pins}

func _pack_key_source(pack_key: String) -> Dictionary:
	var ref := host_ref_from_key(pack_key)
	if ref.is_empty():
		return {}
	return {"provider": str(ref["provider"]), "id": str(ref["id"])}

func _modpack_unpaired_host_refs(entry: Dictionary) -> Array:
	var out: Array = []
	var by_slug := false
	var by_uuid := false
	for item: Dictionary in _get_missing_mods_for_modpack(entry):
		var ref: Dictionary = item["ref"]
		if ref.is_empty():
			ref = host_ref_from_key(item["profile_key"])
		if str(ref.get("provider", "")) != HOST_VOSTOKMODS:
			continue
		if _vmp_is_uuid(str(ref["id"])):
			by_uuid = true
		else:
			by_slug = true
	if not (by_slug or by_uuid):
		return out
	var persisted := _get_persisted_mod_sources()
	for e in _ui_mod_entries:
		var ref := _entry_host_ref(e, persisted)
		if str(ref.get("provider", "")) != HOST_VOSTOKMODS or _entry_ref_keys(e, persisted).size() > 1:
			continue
		if _modpack_host_ids_asked.has(host_ref_key(ref)):
			continue
		var installed_by_uuid := _vmp_is_uuid(str(ref["id"]))
		if (installed_by_uuid and by_slug) or (not installed_by_uuid and by_uuid):
			out.append(ref)
	return out

func _modpack_learn_host_ids(entry: Dictionary, during_apply: bool = true) -> void:
	for ref: Dictionary in _modpack_unpaired_host_refs(entry):
		# Outside an apply the cancel flag is stale.
		if (during_apply and _modpack_apply_cancelled) or host_rate_cooldown_seconds(HOST_VOSTOKMODS) > 0:
			return
		var res := await _vmp_detail(str(ref["id"]))
		var code := str(res["code"])
		if not res["ok"] and code in [HOST_ERR_OFFLINE, HOST_ERR_RATE_LIMITED, HOST_ERR_SERVER]:
			return
		if res["ok"] or code != HOST_ERR_BAD_RESPONSE:
			_modpack_host_ids_asked[host_ref_key(ref)] = true
		if _modpack_unpaired_host_refs(entry).is_empty():
			return

## Site and mod.txt versions can differ, so an archive with the pinned bytes counts too.
func _modpack_source_installed(src_data: Variant, installed_refs: Dictionary, sha256: String = "",
		installed_paths: Dictionary = {}) -> bool:
	var rec := _normalize_source_record(src_data)
	var rk := host_ref_key(_source_host_ref(rec))
	if rk == "" or not installed_refs.has(rk):
		return false
	var want := str(rec["version"]).strip_edges().lstrip("vV")
	if want == "":
		return true
	for v in installed_refs[rk]:
		if str(v).strip_edges().lstrip("vV") == want:
			return true
	if sha256 != "":
		for path in installed_paths.get(rk, []):
			if _cached_sha256(str(path)) == sha256.to_lower():
				return true
	return false

func _cached_sha256(path: String) -> String:
	if path == "" or not FileAccess.file_exists(path):
		return ""
	var stamp := "%d:%d" % [FileAccess.get_modified_time(path), FileAccess.get_size(path)]
	var cached: Dictionary = _modpack_sha256_cache.get(path, {})
	if cached.get("stamp", "") == stamp:
		return cached["sha256"]
	var sha := FileAccess.get_sha256(path).to_lower()
	_modpack_sha256_cache[path] = {"stamp": stamp, "sha256": sha}
	return sha

## Discovery picks the newest copy, so an older pin cannot win while a newer one is installed.
func _modpack_pin_conflict(entry: Dictionary) -> String:
	var index := _modpack_installed_index()
	var sources := _modpack_sources(entry)
	var checksums := _modpack_checksums(entry)
	for key in sources:
		var rec := _normalize_source_record(sources[key])
		var want := str(rec["version"]).strip_edges()
		if want.is_empty():
			continue
		var rk := host_ref_key(_source_host_ref(rec))
		var sha := str(checksums.get(key, "")).to_lower()
		var cands: Array = index["by_ref"].get(rk, []).duplicate()
		var files: Array = cands.map(func(c: Dictionary) -> String: return str(c["path"]))
		# A same-id copy no host answers for was dropped in by hand; a newer one blocks too.
		for cand: Dictionary in index["by_id"].get(str(rec["id"]).to_lower(), []):
			if not files.has(cand["path"]):
				cands.append(cand)
				files.append(cand["path"])
		for cand: Dictionary in cands:
			var installed_version := str(cand["version"])
			if compare_versions(installed_version, want) <= 0:
				continue
			if sha != "" and _cached_sha256(str(cand["path"])) == sha:
				continue
			if not entry["hosted"].is_empty():
				return "This pack was fetched when %s was at %s, and %s is installed. Refresh the pack to get the author's current list, or remove the newer version before applying it." \
						% [rk, want, installed_version]
			return "This pack requires %s at %s. Remove the newer installed version %s before applying it." % [rk, want, installed_version]
	return ""

func _source_host_ref(rec: Dictionary) -> Dictionary:
	if str(rec.get("provider", "")) == "" or str(rec.get("id", "")) == "":
		return {}
	return host_ref(str(rec["provider"]), str(rec["id"]))

func _modpack_ref_downloadable(ref: Dictionary) -> bool:
	if not host_ref_valid(ref):
		return false
	return bool(host_caps(str(ref["provider"]))["resolve_file"])

## One mid-apply 429 would otherwise fail every remaining mod; never retries a request.
func _await_host_rate_cooldown(provider: String, progress: Callable, current: int, total: int) -> void:
	while not _modpack_apply_cancelled:
		var wait_s := host_rate_cooldown_seconds(provider)
		if wait_s <= 0:
			return
		if progress.is_valid():
			progress.call({"current": current, "total": total, "mod_name": "", "action": "rate_wait",
					"wait_s": wait_s, "host": host_display_name(provider)})
		await get_tree().create_timer(1.0).timeout

func _modpack_apply_failure(error: String, downloaded: int = 0, failed_downloads: int = 0,
		failures: Array = []) -> Dictionary:
	return {
		"ok": false,
		"error": error,
		"downloaded": downloaded,
		"failed_downloads": failed_downloads,
		"failures": failures,
	}

func _modpack_failure_row(profile_key: String, error: String, ref: Dictionary, version: String,
		sha256: String) -> Dictionary:
	return {"profile_key": profile_key, "error": error, "ref": ref, "version": version, "sha256": sha256}

func _modpack_apply_outcome(result: Dictionary) -> String:
	if result.get("cancelled", false):
		return "cancelled"
	if not result.get("ok", false):
		return "failed"
	if result.get("failed_downloads", 0) > 0:
		return "partial"
	return "applied"

## progress gets {current, total, mod_name, action}, action one of downloading, skipped,
## applying, rate_wait. Result: {ok, error, downloaded, failed_downloads, failures[, cancelled]}.
func apply_modpack(entry: Dictionary, tabs: TabContainer, progress: Callable = Callable()) -> Dictionary:
	if _modpack_apply_in_progress:
		return _modpack_apply_failure("Another apply is in progress; wait for it to finish")
	_modpack_apply_in_progress = true
	_modpack_apply_cancelled = false
	var result := await _apply_modpack_inner(entry, tabs, progress)
	_modpack_apply_in_progress = false
	return result

## Downloads precede any profile change; only _stage_pack leaves active_modpack set on failure.
func _apply_modpack_inner(entry: Dictionary, tabs: TabContainer, progress: Callable) -> Dictionary:
	var validation := _validate_modpack(entry)
	if not validation["ok"]:
		return _modpack_apply_failure(validation["error"])
	var sanitized: String = entry["sanitized_name"]
	if sanitized.is_empty():
		return _modpack_apply_failure("Invalid modpack name")
	var current_active := get_active_modpack()
	if current_active != "" and current_active != sanitized:
		return _modpack_apply_failure("Unload " + current_active + " before applying another modpack")
	await _modpack_learn_host_ids(entry)
	var pin_conflict := _modpack_pin_conflict(entry)
	if not pin_conflict.is_empty():
		return _modpack_apply_failure(pin_conflict)
	var modpack_profile := MODPACK_PROFILE_PREFIX + sanitized

	var tally := await _download_pack_mods(entry, sanitized, progress)
	var done_dl: int = tally["downloaded"]
	var failed_dl: int = tally["failed_downloads"]
	var failures: Array = tally["failures"]
	if tally["error"] != "":
		var cancelled := _modpack_apply_failure(tally["error"], done_dl, failed_dl, failures)
		cancelled["cancelled"] = true
		return cancelled

	if current_active != sanitized:
		var stage_error := _stage_pack(entry, sanitized)
		if stage_error != "":
			return _modpack_apply_failure(stage_error, done_dl, failed_dl, failures)
		_switch_profile(modpack_profile)
		# The switch rewrote the cfg; put back the flag _stage_pack set.
		var cfg := ConfigFile.new()
		var cfg_err := _ui_cfg_load(cfg)
		if cfg_err == OK:
			cfg.set_value("settings", "active_modpack", sanitized)
			_persist_ui_cfg(cfg)
		else:
			_log_warning("[Modpack] could not re-read mod_config.cfg after the switch (error %d)" % cfg_err)
	elif done_dl > 0:
		if _modpack_reconcile_profile_keys(modpack_profile, _modpack_sources(entry), _modpack_checksums(entry)) > 0:
			var cfg_re := ConfigFile.new()
			if _ui_cfg_load(cfg_re) == OK:
				_apply_profile_to_entries(cfg_re, _active_profile)

	# The launcher can close during the downloads.
	if is_instance_valid(tabs):
		_rebuild_mods_tab(tabs)
	return {"ok": true, "error": "", "downloaded": done_dl, "failed_downloads": failed_dl, "failures": failures}

func _download_pack_mods(entry: Dictionary, sanitized: String, progress: Callable) -> Dictionary:
	var tally := {"downloaded": 0, "failed_downloads": 0, "failures": [], "error": ""}
	var missing := _get_missing_mods_for_modpack(entry)
	if not missing.is_empty():
		_log_info("[Modpack] applying %s: %d mod(s) to install" % [sanitized, missing.size()])
		for item: Dictionary in missing:
			_persist_single_mod_source(item["profile_key"], item["source"])
		var total := missing.size()
		for i in range(total):
			var item: Dictionary = missing[i]
			var pk: String = item["profile_key"]
			var ref: Dictionary = item["ref"]
			if not ref.is_empty():
				await _await_host_rate_cooldown(str(ref["provider"]), progress, i + 1, total)
			# An in-flight request cannot be interrupted, so cancel is checked between mods.
			if _modpack_apply_cancelled:
				_log_info("[Modpack] cancelled by user at item %d of %d" % [i + 1, total])
				if tally["downloaded"] > 0:
					_rescan_entries()
				tally["error"] = "Cancelled by user after downloading %d of %d mod(s)" % [tally["downloaded"], total]
				return tally
			if item.get("unreachable", false):
				var reason: String = item["unreachable_reason"]
				tally["failed_downloads"] += 1
				tally["failures"].append(_modpack_failure_row(pk, reason, ref, item["version"], item.get("sha256", "")))
				_log_warning("[Modpack] skipped: " + pk + " -- " + reason)
				if progress.is_valid():
					progress.call({"current": i + 1, "total": total, "mod_name": pk, "action": "skipped"})
				continue
			var got := await _download_pack_mod(item, progress, i, total, "downloading")
			if got["ok"] or got["already"]:
				tally["downloaded"] += 1
				if got["already"]:
					_log_info("[Modpack] already on disk: " + pk + " (" + got["error"] + ")")
			else:
				tally["failed_downloads"] += 1
				tally["failures"].append(_modpack_failure_row(pk, got["error"], ref, item["version"], item["sha256"]))
				_log_warning("[Modpack] failed: " + pk + " -- " + got["error"])
		_rescan_entries()
		if progress.is_valid():
			progress.call({"current": total, "total": total, "mod_name": "", "action": "applying"})

	# A cancel during the last download has no loop-top check to see it.
	if _modpack_apply_cancelled:
		_log_info("[Modpack] cancelled by user after the download phase, before any state change")
		tally["error"] = "Cancelled by user after downloading %d mod(s)" % tally["downloaded"]
	return tally

func _download_pack_mod(item: Dictionary, progress: Callable, i: int, total: int, action: String) -> Dictionary:
	var pk: String = item["profile_key"]
	var ref: Dictionary = item["ref"]
	var version: String = item["version"]
	if progress.is_valid():
		progress.call({"current": i + 1, "total": total, "mod_name": pk, "action": action})
	var pin := (" v" + version) if version != "" else " (primary)"
	_log_info("[Modpack] %s %s (%s%s)" % [action, pk, host_ref_key(ref), pin])
	# Renaming on collision: a different version lands beside the existing file; dedup picks one.
	var r: Dictionary = await download_mod_from_ref(ref, version, true, item["sha256"])
	if r["ok"]:
		_log_info("[Modpack] ok: " + str(r["file_name"]))
		return {"ok": true, "already": false, "error": ""}
	return {"ok": false, "already": str(r.get("code", "")) == DOWNLOAD_ALREADY_INSTALLED, "error": str(r["error"])}

func _stage_pack(entry: Dictionary, sanitized: String) -> String:
	var pre_active := _active_profile
	var backup_profile := MODPACK_BACKUP_PREFIX + sanitized
	var modpack_profile := MODPACK_PROFILE_PREFIX + sanitized
	var cfg := ConfigFile.new()
	var cfg_err := _ui_cfg_load(cfg)
	if cfg_err != OK and cfg_err != ERR_FILE_NOT_FOUND:
		return "Cannot read your mod settings file (mod_config.cfg, error %d) -- the modpack was not applied and your profiles are unchanged. Any downloaded mods remain in your mods folder. Restart the game and try again." % cfg_err
	_copy_profile_sections(cfg, pre_active, backup_profile, [".enabled", ".priority"])
	cfg.set_value("settings", "modpack_backup_profile", pre_active)
	# Written even for an empty backup, or unload cannot tell it from a missing one.
	cfg.set_value("settings", "modpack_backup_valid", true)
	# Set early: it is the crash trigger the boot reconciler keys off.
	cfg.set_value("settings", "active_modpack", sanitized)
	_persist_ui_cfg(cfg)
	# With no MCM folder the backup is an empty snapshot, so unload restores "none".
	_capture_mcm_into(backup_profile, pre_active)

	cfg = ConfigFile.new()
	cfg_err = _ui_cfg_load(cfg)
	if cfg_err != OK:
		return "Cannot read settings (error %d) -- nothing was changed." % cfg_err
	# A kept slot is rebuilt when its stamp names another zip (one replaced by hand).
	var stamp := str(cfg.get_value(_profile_sec(modpack_profile, ".settings"), "pack_sha256", ""))
	if not cfg.has_section(_profile_sec(modpack_profile, ".enabled")) \
			or (stamp != "" and stamp != _cached_sha256(entry["file_path"])):
		var mat := _materialize_modpack_profile(entry, modpack_profile)
		if not mat["ok"]:
			cfg.set_value("settings", "active_modpack", "")
			cfg.set_value("settings", "modpack_backup_valid", false)
			_persist_ui_cfg(cfg)
			return mat["error"]
	else:
		_modpack_reconcile_profile_keys(modpack_profile, _modpack_sources(entry), _modpack_checksums(entry))
	return ""

func _materialize_modpack_profile(entry: Dictionary, profile_name: String) -> Dictionary:
	var file_path: String = entry["file_path"]
	var reader := ZIPReader.new()
	if reader.open(file_path) != OK:
		return {"ok": false, "error": "Cannot open modpack zip"}
	var files := reader.get_files()
	if not ("profile.json" in files):
		reader.close()
		return {"ok": false, "error": "Modpack missing profile.json"}
	var pd: Variant = _parse_profile_bytes(reader.read_file("profile.json"))
	if pd == null:
		reader.close()
		return {"ok": false, "error": "Modpack profile.json is invalid"}

	var cfg := ConfigFile.new()
	var cfg_err := _ui_cfg_load(cfg)
	if cfg_err != OK and cfg_err != ERR_FILE_NOT_FOUND:
		reader.close()
		return {"ok": false, "error": "Cannot read your mod settings file (mod_config.cfg, error %d) -- modpack profile not created. Restart the game and try again." % cfg_err}
	var en_sec := _profile_sec(profile_name, ".enabled")
	var pr_sec := _profile_sec(profile_name, ".priority")
	var ig_sec := _profile_sec(profile_name, ".dep_ignore")
	for sec in [en_sec, pr_sec]:
		if cfg.has_section(sec):
			cfg.erase_section(sec)
	var enabled_dict := _pack_dict(pd, "enabled")
	for k in enabled_dict:
		cfg.set_value(en_sec, str(k), _json_truthy(enabled_dict[k]))
	var priority_dict := _pack_dict(pd, "priority")
	for k in priority_dict:
		var pv_raw: Variant = priority_dict[k]
		var pv: int = int(pv_raw) if (pv_raw is int or pv_raw is float) else 0
		cfg.set_value(pr_sec, str(k), clampi(pv, PRIORITY_MIN, PRIORITY_MAX))
	if cfg.has_section(ig_sec):
		cfg.erase_section(ig_sec)
	var dep_ignore_dict := _pack_dict(pd, "dep_ignore")
	for k in dep_ignore_dict:
		if _json_truthy(dep_ignore_dict[k]):
			cfg.set_value(ig_sec, str(k), true)
	# A settings-only pack has no keys; without the marker the next launch reads it as stranded.
	_keep_profile_listed(cfg, profile_name)
	cfg.set_value(_profile_sec(profile_name, ".settings"), "pack_sha256", _cached_sha256(file_path))
	_persist_ui_cfg(cfg)
	_modpack_reconcile_profile_keys(profile_name, _pack_dict(pd, "sources"), _pack_dict(pd, "checksums"))

	var mcm_data: Dictionary = {}
	for f in files:
		if not f.begins_with("MCM/") or f.ends_with("/"):
			continue
		var rel: String = f.substr(4)
		if rel.contains("..") or rel.begins_with("/") or rel.is_empty():
			continue
		mcm_data[rel] = reader.read_file(f)
	reader.close()
	_write_mcm_snapshot_from_data(profile_name, _mcm_restore_files(mcm_data))
	return {"ok": true, "error": ""}

func _restamp_pack_slot(sanitized: String, file_path: String) -> void:
	if sanitized.is_empty():
		return
	var cfg := _load_ui_cfg_for_write()
	if cfg == null:
		return
	var sec := _profile_sec(MODPACK_PROFILE_PREFIX + sanitized, ".settings")
	if not cfg.has_section_key(sec, "pack_sha256"):
		return
	_modpack_sha256_cache.erase(file_path)
	_modpack_zip_memo.erase(file_path)
	cfg.set_value(sec, "pack_sha256", _cached_sha256(file_path))
	_persist_ui_cfg(cfg)

# The cfg and its active pack, or {error}: a hard read failure would misreport as no pack.
func _active_pack_cfg() -> Dictionary:
	var cfg := ConfigFile.new()
	var cfg_err := _ui_cfg_load(cfg)
	if cfg_err != OK and cfg_err != ERR_FILE_NOT_FOUND:
		return {"error": "Cannot read your mod settings file (mod_config.cfg, error %d) -- nothing was unloaded. Restart the game and try again." % cfg_err}
	var active := str(cfg.get_value("settings", "active_modpack", ""))
	if active == "":
		return {"error": "No modpack is active"}
	return {"cfg": cfg, "active": active}

# An empty backup has only the flag.
func _has_pack_backup(cfg: ConfigFile, active: String) -> bool:
	var backup_profile := MODPACK_BACKUP_PREFIX + active
	return bool(cfg.get_value("settings", "modpack_backup_valid", false)) \
			or cfg.has_section(_profile_sec(backup_profile, ".enabled")) \
			or cfg.has_section(_profile_sec(backup_profile, ".priority"))

# The pack's display name as a free profile name, "Name 2" style on a clash.
func _kept_pack_name(cfg: ConfigFile, active: String) -> String:
	var shown := active
	for e in _modpack_entries:
		if e["sanitized_name"] == active:
			shown = e["raw_name"]
	var base := _sanitize_profile_name(shown)
	var none: Array[String] = []
	if _validate_profile_name(base, none) != "":
		base = "Modpack"
	var existing := _list_profiles_in_cfg(cfg)
	var name := base
	var n := 2
	while _validate_profile_name(name, existing) != "":
		name = "%s %d" % [base, n]
		n += 1
	return name

func unload_modpack(tabs: TabContainer) -> Dictionary:
	var state := _active_pack_cfg()
	if state.has("error"):
		return {"ok": false, "error": state["error"]}
	var cfg: ConfigFile = state["cfg"]
	var active: String = state["active"]
	var backup_profile := MODPACK_BACKUP_PREFIX + active
	var pre_active := str(cfg.get_value("settings", "modpack_backup_profile", "Default"))
	# Without a backup the erase would wipe the pre-apply profile.
	if not _has_pack_backup(cfg, active):
		return {"ok": false, "needs_force": true, "profile": _kept_pack_name(cfg, active),
				"error": "The backup for this pack is missing, so your previous profile cannot be restored."}
	_copy_profile_sections(cfg, backup_profile, pre_active, [".enabled", ".priority"])
	_erase_profile_sections(cfg, backup_profile)
	cfg.set_value("settings", "modpack_backup_valid", false)
	cfg.set_value("settings", "active_modpack", "")
	_persist_ui_cfg(cfg)

	# After boot the live MCM stays the pack's: the backup becomes the profile's slot until restart.
	var deferred := _boot_complete
	if deferred and _has_mcm_snapshot(backup_profile):
		_snapshot_mcm_to(pre_active, _mcm_snapshot_dir(backup_profile))
	_switch_profile(pre_active)
	# Cleared only after the switch: a crash inside it recovers onto this name.
	var cfg_after := _load_ui_cfg_for_write()
	if cfg_after != null:
		cfg_after.set_value("settings", "modpack_backup_profile", "")
		_persist_ui_cfg(cfg_after)

	var mcm_ok := true
	if _has_mcm_snapshot(backup_profile) and not deferred:
		mcm_ok = _restore_mcm_from(backup_profile)
		# The switch seeded a snapshot-less profile from the live folder, which held the pack's MCM.
		if mcm_ok:
			_snapshot_mcm_to(pre_active)
	# The slot directory goes only when empty: files beside MCM/ are not consumed.
	if mcm_ok:
		_remove_tree(_mcm_snapshot_dir(backup_profile), false)
		DirAccess.remove_absolute(MCM_SNAPSHOT_BASE.path_join(backup_profile))
	else:
		_log_warning("[Modpack] unload: MCM restore incomplete; kept " + MCM_SNAPSHOT_BASE.path_join(backup_profile))
	if tabs != null:
		_rebuild_mods_tab(tabs)
	return {"ok": true, "error": ""}

# With no backup to restore, the pack's slot becomes a plain profile that keeps the live MCM.
func force_unload_modpack(tabs: TabContainer) -> Dictionary:
	_flush_priority_save()
	var state := _active_pack_cfg()
	if state.has("error"):
		return {"ok": false, "error": state["error"]}
	var cfg: ConfigFile = state["cfg"]
	var active: String = state["active"]
	if _has_pack_backup(cfg, active):
		return {"ok": false, "error": "This pack's backup is intact, so use Unload instead."}
	var slot := MODPACK_PROFILE_PREFIX + active
	var name := _kept_pack_name(cfg, active)
	_copy_profile_sections(cfg, slot, name, PROFILE_SUBSECTIONS)
	if cfg.has_section_key(_profile_sec(name, ".settings"), "pack_sha256"):
		cfg.erase_section_key(_profile_sec(name, ".settings"), "pack_sha256")
	_keep_profile_listed(cfg, name)
	_erase_profile_sections(cfg, slot)
	_erase_profile_sections(cfg, MODPACK_BACKUP_PREFIX + active)
	for key: String in cfg.get_section_keys("settings"):
		if key.begins_with("modpack_"):
			cfg.erase_section_key("settings", key)
	cfg.set_value("settings", "active_modpack", "")
	cfg.set_value("settings", "active_profile", name)
	# The slot's MCM goes with it, a pending swap included.
	for pk: String in ["mcm_pending_from", "mcm_pending_to"]:
		if str(cfg.get_value("settings", pk, "")) == slot:
			cfg.set_value("settings", pk, name)
	_capture_mcm_into(name, slot)
	_delete_mcm_snapshot(slot)
	_persist_ui_cfg(cfg)
	_active_profile = name
	_apply_profile_to_entries(cfg, name)
	_log_warning("[Modpack] force-unloaded %s with no backup; kept as profile '%s'" % [active, name])
	if tabs != null:
		_rebuild_mods_tab(tabs)
	return {"ok": true, "error": "", "profile": name}

func retry_failed_downloads(failures: Array, progress: Callable = Callable()) -> Dictionary:
	if _modpack_apply_in_progress:
		return {"downloaded": 0, "failures": failures, "cancelled": false}
	_modpack_apply_in_progress = true
	# A retry is a run of its own: an earlier run's Cancel does not carry over.
	_modpack_apply_cancelled = false
	var still_failed: Array = []
	var newly_downloaded := 0
	for i in range(failures.size()):
		var item: Dictionary = failures[i]
		var ref: Dictionary = item["ref"]
		if _modpack_apply_cancelled or not _modpack_ref_downloadable(ref):
			still_failed.append(item)
			continue
		await _await_host_rate_cooldown(str(ref["provider"]), progress, i + 1, failures.size())
		if _modpack_apply_cancelled:
			still_failed.append(item)
			continue
		var got := await _download_pack_mod(item, progress, i, failures.size(), "retrying")
		if got["ok"]:
			newly_downloaded += 1
		else:
			still_failed.append(_modpack_failure_row(item["profile_key"], got["error"], ref, item["version"], item["sha256"]))
			_log_warning("[Modpack] retry failed: %s -- %s" % [item["profile_key"], got["error"]])
	if newly_downloaded > 0:
		# The reload also reconciles: retried mods may land under names the pack did not use.
		_reload_entries_for_active_profile()
	_modpack_apply_in_progress = false
	return {"downloaded": newly_downloaded, "failures": still_failed, "cancelled": _modpack_apply_cancelled}
