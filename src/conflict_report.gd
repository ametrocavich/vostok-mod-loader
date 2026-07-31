## ----- conflict_report.gd -----
## Developer-mode diagnostics: verify script_overrides took effect, probe the
## scene tree for mismatches, log override timing issues, and produce the
## conflict report written to user://. Loaded alongside the normal loading
## path but only runs when developer_mode=true.
##
## Mod scripts are never rewritten, so there is no marker inside a mod's source
## to test against. Whether an override took effect is determined from the
## script's resource_path and its extends chain.

# Log which mods use overrideScript() -- overrides apply after scene reload.
func _log_override_timing_warnings() -> void:
	for mod_name: String in _mod_script_analysis:
		var analysis: Dictionary = _mod_script_analysis[mod_name]
		if not analysis["uses_dynamic_override"]:
			continue
		var targets: Array = analysis["extends_paths"]
		if targets.is_empty():
			continue
		var target_list := ", ".join(targets.map(func(p): return (p as String).get_file()))
		_log_debug(mod_name + " uses overrideScript() on: " + target_list
				+ " -- applies after scene reload")

# Sanity check on dynamic overrides, run after frameworks_ready. For each mod
# that calls take_over_path() at runtime, load the declared target and log its
# resource_path plus the head of its source so the reader can see which script
# actually sits at that path. This reports; it does not diagnose. Deciding
# whether an override is stale or broken needs a signal inside the mod's own
# source, and mod sources are not rewritten.

func _verify_script_overrides() -> void:
	var printed_header: bool = false
	for mod_name: String in _mod_script_analysis:
		var analysis: Dictionary = _mod_script_analysis[mod_name]
		if not analysis.get("uses_dynamic_override", false):
			continue
		var targets: Array = analysis.get("extends_paths", [])
		if targets.is_empty():
			continue
		if not printed_header:
			# Debug, not info: a player can act on none of this. The FAIL
			# branch below stays a warning, since that one means a mod's
			# override did not apply.
			#
			# Only the logging is gated. The load() below always runs: it
			# populates the ResourceCache just as mod autoloads finish, which
			# may be load-bearing for the override mechanism itself. Confirm
			# that with a runtime test before gating it too.
			_log_debug("[OverrideVerify] === Post-autoload cache check ===")
			printed_header = true
		for vanilla_path in targets:
			var vp: String = String(vanilla_path)
			var scr := load(vp) as Script
			if scr == null:
				_log_warning("[OverrideVerify] %s | %s | FAIL: load() returned null" % [mod_name, vp])
				continue
			var src: String = scr.source_code
			var src_head: String = src.substr(0, 60).replace("\n", " | ").replace("\t", " ")
			_log_debug("[OverrideVerify] %s | %s | resource_path=%s src_head=[%s]" \
					% [mod_name, vp, scr.resource_path, src_head])

# Conflict summary + report output (developer mode; called from every
# finish path in lifecycle.gd)

func _print_conflict_summary() -> void:
	_log_info("")
	_log_info("============================================")
	_log_info("=== ModLoader Compatibility Summary      ===")
	_log_info("============================================")
	_log_info("Mods loaded:  " + str(_loaded_mod_ids.size()))

	var conflicted_paths: Array[String] = []
	for res_path: String in _override_registry:
		var claims: Array = _override_registry[res_path]
		if claims.size() > 1:
			conflicted_paths.append(res_path)

	_log_info("Conflicting resource paths: " + str(conflicted_paths.size()))

	if conflicted_paths.is_empty():
		_log_info("No resource path conflicts -- all mods appear compatible.")
	else:
		_log_info("")
		_log_info("--- Conflicted Paths (last loader wins) ---")
		for res_path in conflicted_paths:
			var claims: Array = _override_registry[res_path]
			var winner: Dictionary = claims[claims.size() - 1]
			_log_warning("CONFLICT: " + res_path)
			for claim in claims:
				var marker := " <-- wins" if claim == winner else ""
				_log_info("    [" + str(claim["load_index"] + 1) + "] "
						+ claim["mod_name"] + " via " + claim["archive"] + marker)

	if not _hooks.is_empty():
		_log_info("")
		_log_info("--- Hook Registrations ---")
		for hook_name: String in _hooks:
			var arr: Array = _hooks[hook_name]
			if arr.size() > 0:
				_log_info("  %s (%d callback(s))" % [hook_name, arr.size()])

	_log_info("============================================")
	_log_info("")

func _write_conflict_report() -> void:
	var f := FileAccess.open(CONFLICT_REPORT_PATH, FileAccess.WRITE)
	if f == null:
		_log_warning("Could not write report to: " + CONFLICT_REPORT_PATH)
		return
	# store_line returns bool since Godot 4.3. Without checking it, a mid-file
	# failure (disk full, quota) truncates the report while the log claims
	# success.
	var ok := true
	for line in _report_lines:
		ok = f.store_line(line) and ok
	f.close()
	if ok:
		_log_info("Conflict report written to: " + CONFLICT_REPORT_PATH)
	else:
		_log_warning("Conflict report PARTIAL/FAILED write to: " + CONFLICT_REPORT_PATH)
