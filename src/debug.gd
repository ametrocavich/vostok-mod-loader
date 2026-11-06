## Developer-mode probes: _dev_preactivate_summary and _dev_hook_probes, run
## by hook_pack.gd only when developer mode is on.

# The autoloads the game's project.godot declares; AUTOLOAD-CHECK inspects each.
const _DEV_AUTOLOADS: Array[String] = ["Loader", "Database", "Simulation"]

func _dev_preactivate_summary(res_paths: Array[String]) -> void:
	var preempted := 0
	var other := 0
	var with_source: PackedStringArray = []
	var tokenized: PackedStringArray = []
	for res_path: String in res_paths:
		if _scripts_with_scene_preloads.has(res_path):
			continue
		var c := load(res_path) as GDScript
		if c == null:
			other += 1
		elif _static_script_has_rewrite(c):
			preempted += 1
		elif c.source_code.length() > 0:
			with_source.append(res_path)
		else:
			tokenized.append(res_path)
	_log_debug("[RTVCodegen] PRE-ACTIVATE preempted=%d pinned-with-source=%d pinned-tokenized=%d other=%d total=%d" \
			% [preempted, with_source.size(), tokenized.size(), other, res_paths.size()])
	if not with_source.is_empty():
		_log_debug("[RTVCodegen]   pinned-with-source (our text, vanilla methods): %s" \
				% ", ".join(with_source.slice(0, 25)))
	if not tokenized.is_empty():
		_log_debug("[RTVCodegen]   pinned-tokenized (PCK .gdc, static-init preload missed): %s" \
				% ", ".join(tokenized.slice(0, 25)))

func _dev_hook_probes() -> void:
	_dev_register_hook_probes()
	_dev_check_autoload_rewrites()
	_dev_registry_smoke_probe()
	_dev_schedule_probe_report()

# hook() cannot widen the wrap surface of a pack that is already built, so the
# probe sits on Menu._ready, which _seed_core_hooks wraps in every session.
func _dev_register_hook_probes() -> void:
	Engine.set_meta("_rtv_probe_counts", {"menu_ready": 0})
	var probe := func():
		var pc: Dictionary = Engine.get_meta("_rtv_probe_counts")
		pc["menu_ready"] += 1
	hook("menu-_ready-pre", probe, 100)

# A live autoload node can still hold the original bytecode via get_script()
# even when the resource shows the renames, so both are reported.
func _dev_check_autoload_rewrites() -> void:
	var root := get_tree().root
	for aname: String in _DEV_AUTOLOADS:
		var node: Node = root.get_node_or_null(aname)
		if node == null:
			_log_info("[RTVCodegen] AUTOLOAD-CHECK %s: node NOT in tree" % aname)
			continue
		var scr := node.get_script() as GDScript
		if scr == null:
			_log_info("[RTVCodegen] AUTOLOAD-CHECK %s: no script attached" % aname)
			continue
		_log_info("[RTVCodegen] AUTOLOAD-CHECK %s: script=%s script_has_rename=%s instance_has_rename=%s" \
				% [aname, scr.resource_path, _static_script_has_rewrite(scr),
				_static_method_list_has_rewrite(node.get_method_list())])

func _dev_registry_smoke_probe() -> void:
	var db_node: Node = _autoload_node("Database", false)
	if db_node == null:
		_log_warning("[RegistryProbe] Database autoload not in tree -- cannot verify the rewrite")
		return
	if not ("_rtv_vanilla_scenes" in db_node):
		_log_warning("[RegistryProbe] Database._rtv_vanilla_scenes missing -- the rewrite did not run")
		return
	var vs: Dictionary = db_node._rtv_vanilla_scenes
	if vs.is_empty():
		_log_warning("[RegistryProbe] Database._rtv_vanilla_scenes is empty -- no entries extracted")
		return
	var probe_key: String = vs.keys()[0]
	var probe_result: Variant = db_node.get(probe_key)
	if probe_result is PackedScene:
		_log_info("[RegistryProbe] Database: %d scenes; get('%s') is a PackedScene -- _get() OK" \
				% [vs.size(), probe_key])
	else:
		_log_warning("[RegistryProbe] Database: %d scenes but get('%s') returned %s -- _get() broken" \
				% [vs.size(), probe_key, type_string(typeof(probe_result))])

# 30s lets the player reach gameplay, so the dispatch counts cover it too.
func _dev_schedule_probe_report() -> void:
	_dispatch_counts.clear()
	get_tree().create_timer(30.0).timeout.connect(func():
		# The launcher can turn developer mode off within the window.
		if _developer_mode and _dispatch_counts.size() > 0:
			_dev_report_dispatch_counts()
		var fires: int = Engine.get_meta("_rtv_probe_counts")["menu_ready"]
		_log_info("[RTVCodegen] HOOK-API menu_ready: count=%d" % fires)
		if fires > 0:
			_log_info("[RTVCodegen] HOOK-API-LIVE: %d callback fires -- full chain verified" % fires)
		else:
			_log_critical("[RTVCodegen] HOOK-API-DEAD: 0 callback fires -- dispatch runs but _hooks lookup/callback is broken")
	)

# Lifecycle methods fire once per node, so a count over 10 means a mod is
# calling them in a loop.
func _dev_report_dispatch_counts() -> void:
	var pairs: Array = []
	for k: String in _dispatch_counts:
		pairs.append([k, int(_dispatch_counts[k])])
	pairs.sort_custom(func(a, b): return a[1] > b[1])
	var top: int = min(20, pairs.size())
	_log_info("[RTVCodegen] DISPATCH-COUNT top %d / %d tracked methods (dev mode, 30s window):" \
			% [top, pairs.size()])
	for i in top:
		_log_info("[RTVCodegen]   %-48s %d" % pairs[i])
	var runaway: PackedStringArray = []
	for p in pairs:
		var base: String = p[0]
		if (base.ends_with("-_ready") or base.ends_with("-_enter_tree") or base.ends_with("-_init")) and p[1] > 10:
			runaway.append("%s=%d" % p)
	if not runaway.is_empty():
		_log_critical("[RTVCodegen] LIFECYCLE-RUNAWAY: %s -- these fire once per node; likely a mod loop" \
				% ", ".join(runaway))
