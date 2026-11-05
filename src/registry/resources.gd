## resources: patch fields of any vanilla .tres by its res:// path; the Resource
## cache carries the change to every holder.

func _load_resource_at(path: String, verb: String) -> Resource:
	if path == "" or not path.begins_with("res://"):
		push_warning("[Registry] %s('resources', '%s'): id must be an absolute res:// path" % [verb, path])
		return null
	var res := _registry_resource(path, "")
	if res == null:
		push_warning("[Registry] %s('resources', '%s'): couldn't load resource at path" % [verb, path])
	return res

func _array_op_resource(id: String, field: String, op: String, values: Array, allow_duplicates: bool) -> bool:
	var res := _load_resource_at(id, op)
	if res == null:
		return false
	return _array_op_on_resource("resources", id, res, field, op, values, allow_duplicates)

func _patch_resource(id: String, fields: Dictionary) -> bool:
	if fields.is_empty():
		push_warning("[Registry] patch('resources', '%s'): empty fields is a no-op" % id)
		return false
	var res := _load_resource_at(id, "patch")
	if res == null:
		return false
	# Nothing is recorded unless at least one field applied.
	var stash: Dictionary = (_registry_patched.get("resources", {}) as Dictionary).get(id, {})
	if _patch_resource_fields("resources", id, res, fields, stash, res.get_class()) == 0:
		return false
	_bucket(_registry_patched, "resources")[id] = stash
	_log_debug("[Registry] patched resource '%s' fields %s" % [id, fields.keys()])
	return true

func _revert_resource(id: String, fields: Array) -> bool:
	if not (_registry_patched.get("resources", {}) as Dictionary).has(id):
		push_warning("[Registry] revert('resources', '%s'): no patches on this path" % id)
		return false
	var res := _load_resource_at(id, "revert")
	if res == null:
		return false
	return _revert_stashed_fields("resources", id, fields,
			func(fname: String, value: Variant) -> void: res.set(fname, value))
