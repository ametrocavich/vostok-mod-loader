## ----- modpacks.gd -----
## Modpack discovery, apply, unload. A modpack is a .zip in <game>/mods/
## with profile.json at the root (regular mods have mod.txt at root). The
## modloader differentiates them at scan time and routes them into the
## Modpacks tab instead of the Mods tab.
##
## Design: an applied modpack lives as a regular profile in mod_config.cfg
## (with the "modpack__" prefix), so all the existing profile lifecycle
## machinery (switch, save, MCM snapshot) handles it without special cases.
## The modpack zip is the *template*, consulted only on first apply or
## reset; once applied, user edits go to the profile slot and persist. The
## backup of pre-apply state lives in another prefix-named profile slot
## ("_before_modpack_") plus an MCM snapshot.
##
## Conventions:
##   modpack__<sanitized_name>           -- live state of an applied modpack
##   _before_modpack_<sanitized_name>    -- backup of pre-apply state
##   [settings] active_modpack=<name>    -- which modpack is currently active
##   [settings] modpack_backup_profile   -- which profile to restore on unload

const MODPACK_PROFILE_PREFIX := "modpack__"
const MODPACK_BACKUP_PREFIX := "_before_modpack_"

# Paths inside a modpack zip that should NOT be applied as user:// overrides.
# Anything matching any of these prefixes (relative to user://) is silently
# dropped during apply -- the modpack can ship them in its zip but they
# won't take effect. These are launcher-internal: modpacks must not affect
# the modloader's own state files, snapshot dirs, or caches.
const MODPACK_OVERRIDE_DENY_PREFIXES: Array[String] = [
	"mod_config.cfg",          # the launcher's config -- modpack profile is its own slot
	".profile_snapshots/",     # backup snapshots
	"mws_cache/",              # Browse-tab thumbnail / API cache
	"vmz_mount_cache/",        # archive mount tmpdir
	"modloader_",              # heartbeat, safe-mode, pass-state, etc.
]

# Profile names the modpack system manages internally. The Mods tab dropdown
# filters these out so the user only sees profiles they explicitly created.
func _is_modpack_managed_profile(profile_name: String) -> bool:
	return profile_name.begins_with(MODPACK_PROFILE_PREFIX) \
			or profile_name.begins_with(MODPACK_BACKUP_PREFIX)

# Pre-apply validation: open the zip, parse profile.json, sanity-check the
# schema. Catches malformed zips, missing profile.json, wrong schema version,
# missing required fields BEFORE apply has touched any state. Returns
# {ok: bool, error: String, enabled_count: int, total_count: int}.
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
		return {"ok": false, "error": "Zip is missing profile.json"}
	var bytes := reader.read_file("profile.json")
	reader.close()
	if bytes.is_empty():
		return {"ok": false, "error": "profile.json is empty"}
	var parsed_v: Variant = JSON.parse_string(bytes.get_string_from_utf8())
	if not (parsed_v is Dictionary):
		return {"ok": false, "error": "profile.json is not a JSON object"}
	var pd: Dictionary = parsed_v
	if int(pd.get("metroprofile", 0)) != 1:
		return {"ok": false, "error": "Unsupported metroprofile schema version"}
	if not (pd.get("name") is String):
		return {"ok": false, "error": "profile.json is missing 'name'"}
	if not (pd.get("enabled") is Dictionary):
		return {"ok": false, "error": "profile.json is missing 'enabled'"}
	var enabled: Dictionary = pd["enabled"]
	var enabled_count := 0
	for k in enabled.keys():
		if bool(enabled[k]):
			enabled_count += 1
	return {
		"ok": true,
		"error": "",
		"enabled_count": enabled_count,
		"total_count": enabled.size(),
	}

# Cheap content sniff: a zip with profile.json at the root is a modpack.
# Regular mods have mod.txt at root; presence of profile.json (and not
# mod.txt) is the distinguishing signal. Used by mod_discovery to skip
# modpack zips out of the regular mod list, and by collect_modpack_metadata
# to find them.
func _is_modpack_zip(file_path: String) -> bool:
	var reader := ZIPReader.new()
	if reader.open(file_path) != OK:
		return false
	var files := reader.get_files()
	var has_profile := files.has("profile.json")
	reader.close()
	return has_profile

# Read enough of a modpack zip to render a row in the Modpacks tab list.
# Doesn't fully validate the schema (apply does that); just pulls name +
# enabled count for display. Returns {} if the zip is malformed.
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
	var enabled: Dictionary = pd.get("enabled", {})
	var enabled_count := 0
	for k in enabled.keys():
		if bool(enabled[k]):
			enabled_count += 1
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
	}

# Scan <game>/mods/ for modpack zips. Refreshes _modpack_entries; called by
# the Modpacks tab build whenever it needs a fresh list (initial build,
# after apply, after unload).
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

	# Dedupe by sanitized_name. Without this, two zips whose names sanitize
	# to the same key both match the single active_modpack string in
	# mod_config.cfg -- both rows get tagged ACTIVE which is misleading.
	# Keep the newest by file mtime, attach the dropped files as
	# duplicates_hidden so the UI can surface them.
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
			# Sort newest mtime first so the "kept" one is the most recent
			# file the user wrote. Equal mtimes (rare) fall back to first-
			# seen scan order.
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

# True when a path inside the modpack zip should be skipped during override
# apply -- path traversal attempts and modloader-internal paths.
func _modpack_override_path_allowed(rel: String) -> bool:
	if rel.is_empty():
		return false
	if rel.contains(".."):
		return false
	if rel.begins_with("/"):
		return false
	# MCM/ is handled by the per-profile MCM snapshot mechanic, not the
	# generic overrides flow -- exclude it here.
	if rel.begins_with("MCM/"):
		return false
	# profile.json is the schema, not an override.
	if rel == "profile.json":
		return false
	for prefix in MODPACK_OVERRIDE_DENY_PREFIXES:
		if rel.begins_with(prefix):
			return false
	return true

# Apply the modpack's non-MCM, non-profile.json files as user:// overrides.
# Snapshots any pre-existing originals to the backup slot, copies the
# modpack's version into user://path, and writes a manifest the unload
# path uses to know which originals to restore vs which paths to delete.
# Returns the number of files applied (informational; failures are silent
# and just skipped). MCM/ files are handled separately via the per-profile
# MCM snapshot mechanic that _materialize_modpack_profile already drives.
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

	for f in reader.get_files():
		if f.ends_with("/"):
			continue
		if not _modpack_override_path_allowed(f):
			continue
		var bytes := reader.read_file(f)
		var user_path := "user://" + f
		var existed := FileAccess.file_exists(user_path)
		if existed:
			# Snapshot original to the backup slot's overrides/ tree.
			var bk_path := overrides_root.path_join(f)
			DirAccess.make_dir_recursive_absolute(bk_path.get_base_dir())
			var orig := FileAccess.open(user_path, FileAccess.READ)
			if orig != null:
				var orig_bytes := orig.get_buffer(orig.get_length())
				orig.close()
				var bk_f := FileAccess.open(bk_path, FileAccess.WRITE)
				if bk_f != null:
					bk_f.store_buffer(orig_bytes)
					bk_f.close()
			(manifest["replaced"] as Array).append(f)
		else:
			(manifest["added"] as Array).append(f)
		# Write modpack's version into user://path.
		DirAccess.make_dir_recursive_absolute(user_path.get_base_dir())
		var dst := FileAccess.open(user_path, FileAccess.WRITE)
		if dst != null:
			dst.store_buffer(bytes)
			dst.close()
			applied += 1

	reader.close()

	# Persist the manifest. Unload reads this to know what to revert.
	DirAccess.make_dir_recursive_absolute(backup_root)
	var manifest_path := backup_root.path_join("overrides_manifest.json")
	var mf := FileAccess.open(manifest_path, FileAccess.WRITE)
	if mf != null:
		mf.store_string(JSON.stringify(manifest, "  "))
		mf.close()

	return applied

# Reverse what _apply_modpack_overrides did, using the manifest in the
# backup slot. "replaced" entries are restored from the snapshot copy;
# "added" entries are deleted. Silently no-ops if the manifest doesn't
# exist (older modpacks or apply that wrote nothing).
func _restore_modpack_overrides(backup_profile: String) -> void:
	var backup_root := MCM_SNAPSHOT_BASE.path_join(backup_profile)
	var manifest_path := backup_root.path_join("overrides_manifest.json")
	if not FileAccess.file_exists(manifest_path):
		return
	var mf := FileAccess.open(manifest_path, FileAccess.READ)
	if mf == null:
		return
	var content := mf.get_as_text()
	mf.close()
	var parsed_v: Variant = JSON.parse_string(content)
	if not (parsed_v is Dictionary):
		return
	var manifest: Dictionary = parsed_v

	var overrides_root := backup_root.path_join("overrides")

	# Restore replaced files first so any ordering issues (added file under
	# a path that should be a directory containing replaced files) don't
	# fight us. In practice paths are flat enough that ordering doesn't
	# matter, but conservative is cheap here.
	var replaced: Array = manifest.get("replaced", []) if manifest.get("replaced") is Array else []
	for path_v in replaced:
		var rel: String = str(path_v)
		var bk_path := overrides_root.path_join(rel)
		var user_path := "user://" + rel
		if not FileAccess.file_exists(bk_path):
			continue
		var src := FileAccess.open(bk_path, FileAccess.READ)
		if src == null:
			continue
		var bytes := src.get_buffer(src.get_length())
		src.close()
		DirAccess.make_dir_recursive_absolute(user_path.get_base_dir())
		var dst := FileAccess.open(user_path, FileAccess.WRITE)
		if dst != null:
			dst.store_buffer(bytes)
			dst.close()

	# Delete added files.
	var added: Array = manifest.get("added", []) if manifest.get("added") is Array else []
	for path_v in added:
		var rel: String = str(path_v)
		var user_path := "user://" + rel
		if FileAccess.file_exists(user_path):
			DirAccess.remove_absolute(user_path)


# Find mods declared in the modpack's `sources` field that aren't currently
# installed locally at the EXACT pinned version. Earlier revision did
# id-prefix fallback (foo@1.2.3 in modpack treated as satisfied by foo@1.5.0
# locally), but that defeats version pinning -- the modpack author picked
# 1.2.3 specifically. Now: only an exact profile_key match counts as already
# installed. A different version of the same mod is treated as missing, so
# we attempt to download the pinned version. Returns Array of
# {profile_key, mws_id, version}.
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

	# Build set of installed profile_keys for exact-match lookup. Also
	# track (lowercase mod_id, version) -> true for a fallback fuzzy match
	# below; modpack-saved keys and runtime-computed installed keys can
	# disagree on casing or id-format (e.g. "FixedDoors@1.1.0" saved vs
	# "fixed_doors@1.1.0" from mod.txt). The fuzzy match uses the raw
	# mod_id field instead of the composite profile_key.
	var installed_keys: Dictionary = {}
	var installed_id_ver: Dictionary = {}
	for installed_entry in _ui_mod_entries:
		var pk: String = str(installed_entry.get("profile_key", ""))
		if pk != "":
			installed_keys[pk] = true
		var inst_id_l: String = str(installed_entry.get("mod_id", "")).to_lower()
		var inst_ver: String = str(installed_entry.get("version", ""))
		if inst_id_l != "":
			installed_id_ver[inst_id_l + "@" + inst_ver] = true

	# Walk every profile_key the modpack expects (union of enabled + sources),
	# so a mod listed in `enabled` but missing from `sources` doesn't get
	# silently skipped at apply time -- the user sees a clear "no source
	# info" failure instead of a mystery missing-from-profile entry.
	var seen: Dictionary = {}
	var ordered_keys: Array = []
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
		# Exact match -- user already has this mod at this version.
		if installed_keys.has(src_key):
			continue
		# Fallback: case-insensitive (mod_id, version) match. Catches the
		# "modpack saved 'FixedDoors@1.1.0' but the installed copy's
		# mod.txt declared id='fixed_doors'" mismatch -- exact key check
		# fails, but the underlying mod IS installed at the right version.
		var at_pos := src_key.find("@")
		if at_pos > 0:
			var src_id_l := src_key.substr(0, at_pos).to_lower()
			var src_ver := src_key.substr(at_pos + 1)
			if installed_id_ver.has(src_id_l + "@" + src_ver):
				continue
		var src_data: Dictionary = sources.get(src_key, {}) if sources.get(src_key) is Dictionary else {}
		var mws_id := int(src_data.get("modworkshop_id", 0))
		# Version is OPTIONAL and only used when explicit. Earlier revision
		# fell back to parsing the suffix off the profile_key, but that
		# silently turned legacy modpacks (which only have modworkshop_id
		# and no version field) into strict-pinned downloads against old
		# versions that have since been replaced upstream -- mass failures.
		# Now: only honor the version when the modpack author chose to
		# include it (modloader-produced modpacks do; legacy ones don't).
		var version := str(src_data.get("version", ""))
		# Cache the source so a missing-mod stub on this profile (or a
		# future profile referencing the same key) can offer Download
		# without re-reading the modpack zip.
		_persist_single_mod_source(src_key, mws_id, version)
		var item := {"profile_key": src_key, "mws_id": mws_id, "version": version}
		if mws_id <= 0:
			# No downloadable source. Surface it to apply_modpack so the
			# user sees an explanatory failure row instead of a missing
			# mod with no explanation.
			item["unreachable"] = true
			item["unreachable_reason"] = ("no source info for this mod in the modpack" if src_data.is_empty()
					else "no modworkshop_id in this mod's source entry")
		missing.append(item)
	return missing


# Apply a discovered modpack. Snapshots current state to a backup slot,
# downloads any missing mods declared in `sources`, materializes the
# modpack into a profile (creates from zip on first apply, resumes on
# subsequent applies preserving user edits), switches to it, and marks
# active. progress is an optional Callable(text: String) invoked at each
# step so the UI can show what's happening during downloads. Returns
# {ok, error, downloaded, failed_downloads}.
func apply_modpack(entry: Dictionary, tabs: TabContainer, progress: Callable = Callable()) -> Dictionary:
	# Concurrency guard. apply_modpack awaits during downloads; without this
	# flag a second click on a different modpack's Apply button would race
	# on cfg writes + the backup slot.
	if _modpack_apply_in_progress:
		return {"ok": false, "error": "Another apply is in progress; wait for it to finish"}
	_modpack_apply_in_progress = true
	# Cancel flag is reset per-apply so prior cancels don't poison the next
	# attempt.
	_modpack_apply_cancelled = false

	var result := await _apply_modpack_inner(entry, tabs, progress)
	_modpack_apply_in_progress = false
	return result

# Inner apply flow. Split out so the outer wrapper can manage the
# in-progress flag in one place via a single await + assign.
func _apply_modpack_inner(entry: Dictionary, tabs: TabContainer, progress: Callable) -> Dictionary:
	# Validate the zip BEFORE doing any backup/state mutation. If the zip
	# is malformed we fail clean -- user's existing state is untouched.
	var validation := _validate_modpack(entry)
	if not bool(validation.get("ok", false)):
		return validation

	var sanitized: String = str(entry.get("sanitized_name", ""))
	if sanitized.is_empty():
		return {"ok": false, "error": "Invalid modpack name"}
	var modpack_profile := MODPACK_PROFILE_PREFIX + sanitized
	var backup_profile := MODPACK_BACKUP_PREFIX + sanitized

	# Refuse to apply a second modpack while another is active. The UI
	# layer should make this unreachable (Apply hidden when something else
	# is active), but defensive in case the flow gets confused.
	var current_active := get_active_modpack()
	if current_active != "" and current_active != sanitized:
		return {"ok": false, "error": "Unload " + current_active + " before applying another modpack"}

	# Re-apply path: user clicked Apply on the already-active modpack. Skip
	# backup (would clobber the original pre-modpack backup with current
	# modpack state -> unload would restore to modpack state instead of
	# pre-modpack), skip materialize (preserves user edits), skip switch
	# (pointless, also wipes MCM edits via _restore_mcm_from). Re-apply is
	# essentially "re-download missing mods" -- which already happened by
	# this point. Just rebuild Mods to reflect any newly-downloaded mods.
	var is_reapply := current_active == sanitized

	# Download missing mods BEFORE touching state, so a network failure
	# doesn't leave the user with a half-applied modpack. Failures here
	# are non-fatal -- mods that fail to download just remain as missing-
	# mod stubs in the Mods tab afterward, which is the same outcome as
	# applying without sources data at all. We collect per-mod failure
	# reasons so the user can see what went wrong (network vs filename
	# collision vs validation), instead of a bare "X failed" count.
	var missing := _get_missing_mods_for_modpack(entry)
	var failed_dl: int = 0
	var done_dl: int = 0
	var failures: Array = []
	if not missing.is_empty():
		_log_info("[Modpack] applying " + sanitized + ": " + str(missing.size()) + " mod(s) to install")
		var total := missing.size()
		for i in range(total):
			# Check the cancel flag BEFORE each download so an in-flight one
			# completes (no way to interrupt HTTPRequest mid-await cleanly
			# without refactoring download_new_mod) but no further ones
			# start. Returns a partial-success result the UI can surface.
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
			var mws_id: int = int(item.get("mws_id", 0))
			var version: String = str(item.get("version", ""))
			# Sourceless / mws_id<=0 entries can't be downloaded -- record as
			# failures directly so they show up in the apply summary instead
			# of being silently skipped.
			if bool(item.get("unreachable", false)):
				failed_dl += 1
				var u_reason: String = str(item.get("unreachable_reason", "no downloadable source"))
				failures.append({
					"profile_key": pk,
					"error": u_reason,
					"mws_id": mws_id,
					"version": version,
				})
				_log_warning("[Modpack]   skipped: " + pk + " -- " + u_reason)
				if progress.is_valid():
					progress.call({"current": i + 1, "total": total, "mod_name": pk, "action": "skipped"})
				continue
			if progress.is_valid():
				progress.call({"current": i + 1, "total": total, "mod_name": pk, "action": "downloading"})
			var version_tag := (" v" + version) if version != "" else " (primary)"
			_log_info("[Modpack] downloading " + pk + " (mws_id=" + str(mws_id) + version_tag + ")")
			# allow_rename_on_collision: modpack apply can land both the
			# user's existing file AND a different version side-by-side.
			# Dedup logic at scan time picks one; better than failing the
			# whole download because the filename happened to match.
			var r: Dictionary = await download_new_mod(mws_id, version, true)
			if bool(r.get("ok", false)):
				done_dl += 1
				_log_info("[Modpack]   ok: " + str(r.get("file_name", "?")))
			else:
				var err: String = str(r.get("error", "unknown"))
				# "Already have a file named X" means we tried to write a
				# new copy but the canonical AND renamed-variant filenames
				# are already occupied -- typically because a previous
				# apply attempt landed the file under one of those names.
				# Count as installed rather than failed: the user actually
				# has the mod, _get_missing_mods_for_modpack just couldn't
				# match it cleanly. Avoids spurious failure rows.
				if err.begins_with("Already have"):
					done_dl += 1
					_log_info("[Modpack]   already on disk: " + pk + " (" + err + ")")
					continue
				failed_dl += 1
				# Include mws_id + version so the failure UI can offer a
				# Retry that re-runs the same call, and an Open-MWS-page
				# button for off-site / deleted mods.
				failures.append({
					"profile_key": pk,
					"error": err,
					"mws_id": mws_id,
					"version": str(item.get("version", "")),
				})
				_log_warning("[Modpack]   failed: " + pk + " -- " + err)
		# Re-scan _ui_mod_entries so the just-downloaded mods are part of
		# the list when we materialize and switch into the modpack profile.
		_ui_mod_entries = collect_mod_metadata()
		var cfg_apply := ConfigFile.new()
		cfg_apply.load(UI_CONFIG_PATH)
		_apply_profile_to_entries(cfg_apply, _active_profile)
		if progress.is_valid():
			progress.call({"current": missing.size(), "total": missing.size(), "mod_name": "", "action": "applying"})

	if not is_reapply:
		# 1. Backup current profile sections to the backup slot. profile_keys
		# are stable across renames so a future "rename profile" wouldn't break
		# unload, but we capture the current name explicitly for restore_to.
		var pre_active := _active_profile
		var cfg := ConfigFile.new()
		cfg.load(UI_CONFIG_PATH)

		var src_en := "profile." + pre_active + ".enabled"
		var src_pr := "profile." + pre_active + ".priority"
		var bk_en := "profile." + backup_profile + ".enabled"
		var bk_pr := "profile." + backup_profile + ".priority"

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
		_persist_ui_cfg(cfg)

		# Snapshot pre-modpack MCM into the backup slot. Vanilla has no MCM
		# state worth preserving (no mods active to consume MCM).
		if pre_active != VANILLA_PROFILE:
			_snapshot_mcm_to(backup_profile)

		# 2. If modpack profile doesn't exist, materialize it from the zip.
		# If it does exist, leave alone -- user's prior edits are preserved.
		cfg.load(UI_CONFIG_PATH)
		if not cfg.has_section("profile." + modpack_profile + ".enabled"):
			var mat_result := _materialize_modpack_profile(entry, modpack_profile)
			if not bool(mat_result.get("ok", false)):
				return mat_result

		# 3. Apply override files (anything in the zip outside profile.json
		# and MCM/). Snapshots originals into the backup slot via a
		# manifest so unload can revert. MCM/ is handled separately via
		# the per-profile MCM snapshot mechanic.
		_apply_modpack_overrides(entry, backup_profile)

		# 4. Switch to modpack profile (existing function handles MCM swap)
		_switch_profile(modpack_profile)

		# 5. Mark active in cfg (after switch, since _switch_profile rewrites
		# active_profile in cfg too).
		cfg.load(UI_CONFIG_PATH)
		cfg.set_value("settings", "active_modpack", sanitized)
		_persist_ui_cfg(cfg)

	# 5. Refresh the Mods tab so the modpack's selection + banner show
	# (or, in the re-apply path, so any newly-downloaded mods appear).
	if tabs != null and is_instance_valid(tabs):
		_rebuild_mods_tab(tabs)

	return {
		"ok": true,
		"error": "",
		"downloaded": done_dl,
		"failed_downloads": failed_dl,
		"failures": failures,
	}

# Read modpack zip into a profile slot. Writes enabled/priority sections
# to mod_config.cfg and the MCM/ tree to user://.profile_snapshots/<slot>/MCM/.
# Used by apply when the slot doesn't exist yet (first apply, or after a
# manual reset). Returns {ok, error}.
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
	cfg.load(UI_CONFIG_PATH)
	var en_sec := "profile." + profile_name + ".enabled"
	var pr_sec := "profile." + profile_name + ".priority"
	if cfg.has_section(en_sec):
		cfg.erase_section(en_sec)
	if cfg.has_section(pr_sec):
		cfg.erase_section(pr_sec)

	var enabled_dict: Dictionary = pd.get("enabled", {}) if pd.get("enabled") is Dictionary else {}
	for k in enabled_dict.keys():
		cfg.set_value(en_sec, str(k), bool(enabled_dict[k]))
	var priority_dict: Dictionary = pd.get("priority", {}) if pd.get("priority") is Dictionary else {}
	for k in priority_dict.keys():
		var pv := int(priority_dict[k])
		cfg.set_value(pr_sec, str(k), clampi(pv, PRIORITY_MIN, PRIORITY_MAX))
	_persist_ui_cfg(cfg)

	# Extract MCM tree into the profile's snapshot slot. _switch_profile
	# will then restore from this slot when we switch into the profile.
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

# Unload the active modpack. Restores backup state and clears active flag.
# The modpack profile slot is preserved with any user edits intact, so
# re-applying picks up where they left off.
func unload_modpack(tabs: TabContainer) -> Dictionary:
	var cfg := ConfigFile.new()
	cfg.load(UI_CONFIG_PATH)
	var active := str(cfg.get_value("settings", "active_modpack", ""))
	if active == "":
		return {"ok": false, "error": "No modpack is active"}

	var backup_profile := MODPACK_BACKUP_PREFIX + active
	var pre_active := str(cfg.get_value("settings", "modpack_backup_profile", "Default"))

	# 1. Restore backup sections into the pre-active profile slot.
	var bk_en := "profile." + backup_profile + ".enabled"
	var bk_pr := "profile." + backup_profile + ".priority"
	var dst_en := "profile." + pre_active + ".enabled"
	var dst_pr := "profile." + pre_active + ".priority"

	# Backup gone entirely (corrupt state, hand-edited cfg)? Then there is
	# nothing to restore FROM -- erasing the destination first would wipe the
	# user's pre-apply profile and replace it with nothing. Abort and leave
	# every profile untouched; the orange state stays visible instead of
	# silently destroying data.
	if not cfg.has_section(bk_en) and not cfg.has_section(bk_pr):
		return {"ok": false,
				"error": "Backup state for this modpack is missing -- unload aborted, profiles untouched. Delete settings.active_modpack in mod_config.cfg to clear the flag manually."}

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
	cfg.set_value("settings", "active_modpack", "")
	_persist_ui_cfg(cfg)

	# 3. Restore non-MCM override files (Preferences.tres etc) from the
	# backup slot's manifest. This must happen BEFORE _switch_profile
	# touches user://MCM/, so MCM and other overrides are restored in
	# the correct order. Files under MCM/ aren't in this manifest --
	# they're handled by the MCM-snapshot path below.
	_restore_modpack_overrides(backup_profile)

	# 4. Switch to pre-active profile. _switch_profile snapshots the
	# (now-modpack) MCM and restores the pre-active's MCM if it has a
	# snapshot. Vanilla incoming leaves user://MCM/ alone, which is the
	# right behavior -- the next step overwrites it from the backup
	# snapshot we took at apply time.
	_switch_profile(pre_active)

	# 5. Restore the pre-modpack MCM from backup snapshot. This overrides
	# whatever _switch_profile did with MCM, which is what we want -- the
	# backup IS the authoritative pre-modpack MCM.
	if _has_mcm_snapshot(backup_profile):
		_restore_mcm_from(backup_profile)

	# 6. Wipe the backup slot wholesale -- MCM, overrides, manifest, all
	# of it. _delete_mcm_snapshot only handles MCM/; the slot now also
	# carries overrides/ and overrides_manifest.json which we wrote at
	# apply time, so a recursive wipe of the entire profile slot is the
	# correct cleanup.
	_remove_dir_recursive(MCM_SNAPSHOT_BASE.path_join(backup_profile))

	# 7. Refresh Mods tab (banner gone, profile dropdown back).
	if tabs != null and is_instance_valid(tabs):
		_rebuild_mods_tab(tabs)

	return {"ok": true, "error": ""}

# Re-attempt the failed downloads from a previous apply. The active modpack
# is unchanged; this just runs the download step again for items that
# failed the first time. After any new successes, re-runs collect to get
# the new mod files into _ui_mod_entries. Returns {downloaded, failures}
# where failures has the same shape as apply's (still-failed items only).
func retry_failed_downloads(failures: Array, progress: Callable = Callable()) -> Dictionary:
	var still_failed: Array = []
	var newly_downloaded: int = 0
	for i in range(failures.size()):
		var item = failures[i]
		if not (item is Dictionary):
			continue
		var pk: String = str(item.get("profile_key", "?"))
		var mws_id: int = int(item.get("mws_id", 0))
		var version: String = str(item.get("version", ""))
		if mws_id <= 0:
			still_failed.append(item)
			continue
		if progress.is_valid():
			progress.call({"current": i + 1, "total": failures.size(), "mod_name": pk, "action": "retrying"})
		_log_info("[Modpack][Retry] " + pk + " (mws_id=" + str(mws_id) + ")")
		var r: Dictionary = await download_new_mod(mws_id, version, true)
		if bool(r.get("ok", false)):
			newly_downloaded += 1
			_log_info("[Modpack][Retry]   ok: " + str(r.get("file_name", "?")))
		else:
			var err: String = str(r.get("error", "unknown"))
			still_failed.append({
				"profile_key": pk,
				"error": err,
				"mws_id": mws_id,
				"version": version,
			})
			_log_warning("[Modpack][Retry]   failed: " + pk + " -- " + err)
	if newly_downloaded > 0:
		_ui_mod_entries = collect_mod_metadata()
		var cfg := ConfigFile.new()
		cfg.load(UI_CONFIG_PATH)
		_apply_profile_to_entries(cfg, _active_profile)
	return {"downloaded": newly_downloaded, "failures": still_failed}


# Save the named profile as a modpack zip in <game>/mods/. Used by the
# "Save as modpack" entry on the profile dropdown. Filename is the
# sanitized profile name; refuses to overwrite an existing zip.
func save_profile_as_modpack(profile_name: String, description: String = "", author: String = "") -> Dictionary:
	if _mods_dir.is_empty():
		_mods_dir = OS.get_executable_path().get_base_dir().path_join(MOD_DIR)
	var safe := _sanitize_profile_name(profile_name)
	if safe.is_empty():
		return {"ok": false, "error": "Invalid profile name"}
	var output := _mods_dir.path_join(safe + ".zip")
	if FileAccess.file_exists(output):
		return {"ok": false, "error": "A file named " + safe + ".zip already exists in /mods/"}
	return _export_profile_to_zip(profile_name, output, description, author)
