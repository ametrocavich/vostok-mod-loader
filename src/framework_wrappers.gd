## ----- framework_wrappers.gd -----
## Legacy extends-wrapper path: node_added signal swaps vanilla scripts to
## Framework<Name>.gd subclasses at runtime. Superseded by the source-rewrite
## system (rewriter.gd + hook_pack.gd). Retained for scripts that rewrite
## can't handle, and for the fallback case when a hook pack fails to mount.
## Candidate for removal in a future cleanup pass.

# Collect [rtvmodlib] needs= values across all enabled mods.
# Keys are lowercased framework names ("lootcontainer").
func _collect_needed_from_mods() -> Dictionary:
	var needed: Dictionary = {}
	for entry in _ui_mod_entries:
		if not entry.get("enabled", false):
			continue
		var cfg = entry.get("cfg", null)
		if cfg == null:
			continue
		if not cfg.has_section_key("rtvmodlib", "needs"):
			continue
		var raw = cfg.get_value("rtvmodlib", "needs", null)
		var names: Array = []
		if raw is Array or raw is PackedStringArray:
			for v in raw:
				names.append(str(v))
		elif raw is String:
			for part in (raw as String).split(","):
				var trimmed := (part as String).strip_edges()
				if trimmed != "":
					names.append(trimmed)
		else:
			_log_warning("[RTVModLib] mod '%s' has malformed [rtvmodlib] needs -- ignored" \
					% str(entry.get("mod_name", "?")))
			continue
		for n in names:
			needed[(n as String).to_lower()] = true
	return needed


func _activate_hooked_scripts() -> void:
	if _defer_to_tetra_modlib:
		_log_info("[Hooks] Deferred to tetra's RTVModLib mod -- skipping activation")
		return

	var needed := _collect_needed_from_mods()
	if needed.is_empty():
		_log_info("[Hooks] No mod declared [rtvmodlib] needs -- nothing to activate")
		return

	var activated := 0
	for key in needed.keys():
		var vanilla_path := _resolve_framework_vanilla_path(key)
		if vanilla_path == "":
			_log_warning("[RTVModLib] requested framework '%s' has no vanilla script -- skipped" % key)
			continue
		# Load via the mounted pack (res://) rather than user://. GDScript's
		# extends-chain resolution for class_name parents misbehaves for user://
		# scripts in 4.6.
		var framework_file := HOOK_PACK_MOUNT_BASE.path_join("Framework" + vanilla_path.get_file())
		if not ResourceLoader.exists(framework_file):
			_log_warning("[RTVModLib] Framework not in pack for '%s' at %s -- skipped" % [key, framework_file])
			continue
		if _register_override(framework_file, vanilla_path):
			activated += 1

	if activated > 0:
		_log_info("[RTVModLib] activated %d framework override(s)" % activated)

# Case-insensitive filename match. class_name map covers most; fall back to
# PCK-parsed script list for non-class_name frameworks (Interface, Task, AI,
# Audio, Cables, etc.). DirAccess can't list PCK contents in 4.6, so we use
# the path list populated by _enumerate_game_scripts(). Credit: tetrahydroc.
func _resolve_framework_vanilla_path(key_lower: String) -> String:
	for cn: String in _class_name_to_path:
		var path: String = _class_name_to_path[cn]
		if path.get_file().get_basename().to_lower() == key_lower:
			return path
	for script_path: String in _all_game_script_paths:
		if script_path.get_file().get_basename().to_lower() == key_lower:
			return script_path
	return ""

# class_name scripts can't be take_over_path'd safely: Resource::set_path
# doesn't clear global_name, so ScriptServer ends up with the moved script's
# class_name colliding with the evicted original (corrupts the class, see
# WeaponRig crash). For those we swap via node_added only -- ClassName.new()
# call sites aren't hookable this way.
func _register_override(framework_path: String, expected_vanilla_path: String) -> bool:
	var script: Script = load(framework_path)
	if script == null:
		_log_critical("[RTVModLib] Failed to load %s" % framework_path)
		return false
	(script as GDScript).reload()
	var parent_script := script.get_base_script() as Script
	if parent_script == null:
		_log_critical("[RTVModLib] No parent script for %s" % framework_path)
		return false
	var original_path := parent_script.resource_path
	if original_path == "":
		_log_critical("[RTVModLib] Empty parent path for %s" % framework_path)
		return false
	if expected_vanilla_path != "" and original_path != expected_vanilla_path:
		_log_warning("[RTVModLib] Parent path mismatch for %s (got %s, expected %s)" \
				% [framework_path, original_path, expected_vanilla_path])
	_original_scripts[original_path] = parent_script
	# Index evicted ancestors by instance_id so node_added can still identify
	# UID-loaded nodes whose resource_path went empty after take_over_path.
	_vanilla_id_to_path[parent_script.get_instance_id()] = original_path
	var base := parent_script.get_base_script() as GDScript
	while base != null:
		if base.resource_path == "":
			var bid := base.get_instance_id()
			if not _vanilla_id_to_path.has(bid):
				_vanilla_id_to_path[bid] = original_path
		base = base.get_base_script() as GDScript

	# class_name guard (tetra's fix for WeaponRig crash).
	var global_name: StringName = parent_script.get_global_name()
	if global_name == &"" or String(global_name) == "":
		script.take_over_path(original_path)
		_log_info("[RTVModLib] registered override (take_over_path): %s -> %s" \
				% [framework_path, original_path])
	else:
		_log_info("[RTVModLib] registered override (node_added only): %s -> %s (class_name: %s)" \
				% [framework_path, original_path, global_name])
	_hook_swap_map[original_path] = script
	return true

func _connect_node_swap() -> void:
	if _defer_to_tetra_modlib:
		return
	if _node_swap_connected:
		return
	if _hook_swap_map.is_empty():
		return
	get_tree().node_added.connect(_on_node_added)
	_node_swap_connected = true
	_log_info("[RTVModLib] node_added connected -- tracking %d script(s)" % _hook_swap_map.size())

func _on_node_added(node: Node) -> void:
	var node_script = node.get_script()
	if node_script == null:
		return
	var path: String = node_script.resource_path
	if path == "":
		# UID-loaded scripts lose resource_path. Identify by vanilla identity.
		for original_path in _original_scripts:
			if node_script == _original_scripts[original_path]:
				path = original_path
				break
		if path == "":
			var sid: int = node_script.get_instance_id()
			if _vanilla_id_to_path.has(sid):
				path = _vanilla_id_to_path[sid]
			else:
				return

	if not _hook_swap_map.has(path):
		return
	var framework_script = _hook_swap_map[path]
	if node_script != framework_script:
		call_deferred("_deferred_swap", node, framework_script, path)

# Swap a vanilla-script node to its framework wrapper: snapshot props,
# set_script, restore, then fire _ready so the wrapper dispatches.
#
# Pre-set _rtv_ready_done depends on whether vanilla _ready is async:
#  - Sync _ready (Pickup, Controller, etc): pre-set true, super() is skipped,
#    only post hooks fire. Re-running sync _ready can clobber state mutated
#    by the caller after the original _ready returned (e.g. Pickup._ready
#    calls Freeze, then the drop logic calls Unfreeze; re-running _ready
#    re-Freezes and the item floats).
#  - Async _ready (Trader): leave false. set_script kills the coroutine on
#    the old instance, so post-await code never runs. Letting super() re-run
#    vanilla _ready on the new instance gets it to completion. Pre-await
#    statements re-run, idempotent for tested cases (timer.start /
#    animations.play / @onready assignments).
func _deferred_swap(node: Node, framework_script: Script, path: String) -> void:
	if not is_instance_valid(node):
		return
	if node.get_script() == framework_script:
		return

	# Skip nulls: typed @export node refs can become stale after set_script
	# tears down the instance, and writing a stale ref into a freshly-
	# initialized typed slot corrupts memory.
	var saved_props := {}
	for prop in node.get_property_list():
		var pname: String = prop["name"]
		if pname == "script" or pname == "":
			continue
		var val = node.get(pname)
		if val != null:
			saved_props[pname] = val

	node.set_script(framework_script)

	for pname in saved_props:
		var current = node.get(pname)
		if current != saved_props[pname]:
			node.set(pname, saved_props[pname])

	# Direct _ready() instead of NOTIFICATION_READY: notification re-resolves
	# @onready, which crashes on missing child nodes (per RTVModLib).
	if node.is_inside_tree() and node.has_method("_ready"):
		if _ready_is_coroutine_by_path.has(path) \
				and not _ready_is_coroutine_by_path[path]:
			node.set("_rtv_ready_done", true)
		node._ready()

	_swap_count += 1
	if _swap_count <= 50:
		_log_info("[RTVModLib] Runtime swapped %s on %s" % [path.get_file(), node.name])

# --- Hook API (port of tetra's RTVLib.gd) -----------------------------------
# Mods call these via Engine.get_meta("RTVModLib").

## Register a hook. Returns a hook ID for removal, or -1 if rejected.
## hook_name examples:
##   "interface-open-pre"       - runs before original (stackable)
##   "interface-open-post"      - runs after original (stackable)
##   "interface-open-callback"  - deferred after original (stackable)
##   "interface-open"           - REPLACE the original (first-wins, only one allowed)
## callback: Callable to invoke
## priority: lower = runs first (default 100). Ignored for replace hooks.

# Recursively walk the scene tree, collecting nodes whose attached script
# (or any ancestor in its extends chain) has the given class_name. Base
# chain walk is needed because mods that override vanilla via
# take_over_path typically use extends-by-path (no class_name of their
# own), so their instances report get_global_name() == "". Matching via
# base chain catches IXP's Controller which extends our class_name
# Controller rewrite.
func _rtv_collect_nodes_by_class(node: Node, cls_name: String, out: Array) -> void:
	var scr := node.get_script() as GDScript
	if scr != null:
		var matched := false
		var s: GDScript = scr
		var depth := 0
		while s != null and depth < 8:
			if str(s.get_global_name()) == cls_name:
				matched = true
				break
			s = s.get_base_script() as GDScript
			depth += 1
		if matched:
			out.append(node)
	for child in node.get_children():
		_rtv_collect_nodes_by_class(child, cls_name, out)

# Archive scanner

