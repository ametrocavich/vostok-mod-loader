## ----- conflict_report.gd -----
## Developer-mode diagnostics: verify script_overrides took effect, probe the
## scene tree for mismatches, log override timing issues, and produce the
## conflict report written to user://. Loaded alongside the normal loading
## path but only runs when developer_mode=true.
##
## v2.4.0 cutover note: mod subclass scripts are no longer rewritten (old
## Step C removed), so the _rtv_mod_ method-prefix signal is gone. Detection
## now classifies by "does the instance's script extend the wrapped vanilla"
## rather than "does it carry a _rtv_mod_ prefix." Script path + extends-
## chain walk are the reliable signals for override-took-effect.

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

# [OverrideVerify]: Post-frameworks_ready sanity check on dynamic overrides.
#
# v2.4.0: classification is path-based, not method-prefix-based. For each
# mod that calls take_over_path() dynamically, load() the declared target
# path and log its resource_path + source head. Operators can eyeball
# whether the take_over_path took effect. Full STALE/BROKEN diagnosis
# that v3.0.0's _rtv_mod_ prefix enabled is gone with Step C -- without
# rewriting mod sources there is no reliable in-source signal to test.

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
			_log_info("[OverrideVerify] === Post-autoload cache check ===")
			printed_header = true
		for vanilla_path in targets:
			var vp: String = String(vanilla_path)
			var scr := load(vp) as Script
			if scr == null:
				_log_warning("[OverrideVerify] %s | %s | FAIL: load() returned null" % [mod_name, vp])
				continue
			var src: String = scr.source_code
			var src_head: String = src.substr(0, 60).replace("\n", " | ").replace("\t", " ")
			_log_info("[OverrideVerify] %s | %s | resource_path=%s src_head=[%s]" \
					% [mod_name, vp, scr.resource_path, src_head])

# Two-pass helpers

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

	if not _hook_swap_map.is_empty():
		_log_info("")
		_log_info("--- Framework Overrides Active ---")
		_log_info("  %d framework(s) take_over_path'd" % _hook_swap_map.size())
		for res_path: String in _hook_swap_map:
			_log_info("  %s" % res_path)

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
	for line in _report_lines:
		f.store_line(line)
	f.close()
	_log_info("Conflict report written to: " + CONFLICT_REPORT_PATH)
