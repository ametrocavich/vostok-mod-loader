## ----- conflict_report.gd -----
## Developer-mode diagnostics: verify script_overrides took effect, probe the
## scene tree for mismatches, log override timing issues, and produce the
## conflict report written to user://. Loaded alongside the normal loading
## path but only runs when developer_mode=true.

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

# [OverrideVerify]: diagnose silent override failures. Runs once after
# frameworks_ready (all mod autoloads finished their overrideScript calls).
#
# There are TWO failure modes we need to distinguish:
#
#   MODE 1 (cache miss): mod's autoload ran AFTER vanilla's preload chain
#     already resolved the scripts, so when mod.Main.gd's `overrideScript`
#     does `load(vanilla_path)` + `take_over_path`, vanilla is already
#     cached and the mod's take_over_path DOES replace the cache entry,
#     BUT any PackedScene / preload reference resolved earlier still points
#     at the vanilla script object.
#
#   MODE 2 (cache ok, instance stale): take_over_path updated the cache
#     entry but pre-loaded PackedScenes captured the vanilla script at
#     ext_resource resolution time -- those PackedScenes won't see the
#     update, so `instantiate()` creates nodes with the vanilla script.
#
# We need to SEE both to pick a fix. Probe in two layers:
#   Layer A (this function): load(vanilla_path) post-frameworks_ready and
#     check for `_rtv_mod_*` methods on the cached script. Presence = mod's
#     script object is what the cache serves.
#   Layer B (node_added): catch the first instance of each overridden class
#     to enter the tree, check its get_script().get_script_method_list()
#     for _rtv_mod_*. Absence = PackedScene ext_resource staleness.
#
# Distinguishing feature: our codegen renames the mod's body methods to
# `_rtv_mod_<name>` and the vanilla's to `_rtv_vanilla_<name>`. Both
# scripts have dispatch wrappers at the original names, so the rename
# prefix is the only reliable signal of which script is in use.
var _override_probe_sampled: Dictionary = {}
var _override_probe_active: bool = false
var _override_probe_expected: Dictionary = {}  # vanilla_path -> mod_name

func _verify_script_overrides() -> void:
	# Layer A: cache-level check. For each declared override target, load
	# it and classify by renamed-method prefix. Build a path-to-expected-mod
	# map that Layer B will use to classify instance scripts.
	var expected_map: Dictionary = {}  # vanilla_path -> mod_name (first declared wins)
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
			if not expected_map.has(vp):
				expected_map[vp] = mod_name
			var scr := load(vp) as Script
			if scr == null:
				_log_warning("[OverrideVerify] %s | %s | FAIL: load() returned null -- cache is empty or mismatched" \
						% [mod_name, vp])
				continue
			var has_mod_rename: bool = false
			var has_vanilla_rename: bool = false
			for m in scr.get_script_method_list():
				var n: String = str(m["name"])
				if n.begins_with("_rtv_mod_"):
					has_mod_rename = true
				elif n.begins_with("_rtv_vanilla_"):
					has_vanilla_rename = true
				if has_mod_rename and has_vanilla_rename:
					break
			var src: String = scr.source_code
			var src_head: String = src.substr(0, 60).replace("\n", " | ").replace("\t", " ")
			# Mod subclass without any method overrides (e.g. CustomItemTest's
			# Database.gd just adds a const, no funcs) gets skipped by the
			# Step C rewrite because hookable_count == 0 -- so it ships with
			# no _rtv_mod_* methods, only _rtv_vanilla_* inherited from the
			# rewritten parent. Distinguish from actual cache-stale vanilla
			# by looking for "extends \"res://Scripts/..." in the source.
			var is_mod_subclass: bool = src.contains("extends \"res://Scripts/")
			# Skip-listed vanilla scripts (RTV_SKIP_LIST: Explosion, Hit, Mine,
			# Message, MuzzleFlash, ParticleInstance, TreeRenderer) are NOT
			# rewritten by our hook pipeline because dispatch wrappers would
			# break their runtime semantics (short-lived instances, coroutine
			# lifetime, GPUParticles draw_pass corruption). Mod subclasses
			# that extend these aren't rewritten either -- they rely on
			# Godot's standard class-inheritance virtual dispatch. So
			# "no _rtv_* methods" is the CORRECT state for these, not an
			# error. Classify separately.
			var is_skip_listed: bool = vp.get_file() in RTV_SKIP_LIST
			var status: String
			if has_mod_rename:
				status = "OK: mod's script serves this path (has _rtv_mod_* methods)"
			elif has_vanilla_rename and is_mod_subclass:
				status = "OK: mod's subclass serves this path (no method overrides -- inherits vanilla dispatch)"
			elif is_skip_listed and is_mod_subclass:
				status = "OK: skip-listed vanilla (%s) -- mod subclass inherits unrewritten vanilla via Godot virtual dispatch (no hooks for runtime-sensitive classes)" % vp.get_file()
			elif has_vanilla_rename:
				status = "STALE: cache still serves vanilla -- overrideScript take_over_path did not win"
			else:
				status = "UNKNOWN: neither _rtv_mod_ nor _rtv_vanilla_ methods -- rewrite likely did not run"
			_log_info("[OverrideVerify] %s | %s | %s | src_head=[%s]" % [mod_name, vp, status, src_head])

	# Post-override autoload instance check. If any vanilla we hooked is also
	# a game autoload, the autoload instance was created BEFORE any mod
	# autoload ran overrideScript. take_over_path updates ResourceCache but
	# NOT live instances (Resource::set_path only touches the cache; it does
	# not walk the scene tree). So /root/<AutoloadName>.get_script() may
	# still point at the rewritten vanilla (now orphaned after take_over_path
	# cleared its path_cache), even though load(vanilla_path) returns mod's
	# script. Report which autoloads actually got their instance script
	# updated, and auto-swap the stale ones. Relevant for RTVCoop and any
	# mod that overrides autoload scripts like Loader.gd, Settings.gd, etc.
	var autoload_names: Array[String] = ["Database", "GameData", "Settings",
			"Menu", "Loader", "Inputs", "Mode", "Profiler", "Simulation"]
	var autoload_paths: Dictionary = {}  # autoload_name -> res://Scripts/<Name>.gd
	for an: String in autoload_names:
		autoload_paths[an] = "res://Scripts/" + an + ".gd"
	var any_overridden_autoload := false
	for an: String in autoload_names:
		if expected_map.has(autoload_paths[an]):
			any_overridden_autoload = true
			break
	if any_overridden_autoload:
		_log_info("[AutoloadInstanceProbe] === Post-override autoload instance check ===")
		var root := get_tree().root
		var swap_count: int = 0
		for an: String in autoload_names:
			var ap: String = autoload_paths[an]
			if not expected_map.has(ap):
				continue
			var node: Node = root.get_node_or_null(an)
			if node == null:
				_log_info("[AutoloadInstanceProbe] %s | node NOT in tree (not a live autoload)" % an)
				continue
			var iscr := node.get_script() as GDScript
			if iscr == null:
				_log_info("[AutoloadInstanceProbe] %s | node has no script attached" % an)
				continue
			var cur_has_mod: bool = false
			for m0 in iscr.get_script_method_list():
				if str(m0["name"]).begins_with("_rtv_mod_"):
					cur_has_mod = true
					break
			# Auto-swap: game autoload was instantiated BEFORE any mod ran
			# overrideScript, so its ScriptInstance still holds the pre-override
			# rewritten vanilla (orphaned by take_over_path -- resource.cpp:92
			# clears old path_cache entry but never walks the scene tree).
			# load(ap) now returns the mod subclass from the remapped cache;
			# set_script swaps the instance script in place. Inherited property
			# slots (mod extends rewritten vanilla) survive via type overlap;
			# any state built into vanilla-only slots by _ready is lost --
			# unavoidable without engine-level refresh. Matches RTVCoop's manual
			# set_script pattern for Loader, and Godot's own reload_scripts
			# pattern at gdscript.cpp:2419.
			var swapped: bool = false
			if not cur_has_mod:
				var new_scr: GDScript = load(ap) as GDScript
				if new_scr != null and new_scr != iscr:
					node.set_script(new_scr)
					swapped = true
					swap_count += 1
					iscr = node.get_script() as GDScript
			var ipath: String = iscr.resource_path if iscr != null else ""
			var ihas_mod: bool = false
			var ihas_vanilla: bool = false
			if iscr != null:
				for m in iscr.get_script_method_list():
					var mn: String = str(m["name"])
					if mn.begins_with("_rtv_mod_"): ihas_mod = true
					elif mn.begins_with("_rtv_vanilla_"): ihas_vanilla = true
					if ihas_mod and ihas_vanilla: break
			var expected_mod: String = expected_map[ap]
			var istatus: String
			if ihas_mod:
				istatus = "OK: instance runs mod's body (has _rtv_mod_* methods)"
				if swapped:
					istatus = "FIXED via set_script swap -- " + istatus
			elif ipath == "" and ihas_vanilla:
				istatus = "BROKEN: instance holds ORPHAN script (empty resource_path, _rtv_vanilla_* only) -- swap attempted but did not resolve"
			elif ihas_vanilla:
				istatus = "BROKEN: instance runs vanilla body (has _rtv_vanilla_* only; resource_path=%s)" % ipath
			else:
				istatus = "UNKNOWN: instance script has no _rtv_* methods"
			_log_info("[AutoloadInstanceProbe] %s | expected mod=%s | instance_path=%s | %s" \
					% [an, expected_mod, ipath if ipath != "" else "<empty>", istatus])
		if swap_count > 0:
			_log_info("[AutoloadInstanceProbe] Auto-swapped %d stale autoload instance(s) to mod body" % swap_count)

	# Layer B: arm the node_added probe. One-shot per vanilla_path.
	if expected_map.is_empty():
		return
	_override_probe_expected = expected_map
	_override_probe_sampled.clear()
	for vp in expected_map:
		_override_probe_sampled[vp] = false  # false = not yet sampled
	if not _override_probe_active:
		_override_probe_active = true
		get_tree().node_added.connect(_on_override_probe_node_added)
		_log_info("[OverrideVerify] Instance probe armed for %d path(s): %s" \
				% [expected_map.size(), ", ".join(expected_map.keys())])
	# Schedule a tree-walk fallback 12s after frameworks_ready. node_added
	# should catch instances but can miss cases where scripts are assigned
	# via set_script() after tree entry, or where the initial script ref
	# wasn't the one we expected. The walk reports every scripted node
	# whose script resource_path OR any ancestor-script path hits our
	# expected_map. One-shot; logs "TREEWALK" so it's grep-distinct from
	# the node_added InstanceProbe entries. Developer-mode only -- the walk
	# visits the full tree (~20k nodes) and prints a 30-entry histogram;
	# useful for debugging override staleness, noisy for release builds.
	if _developer_mode:
		get_tree().create_timer(12.0).timeout.connect(_probe_tree_walk)

# One-shot-per-class instance probe. Fired on every node_added; checks if
# the node's script is one of the overridden paths and classifies by method
# rename prefix. Once we've sampled every expected path we disconnect.
func _on_override_probe_node_added(node: Node) -> void:
	var scr := node.get_script() as Script
	if scr == null:
		return
	var sp: String = scr.resource_path
	if not _override_probe_expected.has(sp):
		return
	if _override_probe_sampled.get(sp, true):
		return  # already sampled (true means sampled)
	_override_probe_sampled[sp] = true
	var has_mod_rename: bool = false
	var has_vanilla_rename: bool = false
	for m in scr.get_script_method_list():
		var n: String = str(m["name"])
		if n.begins_with("_rtv_mod_"):
			has_mod_rename = true
		elif n.begins_with("_rtv_vanilla_"):
			has_vanilla_rename = true
		if has_mod_rename and has_vanilla_rename:
			break
	var expected_mod: String = _override_probe_expected[sp]
	# Skip-listed vanillas (RTV_SKIP_LIST) aren't rewritten; mod subclasses
	# that extend them ride Godot's normal virtual dispatch and thus have
	# neither _rtv_mod_ nor _rtv_vanilla_ method prefixes. Classify
	# separately so we don't flag correct pass-through as STALE/UNKNOWN.
	var is_skip_listed: bool = sp.get_file() in RTV_SKIP_LIST
	var status: String
	if has_mod_rename:
		status = "OK: instance uses mod's script"
	elif is_skip_listed:
		# Verify pass-through: instance script should be a subclass of vanilla
		# (mod's Override.gd extending res://Scripts/<SkipListed>.gd).
		var src: String = (scr as GDScript).source_code if scr is GDScript else ""
		if src.contains("extends \"res://Scripts/") or src.contains("extends\"res://Scripts/"):
			status = "OK: skip-listed pass-through (instance is mod subclass extending unrewritten vanilla; methods resolve via Godot virtual dispatch)"
		else:
			status = "UNKNOWN: skip-listed vanilla but instance source doesn't extend res://Scripts/ -- possible bare vanilla (override did not take)"
	elif has_vanilla_rename:
		status = "STALE SCENE: instance uses vanilla -- PackedScene captured pre-override script binding (cache may be OK, but scene ext_resource is stale)"
	else:
		status = "UNKNOWN: no renamed methods on instance script"
	_log_info("[InstanceProbe] %s | node=%s (%s) | expected mod=%s | %s" \
			% [sp, node.name, node.get_class(), expected_mod, status])
	# Auto-disconnect once all expected paths have been sampled.
	var all_sampled: bool = true
	for v in _override_probe_sampled.values():
		if not v:
			all_sampled = false
			break
	if all_sampled and _override_probe_active:
		_override_probe_active = false
		if get_tree().node_added.is_connected(_on_override_probe_node_added):
			get_tree().node_added.disconnect(_on_override_probe_node_added)
		_log_info("[InstanceProbe] All %d path(s) sampled -- probe disconnected" \
				% _override_probe_sampled.size())

# Tree-walk fallback for InstanceProbe. Covers cases where node_added
# signal missed a node (e.g. script assigned after tree entry, or script
# resource_path differs from what we expected). Walks the full scene tree,
# logs every node whose ATTACHED script OR any parent-in-extends-chain
# script matches one of our expected override paths.
func _probe_tree_walk() -> void:
	if _override_probe_expected.is_empty():
		return
	var hits: Dictionary = {}  # vanilla_path -> {sample info, count}
	# all_scripts: Every scripted node's top-level script.resource_path -> count.
	# Surfaces the case where AI instances exist but their scripts report a
	# path we didn't expect (e.g. sub-resource path from scene baking).
	var all_scripts: Dictionary = {}
	var total_nodes: int = 0
	var scripted_nodes: int = 0
	_probe_tree_walk_recursive(get_tree().root, hits, all_scripts, 0, [total_nodes, scripted_nodes])
	var stats: Array = [0, 0]
	_probe_tree_walk_stats(get_tree().root, stats, 0)
	total_nodes = stats[0]
	scripted_nodes = stats[1]
	_log_info("[TREEWALK] === Post-gameplay tree walk (t+12s) -- %d nodes total, %d scripted ===" \
			% [total_nodes, scripted_nodes])
	for vp: String in _override_probe_expected:
		if hits.has(vp):
			var info: Dictionary = hits[vp]
			var mod_name: String = _override_probe_expected[vp]
			_log_info("[TREEWALK] %s | found %d instance(s); sample: %s (%s) script=%s has_mod_rename=%s chain_depth=%d expected_mod=%s" \
					% [vp, info.count, info.name, info.cls, info.script_path, info.has_mod, info.depth, mod_name])
		else:
			# Not a warning: the probe runs at t+12s (typically still in menu
			# or loading shelter) while most overrideScript targets only
			# instantiate in World/Combat scenes loaded later (AI, Door,
			# Pickup, Helicopter, etc.). An absent instance here is
			# expected, not broken. InstanceProbe (node_added) verifies
			# when instances actually spawn. Info-level keeps the signal
			# without the false alarm.
			_log_info("[TREEWALK] %s | not instantiated in current scene tree at t+12s (typical for classes that load with World scene; node_added probe will verify on spawn)" \
					% vp)
	# Dump top script paths by count. The expected paths above are included.
	# Anything UNEXPECTED here that matches a class name pattern of something
	# we DID expect (e.g. "AI" substring in path) is the smoking gun.
	_log_info("[TREEWALK] All scripted-node resource_paths (top 30 by count):")
	var pairs: Array = []
	for k: String in all_scripts:
		pairs.append([k, int(all_scripts[k])])
	pairs.sort_custom(func(a, b): return a[1] > b[1])
	for i in range(min(30, pairs.size())):
		_log_info("[TREEWALK]   %-8d %s" % [pairs[i][1], pairs[i][0]])

func _probe_tree_walk_stats(node: Node, stats: Array, depth: int) -> void:
	if depth > 20:
		return
	stats[0] += 1
	if node.get_script() != null:
		stats[1] += 1
	for child in node.get_children():
		_probe_tree_walk_stats(child, stats, depth + 1)

func _probe_tree_walk_recursive(node: Node, hits: Dictionary, all_scripts: Dictionary, depth: int, _counts) -> void:
	if depth > 20:
		return
	var scr := node.get_script() as Script
	if scr != null:
		var top_path: String = scr.resource_path
		if top_path.is_empty():
			top_path = "<empty-path:" + scr.get_class() + ">"
		all_scripts[top_path] = int(all_scripts.get(top_path, 0)) + 1
	var cur: Script = scr
	var chain_depth := 0
	while cur != null and chain_depth < 6:
		var rp: String = cur.resource_path
		if _override_probe_expected.has(rp) and not hits.has(rp):
			var has_mod: bool = false
			for m in cur.get_script_method_list():
				if str(m["name"]).begins_with("_rtv_mod_"):
					has_mod = true
					break
			hits[rp] = {
				"name": node.name,
				"cls": node.get_class(),
				"script_path": (scr.resource_path if scr != null else "<null>"),
				"has_mod": has_mod,
				"depth": chain_depth,
				"count": 1,
			}
		elif _override_probe_expected.has(rp):
			hits[rp].count += 1
		cur = cur.get_base_script() as Script
		chain_depth += 1
	for child in node.get_children():
		_probe_tree_walk_recursive(child, hits, all_scripts, depth + 1, _counts)

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
