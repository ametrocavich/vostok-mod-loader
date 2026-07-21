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
##
## State machine. Transitions are owned by: apply_modpack/_apply_modpack_inner
## (no-pack -> active), unload_modpack (active -> no-pack), the boot reconciler
## in ui.gd _load_ui_config (stranded -> no-pack), and _restore_apply_snapshot
## (no-pack -> no-pack revert via the Restore backup button; the UI refuses it
## while a pack is active).
##
##   NO-PACK      [settings] active_modpack is "" and active_profile is a user
##                profile. Nominally no _before_modpack_ cfg sections exist,
##                but a crash-window recovery (see stranded states below)
##                clears the flag without erasing them; the next apply's
##                step 1 erase cleans stale ones up.
##   DOWNLOADING  apply_modpack is awaiting missing-mod downloads. No profile,
##                backup, override, or MCM state has been touched yet -- a
##                crash or Cancel here only leaves downloaded zips in /mods/
##                and cached [mod_sources] entries (both harmless). Concurrent
##                applies are serialized by _modpack_apply_in_progress; Cancel
##                sets _modpack_apply_cancelled (checked before each download
##                and once more after the loop).
##   MUTATING     _apply_modpack_inner's numbered steps, fresh apply only
##                (re-apply of the already-active pack skips them all):
##                  0. _snapshot_state_before_apply -- independent restore
##                     point; its failure never blocks the apply.
##                  1. copy the active profile's .enabled/.priority into the
##                     _before_modpack_ slot, set modpack_backup_profile, set
##                     active_modpack EARLY (the crash trigger the reconciler
##                     keys off), persist cfg, then snapshot the pre-pack MCM
##                     into the backup slot (skipped coming from vanilla).
##                  2. materialize the modpack__ profile from the zip if the
##                     slot doesn't exist (enabled/priority/dep_ignore + MCM).
##                  3. _apply_modpack_overrides -- copy zip files over user://,
##                     snapshotting originals + an added/replaced manifest
##                     into the backup slot.
##                  4. _switch_profile into the modpack__ slot (rewrites
##                     active_profile in cfg, swaps MCM).
##                  5. re-assert active_modpack (the switch rewrote cfg).
##                A hard failure after step 1 (e.g. a materialize error)
##                returns with the flag still set; the next boot's reconciler
##                clears it.
##   ACTIVE       active_modpack=<name>, active_profile=modpack__<name>,
##                backup slot sections + overrides manifest on disk. Re-apply
##                in this state is downloads-only (never touches backups,
##                restore points, profile slots, or MCM).
##   UNLOADING    unload_modpack: aborts with profiles untouched when BOTH
##                backup sections are missing (corruption guard); otherwise
##                1. restore backup sections into the pre-apply profile slot,
##                2. erase backup sections, clear both [settings] flags,
##                persist, 3. restore override files from the manifest,
##                4. _switch_profile back to the pre-apply profile,
##                5. restore the pre-pack MCM from the backup slot
##                (authoritative over whatever step 4 restored), 6. wipe the
##                backup slot dir wholesale.
##
## Stranded states (crash/quit inside MUTATING or UNLOADING) are recovered at
## the next boot by ui.gd _load_ui_config:
##   - active_profile is a managed slot but active_modpack doesn't name it
##     (quit between unload steps 2 and 4, or a profile delete resolved into
##     a managed slot): when the slot is a modpack__ one, restore override
##     files and roll live MCM back from the slot-derived backup; then recover
##     active_profile to the first user profile and clear the flag.
##   - active_modpack is set but active_profile isn't that pack's slot (crash
##     between apply steps 1 and 4): best-effort override restore via the
##     manifest -- a no-op if the crash predates step 3 writing it, the window
##     the manual Restore button covers -- then clear the flag.
##
## Invariants:
##   - Downloads strictly precede state mutation; the mutation phase does no
##     network I/O.
##   - The independent restore point (user://.modpack_backups/, one per fresh
##     apply) is only ever taken while NO pack is active, and the apply/
##     unload/reconcile machinery never consumes it -- only pruning to the
##     MODPACK_SNAPSHOT_KEEP newest deletes one.
##   - The _before_modpack_ backup slot is created at apply step 1 and torn
##     down by unload (cfg sections at step 2, the on-disk dir at step 6).
##     Reconciler recovery restores FROM the slot but never deletes it, so
##     stale sections or dirs can linger after a crash-window recovery or an
##     interrupted unload; the next apply's step 1 erase and the next
##     unload's step 6 wipe remove any leftovers.
##   - At most one pack is active; applying another requires unloading first.

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
	".modpack_backups/",       # pre-apply restore points -- packs must not poison them
	"mws_cache/",              # Browse-tab thumbnail / API cache
	"vmz_mount_cache/",        # archive mount tmpdir
	"modloader_",              # heartbeat, safe-mode, pass-state, etc.
]

# Profile names the modpack system manages internally. The Mods tab dropdown
# filters these out so the user only sees profiles they explicitly created.
func _is_modpack_managed_profile(profile_name: String) -> bool:
	return profile_name.begins_with(MODPACK_PROFILE_PREFIX) \
			or profile_name.begins_with(MODPACK_BACKUP_PREFIX)

# Count the truthy values in a dictionary -- used to tally how many mods a
# modpack's `enabled` map turns on.
func _count_truthy(d: Dictionary) -> int:
	var count := 0
	for k in d.keys():
		if bool(d[k]):
			count += 1
	return count

# --- profile.json (metroprofile v1) consumer map ------------------------------
# A modpack zip's profile.json carries the metroprofile v1 schema, produced by
# a single writer. Adding a field means auditing every site below; new fields
# must be optional with a safe default on read (old parsers ignore unknown
# keys, new parsers must tolerate absence) or the metroprofile version must be
# bumped. The v1 shape is locked -- see the note above _profile_to_json_string
# (ui.gd) and docs/wiki/Profile-Format.md.
#   WRITE:    _profile_to_json_string (ui.gd) -- sole producer; feeds
#             _export_profile_to_zip (modpack zips).
#   VALIDATE: _validate_modpack (below; modpack apply).
#   READ:     _build_modpack_entry (name/description/author/exported_at/
#             enabled -> Modpacks tab rows),
#             _get_missing_mods_for_modpack (enabled + sources -> download
#             list), _materialize_modpack_profile (enabled/priority/
#             dep_ignore -> profile slot; the state consumer),
#             _missing_mod_sources_combined (ui.gd; sources overlay for
#             missing-mod stubs), and _show_modpack_detail_dialog via
#             _read_modpack_profile_json (ui.gd; enabled + sources for the
#             counts and detail mod list).

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
		return {"ok": false, "error": "This file is not a valid modpack (no mod list inside). Get a fresh copy of the modpack and try again."}
	var bytes := reader.read_file("profile.json")
	reader.close()
	if bytes.is_empty():
		return {"ok": false, "error": "This modpack file is damaged (its mod list is empty). Get a fresh copy and try again."}
	var parsed_v: Variant = JSON.parse_string(bytes.get_string_from_utf8())
	if not (parsed_v is Dictionary):
		return {"ok": false, "error": "This modpack file is damaged (its mod list is unreadable). Get a fresh copy and try again."}
	var pd: Dictionary = parsed_v
	if int(pd.get("metroprofile", 0)) != 1:
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
	var enabled: Dictionary = pd.get("enabled", {}) if pd.get("enabled") is Dictionary else {}
	var enabled_count := _count_truthy(enabled)
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
	# Normalize before checking: zip entry names are attacker-controlled and
	# Windows resolves paths case-insensitively with either separator, so the
	# deny checks must run against a lowercased, forward-slash form. Callers
	# keep using the original rel for the actual write path.
	var norm := rel.replace("\\", "/").to_lower()
	if norm.is_empty():
		return false
	if norm.contains(".."):
		return false
	# Blocks Windows drive-letter and NTFS alternate-data-stream tricks;
	# legitimate zip entries never contain ":".
	if norm.contains(":"):
		return false
	if norm.begins_with("/"):
		return false
	# MCM/ is handled by the per-profile MCM snapshot mechanic, not the
	# generic overrides flow -- exclude it here.
	if norm.begins_with("mcm/"):
		return false
	# profile.json is the schema, not an override.
	if norm == "profile.json":
		return false
	for prefix in MODPACK_OVERRIDE_DENY_PREFIXES:
		if norm.begins_with(prefix):
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
func _restore_modpack_overrides(backup_profile: String) -> bool:
	var backup_root := MCM_SNAPSHOT_BASE.path_join(backup_profile)
	var manifest_path := backup_root.path_join("overrides_manifest.json")
	if not FileAccess.file_exists(manifest_path):
		# Nothing was overridden, nothing to lose.
		return true
	var mf := FileAccess.open(manifest_path, FileAccess.READ)
	if mf == null:
		# Originals may exist in overrides/ but cannot be located -- the
		# slot must survive.
		return false
	var content := mf.get_as_text()
	mf.close()
	var parsed_v: Variant = JSON.parse_string(content)
	if not (parsed_v is Dictionary):
		return false
	var manifest: Dictionary = parsed_v

	var overrides_root := backup_root.path_join("overrides")

	# Restore replaced files first so any ordering issues (added file under
	# a path that should be a directory containing replaced files) don't
	# fight us. In practice paths are flat enough that ordering doesn't
	# matter, but conservative is cheap here.
	var all_ok := true
	var replaced: Array = manifest.get("replaced", []) if manifest.get("replaced") is Array else []
	for path_v in replaced:
		var rel: String = str(path_v)
		var bk_path := overrides_root.path_join(rel)
		var user_path := "user://" + rel
		if not FileAccess.file_exists(bk_path):
			# The apply-time snapshot never captured it, so nothing is
			# recoverable.
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
			# A partial write (disk full / AV lock) must count as failure too,
			# or unload wipes the backup slot with the original half-restored.
			if not dst.store_buffer(bytes):
				all_ok = false
			dst.close()
		else:
			all_ok = false

	# Delete added files.
	var added: Array = manifest.get("added", []) if manifest.get("added") is Array else []
	for path_v in added:
		var rel: String = str(path_v)
		var user_path := "user://" + rel
		if FileAccess.file_exists(user_path):
			DirAccess.remove_absolute(user_path)

	return all_ok

# --- Independent pre-apply restore points ------------------------------------
# The per-slot _before_modpack_ backup above exists for Unload, but its restore
# is driven by the apply/unload state machine, so a crash in the wrong window
# can leave it unconsumed. The functions below take a SECOND, write-once,
# timestamped snapshot right before apply that the state machine never touches
# -- the user-facing safety net (Restore button in the Modpacks tab). Mod
# archives (large, re-downloadable) and game saves (untouched by apply) are
# deliberately excluded, so a snapshot is small (config + MCM + override files).

# Capture mod_config.cfg + live user://MCM/ + the files this pack will overwrite
# into user://.modpack_backups/<pack>_<timestamp>/. Best-effort: failures are
# logged as loud warnings but never block the apply, and a snapshot that
# captured nothing (despite mod_config.cfg existing to capture) is deleted
# rather than left masquerading as a restore point in the Restore picker.
# Returns the snapshot dir (or "" if nothing could be written).
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

	# 2. Live mod-config-menu settings tree. Record whether user://MCM/ existed
	# at all: when it did not, the snapshot legitimately has no MCM dir, and
	# restore must WIPE the pack's MCM rather than skip (mcm_absent marker in
	# snapshot.json, read by _restore_apply_snapshot step 2).
	var mcm_existed := DirAccess.dir_exists_absolute(MCM_SOURCE_DIR)
	if _copy_dir_recursive(MCM_SOURCE_DIR, snap_root.path_join("MCM")):
		captured += 1

	# 3. The files the pack is about to overwrite (saved so restore can revert
	# them) and the files it will ADD (recorded so restore can delete them for a
	# true revert -- mirrors the unload manifest's added/replaced split).
	var added: Array = []
	var file_path: String = str(entry.get("file_path", ""))
	if not file_path.is_empty():
		var reader := ZIPReader.new()
		if reader.open(file_path) == OK:
			var ov_root := snap_root.path_join("overrides")
			for f in reader.get_files():
				if f.ends_with("/"):
					continue
				if not _modpack_override_path_allowed(f):
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

	# Marker so the restore UI can label the snapshot, and so restore can delete
	# the files the pack added.
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

	# If literally nothing was captured (disk full, IO errors), don't leave an
	# empty dir masquerading as a restore point in the Restore picker.
	if captured == 0 and FileAccess.file_exists(UI_CONFIG_PATH):
		_log_warning("[Modpack] restore point captured NOTHING -- removing " + snap_root
				+ "; apply will proceed WITHOUT a restore point")
		_remove_dir_recursive(snap_root)
		return ""

	# A snapshot without mod_config.cfg cannot restore profiles, and
	# _restore_apply_snapshot refuses it outright. Delete it rather than
	# leaving a picker entry that can only fail.
	if cfg_copy_failed:
		_log_warning("[Modpack] restore point is missing mod_config.cfg -- removing " + snap_root
				+ "; apply will proceed WITHOUT a restore point")
		_remove_dir_recursive(snap_root)
		return ""

	_log_info("[Modpack] pre-apply restore point saved: " + snap_root + " (" + str(captured) + " item(s))")
	_prune_apply_snapshots()
	return snap_root

# List saved pre-apply restore points, newest first. Each entry:
# {name, path, pack, created, sort_key} (sort_key is the internal
# newest-first ordering key; see the comment inside).
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
	# Sort by timestamp, newest first. A folder-name sort would group by pack
	# name first (the name is the leading token), which could let prune delete
	# a genuinely newer snapshot of an alphabetically-early pack. Each entry
	# gets ONE key: 'created' (normalized to the dash form) when present, else
	# the trailing stamp of the folder name -- a per-entry key keeps the
	# comparator total even when some snapshots lost their snapshot.json.
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

# Read a restore point's snapshot.json. Returns {} when the file is missing,
# unreadable, or not a JSON object, so callers can .get() with defaults.
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

# Restore-only recursive copy that INCLUDES dot-prefixed entries. The override
# capture in _snapshot_state_before_apply step 3 records files per-path with
# no dot filter, so the replay must not filter either -- the shared
# _copy_dir_recursive skips every ".xyz" entry and would silently never write
# back a captured original like ".rtvcfg" or "cfg/.settings". Do NOT reuse
# this for profile/MCM swaps: those rely on _copy_dir_recursive skipping dot
# dirs (".profile_snapshots" etc).
func _copy_snapshot_tree_incl_hidden(src: String, dst: String) -> void:
	if not DirAccess.dir_exists_absolute(src):
		return
	DirAccess.make_dir_recursive_absolute(dst)
	var dir := DirAccess.open(src)
	if dir == null:
		return
	# On Linux/macOS dot-prefixed entries count as hidden and are omitted from
	# the listing by default; on Windows they are listed regardless.
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

# Restore a pre-apply snapshot: copy mod_config.cfg, MCM, and saved override
# files back over the live user:// state -- a full revert to how things were
# before that apply. Keeps a .bak of the current cfg first so a botched restore
# is itself recoverable. Caller re-reads state + rebuilds the UI afterward.
# Returns {ok, error}.
func _restore_apply_snapshot(snap_path: String) -> Dictionary:
	if not DirAccess.dir_exists_absolute(snap_path):
		return {"ok": false, "error": "Snapshot folder no longer exists"}

	# 1. mod_config.cfg (profiles + settings, incl. active_modpack/backup flags).
	# Every valid restore point carries mod_config.cfg (the launcher saves it
	# before any apply can run). If it is absent the capture failed at apply
	# time; restoring the rest would revert MCM/files while leaving profiles
	# untouched -- a mixed state reported as a clean revert. Refuse up front,
	# before anything is mutated.
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
		# user://MCM/ did not exist when this restore point was saved (so the
		# snapshot has no MCM dir on purpose). Whatever lives there now was put
		# there by the applied pack -- wipe it for a true revert. Snapshots
		# from older versions lack the marker and keep the old skip behavior.
		_remove_dir_recursive(MCM_SOURCE_DIR)

	# 3. Override files saved at snapshot time, back to their user:// paths.
	# Replayed with the dot-inclusive walker: capture recorded these per-path
	# without a dot filter, so restore must not drop dot-prefixed entries.
	var ov_root := snap_path.path_join("overrides")
	if DirAccess.dir_exists_absolute(ov_root):
		_copy_snapshot_tree_incl_hidden(ov_root, "user://")

	# 4. Delete files the pack ADDED (recorded in snapshot.json), so the revert
	# matches pre-apply state instead of leaving the pack's new files behind.
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
			item["unreachable_reason"] = ("the modpack has no download info for this mod -- install it manually" if src_data.is_empty()
					else "the modpack has no ModWorkshop ID for this mod -- install it manually")
		missing.append(item)
	return missing


# Apply a discovered modpack. Snapshots current state to a backup slot,
# downloads any missing mods declared in `sources`, materializes the
# modpack into a profile (creates from zip on first apply, resumes on
# subsequent applies preserving user edits), switches to it, and marks
# active. progress is an optional Callable(info: Dictionary) invoked per
# step with {current: int, total: int, mod_name: String, action: String}
# where action is one of "downloading" | "skipped" | "applying" (mod_name
# is "" for "applying"), so the UI can show download progress. Returns
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

	# Re-check the cancel flag AFTER the download loop: a cancel clicked during
	# the FINAL (or only) download is otherwise never seen -- the loop-top check
	# has no next iteration -- and the pack would fully apply while the UI says
	# "Cancelling...". Downloads that already landed stay on disk (same contract
	# as the loop-top cancel); no state below has been mutated yet.
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
		# Independent, write-once restore point BEFORE any state mutation. This
		# is the user-facing safety net (Restore button in the Modpacks tab);
		# it survives any crash in the apply state machine below.
		_snapshot_state_before_apply(entry)
		# 1. Backup current profile sections to the backup slot. profile_keys
		# are stable across renames so a future "rename profile" wouldn't break
		# unload, but we capture the current name explicitly for restore_to.
		var pre_active := _active_profile
		var cfg := ConfigFile.new()
		cfg.load(UI_CONFIG_PATH)

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
		# Write the active_modpack flag NOW, before applying overrides or
		# switching profiles, so it acts as the revert trigger if we crash
		# mid-apply: the boot reconciler keys off this flag to restore stranded
		# override files. Re-asserted at step 5 (after the step-4 _switch_profile)
		# in case the switch rewrites cfg.
		cfg.set_value("settings", "active_modpack", sanitized)
		_persist_ui_cfg(cfg)

		# Snapshot pre-modpack MCM into the backup slot. Vanilla has no MCM
		# state worth preserving (no mods active to consume MCM).
		if pre_active != VANILLA_PROFILE:
			_snapshot_mcm_to(backup_profile)

		# 2. If modpack profile doesn't exist, materialize it from the zip.
		# If it does exist, leave alone -- user's prior edits are preserved.
		cfg.load(UI_CONFIG_PATH)
		if not cfg.has_section(_profile_sec(modpack_profile, ".enabled")):
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

	# 6. Refresh the Mods tab so the modpack's selection + banner show
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
	var en_sec := _profile_sec(profile_name, ".enabled")
	var pr_sec := _profile_sec(profile_name, ".priority")
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
	# dep_ignore ("Load anyway") overrides travel with the pack (the export
	# writes them into profile.json); materialize them like the profile-import
	# path does, sparse true-only, so the applied pack loads the same mods the
	# author's install did.
	var ig_sec := _profile_sec(profile_name, ".dep_ignore")
	if cfg.has_section(ig_sec):
		cfg.erase_section(ig_sec)
	var dep_ignore_dict: Dictionary = pd.get("dep_ignore", {}) if pd.get("dep_ignore") is Dictionary else {}
	for k in dep_ignore_dict.keys():
		if bool(dep_ignore_dict[k]):
			cfg.set_value(ig_sec, str(k), true)
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
	var bk_en := _profile_sec(backup_profile, ".enabled")
	var bk_pr := _profile_sec(backup_profile, ".priority")
	var dst_en := _profile_sec(pre_active, ".enabled")
	var dst_pr := _profile_sec(pre_active, ".priority")

	# Backup gone entirely (corrupt state, hand-edited cfg)? Then there is
	# nothing to restore FROM -- erasing the destination first would wipe the
	# user's pre-apply profile and replace it with nothing. Abort and leave
	# every profile untouched; the orange state stays visible instead of
	# silently destroying data.
	if not cfg.has_section(bk_en) and not cfg.has_section(bk_pr):
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
	cfg.set_value("settings", "active_modpack", "")
	_persist_ui_cfg(cfg)

	# 3. Restore non-MCM override files (Preferences.tres etc) from the
	# backup slot's manifest. Files under MCM/ are never in this manifest
	# (_modpack_override_path_allowed rejects them at apply time), so this
	# step has no ordering dependency on the MCM swap in steps 4-5; those
	# handle MCM via the per-profile snapshot mechanic.
	var overrides_ok := _restore_modpack_overrides(backup_profile)

	# 4. Switch to pre-active profile. _switch_profile snapshots the
	# (now-modpack) MCM and restores the pre-active's MCM if it has a
	# snapshot. Vanilla incoming leaves user://MCM/ alone, which is the
	# right behavior -- the next step overwrites it from the backup
	# snapshot we took at apply time.
	_switch_profile(pre_active)

	# 5. Restore the pre-modpack MCM from backup snapshot. This overrides
	# whatever _switch_profile did with MCM, which is what we want -- the
	# backup IS the authoritative pre-modpack MCM.
	var mcm_ok := true
	if _has_mcm_snapshot(backup_profile):
		mcm_ok = _restore_mcm_from(backup_profile)

	# 6. Wipe the backup slot wholesale -- MCM, overrides, manifest, all
	# of it. _delete_mcm_snapshot only handles MCM/; the slot now also
	# carries overrides/ and overrides_manifest.json which we wrote at
	# apply time, so a recursive wipe of the entire profile slot is the
	# correct cleanup. Only safe once both restores actually consumed the
	# slot's contents -- otherwise leave the slot in place.
	if overrides_ok and mcm_ok:
		_remove_dir_recursive(MCM_SNAPSHOT_BASE.path_join(backup_profile))
	else:
		_log_warning("[Modpack] unload: backup-slot restore incomplete (overrides_ok=" + str(overrides_ok) + ", mcm_ok=" + str(mcm_ok) + ") -- leaving " + MCM_SNAPSHOT_BASE.path_join(backup_profile) + " in place; it will be cleaned up by the next apply/unload")

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
func save_profile_as_modpack(profile_name: String, modpack_name: String = "", description: String = "", author: String = "") -> Dictionary:
	if _mods_dir.is_empty():
		_mods_dir = OS.get_executable_path().get_base_dir().path_join(MOD_DIR)
	# The pack's own name drives the zip filename + the profile.json "name". The
	# source profile only supplies the mod set. Empty name falls back to the
	# profile name (old behavior).
	var pack_name := modpack_name.strip_edges() if modpack_name.strip_edges() != "" else profile_name
	var safe := _sanitize_profile_name(pack_name)
	if safe.is_empty():
		return {"ok": false, "error": "Invalid modpack name"}
	var output := _mods_dir.path_join(safe + ".zip")
	if FileAccess.file_exists(output):
		return {"ok": false, "error": "A file named " + safe + ".zip already exists in your mods folder -- pick a different modpack name"}
	var res := _export_profile_to_zip(profile_name, output, description, author, pack_name)
	# Thread the saved file's path back so the UI can show the user exactly
	# where it landed and how to share it.
	if bool(res.get("ok", false)):
		res["path"] = output
		res["display_name"] = pack_name
	return res
