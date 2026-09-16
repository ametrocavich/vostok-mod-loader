## ----- mod_loading.gd -----
## Runtime loading: mounts mod archives, scans their .gd files, registers
## file claims, instantiates autoloads, applies [script_extend] overrides.

# Attribution side channel for the hook reconciliation in hook_pack.gd:
# res_path -> {mod_name: true}. _hooked_methods cannot carry it, since an
# empty inner dict is the wildcard sentinel. Diagnostic only.
var _hook_declared_by: Dictionary = {}
var _database_replaced_by := ""

# Every mod.txt section this loader reads anywhere. Feeds only the
# unrecognized-section notice in _process_mod_candidate.
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
	_archive_zip_paths.clear()
	_hooks.clear()
	_pending_script_overrides.clear()
	_hooked_methods.clear()
	_hook_declared_by.clear()
	_any_mod_declared_registry = false

	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(TMP_DIR))

	var pick := _loadable_enabled_entries(true, true)
	var candidates: Array[Dictionary] = pick["loadable"]
	if int(pick["enabled_count"]) == 0:
		_log_info("No mods enabled.")
		return
	if candidates.is_empty():
		_log_warning("All %d enabled mod(s) are blocked by missing dependencies -- nothing will load. Fix or override from the Mods tab." % int(pick["enabled_count"]))
		return
	if bool(pick["adjusted"]):
		_log_info("Load order adjusted: required dependencies load before their dependents.")
	for ck in pick["cycle_keys"]:
		_log_warning("Dependency cycle involving '%s' -- load order left as priorities." % str(ck))

	# Duplicate mod names are likely a packaging mistake or fork; say so.
	for i in range(1, candidates.size()):
		if (candidates[i]["mod_name"] as String).to_lower() \
				== (candidates[i - 1]["mod_name"] as String).to_lower():
			_log_warning("Duplicate mod name '" + candidates[i]["mod_name"]
					+ "' -- archives '" + candidates[i - 1]["file_name"]
					+ "' and '" + candidates[i]["file_name"]
					+ "'. Load order tie broken by archive filename.")

	# Account for every mod on disk; disabled mods are otherwise invisible in the log.
	var found_total: int = _ui_mod_entries.size()
	var enabled_total: int = int(pick["enabled_count"])
	var loading_total: int = candidates.size()
	var blocked_total: int = enabled_total - loading_total
	var accounting := "Found %d mod(s) -- %d enabled, %d loading" % [found_total, enabled_total, loading_total]
	if blocked_total > 0:
		accounting += ", %d blocked by dependencies" % blocked_total
	accounting += ", %d disabled (profile \"%s\")" % [maxi(0, found_total - enabled_total), _active_profile]
	_log_info(accounting)

	var header := "=== Load Order" + (" (" + pass_label + ")" if pass_label != "" else "") + " ==="
	_log_info(header)
	for i in candidates.size():
		var c: Dictionary = candidates[i]
		_log_info("  [" + str(i + 1) + "] " + c["mod_name"] + " | " + c["file_name"]
				+ " [priority=" + str(c["priority"]) + "]")
	_log_info("=" .repeat(header.length()))

	for load_index in candidates.size():
		_process_mod_candidate(candidates[load_index], load_index)

	# Collapse the per-mod .hook() scan into _hooked_methods.
	_merge_hook_calls_into_wrap_mask()

func _merge_hook_calls_into_wrap_mask() -> void:
	if _mod_script_analysis.is_empty():
		return
	# Prefix -> res://Scripts/<File>.gd, from the class-name lookup plus the PCK list.
	var prefix_to_path: Dictionary = {}
	for cn: String in _class_name_to_path:
		var p: String = _class_name_to_path[cn]
		prefix_to_path[p.get_file().get_basename().to_lower()] = p
	for sp: String in _all_game_script_paths:
		var key := sp.get_file().get_basename().to_lower()
		if not prefix_to_path.has(key):
			prefix_to_path[key] = sp
	# Both sources empty means no prefix can resolve; say that once.
	if prefix_to_path.is_empty():
		var any_hook_calls := false
		for mod_name: String in _mod_script_analysis:
			if not ((_mod_script_analysis[mod_name] as Dictionary).get("hook_calls", []) as Array).is_empty():
				any_hook_calls = true
				break
		if any_hook_calls:
			_log_critical("[Hooks] Game script enumeration is empty -- no .hook() call can be resolved to a vanilla script, so ALL scanned hooks are dropped this session (PCK parse failed or game layout changed). This is a loader/game problem, not a mod problem.")
		return
	for mod_name: String in _mod_script_analysis:
		var analysis: Dictionary = _mod_script_analysis[mod_name]
		var resolved_count := 0
		for entry: Dictionary in (analysis.get("hook_calls", []) as Array):
			var prefix: String = entry["prefix"]
			var method: String = entry["method"]
			if not prefix_to_path.has(prefix):
				# No vanilla script matches the prefix: a typo, or a renamed script.
				_log_warning("[Hooks] %s calls .hook(\"%s-%s-...\") but no vanilla script matches prefix '%s' -- check spelling, or declare the path in [hooks] in mod.txt" \
						% [mod_name, prefix, method, prefix])
				continue
			var path: String = prefix_to_path[prefix]
			# Attribution for the reconciliation report (diagnostic only).
			if not _hook_declared_by.has(path):
				_hook_declared_by[path] = {}
			(_hook_declared_by[path] as Dictionary)[mod_name] = true
			resolved_count += 1
			# Mask keys are lowercase (hook_pack.gd compares lowercased names).
			if not _hooked_methods.has(path):
				_hooked_methods[path] = {method.to_lower(): true}
				continue
			var mask: Dictionary = _hooked_methods[path] as Dictionary
			# An existing empty dict is the "[hooks] <path> = *" wildcard sentinel;
			# inserting the method would narrow wrap-all and kill the wildcard mod's hooks.
			if mask.is_empty():
				continue
			mask[method.to_lower()] = true
		if resolved_count > 0:
			_log_debug("[Hooks] %d scanned .hook() call(s) resolved to vanilla scripts [%s]" % [resolved_count, mod_name])

# One mod, one call: mount its archive, scan and register file claims, then
# apply its mod.txt sections via the handler blocks below. Adding a section:
#   1. Add an idempotent handler block (load_all_mods re-runs in Pass 2).
#   2. List the name in MOD_TXT_KNOWN_SECTIONS or every user gets the notice.
#   3. Non-Variant value syntax (bare identifiers, `*`, top-level commas) needs
#      preprocessing in _parse_mod_txt; empty presence sections need the
#      [registry] sentinel-key workaround there too.
#   4. Discovery-time UI is a separate wire: an entry field in _entry_from_config.
#   5. Document it in docs/wiki/Mod-Format.md.
# ConfigFile makes a forgotten handler silent: unknown sections parse fine.
func _process_mod_candidate(c: Dictionary, load_index: int) -> void:
	var file_name: String = c["file_name"]
	var full_path: String = c["full_path"]
	var ext:       String = c["ext"]
	var mod_name:  String = c["mod_name"]
	var mod_id:    String = c["mod_id"]
	var cfg               = c["cfg"]

	_log_info("--- [" + str(load_index + 1) + "] " + mod_name + " (" + file_name + ")")

	if ext != "pck" and _loaded_mod_ids.has(mod_id):
		_log_warning("Duplicate mod id '" + mod_id + "' -- skipped: " + file_name)
		return

	var mount_path := full_path
	var skip_remount := _filescope_mounted.has(full_path)
	if ext == "folder":
		# A folder mod's mount identity is its temp _dev.zip, the path pass state
		# records. Decided before re-zipping: overwriting a VFS-mounted zip in place
		# invalidates its file handles, so the zip is rebuilt only when the folder changed.
		mount_path = _folder_dev_zip_path(full_path)
		skip_remount = _filescope_mounted.has(mount_path) \
				and _folder_dev_zip_current(mount_path)
		if not skip_remount:
			mount_path = zip_folder_to_temp(full_path)
			if mount_path == "":
				_log_critical("Failed to zip folder: " + file_name)
				return

	# Already file-scope-mounted at static init: a re-mount (replace_files=true)
	# would clobber any pack mounted after this archive, such as the hook pack.
	if skip_remount:
		_log_debug("  File-scope mount active -- skipping re-mount")
		_log_debug("  Mount path: " + mount_path)
	elif not _try_mount_pack(mount_path):
		_log_critical("Failed to mount: " + file_name + " (path: " + mount_path + ")")
		return
	else:
		_log_debug("  Mounted OK")
		_log_debug("  Mount path: " + mount_path)

	if ext != "pck":
		var scan_path := mount_path if ext == "folder" else full_path
		scan_and_register_archive_claims(scan_path, mod_name, file_name, load_index)

	if ext == "pck" or cfg == null:
		if cfg == null and ext != "pck":
			var status: String = c.get("mod_txt_status", "none")
			if status.begins_with("nested:"):
				_log_warning("  Invalid mod -- mod.txt is inside a subfolder (" + status.substr(7) + "), not at the zip root. Zip the mod's CONTENTS so mod.txt sits at the zip root, not the folder that holds them.")
			elif status == "parse_error":
				var detail: String = c.get("mod_txt_error", "")
				if detail.is_empty():
					_log_warning("  Invalid mod -- mod.txt failed to parse")
				else:
					_log_warning("  Invalid mod -- mod.txt parse error at " + detail)
			else:
				_log_warning("  No mod.txt -- autoloads skipped")
		return

	# Full info so has_mod/mod_info/loaded_mods can answer version queries.
	_loaded_mod_ids[mod_id] = {
		"mod_id":    mod_id,
		"mod_name":  mod_name,
		"version":   String(c.get("version", "")),
		"file_name": file_name,
		"priority":  int(c.get("priority", 0)),
		"required_dependencies": (c.get("required_dependencies", []) as Array).duplicate(),
		"optional_dependencies": (c.get("optional_dependencies", []) as Array).duplicate(),
	}

	# Unrecognized-section notice: one info line per mod; never blocks loading.
	var _unknown_sections: PackedStringArray = []
	for _sect in cfg.get_sections():
		if not (_sect in MOD_TXT_KNOWN_SECTIONS):
			_unknown_sections.append("[" + _sect + "]")
	if not _unknown_sections.is_empty():
		_log_info("  mod.txt section(s) %s not recognized by this loader -- ignored (typo? see the Mod-Format wiki)" % ", ".join(_unknown_sections))

	# [hooks] static declaration, for mods the .hook() scanner cannot see.
	# Formats:
	#   res://Scripts/Interface.gd = _ready, update_tooltip   # named methods
	#   res://Scripts/Interface.gd = *                        # all methods
	#   res://Scripts/Interface.gd =                          # empty = all
	# Populates _hooked_methods[path][method], lowercased; an empty inner dict means wrap all.
	if cfg != null and cfg.has_section("hooks"):
		# Per-mod tallies for one summary line; per-method detail is debug-only.
		var hooks_scripts_declared := 0
		var hooks_methods_declared := 0
		var hooks_wildcards := 0
		for key in cfg.get_section_keys("hooks"):
			var script_path := str(key).strip_edges()
			var methods_str := str(cfg.get_value("hooks", key, "")).strip_edges()
			if script_path.is_empty():
				continue
			var mask_existed := _hooked_methods.has(script_path)
			if not mask_existed:
				_hooked_methods[script_path] = {}
			var script_mask: Dictionary = _hooked_methods[script_path] as Dictionary
			# Empty mask = wildcard sentinel from an earlier mod; do not narrow it.
			var wildcard_already := mask_existed and script_mask.is_empty()
			# "*" anywhere in the list promotes to a whole-script wildcard.
			var specific_methods: Array[String] = []
			var has_wildcard := methods_str == ""
			for raw_method in methods_str.split(","):
				var method_name: String = raw_method.strip_edges()
				if method_name == "":
					continue
				if method_name == "*":
					has_wildcard = true
					continue
				specific_methods.append(method_name)
			if not has_wildcard and specific_methods.is_empty():
				# Content that yielded no names is junk, not a wildcard.
				if not mask_existed:
					_hooked_methods.erase(script_path)
				_log_warning("  [hooks] %s has no valid method names ('%s') -- entry ignored [%s]" % [script_path, methods_str, mod_name])
				continue
			# Attribution so a lost hook target can name the declaring mod.
			if not _hook_declared_by.has(script_path):
				_hook_declared_by[script_path] = {}
			(_hook_declared_by[script_path] as Dictionary)[mod_name] = true
			hooks_scripts_declared += 1
			if has_wildcard:
				hooks_wildcards += 1
				if not specific_methods.is_empty():
					_log_warning("  [hooks] %s mixes '*' with specific methods (%s); '*' wins, all methods wrapped [%s]" \
							% [script_path, ", ".join(specific_methods), mod_name])
				else:
					_log_debug("  Hooks declared: %s :: * (all methods) [%s]" % [script_path, mod_name])
				# "*" wins across mods too; wrap-all is a superset.
				if not script_mask.is_empty():
					_log_info("  Hooks: '*' from %s widens the earlier method list for %s -- all methods wrapped" % [mod_name, script_path])
					script_mask.clear()
				continue
			hooks_methods_declared += specific_methods.size()
			if wildcard_already:
				if not specific_methods.is_empty():
					_log_debug("  Hooks declared: %s :: %s [%s] -- already covered by an earlier wildcard (*), all methods wrapped" \
							% [script_path, ", ".join(specific_methods), mod_name])
				continue
			for method_name in specific_methods:
				script_mask[method_name.to_lower()] = true
				_log_debug("  Hook declared: %s :: %s [%s]" % [script_path, method_name, mod_name])
		if hooks_scripts_declared > 0:
			var wc_tag := (", %d wildcard (all methods)" % hooks_wildcards) if hooks_wildcards > 0 else ""
			_log_info("  Hooks: %d method(s) across %d script(s)%s [%s]" \
					% [hooks_methods_declared, hooks_scripts_declared, wc_tag, mod_name])

	# [registry] opt-in gates the Database.gd wrapping and const-to-dict
	# transform; without it lib.register()/override() do not work. Presence suffices.
	if cfg != null and cfg.has_section("registry"):
		_any_mod_declared_registry = true
		_log_info("  Registry declared [%s]" % mod_name)

	# B_Loader compat: mods calling Loader.add_shelter/add_map never declare
	# [registry], but the shim needs the rewrite; treat the call sites as a declaration.
	var analysis: Dictionary = _mod_script_analysis.get(mod_name, {})
	if analysis.get("calls_bloader_api", false):
		if not _any_mod_declared_registry:
			_any_mod_declared_registry = true
			_log_info("  B_Loader-style call detected (Loader.add_shelter/add_map) [%s] -- treating as registry-declaring; compat shim activates" % mod_name)
		else:
			_log_info("  B_Loader-style call detected [%s] -- compat shim active" % mod_name)

	# [script_extend] / [script_overrides]: full script replacements chained via
	# extends. Higher-priority mods land last (latest take_over_path wins).
	var _extend_sections: Array[String] = ["script_extend", "script_overrides"]
	if cfg != null:
		for section in _extend_sections:
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
					"priority": c.get("priority", 0),
					"seq": _pending_script_overrides.size(),
				})
				_log_info("  [%s] %s -> %s" % [section, vanilla_path, mod_script_path])

	if cfg == null or not cfg.has_section("autoload"):
		return

	var keys: PackedStringArray = cfg.get_section_keys("autoload")
	for key in keys:
		var autoload_name := str(key)
		var marker: Array = _split_autoload_marker(str(cfg.get_value("autoload", key)))
		var res_path: String = marker[0]
		var is_early: bool = marker[1]

		if res_path == "":
			_log_warning("  Empty autoload path for '" + autoload_name + "' -- skipped")
			continue

		if _registered_autoload_names.has(autoload_name):
			_log_warning("Duplicate autoload name '" + autoload_name + "' -- skipped")
			continue

		if _archive_file_sets.has(file_name) and not _archive_file_sets[file_name].has(res_path):
			# Autoloads may point at a vanilla script or another mod's file; only a path that exists nowhere is an error.
			if ResourceLoader.exists(res_path):
				pass
			else:
				_log_critical("  Autoload path not found: " + res_path)
				_log_critical("    Declared in mod.txt but missing from " + file_name + " and not provided by any mod or the game")
				# Log similar paths to help mod authors diagnose typos / case mismatches.
				var similar: Array[String] = []
				var target_file := res_path.get_file().to_lower()
				for p: String in _archive_file_sets[file_name]:
					if p.get_file().to_lower() == target_file:
						similar.append(p)
				if similar.size() > 0:
					_log_critical("    Similar paths in archive: " + ", ".join(similar))
				continue

		# Reserve the name only after the path validated.
		_registered_autoload_names[autoload_name] = true

		_pending_autoloads.append({
			"mod_name": mod_name, "name": autoload_name, "path": res_path,
			"is_early": is_early,
		})
		var early_tag := " [EARLY]" if is_early else ""
		_log_debug("  Autoload queued: " + autoload_name + " -> " + res_path + early_tag)
		_register_claim(res_path, mod_name, file_name, load_index)

# Resource-claim registry: which mod claims which res:// path (conflict_report.gd).


func _register_claim(res_path: String, mod_name: String, archive: String,
		load_index: int) -> void:
	if not _override_registry.has(res_path):
		_override_registry[res_path] = []
	for existing in _override_registry[res_path]:
		if existing["mod_name"] == mod_name and existing["archive"] == archive:
			return
	_override_registry[res_path].append({
		"mod_name": mod_name, "archive": archive, "load_index": load_index,
	})

# Apply [script_overrides] / [script_extend] via take_over_path, lowest
# priority first so each override's extends resolves to the previous one:
# ModB -> ModA -> vanilla. Legacy-syntax autofix runs on each source first.
func _apply_script_overrides() -> void:
	if _pending_script_overrides.is_empty():
		return
	# sort_custom is not stable; break priority ties by append order (seq).
	_pending_script_overrides.sort_custom(func(a, b):
		if a["priority"] != b["priority"]:
			return a["priority"] < b["priority"]
		return int(a.get("seq", 0)) < int(b.get("seq", 0)))
	var applied := 0
	for entry in _pending_script_overrides:
		var vanilla_path: String = entry["vanilla_path"]
		var mod_path: String = entry["mod_script_path"]
		var mod_name: String = entry["mod_name"]

		# Compile fresh so extends resolves to the current occupant of the vanilla path.
		var src_script := load(mod_path) as GDScript
		if src_script == null:
			_log_critical("[Overrides] Failed to load: %s [%s]" % [mod_path, mod_name])
			continue
		var source := src_script.source_code
		if source.is_empty():
			_log_critical("[Overrides] Empty source: %s [%s]" % [mod_path, mod_name])
			continue

		# Normalize line endings and autofix legacy syntax; no-op for clean source.
		var normalized: String = source.replace("\r\n", "\n").replace("\r", "\n")
		var af := _rtv_autofix_legacy_syntax(normalized)
		var fixed_src: String = af["source"]
		var af_total: int = int(af["bodyless"]) + int(af["tool"]) + int(af["onready"]) \
				+ int(af["export"]) + int(af.get("base", 0))
		if af_total > 0:
			_log_info("[Overrides] Autofix %s: %d bodyless, %d tool, %d onready, %d export, %d base() -> super" \
					% [mod_path, af["bodyless"], af["tool"], af["onready"], af["export"], af.get("base", 0)])

		var new_script := GDScript.new()
		new_script.source_code = fixed_src
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

	# Archives repacked on Windows via ZipFile.CreateFromDirectory() write backslash separators.
	var backslash_count := 0
	var example_bad := ""
	for f: String in files:
		if "\\" in f:
			backslash_count += 1
			if example_bad == "":
				example_bad = f
	if backslash_count > 0:
		_log_critical("  BAD ZIP: " + str(backslash_count) + " entries use Windows backslash paths.")
		_log_critical("    Re-pack with 7-Zip. Example bad entry: '" + example_bad + "'")

	var tracked_count := 0
	var path_set: Dictionary = {}
	var gd_analysis: Dictionary = {
		"take_over_literal_paths": [],
		"extends_paths":           [],
		"uses_dynamic_override":   false,
		"lifecycle_no_super":      [],
		"calls_update_tooltip":    false,
		"class_names":             [],
		"extends_class_names":     [],
		"override_methods":        {},   # extends_path -> Array[method_name]
		"preload_paths":           [],
		"calls_base":              false, # uses base() instead of super() -- Godot 3 or removed method
		"total_gd_files":          0,
		# .hook() declarations found in source; {prefix, method} feed the wrap mask.
		"hook_calls":              [],  # Array of {prefix, method}
		# True if source calls B_Loader's Loader.add_shelter/add_map (implicit registry).
		"calls_bloader_api":       false,
	}

	for f in files:
		if f.get_extension().to_lower() == "gd":
			gd_analysis["total_gd_files"] = gd_analysis["total_gd_files"] + 1
			var gd_bytes := zr.read_file(f)
			if gd_bytes.size() > 0:
				var gd_text := gd_bytes.get_string_from_utf8()
				_scan_gd_source(gd_text, gd_analysis)
				if _class_name_to_path.size() > 0:
					_check_class_name_safety(gd_text, f, mod_name)

		var res_path := _normalize_to_res_path(f)
		if res_path == "" and f.ends_with(".remap"):
			res_path = _normalize_to_res_path(f.trim_suffix(".remap"))
		if res_path == "":
			continue

		path_set[res_path] = true
		tracked_count += 1
		_register_claim(res_path, mod_name, archive_file, load_index)

		var bare_name := res_path.get_file().get_basename().to_lower()
		var is_db_file := bare_name == "database" and res_path.get_extension().to_lower() == "gd"

		if is_db_file:
			if _database_replaced_by == "":
				_database_replaced_by = mod_name
				_log_info("  DATABASE OVERRIDE: " + mod_name + " replaces Database.gd")
			else:
				_log_warning("  DATABASE COPY: " + mod_name + " bundles a private Database.gd at " + res_path)
				_log_warning("    Hardcoded preload() paths may break if companion mods aren't present.")

	zr.close()
	if _mod_script_analysis.has(mod_name):
		# Two archives can share a display name; merge so both scans reach the wrap mask.
		var prev: Dictionary = _mod_script_analysis[mod_name]
		for k: String in ["take_over_literal_paths", "extends_paths",
				"lifecycle_no_super", "class_names", "extends_class_names",
				"preload_paths", "hook_calls"]:
			for v in (gd_analysis[k] as Array):
				if v not in (prev[k] as Array):
					(prev[k] as Array).append(v)
		for k: String in ["uses_dynamic_override", "calls_update_tooltip",
				"calls_base", "calls_bloader_api"]:
			prev[k] = prev[k] or gd_analysis[k]
		var prev_om: Dictionary = prev["override_methods"]
		for target: String in (gd_analysis["override_methods"] as Dictionary):
			if not prev_om.has(target):
				prev_om[target] = gd_analysis["override_methods"][target]
			else:
				for m in (gd_analysis["override_methods"][target] as Array):
					if m not in (prev_om[target] as Array):
						(prev_om[target] as Array).append(m)
		prev["total_gd_files"] = int(prev["total_gd_files"]) + int(gd_analysis["total_gd_files"])
	else:
		_mod_script_analysis[mod_name] = gd_analysis
	_archive_file_sets[archive_file] = path_set
	_archive_zip_paths[archive_file] = archive_path

	_log_debug("  " + str(tracked_count) + " resource path(s)")

	if gd_analysis["total_gd_files"] > 0:
		var override_count: int = (gd_analysis["take_over_literal_paths"] as Array).size() \
				+ (gd_analysis["extends_paths"] as Array).size()
		var dynamic_tag := " [uses overrideScript()]" if gd_analysis["uses_dynamic_override"] else ""
		_log_debug("  " + str(gd_analysis["total_gd_files"]) + " .gd file(s), "
				+ str(override_count) + " override target(s)" + dynamic_tag)

# GDScript source analysis

func _scan_gd_source(text: String, analysis: Dictionary) -> void:
	for m in _re_take_over.search_all(text):
		var path := m.get_string(1)
		if path not in (analysis["take_over_literal_paths"] as Array):
			(analysis["take_over_literal_paths"] as Array).append(path)

	var m_ext := _re_extends.search(text)
	if m_ext:
		var path := m_ext.get_string(1)
		if path not in (analysis["extends_paths"] as Array):
			(analysis["extends_paths"] as Array).append(path)

	# Detect extends via class_name (e.g. "extends Weapon") -- breaks override chains.
	var m_ext_cn := _re_extends_classname.search(text)
	if m_ext_cn:
		var cn := m_ext_cn.get_string(1)
		if cn not in (analysis["extends_class_names"] as Array):
			(analysis["extends_class_names"] as Array).append(cn)

	# Detect class_name declarations -- Godot bug #83542: can only be overridden once.
	for m_cn in _re_class_name.search_all(text):
		var cn := m_cn.get_string(1)
		if cn not in (analysis["class_names"] as Array):
			(analysis["class_names"] as Array).append(cn)

	if not analysis["uses_dynamic_override"]:
		# Any take_over_path() call counts (RTVCoop uses the literal-path form).
		analysis["uses_dynamic_override"] = "take_over_path(" in text

	# UpdateTooltip() is inventory-UI only; world-item tooltips come from HUD._physics_process.
	if not analysis["calls_update_tooltip"]:
		analysis["calls_update_tooltip"] = "UpdateTooltip" in text

	# Substring match: a false positive only over-treats the mod as registry-declaring.
	if not analysis["calls_bloader_api"]:
		if "Loader.add_shelter(" in text or "Loader.add_map(" in text:
			analysis["calls_bloader_api"] = true

	# Detect base() calls -- Godot 3 pattern or removed parent method.
	if not analysis["calls_base"]:
		analysis["calls_base"] = "base(" in text

	# preload() paths -- used for stale-cache detection.
	for m_pl in _re_preload.search_all(text):
		var pl_path := m_pl.get_string(1)
		if pl_path not in (analysis["preload_paths"] as Array):
			(analysis["preload_paths"] as Array).append(pl_path)

	# .hook("<prefix>-<method>[-suffix]") calls: prefix is the lowercase script
	# stem, method drops the -pre/-post/-callback suffix.
	for m_hk in _re_hook_call.search_all(text):
		var prefix := m_hk.get_string(1).to_lower()
		var method := m_hk.get_string(2)
		var already: bool = false
		for existing: Dictionary in (analysis["hook_calls"] as Array):
			if existing["prefix"] == prefix and existing["method"] == method:
				already = true
				break
		if not already:
			(analysis["hook_calls"] as Array).append({"prefix": prefix, "method": method})

	var func_matches := _re_func.search_all(text)

	var ext_target := ""
	if m_ext:
		ext_target = m_ext.get_string(1)

	for i in func_matches.size():
		var func_name := func_matches[i].get_string(1)

		if ext_target != "":
			if not (analysis["override_methods"] as Dictionary).has(ext_target):
				(analysis["override_methods"] as Dictionary)[ext_target] = []
			var method_list: Array = (analysis["override_methods"] as Dictionary)[ext_target]
			if func_name not in method_list:
				method_list.append(func_name)

		# Warn if lifecycle methods lack super() in scripts that extend game scripts.
		if ext_target == "":
			continue
		const _LIFECYCLE := ["_ready", "_process", "_physics_process",
				"_input", "_unhandled_input", "_unhandled_key_input"]
		if func_name not in _LIFECYCLE:
			continue
		var body_start := func_matches[i].get_end()
		var body_end := text.length() if i + 1 >= func_matches.size() \
				else func_matches[i + 1].get_start()
		var body := text.substr(body_start, body_end - body_start)
		if "super(" not in body and "super." not in body:
			if func_name not in (analysis["lifecycle_no_super"] as Array):
				(analysis["lifecycle_no_super"] as Array).append(func_name)

func _check_class_name_safety(text: String, file_path: String, mod_name: String) -> void:
	for m_cn in _re_class_name.search_all(text):
		var cn := m_cn.get_string(1)
		if _class_name_to_path.has(cn):
			var res_path := _normalize_to_res_path(file_path)
			var game_path: String = _class_name_to_path[cn]
			if res_path != game_path:
				_log_critical("  CONFLICT: %s re-declares class_name %s (game has it at %s)" % [file_path, cn, game_path])
	for m_to in _re_take_over.search_all(text):
		var to_path := m_to.get_string(1)
		for cn: String in _class_name_to_path:
			if _class_name_to_path[cn] == to_path:
				_log_critical("  DANGER: %s calls take_over_path on class_name script %s (%s) -- this will crash" % [file_path, to_path, cn])
				break

# Autoload instantiation


func _instantiate_autoload(mod_name: String, autoload_name: String, res_path: String) -> void:
	var resource: Resource = load(res_path)
	if resource == null:
		_log_critical("Autoload failed: %s -> %s [%s]" % [autoload_name, res_path, mod_name])
		if _developer_mode:
			_log_debug("  FileAccess=%s  ResourceLoader=%s"
					% [str(FileAccess.file_exists(res_path)), str(ResourceLoader.exists(res_path))])
		return

	if get_tree().root.has_node(autoload_name):
		_log_warning("Autoload name '" + autoload_name + "' conflicts with existing node at /root/"
				+ autoload_name + " -- Godot will rename it. [" + mod_name + "]")

	if resource is PackedScene:
		var instance: Node = (resource as PackedScene).instantiate()
		if instance == null:
			_log_critical("PackedScene.instantiate() returned null: " + autoload_name
					+ " -> " + res_path + " [" + mod_name + "]")
			return
		instance.name = autoload_name
		get_tree().root.add_child(instance)
		_log_debug("Autoload instantiated (scene): " + autoload_name + " [" + mod_name + "]")
		return

	if resource is GDScript:
		var gdscript := resource as GDScript
		if not gdscript.can_instantiate():
			_log_critical("Autoload script failed to compile: " + autoload_name
					+ " -> " + res_path + " [" + mod_name + "]")
			_log_critical("  can_instantiate() returned false. Check the Godot log above for parse errors.")
			return
		var inst: Variant = gdscript.new()
		if inst == null:
			_log_warning("Autoload script returned null: " + autoload_name)
			return
		if inst is Node:
			(inst as Node).name = autoload_name
			get_tree().root.add_child(inst as Node)
			_log_debug("Autoload instantiated (script): " + autoload_name + " [" + mod_name + "]")
			return
		_log_warning("Autoload is not a Node -- not added to tree: " + autoload_name
				+ " [" + mod_name + "]")
		return

	_log_warning("Autoload is not a PackedScene or GDScript: " + autoload_name
			+ " -> " + res_path + " [" + mod_name + "]")
