## scene_nodes: per-instance property patches on vanilla scene nodes, id "<res://scene>#<node>".
## Applied on node_added, which fires before _ready; only a scene root has scene_file_path.

# scene_path -> node_path -> {prop: value}; the stash has the same shape and holds the
# value before the first patch, read at apply time since no instance exists at patch().
var _scene_node_patches: Dictionary = {}
var _scene_node_stash: Dictionary = {}
# Probe verdicts keyed "<scene>#<node>|<sorted fields>"; live instances are re-checked.
var _validated_patches: Dictionary = {}

func _scene_nodes_connect_listener() -> void:
	if not get_tree().node_added.is_connected(_on_any_node_added):
		get_tree().node_added.connect(_on_any_node_added)

func _on_any_node_added(node: Node) -> void:
	if _scene_node_patches.has(node.scene_file_path):
		_apply_scene_patches(node.scene_file_path, node)

func _apply_scene_patches(scene_path: String, scene_root: Node) -> void:
	var per_node: Dictionary = _scene_node_patches[scene_path]
	var stash_per_scene: Dictionary = _scene_node_stash.get_or_add(scene_path, {})
	for node_path in per_node.keys():
		var target: Node = _resolve_scene_target(scene_root, node_path)
		if target == null:
			_log_warning("[Registry] scene_nodes: node '%s' not found in '%s'; skipped for this instance" \
					% [node_path, scene_path])
			continue
		var props: Dictionary = per_node[node_path]
		var stash_per_node: Dictionary = stash_per_scene.get_or_add(node_path, {})
		for prop in props.keys():
			var fname: String = String(prop)
			if not _object_has_property(target, fname):
				_log_warning("[Registry] scene_nodes: no property '%s' on node '%s' in '%s'; skipped" \
						% [fname, node_path, scene_path])
				continue
			if not stash_per_node.has(fname):
				stash_per_node[fname] = target.get(fname)
			target.set(fname, props[fname])

# [scene_path, node_path], or [] when malformed. "" and "." both mean the scene root.
func _split_scene_node_id(id: String) -> Array:
	var hash_idx: int = id.find("#")
	if hash_idx <= 0 or not id.begins_with("res://"):
		return []
	return [id.substr(0, hash_idx), id.substr(hash_idx + 1)]

func _resolve_scene_target(scene_root: Node, node_path: String) -> Node:
	if node_path == "" or node_path == ".":
		return scene_root
	return scene_root.get_node_or_null(NodePath(node_path))

# Checked against a fresh probe instance: mods patch before the scene is in the tree.
func _validate_scene_node_patch(scene_path: String, node_path: String, fields: Dictionary) -> bool:
	var field_keys: Array = []
	for k in fields.keys():
		field_keys.append(String(k))
	field_keys.sort()
	var cache_key: String = "%s#%s|%s" % [scene_path, node_path, ",".join(field_keys)]
	if _validated_patches.has(cache_key):
		return true
	var pscene := load(scene_path)
	if not (pscene is PackedScene):
		push_warning("[Registry] patch('scene_nodes'): scene '%s' failed to load (not a PackedScene)" % scene_path)
		return false
	var probe: Node = (pscene as PackedScene).instantiate()
	if probe == null:
		push_warning("[Registry] patch('scene_nodes'): scene '%s' failed to instantiate for validation" % scene_path)
		return false
	var target: Node = _resolve_scene_target(probe, node_path)
	var ok := target != null
	if not ok:
		push_warning("[Registry] patch('scene_nodes', '%s#%s'): node path doesn't resolve in the scene" \
				% [scene_path, node_path])
	else:
		for prop in fields.keys():
			if not _object_has_property(target, String(prop)):
				push_warning("[Registry] patch('scene_nodes', '%s#%s'): property '%s' not found on node (class=%s)" \
						% [scene_path, node_path, prop, target.get_class()])
				ok = false
				break
	probe.queue_free()
	if ok:
		_validated_patches[cache_key] = true
	return ok

func _patch_scene_node(id: String, fields: Dictionary) -> bool:
	if fields.is_empty():
		push_warning("[Registry] patch('scene_nodes', '%s'): empty fields dict is a no-op" % id)
		return false
	var parts := _split_scene_node_id(id)
	if parts.is_empty():
		push_warning("[Registry] patch('scene_nodes', '%s'): id must be '<res://scene_path>#<node_path>'" % id)
		return false
	var scene_path: String = parts[0]
	if not _validate_scene_node_patch(scene_path, parts[1], fields):
		return false
	# A mod can patch before frameworks_ready connects the listener.
	_scene_nodes_connect_listener()
	var props: Dictionary = _scene_node_patches.get_or_add(scene_path, {}).get_or_add(parts[1], {})
	for prop in fields.keys():
		props[String(prop)] = fields[prop]
	var roots: Array[Node] = []
	_collect_scene_roots(get_tree().root, scene_path, roots)
	for scene_root in roots:
		_apply_scene_patches(scene_path, scene_root)
	_log_debug("[Registry] patched scene node '%s' (%d field(s))" % [id, fields.size()])
	return true

# Stashed originals go back onto every live instance, and the patch is erased so
# later instances see vanilla.
func _revert_scene_node(id: String, fields: Array) -> bool:
	var parts := _split_scene_node_id(id)
	if parts.is_empty():
		push_warning("[Registry] revert('scene_nodes', '%s'): id must be '<res://scene_path>#<node_path>'" % id)
		return false
	var scene_path: String = parts[0]
	var node_path: String = parts[1]
	var per_node: Dictionary = _scene_node_patches.get(scene_path, {})
	if not per_node.has(node_path):
		push_warning("[Registry] revert('scene_nodes', '%s'): nothing patched at that id" % id)
		return false
	var props: Dictionary = per_node[node_path]
	var stash_per_scene: Dictionary = _scene_node_stash.get(scene_path, {})
	var stash_per_node: Dictionary = stash_per_scene.get(node_path, {})
	var targets: Array[String] = []
	for k in (props.keys() if fields.is_empty() else fields):
		targets.append(String(k))
	var live_roots: Array[Node] = []
	_collect_scene_roots(get_tree().root, scene_path, live_roots)
	var reverted_any := false
	for fname in targets:
		if props.has(fname):
			reverted_any = true
		if stash_per_node.has(fname):
			for root in live_roots:
				var target: Node = _resolve_scene_target(root, node_path)
				if target != null and _object_has_property(target, fname):
					target.set(fname, stash_per_node[fname])
			stash_per_node.erase(fname)
		elif not fields.is_empty() and not props.has(fname):
			push_warning("[Registry] revert('scene_nodes', '%s'): field '%s' wasn't patched" % [id, fname])
		# A patch no instance has applied yet has no stash entry but still goes.
		props.erase(fname)
	_prune_scene_store(_scene_node_patches, scene_path, node_path)
	_prune_scene_store(_scene_node_stash, scene_path, node_path)
	_log_debug("[Registry] reverted scene_nodes '%s' (fields=%s)" % [id, targets])
	return reverted_any

# Drops store[scene][node] once it is empty, then store[scene] once that is empty.
func _prune_scene_store(store: Dictionary, scene_path: String, node_path: String) -> void:
	var per_scene: Dictionary = store.get(scene_path, {})
	if (per_scene.get(node_path, {}) as Dictionary).is_empty():
		per_scene.erase(node_path)
	if per_scene.is_empty():
		store.erase(scene_path)

func _collect_scene_roots(node: Node, scene_path: String, out: Array[Node]) -> void:
	if node.scene_file_path == scene_path:
		# A nested instance of the same scene reaches node_added on its own.
		out.append(node)
		return
	for child in node.get_children():
		_collect_scene_roots(child, scene_path, out)
