## ----- mod_discovery.gd -----
## Scans the mods directory, parses mod.txt metadata, builds the ordered list
## of mod entries, and owns the host-neutral download and update-check path.

# Dependency ids satisfied by the mod loader itself; always count as present.
const LOADER_ID_ALIASES: Array[String] = [
	"metro_mod_loader", "metromodloader", "vostok_mod_loader",
	"mod_loader", "modloader", "mml", "rtvmodlib",
]

# HTTPRequest.timeout covers the whole transfer; mod bodies run to ~256MB.
const API_DOWNLOAD_TIMEOUT := 300.0

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
	if ext == "pck":
		_last_mod_txt_status = "pck"
		_last_mod_txt_files.clear()  # no read_mod_config call to reset it
		# Reset so the previous mod's parse-error detail can't leak here.
		_last_mod_txt_error = ""
	var cfg: ConfigFile = read_mod_config(full_path) if ext != "pck" else null
	var entry := _entry_from_config(cfg, file_name, full_path, ext)
	entry["warnings"] = _build_entry_warnings(entry)
	entry["author_notes"] = _build_entry_author_notes(entry)
	entry["security_findings"] = scan_mod(full_path, ext)
	entry["risk_level"] = compute_risk_level(entry["security_findings"])
	_log_security_findings(entry)
	return entry

func _build_folder_entry(mods_dir: String, dir_name: String) -> Dictionary:
	_log_debug("[ModScan] inspecting " + dir_name + " [folder]")
	var folder_path := mods_dir.path_join(dir_name)
	var cfg: ConfigFile = read_mod_config_folder(folder_path)
	var entry := _entry_from_config(cfg, dir_name, folder_path, "folder")
	entry["warnings"] = _build_entry_warnings(entry)
	entry["author_notes"] = _build_entry_author_notes(entry)
	entry["security_findings"] = scan_mod(folder_path, "folder")
	entry["risk_level"] = compute_risk_level(entry["security_findings"])
	_log_security_findings(entry)
	return entry

# A folder mod excluded by dev mode off, so the orphan scan can tell it from deleted.
func _record_hidden_folder(mods_dir: String, dir_name: String) -> void:
	var folder_path := mods_dir.path_join(dir_name)
	var cfg: ConfigFile = read_mod_config_folder(folder_path)
	var entry := _entry_from_config(cfg, dir_name, folder_path, "folder")
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
#                         from the _last_mod_txt_status side channel (fs_archive.gd)
#   mod_txt_error         parse-error detail
#   has_registry          mod.txt declares [registry]; drives the disable-time confirm
# Added by _build_archive_entry / _build_folder_entry: warnings (Array[String]),
# security_findings ({rule, file, line, preview}), risk_level (RISK_CLEAN | RISK_RED).
# Added by _dedupe_by_mod_id on a winner: duplicates_hidden ({file_name, version}).
# Added by ui.gd _apply_profile_to_entries: profile_version_mismatch {stored, current}.
func _entry_from_config(cfg: ConfigFile, file_name: String, full_path: String, ext: String) -> Dictionary:
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
	#   - the "@" split (first "@") in ui.gd _version_from_profile_key and
	#     _missing_mods_in_active_profile, modpacks.gd _get_missing_mods_for_modpack,
	#     and the mod_id + "@" prefix match in _apply_profile_to_entries;
	#   - the "zip:" prefix tests and trim_prefix("zip:") in ui.gd;
	#   - the [mod_sources] cache and per-profile sections keyed by it, so a
	#     format change invalidates existing user configs.
	var profile_key := ("zip:" + file_name) if not has_mod_id else (mod_id + "@" + version)

	var entry := {
		"file_name": file_name, "full_path": full_path, "ext": ext,
		"mod_name": mod_name, "mod_id": mod_id, "version": version,
		"author": author,
		"profile_key": profile_key,
		"priority": priority, "enabled": true,
		"required_dependencies": required_dependencies,
		"optional_dependencies": optional_dependencies,
		"provides": provides,
		"dependency_warnings": [], "dependency_blockers": [],
		"dependency_blockers_info": [], "dependency_ignored": false,
		"dependencies_satisfied": true,
		"cfg": cfg, "mod_txt_status": _last_mod_txt_status,
		"mod_txt_error": _last_mod_txt_error,
		"has_registry": cfg != null and cfg.has_section("registry"),
	}
	return entry

func _build_entry_warnings(entry: Dictionary) -> Array[String]:
	var warnings: Array[String] = []
	var ext: String = entry["ext"]
	if ext == "pck" or ext == "folder":
		return warnings
	var status: String = entry.get("mod_txt_status", "none")
	if status == "none":
		warnings.append("Invalid mod -- may not work correctly. Try re-downloading.")
	elif status == "parse_error":
		# Name the line/section so authors can fix their own mod.txt typo.
		var detail: String = entry.get("mod_txt_error", "")
		if detail.is_empty():
			warnings.append("Invalid mod -- mod.txt failed to parse. Try re-downloading.")
		else:
			warnings.append("mod.txt parse error at " + detail)
	elif status.begins_with("nested:"):
		warnings.append("Invalid mod -- mod.txt is in a subfolder, not at the zip root. Re-zip so mod.txt is at the root.")
	elif status == "ok":
		warnings.append_array(_autoload_path_warnings(entry))
	return warnings

# Notes for the mod's author rather than its user: the mod loads, but its
# mod.txt could be better. The Mods tab shows them only in developer mode.
func _build_entry_author_notes(entry: Dictionary) -> Array[String]:
	var notes: Array[String] = []
	var ext: String = entry["ext"]
	if ext == "pck" or ext == "folder":
		return notes
	notes.append_array(_stale_bake_warnings(entry))
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
			warnings.append("mod.txt has an unrecognized [updates] source=\"%s\". Use \"<provider>:<id>\" with a known provider (%s), e.g. \"modworkshop:12345\". This mod will not update or show where it came from." % [raw, ", ".join(HOST_PROVIDERS_KNOWN)])
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
# _static_resolve_remaps leaves these alone (MCM ships a real baked cache).
func _stale_bake_warnings(entry: Dictionary) -> Array[String]:
	var warnings: Array[String] = []
	var baked := 0
	for p: String in _last_mod_txt_files:
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
# does nothing. Reads the _last_mod_txt_files side channel, so it must run
# right after the entry's read_mod_config. Warns only on a same-name file elsewhere.
func _autoload_path_warnings(entry: Dictionary) -> Array[String]:
	var warnings: Array[String] = []
	var cfg: ConfigFile = entry.get("cfg")
	if cfg == null or not cfg.has_section("autoload") or _last_mod_txt_files.is_empty():
		return warnings
	for autoload_name: String in cfg.get_section_keys("autoload"):
		# Must match what mod_loading.gd resolves, or this warns about mods that load fine.
		var res_path: String = _split_autoload_marker(str(cfg.get_value("autoload", autoload_name, "")))[0]
		if res_path.is_empty() or _last_mod_txt_files.has(res_path):
			continue
		var target := res_path.get_file().to_lower()
		for p: String in _last_mod_txt_files:
			if p.get_file().to_lower() == target:
				warnings.append("Autoload \"" + autoload_name + "\" points at "
					+ res_path + ", which is not in this mod -- did you mean "
					+ p + "?")
				break
	return warnings

func _parse_dependency_list(cfg: ConfigFile, key: String) -> Array[String]:
	var deps: Array[String] = []
	if cfg == null or not cfg.has_section_key("dependencies", key):
		return deps
	var raw: Variant = cfg.get_value("dependencies", key)
	if raw is Array:
		for item in (raw as Array):
			_append_dependency_id(deps, str(item))
		return deps
	if typeof(raw) == TYPE_PACKED_STRING_ARRAY:
		for item in (raw as PackedStringArray):
			_append_dependency_id(deps, str(item))
		return deps

	# Whole-value strings like "foo, bar" for older author tools.
	var text := str(raw).strip_edges()
	if text.begins_with("[") and text.ends_with("]") and text.length() >= 2:
		text = text.substr(1, text.length() - 2)
	for part in text.split(","):
		_append_dependency_id(deps, part)
	return deps

func _append_dependency_id(deps: Array[String], raw_id: String) -> void:
	var dep_id := raw_id.strip_edges()
	if dep_id.length() >= 2:
		var quoted := (dep_id.begins_with("\"") and dep_id.ends_with("\"")) \
				or (dep_id.begins_with("'") and dep_id.ends_with("'"))
		if quoted:
			dep_id = dep_id.substr(1, dep_id.length() - 2).strip_edges()
	if dep_id == "":
		return
	var dep_key := dep_id.to_lower()
	for existing in deps:
		if existing.to_lower() == dep_key:
			return
	deps.append(dep_id)

# [mod] provides=["old_id", ...]: rename aliases. A requirement naming an
# alias is satisfied by this mod; a real installed mod with that id always
# wins. Junk shapes degrade to no aliases with a log line.
func _parse_provides_list(cfg: ConfigFile, mod_id: String, file_name: String) -> Array[String]:
	var ids: Array[String] = []
	if cfg == null or not cfg.has_section_key("mod", "provides"):
		return ids
	var raw: Variant = cfg.get_value("mod", "provides")
	if raw is Array:
		for item in (raw as Array):
			if item is String or item is StringName:
				_append_dependency_id(ids, str(item))
			else:
				_log_warning(file_name + ": ignoring non-string provides entry "
						+ str(item))
	elif typeof(raw) == TYPE_PACKED_STRING_ARRAY:
		for item in (raw as PackedStringArray):
			_append_dependency_id(ids, str(item))
	elif raw is String or raw is StringName:
		# Whole-value strings like "foo, bar" (mirrors _parse_dependency_list).
		var text := str(raw).strip_edges()
		if text.begins_with("[") and text.ends_with("]") and text.length() >= 2:
			text = text.substr(1, text.length() - 2)
		for part in text.split(","):
			_append_dependency_id(ids, part)
	else:
		_log_warning(file_name + ": ignoring provides= -- expected a string array, got "
				+ type_string(typeof(raw)))
		return ids
	# Drop self-aliases so the alias passes never see one.
	var self_key := mod_id.strip_edges().to_lower()
	var cleaned: Array[String] = []
	for alias in ids:
		if alias.to_lower() != self_key:
			cleaned.append(alias)
	return cleaned

func _compare_load_order(a: Dictionary, b: Dictionary) -> bool:
	if a["priority"] != b["priority"]:
		return a["priority"] < b["priority"]
	var a_name := (a["mod_name"] as String).to_lower()
	var b_name := (b["mod_name"] as String).to_lower()
	if a_name != b_name:
		return a_name < b_name
	return (a["file_name"] as String).to_lower() < (b["file_name"] as String).to_lower()

func _entry_mod_key(entry: Dictionary) -> String:
	return str(entry.get("mod_id", "")).strip_edges().to_lower()

func _entries_by_mod_id(entries: Array) -> Dictionary:
	var by_id: Dictionary = {}
	for entry in entries:
		var key := _entry_mod_key(entry)
		if key == "":
			continue
		if not by_id.has(key):
			by_id[key] = entry
	# Second pass: aliases resolve to their providing mod, after the real-id
	# pass so an alias never shadows a real id; ties go to the first entry.
	for entry in entries:
		for raw_alias in (entry as Dictionary).get("provides", []):
			var alias_key := str(raw_alias).strip_edges().to_lower()
			if alias_key == "" or by_id.has(alias_key):
				continue
			by_id[alias_key] = entry
	return by_id

func _dependency_display(entry: Dictionary) -> String:
	var name := str(entry.get("mod_name", "")).strip_edges()
	var mod_id := str(entry.get("mod_id", "")).strip_edges()
	if name != "" and mod_id != "" and name != mod_id:
		return name + " (" + mod_id + ")"
	if mod_id != "":
		return mod_id
	return name

func _filter_dependency_ready_candidates(candidates: Array,
		log_skips: bool = false) -> Array[Dictionary]:
	var active_by_id := _entries_by_mod_id(candidates)
	var installed_by_id := _entries_by_mod_id(_ui_mod_entries)
	var blocked: Dictionary = {}
	var changed := true
	while changed:
		changed = false
		for entry in candidates:
			var entry_key := _entry_mod_key(entry)
			if entry_key == "" or blocked.has(entry_key):
				continue
			# "Load anyway": loads regardless and stays active for dependents.
			if bool(entry.get("dependency_ignored", false)):
				continue
			for raw_dep in entry.get("required_dependencies", []):
				var dep_id := str(raw_dep).strip_edges()
				if dep_id == "":
					continue
				var dep_key := dep_id.to_lower()
				# Self-dependency is a typo; warned elsewhere, never blocked.
				if dep_key == entry_key:
					continue
				# "Requires Metro Mod Loader": the loader itself satisfies it.
				if LOADER_ID_ALIASES.has(dep_key):
					continue
				# Canonicalize an alias to the provider's real id: `blocked` is keyed by
				# real ids, so a raw alias would read a blocked provider as satisfied.
				if active_by_id.has(dep_key):
					dep_key = _entry_mod_key(active_by_id[dep_key])
				elif installed_by_id.has(dep_key):
					dep_key = _entry_mod_key(installed_by_id[dep_key])
				if active_by_id.has(dep_key) and not blocked.has(dep_key):
					continue
				var status := "not_installed"
				if active_by_id.has(dep_key) and blocked.has(dep_key):
					status = "not_loaded"
				elif installed_by_id.has(dep_key):
					var installed: Dictionary = installed_by_id[dep_key]
					status = "disabled" if not bool(installed.get("enabled", false)) else "not_loaded"
				elif _dep_is_hidden_folder(dep_key):
					status = "hidden_folder"
				blocked[entry_key] = {"dependency": dep_id, "status": status}
				changed = true
				break

	var ready: Array[Dictionary] = []
	for entry in candidates:
		var entry_key := _entry_mod_key(entry)
		if entry_key != "" and blocked.has(entry_key):
			if log_skips:
				var info: Dictionary = blocked[entry_key]
				_log_critical("Skipping %s -- required dependency %s is %s" \
						% [_dependency_display(entry), info["dependency"],
						   _dependency_status_label(str(info["status"]))])
			continue
		ready.append(entry)
	return ready

func _dependency_status_label(status: String) -> String:
	match status:
		"disabled":
			return "installed but disabled"
		"not_loaded":
			return "blocked by its own missing dependency"
		"hidden_folder":
			return "a dev folder hidden while Developer Mode is off"
		_:
			return "not installed"

# A required dep that exists only as a dev folder while Developer Mode is
# off gets its own status so the row can name the fix.
func _dep_is_hidden_folder(dep_key: String) -> bool:
	for hid in _hidden_folder_ids.keys():
		if str(hid).strip_edges().to_lower() == dep_key:
			return true
	return false

# Stable topological pass over priority-sorted candidates: a required dep is
# hoisted above its dependent only when priority order violates the edge
# (Kahn walk, lowest original index first). Cycles are reported, not force-ordered.
func _apply_dependency_ordering(candidates: Array) -> Dictionary:
	var n := candidates.size()
	var key_to_index: Dictionary = {}
	for i in n:
		var k := _entry_mod_key(candidates[i])
		if k != "" and not key_to_index.has(k):
			key_to_index[k] = i
	# Alias edges point at the providing mod; second pass so an alias never steals a real id.
	for i in n:
		for raw_alias in (candidates[i] as Dictionary).get("provides", []):
			var ak := str(raw_alias).strip_edges().to_lower()
			if ak != "" and not key_to_index.has(ak):
				key_to_index[ak] = i
	var indegree := PackedInt32Array()
	indegree.resize(n)
	var dependents: Dictionary = {}
	var has_edges := false
	for i in n:
		var entry: Dictionary = candidates[i]
		var entry_key := _entry_mod_key(entry)
		# Required deps are hard edges; optional deps are soft edges applied only
		# when the dep is present. Optional deps never block, they only order.
		var dep_lists := [entry.get("required_dependencies", []), entry.get("optional_dependencies", [])]
		for dep_list in dep_lists:
			for raw_dep in dep_list:
				var dep_key := str(raw_dep).strip_edges().to_lower()
				if dep_key == "" or dep_key == entry_key or not key_to_index.has(dep_key):
					continue
				var di: int = key_to_index[dep_key]
				if di == i:
					continue
				if (dependents.get(di, []) as Array).has(i):
					continue  # required+optional both name it -- one edge only
				if not dependents.has(di):
					dependents[di] = []
				(dependents[di] as Array).append(i)
				indegree[i] += 1
				has_edges = true
	var ordered: Array[Dictionary] = []
	if not has_edges:
		for c in candidates:
			ordered.append(c)
		return {"ordered": ordered, "adjusted": false, "cycle_keys": []}
	var emitted: Dictionary = {}
	var remaining := n
	var progress := true
	while remaining > 0 and progress:
		progress = false
		for i in n:
			if emitted.has(i) or indegree[i] > 0:
				continue
			emitted[i] = true
			ordered.append(candidates[i])
			remaining -= 1
			for j in dependents.get(i, []):
				indegree[j] -= 1
			progress = true
			break
	# Leftovers are in a cycle or downstream of one. Emit them at the end in
	# original order, but report only nodes that are in a cycle.
	var cycle_keys: Array[String] = []
	if remaining > 0:
		var leftover: Array[int] = []
		for i in n:
			if not emitted.has(i):
				leftover.append(i)
				ordered.append(candidates[i])
		for i in leftover:
			if _node_reaches_self(i, dependents, emitted):
				var ck := _entry_mod_key(candidates[i])
				if ck != "":
					cycle_keys.append(ck)
	var adjusted := false
	for i in n:
		if ordered[i] != candidates[i]:
			adjusted = true
			break
	return {"ordered": ordered, "adjusted": adjusted, "cycle_keys": cycle_keys}

# True iff `start` can reach itself within the still-unemitted subgraph.
# `dependents[x]` lists nodes that depend on x.
func _node_reaches_self(start: int, dependents: Dictionary, emitted: Dictionary) -> bool:
	var seen: Dictionary = {}
	# Plain Array: an untyped Array cannot be assigned to an Array[int] var.
	var stack: Array = (dependents.get(start, []) as Array).duplicate()
	while not stack.is_empty():
		var x: int = stack.pop_back()
		if emitted.has(x):
			continue
		if x == start:
			return true
		if seen.has(x):
			continue
		seen[x] = true
		for y in dependents.get(x, []):
			if not emitted.has(y):
				stack.append(y)
	return false

# The one definition of what loads, in what order: load_all_mods, boot's
# archive collection, the order panel and the launch button all read this.
# duplicate_entries=true hands back copies; the UI passes false to observe live dicts.
func _loadable_enabled_entries(log_skips := false, duplicate_entries := false) -> Dictionary:
	var enabled: Array[Dictionary] = []
	for entry in _ui_mod_entries:
		if bool(entry.get("enabled", false)):
			enabled.append(entry.duplicate() if duplicate_entries else entry)
	enabled.sort_custom(_compare_load_order)
	var ordering := _apply_dependency_ordering(enabled)
	var loadable := _filter_dependency_ready_candidates(ordering["ordered"], log_skips)
	return {
		"loadable": loadable,
		"enabled_count": enabled.size(),
		"adjusted": ordering["adjusted"],
		"cycle_keys": ordering["cycle_keys"],
	}

# Enable every required dependency (transitively) that is installed but off.
func _enable_required_deps(entry: Dictionary) -> Dictionary:
	var installed_by_id := _entries_by_mod_id(_ui_mod_entries)
	var enabled_names: Array[String] = []
	var unfixed: Array[String] = []
	var queue: Array[String] = []
	var seen: Dictionary = {}
	for raw_dep in entry.get("required_dependencies", []):
		queue.append(str(raw_dep).strip_edges().to_lower())
	while not queue.is_empty():
		var dep_key: String = queue.pop_front()
		if dep_key == "" or seen.has(dep_key) or LOADER_ID_ALIASES.has(dep_key):
			continue
		seen[dep_key] = true
		if not installed_by_id.has(dep_key):
			unfixed.append(dep_key)
			continue
		var dep_entry: Dictionary = installed_by_id[dep_key]
		if not bool(dep_entry.get("enabled", false)):
			dep_entry["enabled"] = true
			enabled_names.append(str(dep_entry.get("mod_name", dep_key)))
		for raw in dep_entry.get("required_dependencies", []):
			queue.append(str(raw).strip_edges().to_lower())
	return {"enabled_names": enabled_names, "unfixed": unfixed}

# Display name for a dependency id; loop callers should pass a prebuilt map.
func _dependency_display_for_id(dep_id: String, installed_by_id: Variant = null) -> String:
	var dep_key := dep_id.strip_edges().to_lower()
	var by_id: Dictionary = installed_by_id if installed_by_id is Dictionary \
			else _entries_by_mod_id(_ui_mod_entries)
	if by_id.has(dep_key):
		return str((by_id[dep_key] as Dictionary).get("mod_name", dep_id))
	return dep_id

# Returns the _loadable_enabled_entries pick computed mid-pass so hot callers reuse it.
func _refresh_dependency_status() -> Dictionary:
	var installed_by_id := _entries_by_mod_id(_ui_mod_entries)
	var enabled_by_id := _entries_by_mod_id(_ui_mod_entries.filter(
			func(e): return bool((e as Dictionary).get("enabled", false))))
	for entry in _ui_mod_entries:
		entry["dependency_warnings"] = []
		entry["dependency_blockers"] = []
		entry["dependency_blockers_info"] = []
		entry["dependencies_satisfied"] = true

	var pick := _loadable_enabled_entries()
	var loadable_by_id := _entries_by_mod_id(pick["loadable"])
	var cycle_keys: Array = pick["cycle_keys"]

	for entry in _ui_mod_entries:
		if not bool(entry.get("enabled", false)):
			continue
		var warnings: Array[String] = []
		var blockers: Array[String] = []
		var info: Array[Dictionary] = []
		var entry_key := _entry_mod_key(entry)
		if cycle_keys.has(entry_key):
			warnings.append("load order could not be fully resolved (dependency cycle in chain)")
		for raw_dep in entry.get("required_dependencies", []):
			var dep_id := str(raw_dep).strip_edges()
			if dep_id == "":
				continue
			var dep_key := dep_id.to_lower()
			if dep_key == entry_key:
				warnings.append("lists itself as a dependency (ignored)")
				continue
			if LOADER_ID_ALIASES.has(dep_key):
				continue
			# Resolve the dep the way the load filter does: bind the id to whichever
			# enabled mod owns it (real id beats alias), else installed, then satisfied
			# only if that owner is loadable. A raw-id test would let a blocked id escape to an alias.
			var owner_key := dep_key
			if enabled_by_id.has(dep_key):
				owner_key = _entry_mod_key(enabled_by_id[dep_key])
			elif installed_by_id.has(dep_key):
				owner_key = _entry_mod_key(installed_by_id[dep_key])
			if loadable_by_id.has(owner_key) and _entry_mod_key(loadable_by_id[owner_key]) == owner_key:
				continue
			var status := "not_installed"
			var display := dep_id
			var fixable := false
			if installed_by_id.has(dep_key):
				var dep_entry: Dictionary = installed_by_id[dep_key]
				display = _dependency_display(dep_entry)
				if not bool(dep_entry.get("enabled", false)):
					status = "disabled"
					fixable = true
				else:
					status = "not_loaded"
			elif _dep_is_hidden_folder(dep_key):
				status = "hidden_folder"
			blockers.append(dep_id)
			info.append({"id": dep_id, "status": status, "display": display, "fixable": fixable})
		entry["dependency_warnings"] = warnings
		entry["dependency_blockers_info"] = info
		if bool(entry.get("dependency_ignored", false)):
			# "Load anyway": nothing blocks the mod, but keep the info for the row.
			entry["dependency_blockers"] = []
			entry["dependencies_satisfied"] = true
		else:
			entry["dependency_blockers"] = blockers
			entry["dependencies_satisfied"] = blockers.is_empty()
	return pick

# Returns -1/0/1 for version comparison (a < b, equal, a > b).
func compare_versions(a: String, b: String) -> int:
	if a.is_empty() or b.is_empty():
		return 0 if a == b else (-1 if a.is_empty() else 1)
	var pa := a.lstrip("vV").split(".")
	var pb := b.lstrip("vV").split(".")
	var n: int = max(pa.size(), pb.size())
	for i in n:
		var sa := pa[i] if i < pa.size() else "0"
		var sb := pb[i] if i < pb.size() else "0"
		var va := int(sa) if sa.is_valid_int() else 0
		var vb := int(sb) if sb.is_valid_int() else 0
		if va < vb: return -1
		if va > vb: return 1
	return 0

# Compare two semver prerelease tails ("beta.1" vs "beta.10"). Numeric
# identifiers rank below non-numeric; a shorter run ranks lower on an equal prefix.
func _compare_prerelease(a: String, b: String) -> int:
	if a == b:
		return 0
	var pa := a.split(".")
	var pb := b.split(".")
	var n: int = max(pa.size(), pb.size())
	for i in n:
		if i >= pa.size():
			return -1
		if i >= pb.size():
			return 1
		var ia: String = pa[i]
		var ib: String = pb[i]
		var a_num := ia.is_valid_int()
		var b_num := ib.is_valid_int()
		if a_num and b_num:
			var va := ia.to_int()
			var vb := ib.to_int()
			if va != vb:
				return -1 if va < vb else 1
		elif a_num != b_num:
			return -1 if a_num else 1
		elif ia != ib:
			return -1 if ia < ib else 1
	return 0

# Collapse same-id duplicates (CoolMod_v1.zip + CoolMod_v1.1.zip). Mods with
# no declared id group by normalized filename stem; .pck files never collapse.
func _dedupe_by_mod_id(entries: Array[Dictionary]) -> Array[Dictionary]:
	# Group on the lowercased key so ids differing only in case collapse too.
	var groups: Dictionary = {}
	for e in entries:
		var mid := _dedupe_group_key(e)
		if mid.is_empty():
			continue
		if not groups.has(mid):
			groups[mid] = []
		(groups[mid] as Array).append(e)

	var winners_by_id: Dictionary = {}
	for mid in groups.keys():
		var members: Array = groups[mid]
		if members.size() == 1:
			winners_by_id[mid] = members[0]
			continue
		members.sort_custom(_compare_dedup_priority)
		var winner: Dictionary = members[0]
		var hidden: Array[Dictionary] = []
		var w_v: String = ("v" + str(winner["version"])) if str(winner["version"]) != "" else "(unversioned)"
		for j in range(1, members.size()):
			var loser: Dictionary = members[j]
			hidden.append({"file_name": loser["file_name"], "version": loser["version"]})
			var l_v: String = ("v" + str(loser["version"])) if str(loser["version"]) != "" else "(unversioned)"
			_log_warning("Duplicate mod_id '" + str(winner["mod_id"]) + "' detected: keeping "
					+ str(winner["file_name"]) + " (" + w_v + "), hiding "
					+ str(loser["file_name"]) + " (" + l_v + ")")
		winner["duplicates_hidden"] = hidden
		winners_by_id[mid] = winner

	var seen_ids: Dictionary = {}
	var out: Array[Dictionary] = []
	for e in entries:
		var mid := _dedupe_group_key(e)
		if mid.is_empty():
			out.append(e)
			continue
		if seen_ids.has(mid):
			continue
		seen_ids[mid] = true
		out.append(winners_by_id[mid])
	return out

# Identity used to collapse duplicates; "" means never collapse.
func _dedupe_group_key(entry: Dictionary) -> String:
	if str(entry.get("ext", "")) == "pck":
		return ""
	if not str(entry.get("profile_key", "")).begins_with("zip:"):
		return _entry_mod_key(entry)
	var stem := _normalized_mod_stem(str(entry.get("file_name", "")))
	return "stem:" + stem if not stem.is_empty() else ""

# Filename reduced to what survives a re-package: extension gone, lowercased,
# one trailing version token stripped ("CoolMod_v1.2" -> "coolmod"). What
# survives must contain a letter, or bare-numeric filenames would all collapse.
func _normalized_mod_stem(file_name: String) -> String:
	var stem := file_name.get_basename().to_lower().strip_edges()
	var re := RegEx.new()
	# Version-token shapes: [_-.] separator with optional v, space plus explicit
	# v, space plus dotted number, or v attached to the name. A space plus a bare
	# integer is not a version: "Ammo Pack 1" and "Ammo Pack 2" are different mods.
	re.compile("^(.*?)(?:[_\\-.]+v?[0-9]+(?:[._][0-9]+)*| +v[0-9]+(?:[._][0-9]+)*| +[0-9]+(?:[._][0-9]+)+|v[0-9]+(?:[._][0-9]+)*)$")
	var m := re.search(stem)
	if m != null:
		var head := m.get_string(1).strip_edges()
		var named := RegEx.new()
		named.compile("[a-z]")
		if named.search(head) != null:
			return head
	return stem

# Higher version wins; tiebreak newer mtime, then alphabetically lower filename.
func _compare_dedup_priority(a: Dictionary, b: Dictionary) -> bool:
	var vc := compare_versions(str(a.get("version", "")), str(b.get("version", "")))
	if vc != 0:
		return vc > 0
	var am: int = FileAccess.get_modified_time(str(a["full_path"]))
	var bm: int = FileAccess.get_modified_time(str(b["full_path"]))
	if am != bm:
		return am > bm
	return (a["file_name"] as String).to_lower() < (b["file_name"] as String).to_lower()

## Current version of many installed mods, grouped by host. Returns
## {ref_key: version}; an absent mod could not be checked. Link-out hosts are skipped.
func fetch_latest_versions(refs: Array) -> Dictionary:
	var ids_by_provider: Dictionary = {}
	for ref_v in refs:
		if not host_ref_valid(ref_v):
			continue
		var provider := str(ref_v["provider"])
		var ids: PackedStringArray = ids_by_provider.get(provider, PackedStringArray())
		var id := str(ref_v["id"])
		if not ids.has(id):
			ids.append(id)
		ids_by_provider[provider] = ids
	var out := {}
	for provider in ids_by_provider:
		if not bool(host_caps(provider)["resolve_file"]):
			continue
		var res := await host_latest_versions(provider, ids_by_provider[provider], Callable())
		if not res["ok"]:
			_log_warning("[Updates] %s version check failed: %s" % [host_display_name(provider), host_error_message(provider, res)])
			continue
		if res["data"] is Dictionary:
			out.merge(res["data"], true)
	return out

# Filename from Content-Disposition (plain, quoted, and RFC 5987 filename*).
# Returns "" unless the value is a safe basename with an accepted extension.
func _filename_from_content_disposition(headers: PackedStringArray) -> String:
	for raw in headers:
		var line: String = raw
		var colon := line.find(":")
		if colon < 0:
			continue
		if line.substr(0, colon).strip_edges().to_lower() != "content-disposition":
			continue
		var value := line.substr(colon + 1).strip_edges()
		# filename* first: unicode-safe, and dual-emitting servers prefer it.
		var star_val := _extract_disposition_param(value, "filename*")
		if star_val != "":
			var sep := star_val.find("''")
			if sep >= 0:
				star_val = star_val.substr(sep + 2).uri_decode()
			if _is_safe_mod_filename(star_val):
				return star_val.get_file()
		var plain_val := _extract_disposition_param(value, "filename")
		if plain_val != "":
			# CDNs percent-encode plain filename=; decode, then validate.
			if plain_val.contains("%"):
				plain_val = plain_val.uri_decode()
			if _is_safe_mod_filename(plain_val):
				return plain_val.get_file()
		return ""
	return ""

func _extract_disposition_param(header_value: String, param: String) -> String:
	var pos := header_value.to_lower().find(param.to_lower() + "=")
	if pos < 0:
		return ""
	var rest := header_value.substr(pos + param.length() + 1).strip_edges()
	if rest.begins_with("\""):
		var end := rest.find("\"", 1)
		if end < 0:
			return ""
		return rest.substr(1, end - 1)
	var semi := rest.find(";")
	if semi < 0:
		return rest.strip_edges()
	return rest.substr(0, semi).strip_edges()

# True when a server-supplied name is a bare filename safe to path_join.
# get_file() only splits on "/", so "..\evil.zip" would pass a basename check;
# both separators, drive and ADS colons, and dot-prefixed names are rejected.
func _is_safe_basename(name: String) -> bool:
	if name.is_empty():
		return false
	if "\\" in name or "/" in name or ":" in name or name.begins_with("."):
		return false
	return name == name.get_file()

func _is_safe_mod_filename(name: String) -> bool:
	if not _is_safe_basename(name):
		return false
	return name.get_extension().to_lower() in ["vmz", "zip", "pck"]

# Filename the download lands under: Content-Disposition, else the old stem
# with the new version spliced on. Best-effort; never blocks an update.
func _derive_updated_filename(old_file_name: String, headers: PackedStringArray, new_version: String) -> String:
	var server_name := _filename_from_content_disposition(headers)
	if server_name != "":
		return server_name
	if new_version.is_empty():
		return old_file_name
	# new_version is untrusted; separators would land outside the mods dir.
	if not new_version.lstrip("vV").is_valid_filename():
		return old_file_name
	var ext := old_file_name.get_extension()
	var stem := old_file_name.get_basename()
	var rx := RegEx.new()
	rx.compile("[_-][vV]\\d+(?:\\.\\d+)*$")
	var stripped := rx.sub(stem, "")
	var new_stem := stripped + "_v" + new_version.lstrip("vV")
	return new_stem if ext.is_empty() else new_stem + "." + ext

# --- Download surfaces ------------------------------------------------------
# Four UI surfaces reach the two entry points below; keep this map current:
#   1. Mods tab "Update" badge (build_mods_tab) -> replace_mod_from_ref
#   2. Browse "Download" and its serial queue (build_browse_tab) -> download_mod_from_ref(ref)
#   3. Missing-mod stub "Download" (build_mods_tab) -> download_mod_from_ref(ref, version, true)
#   4. Modpack apply and retry (modpacks.gd) -> download_mod_from_ref(ref, version, true);
#      the apply loop counts the "Already have" prefix as installed, not failed.
# Each surface has its own busy state and error handling; only Browse
# serializes, so two surfaces can race on the same file (hence the
# _live_full_path re-resolution in ui.gd).

# Returns {ok, new_path, new_file_name}; failures also carry "error". On
# success new_path may differ from target_path (Content-Disposition or
# version bump). On failure temp and backup are cleaned up and the original is intact.
func replace_mod_from_ref(target_path: String, ref: Dictionary) -> Dictionary:
	# The Mods-tab badge shows "error" verbatim, so it is never "unknown".
	var failure := {"ok": false, "new_path": target_path, "new_file_name": target_path.get_file(), "error": ""}
	if not host_ref_valid(ref):
		failure["error"] = "This mod has no download source recorded."
		return failure
	var provider := str(ref["provider"])
	var resolved := await host_resolve_file(ref, "")
	if not resolved["ok"]:
		failure["error"] = _host_resolve_failure_copy(provider, resolved, "")
		return failure
	var file: Dictionary = resolved["data"]

	var req := HTTPRequest.new()
	req.timeout = API_DOWNLOAD_TIMEOUT
	req.download_body_size_limit = 256 * 1024 * 1024
	add_child(req)
	var err := req.request(str(file["download_url"]), _host_download_headers(file))
	if err != OK:
		req.queue_free()
		failure["error"] = "Could not start the download request (error %d)" % err
		return failure
	var res: Array = await req.request_completed
	req.queue_free()
	host_note_rate_headers(provider, int(res[1]), res[2])

	if res[0] != HTTPRequest.RESULT_SUCCESS or res[1] < 200 or res[1] >= 300:
		if res[0] != HTTPRequest.RESULT_SUCCESS:
			failure["error"] = "Download failed (connection error or timeout) -- check your network and retry"
		else:
			failure["error"] = host_error_status(provider, "Download failed (HTTP %d)" % int(res[1]))
		return failure
	var headers: PackedStringArray = res[2]
	var response_body: PackedByteArray = res[3]
	if response_body.is_empty():
		failure["error"] = "Server returned an empty file"
		return failure

	var temp_path   := target_path + ".download"
	var backup_path := target_path + ".bak"
	if FileAccess.file_exists(temp_path):   DirAccess.remove_absolute(temp_path)
	if FileAccess.file_exists(backup_path): DirAccess.remove_absolute(backup_path)

	var out := FileAccess.open(temp_path, FileAccess.WRITE)
	if out == null:
		failure["error"] = "Could not write to the mods folder (permissions or disk full)"
		return failure
	var wrote := out.store_buffer(response_body)
	out.close()
	var verify := FileAccess.open(temp_path, FileAccess.READ)
	var disk_len: int = verify.get_length() if verify != null else -1
	if verify != null:
		verify.close()
	if not wrote or disk_len != response_body.size():
		DirAccess.remove_absolute(temp_path)
		failure["error"] = "Could not write the download to disk (disk full?)"
		return failure

	var new_cfg: ConfigFile = read_mod_config(temp_path)
	if new_cfg == null:
		DirAccess.remove_absolute(temp_path)
		failure["error"] = "Downloaded file is not a valid mod archive (no readable mod.txt)"
		return failure

	var dir_access := DirAccess.open(target_path.get_base_dir())
	if dir_access == null:
		DirAccess.remove_absolute(temp_path)
		failure["error"] = "Could not open the mods folder"
		return failure

	var old_file_name := target_path.get_file()
	var new_version := str(new_cfg.get_value("mod", "version", ""))
	var new_file_name := _derive_updated_filename(old_file_name, headers, new_version)
	var new_path := target_path.get_base_dir().path_join(new_file_name)

	# Never clobber an unrelated archive at the derived path.
	if new_file_name != old_file_name and FileAccess.file_exists(new_path):
		DirAccess.remove_absolute(temp_path)
		failure["error"] = "A different file named \"%s\" is already in the mods folder -- move or delete it and retry" % new_file_name
		return failure

	# Stash the old archive under .bak so a failed rename can roll back.
	if FileAccess.file_exists(target_path):
		if dir_access.rename(target_path.get_file(), backup_path.get_file()) != OK:
			DirAccess.remove_absolute(temp_path)
			failure["error"] = "Could not back up the current archive (file in use?) -- close anything using it and retry"
			return failure

	if dir_access.rename(temp_path.get_file(), new_file_name) != OK:
		if FileAccess.file_exists(backup_path):
			dir_access.rename(backup_path.get_file(), target_path.get_file())
		DirAccess.remove_absolute(temp_path)
		failure["error"] = "Could not finalize the update (file may be locked) -- the old version was kept"
		return failure

	# New file is in place; the .bak (which is the old archive) can go.
	if FileAccess.file_exists(backup_path):
		DirAccess.remove_absolute(backup_path)
	_record_installed_mod_source(new_file_name, ref, str(file["version"]))
	return {"ok": true, "new_path": new_path, "new_file_name": new_file_name}


# Fetch an archive and adopt it into mods/. Provider-neutral: the caller
# resolved a FileRecord through the seam. Returns {ok, file_name, error}; on
# failure the temp file is cleaned up. The "Already have a file named " prefix
# is a contract: modpacks.gd counts that failure as already-installed.
func _host_install_downloaded_archive(provider: String, download_url: String, headers: PackedStringArray,
		fallback_stem: String, filename_hint: String, version_hint: String,
		allow_rename_on_collision: bool, expected_sha256: String = "") -> Dictionary:
	var failure := {"ok": false, "file_name": "", "error": "unknown"}
	if _mods_dir.is_empty():
		_mods_dir = OS.get_executable_path().get_base_dir().path_join(MOD_DIR)
	DirAccess.make_dir_recursive_absolute(_mods_dir)

	var req := HTTPRequest.new()
	req.timeout = API_DOWNLOAD_TIMEOUT
	req.download_body_size_limit = 256 * 1024 * 1024
	add_child(req)
	var err := req.request(download_url, headers)
	if err != OK:
		req.queue_free()
		failure["error"] = "Could not start the download request (error %d)" % err
		return failure
	var res: Array = await req.request_completed
	req.queue_free()
	if res[0] != HTTPRequest.RESULT_SUCCESS or res[1] < 200 or res[1] >= 300:
		# Transport failures have no status code (res[1] is 0); split the branches.
		if res[0] != HTTPRequest.RESULT_SUCCESS:
			failure["error"] = "Download failed (connection error or timeout) -- check your network and retry"
		else:
			failure["error"] = host_error_status(provider, "Download failed (HTTP %d)" % int(res[1]))
		return failure
	var resp_headers: PackedStringArray = res[2]
	var body: PackedByteArray = res[3]
	if body.is_empty():
		failure["error"] = "The download came back empty. Try again later."
		return failure
	# A pack that names the file's checksum gets it checked before it reaches mods/.
	if expected_sha256 != "":
		var ctx := HashingContext.new()
		ctx.start(HashingContext.HASH_SHA256)
		ctx.update(body)
		var got := ctx.finish().hex_encode()
		if got != expected_sha256.to_lower():
			failure["error"] = "The downloaded file does not match the checksum the modpack lists. Try again later; if it keeps failing, the file on the site may have changed."
			return failure

	# Same _is_safe_mod_filename gate as the update path. The adapter's
	# filename_hint carries whatever its host knows; the fallback stem is
	# provider-specific so ModWorkshop installs keep their old filenames.
	var derived_name := _filename_from_content_disposition(resp_headers)
	if derived_name.is_empty() and _is_safe_mod_filename(filename_hint):
		derived_name = filename_hint
	if derived_name.is_empty():
		derived_name = fallback_stem + ".zip"

	var temp_path := _mods_dir.path_join(derived_name + ".download")
	var final_path := _mods_dir.path_join(derived_name)

	# Collisions: Browse refuses. Modpack apply (allow_rename_on_collision)
	# suffixes the version so a pinned version coexists and dedup picks the higher.
	if FileAccess.file_exists(final_path):
		if not allow_rename_on_collision:
			# Prefix contract with modpacks.gd _apply_modpack_inner; reword it there too.
			failure["error"] = "Already have a file named " + derived_name
			return failure
		var meta_version := version_hint.strip_edges().lstrip("vV")
		# Server-controlled string headed into a filename; is_valid_filename rejects traversal and "<null>".
		if not meta_version.is_empty() and not meta_version.is_valid_filename():
			meta_version = ""
		if meta_version.is_empty():
			# Last-ditch: a timestamp suffix so the install can proceed.
			meta_version = str(int(Time.get_unix_time_from_system()))
		var ext := derived_name.get_extension()
		var stem := derived_name.get_basename()
		derived_name = stem + "-v" + meta_version + ("." + ext if ext != "" else "")
		final_path = _mods_dir.path_join(derived_name)
		temp_path = _mods_dir.path_join(derived_name + ".download")
		if FileAccess.file_exists(final_path):
			# Same "Already have" prefix contract as above.
			failure["error"] = "Already have a file named " + derived_name + " (and the renamed variant)"
			return failure
	if FileAccess.file_exists(temp_path):
		DirAccess.remove_absolute(temp_path)

	var out := FileAccess.open(temp_path, FileAccess.WRITE)
	if out == null:
		failure["error"] = "Could not write to the mods folder (permissions or disk full)"
		return failure
	var wrote := out.store_buffer(body)
	out.close()
	var verify := FileAccess.open(temp_path, FileAccess.READ)
	var disk_len: int = verify.get_length() if verify != null else -1
	if verify != null:
		verify.close()
	if not wrote or disk_len != body.size():
		DirAccess.remove_absolute(temp_path)
		failure["error"] = "Could not write the download to disk (disk full?)"
		return failure

	# Validate before adopting, mirroring collect_mod_metadata: a .pck has no
	# readable root mod.txt, so check its container magic instead.
	var dl_ext := derived_name.get_extension().to_lower()
	if dl_ext == "pck":
		if not _looks_like_pck(temp_path):
			DirAccess.remove_absolute(temp_path)
			failure["error"] = "Downloaded file is not a valid .pck"
			return failure
	else:
		# Reject only an invalid container; mod.txt is optional, same as discovery.
		var zr := ZIPReader.new()
		var zip_ok := zr.open(temp_path) == OK
		if zip_ok:
			zr.close()
		if not zip_ok:
			DirAccess.remove_absolute(temp_path)
			failure["error"] = "Downloaded file is not a valid archive"
			return failure
		if read_mod_config(temp_path) == null:
			_log_warning("Downloaded '%s' has no parseable root mod.txt -- installing as a plain resource pack" % derived_name)

	var dir_access := DirAccess.open(_mods_dir)
	if dir_access == null:
		DirAccess.remove_absolute(temp_path)
		failure["error"] = "Could not open the mods folder"
		return failure

	if dir_access.rename(temp_path.get_file(), derived_name) != OK:
		DirAccess.remove_absolute(temp_path)
		failure["error"] = "Could not move the downloaded file into the mods folder (file may be locked) -- close anything using it and retry"
		return failure

	return {"ok": true, "file_name": derived_name, "error": ""}


## Download headers: our User-Agent (a default one gets a bodyless 403) plus
## the adapter's per-file headers, such as a signed-CDN token.
func _host_download_headers(file: Dictionary) -> PackedStringArray:
	var h := PackedStringArray(["User-Agent: " + (HOST_USER_AGENT_TEMPLATE % MODLOADER_VERSION)])
	var extra: Variant = file.get("headers")
	if extra is PackedStringArray:
		h.append_array(extra)
	return h


## User-facing copy for a failed resolve; codes the install path cares about get specific wording.
func _host_resolve_failure_copy(provider: String, res: Dictionary, version: String) -> String:
	var host := host_display_name(provider)
	match str(res.get("code", "")):
		HOST_ERR_VERSION_NOT_FOUND:
			return host_error_status(provider, "Version " + version + " not available on " + host)
		HOST_ERR_NO_FILE:
			if str(res.get("message", "")).contains("scan"):
				return "This version has not passed " + host + "'s malware scan, so it cannot be downloaded yet."
			return host_error_status(provider, "This mod has no downloadable file on " + host + ". Check its mod page -- the author may host the download elsewhere.")
		HOST_ERR_OFFLINE:
			return "Could not reach " + host + ". Check your connection and try again."
		_:
			return host_error_message(provider, res)


## Record where an installed archive came from, so update checks and modpack
## exports work even when its mod.txt declares no source.
func _record_installed_mod_source(file_name: String, ref: Dictionary, version: String) -> void:
	var entry := _build_archive_entry(_mods_dir, file_name, file_name.get_extension().to_lower())
	var pk := str(entry.get("profile_key", ""))
	if pk.is_empty():
		return
	_persist_single_mod_source(pk, {"provider": str(ref["provider"]), "id": str(ref["id"]), "version": version})


## Filename stem when neither the server nor the adapter names the file.
## ModWorkshop keeps "mws_mod_<id>" so existing installs are recognized.
func _host_fallback_stem(ref: Dictionary) -> String:
	var id := str(ref["id"])
	if str(ref["provider"]) == HOST_MODWORKSHOP:
		return "mws_mod_" + id
	return str(ref["provider"]) + "_" + id.validate_filename()


# Browse "Get" and modpack apply, for any host. Empty `version` installs the
# host's current file; a set version pins it. Returns {ok, file_name, error}.
func download_mod_from_ref(ref: Dictionary, version: String = "", allow_rename_on_collision: bool = false,
		expected_sha256: String = "") -> Dictionary:
	var failure := {"ok": false, "file_name": "", "error": "unknown"}
	if not host_ref_valid(ref):
		failure["error"] = "This mod has no download source recorded."
		return failure
	var provider := str(ref["provider"])
	var res := await host_resolve_file(ref, version)
	if not res["ok"]:
		failure["error"] = _host_resolve_failure_copy(provider, res, version)
		return failure
	var file: Dictionary = res["data"]
	var r := await _host_install_downloaded_archive(provider, str(file["download_url"]),
			_host_download_headers(file), _host_fallback_stem(ref), str(file["filename_hint"]),
			str(file["version"]), allow_rename_on_collision, expected_sha256)
	if r["ok"]:
		_record_installed_mod_source(str(r["file_name"]), ref, str(file["version"]))
	return r


# .pck archives begin with "GDPC"; a CDN error page under a .pck name is refused.
func _looks_like_pck(path: String) -> bool:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return false
	var magic := f.get_buffer(4)
	f.close()
	return magic == PackedByteArray([0x47, 0x44, 0x50, 0x43])


# ----- provider-qualified mod sources ------------------------------------
# Canonical record: {"provider", "id", "version"}, every field present;
# provider "" is the single "no source" test. Three disk surfaces carry it:
#   mod.txt [updates]      source="<provider>:<id>", plus legacy modworkshop=<int>
#   mod_config.cfg         [mod_sources] <profile_key> = <json>
#   modpack profile.json   "sources": {<profile_key>: <record>}
# The JSON record is {provider, id, modworkshop_id?, version?}; modworkshop_id
# is a compat mirror emitted only for ModWorkshop, since a pre-source loader
# reading it on another host's record would download the wrong mod.
# When mod.txt and the stored record disagree, _resolve_mod_source ranks them.

## mod.txt `source=` value -> canonical record (version ""), {} on reject.
## Delegates to host_ref_from_key; bare no-colon values are rejected, not defaulted.
func _parse_source_token(raw: String) -> Dictionary:
	var ref := host_ref_from_key(raw.strip_edges())
	if ref.is_empty():
		return {}
	var provider := str(ref["provider"])
	var id := str(ref["id"])
	# Canonicalize a ModWorkshop id like the legacy path, or update checks never match.
	if provider == HOST_MODWORKSHOP and id.is_valid_int():
		id = str(id.to_int())
	return {"provider": provider, "id": id, "version": ""}


## The one reader of a mod.txt source declaration. source= wins; a malformed
## one falls through to legacy modworkshop=, which must be a pure integer
## (to_int() would mint id 12 out of "12abc"). The record carries a fourth
## key, `explicit`: true when it came from source=, false for the legacy key
## or no declaration. _resolve_mod_source ranks the two differently.
func _mod_source_from_cfg(cfg: ConfigFile) -> Dictionary:
	if cfg == null:
		return {"provider": "", "id": "", "version": "", "explicit": false}
	var version := str(cfg.get_value("mod", "version", "")).strip_edges()
	if cfg.has_section_key("updates", "source"):
		var rec := _parse_source_token(str(cfg.get_value("updates", "source", "")))
		if not rec.is_empty():
			rec["version"] = version
			rec["explicit"] = true
			return rec
	if cfg.has_section_key("updates", "modworkshop"):
		var legacy := str(cfg.get_value("updates", "modworkshop", "")).strip_edges()
		if legacy.is_valid_int() and legacy.to_int() > 0:
			# Round-trip through int so "0123" and "+123" normalize to the wire id.
			return {"provider": HOST_MODWORKSHOP, "id": str(legacy.to_int()), "version": version, "explicit": false}
	return {"provider": "", "id": "", "version": "", "explicit": false}


## Rank a mod.txt declaration (from _mod_source_from_cfg) against the stored
## [mod_sources] record for the same mod (normalized, or {}). An explicit
## source= wins. Otherwise the stored record wins: the launcher wrote it at
## download or pack-install time, so it names the host the file came from,
## while a legacy modworkshop= line is what vostokmods.net serves in every
## file. Legacy is used only when nothing is stored. Returns the canonical
## {provider, id, version}, provider "" when neither names a host.
func _resolve_mod_source(declared: Dictionary, stored: Dictionary) -> Dictionary:
	var from_mod_txt := {
		"provider": str(declared.get("provider", "")),
		"id": str(declared.get("id", "")),
		"version": str(declared.get("version", "")),
	}
	if bool(declared.get("explicit", false)) and from_mod_txt["provider"] != "":
		return from_mod_txt
	if str(stored.get("provider", "")) != "":
		return {
			"provider": str(stored["provider"]),
			"id": str(stored.get("id", "")),
			"version": str(stored.get("version", "")),
		}
	return from_mod_txt


## Normalize a [mod_sources]/profile.json record of either era. With a
## "provider" key present, modworkshop_id is never consulted, even as a fallback.
func _normalize_source_record(v: Variant) -> Dictionary:
	if not (v is Dictionary):
		return {"provider": "", "id": "", "version": ""}
	var rec: Dictionary = v
	var ver_raw: Variant = rec.get("version", "")
	var version := str(ver_raw) if ver_raw is String else ""
	if rec.has("provider"):
		var provider := str(rec.get("provider", ""))
		var id := str(rec.get("id", "")).strip_edges()
		if HOST_PROVIDERS_KNOWN.has(provider) and not id.is_empty():
			# Same id canonicalization as the legacy path.
			if provider == HOST_MODWORKSHOP and id.is_valid_int():
				id = str(id.to_int())
			return {"provider": provider, "id": id, "version": version}
		return {"provider": "", "id": "", "version": ""}
	# Legacy {"modworkshop_id": N}: floats from JSON, and hand-edited packs have
	# carried null and quoted ids. Only ints, floats and pure-integer strings count.
	var mws_raw: Variant = rec.get("modworkshop_id", 0)
	var mws_id := 0
	if mws_raw is int:
		mws_id = mws_raw
	elif mws_raw is float:
		mws_id = int(mws_raw)
	elif mws_raw is String and str(mws_raw).strip_edges().is_valid_int():
		mws_id = str(mws_raw).strip_edges().to_int()
	if mws_id > 0:
		return {"provider": HOST_MODWORKSHOP, "id": str(mws_id), "version": version}
	return {"provider": "", "id": "", "version": ""}


## A record's ModWorkshop integer id, or 0; the only place a record becomes an int.
func _source_mws_id(rec: Dictionary) -> int:
	if str(rec.get("provider", "")) != HOST_MODWORKSHOP:
		return 0
	var id := str(rec.get("id", ""))
	if not id.is_valid_int():
		return 0
	var n := id.to_int()
	return n if n > 0 else 0


## Payload shared by the [mod_sources] cache and profile.json. Key order is
## fixed: the persist functions diff the serialized string against the stored one.
func _mod_source_payload(rec: Dictionary) -> Dictionary:
	var payload: Dictionary = {
		"provider": str(rec.get("provider", "")),
		"id": str(rec.get("id", "")),
	}
	var mws_id := _source_mws_id(rec)
	if mws_id > 0:
		payload["modworkshop_id"] = mws_id
	var version := str(rec.get("version", ""))
	if not version.is_empty():
		payload["version"] = version
	return payload


# Dictionaries keep insertion order, so identical records serialize identically.
func _serialize_mod_source_rec(rec: Dictionary) -> String:
	return JSON.stringify(_mod_source_payload(rec))


# Persist each scanned mod's source so missing-mod stubs can offer Download.
# Follows the _resolve_mod_source ranking: a legacy modworkshop= line never
# displaces a record another host's download wrote.
func _persist_mod_sources_for_entries(entries: Array[Dictionary]) -> void:
	var cfg := ConfigFile.new()
	var load_err := cfg.load(UI_CONFIG_PATH)
	# Never save over a config that exists but failed to parse: this runs before
	# backup recovery and would clobber the good .bak. A missing file is fine.
	if load_err != OK and FileAccess.file_exists(UI_CONFIG_PATH):
		_log_critical("mod_config.cfg exists but failed to load (error " + str(load_err)
				+ ") -- skipped saving the mod-source cache so the config backup stays"
				+ " usable. The launcher will attempt backup recovery when it loads.")
		return
	var changed := false
	for entry in entries:
		var declared := _mod_source_from_cfg(entry.get("cfg"))
		if declared["provider"] == "":
			continue
		var pk: String = str(entry.get("profile_key", ""))
		if pk == "":
			continue
		var current := str(cfg.get_value("mod_sources", pk, ""))
		if not bool(declared["explicit"]) and current != "":
			var stored := _normalize_source_record(JSON.parse_string(current))
			if stored["provider"] != "" and stored["provider"] != declared["provider"]:
				continue
		var serialized := _serialize_mod_source_rec(declared)
		if current != serialized:
			cfg.set_value("mod_sources", pk, serialized)
			changed = true
	if changed:
		_persist_ui_cfg(cfg)


# Persisted [mod_sources] cache as {profile_key -> canonical record}, normalized.
func _get_persisted_mod_sources() -> Dictionary:
	var out: Dictionary = {}
	var cfg := ConfigFile.new()
	if cfg.load(UI_CONFIG_PATH) != OK:
		return out
	if not cfg.has_section("mod_sources"):
		return out
	for key in cfg.get_section_keys("mod_sources"):
		var raw := str(cfg.get_value("mod_sources", key, ""))
		if raw == "":
			continue
		var rec := _normalize_source_record(JSON.parse_string(raw))
		if rec["provider"] != "":
			out[key] = rec
	return out


# Add one source entry; modpack apply records sources for mods it has not installed.
func _persist_single_mod_source(profile_key: String, rec: Dictionary) -> void:
	if profile_key.is_empty() or str(rec.get("provider", "")) == "":
		return
	var cfg := ConfigFile.new()
	var load_err := cfg.load(UI_CONFIG_PATH)
	# Same guard as _persist_mod_sources_for_entries.
	if load_err != OK and FileAccess.file_exists(UI_CONFIG_PATH):
		_log_critical("mod_config.cfg exists but failed to load (error " + str(load_err)
				+ ") -- skipped recording the mod source for '" + profile_key
				+ "' so the config backup stays usable.")
		return
	var serialized := _serialize_mod_source_rec(rec)
	var current := str(cfg.get_value("mod_sources", profile_key, ""))
	if current != serialized:
		cfg.set_value("mod_sources", profile_key, serialized)
		_persist_ui_cfg(cfg)
