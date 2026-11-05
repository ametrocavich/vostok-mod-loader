# ItemData keyed by `file`, the name vanilla reads. The Resource cache shares one ItemData per
# path, so a change reaches every holder, saves included (SlotData stores ItemData by value).

# LT_Master's items by `file`, read on the first lookup; LT_Master is fixed per install.
var _vanilla_items = null

func _register_item(id: String, data: Variant) -> bool:
	if not _looks_like_item_data(data):
		push_warning("[Registry] register('items', '%s', ...) expects an ItemData Resource, got %s" % [id, type_string(typeof(data))])
		return false
	if _find_vanilla_item(id) != null:
		push_warning("[Registry] register('items', '%s'): id collides with vanilla item; use override or patch instead" % id)
		return false
	var reg := _bucket(_registry_registered, "items")
	if reg.has(id):
		push_warning("[Registry] register('items', '%s'): already registered by a mod" % id)
		return false
	data.set("file", id)
	reg[id] = data
	_log_debug("[Registry] registered item '%s'" % id)
	return true

func _override_item(id: String, data: Variant) -> bool:
	if not _looks_like_item_data(data):
		push_warning("[Registry] override('items', '%s', ...) expects an ItemData Resource, got %s" % [id, type_string(typeof(data))])
		return false
	var existing := _lookup_item(id)
	if existing == null:
		push_warning("[Registry] override('items', '%s'): no existing item to override" % id)
		return false
	# First write wins, so stacked overrides revert to the original. The override itself
	# lives in the registered dict, where lookups find it.
	var ov := _bucket(_registry_overridden, "items")
	if not ov.has(id):
		ov[id] = existing
	_bucket(_registry_registered, "items")[id] = data
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
	var stash: Dictionary = _bucket(_registry_patched, "items").get_or_add(id, {})
	_patch_resource_fields("items", id, target, fields, stash, target.get_class())
	_log_debug("[Registry] patched item '%s' fields %s" % [id, fields.keys()])
	return true

func _array_op_item(id: String, field: String, op: String, values: Array, allow_duplicates: bool) -> bool:
	var target := _lookup_item(id)
	if target == null:
		push_warning("[Registry] %s('items', '%s'): no item with that id" % [op, id])
		return false
	return _array_op_on_resource("items", id, target, field, op, values, allow_duplicates)

func _remove_item(id: String) -> bool:
	var reg := _bucket(_registry_registered, "items")
	if not reg.has(id):
		push_warning("[Registry] remove('items', '%s'): not registered by a mod" % id)
		return false
	var ov: Dictionary = _registry_overridden.get("items", {})
	if ov.has(id):
		push_warning("[Registry] remove('items', '%s'): entry is an override, use revert instead" % id)
		return false
	reg.erase(id)
	_drop_patch_stash("items", id)
	_log_debug("[Registry] removed item '%s'" % id)
	return true

func _revert_item(id: String, fields: Array) -> bool:
	# A stashed value goes back onto the object it was read from: the override when the
	# patch came after it, the entry under the override when it came before.
	var restore := func(fname: String, value: Variant) -> void:
		var source: Resource = _patch_source("items", id, fname, _lookup_item(id))
		if source != null:
			source.set(fname, value)
	if fields.is_empty():
		var did_something := _revert_stashed_fields("items", id, [], restore)
		var ov := _bucket(_registry_overridden, "items")
		if ov.has(id):
			var reg := _bucket(_registry_registered, "items")
			var original = ov[id]
			if original != null and original != _find_vanilla_item(id):
				reg[id] = original
			else:
				reg.erase(id)
			ov.erase(id)
			did_something = true
		if not did_something:
			push_warning("[Registry] revert('items', '%s'): nothing to revert" % id)
		return did_something
	if not (_registry_patched.get("items", {}) as Dictionary).has(id):
		push_warning("[Registry] revert('items', '%s', %s): no patches on this id" % [id, fields])
		return false
	if _lookup_item(id) == null:
		push_warning("[Registry] revert('items', '%s', %s): id no longer resolves" % [id, fields])
		return false
	return _revert_stashed_fields("items", id, fields, restore)

func _lookup_item(id: String) -> Resource:
	var reg: Dictionary = _registry_registered.get("items", {})
	if reg.has(id):
		return reg[id]
	return _find_vanilla_item(id)

func _find_vanilla_item(id: String) -> Resource:
	if _vanilla_items == null:
		_vanilla_items = _lt_master_items_by_file()
		if _vanilla_items == null:
			push_warning("[Registry] LT_Master.tres missing or unreadable; items lookups see mod entries only")
			_vanilla_items = {}
	return _vanilla_items.get(id)

# LT_Master's items keyed by `file`, or null when it is missing; silent, unlike _find_vanilla_item.
func _lt_master_items_by_file() -> Variant:
	var master = load("res://Loot/LT_Master.tres")
	if master == null or not ("items" in master):
		return null
	var by_file: Dictionary = {}
	for it in master.items:
		if it == null:
			continue
		var f = it.get("file")
		if f != null and String(f) != "":
			by_file[String(f)] = it
	return by_file
