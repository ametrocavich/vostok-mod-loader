# Registry helpers used by more than one section handler.

func _bucket(store: Dictionary, section: String) -> Dictionary:
	return store.get_or_add(section, {})

# With `warn`, a missing autoload warns: a registry call that needs it came too early.
func _autoload_node(autoload: String, warn: bool) -> Node:
	var node := get_tree().root.get_node_or_null(autoload)
	if node == null and warn:
		push_warning("[Registry] %s autoload not in tree yet; is the loader still booting?" % autoload)
	return node

# True, with a warning, when the compile probe shipped `filename` without its registry
# code: the entries go through Engine meta that only the injected code reads.
func _registry_target_inert(filename: String, what: String) -> bool:
	if not _hook_pack_demotions.has("res://Scripts/" + filename):
		return false
	push_warning("[Registry] %s: %s lacks registry code on this game build (nothing will appear); update the ModLoader" \
			% [what, filename])
	return true

# The injected readers run in many independent scene instances and read the
# section from Engine meta `key`, in registration order.
func _publish_registry_meta(section: String, key: String) -> void:
	var flat: Array = []
	var reg := _bucket(_registry_registered, section)
	for id in reg.keys():
		flat.append(reg[id])
	Engine.set_meta(key, flat)

# Load-bearing: a Resource nothing else holds drops out of Godot's cache, and a
# later load() hands back a fresh copy without the mods' changes.
var _registry_resource_cache: Dictionary = {}
var _registry_resource_warned: Dictionary = {}

# A missing file returns null; with a `section` it also warns, once per path.
func _registry_resource(path: String, section: String) -> Resource:
	var cached = _registry_resource_cache.get(path)
	if cached != null:
		return cached
	var res = load(path)
	if res == null:
		if section != "" and not _registry_resource_warned.has(path):
			push_warning("[Registry] %s: %s missing at %s; %s registry is inert" \
					% [section, path.get_file(), path, section])
			_registry_resource_warned[path] = true
		return null
	_registry_resource_cache[path] = res
	return res

# A vanilla short name in `paths`, or an absolute res:// path, to the Resource there,
# which must carry an Array `field`. Warnings call the ref a `noun`.
func _resolve_named_resource(section: String, noun: String, ref: String, paths: Dictionary, field: String,
		type_name: String) -> Resource:
	if ref == "":
		push_warning("[Registry] %s: empty %s name" % [section, noun])
		return null
	var path := ref
	if paths.has(ref):
		path = paths[ref]
	elif not ref.begins_with("res://"):
		push_warning("[Registry] %s: unknown %s '%s' (valid: %s, or pass an absolute res:// path)" \
				% [section, noun, ref, paths.keys()])
		return null
	var res := _registry_resource(path, "")
	if res == null:
		push_warning("[Registry] %s: couldn't load %s at '%s'" % [section, type_name, path])
		return null
	if not (field in res):
		push_warning("[Registry] %s: resource at '%s' has no `%s` array (not a %s?)" \
				% [section, path, field, type_name])
		return null
	return res

# Object, not Resource, so scene_nodes can pass Nodes.
func _object_has_property(res: Object, prop: String) -> bool:
	for p in res.get_property_list():
		if p["name"] == prop:
			return true
	return false

func _has_properties(res: Object, props: Array) -> bool:
	for prop in props:
		if not _object_has_property(res, prop):
			return false
	return true

# `is ItemData` would need the game class in the loader's script scope, so this
# checks for the canonical `file` field.
func _looks_like_item_data(res: Variant) -> bool:
	return res is Resource and _object_has_property(res, "file")

# Must accept exactly what the engine's typed-array validation accepts: a false
# positive makes an append drop the value silently while the call reports success.
func _typed_array_accepts(arr: Array, item: Variant) -> bool:
	if not arr.is_typed():
		return true
	var builtin: int = arr.get_typed_builtin()
	if builtin != TYPE_OBJECT:
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
	# The native class, also the native base of a script-typed array ("Resource"
	# for Array[ItemData]).
	var cls: StringName = arr.get_typed_class_name()
	if cls != &"" and not (item as Object).is_class(String(cls)):
		return false
	var required = arr.get_typed_script()
	if required == null:
		return true
	var s = item.get_script()
	while s != null:
		if s == required:
			return true
		s = s.get_base_script()
	return false

# append, prepend and remove_from on an Array field. The stash is patch()'s, so a
# patch and an array op on one field keep the true original for revert.
func _array_op_on_resource(reg: String, stash_key: Variant, target: Resource, field: String, op: String,
		values: Array, allow_duplicates: bool) -> bool:
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
	if op != "remove_from":
		for v in values:
			if not _typed_array_accepts(working, v):
				push_warning("[Registry] %s('%s', %s): value %s rejected by typed-array constraint on field '%s'" \
						% [op, reg, str(stash_key), str(v), field])
				return false
	var stash: Dictionary = _bucket(_registry_patched, reg).get_or_add(stash_key, {})
	if not stash.has(field):
		stash[field] = (current as Array).duplicate()
		_patch_source_note(reg, stash_key, field, target)
	match op:
		"append":
			for v in values:
				if allow_duplicates or not working.has(v):
					working.append(v)
		"prepend":
			# In reverse, so prepend([a, b]) on [c] gives [a, b, c].
			for i in range(values.size() - 1, -1, -1):
				var v = values[i]
				if allow_duplicates or not working.has(v):
					working.insert(0, v)
		"remove_from":
			for v in values:
				while working.has(v):
					working.erase(v)
	target.set(field, working)
	_log_debug("[Registry] %s('%s', %s) field '%s' values=%s" % [op, reg, str(stash_key), field, str(values)])
	return true

# Returns how many fields were set. The property-list check, not get(), because get()
# returns null for a missing and a null property alike, so a typo would patch a phantom.
func _patch_resource_fields(section: String, key: Variant, target: Object, fields: Dictionary, stash: Dictionary,
		what: String) -> int:
	var applied := 0
	for field in fields.keys():
		var fname := String(field)
		if not _object_has_property(target, fname):
			push_warning("[Registry] patch('%s', '%s'): field '%s' doesn't exist on %s" \
					% [section, str(key), fname, what])
			continue
		if not stash.has(fname):
			stash[fname] = target.get(fname)
			_patch_source_note(section, key, fname, target)
		target.set(fname, fields[field])
		applied += 1
	return applied

# Empty `fields` restores the whole stash and is true whenever there was one; a
# per-field revert is true when it restored anything.
func _revert_stashed_fields(section: String, key: Variant, fields: Array, restore: Callable) -> bool:
	var patched: Dictionary = _registry_patched.get(section, {})
	if not patched.has(key):
		return false
	var stash: Dictionary = patched[key]
	if fields.is_empty():
		for fname in stash.keys():
			restore.call(fname, stash[fname])
		patched.erase(key)
		_patch_source_forget(section, key)
		return true
	var did_something := false
	for field in fields:
		var fname := String(field)
		if not stash.has(fname):
			push_warning("[Registry] revert('%s', '%s'): field '%s' wasn't patched" % [section, str(key), fname])
			continue
		restore.call(fname, stash[fname])
		_patch_source_forget(section, key, fname)
		stash.erase(fname)
		did_something = true
	if stash.is_empty():
		patched.erase(key)
	return did_something

# A removed entry takes its originals along, or they would poison a re-registration.
func _drop_patch_stash(section: String, key: Variant) -> void:
	var patched: Dictionary = _registry_patched.get(section, {})
	if patched.has(key):
		patched.erase(key)
		_patch_source_forget(section, key)

func _patch_source_note(reg: String, key: Variant, field: String, source: Variant) -> void:
	var by_field: Dictionary = _bucket(_registry_patch_sources, reg).get_or_add(key, {})
	by_field[field] = source

func _patch_source(reg: String, key: Variant, field: String, fallback: Variant) -> Variant:
	var by_field: Dictionary = (_registry_patch_sources.get(reg, {}) as Dictionary).get(key, {})
	return by_field.get(field, fallback)

func _patch_source_forget(reg: String, key: Variant, field: String = "") -> void:
	var by_key: Dictionary = _registry_patch_sources.get(reg, {})
	if not by_key.has(key):
		return
	if field == "":
		by_key.erase(key)
		return
	var by_field: Dictionary = by_key[key]
	by_field.erase(field)
	if by_field.is_empty():
		by_key.erase(key)
