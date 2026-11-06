## What Pass 1 hands to the restarted process: override.cfg, pass state and the
## state hash. boot.gd reads them at the next static init.

func _build_autoload_sections() -> Dictionary:
	_remove_tree(ProjectSettings.globalize_path(EARLY_AUTOLOAD_DIR), true)
	var prepend: Array[Dictionary] = []
	var append: Array[Dictionary] = []
	for entry in _pending_autoloads:
		if entry["is_early"]:
			var path: String = entry["path"]
			var disk_path := _ensure_early_autoload_on_disk(path, entry["mod_name"])
			prepend.append({ "name": entry["name"], "path": disk_path })
		else:
			append.append({ "name": entry["name"], "path": entry["path"] })
	return { "prepend": prepend, "append": append }

# Godot opens [autoload_prepend] scripts before any archive is mounted, so an
# archive-only early autoload goes to disk. Scenes return as-is.
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
		# A truncated script would be compiled next boot.
		DirAccess.remove_absolute(target)
		_log_critical("Failed writing early autoload to disk: " + target + " [" + mod_name + "]")
		return res_path

	var user_path := EARLY_AUTOLOAD_DIR.path_join(rel)
	_log_info("  Extracted early autoload to disk: " + user_path + " [" + mod_name + "]")
	return user_path

# Same pick as load_all_mods, so the mount order matches the load order.
func _collect_enabled_archive_paths() -> PackedStringArray:
	var paths := PackedStringArray()
	var candidates: Array[Dictionary] = _loadable_enabled_entries()["loadable"]
	for c in candidates:
		if c["ext"] == "folder":
			var tmp_zip: String = _folder_dev_zip_path(c["full_path"])
			if FileAccess.file_exists(tmp_zip):
				paths.append(tmp_zip)
			else:
				_log_warning("Folder mod '%s' has no cached zip -- skipping from pass state"
						% c["mod_name"])
			continue
		paths.append(c["full_path"])
	return paths

# Both halves come from mod.txt: Godot stops applying override.cfg entries at
# the first bad line, and the ModLoader= line comes after the mod entries.
func _autoload_entry_writable(entry_name: String, entry_path: String) -> bool:
	# The autoload name becomes a singleton identifier.
	if not entry_name.is_valid_identifier():
		return false
	if not (entry_path.begins_with("res://") or entry_path.begins_with(EARLY_AUTOLOAD_DIR + "/")):
		return false
	# A quote closes the value early, a backslash starts an escape, a newline splits the entry.
	return not (entry_path.contains('"') or entry_path.contains("\\")
			or entry_path.contains("\n") or entry_path.contains("\r"))

func _write_override_cfg(prepend_autoloads: Array[Dictionary]) -> Error:
	var path := _override_cfg_path()
	var preserved := _read_preserved_cfg_sections(path)
	var lines := PackedStringArray()
	for entry in prepend_autoloads:
		var entry_name: String = entry["name"]
		var entry_path: String = entry["path"]
		if not _autoload_entry_writable(entry_name, entry_path):
			_log_warning("Skipping early autoload '%s' -> '%s': it would corrupt override.cfg" \
					% [entry_name, entry_path])
			continue
		lines.append('%s="*%s"' % [entry_name, entry_path])
	if not _static_write_cfg_atomic(path, _override_cfg_text(lines, preserved)):
		return ERR_FILE_CANT_WRITE
	return OK

# Loads first so the other keys survive; a missing file starts empty.
func _persist_hook_pack_state(pack_path: String, wrapped_paths: PackedStringArray) -> void:
	var cfg := ConfigFile.new()
	cfg.load(PASS_STATE_PATH)
	cfg.set_value("state", "hook_pack_path", pack_path)
	cfg.set_value("state", "hook_pack_wrapped_paths", wrapped_paths)
	# For the generations that must not probe (see _hook_pack_begin_vetting).
	cfg.set_value("state", "hook_pack_demotions", _hook_pack_demotions)
	# Pass 1 persists the pack before _write_pass_state, and a single-pass launch
	# writes none: without these keys the next static init drops the pack as stale.
	if _state_int(cfg, "exe_mtime", 0) == 0:
		cfg.set_value("state", "exe_mtime", FileAccess.get_modified_time(OS.get_executable_path()))
	if _state_str(cfg, "pck_stamp", "") == "":
		cfg.set_value("state", "pck_stamp", _game_pck_stamp())
	if _state_str(cfg, "modloader_version", "") == "":
		cfg.set_value("state", "modloader_version", MODLOADER_VERSION)
	if cfg.save(PASS_STATE_PATH) == OK and pack_path != "":
		_log_info("[RTVCodegen] Persisted hook pack path for next-session static-init mount: %s (%d wrapped path(s))" \
				% [pack_path.get_file(), wrapped_paths.size()])

func _write_pass_state(archive_paths: PackedStringArray, state_hash: String) -> Error:
	var cfg := ConfigFile.new()
	cfg.load(PASS_STATE_PATH)
	var count := _state_int(cfg, "restart_count", 0)
	cfg.set_value("state", "restart_count", count + 1)
	# The durable streak survives the crashed-Pass-2 wipe of this file.
	_static_write_crash_streak(_static_read_crash_streak() + 1)
	cfg.set_value("state", "mods_hash", state_hash)
	cfg.set_value("state", "archive_paths", archive_paths)
	cfg.set_value("state", "modloader_version", MODLOADER_VERSION)
	cfg.set_value("state", "exe_mtime", FileAccess.get_modified_time(OS.get_executable_path()))
	cfg.set_value("state", "pck_stamp", _game_pck_stamp())
	cfg.set_value("state", "timestamp", Time.get_unix_time_from_system())
	var override_data: Array = []
	for entry in _pending_script_overrides:
		override_data.append(entry.duplicate())
	cfg.set_value("state", "script_overrides", override_data)
	var err := cfg.save(PASS_STATE_PATH)
	if err != OK:
		_log_critical("Failed to save pass state (error %d)" % err)
	return err

# An mtime, or for a folder mod's temp zip (rewritten every launch) a hash of
# its source folder. _folder_dev_zip_stamp in fs_archive.gd stamps the zip cache with it.
func _stable_path_stamp(p: String) -> int:
	var tmp_dir := ProjectSettings.globalize_path(TMP_DIR)
	if p.begins_with(tmp_dir) and p.ends_with("_dev.zip"):
		var folder_name := p.get_file().trim_suffix("_dev.zip")
		var folder := _mods_dir.path_join(folder_name)
		if DirAccess.dir_exists_absolute(folder):
			# Newest mtime alone misses deletions; fold in file count and a per-file hash.
			var stats := { "count": 0, "set_hash": 0 }
			var newest := _folder_recursive_mtime(folder, stats)
			return hash([newest, stats["count"], stats["set_hash"]])
	return FileAccess.get_modified_time(p)

func _folder_recursive_mtime(folder: String, stats: Dictionary) -> int:
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
				stats["count"] += 1
				stats["set_hash"] = stats["set_hash"] ^ ("%s@%d" % [child, mtime]).hash()
		name = dir.get_next()
	dir.list_dir_end()
	return newest

func _compute_state_hash(archive_paths: PackedStringArray, prepend_autoloads: Array[Dictionary]) -> String:
	if archive_paths.is_empty() and prepend_autoloads.is_empty():
		return ""
	var parts := PackedStringArray()
	# Load order, not sorted: the last mount wins a shared file, so a priority
	# change has to change the hash.
	for p in archive_paths:
		parts.append("a:%s@%d" % [p, _stable_path_stamp(p)])
	for entry in prepend_autoloads:
		parts.append("p:%s=%s" % [entry["name"], entry["path"]])
	for entry in _ui_mod_entries:
		if entry["enabled"] and entry["cfg"] != null:
			# str(): an unquoted version arrives as a float.
			var ver := str((entry["cfg"] as ConfigFile).get_value("mod", "version", ""))
			if not ver.is_empty():
				parts.append("v:%s=%s" % [entry["mod_id"], ver])
	for entry in _pending_script_overrides:
		parts.append("so:%s=%s" % [entry["vanilla_path"], entry["mod_script_path"]])
	parts.append("ml:" + MODLOADER_VERSION)
	# A loader rebuild forces a restart: regenerating the pack under an existing
	# mount leaves stale offsets, and reads of moved entries fail.
	var self_mtime: int = FileAccess.get_modified_time("res://modloader.gd")
	if self_mtime > 0:
		parts.append("ml_mtime:%d" % self_mtime)
	return "\n".join(parts).md5_text()

# "" when the next process can start without the previous mod set.
func _clear_unmodded_boot_state(state_path: String = PASS_STATE_PATH, cfg_path: String = "") -> String:
	state_path = ProjectSettings.globalize_path(state_path)
	if FileAccess.file_exists(state_path) or DirAccess.dir_exists_absolute(state_path):
		var err := DirAccess.remove_absolute(state_path)
		if err != OK:
			return "Cannot remove %s (error %d). Check the file's permissions or whether another program has it open." % [state_path, err]
	if cfg_path.is_empty():
		cfg_path = _override_cfg_path()
	cfg_path = ProjectSettings.globalize_path(cfg_path)
	var current := ""
	if FileAccess.file_exists(cfg_path):
		var file := FileAccess.open(cfg_path, FileAccess.READ)
		if file == null:
			return "Cannot read %s (error %d). Check the game folder's permissions." % [cfg_path, FileAccess.get_open_error()]
		current = file.get_as_text()
		file.close()
	var clean := _override_cfg_text(PackedStringArray(), _read_preserved_cfg_sections(cfg_path))
	if current != clean and not _static_write_cfg_atomic(cfg_path, clean):
		return "Cannot write %s (%s). Check the game folder's permissions or whether another program has it open." % [cfg_path, _static_cfg_write_error]
	return ""

func _restore_clean_override_cfg() -> void:
	if not _reset_override_cfg(_override_cfg_path()):
		_log_critical("Cannot write override.cfg (%s) -- game dir may be read-only: %s" \
				% [_static_cfg_write_error, _static_exe_dir()])
