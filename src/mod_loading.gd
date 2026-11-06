## Runtime loading: mounts mod archives, scans their .gd files, registers file
## claims, queues autoloads and [script_extend] overrides, then applies them.

# res_path -> {mod_name: true}, for the reconciliation report in hook_pack.gd.
# _hooked_methods cannot carry it: an empty inner dict is the wildcard mask.
var _hook_declared_by: Dictionary = {}
# {mod_name: true} for [registry] or a B_Loader call; REGISTRY_TARGETS have no [hooks] declarer.
var _registry_declared_by: Dictionary = {}
var _database_replaced_by := ""

const MOD_TXT_KNOWN_SECTIONS: Array[String] = [
	"mod", "autoload", "hooks", "registry",
	"script_extend", "script_overrides",
	"dependencies", "updates",
	"rtvmodlib",  # legacy, tolerated no-op
]

func load_all_mods(pass_label: String = "") -> void:
	_pending_autoloads.clear()
	_loaded_mod_ids.clear()
	_registered_autoload_names.clear()
	_override_registry.clear()
	_report_lines.clear()
	_database_replaced_by = ""
	_mod_script_analysis.clear()
	_archive_file_sets.clear()
	_pending_script_overrides.clear()
	_hook_declared_by.clear()
	_registry_declared_by.clear()
	# _hooks and _hooked_methods stay: a `!` early autoload has already run and hooked.
	_any_mod_declared_registry = false
	_loaded_profile = _active_profile

	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(TMP_DIR))

	var pick := _loadable_enabled_entries(true)
	var candidates: Array[Dictionary] = pick["loadable"]
	var enabled_total: int = pick["enabled_count"]
	if enabled_total == 0:
		_log_info("No mods enabled.")
		return
	if candidates.is_empty():
		_log_warning(("All %d enabled mod(s) are blocked by missing dependencies -- nothing will load."
				+ " Fix or override from the Mods tab.") % enabled_total)
		return
	if pick["adjusted"]:
		_log_info("Load order adjusted: required dependencies load before their dependents.")
	for ck in pick["cycle_keys"]:
		_log_warning("Dependency cycle involving '%s' -- load order left as priorities." % ck)

	for i in range(1, candidates.size()):
		if candidates[i]["mod_name"].to_lower() == candidates[i - 1]["mod_name"].to_lower():
			_log_warning("Duplicate mod name '%s' in '%s' and '%s'; tie broken by file name"
					% [candidates[i]["mod_name"], candidates[i - 1]["file_name"], candidates[i]["file_name"]])

	# Disabled mods are otherwise invisible in the log.
	var found_total := _ui_mod_entries.size()
	var accounting := "Found %d mod(s) -- %d enabled, %d loading" % [found_total, enabled_total, candidates.size()]
	if enabled_total > candidates.size():
		accounting += ", %d blocked by dependencies" % (enabled_total - candidates.size())
	accounting += ", %d disabled (profile \"%s\")" % [maxi(0, found_total - enabled_total), _active_profile]
	_log_info(accounting)

	var header := "=== Load Order" + (" (" + pass_label + ")" if pass_label != "" else "") + " ==="
	_log_info(header)
	for i in candidates.size():
		var c: Dictionary = candidates[i]
		_log_info("  [%d] %s | %s [priority=%s]" % [i + 1, c["mod_name"], c["file_name"], c["priority"]])
	_log_info("=".repeat(header.length()))

	for load_index in candidates.size():
		_process_mod_candidate(candidates[load_index], load_index)

	_merge_scanned_hooks()

# Literal .hook("<stem>-<method>") calls found by the scan become wrap-mask entries.
func _merge_scanned_hooks() -> void:
	if _mod_script_analysis.is_empty():
		return
	var prefix_to_path: Dictionary = {}
	for cn: String in _class_name_to_path:
		var p: String = _class_name_to_path[cn]
		prefix_to_path[p.get_file().get_basename().to_lower()] = p
	for sp: String in _all_game_script_paths:
		var key := sp.get_file().get_basename().to_lower()
		if not prefix_to_path.has(key):
			prefix_to_path[key] = sp
	if prefix_to_path.is_empty():
		for mod_name: String in _mod_script_analysis:
			if not _mod_script_analysis[mod_name]["hook_calls"].is_empty():
				_log_critical("[Hooks] Game script list is empty, so every scanned .hook() call is dropped")
				break
		return
	for mod_name: String in _mod_script_analysis:
		var resolved := 0
		for hc: Dictionary in _mod_script_analysis[mod_name]["hook_calls"]:
			var prefix: String = hc["prefix"]
			var method: String = hc["method"]
			if not prefix_to_path.has(prefix):
				_log_warning(("[Hooks] %s calls .hook(\"%s-%s-...\") but no vanilla script matches prefix '%s'"
						+ " -- check spelling, or declare the path in [hooks] in mod.txt")
						% [mod_name, prefix, method, prefix])
				continue
			var path: String = prefix_to_path[prefix]
			(_hook_declared_by.get_or_add(path, {}) as Dictionary)[mod_name] = true
			resolved += 1
			# Mask keys are lowercase (hook_pack.gd compares lowercased names), and
			# a method inserted into a wildcard would narrow it.
			if not _hooked_methods.has(path):
				_hooked_methods[path] = {method.to_lower(): true}
			elif not _mask_is_wildcard(_hooked_methods[path]):
				_hooked_methods[path][method.to_lower()] = true
		if resolved > 0:
			_log_debug("[Hooks] %d scanned .hook() call(s) resolved to vanilla scripts [%s]" % [resolved, mod_name])

# Mount, scan, then apply the mod.txt sections. Handlers must be idempotent (Pass 2 re-runs
# load_all_mods); an empty new section also needs _parse_mod_txt's [registry] sentinel key.
func _process_mod_candidate(c: Dictionary, load_index: int) -> void:
	var file_name: String = c["file_name"]
	_log_info("--- [" + str(load_index + 1) + "] " + c["mod_name"] + " (" + file_name + ")")
	if c["ext"] != "pck" and _loaded_mod_ids.has(c["mod_id"]):
		_log_warning("Duplicate mod id '" + c["mod_id"] + "' -- skipped: " + file_name)
		return
	var mount_path := _mount_candidate(c)
	if mount_path == "" or c["ext"] == "pck":
		return
	scan_and_register_archive_claims(mount_path, c["mod_name"], file_name, load_index)
	if c["cfg"] == null:
		# T45 greps "Invalid mod -- mod.txt parse error at"; the row warning has no prefix.
		var problem := _mod_txt_problem(c)
		var status: String = c["mod_txt_status"]
		if status.begins_with("nested:"):
			problem = "Invalid mod -- mod.txt is at %s, not the zip root; re-zip from inside that folder" \
					% status.substr(7)
		_log_warning("  " + (problem if problem.begins_with("Invalid mod") else "Invalid mod -- " + problem))
		return
	_apply_mod_txt(c, load_index)

# A re-mount (replace_files=true) would clobber packs mounted after it, such as the hook pack.
func _mount_candidate(c: Dictionary) -> String:
	var file_name: String = c["file_name"]
	var path: String = c["full_path"]
	if c["ext"] == "folder":
		# A folder mounts as its _dev.zip, rebuilt only when the folder changed:
		# overwriting a mounted zip invalidates its file handles.
		var dev_zip := _folder_dev_zip_path(path)
		if _filescope_mounted.has(dev_zip) and _folder_dev_zip_current(dev_zip):
			_log_debug("  File-scope mount active, not re-mounted: " + dev_zip)
			return dev_zip
		path = zip_folder_to_temp(path)
		if path == "":
			_log_critical("Failed to zip folder: " + file_name)
			return ""
	elif _filescope_mounted.has(path):
		_log_debug("  File-scope mount active, not re-mounted: " + path)
		return path
	if not _try_mount_pack(path):
		_log_critical("Failed to mount: " + file_name + " (path: " + path + ")")
		return ""
	_log_debug("  Mounted: " + path)
	return path

func _apply_mod_txt(c: Dictionary, load_index: int) -> void:
	var file_name: String = c["file_name"]
	var mod_name: String = c["mod_name"]
	var mod_id: String = c["mod_id"]
	var cfg: ConfigFile = c["cfg"]
	# has_mod/mod_info/loaded_mods answer from this.
	_loaded_mod_ids[mod_id] = {
		"mod_id": mod_id,
		"mod_name": mod_name,
		"version": c["version"],
		"file_name": file_name,
		"priority": c["priority"],
		"required_dependencies": c["required_dependencies"].duplicate(),
		"optional_dependencies": c["optional_dependencies"].duplicate(),
	}

	var unknown_sections: PackedStringArray = []
	for section in cfg.get_sections():
		if not (section in MOD_TXT_KNOWN_SECTIONS):
			unknown_sections.append("[" + section + "]")
	if not unknown_sections.is_empty():
		_log_info("  mod.txt section(s) %s not recognized by this loader -- ignored (typo? see the Mod-Format wiki)" \
				% ", ".join(unknown_sections))

	_apply_hooks_section(cfg, mod_name)

	# [registry] gates the Database.gd wrapping that lib.register()/override() need.
	if c["has_registry"]:
		_any_mod_declared_registry = true
		_registry_declared_by[mod_name] = true
		_log_info("  Registry declared [%s]" % mod_name)

	# B_Loader's Loader.add_shelter/add_map need the registry rewrite too. No analysis
	# exists when the archive could not be opened.
	if _mod_script_analysis.get(mod_name, {}).get("calls_bloader_api", false):
		_registry_declared_by[mod_name] = true
		if not _any_mod_declared_registry:
			_any_mod_declared_registry = true
			_log_info("  B_Loader-style call detected [%s] -- treating as registry-declaring" % mod_name)
		else:
			_log_info("  B_Loader-style call detected [%s] -- compat shim active" % mod_name)

	_apply_extend_sections(cfg, mod_name, c["priority"])
	_apply_autoload_section(cfg, mod_name, file_name, load_index)

func _apply_hooks_section(cfg: ConfigFile, mod_name: String) -> void:
	if not cfg.has_section("hooks"):
		return
	var scripts := 0
	var methods := 0
	var wildcards := 0
	for key in cfg.get_section_keys("hooks"):
		var script_path := str(key).strip_edges()
		var methods_str := str(cfg.get_value("hooks", key, "")).strip_edges()
		if script_path.is_empty():
			continue
		var named: Array[String] = []
		var wildcard := methods_str == ""
		for raw in methods_str.split(","):
			var method := raw.strip_edges()
			if method == "*":
				wildcard = true
			elif method != "":
				named.append(method)
		if not wildcard and named.is_empty():
			_log_warning("  [hooks] %s has no valid method names ('%s') -- entry ignored [%s]"
					% [script_path, methods_str, mod_name])
			continue
		var wildcard_already := _hooked_methods.has(script_path) and _mask_is_wildcard(_hooked_methods[script_path])
		var mask: Dictionary = _hooked_methods.get_or_add(script_path, {})
		(_hook_declared_by.get_or_add(script_path, {}) as Dictionary)[mod_name] = true
		scripts += 1
		_log_debug("  [hooks] %s :: %s [%s]" % [script_path, "*" if wildcard else ", ".join(named), mod_name])
		if wildcard:
			wildcards += 1
			if not named.is_empty():
				_log_warning("  [hooks] %s mixes '*' with specific methods (%s); '*' wins [%s]"
						% [script_path, ", ".join(named), mod_name])
			# A wildcard from any mod wins over earlier method lists.
			if not _mask_is_wildcard(mask):
				_log_info("  [hooks] '*' from %s widens the earlier method list for %s" % [mod_name, script_path])
				_mask_widen(mask)
			continue
		methods += named.size()
		if not wildcard_already:
			for method in named:
				mask[method.to_lower()] = true
	if scripts > 0:
		var wc_tag := (", %d wildcard (all methods)" % wildcards) if wildcards > 0 else ""
		_log_info("  [hooks] %d method(s) across %d script(s)%s [%s]" % [methods, scripts, wc_tag, mod_name])

func _apply_extend_sections(cfg: ConfigFile, mod_name: String, priority: int) -> void:
	for section in ["script_extend", "script_overrides"]:
		if not cfg.has_section(section):
			continue
		for key in cfg.get_section_keys(section):
			var vanilla_path := str(key).strip_edges()
			var mod_script_path := str(cfg.get_value(section, key)).strip_edges()
			if vanilla_path.is_empty() or mod_script_path.is_empty():
				_log_warning("  Empty [%s] entry -- skipped" % section)
				continue
			_pending_script_overrides.append({
				"vanilla_path": vanilla_path,
				"mod_script_path": mod_script_path,
				"mod_name": mod_name,
				"priority": priority,
				"seq": _pending_script_overrides.size(),
			})
			_log_info("  [%s] %s -> %s" % [section, vanilla_path, mod_script_path])

# An autoload value may lead with "!" (load in Pass 1) and "*" (Godot's instantiate-as-node),
# in either order. Returns [path, is_early]; discovery and loading both read it here.
func _split_autoload_marker(raw: String) -> Array:
	var path := raw.strip_edges()
	var is_early := false
	while path.begins_with("!") or path.begins_with("*"):
		is_early = is_early or path.begins_with("!")
		path = path.substr(1)
	return [path.strip_edges(), is_early]

# An entry whose path is in neither the archive, the game nor another mod is dropped.
func _apply_autoload_section(cfg: ConfigFile, mod_name: String, file_name: String, load_index: int) -> void:
	if not cfg.has_section("autoload"):
		return
	for key in cfg.get_section_keys("autoload"):
		var autoload_name := str(key)
		var marker := _split_autoload_marker(str(cfg.get_value("autoload", key)))
		var res_path: String = marker[0]
		var is_early: bool = marker[1]
		if res_path == "":
			_log_warning("  Empty autoload path for '" + autoload_name + "' -- skipped")
			continue
		if _registered_autoload_names.has(autoload_name):
			_log_warning("Duplicate autoload name '" + autoload_name + "' -- skipped")
			continue
		# No file set exists when the archive could not be opened.
		if _archive_file_sets.has(file_name) and not _archive_file_sets[file_name].has(res_path) \
				and not ResourceLoader.exists(res_path):
			_log_critical("  Autoload path not found: %s (not in %s, any mod or the game)" % [res_path, file_name])
			var similar: Array[String] = []
			for p: String in _archive_file_sets[file_name]:
				if p.get_file().to_lower() == res_path.get_file().to_lower():
					similar.append(p)
			if not similar.is_empty():
				_log_critical("    Similar paths in archive: " + ", ".join(similar))
			continue
		_registered_autoload_names[autoload_name] = true
		_pending_autoloads.append({"mod_name": mod_name, "name": autoload_name, "path": res_path, "is_early": is_early})
		_log_debug("  Autoload queued: " + autoload_name + " -> " + res_path + (" [EARLY]" if is_early else ""))
		_register_claim(res_path, mod_name, file_name, load_index)

func _register_claim(res_path: String, mod_name: String, archive: String, load_index: int) -> void:
	var claims: Array = _override_registry.get_or_add(res_path, [])
	for existing in claims:
		if existing["mod_name"] == mod_name and existing["archive"] == archive:
			return
	claims.append({"mod_name": mod_name, "archive": archive, "load_index": load_index})

# take_over_path each override, lowest priority first, so each one's extends
# resolves to the previous occupant: ModB -> ModA -> vanilla.
func _apply_script_overrides() -> void:
	if _pending_script_overrides.is_empty():
		return
	# sort_custom is not stable; ties keep append order (seq). Pass 2 entries come
	# from the pass state file.
	_pending_script_overrides.sort_custom(func(a, b):
		if a["priority"] != b["priority"]:
			return a["priority"] < b["priority"]
		return a.get("seq", 0) < b.get("seq", 0))
	var applied := 0
	for entry in _pending_script_overrides:
		var vanilla_path: String = entry["vanilla_path"]
		var mod_path: String = entry["mod_script_path"]
		var mod_name: String = entry["mod_name"]
		var src_script := load(mod_path) as GDScript
		if src_script == null:
			_log_critical("[Overrides] Failed to load: %s [%s]" % [mod_path, mod_name])
			continue
		if src_script.source_code.is_empty():
			_log_critical("[Overrides] Empty source: %s [%s]" % [mod_path, mod_name])
			continue
		# Compile fresh so extends resolves to the current occupant of the vanilla path.
		var new_script := GDScript.new()
		new_script.source_code = src_script.source_code
		var err := new_script.reload()
		if err != OK:
			_log_critical("[Overrides] Compile failed for %s (error %d) [%s]" % [mod_path, err, mod_name])
			continue
		new_script.take_over_path(vanilla_path)
		_applied_script_overrides[vanilla_path] = true
		applied += 1
		_log_info("[Overrides] Applied: %s -> %s [%s]" % [vanilla_path, mod_path, mod_name])
	if applied > 0:
		_log_info("[Overrides] Applied %d script override(s)" % applied)

func scan_and_register_archive_claims(archive_path: String, mod_name: String,
		archive_file: String, load_index: int) -> void:
	var zr := ZIPReader.new()
	if zr.open(archive_path) != OK:
		_log_warning("  Could not scan archive: " + archive_file)
		return
	var files := zr.get_files()

	# Windows ZipFile.CreateFromDirectory() writes backslash separators.
	var backslashed := Array(files).filter(func(f): return "\\" in f)
	if not backslashed.is_empty():
		_log_critical("  BAD ZIP: " + str(backslashed.size()) + " entries use Windows backslash paths.")
		_log_critical("    Re-pack with 7-Zip. Example bad entry: '" + backslashed[0] + "'")

	var path_set: Dictionary = {}
	var gd_analysis: Dictionary = {
		"take_over_literal_paths": [],
		"extends_paths": [],
		"uses_dynamic_override": false,
		"total_gd_files": 0,
		"hook_calls": [],  # {prefix, method}
		"calls_bloader_api": false,
	}
	for f in files:
		if f.get_extension().to_lower() == "gd":
			gd_analysis["total_gd_files"] += 1
			var gd_bytes := zr.read_file(f)
			if gd_bytes.size() > 0:
				var gd_text := gd_bytes.get_string_from_utf8()
				_scan_gd_source(gd_text, gd_analysis)
				if not _class_name_to_path.is_empty():
					_check_class_name_safety(gd_text, f)

		var res_path := _normalize_to_res_path(f)
		if res_path == "" and f.ends_with(".remap"):
			res_path = _normalize_to_res_path(f.trim_suffix(".remap"))
		if res_path == "":
			continue
		path_set[res_path] = true
		_register_claim(res_path, mod_name, archive_file, load_index)

		if res_path.get_file().to_lower() == "database.gd":
			if _database_replaced_by == "":
				_database_replaced_by = mod_name
				_log_info("  DATABASE OVERRIDE: " + mod_name + " replaces Database.gd")
			else:
				_log_warning("  DATABASE COPY: " + mod_name + " bundles a private Database.gd at " + res_path)
				_log_warning("    Hardcoded preload() paths may break if companion mods aren't present.")
	zr.close()

	if _mod_script_analysis.has(mod_name):
		# Two archives can share a display name; merge so both scans reach the wrap mask.
		var into: Dictionary = _mod_script_analysis[mod_name]
		for k in ["take_over_literal_paths", "extends_paths", "hook_calls"]:
			for item in gd_analysis[k]:
				if item not in into[k]:
					into[k].append(item)
		into["uses_dynamic_override"] = into["uses_dynamic_override"] or gd_analysis["uses_dynamic_override"]
		into["calls_bloader_api"] = into["calls_bloader_api"] or gd_analysis["calls_bloader_api"]
		into["total_gd_files"] += gd_analysis["total_gd_files"]
	else:
		_mod_script_analysis[mod_name] = gd_analysis
	_archive_file_sets[archive_file] = path_set

	_log_debug("  %d resource path(s)" % path_set.size())
	if gd_analysis["total_gd_files"] > 0:
		_log_debug("  %d .gd file(s), %d override target(s)%s" % [gd_analysis["total_gd_files"],
				gd_analysis["take_over_literal_paths"].size() + gd_analysis["extends_paths"].size(),
				" [uses overrideScript()]" if gd_analysis["uses_dynamic_override"] else ""])

func _scan_gd_source(text: String, analysis: Dictionary) -> void:
	for m in _re_take_over.search_all(text):
		if m.get_string(1) not in analysis["take_over_literal_paths"]:
			analysis["take_over_literal_paths"].append(m.get_string(1))
	var m_ext := _re_extends.search(text)
	if m_ext and m_ext.get_string(1) not in analysis["extends_paths"]:
		analysis["extends_paths"].append(m_ext.get_string(1))
	# Any take_over_path() call counts, the literal-path form included.
	if "take_over_path(" in text:
		analysis["uses_dynamic_override"] = true
	# Substring match: a false positive only over-treats the mod as registry-declaring.
	if "Loader.add_shelter(" in text or "Loader.add_map(" in text:
		analysis["calls_bloader_api"] = true
	# .hook("<prefix>-<method>[-suffix]"): prefix is the lowercase script stem,
	# method drops the -pre/-post/-callback suffix.
	for m_hk in _re_hook_call.search_all(text):
		var hc := {"prefix": m_hk.get_string(2).to_lower(), "method": m_hk.get_string(3)}
		if hc not in analysis["hook_calls"]:
			analysis["hook_calls"].append(hc)

func _check_class_name_safety(text: String, file_path: String) -> void:
	for m_cn in _re_class_name.search_all(text):
		var cn := m_cn.get_string(1)
		if _class_name_to_path.has(cn) and _normalize_to_res_path(file_path) != _class_name_to_path[cn]:
			_log_critical("  CONFLICT: %s re-declares class_name %s (game has it at %s)"
					% [file_path, cn, _class_name_to_path[cn]])
	for m_to in _re_take_over.search_all(text):
		var to_path := m_to.get_string(1)
		for cn: String in _class_name_to_path:
			if _class_name_to_path[cn] == to_path:
				_log_critical("  DANGER: %s calls take_over_path on class_name script %s (%s) -- this will crash"
						% [file_path, to_path, cn])
				break

func _instantiate_autoload(mod_name: String, autoload_name: String, res_path: String) -> void:
	var resource: Resource = load(res_path)
	if resource == null:
		_log_critical("Autoload failed: %s -> %s [%s]" % [autoload_name, res_path, mod_name])
		if _developer_mode:
			_log_debug("  FileAccess=%s  ResourceLoader=%s"
					% [FileAccess.file_exists(res_path), ResourceLoader.exists(res_path)])
		return
	if get_tree().root.has_node(autoload_name):
		_log_warning("Autoload name '%s' conflicts with /root/%s; Godot will rename it [%s]"
				% [autoload_name, autoload_name, mod_name])

	var instance: Variant = null
	if resource is PackedScene:
		instance = (resource as PackedScene).instantiate()
		if instance == null:
			_log_critical("PackedScene.instantiate() returned null: %s -> %s [%s]"
					% [autoload_name, res_path, mod_name])
			return
	elif resource is GDScript:
		if not (resource as GDScript).can_instantiate():
			_log_critical("Autoload script failed to compile: %s -> %s [%s]; see the parse errors above"
					% [autoload_name, res_path, mod_name])
			return
		instance = (resource as GDScript).new()
		if instance == null:
			_log_warning("Autoload script returned null: " + autoload_name)
			return
		if not (instance is Node):
			_log_warning("Autoload is not a Node -- not added to tree: %s [%s]" % [autoload_name, mod_name])
			return
	else:
		_log_warning("Autoload is not a PackedScene or GDScript: %s -> %s [%s]" % [autoload_name, res_path, mod_name])
		return
	(instance as Node).name = autoload_name
	get_tree().root.add_child(instance as Node)
	_log_debug("Autoload instantiated: %s [%s]" % [autoload_name, mod_name])
