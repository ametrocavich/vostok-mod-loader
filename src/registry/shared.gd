## ----- registry/shared.gd -----
## Cross-section registry helpers. Used by more than one section handler, so
## they live here instead of duplicating in each registry file.

# Bump a reg's rollback-registered map with a bare marker entry. Section
# handlers that need to store per-id payload (items, loot) write the payload
# directly instead of calling this.
func _track_registered(registry: String, id: String) -> void:
	var reg: Dictionary = _registry_registered.get(registry, {})
	reg[id] = true
	_registry_registered[registry] = reg

# True if `res` has a declared property named `prop`. Used by patch() to
# reject typos and by shape-checks that test for a specific field.
func _resource_has_property(res: Resource, prop: String) -> bool:
	for p in res.get_property_list():
		if p.get("name") == prop:
			return true
	return false

# Heuristic: does this Resource carry the ItemData shape? We don't use `is
# ItemData` because that requires the class_name to be registered in our
# loader's script scope, which it isn't (ItemData is a game class). Instead
# check for the canonical `file` field every ItemData (and subclass) defines.
func _looks_like_item_data(res: Resource) -> bool:
	return _resource_has_property(res, "file")

# Typed-array validation. Array[ItemData] only accepts instances whose script
# chain inherits from the ItemData script. Raw Resource + inline GDScript
# won't pass. Walks item's script chain looking for a script whose resource
# path matches the array's declared type.
#
# Returns true if either the array is untyped, or the item inherits from the
# array's declared type. Lets handlers fail fast with a clear warning rather
# than letting Godot spit cryptic TypedArray errors.
func _typed_array_accepts(arr: Array, item: Variant) -> bool:
	if not arr.is_typed():
		return true
	# For typed arrays of Objects, get_typed_script() returns the required
	# script. Walk item's script chain; any match means it's a valid subclass.
	var required = arr.get_typed_script()
	if required == null:
		# Typed by built-in type, not a script class; fall back to duck check.
		return true
	if not (item is Object):
		return false
	var s = item.get_script()
	while s != null:
		if s == required:
			return true
		s = s.get_base_script()
	return false


# Shared core for append/prepend/remove_from. Per-registry helpers resolve the
# target Resource (via their existing _lookup_* / _load_* code) and delegate
# here. `stash_key` is the key under _registry_patched[reg] -- usually the id,
# but registries that accept Variant ids (recipes/events/trader_tasks) may
# resolve the id to a different stable key (see _resolve_patch_target). Stash
# is the same dict patch() uses, so patch + append on the same field keeps the
# true original on first-write-wins and revert restores it cleanly.
#
# `op` is "append", "prepend", or "remove_from".
# `allow_duplicates` only affects append/prepend; ignored on remove_from.
# Returns false on any validation failure (and does not mutate target).
func _array_op_on_resource(reg: String, stash_key: Variant, target: Resource, field: String, op: String, values: Array, allow_duplicates: bool = false) -> bool:
	if not _resource_has_property(target, field):
		push_warning("[Registry] %s('%s', %s): field '%s' doesn't exist on %s" \
				% [op, reg, str(stash_key), field, target.get_class()])
		return false
	var current = target.get(field)
	if not (current is Array):
		push_warning("[Registry] %s('%s', %s): field '%s' is not an Array (got %s)" \
				% [op, reg, str(stash_key), field, type_string(typeof(current))])
		return false
	var working: Array = (current as Array).duplicate()
	# Validate every input value passes the typed-array constraint up front,
	# so partial application can't leave the field with mixed-validity entries.
	if op != "remove_from":
		for v in values:
			if not _typed_array_accepts(working, v):
				push_warning("[Registry] %s('%s', %s): value %s rejected by typed-array constraint on field '%s'" \
						% [op, reg, str(stash_key), str(v), field])
				return false
	# First-write-wins stash. Stash holds the original Array (duplicated so the
	# stash itself can't be mutated by future ops on `working`). Shared with
	# patch's stash dict so a patch-then-append sequence preserves the true
	# pre-any-mutation value for revert.
	var patched: Dictionary = _registry_patched.get(reg, {})
	var stash: Dictionary = patched.get(stash_key, {})
	if not stash.has(field):
		stash[field] = (current as Array).duplicate()
	# Apply the op to `working`.
	match op:
		"append":
			for v in values:
				if allow_duplicates or not working.has(v):
					working.append(v)
		"prepend":
			# Insert in reverse so the resulting prefix order matches the
			# input order: prepend([a, b]) on [c] -> [a, b, c], not [b, a, c].
			for i in range(values.size() - 1, -1, -1):
				var v = values[i]
				if allow_duplicates or not working.has(v):
					working.insert(0, v)
		"remove_from":
			for v in values:
				# Remove ALL matching occurrences, not just the first. Mods
				# saying "remove this" almost always mean every instance.
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


# Coerce a single value or Array into an Array. Lets the public verbs accept
# either lib.append(reg, id, field, magA) or lib.append(reg, id, field, [magA, magB]).
func _coerce_to_array(values: Variant) -> Array:
	if values is Array:
		return values
	return [values]
