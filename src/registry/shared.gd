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
