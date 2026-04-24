## ----- registry/scene_nodes.gd -----
##
## Patch-only registry for mutating node properties inside vanilla scenes
## without shipping a full-scene override. Mod calls:
##
##   lib.patch(lib.Registry.SCENE_NODES,
##             "res://UI/Interface.tscn#Tools/Crafting/Types/Margin/Buttons/Equipment",
##             {disabled = false, modulate = Color(1,1,1,1)})
##
## Id format: "<scene_path>#<node_path>" where scene_path is the res:// path
## of a PackedScene and node_path is relative to that scene's root. The two
## are split on the FIRST '#' (scene paths don't legally contain #, node
## names in Godot can't either).
##
## How it works: we subscribe to get_tree().node_added at frameworks_ready
## time. Godot sets `node.scene_file_path` on the ROOT of an instantiated
## scene (and only there); we use that as a cheap filter. When a match
## fires, we walk our registered node_paths for that scene, resolve each via
## get_node_or_null on the scene root, and apply the property patches. The
## signal fires BEFORE the node's _ready, so @onready values that depend on
## the patched props observe the patched state.
##
## The PackedScene resource is never mutated. Trade-off: patches apply per-instance at
## instantiation, not at resource load. Code that calls
## packed_scene.get_bundled_scene() directly still sees vanilla values
## (doesn't come up in RTV vanilla).
##
## What this registry CAN'T do (by design):
##   - Add or remove nodes (structural changes): use override('scenes', ...)
##   - Patch sub-resources embedded inside the scene
##   - Patch values on scenes loaded outside the tree (direct-load mutations)

# Per-scene patch state, keyed by scene_path -> node_path -> {prop: value}.
# Populated by _patch_scene_node, consumed by _apply_patches_for_scene_root.
var _scene_node_patches: Dictionary = {}

# Parallel stash for revert: same shape, holds the value the prop had BEFORE
# the first patch on that (scene, node, prop) triple. Subsequent patches to
# the same prop don't overwrite -- revert restores true original state.
# Populated inside _apply_patches_for_scene_root the first time a live
# instance gets a prop set, not at patch() call time (we don't hold the
# instance yet at that point).
var _scene_node_stash: Dictionary = {}

# Guard against connecting the node_added signal twice across
# frameworks_ready emissions (shouldn't happen, but belt-and-suspenders).
var _scene_nodes_listener_connected: bool = false

# Memoizes successful probe validations keyed by
# "<scene_path>#<node_path>|<sorted,field,names>". Keeps repeat patch()
# calls with the same id + field set (e.g. recipes.gd auto-unlocking the
# Equipment tab once per registered recipe) from instantiating +
# free-ing Interface.tscn N times. Runtime safety is unchanged --
# _apply_patches_for_scene_root still re-checks _node_has_property on
# every live instance, so the cache is strictly additive.
var _validated_patches: Dictionary = {}

# Entry point invoked from hooks_api._register_core_hooks after frameworks_ready.
# Idempotent.
func _scene_nodes_connect_listener() -> void:
	if _scene_nodes_listener_connected:
		return
	var tree := get_tree()
	if tree == null:
		_log_warning("[Registry] scene_nodes: no SceneTree at connect time; listener disabled")
		return
	tree.node_added.connect(_on_any_node_added)
	_scene_nodes_listener_connected = true

func _on_any_node_added(node: Node) -> void:
	# Cheap filter: Godot only sets scene_file_path on the ROOT of an
	# instantiated scene, so 99.9% of node_added events short-circuit here.
	var scene_path: String = node.scene_file_path
	if scene_path.is_empty():
		return
	if not _scene_node_patches.has(scene_path):
		return
	_apply_patches_for_scene_root(scene_path, node)

func _apply_patches_for_scene_root(scene_path: String, scene_root: Node) -> void:
	var per_node: Dictionary = _scene_node_patches[scene_path]
	var stash_per_scene: Dictionary = _scene_node_stash.get(scene_path, {})
	for node_path in per_node.keys():
		var target: Node = scene_root.get_node_or_null(NodePath(node_path))
		if target == null:
			_log_warning("[Registry] scene_nodes: node '%s' not found in instantiated '%s'; patch skipped for this instance" \
					% [node_path, scene_path])
			continue
		var props: Dictionary = per_node[node_path]
		var stash_per_node: Dictionary = stash_per_scene.get(node_path, {})
		for prop in props.keys():
			var fname: String = String(prop)
			if not _node_has_property(target, fname):
				_log_warning("[Registry] scene_nodes: property '%s' not found on node '%s' in '%s'; skipped" \
						% [fname, node_path, scene_path])
				continue
			if not stash_per_node.has(fname):
				stash_per_node[fname] = target.get(fname)
			target.set(fname, props[fname])
		stash_per_scene[node_path] = stash_per_node
	_scene_node_stash[scene_path] = stash_per_scene

# Split 'scene#node' id on the first '#'. Returns [scene_path, node_path] or
# [null, null] on malformed input.
func _split_scene_node_id(id: String) -> Array:
	var hash_idx: int = id.find("#")
	if hash_idx <= 0 or hash_idx == id.length() - 1:
		return [null, null]
	var scene_path: String = id.substr(0, hash_idx)
	var node_path: String = id.substr(hash_idx + 1)
	if not scene_path.begins_with("res://"):
		return [null, null]
	return [scene_path, node_path]

# Check property existence at patch-time against a freshly-instantiated
# probe. We don't require the scene to be in the tree at patch() time
# mods call this from _ready() before the UI scene loads. Instead we load
# the PackedScene and peek at the target node by instantiating and freeing.
# This is a per patch() call but only on cold paths (mod boot).
# Returns true if the (scene, node, props) triple is well-formed, false if
# any piece doesn't resolve (with a warn on each failure).
func _validate_scene_node_patch(scene_path: String, node_path: String, fields: Dictionary) -> bool:
	var field_keys: Array = []
	for k in fields.keys():
		field_keys.append(String(k))
	field_keys.sort()
	var cache_key: String = "%s#%s|%s" % [scene_path, node_path, ",".join(field_keys)]
	if _validated_patches.has(cache_key):
		return true
	var pscene := load(scene_path)
	if pscene == null or not (pscene is PackedScene):
		push_warning("[Registry] patch('scene_nodes'): scene '%s' failed to load (not a PackedScene)" % scene_path)
		return false
	var probe: Node = (pscene as PackedScene).instantiate()
	if probe == null:
		push_warning("[Registry] patch('scene_nodes'): scene '%s' failed to instantiate for validation" % scene_path)
		return false
	var target: Node = probe.get_node_or_null(NodePath(node_path))
	if target == null:
		push_warning("[Registry] patch('scene_nodes', '%s#%s'): node path doesn't resolve in the scene; check node hierarchy" \
				% [scene_path, node_path])
		probe.queue_free()
		return false
	for prop in fields.keys():
		if not _node_has_property(target, String(prop)):
			push_warning("[Registry] patch('scene_nodes', '%s#%s'): property '%s' not found on node (class=%s)" \
					% [scene_path, node_path, prop, target.get_class()])
			probe.queue_free()
			return false
	probe.queue_free()
	_validated_patches[cache_key] = true
	return true

# Does `node` have a declared property named `prop`? Mirrors
# _resource_has_property from shared.gd but for Node. (Nodes expose both
# class properties and script properties through get_property_list.)
func _node_has_property(node: Node, prop: String) -> bool:
	for p in node.get_property_list():
		if p.get("name") == prop:
			return true
	return false

func _patch_scene_node(id: String, fields: Dictionary) -> bool:
	if fields.is_empty():
		push_warning("[Registry] patch('scene_nodes', '%s'): empty fields dict is a no-op" % id)
		return false
	var parts := _split_scene_node_id(id)
	var scene_path = parts[0]
	var node_path = parts[1]
	if scene_path == null:
		push_warning("[Registry] patch('scene_nodes', '%s'): id must be '<res://scene_path>#<node_path>'" % id)
		return false
	if not _validate_scene_node_patch(scene_path, node_path, fields):
		return false
	# Connect the listener lazily, in case a mod patches before
	# frameworks_ready fires. Idempotent.
	_scene_nodes_connect_listener()
	var per_node: Dictionary = _scene_node_patches.get(scene_path, {})
	var props: Dictionary = per_node.get(node_path, {})
	for prop in fields.keys():
		props[String(prop)] = fields[prop]
	per_node[node_path] = props
	_scene_node_patches[scene_path] = per_node
	# Track into _registry_patched so the rest of the registry subsystem
	# sees a consistent shape: scene_nodes -> {id -> {prop -> value}}.
	# Note: the STASH (for revert) is populated at apply time, not here.
	var patched: Dictionary = _registry_patched.get("scene_nodes", {})
	var pat_entry: Dictionary = patched.get(id, {})
	for prop in fields.keys():
		pat_entry[String(prop)] = fields[prop]
	patched[id] = pat_entry
	_registry_patched["scene_nodes"] = patched
	# Apply immediately to any scene instance already in the tree. Covers
	# the case where a mod patches after the scene was instantiated (rare
	# but legal -- e.g. a config-menu toggle flipping a UI property live).
	_apply_patch_to_live_instances(scene_path)
	_log_debug("[Registry] patched scene node '%s' (%d field(s))" % [id, fields.size()])
	return true

# Scan the current tree for any live instance of `scene_path`, re-applying
# all registered patches for that scene. Called from _patch_scene_node so
# late patches land on already-instantiated scenes.
func _apply_patch_to_live_instances(scene_path: String) -> void:
	var tree := get_tree()
	if tree == null:
		return
	_walk_for_scene_roots(tree.root, scene_path)

func _walk_for_scene_roots(node: Node, scene_path: String) -> void:
	if node.scene_file_path == scene_path:
		_apply_patches_for_scene_root(scene_path, node)
		# Don't recurse into an already-matched root; its children can't
		# have the SAME scene_file_path unless they're nested instances
		# of the same scene, which is legal but exceedingly rare. A deeper
		# nested instance will also surface via node_added on its own.
		return
	for child in node.get_children():
		_walk_for_scene_roots(child, scene_path)

# Revert. Fields-empty: revert every prop on the id. Fields-nonempty:
# per-field revert. Restoration writes the stashed original value back to
# every live instance (found via tree walk) AND erases the patch so future
# instantiations see vanilla.
func _revert_scene_node(id: String, fields: Array) -> bool:
	var parts := _split_scene_node_id(id)
	var scene_path = parts[0]
	var node_path = parts[1]
	if scene_path == null:
		push_warning("[Registry] revert('scene_nodes', '%s'): id must be '<res://scene_path>#<node_path>'" % id)
		return false
	var patched: Dictionary = _registry_patched.get("scene_nodes", {})
	if not patched.has(id):
		push_warning("[Registry] revert('scene_nodes', '%s'): nothing patched at that id" % id)
		return false
	var pat_entry: Dictionary = patched[id]
	var per_node: Dictionary = _scene_node_patches.get(scene_path, {})
	var props: Dictionary = per_node.get(node_path, {})
	var stash_per_scene: Dictionary = _scene_node_stash.get(scene_path, {})
	var stash_per_node: Dictionary = stash_per_scene.get(node_path, {})
	var targets: Array[String] = []
	if fields.is_empty():
		for k in pat_entry.keys():
			targets.append(String(k))
	else:
		for k in fields:
			targets.append(String(k))
	# Restore stashed values on live instances.
	var live_roots: Array[Node] = []
	var tree := get_tree()
	if tree != null:
		_collect_scene_roots(tree.root, scene_path, live_roots)
	for fname in targets:
		if not stash_per_node.has(fname) and fields.is_empty() == false:
			# Per-field revert for a field that was never applied to any
			# live instance: it won't have a stashed original. We still
			# want to drop the patch, but there's nothing to restore on
			# live instances.
			push_warning("[Registry] revert('scene_nodes', '%s'): field '%s' wasn't patched (or never observed on a live instance)" % [id, fname])
			continue
		if stash_per_node.has(fname):
			for root in live_roots:
				var target: Node = root.get_node_or_null(NodePath(node_path))
				if target != null and _node_has_property(target, fname):
					target.set(fname, stash_per_node[fname])
			stash_per_node.erase(fname)
		props.erase(fname)
		pat_entry.erase(fname)
	# Prune empty nested dicts to keep state clean.
	if props.is_empty():
		per_node.erase(node_path)
	else:
		per_node[node_path] = props
	if per_node.is_empty():
		_scene_node_patches.erase(scene_path)
	else:
		_scene_node_patches[scene_path] = per_node
	if stash_per_node.is_empty():
		stash_per_scene.erase(node_path)
	else:
		stash_per_scene[node_path] = stash_per_node
	if stash_per_scene.is_empty():
		_scene_node_stash.erase(scene_path)
	else:
		_scene_node_stash[scene_path] = stash_per_scene
	if pat_entry.is_empty():
		patched.erase(id)
	else:
		patched[id] = pat_entry
	_registry_patched["scene_nodes"] = patched
	_log_debug("[Registry] reverted scene_nodes '%s' (fields=%s)" % [id, targets])
	return true

func _collect_scene_roots(node: Node, scene_path: String, out: Array[Node]) -> void:
	if node.scene_file_path == scene_path:
		out.append(node)
		return
	for child in node.get_children():
		_collect_scene_roots(child, scene_path, out)
