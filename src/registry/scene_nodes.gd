## ----- registry/scene_nodes.gd -----
## Patch-only registry for mutating node properties inside vanilla scenes
## without a full-scene override:
##   lib.patch(lib.Registry.SCENE_NODES, "<scene_path>#<node_path>", {...})
## The id splits on the first '#'; node_path is relative to the scene root.
## "<scene_path>#" or "<scene_path>#." targets the root itself (get_node
## can only walk down, so root properties need the special form).
##
## Applies via get_tree().node_added: Godot sets scene_file_path only on
## the root of an instantiated scene, which makes a cheap filter, and the
## signal fires before the node's _ready, so @onready values observe the
## patched state. The PackedScene resource is never mutated -- patches are
## per-instance, and packed_scene.get_bundled_scene() still sees vanilla.
##
## Can't (by design): add/remove nodes (use override('scenes', ...)),
## patch embedded sub-resources, or patch scenes loaded outside the tree.

# Patch state: scene_path -> node_path -> {prop: value}.
var _scene_node_patches: Dictionary = {}

# Revert stash, same shape: the value before the first patch on that
# (scene, node, prop) triple. Populated at apply time, not patch() time --
# no live instance exists yet then.
var _scene_node_stash: Dictionary = {}

var _scene_nodes_listener_connected: bool = false

# Memoized probe validations, keyed "<scene>#<node>|<sorted,fields>".
# Keeps repeat patch() calls with the same id + field set from
# instantiating + freeing the scene N times. Strictly additive:
# _apply_patches_for_scene_root still re-checks every live instance.
var _validated_patches: Dictionary = {}

# Invoked from hooks_api._register_core_hooks after frameworks_ready.
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
	# Only instantiated-scene roots carry scene_file_path.
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
		var target: Node = _resolve_scene_target(scene_root, node_path)
		if target == null:
			_log_warning("[Registry] scene_nodes: node '%s' not found in instantiated '%s'; patch skipped for this instance" \
					% [node_path, scene_path])
			continue
		var props: Dictionary = per_node[node_path]
		var stash_per_node: Dictionary = stash_per_scene.get(node_path, {})
		for prop in props.keys():
			var fname: String = String(prop)
			if not _object_has_property(target, fname):
				_log_warning("[Registry] scene_nodes: property '%s' not found on node '%s' in '%s'; skipped" \
						% [fname, node_path, scene_path])
				continue
			if not stash_per_node.has(fname):
				stash_per_node[fname] = target.get(fname)
			target.set(fname, props[fname])
		stash_per_scene[node_path] = stash_per_node
	_scene_node_stash[scene_path] = stash_per_scene

# Split 'scene#node' on the first '#'. Returns [scene_path, node_path], or
# [null, null] on malformed input. "" and "." both mean the scene root.
func _split_scene_node_id(id: String) -> Array:
	var hash_idx: int = id.find("#")
	if hash_idx <= 0:
		return [null, null]
	var scene_path: String = id.substr(0, hash_idx)
	var node_path: String = id.substr(hash_idx + 1)
	if not scene_path.begins_with("res://"):
		return [null, null]
	return [scene_path, node_path]

# Empty or "." resolves to the root itself; anything else through
# get_node_or_null.
func _resolve_scene_target(scene_root: Node, node_path: String) -> Node:
	if node_path == "" or node_path == ".":
		return scene_root
	return scene_root.get_node_or_null(NodePath(node_path))

# Validate at patch() time against a freshly-instantiated probe; the scene
# need not be in the tree yet (mods patch from _ready() before UI loads).
# Warns and returns false if any piece doesn't resolve.
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
	var target: Node = _resolve_scene_target(probe, node_path)
	if target == null:
		push_warning("[Registry] patch('scene_nodes', '%s#%s'): node path doesn't resolve in the scene; check node hierarchy" \
				% [scene_path, node_path])
		probe.queue_free()
		return false
	for prop in fields.keys():
		if not _object_has_property(target, String(prop)):
			push_warning("[Registry] patch('scene_nodes', '%s#%s'): property '%s' not found on node (class=%s)" \
					% [scene_path, node_path, prop, target.get_class()])
			probe.queue_free()
			return false
	probe.queue_free()
	_validated_patches[cache_key] = true
	return true

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
	# Lazy connect in case a mod patches before frameworks_ready. Idempotent.
	_scene_nodes_connect_listener()
	var per_node: Dictionary = _scene_node_patches.get(scene_path, {})
	var props: Dictionary = per_node.get(node_path, {})
	for prop in fields.keys():
		props[String(prop)] = fields[prop]
	per_node[node_path] = props
	_scene_node_patches[scene_path] = per_node
	# Track into _registry_patched for shape consistency with the rest of
	# the subsystem; the revert stash is populated at apply time, not here.
	var patched: Dictionary = _registry_patched.get("scene_nodes", {})
	var pat_entry: Dictionary = patched.get(id, {})
	for prop in fields.keys():
		pat_entry[String(prop)] = fields[prop]
	patched[id] = pat_entry
	_registry_patched["scene_nodes"] = patched
	# Apply immediately to instances already in the tree (patching after
	# instantiation is rare but legal, e.g. a config-menu toggle).
	_apply_patch_to_live_instances(scene_path)
	_log_debug("[Registry] patched scene node '%s' (%d field(s))" % [id, fields.size()])
	return true

# Re-apply all registered patches to any live instance of `scene_path`.
func _apply_patch_to_live_instances(scene_path: String) -> void:
	var tree := get_tree()
	if tree == null:
		return
	_walk_for_scene_roots(tree.root, scene_path)

func _walk_for_scene_roots(node: Node, scene_path: String) -> void:
	if node.scene_file_path == scene_path:
		_apply_patches_for_scene_root(scene_path, node)
		# Don't recurse into a matched root: same-scene nested instances are
		# exceedingly rare and surface via node_added on their own.
		return
	for child in node.get_children():
		_walk_for_scene_roots(child, scene_path)

# Revert (all props when fields is empty, else per-field): write stashed
# originals back to every live instance and erase the patch so future
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
	var live_roots: Array[Node] = []
	var tree := get_tree()
	if tree != null:
		_collect_scene_roots(tree.root, scene_path, live_roots)
	for fname in targets:
		if stash_per_node.has(fname):
			for root in live_roots:
				var target: Node = _resolve_scene_target(root, node_path)
				if target != null and _object_has_property(target, fname):
					target.set(fname, stash_per_node[fname])
			stash_per_node.erase(fname)
		elif not fields.is_empty() and not pat_entry.has(fname):
			push_warning("[Registry] revert('scene_nodes', '%s'): field '%s' wasn't patched" % [id, fname])
		# Always drop the patch: a pending never-applied patch has no stash
		# entry but must still be erased so future instantiations see vanilla.
		props.erase(fname)
		pat_entry.erase(fname)
	# Prune empty nested dicts.
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
