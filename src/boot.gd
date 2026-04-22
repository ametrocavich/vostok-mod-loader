## ----- boot.gd -----
## Static-init boot layer. Runs at script load time (before _ready) via
## _mount_previous_session. Owns the two-pass archive mount, override.cfg
## rewriting, pass state persistence, heartbeat + crash recovery, safe mode,
## and the hook-pack preload that preempts Godot's PCK-bytecode pinning for
## class_name scripts.

static func _is_modloader_disabled() -> bool:
	# Check for sentinel file in the game exe directory. When present, ModLoader
	# skips all work: no archives mount, no UI shows, no autoloads instantiate.
	# Use this as a nuclear escape hatch when modloader itself is broken or the
	# user wants guaranteed vanilla behavior without navigating the UI.
	var exe_dir := OS.get_executable_path().get_base_dir()
	return FileAccess.file_exists(exe_dir.path_join(DISABLED_FILE))

# Force all persistent state back to a vanilla baseline: clean override.cfg,
# delete pass state, wipe the hook pack directory. Safe to call when any of
# these artifacts are missing. Shared cleanup for the disabled sentinel,
# crashed-Pass-2 recovery, and (via instance wrapper) the UI reset button.
static func _static_force_vanilla_state(reason: String, log_lines: PackedStringArray) -> void:
	log_lines.append("[FileScope] RESET (" + reason + "): forcing vanilla state")
	_static_reset_override_cfg(log_lines)
	if FileAccess.file_exists(PASS_STATE_PATH):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(PASS_STATE_PATH))
		log_lines.append("[FileScope] RESET (" + reason + "): wiped pass state")
	if FileAccess.file_exists(PASS2_DIRTY_PATH):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(PASS2_DIRTY_PATH))
		log_lines.append("[FileScope] RESET (" + reason + "): cleared pass2 dirty marker")
	_static_wipe_hook_cache()
	log_lines.append("[FileScope] RESET (" + reason + "): wiped hook pack")

static func _mount_previous_session() -> Dictionary:
	var mounted: Dictionary = {}
	var log_lines: PackedStringArray = []
	log_lines.append("[FileScope] _mount_previous_session() starting")

	# Nuclear escape hatch: sentinel file in game dir skips everything and
	# resets persistent state so next launch is clean vanilla. This boot may
	# log errors about failed mod autoloads (override.cfg was read before we
	# got here), but the reset takes effect for the NEXT launch.
	if _is_modloader_disabled():
		_static_force_vanilla_state("modloader_disabled sentinel", log_lines)
		_write_filescope_log(log_lines)
		return mounted

	# Crashed Pass 2 recovery: if the dirty marker survived, the previous
	# Pass 2 was interrupted before cleanup (force-quit, crash, power loss).
	# Hook pack may be half-written; pass state + override.cfg reference a
	# state we can't trust. Full wipe forces Pass 1 to regenerate cleanly.
	if FileAccess.file_exists(PASS2_DIRTY_PATH):
		_static_force_vanilla_state("pass 2 crashed mid-run", log_lines)
		_write_filescope_log(log_lines)
		return mounted

	# Pinned probes narrowed (v3.0.1): previously a hardcoded list of 16
	# class_name scripts the game pre-compiles at boot. Now read from the
	# pass_state's hook_pack_wrapped_paths key -- only scripts this modlist
	# actually wrapped get CACHE_MODE_IGNORE preempt. Populated further
	# down after pass_state loads; the cache-snapshot diagnostic now logs
	# whatever the prior session wrapped.

	var cfg := ConfigFile.new()
	if cfg.load(PASS_STATE_PATH) != OK:
		log_lines.append("[FileScope] No pass state file -- skipping")
		_write_filescope_log(log_lines)
		return mounted
	# Wipe stale state from a different modloader version (format may have changed).
	# Also reset override.cfg -- prior version may have written [autoload_prepend]
	# entries for mods that are no longer enabled, causing Godot to fail loading
	# their scripts before modloader's _ready even runs.
	var saved_ver: String = cfg.get_value("state", "modloader_version", "")
	if saved_ver != MODLOADER_VERSION:
		log_lines.append("[FileScope] Version mismatch: saved=%s current=%s -- wiping" % [saved_ver, MODLOADER_VERSION])
		DirAccess.remove_absolute(ProjectSettings.globalize_path(PASS_STATE_PATH))
		_static_reset_override_cfg(log_lines)
		_write_filescope_log(log_lines)
		return mounted
	# Detect game updates -- exe mtime change means vanilla scripts may have changed.
	var saved_exe_mtime: int = cfg.get_value("state", "exe_mtime", 0)
	if saved_exe_mtime != 0:
		var current_exe_mtime := FileAccess.get_modified_time(OS.get_executable_path())
		if current_exe_mtime != saved_exe_mtime:
			log_lines.append("[FileScope] Game exe mtime changed -- wiping hook cache")
			# Game updated -- wipe hook cache so Pass 1 regenerates from fresh vanilla.
			_static_wipe_hook_cache()
			DirAccess.remove_absolute(ProjectSettings.globalize_path(PASS_STATE_PATH))
			_static_reset_override_cfg(log_lines)
			_write_filescope_log(log_lines)
			return mounted
	var paths: PackedStringArray = cfg.get_value("state", "archive_paths", PackedStringArray())
	if paths.is_empty():
		log_lines.append("[FileScope] Pass state has no archive paths -- skipping")
		_write_filescope_log(log_lines)
		return mounted

	log_lines.append("[FileScope] %d archive path(s) in pass state" % paths.size())

	# Were any archives deleted since last session?
	var any_missing := false
	var any_stale := false
	for path in paths:
		var abs_path := path if not path.begins_with("res://") and not path.begins_with("user://") \
				else ProjectSettings.globalize_path(path)
		if FileAccess.file_exists(abs_path):
			log_lines.append("[FileScope]   EXISTS: " + abs_path)
			continue
		# VMZ source gone -- check if the zip cache survived.
		if abs_path.get_extension().to_lower() == "vmz":
			var cache_dir := ProjectSettings.globalize_path(TMP_DIR)
			var cached := cache_dir.path_join(abs_path.get_file().get_basename() + ".zip")
			if FileAccess.file_exists(cached):
				log_lines.append("[FileScope]   STALE (vmz gone, cache ok): " + abs_path)
				any_stale = true
				continue
		log_lines.append("[FileScope]   MISSING: " + abs_path)
		any_missing = true

	if any_missing:
		log_lines.append("[FileScope] Archive(s) missing -- resetting to clean state")
		# Archive gone, no cache. Wipe override.cfg autoload sections so the next
		# boot is clean, but preserve any non-autoload settings ([display], etc.).
		var exe_dir := OS.get_executable_path().get_base_dir()
		var cfg_path := exe_dir.path_join("override.cfg")
		var preserved := _read_preserved_cfg_sections(cfg_path)
		var f := FileAccess.open(cfg_path, FileAccess.WRITE)
		if f:
			f.store_string("[autoload_prepend]\nModLoader=\"*" + MODLOADER_RES_PATH + "\"\n\n[autoload]\n\n" + preserved)
			f.close()
		var state_path := ProjectSettings.globalize_path(PASS_STATE_PATH)
		if FileAccess.file_exists(state_path):
			DirAccess.remove_absolute(state_path)
		_write_filescope_log(log_lines)
		return mounted

	if any_stale:
		# Source gone but cache works -- invalidate hash so Pass 1 rewrites state.
		cfg.set_value("state", "mods_hash", "")
		cfg.save(PASS_STATE_PATH)

	for path in paths:
		if ProjectSettings.load_resource_pack(path):
			var remaps := _static_resolve_remaps(path)
			log_lines.append("[FileScope]   MOUNTED: " + path
					+ (" (%d remaps)" % remaps if remaps > 0 else ""))
			mounted[path] = true
		elif path.get_extension().to_lower() == "vmz":
			var zip_path := _static_vmz_to_zip(path)
			if not zip_path.is_empty() and ProjectSettings.load_resource_pack(zip_path):
				var remaps := _static_resolve_remaps(zip_path)
				log_lines.append("[FileScope]   MOUNTED (vmz->zip): " + path
						+ (" (%d remaps)" % remaps if remaps > 0 else ""))
				mounted[path] = true
			else:
				log_lines.append("[FileScope]   MOUNT FAILED (vmz): " + path + " zip_path=" + zip_path)
		else:
			log_lines.append("[FileScope]   MOUNT FAILED: " + path)

	# Step D: mount the hook pack (Scripts/<Name>.gd + .gd.remap + empty
	# .gdc for each rewritten vanilla) at static init -- BEFORE any game
	# autoload compiles a class_name script. This is the only way to
	# rewire scripts Godot pre-compiles during class_cache population
	# (Camera, WeaponRig in the current mod set); source_code+reload and
	# CACHE_MODE_IGNORE+take_over_path both fail after class_cache pins
	# a compiled reference. Must mount AFTER mod archives so our
	# Scripts/*.gd entries win via replace_files=true.
	#
	# First-ever session: no pass_state entry, skip. Pass 1 will generate
	# and activate this session -- Camera/WeaponRig fall back to PCK
	# bytecode that first run. Second session onward: pre-mount works.
	# No fallback by filename: per-session filenames mean a lost pass_state
	# entry leaves us with orphan files we can't distinguish. Let Pass 1
	# regenerate from scratch; the orphan-cleanup pass below sweeps them.
	var hook_pack: String = cfg.get_value("state", "hook_pack_path", "") as String
	var wrapped_paths: PackedStringArray = cfg.get_value("state", "hook_pack_wrapped_paths", PackedStringArray())
	# Orphan cleanup: previous sessions may have left framework_pack_*.zip
	# files behind (Windows can't delete the currently-mounted one mid-session).
	# At static-init the engine has mounted nothing yet, so deleting every pack
	# EXCEPT the one pass_state points at is safe. Prevents unbounded growth
	# for users cycling large mod sets over many sessions.
	_static_cleanup_orphan_hook_packs(hook_pack, log_lines)
	# Cache-snapshot diagnostic -- shows which wrapped scripts were already
	# loaded into ResourceLoader by Godot's eager class_cache pass before
	# we get a chance to preempt them. Useful for diagnosing "why didn't
	# my hook fire" on pinned paths. Skipped when no wrapped_paths exist.
	if wrapped_paths.size() > 0:
		var pre_cached_count := 0
		var pre_cached_tokenized: PackedStringArray = []
		var pre_cached_source: PackedStringArray = []
		var pre_notloaded: PackedStringArray = []
		for path in wrapped_paths:
			if ResourceLoader.has_cached(path):
				pre_cached_count += 1
				var s := load(path) as GDScript
				if s != null and s.source_code.length() > 0:
					pre_cached_source.append(path.get_file())
				else:
					pre_cached_tokenized.append(path.get_file())
			else:
				pre_notloaded.append(path.get_file())
		log_lines.append("[FileScope] PRE-INIT cache: %d/%d wrapped scripts already cached at static init" \
				% [pre_cached_count, wrapped_paths.size()])
		if pre_cached_tokenized.size() > 0:
			log_lines.append("[FileScope]   tokenized (PCK-compiled already): " + ", ".join(pre_cached_tokenized))
		if pre_cached_source.size() > 0:
			log_lines.append("[FileScope]   source-loaded (our take_over_path from prev session): " + ", ".join(pre_cached_source))
		if pre_notloaded.size() > 0:
			log_lines.append("[FileScope]   NOT YET LOADED (preempt window open): " + ", ".join(pre_notloaded))
	if hook_pack != "":
		var hook_abs: String = hook_pack if not hook_pack.begins_with("user://") \
				else ProjectSettings.globalize_path(hook_pack)
		if FileAccess.file_exists(hook_abs):
			if ProjectSettings.load_resource_pack(hook_abs, true):
				log_lines.append("[FileScope] HOOK PACK mounted at static init: " + hook_pack)
				# Preempt ONLY the scripts this modlist declared + wrapped
				# (v3.0.1). Previous behavior was to preempt a hardcoded list
				# of 16 class_name scripts regardless of whether a mod
				# touched them. Narrowing to wrapped_paths ensures legacy
				# modlists (zero declarations) never see static-init
				# preemption at all -- Godot's native lazy-compile runs
				# unmodified, byte-identical to v2.1.0 behavior.
				var hzr := ZIPReader.new()
				if hzr.open(hook_abs) == OK:
					var wrapped_set: Dictionary = {}
					for wp in wrapped_paths:
						wrapped_set[wp] = true
					var preloaded := 0
					var preload_failed := 0
					var skipped_lenient := 0
					for f: String in hzr.get_files():
						if not f.begins_with("Scripts/") or not f.ends_with(".gd"):
							continue
						var rpath := "res://" + f
						if not wrapped_set.has(rpath):
							# Not declared as a wrapped target -- skip strict
							# preempt. VFS mount (replace_files=true) still
							# serves our rewrite to Godot's lenient lazy-
							# compile when game code first loads the path.
							skipped_lenient += 1
							continue
						var scr := ResourceLoader.load(rpath, "", ResourceLoader.CACHE_MODE_IGNORE) as GDScript
						if scr == null or scr.source_code.is_empty():
							preload_failed += 1
							continue
						scr.take_over_path(rpath)
						preloaded += 1
					hzr.close()
					log_lines.append("[FileScope] HOOK PACK preempted %d wrapped script(s) at static init (%d failed, %d other vanilla left to lenient lazy-compile)" \
							% [preloaded, preload_failed, skipped_lenient])
			else:
				log_lines.append("[FileScope] HOOK PACK mount FAILED: " + hook_pack)
		else:
			log_lines.append("[FileScope] HOOK PACK path in pass_state but file missing: " + hook_abs)

	# TEST HOOK: mount the test pack here (static-init, before any autoload
	# runs) so VFS serves our rewritten scripts to the FIRST compilation.
	# Mount it AFTER mod archives so our entries win via replace_files=true.
	var test_pack_path := ProjectSettings.globalize_path("user://test_pack_precedence.zip")
	if FileAccess.file_exists(test_pack_path):
		if ProjectSettings.load_resource_pack(test_pack_path, true):
			log_lines.append("[FileScope] TEST: mounted test_pack_precedence.zip at static init")
		else:
			log_lines.append("[FileScope] TEST: FAILED to mount test_pack_precedence.zip")

	log_lines.append("[FileScope] Done -- %d archive(s) mounted" % mounted.size())
	_write_filescope_log(log_lines)
	return mounted

# Reset override.cfg to a clean state -- just [autoload] ModLoader + any
# preserved non-autoload sections. Used when pass state is wiped so stale
# [autoload_prepend] entries from prior launches don't crash the next boot
# by referencing scripts whose archive isn't file-scope-mounted.
static func _static_reset_override_cfg(log_lines: PackedStringArray) -> void:
	var exe_dir := OS.get_executable_path().get_base_dir()
	var cfg_path := exe_dir.path_join("override.cfg")
	if not FileAccess.file_exists(cfg_path):
		return
	var preserved := _read_preserved_cfg_sections(cfg_path)
	var f := FileAccess.open(cfg_path, FileAccess.WRITE)
	if f == null:
		log_lines.append("[FileScope] WARNING: could not rewrite override.cfg (read-only?)")
		return
	f.store_string("[autoload_prepend]\nModLoader=\"*" + MODLOADER_RES_PATH + "\"\n\n[autoload]\n\n" + preserved)
	f.close()
	log_lines.append("[FileScope] override.cfg reset to clean [autoload_prepend] state")

static func _static_cleanup_orphan_hook_packs(keep_path: String, log_lines: PackedStringArray) -> void:
	# Delete every framework_pack_*.zip in HOOK_PACK_DIR except keep_path.
	# Called at static-init BEFORE any hook-pack mount, so the VFS holds no
	# handles to these files. Safe to delete them on every platform. If
	# keep_path is empty (no pass_state entry, or no hook pack yet) every
	# file matching the pattern is treated as orphan.
	var pack_dir := ProjectSettings.globalize_path(HOOK_PACK_DIR)
	if not DirAccess.dir_exists_absolute(pack_dir):
		return
	var keep_abs := ProjectSettings.globalize_path(keep_path) if keep_path != "" else ""
	var dir := DirAccess.open(pack_dir)
	if dir == null:
		return
	dir.list_dir_begin()
	var removed := 0
	while true:
		var fname := dir.get_next()
		if fname == "":
			break
		if not fname.begins_with(HOOK_PACK_PREFIX) or not fname.ends_with(".zip"):
			continue
		var full := pack_dir.path_join(fname)
		if keep_abs != "" and full == keep_abs:
			continue
		DirAccess.remove_absolute(full)
		removed += 1
	dir.list_dir_end()
	if removed > 0:
		log_lines.append("[FileScope] Cleaned %d orphan hook pack(s) from prior session(s)" % removed)

static func _static_wipe_hook_cache() -> void:
	# Wipe every Framework*.gd we previously generated (cheap to regenerate)
	# and every framework_pack_*.zip (per-session hook packs). On Windows,
	# a zip currently mounted by Godot's VFS may refuse deletion (open handle);
	# the orphan-cleanup pass in _mount_previous_session catches stragglers
	# on the next fresh-engine launch.
	var pack_dir := ProjectSettings.globalize_path(HOOK_PACK_DIR)
	if DirAccess.dir_exists_absolute(pack_dir):
		var pdir := DirAccess.open(pack_dir)
		if pdir != null:
			pdir.list_dir_begin()
			while true:
				var pname := pdir.get_next()
				if pname == "":
					break
				if pname.begins_with("Framework") and pname.ends_with(".gd"):
					DirAccess.remove_absolute(pack_dir.path_join(pname))
				elif pname.begins_with(HOOK_PACK_PREFIX) and pname.ends_with(".zip"):
					DirAccess.remove_absolute(pack_dir.path_join(pname))
			pdir.list_dir_end()
	var cache_dir := ProjectSettings.globalize_path(VANILLA_CACHE_DIR)
	if not DirAccess.dir_exists_absolute(cache_dir):
		return
	var dir := DirAccess.open(cache_dir)
	if dir == null:
		return
	dir.list_dir_begin()
	var file_name := dir.get_next()
	while file_name != "":
		var full := cache_dir.path_join(file_name)
		if dir.current_is_dir():
			# Shallow -- vanilla cache is only Scripts/*.gd (one level deep)
			var sub := DirAccess.open(full)
			if sub:
				sub.list_dir_begin()
				var sub_file := sub.get_next()
				while sub_file != "":
					DirAccess.remove_absolute(full.path_join(sub_file))
					sub_file = sub.get_next()
				sub.list_dir_end()
			DirAccess.remove_absolute(full)
		else:
			DirAccess.remove_absolute(full)
		file_name = dir.get_next()
	dir.list_dir_end()
	DirAccess.remove_absolute(cache_dir)

func _build_autoload_sections() -> Dictionary:
	# Wipe previous early-autoload extractions so stale scripts don't linger.
	_clean_early_autoload_dir()
	var prepend: Array[Dictionary] = []
	var append: Array[Dictionary] = []
	for entry in _pending_autoloads:
		if entry.get("is_early", false):
			var path: String = entry["path"]
			var disk_path := _ensure_early_autoload_on_disk(path, entry.get("mod_name", ""))
			prepend.append({ "name": entry["name"], "path": disk_path })
		else:
			append.append({ "name": entry["name"], "path": entry["path"] })
	return { "prepend": prepend, "append": append }

const EARLY_AUTOLOAD_DIR := "user://modloader_early"

func _clean_early_autoload_dir() -> void:
	var dir_path := ProjectSettings.globalize_path(EARLY_AUTOLOAD_DIR)
	if not DirAccess.dir_exists_absolute(dir_path):
		return
	var dir := DirAccess.open(dir_path)
	if dir == null:
		return
	# Simple recursive wipe -- this directory is entirely modloader-managed.
	dir.list_dir_begin()
	while true:
		var entry := dir.get_next()
		if entry == "":
			break
		var full: String = dir_path.path_join(entry)
		if dir.current_is_dir():
			var sub := DirAccess.open(full)
			if sub:
				sub.list_dir_begin()
				var sub_file := sub.get_next()
				while sub_file != "":
					DirAccess.remove_absolute(full.path_join(sub_file))
					sub_file = sub.get_next()
				sub.list_dir_end()
			DirAccess.remove_absolute(full)
		else:
			DirAccess.remove_absolute(full)
	dir.list_dir_end()

# Extract an early autoload .gd script to disk if it only exists inside a
# mounted archive.  Godot opens [autoload_prepend] scripts before file-scope
# code runs, so archive-only scripts must be on disk for the restart.
# Scene autoloads (.tscn) are handled by file-scope mounting -- returned as-is.
func _ensure_early_autoload_on_disk(res_path: String, mod_name: String) -> String:
	var global := ProjectSettings.globalize_path(res_path)
	if FileAccess.file_exists(global):
		return res_path

	# Only .gd scripts need extraction -- scenes resolve via file-scope mount.
	var script := load(res_path) as GDScript
	if script == null or not script.has_source_code():
		return res_path

	var rel := res_path.trim_prefix("res://")
	var disk_dir := ProjectSettings.globalize_path(EARLY_AUTOLOAD_DIR)
	var target := disk_dir.path_join(rel)
	DirAccess.make_dir_recursive_absolute(target.get_base_dir())
	var f := FileAccess.open(target, FileAccess.WRITE)
	if f == null:
		_log_critical("Cannot write early autoload to disk: " + target + " [" + mod_name + "]")
		return res_path
	f.store_string(script.source_code)
	f.close()

	# Return as user:// path so Godot finds it without archive mounting.
	var user_path := EARLY_AUTOLOAD_DIR.path_join(rel)
	_log_info("  Extracted early autoload to disk: " + user_path + " [" + mod_name + "]")
	return user_path

func _collect_enabled_archive_paths() -> PackedStringArray:
	var paths := PackedStringArray()
	var candidates: Array[Dictionary] = []
	for entry in _ui_mod_entries:
		if not entry["enabled"]:
			continue
		candidates.append(entry.duplicate())
	candidates.sort_custom(_compare_load_order)
	for c in candidates:
		if c["ext"] == "zip":
			continue
		if c["ext"] == "folder":
			# Folder mods are zipped to a temp cache during load_all_mods().
			# Store the temp zip path -- the folder itself can't be mounted.
			var folder_name: String = c["full_path"].get_file()
			var tmp_zip := ProjectSettings.globalize_path(TMP_DIR).path_join(
					folder_name + "_dev.zip")
			if FileAccess.file_exists(tmp_zip):
				paths.append(tmp_zip)
			else:
				_log_warning("Folder mod '%s' has no cached zip -- skipping from pass state"
						% c["mod_name"])
			continue
		paths.append(c["full_path"])
	return paths

# Uses FileAccess instead of ConfigFile (which erases null keys).
# ModLoader listed last in [autoload_prepend] = loaded first (reverse insertion).
func _write_override_cfg(prepend_autoloads: Array[Dictionary]) -> Error:
	var exe_dir := OS.get_executable_path().get_base_dir()
	var path := exe_dir.path_join("override.cfg")
	var tmp := path + ".tmp"
	var preserved := _read_preserved_cfg_sections(path)
	var lines := PackedStringArray()
	# Always put ModLoader in [autoload_prepend] (last = loaded first via
	# reverse insertion). Without this, when no mods use the "!" prefix,
	# ModLoader falls into plain [autoload] and some game autoloads
	# (Database, GameData, Loader, Simulation) load before our class-level
	# static init runs -- pinning their .gdc bytecode before our hook pack
	# can preempt them.
	lines.append("[autoload_prepend]")
	for entry in prepend_autoloads:
		lines.append('%s="*%s"' % [entry["name"], entry["path"]])
	lines.append('ModLoader="*' + MODLOADER_RES_PATH + '"')
	lines.append("")
	lines.append("[autoload]")
	lines.append("")
	var f := FileAccess.open(tmp, FileAccess.WRITE)
	if f == null:
		return FileAccess.get_open_error()
	f.store_string("\n".join(lines) + "\n" + preserved)
	f.close()
	# Windows DirAccess.rename() won't overwrite -- remove target first.
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(path)
	var dir := DirAccess.open(exe_dir)
	if dir == null:
		DirAccess.remove_absolute(tmp)
		return ERR_CANT_OPEN
	var err := dir.rename(tmp.get_file(), path.get_file())
	if err != OK:
		DirAccess.remove_absolute(tmp)
	return err

func _persist_hook_pack_state(pack_path: String, wrapped_paths: PackedStringArray = PackedStringArray()) -> void:
	# Write hook_pack_path + wrapped_paths to pass_state so the next session
	# (1) mounts the pack at static init and (2) preempts ONLY the declared
	# scripts in _mount_previous_session's class_cache-pinning path.
	# Piggybacks on the existing pass_state ConfigFile -- doesn't overwrite
	# other keys.
	var cfg := ConfigFile.new()
	cfg.load(PASS_STATE_PATH)  # OK if missing; we populate below
	cfg.set_value("state", "hook_pack_path", pack_path)
	cfg.set_value("state", "hook_pack_wrapped_paths", wrapped_paths)
	# Store exe mtime alongside so _mount_previous_session's existing
	# exe-mtime check also invalidates the hook pack on game updates.
	cfg.set_value("state", "hook_pack_exe_mtime", FileAccess.get_modified_time(OS.get_executable_path()))
	if cfg.get_value("state", "modloader_version", "") == "":
		cfg.set_value("state", "modloader_version", MODLOADER_VERSION)
	if cfg.save(PASS_STATE_PATH) == OK:
		_log_info("[RTVCodegen] Persisted hook pack path for next-session static-init mount: %s (%d wrapped path(s))" \
				% [pack_path.get_file(), wrapped_paths.size()])

func _write_pass_state(archive_paths: PackedStringArray, state_hash: String = "") -> Error:
	var cfg := ConfigFile.new()
	cfg.load(PASS_STATE_PATH)
	var count: int = cfg.get_value("state", "restart_count", 0)
	cfg.set_value("state", "restart_count", count + 1)
	cfg.set_value("state", "mods_hash", state_hash)
	cfg.set_value("state", "archive_paths", archive_paths)
	cfg.set_value("state", "modloader_version", MODLOADER_VERSION)
	cfg.set_value("state", "exe_mtime", FileAccess.get_modified_time(OS.get_executable_path()))
	cfg.set_value("state", "timestamp", Time.get_unix_time_from_system())
	# Persist script overrides so Pass 2 can apply them without re-parsing mods.
	var override_data: Array = []
	for entry in _pending_script_overrides:
		override_data.append(entry.duplicate())
	cfg.set_value("state", "script_overrides", override_data)
	var err := cfg.save(PASS_STATE_PATH)
	if err != OK:
		_log_critical("Failed to save pass state (error %d)" % err)
	return err

func _compute_state_hash(archive_paths: PackedStringArray, prepend_autoloads: Array[Dictionary]) -> String:
	if archive_paths.is_empty() and prepend_autoloads.is_empty():
		return ""
	var parts := PackedStringArray()
	var sorted_paths := Array(archive_paths)
	sorted_paths.sort()
	for p in sorted_paths:
		# Include mtime so replacing a file with the same name triggers a restart.
		parts.append("a:%s@%d" % [p, FileAccess.get_modified_time(p)])
	for entry in prepend_autoloads:
		parts.append("p:%s=%s" % [entry["name"], entry["path"]])
	for entry in _ui_mod_entries:
		if entry["enabled"] and entry.get("cfg") != null:
			var ver: String = (entry["cfg"] as ConfigFile).get_value("mod", "version", "")
			if not ver.is_empty():
				parts.append("v:%s=%s" % [entry["mod_id"], ver])
	for entry in _pending_script_overrides:
		parts.append("so:%s=%s" % [entry["vanilla_path"], entry["mod_script_path"]])
	parts.append("ml:" + MODLOADER_VERSION)
	# Include modloader.gd's mtime so any rebuild of the loader itself
	# triggers a restart, even when the mod set is unchanged. Rationale:
	# _finish_with_existing_mounts regenerates the hook pack in place on
	# a process that already has the old pack mounted. ZIPPacker.open
	# rewrites the file but ProjectSettings.load_resource_pack dedupes by
	# path (see lifecycle.gd comment), so the re-mount is a no-op and the
	# VFS keeps the OLD mount's cached file offsets. If the new pack's
	# entry layout differs from the old pack's (common when the rewriter
	# changes between builds), every read of a moved entry fails at
	# file_access_zip.cpp:141 (unzGoToFilePos on a stale offset). Forcing
	# a restart on modloader rebuild means Pass 2's fresh engine mounts
	# the new pack with a fresh index -- no stale cache to fight.
	var self_mtime: int = FileAccess.get_modified_time("res://modloader.gd")
	if self_mtime > 0:
		parts.append("ml_mtime:%d" % self_mtime)
	return "\n".join(parts).md5_text()

func _write_heartbeat() -> void:
	var f := FileAccess.open(HEARTBEAT_PATH, FileAccess.WRITE)
	if f:
		f.store_string("started:%d" % Time.get_unix_time_from_system())
		f.close()

func _delete_heartbeat() -> void:
	if FileAccess.file_exists(HEARTBEAT_PATH):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(HEARTBEAT_PATH))

func _check_crash_recovery() -> void:
	if not FileAccess.file_exists(HEARTBEAT_PATH):
		return
	_log_warning("Heartbeat detected -- previous launch may have crashed")
	var cfg := ConfigFile.new()
	if cfg.load(PASS_STATE_PATH) == OK:
		var count: int = cfg.get_value("state", "restart_count", 0)
		if count >= MAX_RESTART_COUNT:
			_log_critical("Restart loop (%d crashes) -- resetting to clean state" % count)
			_restore_clean_override_cfg()
			DirAccess.remove_absolute(ProjectSettings.globalize_path(PASS_STATE_PATH))
			_delete_heartbeat()
			return
	_delete_heartbeat()

func _check_safe_mode() -> void:
	var exe_dir := OS.get_executable_path().get_base_dir()
	var safe_path := exe_dir.path_join(SAFE_MODE_FILE)
	if not FileAccess.file_exists(safe_path):
		return
	_log_warning("Safe mode file detected -- resetting to clean state")
	_restore_clean_override_cfg()
	if FileAccess.file_exists(PASS_STATE_PATH):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(PASS_STATE_PATH))
	_delete_heartbeat()
	DirAccess.remove_absolute(safe_path)

func _clean_stale_cache() -> void:
	# Remove cached zips whose source .vmz / folder no longer exists in the mods dir.
	var cache_dir := ProjectSettings.globalize_path(TMP_DIR)
	if not DirAccess.dir_exists_absolute(cache_dir):
		return
	var dir := DirAccess.open(cache_dir)
	if dir == null:
		return
	dir.list_dir_begin()
	while true:
		var fname := dir.get_next()
		if fname == "":
			break
		if fname.get_extension().to_lower() != "zip":
			continue
		var base := fname.get_basename()
		if base.ends_with("_dev"):
			# Folder mod cache -- check if the source folder still exists.
			var folder_name := base.substr(0, base.length() - 4)
			if DirAccess.dir_exists_absolute(_mods_dir.path_join(folder_name)):
				continue
		else:
			# VMZ cache -- check if the source .vmz still exists.
			var vmz_name := base + ".vmz"
			if FileAccess.file_exists(_mods_dir.path_join(vmz_name)):
				continue
		DirAccess.remove_absolute(cache_dir.path_join(fname))
		_log_debug("Removed stale cache: " + fname)
	dir.list_dir_end()

func _restore_clean_override_cfg() -> void:
	var exe_dir := OS.get_executable_path().get_base_dir()
	var path := exe_dir.path_join("override.cfg")
	var preserved := _read_preserved_cfg_sections(path)
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		_log_critical("Cannot write override.cfg -- game dir may be read-only: " + exe_dir)
		return
	f.store_string("[autoload_prepend]\nModLoader=\"*" + MODLOADER_RES_PATH + "\"\n\n[autoload]\n\n" + preserved)
	f.close()

func _clear_restart_counter() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(PASS_STATE_PATH) == OK:
		cfg.set_value("state", "restart_count", 0)
		cfg.save(PASS_STATE_PATH)
