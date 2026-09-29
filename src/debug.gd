## ----- debug.gd -----
## Developer-mode probes: _dev_preactivate_summary and _dev_hook_probes, run
## by hook_pack.gd only when developer mode is on.

# Developer-mode classification of the rewritten scripts before activation:
# rewrite live from static init, source matches but methods do not, empty
# source (bytecode), or other. Called from _activate_rewritten_scripts.
func _dev_preactivate_summary(res_paths: Array[String]) -> void:
	var pre_a := 0
	var pre_b := 0
	var pre_c := 0
	var pre_d := 0
	var pre_b_names: PackedStringArray = []
	var pre_c_names: PackedStringArray = []
	for res_path: String in res_paths:
		if _scripts_with_scene_preloads.has(res_path):
			continue
		var c := load(res_path) as GDScript
		if c == null:
			pre_d += 1
			continue
		var pre_rename := false
		for m in c.get_script_method_list():
			if str(m["name"]).begins_with("_rtv_vanilla_"):
				pre_rename = true
				break
		var srclen: int = c.source_code.length()
		if pre_rename:
			pre_a += 1
		elif srclen > 0:
			pre_b += 1
			pre_b_names.append(res_path)
		else:
			pre_c += 1
			pre_c_names.append(res_path)
	_log_debug("[RTVCodegen] PRE-ACTIVATE summary: inline-live=%d, pinned-with-source=%d, pinned-tokenized=%d, other=%d / total=%d" \
			% [pre_a, pre_b, pre_c, pre_d, res_paths.size()])
	if pre_b > 0:
		_log_debug("[RTVCodegen]   pinned-with-source (GDScriptCache has our text but compiled methods are vanilla): %s" \
				% ", ".join(Array(pre_b_names).slice(0, 25)))
	if pre_c > 0:
		_log_debug("[RTVCodegen]   pinned-tokenized (PCK .gdc, our static-init preload missed): %s" \
				% ", ".join(Array(pre_c_names).slice(0, 25)))

# Developer-mode end-to-end probes, called once from _activate_rewritten_scripts:
# real hooks on known methods across menu tick, menu click and gameplay, the
# autoload inspection, the registry smoke probe and the 30-second report
# timer. The first set fires and the last does not: timing. None fire but
# the dispatch counter is high: the _hooks lookup is broken.
func _dev_hook_probes() -> void:
	var probe_counts := {
		"loader_pp": 0, "simulation_proc": 0, "profiler_proc": 0,
		"menu_ready": 0, "settings_load": 0,
		"controller_pp": 0, "character_pp": 0, "camera_pp": 0,
	}
	Engine.set_meta("_rtv_probe_counts", probe_counts)
	Engine.set_meta("_rtv_probe_first_args", {})
	var _bump := func(key: String, arg):
		var pc: Dictionary = Engine.get_meta("_rtv_probe_counts", {})
		pc[key] = int(pc.get(key, 0)) + 1
		Engine.set_meta("_rtv_probe_counts", pc)
		var fa: Dictionary = Engine.get_meta("_rtv_probe_first_args", {})
		if not fa.has(key):
			fa[key] = str(arg)
			Engine.set_meta("_rtv_probe_first_args", fa)
	hook("loader-_physics_process-pre", func(d): _bump.call("loader_pp", d), 100)
	hook("simulation-_process-pre", func(d): _bump.call("simulation_proc", d), 100)
	hook("profiler-_process-pre", func(d): _bump.call("profiler_proc", d), 100)
	hook("menu-_ready-pre", func(): _bump.call("menu_ready", "(no args)"), 100)
	hook("settings-loadpreferences-pre", func(): _bump.call("settings_load", "(no args)"), 100)
	hook("controller-_physics_process-pre", func(d): _bump.call("controller_pp", d), 100)
	hook("character-_physics_process-pre", func(d): _bump.call("character_pp", d), 100)
	hook("camera-_physics_process-pre", func(d): _bump.call("camera_pp", d), 100)

	# Autoload inspection (dev-only): a live autoload node can still hold the
	# original bytecode via get_script() even when the resource shows the renames.
	var autoload_names: Array[String] = ["Database", "GameData", "Settings",
			"Menu", "Loader", "Inputs", "Mode", "Profiler", "Simulation"]
	var root := get_tree().root
	for aname: String in autoload_names:
		var node: Node = root.get_node_or_null(aname)
		if node == null:
			_log_info("[RTVCodegen] AUTOLOAD-CHECK %s: node NOT in tree" % aname)
			continue
		var scr := node.get_script() as GDScript
		if scr == null:
			_log_info("[RTVCodegen] AUTOLOAD-CHECK %s: no script attached" % aname)
			continue
		var has_rename := false
		for m in scr.get_script_method_list():
			if str(m["name"]).begins_with("_rtv_vanilla_"):
				has_rename = true
				break
		# The node itself should report an _rtv_vanilla_ method.
		var instance_methods_has_rename := false
		for m in node.get_method_list():
			if str(m["name"]).begins_with("_rtv_vanilla_"):
				instance_methods_has_rename = true
				break
		_log_info("[RTVCodegen] AUTOLOAD-CHECK %s: script=%s script_has_rename=%s instance_has_rename=%s" \
				% [aname, scr.resource_path, has_rename, instance_methods_has_rename])

	# Registry smoke probe (dev-only): the Database rewrite and _get() serve scenes at runtime.
	var db_node: Node = get_tree().root.get_node_or_null("Database")
	if db_node == null:
		_log_warning("[RegistryProbe] Database autoload not in tree -- cannot verify const->dict transform")
	elif not ("_rtv_vanilla_scenes" in db_node):
		_log_warning("[RegistryProbe] Database._rtv_vanilla_scenes missing -- const->dict rewrite did not execute; lib.register/override will not see vanilla ids")
	else:
		var vs: Dictionary = db_node._rtv_vanilla_scenes
		var scene_count: int = vs.size()
		if scene_count == 0:
			_log_warning("[RegistryProbe] Database._rtv_vanilla_scenes empty -- regex extracted no entries from Database.gd; check vanilla const syntax")
		else:
			var probe_key: String = vs.keys()[0]
			var probe_result = db_node.get(probe_key)
			if probe_result is PackedScene:
				_log_info("[RegistryProbe] Database: _rtv_vanilla_scenes=%d entries; get('%s') returns PackedScene -- const->dict transform + _get() injection OK" \
						% [scene_count, probe_key])
			else:
				_log_warning("[RegistryProbe] Database: _rtv_vanilla_scenes=%d entries but get('%s') returned %s (not PackedScene) -- _get() injection broken" \
						% [scene_count, probe_key, type_string(typeof(probe_result))])

	# 30s lets the player reach gameplay so controller-level hooks can fire.
	_dispatch_counts.clear()
	get_tree().create_timer(30.0).timeout.connect(func():
		var pc: Dictionary = Engine.get_meta("_rtv_probe_counts", {})
		var fa: Dictionary = Engine.get_meta("_rtv_probe_first_args", {})
		# Top 20 hot methods, no generic threshold (physics-tick methods run hot).
		# Lifecycle methods fire once per node, so counts > 10 flag a mod looping them.
		if _developer_mode and _dispatch_counts.size() > 0:
			var pairs: Array = []
			for k: String in _dispatch_counts:
				pairs.append([k, int(_dispatch_counts[k])])
			pairs.sort_custom(func(a, b): return a[1] > b[1])
			_log_info("[RTVCodegen] DISPATCH-COUNT top %d / %d tracked methods (dev mode, 30s window):" \
					% [min(20, pairs.size()), pairs.size()])
			for i in range(min(20, pairs.size())):
				_log_info("[RTVCodegen]   %-48s %d" % [pairs[i][0], pairs[i][1]])
			var lifecycle_runaway: Array = []
			for p in pairs:
				var name: String = p[0]
				if (name.ends_with("-_ready") or name.ends_with("-_enter_tree") \
						or name.ends_with("-_init")) and int(p[1]) > 10:
					lifecycle_runaway.append("%s=%d" % [name, p[1]])
			if lifecycle_runaway.size() > 0:
				_log_critical("[RTVCodegen] LIFECYCLE-RUNAWAY: %s -- these should fire once per node; elevated counts usually mean a mod is explicitly calling them from a loop or frequent callback, which cascades into connect-already-connected error spam" \
						% ", ".join(lifecycle_runaway))
		var total := 0
		for k: String in ["loader_pp", "simulation_proc", "profiler_proc",
				"menu_ready", "settings_load",
				"controller_pp", "character_pp", "camera_pp"]:
			var v := int(pc.get(k, 0))
			total += v
			_log_info("[RTVCodegen] HOOK-API %s: count=%d first_arg=%s" \
					% [k, v, fa.get(k, "n/a")])
		if total > 0:
			_log_info("[RTVCodegen] HOOK-API-LIVE: %d callback fires total across probes -- full chain verified" % total)
		else:
			_log_critical("[RTVCodegen] HOOK-API-DEAD: 0 callback fires -- dispatch runs but _hooks lookup/callback is broken")
	)
