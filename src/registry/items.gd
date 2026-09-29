## ----- registry/items.gd -----
## Items are ItemData Resources (or subclasses). Godot's Resource cache
## returns the same instance for every load(), so mutating a loaded
## ItemData mutates it for every holder -- including what saves deserialize,
## since SlotData serializes ItemData by-value.
##
## Vanilla has no central file-string -> ItemData lookup; mod-registered
## items live in a dict keyed by `file`, the primary id, since vanilla
## code reads itemData.file directly.

# Vanilla item resolution: scan LT_Master.items for a matching `file`
# string, cached on first use (LT_Master is static per install).
var _vanilla_item_cache: Dictionary = {}
var _vanilla_item_cache_built: bool = false

func _register_item(id: String, data: Variant) -> bool:
	if not (data is Resource) or not _looks_like_item_data(data):
		push_warning("[Registry] register('items', '%s', ...) expects an ItemData Resource, got %s" % [id, typeof(data)])
		return false
	if _find_vanilla_item(id) != null:
		push_warning("[Registry] register('items', '%s'): id collides with vanilla item; use override or patch instead" % id)
		return false
	var reg: Dictionary = _registry_registered.get("items", {})
	if reg.has(id):
		push_warning("[Registry] register('items', '%s'): already registered by a mod" % id)
		return false
	# Keep ItemData.file in sync with the registry id; vanilla assumes it
	# matches the item's canonical name.
	if data.get("file") != id:
		data.set("file", id)
	reg[id] = data
	_registry_registered["items"] = reg
	_log_debug("[Registry] registered item '%s'" % id)
	return true

func _override_item(id: String, data: Variant) -> bool:
	if not (data is Resource) or not _looks_like_item_data(data):
		push_warning("[Registry] override('items', '%s', ...) expects an ItemData Resource, got %s" % [id, typeof(data)])
		return false
	var existing := _lookup_item(id)
	if existing == null:
		push_warning("[Registry] override('items', '%s'): no existing item to override" % id)
		return false
	# Stash the original (by ref) once; subsequent overrides don't clobber.
	var ov: Dictionary = _registry_overridden.get("items", {})
	if not ov.has(id):
		ov[id] = existing
		_registry_overridden["items"] = ov
	# Overrides live in _registry_registered (lookups hit that dict); the
	# overridden map exists only so revert can restore.
	var reg: Dictionary = _registry_registered.get("items", {})
	reg[id] = data
	_registry_registered["items"] = reg
	if data.get("file") != id:
		data.set("file", id)
	_log_debug("[Registry] overrode item '%s'" % id)
	return true

func _patch_item(id: String, fields: Dictionary) -> bool:
	if fields.is_empty():
		push_warning("[Registry] patch('items', '%s', ...): empty fields dict is a no-op" % id)
		return false
	var target := _lookup_item(id)
	if target == null:
		push_warning("[Registry] patch('items', '%s'): no item with that id" % id)
		return false
	var patched: Dictionary = _registry_patched.get("items", {})
	var stash: Dictionary = patched.get(id, {})
	for field in fields.keys():
		var field_name := String(field)
		# Property-list check, not get(): Resource.get() returns null for
		# both "missing" and legitimate null, so typos would patch a phantom.
		if not _object_has_property(target, field_name):
			push_warning("[Registry] patch('items', '%s'): field '%s' doesn't exist on %s" \
					% [id, field_name, target.get_class()])
			continue
		if not stash.has(field_name):
			stash[field_name] = target.get(field_name)
			_patch_source_note("items", id, field_name, target)
		target.set(field_name, fields[field])
	patched[id] = stash
	_registry_patched["items"] = patched
	_log_debug("[Registry] patched item '%s' fields %s" % [id, fields.keys()])
	return true

# append, prepend and remove_from share one body; `op` selects the operation.
func _array_op_item(id: String, field: String, op: String, values: Array, allow_duplicates: bool) -> bool:
	var target := _lookup_item(id)
	if target == null:
		push_warning("[Registry] %s('items', '%s'): no item with that id" % [op, id])
		return false
	return _array_op_on_resource("items", id, target, field, op, values, allow_duplicates)


func _remove_item(id: String) -> bool:
	var reg: Dictionary = _registry_registered.get("items", {})
	if not reg.has(id):
		push_warning("[Registry] remove('items', '%s'): not registered by a mod" % id)
		return false
	# Overrides live in reg too but must be reverted, not removed.
	var ov: Dictionary = _registry_overridden.get("items", {})
	if ov.has(id):
		push_warning("[Registry] remove('items', '%s'): entry is an override, use revert instead" % id)
		return false
	reg.erase(id)
	_registry_registered["items"] = reg
	# Drop the patch stash with the entry: revert after a re-registration of
	# the same id would otherwise write the old item's values onto the new.
	var patched: Dictionary = _registry_patched.get("items", {})
	if patched.has(id):
		patched.erase(id)
		_registry_patched["items"] = patched
		_patch_source_forget("items", id)
	_log_debug("[Registry] removed item '%s'" % id)
	return true

func _revert_item(id: String, fields: Array) -> bool:
	var did_something := false
	var ov: Dictionary = _registry_overridden.get("items", {})
	var patched: Dictionary = _registry_patched.get("items", {})
	# Full revert: the patch stash first, each value onto the object it was
	# read from (the override when the patch came after it, the entry under
	# the override when it came before), then the override.
	if fields.is_empty():
		if patched.has(id):
			var stash: Dictionary = patched[id]
			for fname in stash.keys():
				var source: Resource = _patch_source("items", id, fname, _lookup_item(id))
				if source != null:
					source.set(fname, stash[fname])
			patched.erase(id)
			_registry_patched["items"] = patched
			_patch_source_forget("items", id)
			did_something = true
		if ov.has(id):
			var reg: Dictionary = _registry_registered.get("items", {})
			var original = ov[id]
			if original != null and original != _find_vanilla_item(id):
				# The overridden entry was a mod registration; put it back.
				reg[id] = original
			else:
				reg.erase(id)
			_registry_registered["items"] = reg
			ov.erase(id)
			_registry_overridden["items"] = ov
			did_something = true
		if not did_something:
			push_warning("[Registry] revert('items', '%s'): nothing to revert" % id)
		return did_something
	# Per-field revert; overrides are whole-entry and don't combine with it.
	if not patched.has(id):
		push_warning("[Registry] revert('items', '%s', %s): no patches on this id" % [id, fields])
		return false
	var target := _lookup_item(id)
	if target == null:
		push_warning("[Registry] revert('items', '%s', %s): id no longer resolves" % [id, fields])
		return false
	var stash: Dictionary = patched[id]
	for field in fields:
		var fname := String(field)
		if not stash.has(fname):
			push_warning("[Registry] revert('items', '%s'): field '%s' wasn't patched" % [id, fname])
			continue
		(_patch_source("items", id, fname, target) as Resource).set(fname, stash[fname])
		_patch_source_forget("items", id, fname)
		stash.erase(fname)
		did_something = true
	if stash.is_empty():
		patched.erase(id)
	else:
		patched[id] = stash
	_registry_patched["items"] = patched
	return did_something

# Mod entries (including overrides, which live in the same dict) beat
# vanilla.
func _lookup_item(id: String) -> Resource:
	var reg: Dictionary = _registry_registered.get("items", {})
	if reg.has(id):
		return reg[id]
	return _find_vanilla_item(id)

func _find_vanilla_item(id: String) -> Resource:
	if not _vanilla_item_cache_built:
		_build_vanilla_item_cache()
	return _vanilla_item_cache.get(id)

func _build_vanilla_item_cache() -> void:
	_vanilla_item_cache_built = true
	var master = load("res://Loot/LT_Master.tres")
	if master == null or not ("items" in master):
		push_warning("[Registry] LT_Master.tres missing or unreadable; items registry lookups will only see mod entries")
		return
	for it in master.items:
		if it == null:
			continue
		var f = it.get("file")
		if f != null and String(f) != "":
			_vanilla_item_cache[String(f)] = it
