## ----- registry/shared.gd -----
## Cross-section registry helpers. Used by more than one section handler, so
## they live here instead of duplicating in each registry file.

# Bare rollback marker. Handlers that store per-id payload write it
# directly instead; only scenes.gd uses this form.
func _track_registered(registry: String, id: String) -> void:
	var reg: Dictionary = _registry_registered.get(registry, {})
	reg[id] = true
	_registry_registered[registry] = reg

# True if `res` declares a property named `prop`. Param is Object (not
# Resource) so Node-backed callers (scene_nodes) can share it.
func _object_has_property(res: Object, prop: String) -> bool:
	for p in res.get_property_list():
		if p.get("name") == prop:
			return true
	return false

# ItemData shape heuristic. `is ItemData` would need the game class in the
# loader's script scope; check the canonical `file` field instead.
func _looks_like_item_data(res: Resource) -> bool:
	return _object_has_property(res, "file")

# True if the array is untyped or the item is accepted by its declared
# type. Must mirror what the engine's own typed-array validation accepts:
# _array_op_on_resource treats a pass here as "every append will land", so
# a false positive means the engine silently drops the value while the
# call reports success.
func _typed_array_accepts(arr: Array, item: Variant) -> bool:
	if not arr.is_typed():
		return true
	var builtin: int = arr.get_typed_builtin()
	if builtin != TYPE_OBJECT:
		# Built-in Variant type: accept exact match plus the strict
		# conversions the engine's container validation performs.
		var t: int = typeof(item)
		if t == builtin:
			return true
		match builtin:
			TYPE_INT, TYPE_FLOAT:
				return t == TYPE_INT or t == TYPE_FLOAT or t == TYPE_BOOL
			TYPE_BOOL:
				return t == TYPE_INT or t == TYPE_FLOAT
			TYPE_STRING:
				return t == TYPE_STRING_NAME or t == TYPE_NODE_PATH
			TYPE_STRING_NAME, TYPE_NODE_PATH:
				return t == TYPE_STRING
		return false
	if not (item is Object):
		return false
	# Native-class constraint (also the native base of script-typed arrays,
	# e.g. "Resource" for Array[ItemData]).
	var cls: StringName = arr.get_typed_class_name()
	if cls != &"" and not (item as Object).is_class(String(cls)):
		return false
	# Script constraint: any match in item's script chain is a valid subclass.
	var required = arr.get_typed_script()
	if required == null:
		return true
	var s = item.get_script()
	while s != null:
		if s == required:
			return true
		s = s.get_base_script()
	return false


# Shared core for append/prepend/remove_from; per-registry helpers resolve
# the target Resource and delegate here. `stash_key` is the key under
# _registry_patched[reg] -- usually the id, but Variant-id registries may
# resolve to a different stable key. The stash is the same dict patch()
# uses, so patch + append on one field keeps the true original for revert.
# Returns false on any validation failure without mutating target.
func _array_op_on_resource(reg: String, stash_key: Variant, target: Resource, field: String, op: String, values: Array, allow_duplicates: bool = false) -> bool:
	if not _object_has_property(target, field):
		push_warning("[Registry] %s('%s', %s): field '%s' doesn't exist on %s" \
				% [op, reg, str(stash_key), field, target.get_class()])
		return false
	var current = target.get(field)
	if not (current is Array):
		push_warning("[Registry] %s('%s', %s): field '%s' is not an Array (got %s)" \
				% [op, reg, str(stash_key), field, type_string(typeof(current))])
		return false
	var working: Array = (current as Array).duplicate()
	# Validate every value up front so partial application can't happen.
	if op != "remove_from":
		for v in values:
			if not _typed_array_accepts(working, v):
				push_warning("[Registry] %s('%s', %s): value %s rejected by typed-array constraint on field '%s'" \
						% [op, reg, str(stash_key), str(v), field])
				return false
	# First-write-wins stash; duplicated so later ops can't mutate it.
	var patched: Dictionary = _registry_patched.get(reg, {})
	var stash: Dictionary = patched.get(stash_key, {})
	if not stash.has(field):
		stash[field] = (current as Array).duplicate()
	match op:
		"append":
			for v in values:
				if allow_duplicates or not working.has(v):
					working.append(v)
		"prepend":
			# Insert in reverse so prepend([a, b]) on [c] -> [a, b, c].
			for i in range(values.size() - 1, -1, -1):
				var v = values[i]
				if allow_duplicates or not working.has(v):
					working.insert(0, v)
		"remove_from":
			for v in values:
				# All matching occurrences, not just the first.
				while working.has(v):
					working.erase(v)
		_:
			push_warning("[Registry] _array_op_on_resource: unknown op '%s'" % op)
			return false
	target.set(field, working)
	patched[stash_key] = stash
	_registry_patched[reg] = patched
	_log_debug("[Registry] %s('%s', %s) field '%s' values=%s" % [op, reg, str(stash_key), field, str(values)])
	return true


# Coerce a single value or Array into an Array.
func _coerce_to_array(values: Variant) -> Array:
	if values is Array:
		return values
	return [values]
