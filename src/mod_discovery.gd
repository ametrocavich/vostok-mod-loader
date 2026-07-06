## ----- mod_discovery.gd -----
## Scans the mods directory, parses mod.txt metadata, builds the ordered list
## of mod entries, and handles ModWorkshop update checking + downloads.
## Everything here feeds the UI (which renders the list) and the loading
## phase (which mounts + applies them).

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
				# Record the folder's profile_key so orphan-detection knows the
				# mod is still on disk, just filtered. Without this, disabling
				# dev mode would flag every installed dev folder as "missing".
				_record_hidden_folder(_mods_dir, entry_name)
			continue
		var ext := entry_name.get_extension().to_lower()
		# Accept set. Must stay in sync with _is_safe_mod_filename (the
		# download filename gate below); mount-side, any non-zip/pck extension
		# also needs the vmz-style cache fallback (_try_mount_pack in
		# fs_archive.gd, the boot.gd static remount, hook_pack.gd's cached-zip
		# sibling resolution).
		if ext not in ["vmz", "zip", "pck"]:
			skipped_files.append(entry_name)
			continue
		if seen.has(entry_name):
			continue
		seen[entry_name] = true
		# Modpack zips co-locate with regular mods in this folder. They have
		# profile.json at root instead of mod.txt. Skip them here so they
		# don't show up as malformed mods in the Mods tab; the Modpacks tab
		# scan picks them up via collect_modpack_metadata.
		if ext == "zip" and _is_modpack_zip(_mods_dir.path_join(entry_name)):
			continue
		entries.append(_build_archive_entry(_mods_dir, entry_name, ext))
	dir.list_dir_end()
	if skipped_files.size() > 0:
		_log_debug("Skipped " + str(skipped_files.size()) + " non-mod file(s) in mods dir:")
		for sf in skipped_files:
			_log_debug("  " + sf + "  (not .vmz/.zip/.pck)")
	entries = _dedupe_by_mod_id(entries)
	# Persist any mws ids we just scanned so missing-mod stubs can offer
	# Download for mods that were once installed but have since been
	# removed. The cache survives mod deletion (we want to remember the
	# source, the file is gone but the profile may still reference it).
	_persist_mod_sources_for_entries(entries)
	if entries.size() == 0:
		_log_warning("No mods found in: " + _mods_dir)
	else:
		_log_info("Found " + str(entries.size()) + " mod(s)")
		# Per-mod listing is useful for first-launch diagnostics but spams
		# the log on re-scans (modpack apply, mod install, mod delete each
		# trigger one). Debug-level keeps it available in dev mode without
		# the noise.
		for e in entries:
			var tag := " [folder]" if e["ext"] == "folder" else ""
			_log_debug("  " + e["file_name"] + " (" + e["mod_name"] + ")" + tag)
	return entries

func _build_archive_entry(mods_dir: String, file_name: String, ext: String) -> Dictionary:
	# Breadcrumb: identifies the mod Godot's UTF-8 C++ warning (printed
	# unconditionally for non-UTF8 bytes in mod.txt / .gd / pck paths) is
	# about to complain about. Without this the user sees "Unicode parsing
	# error, some characters were replaced with ..." and can't tell which
	# mod tripped it. Debug-level so re-scans (after install/delete/apply)
	# don't spam the log -- promotes to info only in dev mode.
	_log_debug("[ModScan] inspecting " + file_name)
	var full_path := mods_dir.path_join(file_name)
	if ext == "pck":
		_last_mod_txt_status = "pck"
	var cfg: ConfigFile = read_mod_config(full_path) if ext != "pck" else null
	var entry := _entry_from_config(cfg, file_name, full_path, ext)
	entry["warnings"] = _build_entry_warnings(entry)
	entry["security_findings"] = scan_mod(full_path, ext)
	entry["risk_level"] = compute_risk_level(entry["security_findings"])
	_log_security_findings(entry)
	return entry

func _build_folder_entry(mods_dir: String, dir_name: String) -> Dictionary:
	# See _build_archive_entry for rationale.
	_log_debug("[ModScan] inspecting " + dir_name + " [folder]")
	var folder_path := mods_dir.path_join(dir_name)
	var cfg: ConfigFile = read_mod_config_folder(folder_path)
	var entry := _entry_from_config(cfg, dir_name, folder_path, "folder")
	entry["warnings"] = _build_entry_warnings(entry)
	entry["security_findings"] = scan_mod(folder_path, "folder")
	entry["risk_level"] = compute_risk_level(entry["security_findings"])
	_log_security_findings(entry)
	return entry

# Track a folder mod that's on disk but excluded from _ui_mod_entries because
# developer mode is off. Lets the orphan scan tell "dev-filtered" apart from
# "truly deleted" when rendering the missing-from-profile list.
func _record_hidden_folder(mods_dir: String, dir_name: String) -> void:
	var folder_path := mods_dir.path_join(dir_name)
	var cfg: ConfigFile = read_mod_config_folder(folder_path)
	var entry := _entry_from_config(cfg, dir_name, folder_path, "folder")
	_hidden_folder_profile_keys[entry["profile_key"]] = true
	if not entry["profile_key"].begins_with("zip:"):
		_hidden_folder_ids[entry["mod_id"]] = true

# Surface scanner findings in the boot log alongside the discovery summary.
# Logged at DEBUG -- findings are *disclosures* of "this mod uses these
# notable APIs", not warnings of malice. The UI surfaces the same data
# as a tappable "Uses N notable APIs" indicator on the mod row; the user
# decides whether the mod's stated purpose matches what it actually does.
# Dev mode enables this dump for deep investigation; regular users
# already see the relevant information in the UI.
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
# The Dictionary built below is the loader's central data structure: every
# element of _ui_mod_entries (and every loading-phase "candidate") has this
# shape. The UI holds these dicts LIVE and mutates enabled / priority /
# dependency_ignored in place (Dictionary reference semantics), so every
# key here is public shape -- update this list when adding one.
#
# Written by _entry_from_config:
#   file_name    String          archive filename / folder name. Readers:
#                                UI rows, mod_loading (mount + dup warning).
#                                Rewritten by ui.gd check_updates_for_ui
#                                after an update rename.
#   full_path    String          absolute path under <game>/mods/. Readers:
#                                mod_loading (mount), boot
#                                (_collect_enabled_archive_paths -> pass-state
#                                mount list), _compare_dedup_priority (mtime),
#                                UI (updates/delete flows). Rewritten
#                                on update rename (check_updates_for_ui).
#   ext          String          "vmz" | "zip" | "pck" | "folder". Readers:
#                                mod_loading, boot, UI (folder rows are not
#                                removable), _dedupe_by_mod_id.
#   mod_name     String          display name ([mod] name; defaults to the
#                                raw filename, or to the stem with the
#                                prefix stripped when the VostokMods
#                                "NNN-Name" priority pattern matches below).
#                                Read everywhere for display; mod_loading
#                                warns on case-insensitive dups.
#   mod_id       String          dependency + dedupe identity ([mod] id;
#                                same filename default as mod_name, and
#                                without a declared id profile_key falls
#                                back to "zip:").
#   version      String          raw [mod] version, may be "". Readers:
#                                update checks, dedupe, profile_key.
#   author       String          display-only.
#   profile_key  String          identity in profile sections -- contract
#                                comment at its construction below.
#   priority     int             clamped PRIORITY_MIN..PRIORITY_MAX;
#                                overwritten per profile and by the spinner
#                                (ui.gd _apply_profile_to_entries / row UI).
#                                Reader: _compare_load_order.
#   enabled      bool            defaults true here; real value is per-
#                                profile (ui.gd _apply_profile_to_entries),
#                                toggled in place by the UI and
#                                _enable_required_deps. Readers:
#                                _loadable_enabled_entries, boot, UI.
#   required_dependencies, optional_dependencies
#                Array[String]   from [dependencies]; read by the dependency
#                                machinery in this file, the UI row, and the
#                                per-mod metadata dict mod_loading builds
#                                for the mods-facing hooks_api.
#   dependency_warnings Array[String], dependency_blockers Array[String],
#   dependency_blockers_info Array of {id, status, display, fixable}
#                                recomputed by _refresh_dependency_status
#                                (status: not_installed | disabled |
#                                not_loaded | hidden_folder). Readers: UI rows.
#   dependencies_satisfied bool  recomputed by _refresh_dependency_status;
#                                currently write-only (no readers at HEAD).
#   dependency_ignored bool      per-profile "Load anyway" override, written
#                                by ui.gd _apply_profile_to_entries; read by
#                                the dependency filter + refresh.
#   cfg          ConfigFile|null parsed mod.txt (null for .pck and for
#                                unparseable archives). Readers: mod_loading
#                                ([registry]/[autoload] sections), boot, UI
#                                (modworkshop id lookup),
#                                _persist_mod_sources_for_entries.
#   mod_txt_status String        "ok" | "none" | "parse_error" |
#                                "nested:<path>" | "pck". Side channel set
#                                by read_mod_config* (fs_archive.gd) through
#                                _last_mod_txt_status; "pck" is preset in
#                                _build_archive_entry. Readers:
#                                _build_entry_warnings,
#                                mod_loading._process_mod_candidate
#                                (boot-log messages).
#   mod_txt_error String         parse-error detail for "parse_error".
#                                Readers: _build_entry_warnings,
#                                mod_loading._process_mod_candidate
#                                (boot-log messages).
#   has_registry bool            mod.txt declares [registry]; drives the
#                                disable-time save-safety confirm in the UI.
#
# Added by _build_archive_entry / _build_folder_entry right after:
#   warnings          Array[String]  row warnings (_build_entry_warnings).
#   security_findings Array of {rule, file, line, preview} (scan_mod).
#   risk_level        int            RISK_CLEAN | RISK_RED
#                                    (compute_risk_level).
#
# Added conditionally by _dedupe_by_mod_id:
#   duplicates_hidden Array of {file_name, version} -- only present on a
#                                winner that shadowed same-id duplicates.
#                                Reader: UI row.
#
# Added conditionally by ui.gd _apply_profile_to_entries:
#   profile_version_mismatch Dictionary {stored, current} -- present when
#                                the profile stored this mod under a
#                                different version's key; erased on every
#                                profile apply. Reader: UI row.
func _entry_from_config(cfg: ConfigFile, file_name: String, full_path: String, ext: String) -> Dictionary:
	var mod_name := file_name
	var mod_id   := file_name
	var version  := ""
	var author   := ""
	var priority := 0
	var has_mod_id := false
	var required_dependencies: Array[String] = []
	var optional_dependencies: Array[String] = []

	# VostokMods compat: parse "100-ModName.vmz" filename priority prefix.
	# The prefix is stripped from mod_name/mod_id defaults and used as fallback priority.
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
			mod_id = str(cfg.get_value("mod", "id"))
			has_mod_id = true
		version = str(cfg.get_value("mod", "version", ""))
		author = str(cfg.get_value("mod", "author", ""))
		if cfg.has_section_key("mod", "priority"):
			priority = int(str(cfg.get_value("mod", "priority")))
		elif has_filename_priority:
			priority = filename_priority
		required_dependencies = _parse_dependency_list(cfg, "required")
		optional_dependencies = _parse_dependency_list(cfg, "optional")
	elif has_filename_priority:
		priority = filename_priority
	priority = clampi(priority, PRIORITY_MIN, PRIORITY_MAX)

	# Profile key identifies the mod across ZIP renames. Uses "<id>@<version>"
	# when mod.txt declares an id (empty version allowed, yielding "<id>@"),
	# otherwise falls back to "zip:<file_name>" -- without a declared id the
	# filename is all we have and renames still orphan those profile entries.
	# CONTRACT -- parsers live far from here; keep in sync when changing:
	#   - The "<id>@<version>" form is split on the FIRST "@" (key.find("@"))
	#     by ui.gd _version_from_profile_key, _import_profile_from_parsed,
	#     _missing_mods_in_active_profile, and by modpacks.gd
	#     _get_missing_mods_for_modpack (rebuilds lowercased id + "@" + version
	#     for a case-insensitive fallback match). ui.gd _apply_profile_to_entries
	#     and _find_stored_key_for_mod_id instead prefix-match on mod_id + "@".
	#     A mod id containing "@" would mis-parse at the split sites; ids are
	#     assumed "@"-free.
	#   - The "zip:" prefix is tested with begins_with("zip:") here (_dedupe_
	#     by_mod_id, _record_hidden_folder), in ui.gd (profile apply, payload
	#     import, missing-mod rows) and stripped for display with
	#     trim_prefix("zip:") in the Mods-tab missing section.
	#   - profile_key is also the key of the persisted [mod_sources] cache and
	#     of the per-profile profile.<name>.enabled / .priority / .dep_ignore
	#     sections in mod_config.cfg, so a format change invalidates existing
	#     user configs.
	var profile_key := ("zip:" + file_name) if not has_mod_id else (mod_id + "@" + version)

	var entry := {
		"file_name": file_name, "full_path": full_path, "ext": ext,
		"mod_name": mod_name, "mod_id": mod_id, "version": version,
		"author": author,
		"profile_key": profile_key,
		"priority": priority, "enabled": true,
		"required_dependencies": required_dependencies,
		"optional_dependencies": optional_dependencies,
		"dependency_warnings": [], "dependency_blockers": [],
		"dependency_blockers_info": [], "dependency_ignored": false,
		"dependencies_satisfied": true,
		"cfg": cfg, "mod_txt_status": _last_mod_txt_status,
		"mod_txt_error": _last_mod_txt_error,
		# Presence-signal: the mod declares a [registry] section, i.e. it adds
		# game content (items/recipes/etc.) that an existing save can come to
		# depend on. Drives the disable-time save-safety confirm in the UI.
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
		# Surface the line/section the parser tripped on so authors can
		# self-correct instead of staring at a generic "re-download" hint
		# when the real problem is a typo in their own mod.txt.
		var detail: String = entry.get("mod_txt_error", "")
		if detail.is_empty():
			warnings.append("Invalid mod -- mod.txt failed to parse. Try re-downloading.")
		else:
			warnings.append("mod.txt parse error at " + detail)
	elif status.begins_with("nested:"):
		warnings.append("Invalid mod -- packaged incorrectly. Try re-downloading.")
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

	# Support whole-value strings like "foo, bar" for older author tools.
	# Godot ConfigFile already parsed strict array syntax into Array above.
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

func _compare_load_order(a: Dictionary, b: Dictionary) -> bool:
	if a["priority"] != b["priority"]:
		return a["priority"] < b["priority"]
	var a_name := (a["mod_name"] as String).to_lower()
	var b_name := (b["mod_name"] as String).to_lower()
	if a_name != b_name:
		return a_name < b_name
	# Filename tiebreaker for stable sort.
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
			# Per-profile user override ("Load anyway"): loads regardless of
			# dependency state, and stays "active" for mods that depend on IT,
			# since it really will be in the running set.
			if bool(entry.get("dependency_ignored", false)):
				continue
			for raw_dep in entry.get("required_dependencies", []):
				var dep_id := str(raw_dep).strip_edges()
				if dep_id == "":
					continue
				var dep_key := dep_id.to_lower()
				# Self-dependency is an authoring typo, not an unmet need --
				# the mod satisfies it by loading. Warned in
				# _refresh_dependency_status, never blocked.
				if dep_key == entry_key:
					continue
				# "Requires Metro Mod Loader" copied from a ModWorkshop page.
				# We ARE the loader; always satisfied.
				if LOADER_ID_ALIASES.has(dep_key):
					continue
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
# off: the mod IS on disk but won't be in the running set. Distinct status
# so the row can say how to fix it (turn Developer Mode on).
func _dep_is_hidden_folder(dep_key: String) -> bool:
	for hid in _hidden_folder_ids.keys():
		if str(hid).strip_edges().to_lower() == dep_key:
			return true
	return false

# Stable topological pass over priority-sorted candidates: a required
# dependency is hoisted above its dependent ONLY when the priority order
# violates the edge; everything else keeps its exact priority position
# (lowest-original-index-first Kahn walk). This is what SMAPI, NeoForge,
# and godot-mod-loader all do -- warn-only ordering pushes the fix onto
# users. Mods in an unresolvable chain (dependency cycle) keep their
# priority positions and are reported instead of "solved": any forced
# order would be wrong for someone.
func _apply_dependency_ordering(candidates: Array) -> Dictionary:
	var n := candidates.size()
	var key_to_index: Dictionary = {}
	for i in n:
		var k := _entry_mod_key(candidates[i])
		if k != "" and not key_to_index.has(k):
			key_to_index[k] = i
	var indegree := PackedInt32Array()
	indegree.resize(n)
	var dependents: Dictionary = {}
	var has_edges := false
	for i in n:
		var entry: Dictionary = candidates[i]
		var entry_key := _entry_mod_key(entry)
		# Required deps are hard ordering edges; optional deps are soft edges
		# that only apply when the optional dep is actually present in the set
		# (key_to_index.has). Both want "dep loads before me" -- a compat mod
		# that optionally integrates with a framework should load after it when
		# it's installed (matches SMAPI / godot-mod-loader). Optional deps never
		# block (that's _filter_dependency_ready_candidates' job, required-only);
		# here they only influence order, and a missing optional adds no edge.
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
	# Leftovers couldn't emit: they're either IN a cycle or merely downstream
	# of one. Emit all at priority positions, but only report nodes that are
	# genuinely in a cycle -- a node downstream of a cycle (its dep is stuck,
	# but it isn't itself looped) would otherwise be mislabeled "cycle in
	# chain" when its real problem is just an unresolvable required dep, which
	# the per-row blocker already explains.
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

# True iff node `start` can reach itself by following dependency edges within
# the still-unemitted subgraph -- i.e. it is genuinely part of a cycle, not
# merely stuck behind one. `dependents[x]` lists nodes that depend on x (the
# forward "x loads before them" edges); we only traverse unemitted targets.
func _node_reaches_self(start: int, dependents: Dictionary, emitted: Dictionary) -> bool:
	var seen: Dictionary = {}
	# Plain Array on purpose: dependents holds untyped arrays, and assigning
	# an untyped Array to an Array[int] var is a RUNTIME error in Godot 4
	# (typed arrays never convert implicitly). Elements are ints regardless.
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

# Single source of truth for "what actually loads, in what order".
# load_all_mods, boot's archive collection, the order panel, and the
# launch button all read this so they can never disagree (the launch
# button once promised mods while every enabled mod was blocked).
# duplicate_entries=true hands back copies (loading mutates candidates);
# the UI passes false so panels observe the live entry dicts.
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

# One click to satisfy "installed but disabled" blockers: enable every
# required dependency (transitively) that is installed and merely turned
# off. Returns what was enabled and which ids this couldn't fix.
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

# Display name for a dependency id: the installed mod's name when we have
# it, the raw id otherwise.
func _dependency_display_for_id(dep_id: String) -> String:
	var dep_key := dep_id.strip_edges().to_lower()
	var installed_by_id := _entries_by_mod_id(_ui_mod_entries)
	if installed_by_id.has(dep_key):
		return str((installed_by_id[dep_key] as Dictionary).get("mod_name", dep_id))
	return dep_id

func _refresh_dependency_status() -> void:
	var installed_by_id := _entries_by_mod_id(_ui_mod_entries)
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
			if loadable_by_id.has(dep_key):
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
			# "Load anyway" override: nothing blocks the mod (it loads), but
			# keep the info list so the row can show what's being ignored.
			entry["dependency_blockers"] = []
			entry["dependencies_satisfied"] = true
		else:
			entry["dependency_blockers"] = blockers
			entry["dependencies_satisfied"] = blockers.is_empty()

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

# Collapse same-id duplicates produced when an author publishes the same mod
# under two filenames (e.g. CoolMod_v1.zip + CoolMod_v1.1.zip). Without this
# the UI shows both rows and the load-time skip at _process_mod_candidate
# silently drops one -- the user is left to figure out which to delete.
#
# Entries with no declared mod_id (profile_key "zip:<file>") and .pck files
# are passed through untouched: their identity is the filename, which the
# scan loop already deduped.
func _dedupe_by_mod_id(entries: Array[Dictionary]) -> Array[Dictionary]:
	# Group on the same lowercased key the dependency machinery uses
	# (_entry_mod_key), so ids differing only in case collapse too --
	# otherwise both archives mount and the later one clobbers overlapping
	# res:// paths while dependency lookups bind to only one of them.
	var groups: Dictionary = {}
	for e in entries:
		var pk: String = str(e.get("profile_key", ""))
		if e["ext"] == "pck" or pk.begins_with("zip:"):
			continue
		var mid: String = _entry_mod_key(e)
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
		var pk: String = str(e.get("profile_key", ""))
		if e["ext"] == "pck" or pk.begins_with("zip:"):
			out.append(e)
			continue
		var mid: String = _entry_mod_key(e)
		if seen_ids.has(mid):
			continue
		seen_ids[mid] = true
		out.append(winners_by_id[mid])
	return out

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

func fetch_latest_modworkshop_versions(ids: Array[int]) -> Dictionary:
	var latest_versions := {}
	for chunk_ids in _chunk_int_array(ids, MODWORKSHOP_BATCH_SIZE):
		var req := HTTPRequest.new()
		req.timeout = API_CHECK_TIMEOUT
		add_child(req)
		var err := req.request(MODWORKSHOP_VERSIONS_URL,
			PackedStringArray(["Content-Type: application/json", "Accept: application/json"]),
			HTTPClient.METHOD_GET, JSON.stringify({"mod_ids": chunk_ids}))
		if err != OK:
			req.queue_free()
			continue

		var res: Array = await req.request_completed
		req.queue_free()
		if res[0] != HTTPRequest.RESULT_SUCCESS or res[1] < 200 or res[1] >= 300:
			continue
		var parsed = JSON.parse_string((res[3] as PackedByteArray).get_string_from_utf8())
		if parsed is Dictionary:
			latest_versions.merge(parsed, true)
	return latest_versions

# Pull a usable filename out of the response's Content-Disposition header.
# Supports the common attachment; filename=X and quoted filename="X" forms,
# plus the RFC 5987 filename*=UTF-8''X variant some CDNs emit. Returns "" if
# the header is missing or the value isn't a safe basename with one of the
# extensions we already accept on disk -- we never let a server pick a path
# we wouldn't have scanned in the first place.
func _filename_from_content_disposition(headers: PackedStringArray) -> String:
	for raw in headers:
		var line: String = raw
		var colon := line.find(":")
		if colon < 0:
			continue
		if line.substr(0, colon).strip_edges().to_lower() != "content-disposition":
			continue
		var value := line.substr(colon + 1).strip_edges()
		# Try filename* first -- RFC 5987 form is unicode-safe, and servers
		# that emit both prefer the encoded one for non-ASCII names.
		var star_val := _extract_disposition_param(value, "filename*")
		if star_val != "":
			var sep := star_val.find("''")
			if sep >= 0:
				star_val = star_val.substr(sep + 2).uri_decode()
			if _is_safe_mod_filename(star_val):
				return star_val.get_file()
		var plain_val := _extract_disposition_param(value, "filename")
		if plain_val != "":
			# The plain filename= form is commonly percent-encoded by CDNs
			# (filename="My%20Mod.zip"); decode so the mod doesn't install with
			# a literal %20 in its name. Validate AFTER decoding.
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

# Reject anything that isn't a plain basename with one of the mod extensions
# we accept. Stops a malicious or misconfigured server from writing under a
# parent dir or with an executable extension. The extension list must stay
# in sync with the scan accept set in collect_mod_metadata.
func _is_safe_mod_filename(name: String) -> bool:
	if name.is_empty():
		return false
	if name != name.get_file():
		return false
	return name.get_extension().to_lower() in ["vmz", "zip", "pck"]

# Pick the filename the validated download should land under. Prefers
# Content-Disposition; falls back to splicing the new mod.txt version onto
# the old stem (CoolMod_v1.0.zip -> CoolMod_v1.1.zip) so the filename never
# claims an older version than its contents. Returns the original filename
# unchanged when neither path produces something better -- a rename is
# best-effort and must never block an update.
func _derive_updated_filename(old_file_name: String, headers: PackedStringArray, new_version: String) -> String:
	var server_name := _filename_from_content_disposition(headers)
	if server_name != "":
		return server_name
	if new_version.is_empty():
		return old_file_name
	var ext := old_file_name.get_extension()
	var stem := old_file_name.get_basename()
	var rx := RegEx.new()
	rx.compile("[_-][vV]\\d+(?:\\.\\d+)*$")
	var stripped := rx.sub(stem, "")
	var new_stem := stripped + "_v" + new_version.lstrip("vV")
	return new_stem if ext.is_empty() else new_stem + "." + ext

# --- Download surfaces ------------------------------------------------------
# Five UI surfaces reach the two download entry points below. Keep this map
# current when adding one (a unified download queue would replace it):
#   1. Mods tab per-row "Update" badge (ui.gd build_mods_tab, updates block)
#      -> download_and_replace_mod(path, id); errors: "Update Failed" dialog,
#      verbatim.
#   2. Updates tab "Download"/"Retry" button (ui.gd check_updates_for_ui,
#      wired from build_updates_tab) -> download_and_replace_mod(path, id);
#      errors: generic "download failed" label + log line (error text dropped).
#   3. Browse tab "Get" + its serial queue (ui.gd build_browse_tab,
#      perform_download_for_item) -> download_new_mod(id); errors: status
#      label, verbatim.
#   4. Missing-mod stub "Download" (ui.gd build_mods_tab, missing section)
#      -> download_new_mod(id, version, true); errors: "Download Failed"
#      dialog, verbatim.
#   5. Modpack apply + retry (modpacks.gd _apply_modpack_inner,
#      retry_failed_downloads) -> download_new_mod(id, version, true);
#      errors: collected into a failures list for the apply summary; the
#      apply loop (not retry) counts the "Already have" error prefix as
#      installed rather than failed (see download_new_mod).
# Each surface implements its own busy-state, queueing and error handling;
# only Browse serializes its own downloads, and nothing prevents two surfaces
# from downloading concurrently (the _live_full_path re-resolution in ui.gd
# exists because the badge and the Updates tab can race on the same file).

# Returns { ok: bool, new_path: String, new_file_name: String }; failure
# returns additionally carry an "error": String (success returns do not,
# unlike download_new_mod which always includes the key). On success
# new_path / new_file_name reflect the on-disk filename the download landed
# under -- which may differ from target_path when the server provided a
# Content-Disposition or the mod.txt version-bumped (CoolMod_v1.0.zip ->
# CoolMod_v1.1.zip). On failure the temp + backup are cleaned up and the
# original file is left intact; new_path / new_file_name echo target_path.
func download_and_replace_mod(target_path: String, modworkshop_id: int) -> Dictionary:
	# Every failure return carries an "error" string -- the Mods-tab update
	# badge surfaces it verbatim in an "Update Failed" dialog, so "unknown"
	# must never be the answer. (The Updates tab currently drops it and shows
	# a generic "download failed" label -- see check_updates_for_ui in ui.gd.)
	var failure := {"ok": false, "new_path": target_path, "new_file_name": target_path.get_file(), "error": ""}

	var req := HTTPRequest.new()
	req.timeout = API_DOWNLOAD_TIMEOUT
	req.download_body_size_limit = 256 * 1024 * 1024
	add_child(req)
	var err := req.request(MODWORKSHOP_DOWNLOAD_URL_TEMPLATE % str(modworkshop_id))
	if err != OK:
		req.queue_free()
		failure["error"] = "Could not start the download request (error %d)" % err
		return failure
	# request_completed -> [result, http_code, headers, body]
	var res: Array = await req.request_completed
	req.queue_free()

	if res[0] != HTTPRequest.RESULT_SUCCESS or res[1] < 200 or res[1] >= 300:
		if res[0] != HTTPRequest.RESULT_SUCCESS:
			failure["error"] = "Download failed (connection error or timeout) -- check your network and retry"
		else:
			failure["error"] = "Download failed (HTTP %d)" % int(res[1])
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
	out.store_buffer(response_body)
	out.close()

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

	# Decide where the validated download should land.
	var old_file_name := target_path.get_file()
	var new_version := str(new_cfg.get_value("mod", "version", ""))
	var new_file_name := _derive_updated_filename(old_file_name, headers, new_version)
	var new_path := target_path.get_base_dir().path_join(new_file_name)

	# Refuse to overwrite an unrelated archive that already lives at the
	# derived path. Better to fail loudly than silently clobber a different
	# mod that happens to share the new versioned name.
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
	return {"ok": true, "new_path": new_path, "new_file_name": new_file_name}

func _chunk_int_array(arr: Array[int], chunk_size: int) -> Array:
	var result: Array = []
	for i in range(0, arr.size(), chunk_size):
		result.append(arr.slice(i, i + chunk_size))
	return result

# Browse-tab "Get" action. Differs from download_and_replace_mod: there's no
# existing file to back up + roll back, and we hit storage.modworkshop.net
# directly via the file record's download_url (skips the api.modworkshop.net
# 302 hop, which is just `return redirect($file->downloadUrl)` server-side).
# When `version` is empty we use /files/primary (author's default download).
# When `version` is set, we fetch that exact version's File record -- this
# is how version-pinned modpacks honor their pin instead of silently getting
# whatever's primary on apply day.
# Filename derivation falls through Content-Disposition -> ?filename= query
# param on the CDN URL -> a synthesized "mws_<id>.zip" last resort.
# Returns { ok: bool, file_name: String, error: String }. On failure the temp
# file is cleaned up and the mods/ folder is untouched.
func download_new_mod(modworkshop_id: int, version: String = "", allow_rename_on_collision: bool = false) -> Dictionary:
	var failure := {"ok": false, "file_name": "", "error": "unknown"}

	var file_meta: Variant
	if version.is_empty():
		# Try primary first (author's designated default download). If that
		# 404s, the author either hasn't set a primary or this is a link-
		# type mod with no MWS-hosted files. Fall back to /files/latest
		# which surfaces the most-recent uploaded file regardless of the
		# primary marker. Genuine "no downloadable file" mods will fail
		# at the latest step too -- caller surfaces the clear error.
		file_meta = await mws_get_primary_file(modworkshop_id)
		if not (file_meta is Dictionary):
			file_meta = await mws_get_latest_file(modworkshop_id)
	else:
		file_meta = await mws_get_file_by_version(modworkshop_id, version)
		if not (file_meta is Dictionary):
			# Don't fall back to primary: silent substitution defeats the point
			# of version pinning. Surface the gap so the caller can decide.
			failure["error"] = "Version " + version + " not available on ModWorkshop"
			return failure
	if not (file_meta is Dictionary):
		failure["error"] = "Mod has no downloadable file on ModWorkshop (off-site link or not uploaded)"
		return failure
	var download_url: String = str((file_meta as Dictionary).get("download_url", ""))
	if download_url.is_empty():
		failure["error"] = "No download URL returned"
		return failure

	if _mods_dir.is_empty():
		_mods_dir = OS.get_executable_path().get_base_dir().path_join(MOD_DIR)
	DirAccess.make_dir_recursive_absolute(_mods_dir)

	var req := HTTPRequest.new()
	req.timeout = API_DOWNLOAD_TIMEOUT
	req.download_body_size_limit = 256 * 1024 * 1024
	add_child(req)
	var headers := PackedStringArray([
		"User-Agent: " + (MWS_USER_AGENT_TEMPLATE % MODLOADER_VERSION),
	])
	var err := req.request(download_url, headers)
	if err != OK:
		req.queue_free()
		failure["error"] = "Failed to start download"
		return failure
	var res: Array = await req.request_completed
	req.queue_free()
	if res[0] != HTTPRequest.RESULT_SUCCESS or res[1] < 200 or res[1] >= 300:
		failure["error"] = "Download failed (HTTP " + str(res[1]) + ")"
		return failure
	var resp_headers: PackedStringArray = res[2]
	var body: PackedByteArray = res[3]
	if body.is_empty():
		failure["error"] = "Empty response body"
		return failure

	# Filename derivation. Same _is_safe_mod_filename gate the update path uses
	# -- never trust a server name that isn't a basename with one of our
	# accepted extensions.
	var derived_name := _filename_from_content_disposition(resp_headers)
	if derived_name.is_empty():
		var q := download_url.find("?filename=")
		if q >= 0:
			var raw := download_url.substr(q + 10).uri_decode()
			# Strip any subsequent query params (& delimits). Storage URLs rarely
			# have more than the filename param, but defensive.
			var amp := raw.find("&")
			if amp >= 0:
				raw = raw.substr(0, amp)
			if _is_safe_mod_filename(raw):
				derived_name = raw
	if derived_name.is_empty():
		derived_name = "mws_mod_" + str(modworkshop_id) + ".zip"

	var temp_path := _mods_dir.path_join(derived_name + ".download")
	var final_path := _mods_dir.path_join(derived_name)

	# Filename collision handling. By default we refuse to clobber existing
	# files (Browse "Get" semantics: "you already have this"). For modpack
	# apply (allow_rename_on_collision=true) we rename with the file's
	# version as a suffix instead, so a modpack pinning v3.0.3 of a mod
	# the user already has at v2.5.0 ends up with both files in /mods/
	# (dedup picks the higher version, modpack's enable list id-prefix
	# matches whichever one wins).
	if FileAccess.file_exists(final_path):
		if not allow_rename_on_collision:
			# LOAD-BEARING PREFIX: modpack apply (modpacks.gd _apply_modpack_inner)
			# matches err.begins_with("Already have") to count this failure as
			# already-installed instead of failed. Reword it there too, or real
			# collisions start showing up as spurious apply successes/failures.
			failure["error"] = "Already have a file named " + derived_name
			return failure
		var meta_version := str((file_meta as Dictionary).get("version", "")).strip_edges().lstrip("vV")
		if meta_version.is_empty():
			# Last-ditch: append the mod ID so we can at least install
			# something distinguishable. Better than dropping the apply.
			meta_version = str(modworkshop_id)
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
		failure["error"] = "Cannot write to mods directory"
		return failure
	out.store_buffer(body)
	out.close()

	# Validate before adopting. Mirror what collect_mod_metadata accepts:
	# zip/vmz mods must parse a root mod.txt (read_mod_config returns null
	# otherwise), but .pck mods carry no readable root mod.txt -- discovery
	# accepts them with cfg==null (see _build_archive_entry's `ext != "pck"`
	# guard), so validate a .pck by its container magic instead of demanding
	# a mod.txt that can never be there.
	var dl_ext := derived_name.get_extension().to_lower()
	if dl_ext == "pck":
		if not _looks_like_pck(temp_path):
			DirAccess.remove_absolute(temp_path)
			failure["error"] = "Downloaded file is not a valid .pck"
			return failure
	else:
		# Reject only when the CONTAINER is invalid (HTML error page,
		# truncated body) -- that's what ZIPReader.open failing means.
		# mod.txt itself is optional, same as discovery: a valid zip
		# without one still mounts as a plain resource pack, so blocking
		# the download would reject mods the loader happily runs.
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
		failure["error"] = "Cannot access mods directory"
		return failure

	if dir_access.rename(temp_path.get_file(), derived_name) != OK:
		DirAccess.remove_absolute(temp_path)
		failure["error"] = "Failed to finalize download"
		return failure

	return {"ok": true, "file_name": derived_name, "error": ""}

# Godot .pck archives begin with the 4-byte magic "GDPC". A cheap shape check
# so a CDN error page or HTML saved under a .pck name isn't adopted as a mod
# (we can't read a mod.txt from a .pck to validate it the zip way).
func _looks_like_pck(path: String) -> bool:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return false
	var magic := f.get_buffer(4)
	f.close()
	return magic == PackedByteArray([0x47, 0x44, 0x50, 0x43])


# Serialize a [mod_sources] cache value: {modworkshop_id, version} as JSON,
# omitting version when empty. Dictionary insertion order is stable, so the
# output string is identical for identical inputs.
func _serialize_mod_source(mws_id: int, version: String) -> String:
	var payload: Dictionary = {"modworkshop_id": mws_id}
	if not version.is_empty():
		payload["version"] = version
	return JSON.stringify(payload)


# Persist source info ([updates] modworkshop= + version) for any scanned mod
# into mod_config.cfg's [mod_sources] section. Lets missing-mod stubs offer
# Download for mods that were once installed but have since been removed --
# the file is gone, the cache remembers the source.
func _persist_mod_sources_for_entries(entries: Array[Dictionary]) -> void:
	var cfg := ConfigFile.new()
	var load_err := cfg.load(UI_CONFIG_PATH)
	# Refuse to persist over a config that exists but failed to parse. This
	# scan runs BEFORE _load_ui_config's backup recovery, and _persist_ui_cfg
	# copies the live file over the .bak first -- saving here would clobber
	# the good backup with the corrupt file and then replace every profile
	# with a config holding only [mod_sources]. Skipping keeps the backup
	# intact so recovery can restore it moments later; the source cache is
	# re-persisted on the next scan. A missing file is fine (first run).
	if load_err != OK and FileAccess.file_exists(UI_CONFIG_PATH):
		_log_critical("mod_config.cfg exists but failed to load (error " + str(load_err)
				+ ") -- skipped saving the mod-source cache so the config backup stays"
				+ " usable. The launcher will attempt backup recovery when it loads.")
		return
	var changed := false
	for entry in entries:
		var cfg2: ConfigFile = entry.get("cfg")
		if cfg2 == null or not cfg2.has_section_key("updates", "modworkshop"):
			continue
		var mws_id := int(str(cfg2.get_value("updates", "modworkshop", "0")))
		if mws_id <= 0:
			continue
		var pk: String = str(entry.get("profile_key", ""))
		if pk == "":
			continue
		var version_str := str(cfg2.get_value("mod", "version", "")).strip_edges()
		var serialized := _serialize_mod_source(mws_id, version_str)
		var current := str(cfg.get_value("mod_sources", pk, ""))
		if current != serialized:
			cfg.set_value("mod_sources", pk, serialized)
			changed = true
	if changed:
		_persist_ui_cfg(cfg)


# Read the persisted [mod_sources] cache as {profile_key -> {modworkshop_id,
# version}}. Empty when no cache exists. Caller can layer active-modpack
# zip sources on top if they want modpack data to take precedence.
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
		var parsed: Variant = JSON.parse_string(raw)
		if parsed is Dictionary:
			out[key] = parsed
	return out


# Add a single source entry to the cache. Used by modpack apply to record
# sources for mods the modpack references but doesn't have installed yet
# (so a download failure or skip still leaves the source recoverable later).
func _persist_single_mod_source(profile_key: String, mws_id: int, version: String) -> void:
	if profile_key.is_empty() or mws_id <= 0:
		return
	var cfg := ConfigFile.new()
	var load_err := cfg.load(UI_CONFIG_PATH)
	# Same guard as _persist_mod_sources_for_entries: never save over a
	# config that exists but failed to load, or the .bak recovery source
	# gets clobbered by _persist_ui_cfg's copy-then-save.
	if load_err != OK and FileAccess.file_exists(UI_CONFIG_PATH):
		_log_critical("mod_config.cfg exists but failed to load (error " + str(load_err)
				+ ") -- skipped recording the mod source for '" + profile_key
				+ "' so the config backup stays usable.")
		return
	var serialized := _serialize_mod_source(mws_id, version)
	var current := str(cfg.get_value("mod_sources", profile_key, ""))
	if current != serialized:
		cfg.set_value("mod_sources", profile_key, serialized)
		_persist_ui_cfg(cfg)
