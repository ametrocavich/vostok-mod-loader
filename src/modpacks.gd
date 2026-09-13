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
## States (owners: apply_modpack, unload_modpack, the boot reconciler in ui.gd
## _load_ui_config, and _restore_apply_snapshot, refused while a pack is active):
##   no pack      active_modpack is ""; stale backup sections are erased by the next apply.
##   downloading  awaiting missing-mod downloads; no state touched yet. Serialized
##                by _modpack_apply_in_progress; Cancel sets _modpack_apply_cancelled.
##   mutating     _apply_modpack_inner's numbered steps, fresh apply only:
##                0. independent restore point, 1. copy the active profile into the
##                backup slot and set active_modpack early (the crash trigger the
##                reconciler keys off), 2. materialize the modpack__ profile from the
##                zip if absent, 3. apply overrides, 4. _switch_profile into the slot,
##                5. re-assert active_modpack. A failure after step 1 leaves the flag
##                set; the next boot's reconciler clears it.
##   active       active_profile is the slot. Re-apply is downloads-only.
##   unloading    aborts untouched when the backup is gone; else restore backup
##                sections, clear flags, restore overrides from the manifest,
##                _switch_profile back, restore the pre-pack MCM, wipe the slot dir.
##
## Invariants: downloads strictly precede state mutation; the independent
## restore point (user://.modpack_backups/) is never consumed by the state
## machine, only pruned; reconciler recovery never deletes the backup slot; at
## most one pack is active at a time.

const MODPACK_PROFILE_PREFIX := "modpack__"
const MODPACK_BACKUP_PREFIX := "_before_modpack_"

# Zip paths with these prefixes (relative to user://) are dropped during apply:
# a pack must not touch the loader's state files, snapshot dirs or caches.
const MODPACK_OVERRIDE_DENY_PREFIXES: Array[String] = [
	"mod_config.cfg",          # the launcher's config -- modpack profile is its own slot
	".profile_snapshots/",     # backup snapshots
	".modpack_backups/",       # pre-apply restore points -- packs must not poison them
	"mws_cache/",              # Browse-tab thumbnail / API cache
	"vmz_mount_cache/",        # archive mount tmpdir
	"modloader_",              # heartbeat, safe-mode, conflicts, hooks, etc.
	# The one loader state file without the modloader_ prefix; boot.gd mounts the
	# paths in it before the scanner runs. Keep in sync with PASS_STATE_PATH.
	"mod_pass_state.cfg",
]

# Mountable resource-pack formats; boot.gd hands exactly these to load_resource_pack().
const MODPACK_OVERRIDE_DENY_EXTENSIONS: Array[String] = ["pck", "vmz"]

# Profiles the modpack system manages internally; hidden from the dropdown.
func _is_modpack_managed_profile(profile_name: String) -> bool:
	return profile_name.begins_with(MODPACK_PROFILE_PREFIX) \
			or profile_name.begins_with(MODPACK_BACKUP_PREFIX)

# Count truthy values in a pack's `enabled` map; values are third-party, so type-check.
func _count_truthy(d: Dictionary) -> int:
	var count := 0
	for k in d.keys():
		var v = d[k]
		if (v is bool and v) or ((v is int or v is float) and v != 0):
			count += 1
	return count

# profile.json carries the metroprofile v1 schema; sole writer is
# _profile_to_json_string (ui.gd). See docs/wiki/Profile-Format.md.

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

# Vet a path inside the modpack zip and return the normalized form callers
# must write, or "" when denied (traversal, loader state, resource packs).
# It returns the path, not a bool: the OS resolves "./x" and "x" to the same
# file, so the gate and the write must use the same string.
func _modpack_override_rel(rel: String) -> String:
	# Lowercase only for matching (Windows is case-insensitive).
	var norm := rel.replace("\\", "/").simplify_path()
	var probe := norm.to_lower()
	if norm.is_empty():
		return ""
	# simplify_path turns a bare "./" into "." -- a directory, not a file.
	if probe == "." or probe.ends_with("/"):
		return ""
	# A leading ".." survives simplify_path, so check after normalizing.
	if probe.contains(".."):
		return ""
	# Drive letters / NTFS alternate data streams; legit entries have no ":".
	if probe.contains(":"):
		return ""
	if probe.begins_with("/"):
		return ""
	# MCM/ goes through the per-profile MCM snapshot mechanic, not overrides.
	if probe.begins_with("mcm/"):
		return ""
	# profile.json is the schema, not an override.
	if probe == "profile.json":
		return ""
	if probe.get_extension() in MODPACK_OVERRIDE_DENY_EXTENSIONS:
		return ""
	for prefix in MODPACK_OVERRIDE_DENY_PREFIXES:
		if probe.begins_with(prefix):
			return ""
	return norm

# Apply the pack's non-MCM, non-profile.json files as user:// overrides,
# snapshotting originals and a manifest into the backup slot. Returns the count applied.
func _apply_modpack_overrides(entry: Dictionary, backup_profile: String) -> int:
	var file_path: String = str(entry.get("file_path", ""))
	if file_path.is_empty():
		return 0
	var reader := ZIPReader.new()
	if reader.open(file_path) != OK:
		return 0

	var backup_root := MCM_SNAPSHOT_BASE.path_join(backup_profile)
	var overrides_root := backup_root.path_join("overrides")
	var manifest := {"replaced": [] as Array, "added": [] as Array}
	var applied := 0

	for raw_f in reader.get_files():
		if raw_f.ends_with("/"):
			continue
		# Write and record the vetted spelling, never raw_f: unload replays the manifest.
		var f := _modpack_override_rel(raw_f)
		if f.is_empty():
			continue
		var bytes := reader.read_file(raw_f)
		var user_path := "user://" + f
		var existed := FileAccess.file_exists(user_path)
		if existed:
			var bk_path := overrides_root.path_join(f)
			DirAccess.make_dir_recursive_absolute(bk_path.get_base_dir())
			var backed_up := false
			var orig := FileAccess.open(user_path, FileAccess.READ)
			if orig != null:
				var orig_bytes := orig.get_buffer(orig.get_length())
				orig.close()
				var bk_f := FileAccess.open(bk_path, FileAccess.WRITE)
				if bk_f != null:
					backed_up = bk_f.store_buffer(orig_bytes)
					bk_f.close()
			if not backed_up:
				_log_warning("[Modpack] could not snapshot original '" + f
						+ "' to the backup slot -- skipping this override (user file left untouched)")
				continue
			(manifest["replaced"] as Array).append(f)
		else:
			(manifest["added"] as Array).append(f)
		DirAccess.make_dir_recursive_absolute(user_path.get_base_dir())
		var dst := FileAccess.open(user_path, FileAccess.WRITE)
		if dst != null:
			dst.store_buffer(bytes)
			dst.close()
			applied += 1

	reader.close()

	# A failed manifest write is loud: unload would restore per a stale manifest.
	# The pre-apply restore point still covers recovery, so warn, don't abort.
	DirAccess.make_dir_recursive_absolute(backup_root)
	var manifest_path := backup_root.path_join("overrides_manifest.json")
	var mf := FileAccess.open(manifest_path, FileAccess.WRITE)
	if mf != null:
		if not mf.store_string(JSON.stringify(manifest, "  ")):
			_log_warning("[Modpack] FAILED writing overrides manifest " + manifest_path
					+ " (disk full?) -- Unload may not restore overridden files; use the Restore button if needed")
		mf.close()
	else:
		_log_warning("[Modpack] could NOT write overrides manifest " + manifest_path
				+ " -- Unload will not restore the " + str(applied)
				+ " override file(s) just applied; use the Restore button if needed")

	return applied

# Reverse _apply_modpack_overrides via the manifest. No-op without one.
func _restore_modpack_overrides(backup_profile: String) -> bool:
	var backup_root := MCM_SNAPSHOT_BASE.path_join(backup_profile)
	var manifest_path := backup_root.path_join("overrides_manifest.json")
	if not FileAccess.file_exists(manifest_path):
		return true
	var mf := FileAccess.open(manifest_path, FileAccess.READ)
	if mf == null:
		# Originals may sit in overrides/ unlocatable; the slot must survive.
		return false
	var content := mf.get_as_text()
	mf.close()
	var parsed_v: Variant = JSON.parse_string(content)
	if not (parsed_v is Dictionary):
		return false
	var manifest: Dictionary = parsed_v

	var overrides_root := backup_root.path_join("overrides")

	var all_ok := true
	var replaced: Array = manifest.get("replaced", []) if manifest.get("replaced") is Array else []
	for path_v in replaced:
		var rel: String = str(path_v)
		var bk_path := overrides_root.path_join(rel)
		var user_path := "user://" + rel
		if not FileAccess.file_exists(bk_path):
			# The apply-time snapshot never captured it; nothing recoverable.
			continue
		var src := FileAccess.open(bk_path, FileAccess.READ)
		if src == null:
			all_ok = false
			continue
		var bytes := src.get_buffer(src.get_length())
		src.close()
		DirAccess.make_dir_recursive_absolute(user_path.get_base_dir())
		var dst := FileAccess.open(user_path, FileAccess.WRITE)
		if dst != null:
			# A partial write is a failure, or unload wipes the slot with the original half-restored.
			if not dst.store_buffer(bytes):
				all_ok = false
			dst.close()
		else:
			all_ok = false

	var added: Array = manifest.get("added", []) if manifest.get("added") is Array else []
	for path_v in added:
		var rel: String = str(path_v)
		var user_path := "user://" + rel
		if FileAccess.file_exists(user_path):
			DirAccess.remove_absolute(user_path)

	return all_ok

# --- Independent pre-apply restore points: a write-once snapshot the state
# machine never touches, the Restore button's safety net.

# Capture mod_config.cfg, live user://MCM/ and the files this pack will
# overwrite into user://.modpack_backups/<pack>_<timestamp>/. Never blocks the apply.
func _snapshot_state_before_apply(entry: Dictionary) -> String:
	var sanitized: String = str(entry.get("sanitized_name", "pack"))
	# Filesystem-safe sortable timestamp: 2026-06-30T14-22-08
	var stamp := Time.get_datetime_string_from_system().replace(":", "-")
	var snap_root := MODPACK_SNAPSHOT_DIR.path_join(sanitized + "_" + stamp)
	if DirAccess.make_dir_recursive_absolute(snap_root) != OK:
		_log_warning("[Modpack] could NOT create restore point dir " + snap_root
				+ " -- apply will proceed WITHOUT a restore point")
		return ""

	var captured := 0

	# 1. Profiles + settings.
	var cfg_copy_failed := false
	if FileAccess.file_exists(UI_CONFIG_PATH):
		if DirAccess.copy_absolute(UI_CONFIG_PATH, snap_root.path_join("mod_config.cfg")) == OK:
			captured += 1
		else:
			cfg_copy_failed = true
			_log_warning("[Modpack] restore point: failed to copy mod_config.cfg into " + snap_root)

	# 2. Live MCM tree. If it did not exist, restore must wipe rather than skip (mcm_absent).
	var mcm_existed := DirAccess.dir_exists_absolute(MCM_SOURCE_DIR)
	if _copy_dir_recursive(MCM_SOURCE_DIR, snap_root.path_join("MCM")):
		captured += 1

	# 3. Files the pack will overwrite (for revert) and add (so restore can delete them).
	var added: Array = []
	var file_path: String = str(entry.get("file_path", ""))
	if not file_path.is_empty():
		var reader := ZIPReader.new()
		if reader.open(file_path) == OK:
			var ov_root := snap_root.path_join("overrides")
			for raw_f in reader.get_files():
				if raw_f.ends_with("/"):
					continue
				# Same normalization as _apply_modpack_overrides.
				var f := _modpack_override_rel(raw_f)
				if f.is_empty():
					continue
				var user_path := "user://" + f
				if FileAccess.file_exists(user_path):
					var dst := ov_root.path_join(f)
					DirAccess.make_dir_recursive_absolute(dst.get_base_dir())
					if DirAccess.copy_absolute(user_path, dst) == OK:
						captured += 1
				else:
					added.append(f)
			reader.close()

	# Marker for the restore UI; "added" lets restore delete pack-added files.
	var meta := {
		"pack": sanitized,
		"created": Time.get_datetime_string_from_system(),
		"added": added,
		"mcm_absent": not mcm_existed,
	}
	var mf := FileAccess.open(snap_root.path_join("snapshot.json"), FileAccess.WRITE)
	if mf != null:
		mf.store_string(JSON.stringify(meta, "  "))
		mf.close()
	else:
		_log_warning("[Modpack] restore point: failed to write snapshot.json in " + snap_root)

	# Don't leave an empty dir masquerading as a restore point in the picker.
	if captured == 0 and FileAccess.file_exists(UI_CONFIG_PATH):
		_log_warning("[Modpack] restore point captured NOTHING -- removing " + snap_root
				+ "; apply will proceed WITHOUT a restore point")
		_remove_dir_recursive(snap_root)
		return ""

	# Without mod_config.cfg the snapshot cannot restore profiles; delete it.
	if cfg_copy_failed:
		_log_warning("[Modpack] restore point is missing mod_config.cfg -- removing " + snap_root
				+ "; apply will proceed WITHOUT a restore point")
		_remove_dir_recursive(snap_root)
		return ""

	_log_info("[Modpack] pre-apply restore point saved: " + snap_root + " (" + str(captured) + " item(s))")
	_prune_apply_snapshots()
	return snap_root

# Saved pre-apply restore points, newest first: {name, path, pack, created, sort_key}.
func _list_apply_snapshots() -> Array:
	var out: Array = []
	if not DirAccess.dir_exists_absolute(MODPACK_SNAPSHOT_DIR):
		return out
	var dir := DirAccess.open(MODPACK_SNAPSHOT_DIR)
	if dir == null:
		return out
	dir.list_dir_begin()
	while true:
		var name := dir.get_next()
		if name == "":
			break
		if not dir.current_is_dir():
			continue
		var path := MODPACK_SNAPSHOT_DIR.path_join(name)
		var pack := name
		var created := ""
		var meta_path := path.path_join("snapshot.json")
		if FileAccess.file_exists(meta_path):
			var mfr := FileAccess.open(meta_path, FileAccess.READ)
			if mfr != null:
				var parsed_v: Variant = JSON.parse_string(mfr.get_as_text())
				mfr.close()
				if parsed_v is Dictionary:
					pack = str((parsed_v as Dictionary).get("pack", name))
					created = str((parsed_v as Dictionary).get("created", ""))
		out.append({"name": name, "path": path, "pack": pack, "created": created})
	dir.list_dir_end()
	# Sort by timestamp, not folder name, or prune could delete a newer snapshot.
	# Falls back to the folder name's stamp when snapshot.json is missing.
	for s_v in out:
		var s: Dictionary = s_v
		var key := str(s["created"]).replace(":", "-")
		if key == "":
			var nm := str(s["name"])
			key = nm.substr(maxi(0, nm.length() - 19))
		s["sort_key"] = key
	out.sort_custom(func(a, b):
		return str(a["sort_key"]) > str(b["sort_key"]))
	return out

# Keep the most recent MODPACK_SNAPSHOT_KEEP restore points; delete older ones.
func _prune_apply_snapshots() -> void:
	var snaps := _list_apply_snapshots()
	for i in range(snaps.size()):
		if i >= MODPACK_SNAPSHOT_KEEP:
			_remove_dir_recursive(str(snaps[i]["path"]))

# A restore point's snapshot.json, or {} when missing or malformed.
func _read_snapshot_meta(snap_path: String) -> Dictionary:
	var meta_path := snap_path.path_join("snapshot.json")
	if not FileAccess.file_exists(meta_path):
		return {}
	var mfr := FileAccess.open(meta_path, FileAccess.READ)
	if mfr == null:
		return {}
	var parsed_v: Variant = JSON.parse_string(mfr.get_as_text())
	mfr.close()
	if parsed_v is Dictionary:
		return parsed_v as Dictionary
	return {}

# Restore-only recursive copy that includes dot-prefixed entries (a captured
# ".rtvcfg"). Profile and MCM swaps rely on _copy_dir_recursive's dot-skip.
func _copy_snapshot_tree_incl_hidden(src: String, dst: String) -> void:
	if not DirAccess.dir_exists_absolute(src):
		return
	DirAccess.make_dir_recursive_absolute(dst)
	var dir := DirAccess.open(src)
	if dir == null:
		return
	# On Linux/macOS dot entries are hidden and omitted by default.
	dir.include_hidden = true
	dir.list_dir_begin()
	while true:
		var name := dir.get_next()
		if name == "":
			break
		var src_full := src.path_join(name)
		var dst_full := dst.path_join(name)
		if dir.current_is_dir():
			_copy_snapshot_tree_incl_hidden(src_full, dst_full)
		else:
			var src_f := FileAccess.open(src_full, FileAccess.READ)
			if src_f == null:
				continue
			var bytes := src_f.get_buffer(src_f.get_length())
			src_f.close()
			var dst_f := FileAccess.open(dst_full, FileAccess.WRITE)
			if dst_f != null:
				dst_f.store_buffer(bytes)
				dst_f.close()
	dir.list_dir_end()

# Restore a pre-apply snapshot over live user:// state; keeps a .bak of the cfg. {ok, error}.
func _restore_apply_snapshot(snap_path: String) -> Dictionary:
	if not DirAccess.dir_exists_absolute(snap_path):
		return {"ok": false, "error": "Snapshot folder no longer exists"}

	# 1. mod_config.cfg. If absent the capture failed; restoring the rest would
	# be a mixed state reported as a clean revert. Refuse before mutating.
	var cfg_snap := snap_path.path_join("mod_config.cfg")
	if not FileAccess.file_exists(cfg_snap):
		return {"ok": false, "error": "This restore point is incomplete and cannot restore your profiles and settings. Nothing was changed -- pick a different restore point."}
	if FileAccess.file_exists(UI_CONFIG_PATH):
		DirAccess.copy_absolute(UI_CONFIG_PATH, UI_CONFIG_PATH + ".bak")
	if DirAccess.copy_absolute(cfg_snap, UI_CONFIG_PATH) != OK:
		return {"ok": false, "error": "Failed to restore mod_config.cfg"}

	# 2. Live MCM tree (wholesale replace so deleted-since files don't linger).
	var mcm_snap := snap_path.path_join("MCM")
	if DirAccess.dir_exists_absolute(mcm_snap):
		_remove_dir_recursive(MCM_SOURCE_DIR)
		_copy_dir_recursive(mcm_snap, MCM_SOURCE_DIR)
	elif bool(_read_snapshot_meta(snap_path).get("mcm_absent", false)):
		# user://MCM/ did not exist at snapshot time; whatever is there came from the pack.
		_remove_dir_recursive(MCM_SOURCE_DIR)

	# 3. Override files back to user://, via the dot-inclusive walker.
	var ov_root := snap_path.path_join("overrides")
	if DirAccess.dir_exists_absolute(ov_root):
		_copy_snapshot_tree_incl_hidden(ov_root, "user://")

	# 4. Delete files the pack added (recorded in snapshot.json).
	var meta_path := snap_path.path_join("snapshot.json")
	if FileAccess.file_exists(meta_path):
		var mfr := FileAccess.open(meta_path, FileAccess.READ)
		if mfr != null:
			var parsed_v: Variant = JSON.parse_string(mfr.get_as_text())
			mfr.close()
			if parsed_v is Dictionary:
				var added_v: Variant = (parsed_v as Dictionary).get("added", [])
				if added_v is Array:
					for rel_v in (added_v as Array):
						var ap := "user://" + str(rel_v)
						if FileAccess.file_exists(ap):
							DirAccess.remove_absolute(ap)

	_log_info("[Modpack] restored pre-apply snapshot: " + snap_path)
	return {"ok": true, "error": ""}


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
			# Not downloadable; surface an explanatory failure row.
			item["unreachable"] = true
			if not ref.is_empty():
				item["unreachable_reason"] = "this mod is hosted on " + host_display_name(str(ref["provider"])) \
						+ ", which the loader cannot download from -- install it manually"
			elif not (src_data is Dictionary) or (src_data as Dictionary).is_empty():
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
	if ref.is_empty() or not host_ref_valid(ref):
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


# Apply a discovered modpack: back up, download missing mods, materialize,
# switch, mark active. progress is Callable(info) with {current, total, mod_name,
# action}, action one of downloading | skipped | applying | rate_wait.
# Returns {ok, error, downloaded, failed_downloads}.
func apply_modpack(entry: Dictionary, tabs: TabContainer, progress: Callable = Callable()) -> Dictionary:
	# apply awaits during downloads; a second Apply click would race on cfg writes.
	if _modpack_apply_in_progress:
		return {"ok": false, "error": "Another apply is in progress; wait for it to finish"}
	_modpack_apply_in_progress = true
	_modpack_apply_cancelled = false

	var result := await _apply_modpack_inner(entry, tabs, progress)
	_modpack_apply_in_progress = false
	return result

# Inner apply flow; the outer wrapper manages the in-progress flag.
func _apply_modpack_inner(entry: Dictionary, tabs: TabContainer, progress: Callable) -> Dictionary:
	var validation := _validate_modpack(entry)
	if not bool(validation.get("ok", false)):
		return validation

	var sanitized: String = str(entry.get("sanitized_name", ""))
	if sanitized.is_empty():
		return {"ok": false, "error": "Invalid modpack name"}
	var modpack_profile := MODPACK_PROFILE_PREFIX + sanitized
	var backup_profile := MODPACK_BACKUP_PREFIX + sanitized

	# The UI hides Apply while another pack is active; guard anyway.
	var current_active := get_active_modpack()
	if current_active != "" and current_active != sanitized:
		return {"ok": false, "error": "Unload " + current_active + " before applying another modpack"}

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
		# Independent restore point before any mutation.
		_snapshot_state_before_apply(entry)
		# 1. Back up the current profile's sections to the backup slot.
		var pre_active := _active_profile
		var cfg := ConfigFile.new()
		# A missing file is fine, but any other load failure means an empty cfg,
		# and persisting that would erase every profile. Abort before mutating.
		var cfg_err := cfg.load(UI_CONFIG_PATH)
		if cfg_err != OK and cfg_err != ERR_FILE_NOT_FOUND:
			return {"ok": false, "error": "Cannot read your mod settings file (mod_config.cfg, error %d) -- the modpack was not applied and your profiles are unchanged. Any downloaded mods remain in your mods folder. Restart the game and try again." % cfg_err}

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
			return {"ok": false, "error": "Cannot read settings (error %d) -- nothing was changed." % cfg2_err}
		if not cfg.has_section(_profile_sec(modpack_profile, ".enabled")):
			var mat_result := _materialize_modpack_profile(entry, modpack_profile)
			if not bool(mat_result.get("ok", false)):
				# Nothing took effect on this clean return; clear the flag set in step 1.
				cfg.set_value("settings", "active_modpack", "")
				_persist_ui_cfg(cfg)
				return mat_result

		# 3. Apply override files, snapshotting originals into the backup slot.
		_apply_modpack_overrides(entry, backup_profile)

		# 4. Switch to the modpack profile (handles the MCM swap).
		_switch_profile(modpack_profile)

		# 5. Re-assert active_modpack (the switch rewrote cfg), but only when the
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

	# 3. Restore override files from the manifest (MCM/ never appears in it).
	var overrides_ok := _restore_modpack_overrides(backup_profile)

	# 4. Switch to the pre-active profile; step 5 overwrites its MCM.
	_switch_profile(pre_active)

	# 5. Restore the pre-modpack MCM from the backup snapshot, the authoritative copy.
	var mcm_ok := true
	if _has_mcm_snapshot(backup_profile):
		mcm_ok = _restore_mcm_from(backup_profile)

	# 6. Wipe the backup slot, only once both restores consumed it.
	if overrides_ok and mcm_ok:
		_remove_dir_recursive(MCM_SNAPSHOT_BASE.path_join(backup_profile))
	else:
		_log_warning("[Modpack] unload: backup-slot restore incomplete (overrides_ok=" + str(overrides_ok) + ", mcm_ok=" + str(mcm_ok) + ") -- leaving " + MCM_SNAPSHOT_BASE.path_join(backup_profile) + " in place; it will be cleaned up by the next apply/unload")

	# 7. Refresh the Mods tab.
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
		var item = failures[i]
		if not (item is Dictionary):
			continue
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


# Save the named profile as a modpack zip in <game>/mods/; refuses to overwrite.
func save_profile_as_modpack(profile_name: String, modpack_name: String = "", description: String = "", author: String = "") -> Dictionary:
	if _mods_dir.is_empty():
		_mods_dir = OS.get_executable_path().get_base_dir().path_join(MOD_DIR)
	# The pack name drives the zip filename and profile.json "name"; defaults to the profile name.
	var pack_name := modpack_name.strip_edges() if modpack_name.strip_edges() != "" else profile_name
	var safe := _sanitize_profile_name(pack_name)
	if safe.is_empty():
		return {"ok": false, "error": "Invalid modpack name"}
	var output := _mods_dir.path_join(safe + ".zip")
	if FileAccess.file_exists(output):
		return {"ok": false, "error": "A file named " + safe + ".zip already exists in your mods folder -- pick a different modpack name"}
	var res := _export_profile_to_zip(profile_name, output, description, author, pack_name)
	if bool(res.get("ok", false)):
		res["path"] = output
		res["display_name"] = pack_name
	return res
