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
##      same full wipe, mount nothing.
##   3. Load PASS_STATE_PATH. Missing or empty pass state -> mount
##      nothing. Modloader-version mismatch, changed exe mtime (game
##      updated), or any recorded archive now missing -> reset
##      override.cfg + delete pass state (version/mtime mismatches also
##      wipe the hook cache), mount nothing. This launch may log
##      autoload-load errors (Godot read override.cfg before we ran);
##      the NEXT launch boots clean.
##   4. Mount every archive the previous session recorded, then the hook
##      pack on top (replace_files=true), then preempt the wrapped
##      class_name scripts via CACHE_MODE_IGNORE + take_over_path.
## Static init logs via _write_filescope_log to
## user://modloader_filescope.log -- the instance log helpers do not
## exist yet at this point.
##
## Stage 1 -- _ready (lifecycle.gd). Dispatch: "--modloader-restart" in
## the user cmdline args -> _run_pass_2, else _run_pass_1.
##
## Pass 1 (fresh launch): _check_crash_recovery + _check_safe_mode,
## discover mods, show the launcher UI (show_mod_ui -- the only place
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
## script overrides from pass state, clears restart_count, re-runs
## discovery + load_all_mods + hook pack generate/activate, instantiates
## autoloads, deletes the heartbeat, clears the dirty marker. Never
## shows the UI.
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
##     _check_crash_recovery warns, and once restart_count reaches
##     MAX_RESTART_COUNT it resets override.cfg + pass state to break
##     the restart loop. restart_count is cleared early in Pass 2, so
##     crashes later in Pass 2 are covered by the dirty marker instead.
##   - Pass 2 after the dirty marker: next static init force-wipes state
##     (step 2 above); the launch after that regenerates fresh.
##   - While DISABLED_ONCE_FILE is pending: the sentinel persists until
##     a _ready runs, so a crash keeps the next launch vanilla -- an
##     intentional fail-safe.

static func _is_modloader_disabled() -> bool:
	# Check for sentinel files in the game exe directory. When either is
	# present, ModLoader skips all work: no archives mount, no UI shows, no
	# autoloads instantiate.
	#
	# DISABLED_FILE: persistent escape hatch; user removes it manually.
	# DISABLED_ONCE_FILE: written by the UI's "Launch Vanilla" button. The
	# modloader's _ready clears it after detection so subsequent launches go
	# through the normal flow. If the game crashes before _ready runs, the
	# file persists and the next launch is also vanilla -- intentional
	# fail-safe.
	var exe_dir := OS.get_executable_path().get_base_dir()
	if FileAccess.file_exists(exe_dir.path_join(DISABLED_FILE)):
		return true
	return FileAccess.file_exists(exe_dir.path_join(DISABLED_ONCE_FILE))

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

# The canonical clean override.cfg content. Boot-order correctness depends on
# this exact layout ([autoload_prepend] with ModLoader as the only entry, an
# empty [autoload], then any preserved non-modloader sections) -- all three
# reset paths must write byte-identical content.
static func _clean_override_cfg_content(preserved: String) -> String:
	return "[autoload_prepend]\nModLoader=\"*" + MODLOADER_RES_PATH + "\"\n\n[autoload]\n\n" + preserved

# Atomic override.cfg writer for the RESET paths. Opening the live file with
# FileAccess.WRITE truncates it instantly, so a crash/power-loss/disk-full
# between open and close bricks the loader permanently (no override.cfg ->
# the ModLoader autoload never loads again -> nothing can self-heal; see the
# same invariant in _write_override_cfg). Mirror its tmp -> park .old ->
# promote -> restore-on-failure dance; static so the static-init reset paths
# can use it. Returns false with the live file untouched (or restored) on
# any failure.
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
			dir.rename(bak.get_file(), cfg_path.get_file())
		return false
	if FileAccess.file_exists(bak):
		DirAccess.remove_absolute(bak)
	return true

static func _mount_previous_session() -> Dictionary:
	var mounted: Dictionary = {}
	var log_lines: PackedStringArray = []
	log_lines.append("[FileScope] _mount_previous_session() starting")
	# Log the runtime engine version unconditionally, once, at loader startup
	# (this static init runs on every launch, on every early-return path) so
	# every user log answers "which Godot is this game actually running"
	# before triage starts. See GODOT_47_COMPAT.md item 7.
	var vinfo := Engine.get_version_info()
	log_lines.append("[FileScope] Engine: Godot %s, modloader %s, os %s" \
			% [str(vinfo.get("string", "")), MODLOADER_VERSION, OS.get_name()])

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
		# Wipe hook cache along with pass state. Rewriter output semantics
		# may have changed across versions (e.g. 3.0.0 -> 3.0.1 changed the
		# opt-in gate + per-method wrap mask shape); any stale framework_pack
		# still on disk must not get mounted. Pass 1 regenerates a fresh
		# pack from the current modlist. Mirrors the exe_mtime wipe below.
		_static_wipe_hook_cache()
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
	for path in paths:
		var abs_path := path if not path.begins_with("res://") and not path.begins_with("user://") \
				else ProjectSettings.globalize_path(path)
		if FileAccess.file_exists(abs_path):
			log_lines.append("[FileScope]   EXISTS: " + abs_path)
			continue
		# Source gone -- treat as MISSING even if a same-basename cache zip
		# survived. Mounting a stale cache here (for a deleted .vmz, or one
		# replaced by a .zip of the same basename) lets Godot resolve the prior
		# session's autoloads through old content before Pass 1 can mount the
		# replacement. The any_missing branch below clears override.cfg +
		# pass_state so this launch logs autoload-load failures and Pass 1
		# rediscovers fresh state.
		log_lines.append("[FileScope]   MISSING: " + abs_path)
		any_missing = true

	if any_missing:
		log_lines.append("[FileScope] Archive(s) missing -- resetting to clean state")
		# Archive source gone. Wipe override.cfg autoload sections so the next
		# boot is clean, but preserve any non-autoload settings ([display], etc.).
		# Also fires when the source .vmz/.zip/.pck is gone but a same-basename
		# cache survived -- we no longer honor that cache (see comment above the
		# MISSING log) so the user's swap takes effect immediately.
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
	if not _static_write_cfg_atomic(cfg_path, _clean_override_cfg_content(preserved)):
		log_lines.append("[FileScope] WARNING: could not rewrite override.cfg (read-only?) -- live file left untouched")
		return
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

# Delete the contents of a one-level-deep directory: every top-level file, and
# every file one level inside each immediate subdirectory, then the subdir
# itself. Does NOT remove dir_path. No-op if dir_path is missing/unopenable.
# Hidden-file handling follows DirAccess defaults. Only suitable for trees
# that are guaranteed one level deep (the vanilla script cache: Scripts/*.gd);
# deeper trees (early autoloads) use _wipe_early_autoload_tree instead.
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
	# _ensure_early_autoload_on_disk mirrors each script's full res:// relative
	# path (e.g. MyMod/Scripts/Auto.gd = depth 3), so the tree can be
	# arbitrarily deep and a shallow wipe leaves stale scripts behind. Wipe it
	# recursively; the helper refuses to run outside the modloader_early prefix.
	_wipe_early_autoload_tree(ProjectSettings.globalize_path(EARLY_AUTOLOAD_DIR))

# Recursive delete of everything under dir_path, restricted to the
# modloader-managed early-autoload directory (EARLY_AUTOLOAD_DIR). Refuses any
# path outside that prefix so a bad argument can never recurse through user
# data. Does NOT remove the root directory itself. No-op if dir_path is
# missing/unopenable.
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
	# Same pick as load_all_mods (order + dependency filter) so the file-scope
	# mount order can never disagree with the runtime load order.
	var candidates: Array[Dictionary] = _loadable_enabled_entries(false, true)["loadable"]
	for c in candidates:
		if c["ext"] == "folder":
			# Folder mods are zipped to a temp cache during load_all_mods().
			# Store the temp zip path -- the folder itself can't be mounted.
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
	# store_string returns bool since Godot 4.3; if the write failed (e.g.
	# disk full) the tmp is truncated and must never be promoted over the
	# good live override.cfg below.
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
	# Never destroy the live override.cfg before the replacement is proven in
	# place -- without override.cfg the modloader autoload never loads again,
	# so nothing can self-heal. Windows DirAccess.rename() won't overwrite, so:
	# park the current file as .old, promote the .tmp, then drop the .old.
	# On any failure, restore the .old so the loader stays bootable.
	var bak := path + ".old"
	var had_existing := FileAccess.file_exists(path)
	if had_existing:
		if FileAccess.file_exists(bak):
			DirAccess.remove_absolute(bak)
		var park_err := dir.rename(path.get_file(), bak.get_file())
		if park_err != OK:
			# Could not move the live cfg aside (e.g. AV share lock). Leave it
			# untouched and report failure; the caller falls back to single-pass.
			DirAccess.remove_absolute(tmp)
			return park_err
	var err := dir.rename(tmp.get_file(), path.get_file())
	if err != OK:
		DirAccess.remove_absolute(tmp)
		if had_existing:
			# Put the previous cfg back so the next launch still loads the
			# modloader. If the rename back fails too, fall back to a byte copy.
			if dir.rename(bak.get_file(), path.get_file()) != OK:
				DirAccess.copy_absolute(bak, path)
		return err
	if had_existing and FileAccess.file_exists(bak):
		DirAccess.remove_absolute(bak)
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

# mtime to fold into the state hash for one archive path. A folder mod is
# re-zipped to <TMP_DIR>/<folder>_dev.zip on every launch, so the zip's own
# mtime changes every time even when the dev edited nothing -- which made the
# hash flap and forced a full two-pass restart EVERY launch with any folder
# mod enabled. For those temp zips, use the SOURCE folder's newest-file mtime
# instead, which only moves when the dev actually changes something.
func _stable_path_mtime(p: String) -> int:
	var tmp_dir := ProjectSettings.globalize_path(TMP_DIR)
	if p.begins_with(tmp_dir) and p.ends_with("_dev.zip"):
		var folder_name := p.get_file().trim_suffix("_dev.zip")
		var folder := _mods_dir.path_join(folder_name)
		if DirAccess.dir_exists_absolute(folder):
			# The newest-file mtime alone misses deletions and replacing a
			# file with an older-mtime copy, so fold in the file count and a
			# per-file path+mtime hash gathered on the same walk. Any change
			# to the folder's file set or timestamps moves the state hash.
			var stats := { "count": 0, "set_hash": 0 }
			var newest := _folder_recursive_mtime(folder, stats)
			return hash([newest, stats["count"], stats["set_hash"]])
	return FileAccess.get_modified_time(p)

# Newest file mtime anywhere under a folder (recursive). Folder mods are small
# dev trees, so the walk is cheap. The optional stats accumulator gathers the
# file count and an order-independent XOR of per-file "path@mtime" hashes on
# the same walk, so callers can detect deletions/renames/timestamp downgrades
# that the max-mtime alone cannot see.
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
		if fname.ends_with(".zip.src"):
			# Sidecar recording the source mtime+size of a vmz cache zip
			# (see _static_vmz_to_zip). Remove it when its zip is gone so
			# orphans don't accumulate; sidecars whose zip gets removed
			# below are deleted alongside it there.
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
	var cfg := ConfigFile.new()
	if cfg.load(PASS_STATE_PATH) == OK:
		cfg.set_value("state", "restart_count", 0)
		cfg.save(PASS_STATE_PATH)
