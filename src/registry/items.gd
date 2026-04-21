## ----- registry/items.gd -----
##
## Items are ItemData Resources (or subclasses: WeaponData, AttachmentData, etc).
## Godot's Resource caching means every `load("res://Items/.../Potato.tres")`
## returns the same instance, so mutating the loaded ItemData mutates it for
## every holder; including what saves deserialize on next load, because
## SlotData serializes ItemData references by-value.
##
## Vanilla has no central file-string -> ItemData lookup; code passes ItemData
## references around directly. So `register` doesn't need to inject anything
## global: we keep mod-registered items in a dict keyed by `file` and expose
## them via get_entry(). `file` is the primary id since vanilla code reads
## itemData.file directly.

# Vanilla item resolution: LT_Master.items is the authoritative list of every
# ItemData that ships with the game. Scan it for a matching `file` string.
# Cached on first hit since LT_Master is static for a given game install.
var _vanilla_item_cache: Dictionary = {}
var _vanilla_item_cache_built: bool = false

func _register_item(id: String, data: Variant) -> bool:
	if not (data is Resource) or not _looks_like_item_data(data):
		push_warning("[Registry] register('items', '%s', ...) expects an ItemData Resource, got %s" % [id, typeof(data)])
		return false
	# Collision: vanilla item with matching file, or prior mod registration.
	if _find_vanilla_item(id) != null:
		push_warning("[Registry] register('items', '%s'): id collides with vanilla item; use override or patch instead" % id)
		return false
	var reg: Dictionary = _registry_registered.get("items", {})
	if reg.has(id):
		push_warning("[Registry] register('items', '%s'): already registered by a mod" % id)
		return false
	# Keep ItemData.file in sync with the registry id; vanilla code reads
	# itemData.file directly and assumes it matches the item's canonical name.
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
	# Overrides live in _registry_registered because lookup precedence is
	# override > register > vanilla, and we key both by id. Track in
	# overridden map so revert can restore; the live value in registered dict
	# is what lookups hit.
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
		# Resource.get() returns null both for "missing" and for legitimate
		# null values. Prefer property-list check so mistyped field names
		# surface as warnings instead of silently patching a phantom field.
		if not _resource_has_property(target, field_name):
			push_warning("[Registry] patch('items', '%s'): field '%s' doesn't exist on %s" \
					% [id, field_name, target.get_class()])
			continue
		# First-write-wins stash: keep pre-any-patch value so revert restores
		# the true original no matter how many patches have piled on.
		if not stash.has(field_name):
			stash[field_name] = target.get(field_name)
		target.set(field_name, fields[field])
	patched[id] = stash
	_registry_patched["items"] = patched
	_log_debug("[Registry] patched item '%s' fields %s" % [id, fields.keys()])
	return true

func _remove_item(id: String) -> bool:
	var reg: Dictionary = _registry_registered.get("items", {})
	if not reg.has(id):
		push_warning("[Registry] remove('items', '%s'): not registered by a mod" % id)
		return false
	# Block remove on entries that are actually overrides, not registrations.
	# An override lives in reg too (see _override_item rationale) but must be
	# reverted, not removed; remove implies "undo a register()".
	var ov: Dictionary = _registry_overridden.get("items", {})
	if ov.has(id):
		push_warning("[Registry] remove('items', '%s'): entry is an override, use revert instead" % id)
		return false
	reg.erase(id)
	_registry_registered["items"] = reg
	_log_debug("[Registry] removed item '%s'" % id)
	return true

func _revert_item(id: String, fields: Array) -> bool:
	# Two revert modes: (a) full-entry revert of an override(), (b) per-field
	# revert of patch()es. Caller distinguishes by presence of `fields`.
	var did_something := false
	var ov: Dictionary = _registry_overridden.get("items", {})
	var patched: Dictionary = _registry_patched.get("items", {})
	# Full revert: no fields specified -> undo override AND clear all patches.
	# Order matters: restore patch stash FIRST (onto the currently-resolving
	# entry, which may be an override), THEN drop the override so lookups
	# fall back to vanilla. Reversing would restore patch values onto vanilla
	# ItemData, mutating the base resource permanently.
	if fields.is_empty():
		if patched.has(id):
			var target := _lookup_item(id)
			if target != null:
				var stash: Dictionary = patched[id]
				for fname in stash.keys():
					target.set(fname, stash[fname])
			patched.erase(id)
			_registry_patched["items"] = patched
			did_something = true
		if ov.has(id):
			var reg: Dictionary = _registry_registered.get("items", {})
			reg.erase(id)
			_registry_registered["items"] = reg
			ov.erase(id)
			_registry_overridden["items"] = ov
			did_something = true
		if not did_something:
			push_warning("[Registry] revert('items', '%s'): nothing to revert" % id)
		return did_something
	# Per-field revert: only undo the named fields on a patch(). Overrides
	# are whole-entry and don't combine with field-level revert.
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
		target.set(fname, stash[fname])
		stash.erase(fname)
		did_something = true
	if stash.is_empty():
		patched.erase(id)
	else:
		patched[id] = stash
	_registry_patched["items"] = patched
	return did_something

# Lookup precedence: mod registrations (which includes overrides) first, then
# vanilla. Matches the scenes registry's override > mod > vanilla shape;
# here overrides live inside the mod-registered dict, so the order collapses
# to "mod entries beat vanilla."
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
