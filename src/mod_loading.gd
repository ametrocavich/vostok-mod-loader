## ----- mod_loading.gd -----
## Runtime loading: mounts mod archives, scans their .gd files for safety
## issues, registers file-claims, instantiates autoloads, and applies
## [script_overrides] from mod.txt. Runs after mod_discovery has built the
## ordered list.

func load_all_mods(pass_label: String = "") -> void:
	_pending_autoloads.clear()
	_loaded_mod_ids.clear()
	_registered_autoload_names.clear()
	_override_registry.clear()
	_report_lines.clear()
	_database_replaced_by = ""
	_mod_script_analysis.clear()
	_archive_file_sets.clear()
	_hooks.clear()
	_pending_script_overrides.clear()
	_applied_script_overrides.clear()
	_hooked_methods.clear()
	_any_mod_declared_registry = false

	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(TMP_DIR))

	var candidates: Array[Dictionary] = []
	for entry in _ui_mod_entries:
		if not entry["enabled"]:
			continue
		candidates.append(entry.duplicate())
	candidates.sort_custom(_compare_load_order)

	if candidates.is_empty():
		_log_info("No mods enabled.")
		return

	# Warn about duplicate mod names -- likely a packaging mistake or fork.
	# The sort is still deterministic (file_name tiebreaker), but users should know.
	for i in range(1, candidates.size()):
		if (candidates[i]["mod_name"] as String).to_lower() \
				== (candidates[i - 1]["mod_name"] as String).to_lower():
			_log_warning("Duplicate mod name '" + candidates[i]["mod_name"]
					+ "' -- archives '" + candidates[i - 1]["file_name"]
					+ "' and '" + candidates[i]["file_name"]
					+ "'. Load order tie broken by archive filename.")

	var header := "=== Load Order" + (" (" + pass_label + ")" if pass_label != "" else "") + " ==="
	_log_info(header)
	for i in candidates.size():
		var c: Dictionary = candidates[i]
		_log_info("  [" + str(i + 1) + "] " + c["mod_name"] + " | " + c["file_name"]
				+ " [priority=" + str(c["priority"]) + "]")
	_log_info("=" .repeat(header.length()))

	for load_index in candidates.size():
		_process_mod_candidate(candidates[load_index], load_index)

	# After every mod has been scanned + its mod.txt parsed, collapse the
	# per-mod .hook() call analysis into the global _hooked_methods map.
	# Resolves each prefix ("controller") to a vanilla path and records
	# the declared method name. _generate_hook_pack uses this + the
	# [hooks] static declarations as the per-path per-method wrap mask.
	_merge_hook_calls_into_wrap_mask()

func _merge_hook_calls_into_wrap_mask() -> void:
	if _mod_script_analysis.is_empty():
		return
	# Build a prefix -> res://Scripts/<File>.gd map. Script enumeration is
	# driven by the PCK list (populated for the rewriter), but the class-name
	# lookup covers the hot-path names (Camera, Controller, Interface, etc.)
	# and is cheap enough to rebuild here. Fall back to lowercased filename
	# match for scripts without class_name.
	var prefix_to_path: Dictionary = {}
	for cn: String in _class_name_to_path:
		var p: String = _class_name_to_path[cn]
		prefix_to_path[p.get_file().get_basename().to_lower()] = p
	for sp: String in _all_game_script_paths:
		var key := sp.get_file().get_basename().to_lower()
		if not prefix_to_path.has(key):
			prefix_to_path[key] = sp
	for mod_name: String in _mod_script_analysis:
		var analysis: Dictionary = _mod_script_analysis[mod_name]
		for entry: Dictionary in (analysis.get("hook_calls", []) as Array):
			var prefix: String = entry["prefix"]
			var method: String = entry["method"]
			if not prefix_to_path.has(prefix):
				# Source-scan saw a .hook("<prefix>-<method>-...") call but
				# we can't resolve <prefix> to any vanilla script. After the
				# pass-1/pass-2 reorder this should only fire for genuine
				# typos or hooks targeting a renamed/removed script -- log
				# loudly so the mod author isn't debugging a silent miss.
				_log_warning("[Hooks] %s calls .hook(\"%s-%s-...\") but no vanilla script matches prefix '%s' -- check spelling, or declare the path in [hooks] in mod.txt" \
						% [mod_name, prefix, method, prefix])
				continue
			var path: String = prefix_to_path[prefix]
			if not _hooked_methods.has(path):
				_hooked_methods[path] = {}
			# Mask keys lowercase (hook_pack.gd compares fe["name"].to_lower()).
			# Hook names are lowercase by convention but mods occasionally
			# write mixed case like .hook("Interface-UpdateToolTip-pre", ...);
			# normalize so the wrap surface picks those up too.
			(_hooked_methods[path] as Dictionary)[method.to_lower()] = true

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
	if ext == "folder":
		mount_path = zip_folder_to_temp(full_path)
		if mount_path == "":
			_log_critical("Failed to zip folder: " + file_name)
			return

	# If this archive was already file-scope-mounted at static init, skip the
	# redundant re-mount. ProjectSettings.load_resource_pack with
	# replace_files=true (default in _try_mount_pack) would otherwise clobber
	# any overlay pack we mounted AFTER this archive -- e.g. an inline-hooks
	# overlay whose entries overlap with this mod's archive paths.
	if _filescope_mounted.has(full_path):
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
				_log_warning("  Invalid mod -- packaged incorrectly (nested mod.txt at " + status.substr(7) + ")")
			elif status == "parse_error":
				_log_warning("  Invalid mod -- mod.txt failed to parse")
			else:
				_log_warning("  No mod.txt -- autoloads skipped")
		return

	_loaded_mod_ids[mod_id] = true

	# [hooks] static declaration (v3.0.1 opt-in model). Escape hatch for
	# mods that can't get auto-enrolled via the .hook("prefix-method-...",
	# cb) scanner -- e.g. godot-mod-loader-compat mods using add_hook()
	# from a runtime autoload, or mods registering hooks via callbacks
	# passed in from elsewhere. Most mods using .hook() directly need no
	# section here. Formats:
	#   res://Scripts/Interface.gd = _ready, update_tooltip   # named methods
	#   res://Scripts/Interface.gd = *                        # all methods
	#   res://Scripts/Interface.gd =                          # empty = all
	# Populates _hooked_methods[path][method]; an empty inner dict is read
	# by _generate_hook_pack as apply_mask=false -> wrap every hookable
	# method. Method names are lowercased on write because hook_pack.gd
	# compares vanilla fn names via .to_lower() against the mask.
	if cfg != null and cfg.has_section("hooks"):
		for key in cfg.get_section_keys("hooks"):
			var script_path := str(key).strip_edges()
			var methods_str := str(cfg.get_value("hooks", key, "")).strip_edges()
			if script_path.is_empty():
				continue
			if not _hooked_methods.has(script_path):
				_hooked_methods[script_path] = {}
			# Parse method list. "*" anywhere (including mixed with specific
			# methods) promotes to whole-script wildcard -- the mixed form
			# used to silently ignore the wildcard and wrap only the listed
			# methods, a silent miss for mod authors who wanted "these for
			# sure, plus anything else I might hook dynamically."
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
			if has_wildcard:
				if not specific_methods.is_empty():
					_log_warning("  [hooks] %s mixes '*' with specific methods (%s); '*' wins, all methods wrapped [%s]" \
							% [script_path, ", ".join(specific_methods), mod_name])
				else:
					_log_info("  Hooks declared: %s :: * (all methods) [%s]" % [script_path, mod_name])
				# Leave the inner dict empty; hook_pack.gd treats that as wrap-all.
				continue
			for method_name in specific_methods:
				(_hooked_methods[script_path] as Dictionary)[method_name.to_lower()] = true
				_log_info("  Hook declared: %s :: %s [%s]" % [script_path, method_name, mod_name])

	# [registry] opt-in (v3.0.1). Gates Database.gd wrapping + const-to-dict
	# transform on explicit mod declaration. Without this, Database.gd stays
	# unwrapped and lib.register()/override() will not work. The presence
	# of the section is sufficient -- body content is parsed by the
	# registry handlers per registry kind (currently only SCENES).
	if cfg != null and cfg.has_section("registry"):
		_any_mod_declared_registry = true
		_log_info("  Registry declared [%s]" % mod_name)

	# [script_extend] / [script_overrides] -- full script replacements that
	# chain via Godot's extends resolution. Both section names accepted
	# (script_extend is the preferred v3.0.1 name; script_overrides is the
	# legacy alias kept for backward compat with mods written pre-cutover).
	# Each entry: vanilla_path = mod_script_path. Higher-priority mods land
	# last in the chain (most recent take_over_path wins, extends resolves
	# to the prior chain tip).
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
				})
				_log_info("  [%s] %s -> %s" % [section, vanilla_path, mod_script_path])

	if cfg == null or not cfg.has_section("autoload"):
		return

	var keys: PackedStringArray = cfg.get_section_keys("autoload")
	for key in keys:
		var autoload_name := str(key)
		var raw_path := str(cfg.get_value("autoload", key)).lstrip("*").strip_edges()
		var is_early := raw_path.begins_with("!")
		if is_early:
			raw_path = raw_path.lstrip("!")
		var res_path := raw_path

		if res_path == "":
			_log_warning("  Empty autoload path for '" + autoload_name + "' -- skipped")
			continue

		if _registered_autoload_names.has(autoload_name):
			_log_warning("Duplicate autoload name '" + autoload_name + "' -- skipped")
			continue
		_registered_autoload_names[autoload_name] = true

		if _archive_file_sets.has(file_name) and not _archive_file_sets[file_name].has(res_path):
			_log_critical("  Autoload path not found in archive: " + res_path)
			_log_critical("    Declared in mod.txt but missing from: " + file_name)
			# Log similar paths to help mod authors diagnose typos / case mismatches.
			var similar: Array[String] = []
			var target_file := res_path.get_file().to_lower()
			for p: String in _archive_file_sets[file_name]:
				if p.get_file().to_lower() == target_file:
					similar.append(p)
			if similar.size() > 0:
				_log_critical("    Similar paths in archive: " + ", ".join(similar))
			continue

		_pending_autoloads.append({
			"mod_name": mod_name, "name": autoload_name, "path": res_path,
			"is_early": is_early,
		})
		var early_tag := " [EARLY]" if is_early else ""
		_log_debug("  Autoload queued: " + autoload_name + " -> " + res_path + early_tag)
		_register_claim(res_path, mod_name, file_name, load_index)

# Logging


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


# Apply [script_overrides] / [script_extend] entries via take_over_path.
# Each override is a mod script that extends the vanilla script. Processing
# in priority order (lowest first) means each subsequent override's extends
# resolves to the previous one, forming a natural chain: ModB -> ModA -> vanilla.
#
# Legacy-syntax autofix runs on each mod source before reload() so Godot 4's
# strict parser accepts Godot-3-era patterns (bodyless blocks, `tool`,
# `onready var`, `export var`, bare `base()` calls). Narrow, semantically-
# equivalent transform. Chain composition survives -- every intermediate
# script in the chain goes through the same autofix.
func _apply_script_overrides() -> void:
	if _pending_script_overrides.is_empty():
		return
	# Sort by priority (lowest first, highest last wins take_over_path).
	_pending_script_overrides.sort_custom(func(a, b): return a["priority"] < b["priority"])
	var applied := 0
	for entry in _pending_script_overrides:
		var vanilla_path: String = entry["vanilla_path"]
		var mod_path: String = entry["mod_script_path"]
		var mod_name: String = entry["mod_name"]

		# Read source and compile fresh so extends resolves to current occupant
		# of the vanilla path (which may be a previous mod's override).
		var src_script := load(mod_path) as GDScript
		if src_script == null:
			_log_critical("[Overrides] Failed to load: %s [%s]" % [mod_path, mod_name])
			continue
		var source := src_script.source_code
		if source.is_empty():
			_log_critical("[Overrides] Empty source: %s [%s]" % [mod_path, mod_name])
			continue

		# Normalize line endings + autofix legacy syntax. GDScript's strict
		# reload parser rejects CRLF/LF mixes, bodyless blocks, and Godot-3
		# annotations; v2.1.0-era mods commonly ship with these and break
		# take_over_path when loaded as-is. Autofix is a no-op for clean
		# source so modern mods pay no transform cost.
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

	# Archives repacked on Windows via ZipFile.CreateFromDirectory() write backslash
	# separators. Godot mounts the pack but can't resolve those paths.
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
		# .hook("<prefix>-<method>[-suffix]") declarations found in source.
		# Each entry is {prefix, method}; _generate_hook_pack uses this to
		# populate the per-path per-method wrap mask. A mod declaring zero
		# hooks AND zero [hooks]/[registry] mod.txt sections leaves the
		# wrap surface empty and skips hook pack generation entirely.
		"hook_calls":              [],  # Array of {prefix, method}
	}

	for f in files:
		if f.get_extension().to_lower() == "gd":
			gd_analysis["total_gd_files"] = gd_analysis["total_gd_files"] + 1
			var gd_bytes := zr.read_file(f)
			if gd_bytes.size() > 0:
				var gd_text := gd_bytes.get_string_from_utf8()
				# Scan is unconditional. _generate_hook_pack reads hook_calls
				# to build the wrap mask; the other fields feed diagnostics
				# (conflict report, override verification).
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
	_mod_script_analysis[mod_name] = gd_analysis
	_archive_file_sets[archive_file] = path_set

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
		# Previous narrow match (get_base_script() + take_over_path(parentScript)
		# missed RTVCoop's pattern: script.take_over_path(gamePath) where gamePath
		# is a literal arg that doesn't start with "parentScript". Matching any
		# take_over_path() call is a superset that still catches AI Overhaul /
		# MCM / other parentScript-style callers.
		analysis["uses_dynamic_override"] = "take_over_path(" in text

	# UpdateTooltip() is inventory-UI only. World-item tooltips are written directly
	# by HUD._physics_process from gameData.tooltip -- this override has no effect there.
	if not analysis["calls_update_tooltip"]:
		analysis["calls_update_tooltip"] = "UpdateTooltip" in text

	# Detect base() calls -- Godot 3 pattern or removed parent method.
	if not analysis["calls_base"]:
		analysis["calls_base"] = "base(" in text

	# preload() paths -- used for stale-cache detection.
	for m_pl in _re_preload.search_all(text):
		var pl_path := m_pl.get_string(1)
		if pl_path not in (analysis["preload_paths"] as Array):
			(analysis["preload_paths"] as Array).append(pl_path)

	# .hook("<prefix>-<method>[-suffix]") calls. Capture (prefix, method)
	# pairs so _generate_hook_pack can build a per-path, per-method wrap
	# mask -- only methods a mod actually hooks get dispatch wrappers,
	# matching godot-mod-loader's method_mask semantics. Prefix is the
	# lowercase script stem ("controller", "camera"); method is the method
	# name without the -pre/-post/-callback dispatch-variant suffix.
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

	# Method declarations -- needed for mod collision detection.
	var func_matches := _re_func.search_all(text)

	# Determine the extends target for this file (if any).
	var ext_target := ""
	if m_ext:
		ext_target = m_ext.get_string(1)

	for i in func_matches.size():
		var func_name := func_matches[i].get_string(1)

		# Track method names per extends target for collision detection.
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

# Override diagnostics (developer mode)


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
