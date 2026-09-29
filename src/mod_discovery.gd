## Discover installed mods and build the launcher entry dictionaries.
## Metadata and author diagnostics live here; dependency, identity, source
## persistence and download rules live in the adjacent mod_*.gd files.

func collect_mod_metadata() -> Array[Dictionary]:
	var entries: Array[Dictionary] = []
	_mods_dir = OS.get_executable_path().get_base_dir().path_join(MOD_DIR)
	_log_info("Scanning mods dir: " + _mods_dir)
	DirAccess.make_dir_recursive_absolute(_mods_dir)
	var dir := DirAccess.open(_mods_dir)
	if dir == null:
		_log_critical("Failed to open mods dir: " + _mods_dir
				+ " (error " + str(DirAccess.get_open_error()) + ")")
		return entries
	var seen: Dictionary = {}
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
				if not seen.has(entry_name):
					seen[entry_name] = true
					entries.append(_build_folder_entry(_mods_dir, entry_name))
			else:
				# Record the profile_key so the orphan scan reads dev-filtered, not missing.
				_record_hidden_folder(_mods_dir, entry_name)
			continue
		var ext := entry_name.get_extension().to_lower()
		# Accept set; keep in sync with _is_safe_mod_filename. A new extension also
		# needs the vmz-style cache fallback on the mount side.
		if ext not in ["vmz", "zip", "pck"]:
			skipped_files.append(entry_name)
			continue
		if seen.has(entry_name):
			continue
		seen[entry_name] = true
		# Modpack zips share this folder; collect_modpack_metadata picks them up.
		if ext == "zip" and _is_modpack_zip(_mods_dir.path_join(entry_name)):
			_log_info("Treating " + entry_name + " as a modpack (profile.json at zip root), not a mod. It appears on the Modpacks tab. If this is meant to be a mod, remove profile.json from the archive root.")
			continue
		entries.append(_build_archive_entry(_mods_dir, entry_name, ext))
	dir.list_dir_end()
	if skipped_files.size() > 0:
		_log_debug("Skipped " + str(skipped_files.size()) + " non-mod file(s) in mods dir:")
		for sf in skipped_files:
			_log_debug("  " + sf + "  (not .vmz/.zip/.pck)")
	entries = _dedupe_by_mod_id(entries)
	_log_provides_notes(entries)
	# Persist scanned source ids so missing-mod stubs can offer Download later.
	_persist_mod_sources_for_entries(entries)
	if entries.size() == 0:
		_log_warning("No mods found in: " + _mods_dir)
	else:
		_log_info("Found " + str(entries.size()) + " mod(s)")
		# Debug-level: re-scans (apply/install/delete) would spam the log.
		for e in entries:
			var tag := " [folder]" if e["ext"] == "folder" else ""
			_log_debug("  " + e["file_name"] + " (" + e["mod_name"] + ")" + tag)
	return entries

func _build_archive_entry(mods_dir: String, file_name: String, ext: String) -> Dictionary:
	# Ties Godot's non-UTF8 warning to the mod that tripped it; debug so re-scans stay quiet.
	_log_debug("[ModScan] inspecting " + file_name)
	var full_path := mods_dir.path_join(file_name)
	# A .pck carries no mod.txt.
	var read: Dictionary = read_mod_config(full_path) if ext != "pck" else _mod_txt_read("pck")
	var entry := _entry_from_config(read, file_name, full_path, ext)
	entry["warnings"] = _build_entry_warnings(entry, read["files"])
	entry["author_notes"] = _build_entry_author_notes(entry, read["files"])
	entry["security_findings"] = scan_mod(full_path, ext)
	entry["risk_level"] = compute_risk_level(entry["security_findings"])
	_log_security_findings(entry)
	return entry

func _build_folder_entry(mods_dir: String, dir_name: String) -> Dictionary:
	_log_debug("[ModScan] inspecting " + dir_name + " [folder]")
	var folder_path := mods_dir.path_join(dir_name)
	var read := read_mod_config_folder(folder_path)
	var entry := _entry_from_config(read, dir_name, folder_path, "folder")
	entry["warnings"] = _build_entry_warnings(entry, read["files"])
	entry["author_notes"] = _build_entry_author_notes(entry, read["files"])
	entry["security_findings"] = scan_mod(folder_path, "folder")
	entry["risk_level"] = compute_risk_level(entry["security_findings"])
	_log_security_findings(entry)
	return entry

# A folder mod excluded by dev mode off, so the orphan scan can tell it from deleted.
func _record_hidden_folder(mods_dir: String, dir_name: String) -> void:
	var folder_path := mods_dir.path_join(dir_name)
	var read := read_mod_config_folder(folder_path)
	var entry := _entry_from_config(read, dir_name, folder_path, "folder")
	_hidden_folder_profile_keys[entry["profile_key"]] = true
	if not entry["profile_key"].begins_with("zip:"):
		_hidden_folder_ids[entry["mod_id"]] = true
		# Aliases too, so a dep naming the old id gets the same hint.
		for alias in entry.get("provides", []):
			_hidden_folder_ids[alias] = true

# Once-per-scan log lines for provides= aliases: an alias shadowed by a real
# installed id (second-pass rule in _entries_by_mod_id), and two mods
# claiming the same alias, where the warning names both and no winner.
func _log_provides_notes(entries: Array[Dictionary]) -> void:
	var real_by_id: Dictionary = {}
	for e in entries:
		var k := _entry_mod_key(e)
		if k != "" and not real_by_id.has(k):
			real_by_id[k] = e
	var alias_owner: Dictionary = {}
	for e in entries:
		for raw_alias in e.get("provides", []):
			var ak := str(raw_alias).strip_edges().to_lower()
			if ak == "":
				continue
			if real_by_id.has(ak):
				var real: Dictionary = real_by_id[ak]
				_log_info("provides alias '" + str(raw_alias) + "' from "
						+ str(e.get("mod_name", e.get("file_name", "?")))
						+ " is shadowed by installed mod "
						+ str(real.get("mod_name", real.get("file_name", "?")))
						+ " while that mod is enabled -- if it is disabled,"
						+ " the alias satisfies dependents in its place")
				continue
			if alias_owner.has(ak):
				_log_warning("Both " + str(alias_owner[ak]) + " and "
						+ str(e.get("file_name", "?")) + " declare provides '"
						+ str(raw_alias) + "' -- only one of them resolves"
						+ " that id, depending on load order")
			else:
				alias_owner[ak] = str(e.get("file_name", "?"))

# Findings are disclosures, not verdicts; debug-level since the row shows them.
func _log_security_findings(entry: Dictionary) -> void:
	var findings: Array = entry.get("security_findings", [])
	if findings.is_empty():
		return
	_log_debug("[ModScan] %s uses %d notable API(s)" \
			% [entry["file_name"], findings.size()])
	for f: Dictionary in findings:
		var loc: String = f["file"]
		if int(f.get("line", 0)) > 0:
			loc += ":" + str(f["line"])
		_log_debug("  %s @ %s -- %s" \
				% [f["rule"], loc, f.get("preview", "")])

# --- The entry dict -------------------------------------------------------
# Every element of _ui_mod_entries has this shape. The UI mutates enabled,
# priority and dependency_ignored in place, so every key is public shape.
# Written by _entry_from_config:
#   file_name, full_path  archive filename / absolute path; rewritten on an
#                         update rename
#   ext                   "vmz" | "zip" | "pck" | "folder"
#   mod_name, mod_id      display name and identity; both default to the
#                         filename stem with a VostokMods "NNN-" prefix stripped
#   version, author       raw [mod] values, may be ""
#   profile_key           identity in profile sections (contract at its construction)
#   priority              clamped PRIORITY_MIN..PRIORITY_MAX; per profile
#   priority_default      the mod.txt or filename-prefix priority, clamped; what
#                         a profile that stores none for this mod applies
#   enabled               per-profile, toggled in place by the UI
#   required_dependencies, optional_dependencies, provides   Array[String]
#   dependency_warnings, dependency_blockers (Array[String]) and
#   dependency_blockers_info ({id, status, display, fixable}, status one of
#                         not_installed | disabled | not_loaded | hidden_folder)
#                         are recomputed by _refresh_dependency_status
#   dependencies_satisfied  bool, write-only at HEAD
#   dependency_ignored    per-profile "Load anyway" override
#   cfg                   parsed mod.txt; null for .pck and unparseable archives
#   mod_txt_status        "ok" | "none" | "parse_error" | "nested:<path>" | "pck",
#                         the status of the read_mod_config record
#   mod_txt_error         parse-error detail from the same record
#   has_registry          mod.txt declares [registry]; drives the disable-time confirm
# Added by _build_archive_entry / _build_folder_entry: warnings (Array[String]),
# security_findings ({rule, file, line, preview}), risk_level (RISK_CLEAN | RISK_RED).
# Added by _dedupe_by_mod_id on a winner: duplicates_hidden ({file_name, version}).
# Added by profiles.gd _apply_profile_to_entries: profile_version_mismatch {stored, current}.
func _entry_from_config(read: Dictionary, file_name: String, full_path: String, ext: String) -> Dictionary:
	var cfg: ConfigFile = read["cfg"]
	var mod_name := file_name
	var mod_id   := file_name
	var version  := ""
	var author   := ""
	var priority := 0
	var has_mod_id := false
	var required_dependencies: Array[String] = []
	var optional_dependencies: Array[String] = []
	var provides: Array[String] = []

	# A VostokMods-style "100-ModName.vmz" prefix is stripped from the name and
	# id defaults and used as the fallback priority.
	var base_name := file_name.get_basename()  # strip extension
	var filename_priority := 0
	var has_filename_priority := false
	if _re_filename_priority:
		var m := _re_filename_priority.search(base_name)
		if m:
			filename_priority = int(m.get_string(1))
			base_name = m.get_string(2)
			has_filename_priority = true
			mod_name = base_name
			mod_id   = base_name

	if cfg:
		mod_name = str(cfg.get_value("mod", "name", mod_name))
		if cfg.has_section_key("mod", "id"):
			var declared := str(cfg.get_value("mod", "id"))
			if declared.strip_edges() != "":
				mod_id = declared
				has_mod_id = true
		version = str(cfg.get_value("mod", "version", ""))
		author = str(cfg.get_value("mod", "author", ""))
		if cfg.has_section_key("mod", "priority"):
			priority = int(str(cfg.get_value("mod", "priority")))
		elif has_filename_priority:
			priority = filename_priority
		required_dependencies = _parse_dependency_list(cfg, "required")
		optional_dependencies = _parse_dependency_list(cfg, "optional")
		provides = _parse_provides_list(cfg, mod_id, file_name)
	elif has_filename_priority:
		priority = filename_priority
	priority = clampi(priority, PRIORITY_MIN, PRIORITY_MAX)

	# Profile key identifies the mod across zip renames: "<id>@<version>" when
	# mod.txt declares an id (empty version allowed), else "zip:<file_name>".
	# Parsers live far from here; keep in sync when changing:
	#   - the "@" split (first "@") in profiles.gd _version_from_profile_key and
	#     _missing_mods_in_active_profile, modpacks.gd _get_missing_mods_for_modpack,
	#     and the mod_id + "@" prefix match in _apply_profile_to_entries;
	#   - the "zip:" prefix tests and trim_prefix("zip:") in profiles.gd;
	#   - the [mod_sources] cache and per-profile sections keyed by it, so a
	#     format change invalidates existing user configs.
	var profile_key := ("zip:" + file_name) if not has_mod_id else (mod_id + "@" + version)

	var entry := {
		"file_name": file_name, "full_path": full_path, "ext": ext,
		"mod_name": mod_name, "mod_id": mod_id, "version": version,
		"author": author,
		"profile_key": profile_key,
		"priority": priority, "priority_default": priority, "enabled": true,
		"required_dependencies": required_dependencies,
		"optional_dependencies": optional_dependencies,
		"provides": provides,
		"dependency_warnings": [], "dependency_blockers": [],
		"dependency_blockers_info": [], "dependency_ignored": false,
		"dependencies_satisfied": true,
		"cfg": cfg, "mod_txt_status": str(read["status"]),
		"mod_txt_error": str(read["error"]),
		"has_registry": cfg != null and cfg.has_section("registry"),
	}
	return entry

# `mod_txt_files` is the archive file set from the entry's read_mod_config record.
func _build_entry_warnings(entry: Dictionary, mod_txt_files: Dictionary) -> Array[String]:
	var warnings: Array[String] = []
	var ext: String = entry["ext"]
	if ext == "pck":
		return warnings
	var status: String = entry.get("mod_txt_status", "none")
	if ext == "folder":
		# A developer's own folder. The archive-shape checks do not apply, but a
		# mod.txt that does not parse is what its author needs to see.
		if status == "parse_error":
			warnings.append(_mod_txt_parse_warning(entry))
		return warnings
	if status == "none":
		warnings.append("Invalid mod -- may not work correctly. Try re-downloading.")
	elif status == "parse_error":
		warnings.append(_mod_txt_parse_warning(entry))
	elif status.begins_with("nested:"):
		warnings.append("Invalid mod -- mod.txt is in a subfolder, not at the zip root. Re-zip so mod.txt is at the root.")
	elif status == "ok":
		warnings.append_array(_autoload_path_warnings(entry, mod_txt_files))
	return warnings

# Names the line and section so an author can fix their own mod.txt typo.
func _mod_txt_parse_warning(entry: Dictionary) -> String:
	var detail: String = entry.get("mod_txt_error", "")
	if detail.is_empty():
		return "Invalid mod -- mod.txt failed to parse. Try re-downloading."
	return "mod.txt parse error at " + detail

# Notes for the mod's author rather than its user: the mod loads, but its
# mod.txt could be better. The Mods tab shows them only in developer mode.
func _build_entry_author_notes(entry: Dictionary, mod_txt_files: Dictionary) -> Array[String]:
	var notes: Array[String] = []
	var ext: String = entry["ext"]
	if ext == "pck" or ext == "folder":
		return notes
	notes.append_array(_stale_bake_warnings(mod_txt_files))
	notes.append_array(_missing_id_warnings(entry))
	notes.append_array(_source_declaration_warnings(entry))
	return notes

# A wrongly declared source gets no source at all, silently (the parser
# returns {}). Name the problem on the mod's row.
func _source_declaration_warnings(entry: Dictionary) -> Array[String]:
	var warnings: Array[String] = []
	if entry.get("mod_txt_status", "none") != "ok":
		return warnings  # already warned about a broken/absent mod.txt
	var cfg_v: Variant = entry.get("cfg")
	if not (cfg_v is ConfigFile):
		return warnings
	var cfg: ConfigFile = cfg_v

	if cfg.has_section_key("updates", "source"):
		var raw := str(cfg.get_value("updates", "source", "")).strip_edges()
		if _parse_source_token(raw).is_empty():
			# _mod_source_from_cfg falls through to a valid legacy line.
			var outcome := "This mod will not update or show where it came from."
			if str(_mod_source_from_cfg(cfg)["provider"]) != "":
				outcome = "The modworkshop= line below it is used instead."
			warnings.append("mod.txt has an unrecognized [updates] source=\"%s\". Use \"<provider>:<id>\" with a known provider (%s), e.g. \"modworkshop:12345\". %s" % [raw, ", ".join(HOST_PROVIDERS_KNOWN), outcome])
	elif cfg.has_section_key("updates", "modworkshop"):
		var legacy := str(cfg.get_value("updates", "modworkshop", "")).strip_edges()
		if not (legacy.is_valid_int() and legacy.to_int() > 0):
			warnings.append("mod.txt [updates] modworkshop=\"%s\" is not a valid ModWorkshop id. This mod will not update." % legacy)

	# ConfigFile coerces an unquoted version to float (1.10 arrives as 1.1).
	# Only harmful when the mod is sourced (the string becomes a pin), so warn then.
	var has_source := cfg.has_section_key("updates", "source") or cfg.has_section_key("updates", "modworkshop")
	if has_source and cfg.has_section_key("mod", "version"):
		if typeof(cfg.get_value("mod", "version")) == TYPE_FLOAT:
			var as_num := str(cfg.get_value("mod", "version"))
			warnings.append("mod.txt [mod] version is unquoted and was read as the number %s, which loses trailing zeros (1.10 becomes 1.1). Quote it: version = \"%s\"." % [as_num, as_num])
	return warnings

# A mod.txt with no id= makes the filename the whole identity (profile_key
# "zip:<file_name>"): renaming orphans its profile state, a leftover copy
# keeps loading under the old key, and two copies cannot be deduplicated.
func _missing_id_warnings(entry: Dictionary) -> Array[String]:
	var warnings: Array[String] = []
	if not str(entry.get("profile_key", "")).begins_with("zip:"):
		return warnings
	if entry.get("mod_txt_status", "none") != "ok":
		return warnings  # already warned about a broken/absent mod.txt
	warnings.append("No id= in mod.txt, so this mod is identified by its filename. Renaming or re-packaging it loses its enabled state and load order, and two copies cannot be told apart. Add an id= line under [mod].")
	return warnings

# An archive shipping Godot's export bake beside its sources: .gd.remap
# redirects each script to compiled .gdc, so edits to the .gd do nothing.
# The engine follows those remaps itself (MCM ships a real baked cache).
func _stale_bake_warnings(mod_txt_files: Dictionary) -> Array[String]:
	var warnings: Array[String] = []
	var baked := 0
	for p: String in mod_txt_files:
		if p.ends_with(".gd.remap"):
			baked += 1
	if baked > 0:
		warnings.append("Ships %d pre-compiled script%s (.gd.remap + .godot/exported). The game runs the compiled copy, not the .gd files in this archive, so source edits do nothing until you re-export. Delete .godot/ before packing, or re-export every time."
				% [baked, "" if baked == 1 else "s"])
	return warnings

# An autoload value may carry two leading markers: "!" (load in Pass 1)
# and "*" (Godot's instantiate-as-node), either order. Returns [path,
# is_early]. Every reader strips markers here so discovery and loading agree.
static func _split_autoload_marker(raw: String) -> Array:
	var path := raw.strip_edges()
	var is_early := false
	while true:
		if path.begins_with("!"):
			is_early = true
			path = path.substr(1)
		elif path.begins_with("*"):
			path = path.substr(1)
		else:
			break
	return [path.strip_edges(), is_early]

# Autoload paths that point nowhere inside the mod: such a mod mounts and
# does nothing. Warns only on a same-name file elsewhere in the archive.
func _autoload_path_warnings(entry: Dictionary, mod_txt_files: Dictionary) -> Array[String]:
	var warnings: Array[String] = []
	var cfg: ConfigFile = entry.get("cfg")
	if cfg == null or not cfg.has_section("autoload") or mod_txt_files.is_empty():
		return warnings
	for autoload_name: String in cfg.get_section_keys("autoload"):
		# Must match what mod_loading.gd resolves, or this warns about mods that load fine.
		var res_path: String = _split_autoload_marker(str(cfg.get_value("autoload", autoload_name, "")))[0]
		if res_path.is_empty() or mod_txt_files.has(res_path):
			continue
		var target := res_path.get_file().to_lower()
		for p: String in mod_txt_files:
			if p.get_file().to_lower() == target:
				warnings.append("Autoload \"" + autoload_name + "\" points at "
					+ res_path + ", which is not in this mod -- did you mean "
					+ p + "?")
				break
	return warnings
