## Scans the mods folder into the launcher's entry dictionaries.

# A new extension also needs the vmz-style cache fallback on the mount side.
const MOD_ARCHIVE_EXTENSIONS: Array[String] = ["vmz", "zip", "pck"]

# The harnesses set _mods_dir to a user:// folder before the first scan.
func _mods_dir_path() -> String:
	if _mods_dir.is_empty():
		_mods_dir = _static_exe_dir().path_join(MOD_DIR)
	return _mods_dir

func collect_mod_metadata() -> Array[Dictionary]:
	var entries: Array[Dictionary] = []
	var mods_dir := _mods_dir_path()
	_log_info("Scanning mods dir: " + mods_dir)
	DirAccess.make_dir_recursive_absolute(mods_dir)
	var dir := DirAccess.open(mods_dir)
	if dir == null:
		_log_critical("Failed to open mods dir: %s (error %d)" % [mods_dir, DirAccess.get_open_error()])
		return entries
	var skipped_files: Array[String] = []
	_hidden_folder_profile_keys.clear()
	_hidden_folder_ids.clear()
	dir.list_dir_begin()
	while true:
		var entry_name := dir.get_next()
		if entry_name == "":
			break
		if dir.current_is_dir():
			if entry_name.begins_with("."):
				continue
			if _developer_mode:
				entries.append(_build_entry(mods_dir, entry_name, "folder"))
			else:
				_record_hidden_folder(mods_dir, entry_name)
			continue
		var ext := entry_name.get_extension().to_lower()
		if ext not in MOD_ARCHIVE_EXTENSIONS:
			skipped_files.append(entry_name)
			continue
		if ext == "zip" and _is_modpack_zip(mods_dir.path_join(entry_name)):
			_log_info("Treating %s as a modpack (root profile.json); remove that file to ship it as a mod" % entry_name)
			continue
		entries.append(_build_entry(mods_dir, entry_name, ext))
	dir.list_dir_end()
	if skipped_files.size() > 0:
		_log_debug("Skipped %d non-mod file(s) in mods dir:" % skipped_files.size())
		for sf in skipped_files:
			_log_debug("  " + sf + "  (not .vmz/.zip/.pck)")
	entries = _dedupe_by_mod_id(entries)
	_log_provides_notes(entries)
	_persist_mod_sources_for_entries(entries)
	if entries.size() == 0:
		_log_warning("No mods found in: " + mods_dir)
	else:
		_log_info("Found %d mod(s)" % entries.size())
		# Debug level: every apply, install and delete re-scans.
		for e in entries:
			var tag := " [folder]" if e["ext"] == "folder" else ""
			_log_debug("  " + e["file_name"] + " (" + e["mod_name"] + ")" + tag)
	return entries

func _build_entry(mods_dir: String, file_name: String, ext: String) -> Dictionary:
	# Logged before the read, so Godot's non-UTF8 warning can be tied to the mod.
	_log_debug("[ModScan] inspecting " + file_name + (" [folder]" if ext == "folder" else ""))
	var full_path := mods_dir.path_join(file_name)
	var read := _read_mod_txt(full_path, ext)
	var entry := _entry_from_config(read, file_name, full_path, ext)
	entry["warnings"] = _build_entry_warnings(entry, read["files"])
	entry["author_notes"] = _build_entry_author_notes(entry, read["files"])
	return entry

func _read_mod_txt(full_path: String, ext: String) -> Dictionary:
	if ext == "folder":
		return read_mod_config_folder(full_path)
	if ext == "pck":
		return _mod_txt_read("pck")
	return read_mod_config(full_path)

func _archive_profile_key(file_name: String, full_path: String) -> String:
	return _profile_key(_read_mod_txt(full_path, file_name.get_extension().to_lower())["cfg"], file_name)

# profiles.gd and modpacks.gd split on the first "@" and test "zip:"; saved profiles and
# [mod_sources] are keyed by it, so a change orphans user configs.
func _profile_key(cfg: ConfigFile, file_name: String) -> String:
	var id := str(cfg.get_value("mod", "id", "")) if cfg else ""
	if id.strip_edges() == "":
		return "zip:" + file_name
	# Raw on purpose: the key embeds the version as written.
	return id + "@" + str(cfg.get_value("mod", "version", ""))

# A folder mod hidden by dev mode off, so the orphan scan tells it from a deleted one.
func _record_hidden_folder(mods_dir: String, dir_name: String) -> void:
	var folder_path := mods_dir.path_join(dir_name)
	var read := _read_mod_txt(folder_path, "folder")
	var entry := _entry_from_config(read, dir_name, folder_path, "folder")
	_hidden_folder_profile_keys[entry["profile_key"]] = true
	if not entry["profile_key"].begins_with("zip:"):
		_hidden_folder_ids[entry["mod_id"]] = true
		for alias in entry["provides"]:
			_hidden_folder_ids[alias] = true

func _log_provides_notes(entries: Array[Dictionary]) -> void:
	var real_by_id: Dictionary = {}
	for e in entries:
		var k := _entry_mod_key(e)
		if k != "" and not real_by_id.has(k):
			real_by_id[k] = e
	var alias_owner: Dictionary = {}
	for e in entries:
		for raw_alias in e["provides"]:
			var ak := str(raw_alias).strip_edges().to_lower()
			if ak == "":
				continue
			if real_by_id.has(ak):
				_log_info("provides '%s' from %s is shadowed by %s while that mod is enabled"
						% [raw_alias, e["mod_name"], real_by_id[ak]["mod_name"]])
			elif alias_owner.has(ak):
				_log_warning("Both %s and %s declare provides '%s'; load order picks one"
						% [alias_owner[ak], e["file_name"], raw_alias])
			else:
				alias_owner[ak] = e["file_name"]

func _entry_from_config(read: Dictionary, file_name: String, full_path: String, ext: String) -> Dictionary:
	var cfg: ConfigFile = read["cfg"]
	# The stem names the mod by default, so a dependency on "CoolMod" finds
	# CoolMod.zip; a Vostok Mods "100-" prefix is stripped and is the fallback priority.
	var mod_name := file_name if ext == "folder" else file_name.get_basename()
	var priority := 0
	var m := _re_filename_priority.search(mod_name)
	if m:
		priority = int(m.get_string(1))
		mod_name = m.get_string(2)
	var mod_id := mod_name
	var version := ""
	var required_dependencies: Array[String] = []
	var optional_dependencies: Array[String] = []
	var provides: Array[String] = []
	if cfg:
		mod_name = str(cfg.get_value("mod", "name", mod_name))
		var declared := str(cfg.get_value("mod", "id", ""))
		if declared.strip_edges() != "":
			mod_id = declared
		version = str(cfg.get_value("mod", "version", ""))
		if cfg.has_section_key("mod", "priority"):
			priority = int(str(cfg.get_value("mod", "priority")))
		required_dependencies = _parse_dependency_list(cfg, "required")
		optional_dependencies = _parse_dependency_list(cfg, "optional")
		provides = _parse_provides_list(cfg, mod_id, file_name)
	priority = clampi(priority, PRIORITY_MIN, PRIORITY_MAX)
	return {
		"file_name": file_name, "full_path": full_path, "ext": ext,
		"mod_name": mod_name, "mod_id": mod_id, "version": version,
		"profile_key": _profile_key(cfg, file_name),
		"priority": priority, "priority_default": priority, "enabled": true,
		"required_dependencies": required_dependencies,
		"optional_dependencies": optional_dependencies,
		"provides": provides,
		"dependency_warnings": [], "dependency_blockers": [],
		"dependency_blockers_info": [], "dependency_ignored": false,
		"cfg": cfg, "mod_txt_status": str(read["status"]),
		"mod_txt_error": str(read["error"]),
		"has_registry": cfg != null and cfg.has_section("registry"),
	}

func _cfg_mod_id(cfg: ConfigFile) -> String:
	if cfg == null:
		return ""
	return str(cfg.get_value("mod", "id", "")).strip_edges().to_lower()

func _cfg_mod_version(cfg: ConfigFile) -> String:
	if cfg == null:
		return ""
	return str(cfg.get_value("mod", "version", "")).strip_edges()

func _build_entry_warnings(entry: Dictionary, mod_txt_files: Dictionary) -> Array[String]:
	var warnings: Array[String] = []
	var status: String = entry["mod_txt_status"]
	if entry["ext"] == "pck" or (entry["ext"] == "folder" and status != "parse_error"):
		return warnings
	if status != "ok":
		var problem := _mod_txt_problem(entry)
		if problem != "":
			warnings.append(problem)
		return warnings
	var cfg: ConfigFile = entry["cfg"]
	if not cfg.has_section("autoload"):
		return warnings
	for autoload_name: String in cfg.get_section_keys("autoload"):
		# Must resolve as mod_loading.gd does, or this warns about mods that load fine.
		var res_path: String = _split_autoload_marker(str(cfg.get_value("autoload", autoload_name, "")))[0]
		if res_path.is_empty() or mod_txt_files.has(res_path):
			continue
		for p: String in mod_txt_files:
			if p.get_file().to_lower() == res_path.get_file().to_lower():
				warnings.append("Autoload \"%s\" points at %s, which is not in this mod -- did you mean %s?" % [autoload_name, res_path, p])
				break
	return warnings

func _mod_txt_problem(entry: Dictionary) -> String:
	var status: String = entry["mod_txt_status"]
	if status == "none":
		return "Invalid mod -- may not work correctly. Try re-downloading."
	if status.begins_with("nested:"):
		return "Invalid mod -- mod.txt is in a subfolder, not at the zip root. Re-zip so mod.txt is at the root."
	if status != "parse_error":
		return ""
	if entry["mod_txt_error"] == "":
		return "Invalid mod -- mod.txt failed to parse. Try re-downloading."
	return "mod.txt parse error at " + entry["mod_txt_error"]

func _build_entry_author_notes(entry: Dictionary, mod_txt_files: Dictionary) -> Array[String]:
	var notes: Array[String] = []
	if entry["ext"] == "pck" or entry["ext"] == "folder":
		return notes
	# A .gd.remap sends the engine to the compiled .gdc, so edits to the .gd do
	# nothing; some mods ship the bake on purpose, hence a note, not a warning.
	var baked := 0
	for p: String in mod_txt_files:
		if p.ends_with(".gd.remap"):
			baked += 1
	if baked > 0:
		notes.append("Ships %d pre-compiled script%s (.gd.remap + .godot/exported). The game runs the compiled copy, not the .gd files in this archive, so source edits do nothing until you re-export. Delete .godot/ before packing, or re-export every time."
				% [baked, "" if baked == 1 else "s"])
	if entry["mod_txt_status"] != "ok":
		return notes
	if entry["profile_key"].begins_with("zip:"):
		notes.append("No id= in mod.txt, so this mod is identified by its filename. Renaming or re-packaging it loses its enabled state and load order, and two copies cannot be told apart. Add an id= line under [mod].")
	notes.append_array(_source_notes(entry["cfg"]))
	return notes

func _source_notes(cfg: ConfigFile) -> Array[String]:
	var notes: Array[String] = []
	if cfg.has_section_key("updates", "source"):
		var raw := str(cfg.get_value("updates", "source")).strip_edges()
		if _parse_source_token(raw).is_empty():
			var outcome := "This mod will not update or show where it came from."
			if _mod_source_from_cfg(cfg)["provider"] != "":
				outcome = "The modworkshop= line below it is used instead."
			notes.append("mod.txt has an unrecognized [updates] source=\"%s\". Use \"<provider>:<id>\" with a known provider (%s), e.g. \"modworkshop:12345\". %s" % [raw, ", ".join(HOST_PROVIDERS_KNOWN), outcome])
	elif cfg.has_section_key("updates", "modworkshop"):
		var legacy := str(cfg.get_value("updates", "modworkshop")).strip_edges()
		if not (legacy.is_valid_int() and legacy.to_int() > 0):
			notes.append("mod.txt [updates] modworkshop=\"%s\" is not a valid ModWorkshop id. This mod will not update." % legacy)
	var has_source := cfg.has_section_key("updates", "source") or cfg.has_section_key("updates", "modworkshop")
	if has_source and cfg.has_section_key("mod", "version") and typeof(cfg.get_value("mod", "version")) == TYPE_FLOAT:
		var as_num := str(cfg.get_value("mod", "version"))
		notes.append("mod.txt [mod] version is unquoted and was read as the number %s, which loses trailing zeros (1.10 becomes 1.1). Quote it: version = \"%s\"." % [as_num, as_num])
	return notes
