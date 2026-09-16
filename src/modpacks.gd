## ----- modpacks.gd -----
## Modpack discovery, apply, unload. A modpack is a .zip in <game>/mods/ with
## profile.json at the root; scan time routes it to the Modpacks tab. An
## applied modpack lives as a regular profile ("modpack__" prefix) so the
## profile lifecycle handles it; the zip is a template read on first apply or
## reset. Pre-apply state is backed up in a "_before_modpack_" profile slot
## plus an MCM snapshot.
##
## Config conventions:
##   modpack__<name>         live state of an applied modpack
##   _before_modpack_<name>  backup of pre-apply state
##   [settings] active_modpack         active pack ("" = none)
##   [settings] modpack_backup_profile profile to restore on unload
##   [settings] modpack_backup_valid   apply wrote a (possibly empty) backup
##
## States (owners: apply_modpack, unload_modpack and the boot reconciler in
## ui.gd _load_ui_config):
##   no pack      active_modpack is ""; stale backup sections are erased by the next apply.
##   downloading  awaiting missing-mod downloads; no state touched yet. Serialized
##                by _modpack_apply_in_progress; Cancel sets _modpack_apply_cancelled.
##   mutating     _apply_modpack_inner's numbered steps, fresh apply only:
##                1. copy the active profile into the backup slot and set
##                active_modpack early (the crash trigger the reconciler keys off),
##                2. materialize the modpack__ profile from the zip if absent,
##                3. _switch_profile into the slot, 4. re-assert active_modpack.
##                A failure after step 1 leaves the flag set; the next boot's
##                reconciler clears it.
##   active       active_profile is the slot. Re-apply is downloads-only.
##   unloading    aborts untouched when the backup is gone; else restore backup
##                sections, clear flags, _switch_profile back, restore the
##                pre-pack MCM, wipe the slot dir.
##
## Invariants: downloads strictly precede state mutation; reconciler recovery
## never deletes the backup slot; at most one pack is active at a time.

const MODPACK_PROFILE_PREFIX := "modpack__"
const MODPACK_BACKUP_PREFIX := "_before_modpack_"

# Mutex for the modpack apply flow; prevents concurrent applies racing on cfg
# writes + the backup slot. UI also gates Apply buttons on it.
var _modpack_apply_in_progress: bool = false

# Profiles the modpack system manages internally; hidden from the dropdown.
func _is_modpack_managed_profile(profile_name: String) -> bool:
	return profile_name.begins_with(MODPACK_PROFILE_PREFIX) \
			or profile_name.begins_with(MODPACK_BACKUP_PREFIX)

# Count truthy values in a pack's `enabled` map; values are third-party, so type-check.
func _count_truthy(d: Dictionary) -> int:
	var count := 0
	for k in d.keys():
		if _json_truthy(d[k]):
			count += 1
	return count

# profile.json carries the metroprofile v1 schema; the writer is
# _hosted_manifest_to_profile (hosted_modpacks.gd). See docs/wiki/Profile-Format.md.

# Pre-apply validation of the zip and schema. Returns {ok, error, enabled_count, total_count}.
func _validate_modpack(entry: Dictionary) -> Dictionary:
	var file_path: String = str(entry.get("file_path", ""))
	if file_path.is_empty():
		return {"ok": false, "error": "Modpack has no file path"}
	if not FileAccess.file_exists(file_path):
		return {"ok": false, "error": "Modpack file no longer exists at:\n" + file_path}
	var reader := ZIPReader.new()
	if reader.open(file_path) != OK:
		return {"ok": false, "error": "Cannot open modpack zip (corrupt or in use)"}
	var files := reader.get_files()
	if not ("profile.json" in files):
		reader.close()
		return {"ok": false, "error": "This file is not a valid modpack (no mod list inside). Get a fresh copy of the modpack and try again."}
	var bytes := reader.read_file("profile.json")
	reader.close()
	if bytes.is_empty():
		return {"ok": false, "error": "This modpack file is damaged (its mod list is empty). Get a fresh copy and try again."}
	var parsed_v: Variant = JSON.parse_string(bytes.get_string_from_utf8())
	if not (parsed_v is Dictionary):
		return {"ok": false, "error": "This modpack file is damaged (its mod list is unreadable). Get a fresh copy and try again."}
	var pd: Dictionary = parsed_v
	# Present-but-null in a hand-edited pack; int(null) is a constructor error.
	var mp_raw = pd.get("metroprofile", 0)
	var mp_ver: int = int(mp_raw) if (mp_raw is int or mp_raw is float) else 0
	if mp_ver != 1:
		return {"ok": false, "error": "This modpack was made for a newer version of the mod loader -- update the mod loader and try again"}
	if not (pd.get("name") is String):
		return {"ok": false, "error": "This modpack file is damaged (it has no name). Get a fresh copy and try again."}
	if not (pd.get("enabled") is Dictionary):
		return {"ok": false, "error": "This modpack file is damaged (its mod list is missing). Get a fresh copy and try again."}
	var enabled: Dictionary = pd["enabled"]
	var enabled_count := _count_truthy(enabled)
	return {
		"ok": true,
		"error": "",
		"enabled_count": enabled_count,
		"total_count": enabled.size(),
	}

# A zip with profile.json at the root is a modpack.
func _is_modpack_zip(file_path: String) -> bool:
	var reader := ZIPReader.new()
	if reader.open(file_path) != OK:
		return false
	var files := reader.get_files()
	var has_profile := files.has("profile.json")
	reader.close()
	return has_profile

# Read enough of a modpack zip to render a row; apply does full validation. {} if malformed.
func _build_modpack_entry(file_path: String) -> Dictionary:
	var reader := ZIPReader.new()
	if reader.open(file_path) != OK:
		return {}
	var bytes := reader.read_file("profile.json")
	reader.close()
	if bytes.is_empty():
		return {}
	var parsed: Variant = JSON.parse_string(bytes.get_string_from_utf8())
	if not (parsed is Dictionary):
		return {}
	var pd: Dictionary = parsed
	var raw_name := str(pd.get("name", file_path.get_file().get_basename()))
	var description := str(pd.get("description", "")).strip_edges()
	var author := str(pd.get("author", "")).strip_edges()
	var exported_at := str(pd.get("exported_at", ""))
	var enabled: Dictionary = pd.get("enabled", {}) if pd.get("enabled") is Dictionary else {}
	var enabled_count := _count_truthy(enabled)
	# A pack imported from a mod site records where it came from (refresh, page link).
	var hosted: Dictionary = pd.get("hosted", {}) if pd.get("hosted") is Dictionary else {}
	return {
		"file_path": file_path,
		"file_name": file_path.get_file(),
		"raw_name": raw_name,
		"description": description,
		"author": author,
		"exported_at": exported_at,
		"sanitized_name": _sanitize_profile_name(raw_name),
		"enabled_count": enabled_count,
		"total_count": enabled.size(),
		"hosted": hosted,
	}

func collect_modpack_metadata() -> Array[Dictionary]:
	var entries: Array[Dictionary] = []
	var mods_dir := _mods_dir
	if mods_dir.is_empty():
		mods_dir = OS.get_executable_path().get_base_dir().path_join(MOD_DIR)
	var dir := DirAccess.open(mods_dir)
	if dir == null:
		return entries
	dir.list_dir_begin()
	while true:
		var name := dir.get_next()
		if name == "":
			break
		if dir.current_is_dir():
			continue
		if name.get_extension().to_lower() != "zip":
			continue
		var full := mods_dir.path_join(name)
		if not _is_modpack_zip(full):
			continue
		var entry := _build_modpack_entry(full)
		if entry.is_empty():
			continue
		entries.append(entry)
	dir.list_dir_end()

	# Dedupe by sanitized_name: two zips with the same key would both render as
	# active. Keep the newest by mtime; the rest go in duplicates_hidden.
	if entries.size() > 1:
		var by_sanitized: Dictionary = {}
		for e_v in entries:
			var e: Dictionary = e_v
			var sn: String = str(e.get("sanitized_name", ""))
			if sn == "":
				continue
			if not by_sanitized.has(sn):
				by_sanitized[sn] = []
			(by_sanitized[sn] as Array).append(e)
		var deduped: Array[Dictionary] = []
		for sn_v in by_sanitized.keys():
			var bucket: Array = by_sanitized[sn_v]
			if bucket.size() == 1:
				deduped.append(bucket[0])
				continue
			bucket.sort_custom(func(a, b):
				return FileAccess.get_modified_time(str(a.get("file_path", ""))) > FileAccess.get_modified_time(str(b.get("file_path", "")))
			)
			var kept: Dictionary = bucket[0]
			var dups: Array = []
			for i in range(1, bucket.size()):
				dups.append({
					"file_name": str(bucket[i].get("file_name", "?")),
					"file_path": str(bucket[i].get("file_path", "")),
				})
			kept["duplicates_hidden"] = dups
			deduped.append(kept)
		entries = deduped
	return entries

# Currently applied modpack (sanitized_name) or "" if none.
func get_active_modpack() -> String:
	var cfg := ConfigFile.new()
	if cfg.load(UI_CONFIG_PATH) != OK:
		return ""
	return str(cfg.get_value("settings", "active_modpack", ""))

# Mods the pack declares that are not installed at the pinned version.
# Returns [{profile_key, ref, version, source}]; ref is {} when no host is named.
func _get_missing_mods_for_modpack(entry: Dictionary) -> Array:
	var missing: Array = []
	var file_path: String = str(entry.get("file_path", ""))
	if file_path.is_empty():
		return missing
	var reader := ZIPReader.new()
	if reader.open(file_path) != OK:
		return missing
	var bytes := reader.read_file("profile.json")
	reader.close()
	if bytes.is_empty():
		return missing
	var parsed_v: Variant = JSON.parse_string(bytes.get_string_from_utf8())
	if not (parsed_v is Dictionary):
		return missing
	var pd: Dictionary = parsed_v
	var sources: Dictionary = pd.get("sources", {}) if pd.get("sources") is Dictionary else {}
	var enabled_map: Dictionary = pd.get("enabled", {}) if pd.get("enabled") is Dictionary else {}
	var unavailable: Dictionary = pd.get("unavailable", {}) if pd.get("unavailable") is Dictionary else {}
	var checksums: Dictionary = pd.get("checksums", {}) if pd.get("checksums") is Dictionary else {}

	var index := _modpack_installed_index()
	var installed_keys: Dictionary = index["keys"]
	var installed_id_ver: Dictionary = index["id_ver"]
	var installed_refs: Dictionary = index["refs"]

	# Lowercased ids that have a source under some key: an exporter can pair a
	# stale enabled key with a live sources key for the same mod.
	var sourced_ids: Dictionary = {}
	for k_v in sources.keys():
		var sk := str(k_v)
		var s_at := sk.find("@")
		if s_at > 0 and str(_normalize_source_record(sources[k_v])["provider"]) != "":
			sourced_ids[sk.substr(0, s_at).to_lower()] = true

	# Walk enabled and sources so a mod missing from `sources` surfaces as a failure.
	var seen: Dictionary = {}
	var ordered_keys: Array[String] = []
	for k_v in enabled_map.keys():
		var k := str(k_v)
		if k != "" and not seen.has(k):
			seen[k] = true
			ordered_keys.append(k)
	for k_v in sources.keys():
		var k := str(k_v)
		if k != "" and not seen.has(k):
			seen[k] = true
			ordered_keys.append(k)

	for src_key in ordered_keys:
		if installed_keys.has(src_key):
			continue
		var at_pos := src_key.find("@")
		if at_pos > 0:
			var src_id_l := src_key.substr(0, at_pos).to_lower()
			var src_ver := src_key.substr(at_pos + 1)
			if installed_id_ver.has(src_id_l + "@" + src_ver):
				continue
		var src_data: Variant = sources.get(src_key)
		# Already installed from the same host at the pinned version (or any when
		# unpinned). Hosted packs key by slug, so this stops the per-apply re-download.
		if _modpack_source_installed(src_data, installed_refs):
			continue
		if unavailable.has(src_key):
			var reason := str(unavailable[src_key])
			_log_warning("[Modpack] " + src_key + " is listed but unavailable (" + reason + ")")
			missing.append({"profile_key": src_key, "ref": {}, "version": "", "source": _normalize_source_record(null),
					"unreachable": true, "unreachable_reason": _hosted_unavailable_copy(reason)})
			continue
		if not (src_data is Dictionary) or (src_data as Dictionary).is_empty():
			var at2 := src_key.find("@")
			if at2 > 0 and sourced_ids.has(src_key.substr(0, at2).to_lower()):
				continue
		# Version is honored only when the record carries it; deriving it from the
		# profile_key would strict-pin legacy packs against replaced versions.
		var src_rec := _normalize_source_record(src_data)
		var version: String = str(src_rec["version"])
		# Cache the source so a missing-mod stub can offer Download.
		_persist_single_mod_source(src_key, src_rec)
		var ref := _source_host_ref(src_rec)
		var item := {"profile_key": src_key, "ref": ref, "version": version, "source": src_rec,
				"sha256": str(checksums.get(src_key, ""))}
		if not _modpack_ref_downloadable(ref):
			# No usable source; surface an explanatory failure row.
			item["unreachable"] = true
			if not (src_data is Dictionary) or (src_data as Dictionary).is_empty():
				item["unreachable_reason"] = "the modpack has no download info for this mod -- install it manually"
			else:
				item["unreachable_reason"] = "the modpack does not say where this mod is hosted -- install it manually"
		missing.append(item)
	return missing


## Rewrite a modpack profile's enabled/priority/dep_ignore keys from the
## author's keys to the keys the same mods have here. They differ when the
## author's mod had no id or when the pack predates an update. Resolution:
## exact key, then id@version case-insensitively, then the source record
## against an installed mod's source. No id-prefix fallback. Unresolved keys
## stay, so a still-missing mod keeps its stub row. Returns the count rewritten.
func _modpack_reconcile_profile_keys(profile_name: String, sources: Dictionary) -> int:
	var cfg := ConfigFile.new()
	if cfg.load(UI_CONFIG_PATH) != OK:
		return 0
	var persisted := _get_persisted_mod_sources()
	var by_id_ver: Dictionary = {}
	var by_ref: Dictionary = {}
	var installed: Dictionary = {}
	for e in _ui_mod_entries:
		var pk := str(e.get("profile_key", ""))
		if pk == "":
			continue
		installed[pk] = true
		var id_l := str(e.get("mod_id", "")).to_lower()
		if id_l != "" and not by_id_ver.has(id_l + "@" + str(e.get("version", ""))):
			by_id_ver[id_l + "@" + str(e.get("version", ""))] = pk
		var rk := host_ref_key(_entry_host_ref(e, persisted))
		if rk != "" and not by_ref.has(rk):
			by_ref[rk] = pk
	var changed := 0
	for suffix in [".enabled", ".priority", ".dep_ignore"]:
		var sec := _profile_sec(profile_name, str(suffix))
		if not cfg.has_section(sec):
			continue
		for k in cfg.get_section_keys(sec):
			var pack_key := str(k)
			if installed.has(pack_key):
				continue
			var target := ""
			var at := pack_key.find("@")
			if at > 0:
				target = str(by_id_ver.get(pack_key.substr(0, at).to_lower() + "@" + pack_key.substr(at + 1), ""))
			if target == "":
				var rk := host_ref_key(_source_host_ref(_normalize_source_record(sources.get(pack_key))))
				if rk != "":
					target = str(by_ref.get(rk, ""))
			if target == "" or target == pack_key:
				continue
			var value: Variant = cfg.get_value(sec, pack_key)
			cfg.erase_section_key(sec, pack_key)
			# An entry the pack already keyed correctly wins over a remap.
			if not cfg.has_section_key(sec, target):
				cfg.set_value(sec, target, value)
			changed += 1
	if changed > 0:
		_log_info("[Modpack] reconciled %d profile key(s) with the installed mods" % changed)
		_persist_ui_cfg(cfg)
	return changed


## The pack's source map, read from the zip so reconcile sees what the download loop used.
func _modpack_sources(entry: Dictionary) -> Dictionary:
	var file_path: String = str(entry.get("file_path", ""))
	if file_path.is_empty():
		return {}
	var reader := ZIPReader.new()
	if reader.open(file_path) != OK:
		return {}
	var bytes := reader.read_file("profile.json")
	reader.close()
	if bytes.is_empty():
		return {}
	var parsed_v: Variant = JSON.parse_string(bytes.get_string_from_utf8())
	if not (parsed_v is Dictionary):
		return {}
	var sources_v: Variant = (parsed_v as Dictionary).get("sources")
	return sources_v if sources_v is Dictionary else {}


## What is installed, three ways: by profile key, by lowercased id@version,
## and by host ref. A pack from a mod site knows only the host ref.
func _modpack_installed_index() -> Dictionary:
	var keys: Dictionary = {}
	var id_ver: Dictionary = {}
	var refs: Dictionary = {}
	var persisted := _get_persisted_mod_sources()
	for installed_entry in _ui_mod_entries:
		var pk: String = str(installed_entry.get("profile_key", ""))
		if pk != "":
			keys[pk] = true
		var inst_id_l: String = str(installed_entry.get("mod_id", "")).to_lower()
		var inst_ver: String = str(installed_entry.get("version", ""))
		if inst_id_l != "":
			id_ver[inst_id_l + "@" + inst_ver] = true
		var rk := host_ref_key(_entry_host_ref(installed_entry, persisted))
		if rk != "":
			# Several installed copies: any version satisfies an unpinned record.
			var vers: Array = refs.get(rk, [])
			vers.append(inst_ver)
			refs[rk] = vers
	return {"keys": keys, "id_ver": id_ver, "refs": refs}


## True when a pack's source record names a host ref that is installed, at
## the record's version when it pins one.
func _modpack_source_installed(src_data: Variant, installed_refs: Dictionary) -> bool:
	if not (src_data is Dictionary):
		return false
	var rec := _normalize_source_record(src_data)
	var rk := host_ref_key(_source_host_ref(rec))
	if rk == "" or not installed_refs.has(rk):
		return false
	var want := str(rec["version"]).strip_edges().lstrip("vV")
	if want == "":
		return true
	for v in (installed_refs[rk] as Array):
		if str(v).strip_edges().lstrip("vV") == want:
			return true
	return false


## The host ref a normalized source record names, or {} when it names none.
func _source_host_ref(rec: Dictionary) -> Dictionary:
	if str(rec.get("provider", "")) == "" or str(rec.get("id", "")) == "":
		return {}
	return host_ref(str(rec["provider"]), str(rec["id"]))


## Fetchable only from a host this build can download from.
func _modpack_ref_downloadable(ref: Dictionary) -> bool:
	if not host_ref_valid(ref):
		return false
	return bool(host_caps(str(ref["provider"]))["resolve_file"])


func _modpack_cooldown_seconds(provider: String) -> int:
	return host_rate_cooldown_seconds(provider)


# Wait out an armed rate-limit cooldown on one host, or one mid-apply 429
# would fail every remaining mod. Ticks the progress countdown; never retries a request.
func _await_host_rate_cooldown(provider: String, progress: Callable, current: int, total: int) -> void:
	while not _modpack_apply_cancelled:
		var wait_s := _modpack_cooldown_seconds(provider)
		if wait_s <= 0:
			return
		if progress.is_valid():
			progress.call({"current": current, "total": total, "mod_name": "", "action": "rate_wait",
					"wait_s": wait_s, "host": host_display_name(provider)})
		if get_tree() == null:
			return
		await get_tree().create_timer(1.0).timeout


# The apply result for a failure. Every return from apply_modpack carries
# these keys; the counts describe the downloads that ran before the failure.
func _modpack_apply_failure(error: String, downloaded: int = 0, failed_downloads: int = 0,
		failures: Array = []) -> Dictionary:
	return {
		"ok": false,
		"error": error,
		"downloaded": downloaded,
		"failed_downloads": failed_downloads,
		"failures": failures,
	}

# Apply a discovered modpack: back up, download missing mods, materialize,
# switch, mark active. progress is Callable(info) with {current, total, mod_name,
# action}, action one of downloading | skipped | applying | rate_wait.
# Returns {ok, error, downloaded, failed_downloads, failures}, plus
# cancelled=true when the user cancelled during the downloads.
func apply_modpack(entry: Dictionary, tabs: TabContainer, progress: Callable = Callable()) -> Dictionary:
	# apply awaits during downloads; a second Apply click would race on cfg writes.
	if _modpack_apply_in_progress:
		return _modpack_apply_failure("Another apply is in progress; wait for it to finish")
	_modpack_apply_in_progress = true
	_modpack_apply_cancelled = false

	var result := await _apply_modpack_inner(entry, tabs, progress)
	_modpack_apply_in_progress = false
	return result

# Inner apply flow; the outer wrapper manages the in-progress flag.
func _apply_modpack_inner(entry: Dictionary, tabs: TabContainer, progress: Callable) -> Dictionary:
	var validation := _validate_modpack(entry)
	if not bool(validation.get("ok", false)):
		return _modpack_apply_failure(str(validation.get("error", "")))

	var sanitized: String = str(entry.get("sanitized_name", ""))
	if sanitized.is_empty():
		return _modpack_apply_failure("Invalid modpack name")
	var modpack_profile := MODPACK_PROFILE_PREFIX + sanitized
	var backup_profile := MODPACK_BACKUP_PREFIX + sanitized

	# The UI hides Apply while another pack is active; guard anyway.
	var current_active := get_active_modpack()
	if current_active != "" and current_active != sanitized:
		return _modpack_apply_failure("Unload " + current_active + " before applying another modpack")

	# Re-apply of the active pack skips backup, materialize and switch (each
	# would clobber user state); it only re-downloads missing mods.
	var is_reapply := current_active == sanitized

	# Download before touching state so a network failure cannot half-apply.
	var missing := _get_missing_mods_for_modpack(entry)
	var failed_dl: int = 0
	var done_dl: int = 0
	var failures: Array = []
	if not missing.is_empty():
		_log_info("[Modpack] applying " + sanitized + ": " + str(missing.size()) + " mod(s) to install")
		var total := missing.size()
		for i in range(total):
			var item_ref: Dictionary = (missing[i] as Dictionary).get("ref", {})
			if not item_ref.is_empty() and _modpack_cooldown_seconds(str(item_ref["provider"])) > 0:
				await _await_host_rate_cooldown(str(item_ref["provider"]), progress, i + 1, total)
			# Cancel check before each download; an in-flight request cannot be interrupted.
			if _modpack_apply_cancelled:
				_log_info("[Modpack] cancelled by user at item %d of %d" % [i + 1, total])
				return {
					"ok": false,
					"error": "Cancelled by user after downloading %d of %d mod(s)" % [done_dl, total],
					"downloaded": done_dl,
					"failed_downloads": failed_dl,
					"failures": failures,
					"cancelled": true,
				}
			var item: Dictionary = missing[i]
			var pk: String = str(item.get("profile_key", "?"))
			var ref: Dictionary = item.get("ref", {})
			var version: String = str(item.get("version", ""))
			var sha: String = str(item.get("sha256", ""))
			# Sourceless entries cannot be downloaded; record them so the summary shows them.
			if bool(item.get("unreachable", false)):
				failed_dl += 1
				var u_reason: String = str(item.get("unreachable_reason", "no downloadable source"))
				failures.append({
					"profile_key": pk,
					"error": u_reason,
					"ref": ref,
					"version": version,
				})
				_log_warning("[Modpack]   skipped: " + pk + " -- " + u_reason)
				if progress.is_valid():
					progress.call({"current": i + 1, "total": total, "mod_name": pk, "action": "skipped"})
				continue
			if progress.is_valid():
				progress.call({"current": i + 1, "total": total, "mod_name": pk, "action": "downloading"})
			var version_tag := (" v" + version) if version != "" else " (primary)"
			_log_info("[Modpack] downloading " + pk + " (" + host_ref_key(ref) + version_tag + ")")
			# allow_rename_on_collision: a different version lands beside the existing file; dedup picks one.
			var r: Dictionary = await download_mod_from_ref(ref, version, true, sha)
			if bool(r.get("ok", false)):
				done_dl += 1
				_log_info("[Modpack]   ok: " + str(r.get("file_name", "?")))
			else:
				var err: String = str(r.get("error", "unknown"))
				# Both candidate filenames occupied, typically from a previous attempt; the mod is on disk.
				if err.begins_with("Already have"):
					done_dl += 1
					_log_info("[Modpack]   already on disk: " + pk + " (" + err + ")")
					continue
				failed_dl += 1
				failures.append({
					"profile_key": pk,
					"error": err,
					"ref": ref,
					"version": str(item.get("version", "")),
					"sha256": sha,
				})
				_log_warning("[Modpack]   failed: " + pk + " -- " + err)
		_ui_mod_entries = collect_mod_metadata()
		var cfg_apply := ConfigFile.new()
		cfg_apply.load(UI_CONFIG_PATH)
		_apply_profile_to_entries(cfg_apply, _active_profile)
		_mark_mod_set_changed()
		if progress.is_valid():
			progress.call({"current": missing.size(), "total": missing.size(), "mod_name": "", "action": "applying"})

	# Re-check cancel after the loop: a cancel during the final download has no
	# next loop-top check. No state below has been mutated yet.
	if _modpack_apply_cancelled:
		_log_info("[Modpack] cancelled by user after the download phase; apply aborted before any state change")
		return {
			"ok": false,
			"error": "Cancelled by user after downloading %d mod(s)" % done_dl,
			"downloaded": done_dl,
			"failed_downloads": failed_dl,
			"failures": failures,
			"cancelled": true,
		}

	if not is_reapply:
		# 1. Back up the current profile's sections to the backup slot.
		var pre_active := _active_profile
		var cfg := ConfigFile.new()
		# A missing file is fine, but any other load failure means an empty cfg,
		# and persisting that would erase every profile. Abort before mutating.
		var cfg_err := cfg.load(UI_CONFIG_PATH)
		if cfg_err != OK and cfg_err != ERR_FILE_NOT_FOUND:
			return _modpack_apply_failure("Cannot read your mod settings file (mod_config.cfg, error %d) -- the modpack was not applied and your profiles are unchanged. Any downloaded mods remain in your mods folder. Restart the game and try again." % cfg_err,
					done_dl, failed_dl, failures)

		var src_en := _profile_sec(pre_active, ".enabled")
		var src_pr := _profile_sec(pre_active, ".priority")
		var bk_en := _profile_sec(backup_profile, ".enabled")
		var bk_pr := _profile_sec(backup_profile, ".priority")

		if cfg.has_section(bk_en):
			cfg.erase_section(bk_en)
		if cfg.has_section(bk_pr):
			cfg.erase_section(bk_pr)

		if cfg.has_section(src_en):
			for k: String in cfg.get_section_keys(src_en):
				cfg.set_value(bk_en, k, cfg.get_value(src_en, k))
		if cfg.has_section(src_pr):
			for k: String in cfg.get_section_keys(src_pr):
				cfg.set_value(bk_pr, k, cfg.get_value(src_pr, k))

		cfg.set_value("settings", "modpack_backup_profile", pre_active)
		# Record that step 1 completed even when it copied nothing: unload must
		# distinguish an empty backup from a missing one or it refuses forever.
		cfg.set_value("settings", "modpack_backup_valid", true)
		# Set active_modpack now: it is the crash trigger the boot reconciler keys off.
		cfg.set_value("settings", "active_modpack", sanitized)
		_persist_ui_cfg(cfg)

		# Snapshot pre-modpack MCM; vanilla has no MCM state worth preserving.
		if pre_active != VANILLA_PROFILE:
			_snapshot_mcm_to(backup_profile)

		# 2. Materialize the modpack profile from the zip unless the slot exists (user edits).
		var cfg2_err := cfg.load(UI_CONFIG_PATH)
		if cfg2_err != OK:
			# Same empty-cfg hazard as step 1; the reconciler clears the flag next boot.
			return _modpack_apply_failure("Cannot read settings (error %d) -- nothing was changed." % cfg2_err,
					done_dl, failed_dl, failures)
		if not cfg.has_section(_profile_sec(modpack_profile, ".enabled")):
			var mat_result := _materialize_modpack_profile(entry, modpack_profile)
			if not bool(mat_result.get("ok", false)):
				# Nothing took effect on this clean return; clear the flag set in step 1.
				cfg.set_value("settings", "active_modpack", "")
				_persist_ui_cfg(cfg)
				return _modpack_apply_failure(str(mat_result.get("error", "")),
						done_dl, failed_dl, failures)

		# 3. Switch to the modpack profile (handles the MCM swap).
		_switch_profile(modpack_profile)

		# 4. Re-assert active_modpack (the switch rewrote cfg), but only when the
		# reload succeeded; the flag is already on disk from step 1.
		var cfg5_err := cfg.load(UI_CONFIG_PATH)
		if cfg5_err == OK:
			cfg.set_value("settings", "active_modpack", sanitized)
			_persist_ui_cfg(cfg)
		else:
			_log_warning("[Modpack] could not re-read mod_config.cfg after profile switch (error %d) -- skipping the active-flag re-assert (already set at step 1)" % cfg5_err)

	elif done_dl > 0:
		# The slot was kept; match its keys to the mods that just landed.
		if _modpack_reconcile_profile_keys(modpack_profile, _modpack_sources(entry)) > 0:
			var cfg_re := ConfigFile.new()
			if cfg_re.load(UI_CONFIG_PATH) == OK:
				_apply_profile_to_entries(cfg_re, _active_profile)

	# 6. Refresh the Mods tab.
	if is_instance_valid(tabs):
		_rebuild_mods_tab(tabs)

	return {
		"ok": true,
		"error": "",
		"downloaded": done_dl,
		"failed_downloads": failed_dl,
		"failures": failures,
	}

# Read a modpack zip into a profile slot: enabled/priority sections into
# mod_config.cfg, the MCM/ tree into the profile's snapshot slot. {ok, error}.
func _materialize_modpack_profile(entry: Dictionary, profile_name: String) -> Dictionary:
	var file_path: String = str(entry["file_path"])
	var reader := ZIPReader.new()
	if reader.open(file_path) != OK:
		return {"ok": false, "error": "Cannot open modpack zip"}
	var files := reader.get_files()
	if not ("profile.json" in files):
		reader.close()
		return {"ok": false, "error": "Modpack missing profile.json"}
	var bytes := reader.read_file("profile.json")
	var parsed_v: Variant = JSON.parse_string(bytes.get_string_from_utf8())
	if not (parsed_v is Dictionary):
		reader.close()
		return {"ok": false, "error": "Modpack profile.json is invalid"}
	var pd: Dictionary = parsed_v

	var cfg := ConfigFile.new()
	# Same empty-cfg guard as apply step 1; missing file is fine.
	var cfg_err := cfg.load(UI_CONFIG_PATH)
	if cfg_err != OK and cfg_err != ERR_FILE_NOT_FOUND:
		reader.close()
		return {"ok": false, "error": "Cannot read your mod settings file (mod_config.cfg, error %d) -- modpack profile not created. Restart the game and try again." % cfg_err}
	var en_sec := _profile_sec(profile_name, ".enabled")
	var pr_sec := _profile_sec(profile_name, ".priority")
	if cfg.has_section(en_sec):
		cfg.erase_section(en_sec)
	if cfg.has_section(pr_sec):
		cfg.erase_section(pr_sec)

	# Third-party values: type-check before bool()/int(); junk degrades to defaults.
	var enabled_dict: Dictionary = pd.get("enabled", {}) if pd.get("enabled") is Dictionary else {}
	for k in enabled_dict.keys():
		var ev = enabled_dict[k]
		var en_on: bool = (ev is bool and ev) or ((ev is int or ev is float) and ev != 0)
		cfg.set_value(en_sec, str(k), en_on)
	var priority_dict: Dictionary = pd.get("priority", {}) if pd.get("priority") is Dictionary else {}
	for k in priority_dict.keys():
		var pv_raw = priority_dict[k]
		var pv: int = int(pv_raw) if (pv_raw is int or pv_raw is float) else 0
		cfg.set_value(pr_sec, str(k), clampi(pv, PRIORITY_MIN, PRIORITY_MAX))
	# dep_ignore overrides travel with the pack; sparse, true-only.
	var ig_sec := _profile_sec(profile_name, ".dep_ignore")
	if cfg.has_section(ig_sec):
		cfg.erase_section(ig_sec)
	var dep_ignore_dict: Dictionary = pd.get("dep_ignore", {}) if pd.get("dep_ignore") is Dictionary else {}
	for k in dep_ignore_dict.keys():
		var iv = dep_ignore_dict[k]
		if (iv is bool and iv) or ((iv is int or iv is float) and iv != 0):
			cfg.set_value(ig_sec, str(k), true)
	_persist_ui_cfg(cfg)
	# The download phase already rescanned, so keys can match what landed on disk.
	var sources_v: Variant = pd.get("sources")
	_modpack_reconcile_profile_keys(profile_name, sources_v if sources_v is Dictionary else {})

	# Extract the MCM tree into the snapshot slot; _switch_profile restores from it.
	var mcm_data: Dictionary = {}
	for f in files:
		if not f.begins_with("MCM/") or f.ends_with("/"):
			continue
		var rel: String = f.substr(4)
		if rel.contains("..") or rel.begins_with("/") or rel.is_empty():
			continue
		mcm_data[rel] = reader.read_file(f)
	reader.close()
	_write_mcm_snapshot_from_data(profile_name, mcm_data)

	return {"ok": true, "error": ""}

# Unload the active modpack: restore backup state, clear the flag. The slot is kept.
func unload_modpack(tabs: TabContainer) -> Dictionary:
	var cfg := ConfigFile.new()
	# A hard read failure would misreport as "No modpack is active"; say what happened.
	var cfg_err := cfg.load(UI_CONFIG_PATH)
	if cfg_err != OK and cfg_err != ERR_FILE_NOT_FOUND:
		return {"ok": false, "error": "Cannot read your mod settings file (mod_config.cfg, error %d) -- nothing was unloaded. Restart the game and try again." % cfg_err}
	var active := str(cfg.get_value("settings", "active_modpack", ""))
	if active == "":
		return {"ok": false, "error": "No modpack is active"}

	var backup_profile := MODPACK_BACKUP_PREFIX + active
	var pre_active := str(cfg.get_value("settings", "modpack_backup_profile", "Default"))

	# 1. Restore backup sections into the pre-active profile slot.
	var bk_en := _profile_sec(backup_profile, ".enabled")
	var bk_pr := _profile_sec(backup_profile, ".priority")
	var dst_en := _profile_sec(pre_active, ".enabled")
	var dst_pr := _profile_sec(pre_active, ".priority")

	# Backup gone: erasing the destination would wipe the pre-apply profile, so
	# abort. Absent sections alone are not proof (a pack applied with no mods has
	# an empty backup), so trust the apply-time flag; the section check covers older cfgs.
	var backup_written := bool(cfg.get_value("settings", "modpack_backup_valid", false))
	if not backup_written and not cfg.has_section(bk_en) and not cfg.has_section(bk_pr):
		return {"ok": false,
				"error": "The backup for this modpack is missing, so nothing was unloaded and your profiles are untouched. To force-remove the modpack, quit the game and delete the active_modpack line from mod_config.cfg."}

	if cfg.has_section(dst_en):
		cfg.erase_section(dst_en)
	if cfg.has_section(dst_pr):
		cfg.erase_section(dst_pr)
	if cfg.has_section(bk_en):
		for k: String in cfg.get_section_keys(bk_en):
			cfg.set_value(dst_en, k, cfg.get_value(bk_en, k))
	if cfg.has_section(bk_pr):
		for k: String in cfg.get_section_keys(bk_pr):
			cfg.set_value(dst_pr, k, cfg.get_value(bk_pr, k))

	# 2. Clear backup sections + markers.
	if cfg.has_section(bk_en):
		cfg.erase_section(bk_en)
	if cfg.has_section(bk_pr):
		cfg.erase_section(bk_pr)
	cfg.set_value("settings", "modpack_backup_profile", "")
	cfg.set_value("settings", "modpack_backup_valid", false)
	cfg.set_value("settings", "active_modpack", "")
	_persist_ui_cfg(cfg)

	# 3. Switch to the pre-active profile; step 4 overwrites its MCM.
	_switch_profile(pre_active)

	# 4. Restore the pre-modpack MCM from the backup snapshot, the authoritative copy.
	var mcm_ok := true
	if _has_mcm_snapshot(backup_profile):
		mcm_ok = _restore_mcm_from(backup_profile)

	# 5. Wipe the backup slot, only once the MCM restore consumed it.
	if mcm_ok:
		_remove_dir_recursive(MCM_SNAPSHOT_BASE.path_join(backup_profile))
	else:
		_log_warning("[Modpack] unload: MCM restore incomplete -- leaving " + MCM_SNAPSHOT_BASE.path_join(backup_profile) + " in place; it will be cleaned up by the next apply/unload")

	# 6. Refresh the Mods tab.
	if is_instance_valid(tabs):
		_rebuild_mods_tab(tabs)

	return {"ok": true, "error": ""}

# Re-attempt failed downloads from a previous apply; cancelled items stay in
# the failures list. Returns {downloaded, failures, cancelled}.
func retry_failed_downloads(failures: Array, progress: Callable = Callable()) -> Dictionary:
	# Same serialization guard as apply_modpack.
	if _modpack_apply_in_progress:
		return {"downloaded": 0, "failures": failures, "cancelled": false}
	_modpack_apply_in_progress = true
	var still_failed: Array = []
	var newly_downloaded: int = 0
	for i in range(failures.size()):
		var item: Dictionary = failures[i]
		if _modpack_apply_cancelled:
			still_failed.append(item)
			continue
		var pk: String = str(item.get("profile_key", "?"))
		var ref: Dictionary = item.get("ref", {})
		var version: String = str(item.get("version", ""))
		var sha: String = str(item.get("sha256", ""))
		if not _modpack_ref_downloadable(ref):
			still_failed.append(item)
			continue
		var provider := str(ref["provider"])
		if _modpack_cooldown_seconds(provider) > 0:
			await _await_host_rate_cooldown(provider, progress, i + 1, failures.size())
			if _modpack_apply_cancelled:
				still_failed.append(item)
				continue
		if progress.is_valid():
			progress.call({"current": i + 1, "total": failures.size(), "mod_name": pk, "action": "retrying"})
		_log_info("[Modpack][Retry] " + pk + " (" + host_ref_key(ref) + ")")
		var r: Dictionary = await download_mod_from_ref(ref, version, true, sha)
		if bool(r.get("ok", false)):
			newly_downloaded += 1
			_log_info("[Modpack][Retry]   ok: " + str(r.get("file_name", "?")))
		else:
			var err: String = str(r.get("error", "unknown"))
			still_failed.append({
				"profile_key": pk,
				"error": err,
				"ref": ref,
				"version": version,
				"sha256": sha,
			})
			_log_warning("[Modpack][Retry]   failed: " + pk + " -- " + err)
	if newly_downloaded > 0:
		_ui_mod_entries = collect_mod_metadata()
		# The retried mods may have landed under names the pack did not use.
		var active := get_active_modpack()
		if active != "":
			for mp in _modpack_entries:
				if str((mp as Dictionary).get("sanitized_name", "")) == active:
					_modpack_reconcile_profile_keys(MODPACK_PROFILE_PREFIX + active, _modpack_sources(mp))
					break
		var cfg := ConfigFile.new()
		cfg.load(UI_CONFIG_PATH)
		_apply_profile_to_entries(cfg, _active_profile)
		_mark_mod_set_changed()
	_modpack_apply_in_progress = false
	return {"downloaded": newly_downloaded, "failures": still_failed, "cancelled": _modpack_apply_cancelled}
