## ----- registry/resources.gd -----
##
## Patches arbitrary field values on any vanilla .tres file. Intended as the
## generic fallback for Resources that don't have a dedicated registry: stat
## tuning files, config-like .tres, anything a mod author wants to tweak
## without us building a purpose-built registry.
##
## Usage:
##   lib.patch(RESOURCES, "res://Resources/GameData.tres", {"walk_speed": 5.0})
##   lib.revert(RESOURCES, "res://Resources/GameData.tres", ["walk_speed"])
##   lib.revert(RESOURCES, "res://Resources/GameData.tres")  # full revert
##
## The `id` is the absolute res:// path to the .tres. Godot's Resource cache
## ensures every `load()` of that path returns the same instance, so
## mutating fields on the loaded Resource propagates to all game-side
## holders. No register/override/remove; vanilla already defines the
## Resource; we only mutate fields and track rollback.
##
## Field stash keys per path, so the same path can be patched multiple
## times without losing the pre-first-patch value.

func _load_resource_at(path: String, verb: String) -> Resource:
	if path == "" or not path.begins_with("res://"):
		push_warning("[Registry] %s('resources', '%s'): id must be an absolute res:// path" % [verb, path])
		return null
	var res = load(path)
	if res == null:
		push_warning("[Registry] %s('resources', '%s'): couldn't load resource at path" % [verb, path])
		return null
	if not (res is Resource):
		push_warning("[Registry] %s('resources', '%s'): path doesn't resolve to a Resource" % [verb, path])
		return null
	return res

func _patch_resource(id: String, fields: Dictionary) -> bool:
	if fields.is_empty():
		push_warning("[Registry] patch('resources', '%s'): empty fields is a no-op" % id)
		return false
	var res := _load_resource_at(id, "patch")
	if res == null:
		return false
	var patched: Dictionary = _registry_patched.get("resources", {})
	var stash: Dictionary = patched.get(id, {})
	var any_applied := false
	for field in fields.keys():
		var fname := String(field)
		if not _resource_has_property(res, fname):
			push_warning("[Registry] patch('resources', '%s'): field '%s' doesn't exist on %s" % [id, fname, res.get_class()])
			continue
		# First-write-wins stash so subsequent patches to the same field
		# don't overwrite the original value.
		if not stash.has(fname):
			stash[fname] = res.get(fname)
		res.set(fname, fields[field])
		any_applied = true
	if not any_applied:
		return false
	patched[id] = stash
	_registry_patched["resources"] = patched
	_log_debug("[Registry] patched resource '%s' fields %s" % [id, fields.keys()])
	return true

func _revert_resource(id: String, fields: Array) -> bool:
	var patched: Dictionary = _registry_patched.get("resources", {})
	if not patched.has(id):
		push_warning("[Registry] revert('resources', '%s'): no patches on this path" % id)
		return false
	var res := _load_resource_at(id, "revert")
	if res == null:
		return false
	var stash: Dictionary = patched[id]
	# Full revert: restore every stashed field, clear the stash.
	if fields.is_empty():
		for fname in stash.keys():
			res.set(fname, stash[fname])
		patched.erase(id)
		_registry_patched["resources"] = patched
		return true
	# Per-field revert.
	var did_something := false
	for field in fields:
		var fname := String(field)
		if not stash.has(fname):
			push_warning("[Registry] revert('resources', '%s'): field '%s' wasn't patched" % [id, fname])
			continue
		res.set(fname, stash[fname])
		stash.erase(fname)
		did_something = true
	if stash.is_empty():
		patched.erase(id)
	else:
		patched[id] = stash
	_registry_patched["resources"] = patched
	return did_something
