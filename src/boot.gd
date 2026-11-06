## Static init: mounts the previous session's archives and hook pack before _ready.
## Static helpers only, since the autoload instance is still being constructed.

# Keyed by archive path; _process_mod_candidate skips these mounts.
var _filescope_mounted: Dictionary = _mount_previous_session()

static func _static_exe_dir() -> String:
	return OS.get_executable_path().get_base_dir()

static func _override_cfg_path() -> String:
	return _static_exe_dir().path_join("override.cfg")

# Delete the file at a user:// or absolute path if it is there; true when it was.
static func _static_remove_file(path: String) -> bool:
	var abs_path := ProjectSettings.globalize_path(path)
	if not FileAccess.file_exists(abs_path):
		return false
	DirAccess.remove_absolute(abs_path)
	return true

# Small marker and counter files; false when the file could not be opened.
static func _write_text(path: String, text: String) -> bool:
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return false
	f.store_string(text)
	f.close()
	return true

static func _is_modloader_disabled() -> bool:
	var exe_dir := _static_exe_dir()
	if FileAccess.file_exists(exe_dir.path_join(DISABLED_FILE)):
		return true
	return FileAccess.file_exists(exe_dir.path_join(DISABLED_ONCE_FILE))

# Never touches CRASH_STREAK_PATH, which counts this very event.
static func _static_force_vanilla_state(reason: String, log_lines: PackedStringArray) -> void:
	log_lines.append("[FileScope] RESET (%s): forcing vanilla state" % reason)
	_reset_cfg_if_present(log_lines)
	var wiped := "hook pack, early autoloads"
	if _static_remove_file(PASS_STATE_PATH):
		wiped += ", pass state"
	if _static_remove_file(PASS2_DIRTY_PATH):
		wiped += ", pass2 dirty marker"
	_static_wipe_hook_cache()
	# Godot read override.cfg before this ran: the extracted early autoloads load unless deleted.
	_remove_tree(ProjectSettings.globalize_path(EARLY_AUTOLOAD_DIR), false)
	log_lines.append("[FileScope] RESET (%s): wiped %s" % [reason, wiped])

# [autoload_prepend] inserts in reverse, so ModLoader, written last, loads first;
# in plain [autoload] the game's autoloads would pin their bytecode first.
static func _override_cfg_text(prepend_lines: PackedStringArray, preserved: String) -> String:
	var lines := PackedStringArray(["[autoload_prepend]"])
	lines.append_array(prepend_lines)
	lines.append('ModLoader="*' + MODLOADER_RES_PATH + '"')
	return "\n".join(lines) + "\n\n[autoload]\n\n" + preserved

# Why the last _static_write_cfg_atomic failed, for the caller's log line.
static var _static_cfg_write_error := ""

# Losing override.cfg means the ModLoader autoload never loads again, so the
# live file is never opened for write: tmp, park .old, promote, restore.
static func _static_write_cfg_atomic(cfg_path: String, content: String) -> bool:
	_static_cfg_write_error = ""
	var tmp := cfg_path + ".tmp"
	var f := FileAccess.open(tmp, FileAccess.WRITE)
	if f == null:
		_static_cfg_write_error = "could not create %s, error %d" % [tmp.get_file(), FileAccess.get_open_error()]
		return false
	var ok := f.store_string(content)
	var werr := f.get_error()
	f.close()
	if not ok or werr != OK:
		_static_cfg_write_error = "could not write %s, error %d" % [tmp.get_file(), werr]
		DirAccess.remove_absolute(tmp)
		return false
	var bak := cfg_path + ".old"
	var dir := DirAccess.open(cfg_path.get_base_dir())
	if dir == null:
		_static_cfg_write_error = "could not open the folder, error %d" % DirAccess.get_open_error()
		DirAccess.remove_absolute(tmp)
		return false
	if FileAccess.file_exists(cfg_path):
		_static_remove_file(bak)
		var park_err := dir.rename(cfg_path.get_file(), bak.get_file())
		if park_err != OK:
			# An antivirus lock can hold the live file; leave it untouched.
			_static_cfg_write_error = "could not move the current %s aside, error %d" % [cfg_path.get_file(), park_err]
			DirAccess.remove_absolute(tmp)
			return false
	var place_err := dir.rename(tmp.get_file(), cfg_path.get_file())
	if place_err != OK:
		_static_cfg_write_error = "could not move %s into place, error %d" % [tmp.get_file(), place_err]
		DirAccess.remove_absolute(tmp)
		if FileAccess.file_exists(bak):
			# If the rename back fails too, byte-copy so a live cfg always exists.
			if dir.rename(bak.get_file(), cfg_path.get_file()) != OK:
				DirAccess.copy_absolute(bak, cfg_path)
		return false
	_static_remove_file(bak)
	return true

# Pass state is hand-editable: a wrong type reads as its default instead of
# aborting the static initializer.
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

static func _static_game_pck_path() -> String:
	var exe_path := OS.get_executable_path()
	var exe_dir := exe_path.get_base_dir()
	for cand in ["RTV.pck", exe_path.get_file().get_basename() + ".pck"]:
		var p := exe_dir.path_join(cand)
		if FileAccess.file_exists(p):
			return p
	return ""

# "<mtime>:<size>", or "". A content patch can replace the PCK and leave the
# executable untouched, so game-update detection keys on both.
static func _static_game_pck_stamp(pck_path: String) -> String:
	if pck_path == "" or not FileAccess.file_exists(pck_path):
		return ""
	var f := FileAccess.open(pck_path, FileAccess.READ)
	if f == null:
		return ""
	var size := f.get_length()
	f.close()
	return "%d:%d" % [FileAccess.get_modified_time(pck_path), size]

# A value missing on either side reads as unchanged.
static func _static_game_build_changed(cfg: ConfigFile, exe_mtime: int, pck_stamp: String) -> bool:
	var saved_exe_mtime := _state_int(cfg, "exe_mtime", 0)
	# 0 on the current side is a stat failure (antivirus holding the file), not a new build.
	if saved_exe_mtime != 0 and exe_mtime != 0 and saved_exe_mtime != exe_mtime:
		return true
	var saved_pck_stamp := _state_str(cfg, "pck_stamp", "")
	return saved_pck_stamp != "" and pck_stamp != "" and saved_pck_stamp != pck_stamp

static func _mount_previous_session() -> Dictionary:
	var mounted: Dictionary = {}
	var log_lines: PackedStringArray = []
	log_lines.append("[FileScope] _mount_previous_session() starting")
	var vinfo := Engine.get_version_info()
	log_lines.append("[FileScope] Engine: Godot %s, modloader %s, os %s" \
			% [str(vinfo["string"]), MODLOADER_VERSION, OS.get_name()])

	if _is_modloader_disabled():
		_static_force_vanilla_state("modloader_disabled sentinel", log_lines)
		return _finish_mount_log(log_lines, mounted)

	if FileAccess.file_exists(PASS2_DIRTY_PATH):
		_static_force_vanilla_state("pass 2 crashed mid-run", log_lines)
		return _finish_mount_log(log_lines, mounted)

	var cfg := ConfigFile.new()
	if cfg.load(PASS_STATE_PATH) != OK:
		log_lines.append("[FileScope] No pass state file -- skipping")
		return _finish_mount_log(log_lines, mounted)
	# Before the first mount: a mod that crashes while the engine builds the
	# autoloads never reaches _run_pass_2, and the breaker must still see it.
	if _static_mark_pass2_entered(OS.get_cmdline_user_args()):
		log_lines.append("[FileScope] Restart launch: pass 2 dirty marker written")
	# Godot read override.cfg before this ran, so the previous session's early
	# autoloads load anyway: the archives mount in every branch that continues.
	var stale_pack := _drop_stale_pack(cfg, log_lines)
	var paths := _state_paths(cfg, "archive_paths")
	if paths.is_empty():
		log_lines.append("[FileScope] Pass state has no archive paths -- skipping")
		return _finish_mount_log(log_lines, mounted)

	log_lines.append("[FileScope] %d archive path(s) in pass state" % paths.size())
	if _any_archive_missing(paths, log_lines):
		_reset_for_missing_archives(log_lines)
		return _finish_mount_log(log_lines, mounted)

	mounted = _static_mount_archives(paths, log_lines)
	if stale_pack:
		log_lines.append("[FileScope] Done -- %d archive(s) mounted, hook pack skipped (stale)" % mounted.size())
		return _finish_mount_log(log_lines, mounted)
	_static_mount_hook_pack(cfg, log_lines)
	log_lines.append("[FileScope] Done -- %d archive(s) mounted" % mounted.size())
	return _finish_mount_log(log_lines, mounted)

static func _finish_mount_log(log_lines: PackedStringArray, mounted: Dictionary) -> Dictionary:
	_write_filescope_log(log_lines)
	return mounted

# Another loader version or game build: wipe the hook pack and pass state and
# reset override.cfg. True when that happened.
static func _drop_stale_pack(cfg: ConfigFile, log_lines: PackedStringArray) -> bool:
	var saved_ver := _state_str(cfg, "modloader_version", "")
	if saved_ver != MODLOADER_VERSION:
		log_lines.append("[FileScope] Version mismatch: saved=%s current=%s -- dropping the hook pack and pass state" \
				% [saved_ver, MODLOADER_VERSION])
	elif _static_game_build_changed(cfg, FileAccess.get_modified_time(OS.get_executable_path()),
			_static_game_pck_stamp(_static_game_pck_path())):
		log_lines.append("[FileScope] Game build changed -- dropping the hook pack and pass state")
	else:
		return false
	_static_wipe_hook_cache()
	_static_remove_file(PASS_STATE_PATH)
	_reset_cfg_if_present(log_lines)
	return true

# A folder mod is recorded by its cache zip, which outlives the folder; a
# missing source folder counts as missing, or the deleted mod would mount once more.
static func _any_archive_missing(paths: PackedStringArray, log_lines: PackedStringArray) -> bool:
	var any_missing := false
	for path in paths:
		var abs_path := ProjectSettings.globalize_path(path)
		var present := FileAccess.file_exists(abs_path)
		var file_name := path.get_file()
		if present and file_name.ends_with("_dev.zip") \
				and (path.begins_with(TMP_DIR) or path.begins_with(ProjectSettings.globalize_path(TMP_DIR))):
			var folder := _static_exe_dir().path_join(MOD_DIR).path_join(file_name.trim_suffix("_dev.zip"))
			present = DirAccess.dir_exists_absolute(folder)
		if present:
			log_lines.append("[FileScope]   EXISTS: " + abs_path)
			continue
		log_lines.append("[FileScope]   MISSING: " + abs_path)
		any_missing = true
	return any_missing

static func _reset_for_missing_archives(log_lines: PackedStringArray) -> void:
	log_lines.append("[FileScope] Archive(s) missing -- resetting to clean state")
	if not _reset_override_cfg(_override_cfg_path()):
		log_lines.append("[FileScope] WARNING: could not rewrite override.cfg (%s) -- live file left untouched" \
				% _static_cfg_write_error)
	_static_remove_file(PASS_STATE_PATH)

static func _static_mount_archives(paths: PackedStringArray, log_lines: PackedStringArray) -> Dictionary:
	var mounted: Dictionary = {}
	for path in paths:
		if _try_mount_pack(path):
			log_lines.append("[FileScope]   MOUNTED: " + path)
			mounted[path] = true
		else:
			log_lines.append("[FileScope]   MOUNT FAILED: " + path)
	return mounted

# At static init because once class_cache pins a compiled reference, neither
# source_code+reload nor CACHE_MODE_IGNORE+take_over_path can replace it.
static func _static_mount_hook_pack(cfg: ConfigFile, log_lines: PackedStringArray) -> void:
	var hook_pack := _state_str(cfg, "hook_pack_path", "")
	# Windows cannot delete a mounted pack; sweep orphans before any mount.
	_static_cleanup_orphan_hook_packs(hook_pack, log_lines)
	if hook_pack == "":
		return
	# Pass state is user-editable: any other path would run arbitrary code before any mod loads.
	if not _pack_path_sane(hook_pack):
		log_lines.append("[FileScope] HOOK PACK path rejected (not a generated pack in "
				+ HOOK_PACK_DIR + "): " + hook_pack)
		return
	var hook_abs := ProjectSettings.globalize_path(hook_pack)
	if not FileAccess.file_exists(hook_abs):
		log_lines.append("[FileScope] HOOK PACK path in pass_state but file missing: " + hook_abs)
		return
	if not ProjectSettings.load_resource_pack(hook_abs, true):
		log_lines.append("[FileScope] HOOK PACK mount FAILED: " + hook_pack)
		return
	log_lines.append("[FileScope] HOOK PACK mounted at static init: " + hook_pack)
	_preempt_wrapped_scripts(hook_abs, _state_paths(cfg, "hook_pack_wrapped_paths"), log_lines)

# Scripts in the pack but not in wrapped_paths are left to lazy compile.
static func _preempt_wrapped_scripts(hook_abs: String, wrapped_paths: PackedStringArray,
		log_lines: PackedStringArray) -> void:
	var hzr := ZIPReader.new()
	if hzr.open(hook_abs) != OK:
		return
	var wrapped_set: Dictionary = {}
	for wp in wrapped_paths:
		wrapped_set[wp] = true
	var preloaded := 0
	var preload_failed := 0
	var failed_names := PackedStringArray()
	var skipped_lenient := 0
	for f: String in hzr.get_files():
		if not f.begins_with("Scripts/") or not f.ends_with(".gd"):
			continue
		var rpath := "res://" + f
		if not wrapped_set.has(rpath):
			skipped_lenient += 1
			continue
		var scr := ResourceLoader.load(rpath, "", ResourceLoader.CACHE_MODE_IGNORE) as GDScript
		# A script that fails to compile still loads with its source: only the method list tells.
		if scr == null or not _static_script_has_rewrite(scr):
			preload_failed += 1
			failed_names.append(f.get_file())
			continue
		scr.take_over_path(rpath)
		preloaded += 1
	hzr.close()
	log_lines.append("[FileScope] HOOK PACK preempted %d wrapped script(s) (%d failed, %d left to lazy compile)" \
			% [preloaded, preload_failed, skipped_lenient])
	if failed_names.size() > 0:
		log_lines.append("[FileScope] HOOK PACK: did not compile, left alone: " + ", ".join(failed_names))

# _run_pass_2 writes the marker again, but only static init sees a crash
# during autoload construction.
static func _static_mark_pass2_entered(user_args: PackedStringArray) -> bool:
	if not (RESTART_ARG in user_args):
		return false
	return _static_write_pass2_dirty()

static func _static_write_pass2_dirty() -> bool:
	return _write_text(PASS2_DIRTY_PATH, str(Time.get_unix_time_from_system()))

static func _static_script_has_rewrite(scr: GDScript) -> bool:
	return _static_method_list_has_rewrite(scr.get_script_method_list())

# A script's or a live node's method list.
static func _static_method_list_has_rewrite(methods: Array) -> bool:
	for m in methods:
		if str(m["name"]).begins_with(_RTV_VANILLA_PREFIX):
			return true
	return false

static func _reset_cfg_if_present(log_lines: PackedStringArray) -> void:
	var cfg_path := _override_cfg_path()
	if not FileAccess.file_exists(cfg_path):
		return
	if not _reset_override_cfg(cfg_path):
		log_lines.append("[FileScope] WARNING: could not rewrite override.cfg (%s) -- live file left untouched" \
				% _static_cfg_write_error)
		return
	log_lines.append("[FileScope] override.cfg reset to clean [autoload_prepend] state")

# Keeps the file's other sections.
static func _reset_override_cfg(cfg_path: String) -> bool:
	return _static_write_cfg_atomic(cfg_path, _override_cfg_text(PackedStringArray(), _read_preserved_cfg_sections(cfg_path)))

# Only a HOOK_PACK_PREFIX*.zip directly inside HOOK_PACK_DIR, the one shape Pass 1 writes.
static func _pack_path_sane(path: String) -> bool:
	if not path.begins_with(HOOK_PACK_DIR + "/"):
		return false
	if path.contains(".."):
		return false
	var rel := path.substr(HOOK_PACK_DIR.length() + 1)
	if rel.contains("/"):
		return false
	return rel.begins_with(HOOK_PACK_PREFIX) and rel.get_extension().to_lower() == "zip"

static func _static_cleanup_orphan_hook_packs(keep_path: String, log_lines: PackedStringArray) -> void:
	var keep_abs := ProjectSettings.globalize_path(keep_path) if keep_path != "" else ""
	var removed := _sweep_hook_packs(keep_abs)
	if removed > 0:
		log_lines.append("[FileScope] Cleaned %d orphan hook pack(s) from prior session(s)" % removed)

# Deletes every generated pack but keep_abs ("" keeps none); returns the count.
static func _sweep_hook_packs(keep_abs: String) -> int:
	var pack_dir := ProjectSettings.globalize_path(HOOK_PACK_DIR)
	if not DirAccess.dir_exists_absolute(pack_dir):
		return 0
	var dir := DirAccess.open(pack_dir)
	if dir == null:
		return 0
	dir.list_dir_begin()
	var removed := 0
	while true:
		var fname := dir.get_next()
		if fname == "":
			break
		if not fname.begins_with(HOOK_PACK_PREFIX) or not fname.ends_with(".zip"):
			continue
		var full := pack_dir.path_join(fname)
		if full == keep_abs:
			continue
		DirAccess.remove_absolute(full)
		removed += 1
	dir.list_dir_end()
	return removed

# Loose Framework*.gd hooks from loaders before the zip pack; nothing loads them.
static func _sweep_legacy_hooks() -> void:
	var pack_dir := ProjectSettings.globalize_path(HOOK_PACK_DIR)
	if not DirAccess.dir_exists_absolute(pack_dir):
		return
	var dir := DirAccess.open(pack_dir)
	if dir == null:
		return
	dir.list_dir_begin()
	while true:
		var fname := dir.get_next()
		if fname == "":
			break
		if fname.begins_with("Framework") and fname.ends_with(".gd"):
			DirAccess.remove_absolute(pack_dir.path_join(fname))
	dir.list_dir_end()

# Refused outside user:// and for user:// itself: a bad path join must never
# reach the saves or the game folder.
static func _remove_tree(dir_path: String, keep_root: bool) -> void:
	var target := ProjectSettings.globalize_path(dir_path).simplify_path()
	var user_root := ProjectSettings.globalize_path("user://").simplify_path()
	if target == user_root or not target.begins_with(user_root + "/"):
		push_warning("[ModLoader] Refusing to delete outside user://: " + dir_path)
		return
	# The root or an ancestor can be a link out of user://, just as a child can.
	var component := user_root
	for part in target.trim_prefix(user_root + "/").split("/"):
		var parent := DirAccess.open(component)
		component = component.path_join(part)
		if parent != null and parent.is_link(component):
			if component == target and not keep_root:
				DirAccess.remove_absolute(target)
			return
	if not DirAccess.dir_exists_absolute(target):
		return
	var dir := DirAccess.open(target)
	if dir == null:
		return
	dir.list_dir_begin()
	while true:
		var entry := dir.get_next()
		if entry == "":
			break
		if entry == "." or entry == "..":
			continue
		var full: String = target.path_join(entry)
		# A symlink or junction is removed as a link; descending would empty a
		# folder the user:// check never saw.
		if dir.current_is_dir() and not dir.is_link(full):
			_remove_tree(full, false)
		else:
			DirAccess.remove_absolute(full)
	dir.list_dir_end()
	if not keep_root:
		DirAccess.remove_absolute(target)

# A mounted zip may refuse deletion on Windows; the next static-init sweep gets it.
static func _static_wipe_hook_cache() -> void:
	_sweep_hook_packs("")
	_sweep_legacy_hooks()
	_remove_tree(ProjectSettings.globalize_path(VANILLA_CACHE_DIR), false)
