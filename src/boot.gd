## ----- boot.gd -----
## Static-init boot layer. Runs at script load time (before _ready) via
## _mount_previous_session. Owns the two-pass archive mount, override.cfg
## rewriting, pass state persistence, heartbeat + crash recovery, safe mode,
## and the hook-pack preload that preempts Godot's PCK-bytecode pinning for
## class_name scripts.
##
## BOOT SEQUENCE
## =============
## Stage 0 -- static init (this file). constants.gd initializes
## _filescope_mounted by calling _mount_previous_session() while the
## ModLoader autoload script itself is loading -- override.cfg lists
## ModLoader last in [autoload_prepend] (= loaded first), so this runs
## before any game autoload compiles a class_name script. In order:
##   1. DISABLED_FILE / DISABLED_ONCE_FILE sentinel present -> force
##      vanilla state (reset override.cfg autoload sections, delete pass
##      state + pass2-dirty marker, wipe hook pack), mount nothing.
##   2. PASS2_DIRTY_PATH present -> a previous Pass 2 crashed mid-run;
##      Same full wipe, mount nothing.
##   3. Load PASS_STATE_PATH. Missing or empty pass state -> mount
##      nothing. Modloader-version mismatch, changed exe mtime (game
##      updated), or any recorded archive now missing -> reset
##      override.cfg + delete pass state (version/mtime mismatches also
##      wipe the hook cache), mount nothing. This launch may log
##      autoload-load errors (Godot read override.cfg first);
##      the NEXT launch boots clean.
##   4. Mount every archive the previous session recorded, then the hook
##      pack on top (replace_files=true), then preempt the wrapped
##      class_name scripts via CACHE_MODE_IGNORE + take_over_path.
## Static init logs via _write_filescope_log to
## user://modloader_filescope.log. The instance log helpers do not
## exist yet at this point.
##
## Stage 1 -- _ready (lifecycle.gd). Dispatch: "--modloader-restart" in
## the user cmdline args -> _run_pass_2, else _run_pass_1.
##
## Pass 1 (fresh launch): _check_crash_recovery + _check_safe_mode,
## discover mods, show the launcher UI (show_mod_ui. The only place
## the UI appears at boot; post-boot it reopens via reopen_mod_ui from
## the main-menu hook), load_all_mods, then compare _compute_state_hash
## against the stored mods_hash:
##   - hash unchanged (and non-empty) -> no restart;
##     _finish_with_existing_mounts rides the archives static init
##     already mounted.
##   - archives enabled + hash changed -> generate the hook pack
##     (defer_activation=true), write heartbeat, override.cfg and pass
##     state (increments restart_count), relaunch the game with
##     --modloader-restart.
##   - no enabled archives -> delete stale pass state / hook artifacts,
##     _finish_single_pass.
##
## Pass 2 (the restarted process): archives were already mounted by THIS
## process's static init. Writes PASS2_DIRTY_PATH first thing, restores
## script overrides from pass state, re-runs discovery + load_all_mods +
## hook pack generate/activate, instantiates autoloads, deletes the
## heartbeat, then clears the restart streak and the dirty marker together
## at the end. Clearing at entry would precede load_all_mods and autoload
## instantiation, the window where a mod actually crashes, so crashed
## launches would record a streak of zero. Never shows the UI.
##
## Sentinel / state files (who writes, who clears):
##   DISABLED_FILE       exe dir; user-created. Permanent vanilla mode.
##   DISABLED_ONCE_FILE  exe dir; written by the UI's "Launch Vanilla"
##                       button, cleared by _ready after one vanilla boot.
##   SAFE_MODE_FILE      exe dir; user-created. _check_safe_mode (Pass 1)
##                       resets override.cfg + pass state, then deletes it.
##   PASS_STATE_PATH     user://; written by Pass 1 before restarting and
##                       by _persist_hook_pack_state; read at static init
##                       and by Pass 2. Holds archive_paths, mods_hash,
##                       hook_pack_path/wrapped_paths, restart_count.
##                       DELETED by the crashed-Pass-2 wipe.
##   CRASH_STREAK_PATH   user://; consecutive crashed restart attempts,
##                       bumped by _write_pass_state, cleared by
##                       _clear_restart_counter. Its own file so the wipe
##                       above cannot erase it.
##   HEARTBEAT_PATH      user://; written right before the Pass 1 ->
##                       Pass 2 restart, deleted by every finish path. A
##                       survivor at the next Pass 1 means the previous
##                       launch died between restart and finish.
##   PASS2_DIRTY_PATH    user://; written at Pass 2 entry, cleared at
##                       Pass 2 end. A survivor means Pass 2 crashed;
##                       static init force-wipes everything.
##
## Crash at each stage:
##   - Pass 1 before the restart branch: no heartbeat written; next
##     launch is a normal Pass 1.
##   - Between the restart and Pass 2's finish: heartbeat survives;
##     _check_crash_recovery warns. The streak lives in CRASH_STREAK_PATH,
##     not pass state: the crashed-Pass-2 wipe deletes pass state, so a
##     counter kept there could never survive to trip. Once the streak
##     reaches MAX_RESTART_COUNT, Pass 1 refuses the two-pass restart and
##     stays single-pass, leaving the launcher reachable so the player can
##     disable the offending mod. Every clean finish resets it to zero.
##   - Pass 2 after the dirty marker: next static init force-wipes state
##     (step 2 above); the launch after that regenerates fresh.
##   - While DISABLED_ONCE_FILE is pending: the sentinel persists until
##     a _ready runs, so a crash keeps the next launch vanilla.

static func _is_modloader_disabled() -> bool:
	# Either sentinel in the game exe dir forces a vanilla launch; see the
	# header's sentinel table.
	var exe_dir := OS.get_executable_path().get_base_dir()
	if FileAccess.file_exists(exe_dir.path_join(DISABLED_FILE)):
		return true
	return FileAccess.file_exists(exe_dir.path_join(DISABLED_ONCE_FILE))

## Consecutive crashed restart attempts. Static because static init reads it
## before any instance exists.
static func _static_read_crash_streak() -> int:
	if not FileAccess.file_exists(CRASH_STREAK_PATH):
		return 0
	var f := FileAccess.open(CRASH_STREAK_PATH, FileAccess.READ)
	if f == null:
		return 0
	var text := f.get_as_text().strip_edges()
	f.close()
	# Hand-editable file: garbage reads as "no streak" rather than tripping the breaker.
	return maxi(0, text.to_int()) if text.is_valid_int() else 0


## value <= 0 removes the file, so "no streak" leaves nothing behind on disk.
static func _static_write_crash_streak(value: int) -> void:
	if value <= 0:
		if FileAccess.file_exists(CRASH_STREAK_PATH):
			DirAccess.remove_absolute(ProjectSettings.globalize_path(CRASH_STREAK_PATH))
		return
	var f := FileAccess.open(CRASH_STREAK_PATH, FileAccess.WRITE)
	if f == null:
		return
	f.store_string(str(value))
	f.close()


## Whether the two-pass restart must be refused because the last
## MAX_RESTART_COUNT attempts all died before finishing. Without this the
## crash-restart-crash cycle repeats forever with no way back into the game.
func _crash_breaker_tripped() -> bool:
	return _static_read_crash_streak() >= MAX_RESTART_COUNT


# Reset persistent state to a vanilla baseline: clean override.cfg, delete
# pass state, wipe the hook pack directory. Safe when any artifact is missing.
# Never touches CRASH_STREAK_PATH: it counts crashed-Pass-2 events, and this
# runs on that very path.
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

# The canonical clean override.cfg content. All three reset paths must write
# byte-identical content ([autoload_prepend] with ModLoader only, empty
# [autoload], then preserved non-modloader sections).
static func _clean_override_cfg_content(preserved: String) -> String:
	return "[autoload_prepend]\nModLoader=\"*" + MODLOADER_RES_PATH + "\"\n\n[autoload]\n\n" + preserved

# Atomic override.cfg writer for the reset paths: tmp -> park .old -> promote
# -> restore on failure. Opening the live file with FileAccess.WRITE truncates
# it instantly, and losing override.cfg means the ModLoader autoload never
# loads again -- nothing can self-heal. Returns false with the live file
# untouched (or restored) on any failure.
static func _static_write_cfg_atomic(cfg_path: String, content: String) -> bool:
	var tmp := cfg_path + ".tmp"
	var f := FileAccess.open(tmp, FileAccess.WRITE)
	if f == null:
		return false
	var ok := f.store_string(content)
	var werr := f.get_error()
	f.close()
	if not ok or werr != OK:
		DirAccess.remove_absolute(tmp)
		return false
	var bak := cfg_path + ".old"
	var dir := DirAccess.open(cfg_path.get_base_dir())
	if dir == null:
		DirAccess.remove_absolute(tmp)
		return false
	if FileAccess.file_exists(cfg_path):
		if FileAccess.file_exists(bak):
			DirAccess.remove_absolute(bak)
		if dir.rename(cfg_path.get_file(), bak.get_file()) != OK:
			# Could not park the live cfg (AV lock?) -- leave it untouched.
			DirAccess.remove_absolute(tmp)
			return false
	if dir.rename(tmp.get_file(), cfg_path.get_file()) != OK:
		DirAccess.remove_absolute(tmp)
		if FileAccess.file_exists(bak):
			# If the rename back fails too, fall back to a byte copy so a live
			# cfg always exists.
			if dir.rename(bak.get_file(), cfg_path.get_file()) != OK:
				DirAccess.copy_absolute(bak, cfg_path)
		return false
	if FileAccess.file_exists(bak):
		DirAccess.remove_absolute(bak)
	return true

# The pass-state file is hand-editable and survives crashes mid-write, so
# every read coerces: a value of the wrong type reads as its default rather
# than raising a typed-assignment error inside a static initializer, where
# nothing could catch it and the boot would stop before any recovery branch.
static func _state_str(cfg: ConfigFile, key: String, default: String) -> String:
	var v: Variant = cfg.get_value("state", key, default)
	return v if v is String else default

static func _state_int(cfg: ConfigFile, key: String, default: int) -> int:
	var v: Variant = cfg.get_value("state", key, default)
	if v is int:
		return v
	if v is float:
		return int(v)
	if v is String and str(v).strip_edges().is_valid_int():
		return str(v).strip_edges().to_int()
	return default

static func _state_paths(cfg: ConfigFile, key: String) -> PackedStringArray:
	var v: Variant = cfg.get_value("state", key, PackedStringArray())
	if v is PackedStringArray:
		return v
	var out := PackedStringArray()
	if v is Array:
		for item in (v as Array):
			if item is String and str(item) != "":
				out.append(str(item))
	return out

# A folder mod is recorded by its cache zip under TMP_DIR. The zip outlives
# the folder, so "the file exists" is not enough: the source folder must
# too, or the deleted mod would mount for one more session.
static func _static_archive_source_present(path: String) -> bool:
	var abs_path := path if not path.begins_with("res://") and not path.begins_with("user://") \
			else ProjectSettings.globalize_path(path)
	if not FileAccess.file_exists(abs_path):
		return false
	var file_name := path.get_file()
	if not file_name.ends_with("_dev.zip"):
		return true
	if not (path.begins_with(TMP_DIR) or path.begins_with(ProjectSettings.globalize_path(TMP_DIR))):
		return true
	var folder := OS.get_executable_path().get_base_dir().path_join(MOD_DIR).path_join(file_name.trim_suffix("_dev.zip"))
	return DirAccess.dir_exists_absolute(folder)

static func _mount_previous_session() -> Dictionary:
	var mounted: Dictionary = {}
	var log_lines: PackedStringArray = []
	log_lines.append("[FileScope] _mount_previous_session() starting")
	# Log the engine version first so every user log answers "which Godot is
	# this" before triage starts.
	var vinfo := Engine.get_version_info()
	log_lines.append("[FileScope] Engine: Godot %s, modloader %s, os %s" \
			% [str(vinfo.get("string", "")), MODLOADER_VERSION, OS.get_name()])

	# Sentinel: reset persistent state, mount nothing. Mod-autoload errors this
	# boot are expected (override.cfg was already read); the next launch is clean.
	if _is_modloader_disabled():
		_static_force_vanilla_state("modloader_disabled sentinel", log_lines)
		_write_filescope_log(log_lines)
		return mounted

	# Dirty marker survived: Pass 2 was interrupted before cleanup, so nothing
	# on disk can be trusted. Full wipe; Pass 1 regenerates.
	if FileAccess.file_exists(PASS2_DIRTY_PATH):
		_static_force_vanilla_state("pass 2 crashed mid-run", log_lines)
		_write_filescope_log(log_lines)
		return mounted

	var cfg := ConfigFile.new()
	if cfg.load(PASS_STATE_PATH) != OK:
		log_lines.append("[FileScope] No pass state file -- skipping")
		_write_filescope_log(log_lines)
		return mounted
	# Different modloader version: wipe pass state and reset override.cfg, whose
	# stale [autoload_prepend] entries would fail to load before _ready runs.
	var saved_ver := _state_str(cfg, "modloader_version", "")
	if saved_ver != MODLOADER_VERSION:
		log_lines.append("[FileScope] Version mismatch: saved=%s current=%s -- wiping" % [saved_ver, MODLOADER_VERSION])
		# Rewriter output semantics can change across versions, so a stale
		# framework_pack must not get mounted; Pass 1 regenerates.
		_static_wipe_hook_cache()
		DirAccess.remove_absolute(ProjectSettings.globalize_path(PASS_STATE_PATH))
		_static_reset_override_cfg(log_lines)
		_write_filescope_log(log_lines)
		return mounted
	# Detect game updates -- exe mtime change means vanilla scripts may have changed.
	var saved_exe_mtime := _state_int(cfg, "exe_mtime", 0)
	if saved_exe_mtime != 0:
		var current_exe_mtime := FileAccess.get_modified_time(OS.get_executable_path())
		if current_exe_mtime != saved_exe_mtime:
			log_lines.append("[FileScope] Game exe mtime changed -- wiping hook cache")
			_static_wipe_hook_cache()
			# The launcher tells the player; a healthy activation clears it.
			_static_mark_game_updated()
			DirAccess.remove_absolute(ProjectSettings.globalize_path(PASS_STATE_PATH))
			_static_reset_override_cfg(log_lines)
			_write_filescope_log(log_lines)
			return mounted
	var paths := _state_paths(cfg, "archive_paths")
	if paths.is_empty():
		log_lines.append("[FileScope] Pass state has no archive paths -- skipping")
		_write_filescope_log(log_lines)
		return mounted

	log_lines.append("[FileScope] %d archive path(s) in pass state" % paths.size())

	# Were any archives deleted since last session?
	var any_missing := false
	for path in paths:
		var abs_path := path if not path.begins_with("res://") and not path.begins_with("user://") \
				else ProjectSettings.globalize_path(path)
		if _static_archive_source_present(path):
			log_lines.append("[FileScope]   EXISTS: " + abs_path)
			continue
		# Source gone: treat as missing even if a same-basename cache zip
		# survived (a .vmz copy, or a folder mod's _dev.zip). Mounting the
		# stale cache would serve old content before Pass 1 can mount the
		# replacement.
		log_lines.append("[FileScope]   MISSING: " + abs_path)
		any_missing = true

	if any_missing:
		log_lines.append("[FileScope] Archive(s) missing -- resetting to clean state")
		# Wipe override.cfg autoload sections but preserve non-autoload
		# settings ([display], etc.).
		var exe_dir := OS.get_executable_path().get_base_dir()
		var cfg_path := exe_dir.path_join("override.cfg")
		var preserved := _read_preserved_cfg_sections(cfg_path)
		if not _static_write_cfg_atomic(cfg_path, _clean_override_cfg_content(preserved)):
			log_lines.append("[FileScope] WARNING: could not rewrite override.cfg -- live file left untouched")
		var state_path := ProjectSettings.globalize_path(PASS_STATE_PATH)
		if FileAccess.file_exists(state_path):
			DirAccess.remove_absolute(state_path)
		_write_filescope_log(log_lines)
		return mounted

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

	# Mount the hook pack at static init, before any game autoload compiles a
	# class_name script: once class_cache pins a compiled reference,
	# source_code+reload and CACHE_MODE_IGNORE+take_over_path both fail.
	# Mount after mod archives so Scripts/*.gd wins via replace_files=true.
	# A first-ever session has no pass_state entry: skip, and those scripts run
	# PCK bytecode for one launch. No fallback by filename -- orphans from a
	# lost pass_state entry cannot be told apart; the cleanup below sweeps them.
	var hook_pack := _state_str(cfg, "hook_pack_path", "")
	var wrapped_paths := _state_paths(cfg, "hook_pack_wrapped_paths")
	# Windows can't delete a mounted pack mid-session, so prior sessions leave
	# framework_pack_*.zip orphans; nothing is mounted yet, so sweep them now.
	_static_cleanup_orphan_hook_packs(hook_pack, log_lines)
	# Diagnostic: which wrapped scripts Godot's eager class_cache pass already
	# loaded before any chance to preempt ("why didn't my hook fire").
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
	# Pass state is a user-editable cfg: treat the mount target as untrusted.
	# Anything but HOOK_PACK_DIR/HOOK_PACK_PREFIX*.zip did not come from
	# _write_pass_state and would run code before the security scanner.
	if hook_pack != "" and not _static_hook_pack_path_sane(hook_pack):
		log_lines.append("[FileScope] HOOK PACK path rejected (not a generated pack in "
				+ HOOK_PACK_DIR + "): " + hook_pack)
		hook_pack = ""
	if hook_pack != "":
		var hook_abs: String = hook_pack if not hook_pack.begins_with("user://") \
				else ProjectSettings.globalize_path(hook_pack)
		if FileAccess.file_exists(hook_abs):
			if ProjectSettings.load_resource_pack(hook_abs, true):
				log_lines.append("[FileScope] HOOK PACK mounted at static init: " + hook_pack)
				# Preempt only the scripts this modlist declared and wrapped;
				# an empty wrapped_paths leaves lazy-compile untouched.
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
							# Undeclared: the VFS mount still serves the rewrite
							# to lenient lazy-compile on first load.
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

	# TEST HOOK: mount before any autoload runs so VFS serves the rewritten
	# scripts to the first compilation. Gated on the same [settings] flag
	# that builds the pack. With the flag off, a zip left behind by an
	# earlier test session (or planted by a mod, since anything under
	# user:// is writable once a mod has run) is deleted, never mounted.
	var test_pack_path := ProjectSettings.globalize_path("user://test_pack_precedence.zip")
	if FileAccess.file_exists(test_pack_path):
		if _load_test_pack_flag():
			if ProjectSettings.load_resource_pack(test_pack_path, true):
				log_lines.append("[FileScope] TEST: mounted test_pack_precedence.zip at static init")
			else:
				log_lines.append("[FileScope] TEST: FAILED to mount test_pack_precedence.zip")
		else:
			DirAccess.remove_absolute(test_pack_path)
			log_lines.append("[FileScope] removed a stale test_pack_precedence.zip (test flag is off)")

	log_lines.append("[FileScope] Done -- %d archive(s) mounted" % mounted.size())
	_write_filescope_log(log_lines)
	return mounted

# Reset override.cfg to the clean baseline so stale [autoload_prepend] entries
# don't reference scripts whose archive is no longer mounted.
static func _static_reset_override_cfg(log_lines: PackedStringArray) -> void:
	var exe_dir := OS.get_executable_path().get_base_dir()
	var cfg_path := exe_dir.path_join("override.cfg")
	if not FileAccess.file_exists(cfg_path):
		return
	var preserved := _read_preserved_cfg_sections(cfg_path)
	if not _static_write_cfg_atomic(cfg_path, _clean_override_cfg_content(preserved)):
		log_lines.append("[FileScope] WARNING: could not rewrite override.cfg (read-only?) -- live file left untouched")
		return
	log_lines.append("[FileScope] override.cfg reset to clean [autoload_prepend] state")

# True only for the shape _write_pass_state can produce: a framework_pack_*.zip
# directly inside HOOK_PACK_DIR. Rejects absolute paths, res://, "..", subdirs.
static func _static_hook_pack_path_sane(path: String) -> bool:
	if not path.begins_with(HOOK_PACK_DIR + "/"):
		return false
	if path.contains(".."):
		return false
	var rel := path.substr(HOOK_PACK_DIR.length() + 1)
	if rel.contains("/"):
		return false
	return rel.begins_with(HOOK_PACK_PREFIX) and rel.get_extension().to_lower() == "zip"

static func _static_cleanup_orphan_hook_packs(keep_path: String, log_lines: PackedStringArray) -> void:
	# Delete every framework_pack_*.zip except keep_path (empty keep_path
	# means all are orphans). Runs before any mount, so no VFS handles exist.
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

# Delete the contents of a one-level-deep directory (the vanilla script cache).
# Does not remove dir_path itself; deeper trees use _wipe_early_autoload_tree.
static func _wipe_shallow_tree(dir_path: String) -> void:
	if not DirAccess.dir_exists_absolute(dir_path):
		return
	var dir := DirAccess.open(dir_path)
	if dir == null:
		return
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

static func _static_wipe_hook_cache() -> void:
	# Wipe generated Framework*.gd and framework_pack_*.zip. A zip mounted by
	# the VFS may refuse deletion on Windows; the static-init orphan sweep
	# catches stragglers next launch.
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
	# Shallow -- vanilla cache is only Scripts/*.gd (one level deep)
	var cache_dir := ProjectSettings.globalize_path(VANILLA_CACHE_DIR)
	_wipe_shallow_tree(cache_dir)
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
	# The tree mirrors full res:// relative paths, so it can be arbitrarily
	# deep; wipe recursively.
	_wipe_early_autoload_tree(ProjectSettings.globalize_path(EARLY_AUTOLOAD_DIR))

# Recursive delete under dir_path, refused outside EARLY_AUTOLOAD_DIR so a bad
# argument can never recurse through user data. Leaves the root dir itself.
func _wipe_early_autoload_tree(dir_path: String) -> void:
	var root := ProjectSettings.globalize_path(EARLY_AUTOLOAD_DIR)
	if dir_path != root and not dir_path.begins_with(root + "/"):
		_log_warning("Refusing to wipe outside the early-autoload dir: " + dir_path)
		return
	if not DirAccess.dir_exists_absolute(dir_path):
		return
	var dir := DirAccess.open(dir_path)
	if dir == null:
		return
	dir.list_dir_begin()
	while true:
		var entry := dir.get_next()
		if entry == "":
			break
		if entry == "." or entry == "..":
			continue
		var full: String = dir_path.path_join(entry)
		if dir.current_is_dir():
			_wipe_early_autoload_tree(full)
		DirAccess.remove_absolute(full)
	dir.list_dir_end()

# Extract an archive-only early autoload .gd to disk: Godot opens
# [autoload_prepend] scripts before any archive is mounted. Scene autoloads
# (.tscn) resolve via file-scope mounting and are returned as-is.
func _ensure_early_autoload_on_disk(res_path: String, mod_name: String) -> String:
	var global := ProjectSettings.globalize_path(res_path)
	if FileAccess.file_exists(global):
		return res_path

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
	var wrote_ok := f.store_string(script.source_code)
	var werr := f.get_error()
	f.close()
	if not wrote_ok or werr != OK:
		# A truncated script would be compiled next boot; drop it and fall
		# back to the archive path.
		DirAccess.remove_absolute(target)
		_log_critical("Failed writing early autoload to disk: " + target + " [" + mod_name + "]")
		return res_path

	# Return as user:// path so Godot finds it without archive mounting.
	var user_path := EARLY_AUTOLOAD_DIR.path_join(rel)
	_log_info("  Extracted early autoload to disk: " + user_path + " [" + mod_name + "]")
	return user_path

func _collect_enabled_archive_paths() -> PackedStringArray:
	var paths := PackedStringArray()
	# Same pick as load_all_mods (order + dependency filter) so the file-scope
	# mount order can never disagree with the runtime load order.
	var candidates: Array[Dictionary] = _loadable_enabled_entries(false, true)["loadable"]
	for c in candidates:
		if c["ext"] == "folder":
			# Folder mods mount via the temp zip load_all_mods() creates.
			var tmp_zip: String = _folder_dev_zip_path(c["full_path"])
			if FileAccess.file_exists(tmp_zip):
				paths.append(tmp_zip)
			else:
				_log_warning("Folder mod '%s' has no cached zip -- skipping from pass state"
						% c["mod_name"])
			continue
		paths.append(c["full_path"])
	return paths

# Uses FileAccess instead of ConfigFile (which erases null keys).
## Whether an autoload declaration can be written into override.cfg as a
## well-formed line. Both halves come from mod.txt, so both are untrusted:
## Godot's parser stops applying entries at the first bad line, and the
## ModLoader= line is written after the mod entries, so one malformed entry
## would stop the loader itself from ever being registered.
func _autoload_entry_writable(entry_name: String, entry_path: String) -> bool:
	# The autoload name becomes a singleton identifier; that grammar also
	# excludes everything that could break the line.
	if not entry_name.is_valid_identifier():
		return false
	# Archive-shipped early autoloads are extracted to EARLY_AUTOLOAD_DIR (see
	# _ensure_early_autoload_on_disk), so that user:// path is the normal case
	# for a packaged mod and must be accepted alongside res://.
	if not (entry_path.begins_with("res://") or entry_path.begins_with(EARLY_AUTOLOAD_DIR + "/")):
		return false
	# A quote closes the value early, a backslash starts an escape, a newline
	# splits the entry.
	return not (entry_path.contains('"') or entry_path.contains("\\")
			or entry_path.contains("\n") or entry_path.contains("\r"))


func _write_override_cfg(prepend_autoloads: Array[Dictionary]) -> Error:
	var exe_dir := OS.get_executable_path().get_base_dir()
	var path := exe_dir.path_join("override.cfg")
	var tmp := path + ".tmp"
	var preserved := _read_preserved_cfg_sections(path)
	var lines := PackedStringArray()
	# ModLoader always goes in [autoload_prepend] (last = loaded first via
	# reverse insertion); in plain [autoload] some game autoloads would pin
	# their bytecode before static init can preempt them.
	lines.append("[autoload_prepend]")
	for entry in prepend_autoloads:
		var entry_name := str(entry.get("name", ""))
		var entry_path := str(entry.get("path", ""))
		if not _autoload_entry_writable(entry_name, entry_path):
			_log_warning("[Boot] Skipping early autoload '%s' -> '%s': the name must be a plain identifier and the path a res:// path with no quotes or newlines. Writing it would corrupt override.cfg." % [entry_name, entry_path])
			continue
		lines.append('%s="*%s"' % [entry_name, entry_path])
	lines.append('ModLoader="*' + MODLOADER_RES_PATH + '"')
	lines.append("")
	lines.append("[autoload]")
	lines.append("")
	var f := FileAccess.open(tmp, FileAccess.WRITE)
	if f == null:
		return FileAccess.get_open_error()
	# store_string returns false on a failed write (disk full); never promote
	# a truncated tmp over the good live cfg.
	var wrote_ok := f.store_string("\n".join(lines) + "\n" + preserved)
	var write_err := f.get_error()
	f.close()
	if not wrote_ok or write_err != OK:
		DirAccess.remove_absolute(tmp)
		return ERR_FILE_CANT_WRITE
	var dir := DirAccess.open(exe_dir)
	if dir == null:
		DirAccess.remove_absolute(tmp)
		return ERR_CANT_OPEN
	# Never destroy the live cfg before the replacement is proven in place
	# (see _static_write_cfg_atomic). Windows DirAccess.rename() won't
	# overwrite: park as .old, promote the .tmp, drop the .old.
	var bak := path + ".old"
	var had_existing := FileAccess.file_exists(path)
	if had_existing:
		if FileAccess.file_exists(bak):
			DirAccess.remove_absolute(bak)
		var park_err := dir.rename(path.get_file(), bak.get_file())
		if park_err != OK:
			# Could not park the live cfg (AV lock?); caller falls back to single-pass.
			DirAccess.remove_absolute(tmp)
			return park_err
	var err := dir.rename(tmp.get_file(), path.get_file())
	if err != OK:
		DirAccess.remove_absolute(tmp)
		if had_existing:
			# Restore the previous cfg; if that rename fails too, byte-copy.
			if dir.rename(bak.get_file(), path.get_file()) != OK:
				DirAccess.copy_absolute(bak, path)
		return err
	if had_existing and FileAccess.file_exists(bak):
		DirAccess.remove_absolute(bak)
	return err

func _persist_hook_pack_state(pack_path: String, wrapped_paths: PackedStringArray = PackedStringArray()) -> void:
	# Record hook_pack_path + wrapped_paths in pass_state for next session's
	# static-init mount/preempt. Loads first so other keys survive.
	var cfg := ConfigFile.new()
	cfg.load(PASS_STATE_PATH)  # OK if missing; we populate below
	cfg.set_value("state", "hook_pack_path", pack_path)
	cfg.set_value("state", "hook_pack_wrapped_paths", wrapped_paths)
	# Seed exe_mtime only when missing: Pass 1 persists the hook pack before
	# _write_pass_state runs, and _write_pass_state's value is authoritative.
	if _state_int(cfg, "exe_mtime", 0) == 0:
		cfg.set_value("state", "exe_mtime", FileAccess.get_modified_time(OS.get_executable_path()))
	if _state_str(cfg, "modloader_version", "") == "":
		cfg.set_value("state", "modloader_version", MODLOADER_VERSION)
	if cfg.save(PASS_STATE_PATH) == OK:
		_log_info("[RTVCodegen] Persisted hook pack path for next-session static-init mount: %s (%d wrapped path(s))" \
				% [pack_path.get_file(), wrapped_paths.size()])

func _write_pass_state(archive_paths: PackedStringArray, state_hash: String = "") -> Error:
	var cfg := ConfigFile.new()
	cfg.load(PASS_STATE_PATH)
	var count := _state_int(cfg, "restart_count", 0)
	cfg.set_value("state", "restart_count", count + 1)
	# Mirror the attempt into the durable streak, which survives the
	# crashed-Pass-2 wipe and is what _crash_breaker_tripped reads.
	_static_write_crash_streak(_static_read_crash_streak() + 1)
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

# mtime to fold into the state hash. A folder mod's temp zip is rewritten
# every launch, so its own mtime would flap the hash and force a restart every
# launch; use the source folder's content mtime instead.
func _stable_path_mtime(p: String) -> int:
	var tmp_dir := ProjectSettings.globalize_path(TMP_DIR)
	if p.begins_with(tmp_dir) and p.ends_with("_dev.zip"):
		var folder_name := p.get_file().trim_suffix("_dev.zip")
		var folder := _mods_dir.path_join(folder_name)
		if DirAccess.dir_exists_absolute(folder):
			# Newest-mtime alone misses deletions and older-mtime replacements;
			# fold in file count and a per-file path+mtime hash.
			var stats := { "count": 0, "set_hash": 0 }
			var newest := _folder_recursive_mtime(folder, stats)
			return hash([newest, stats["count"], stats["set_hash"]])
	return FileAccess.get_modified_time(p)

# Newest file mtime under a folder. The optional stats accumulator gathers
# file count and an order-independent XOR of per-file path@mtime hashes.
func _folder_recursive_mtime(folder: String, stats: Dictionary = {}) -> int:
	var newest := 0
	var dir := DirAccess.open(folder)
	if dir == null:
		return newest
	dir.list_dir_begin()
	var name := dir.get_next()
	while name != "":
		if name != "." and name != "..":
			var child := folder.path_join(name)
			if dir.current_is_dir():
				newest = maxi(newest, _folder_recursive_mtime(child, stats))
			else:
				var mtime := FileAccess.get_modified_time(child)
				newest = maxi(newest, mtime)
				stats["count"] = int(stats.get("count", 0)) + 1
				stats["set_hash"] = int(stats.get("set_hash", 0)) ^ ("%s@%d" % [child, mtime]).hash()
		name = dir.get_next()
	dir.list_dir_end()
	return newest

func _compute_state_hash(archive_paths: PackedStringArray, prepend_autoloads: Array[Dictionary]) -> String:
	if archive_paths.is_empty() and prepend_autoloads.is_empty():
		return ""
	var parts := PackedStringArray()
	var sorted_paths := Array(archive_paths)
	sorted_paths.sort()
	for p in sorted_paths:
		# Include mtime so replacing a file with the same name triggers a restart.
		parts.append("a:%s@%d" % [p, _stable_path_mtime(p)])
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
	# Include modloader.gd's mtime so a loader rebuild forces a restart.
	# _finish_with_existing_mounts would otherwise regenerate the hook pack
	# under an existing mount; load_resource_pack dedupes by path, the VFS
	# keeps stale file offsets, and reads of moved entries fail
	# (file_access_zip.cpp:141). A fresh engine mounts a fresh index.
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
		var count := _state_int(cfg, "restart_count", 0)
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
		if fname.ends_with(".zip.src"):
			# vmz cache sidecar (see _static_vmz_to_zip): remove when its zip
			# is gone.
			if not FileAccess.file_exists(cache_dir.path_join(fname.trim_suffix(".src"))):
				DirAccess.remove_absolute(cache_dir.path_join(fname))
				_log_debug("Removed orphan cache sidecar: " + fname)
			continue
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
		var sidecar := cache_dir.path_join(fname + ".src")
		if FileAccess.file_exists(sidecar):
			DirAccess.remove_absolute(sidecar)
		_log_debug("Removed stale cache: " + fname)
	dir.list_dir_end()

func _restore_clean_override_cfg() -> void:
	var exe_dir := OS.get_executable_path().get_base_dir()
	var path := exe_dir.path_join("override.cfg")
	var preserved := _read_preserved_cfg_sections(path)
	if not _static_write_cfg_atomic(path, _clean_override_cfg_content(preserved)):
		_log_critical("Cannot write override.cfg -- game dir may be read-only: " + exe_dir)

func _clear_restart_counter() -> void:
	# Clear the durable streak unconditionally: a clean finish after the crash
	# wipe has no pass state, so folding this into the guarded path below
	# would leave the streak set forever.
	_static_write_crash_streak(0)
	var cfg := ConfigFile.new()
	if cfg.load(PASS_STATE_PATH) == OK:
		# Skip the save when already 0; this runs every launch on the
		# hash-match fast path.
		if _state_int(cfg, "restart_count", 0) == 0:
			return
		cfg.set_value("state", "restart_count", 0)
		cfg.save(PASS_STATE_PATH)
