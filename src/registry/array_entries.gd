# recipes, events, trader_tasks and loot: entries in an Array on a const-preloaded vanilla
# Resource. Entries have no id, so the registry id is a handle the mod picks.

# Per section: the payload key that holds the entry, the key that names the
# array it goes in ("" when the section has one array) and the entry type.
const _ARRAY_ENTRY_SHAPES := {
	"recipes": {"entry": "recipe", "where": "category", "type": "RecipeData"},
	"events": {"entry": "event", "where": "", "type": "EventData"},
	"trader_tasks": {"entry": "task", "where": "trader", "type": "TaskData"},
	"loot": {"entry": "item", "where": "table", "type": "ItemData"},
}

func _array_entry_key(section: String) -> String:
	return _ARRAY_ENTRY_SHAPES[section]["entry"]

func _array_entry_matches(section: String, value: Variant) -> bool:
	match section:
		"recipes": return _looks_like_recipe_data(value)
		"events": return _looks_like_event_data(value)
		"trader_tasks": return _looks_like_task_data(value)
		"loot": return _looks_like_item_data(value)
	return false

# "a RecipeData", "an EventData".
func _array_entry_kind(section: String) -> String:
	var type_name: String = _ARRAY_ENTRY_SHAPES[section]["type"]
	return ("an " if type_name[0] in "AEIOU" else "a ") + type_name

# "recipe, category".
func _array_entry_payload_keys(section: String) -> String:
	var shape: Dictionary = _ARRAY_ENTRY_SHAPES[section]
	return shape["entry"] if shape["where"] == "" else "%s, %s" % [shape["entry"], shape["where"]]

func _array_entry_where(section: String, record: Dictionary) -> String:
	match section:
		"recipes": return "Recipes.%s" % record["category"]
		"events": return "Events.events"
		"trader_tasks": return "%s.tasks" % record["trader"]
	return "table '%s'" % record["table"]

# The live Array a record's entry sits in, or null.
func _array_entry_list(section: String, id: String, verb: String, record: Dictionary) -> Variant:
	var holder: Resource = null
	var field := ""
	match section:
		"recipes":
			holder = _recipes_resource()
			field = record["category"]
		"events":
			holder = _events_resource()
			field = "events"
		"trader_tasks":
			holder = _resolve_trader_data(record["trader"])
			field = "tasks"
		"loot":
			holder = record["table_res"]
			field = "items"
	if holder == null:
		return null
	var arr = holder.get(field)
	if not (arr is Array):
		push_warning("[Registry] %s('%s', '%s'): %s is not an Array" \
				% [verb, section, id, _array_entry_where(section, record)])
		return null
	return arr

# The record a register or override payload describes, or {} after a warning. Its
# keys are the payload's; loot also keeps the resolved table as `table_res`.
func _array_entry_record(section: String, id: String, verb: String, data: Variant) -> Dictionary:
	var shape: Dictionary = _ARRAY_ENTRY_SHAPES[section]
	if not (data is Dictionary):
		push_warning("[Registry] %s('%s', '%s', ...) expects Dictionary {%s}, got %s" \
				% [verb, section, id, _array_entry_payload_keys(section), type_string(typeof(data))])
		return {}
	var d: Dictionary = data
	for key in [shape["entry"], shape["where"]]:
		if key != "" and not d.has(key):
			push_warning("[Registry] %s('%s', '%s', ...) data dict missing '%s' key" % [verb, section, id, key])
			return {}
	var entry = d[shape["entry"]]
	if not _array_entry_matches(section, entry):
		push_warning("[Registry] %s('%s', '%s'): %s is not %s Resource" \
				% [verb, section, id, shape["entry"], _array_entry_kind(section)])
		return {}
	var record := {shape["entry"]: entry}
	match section:
		"recipes":
			var category = d["category"]
			if not (category is String) or not (category in _RECIPE_CATEGORIES):
				push_warning("[Registry] %s('recipes', '%s'): category must be one of %s, got '%s'" \
						% [verb, id, _RECIPE_CATEGORIES, category])
				return {}
			record["category"] = String(category)
		"trader_tasks":
			if not (d["trader"] is String):
				push_warning("[Registry] %s('trader_tasks', '%s'): trader must be a String (e.g. 'Generalist')" \
						% [verb, id])
				return {}
			record["trader"] = String(d["trader"])
		"loot":
			if not (d["table"] is String):
				push_warning("[Registry] %s('loot', '%s'): table must be a String (name or res:// path)" % [verb, id])
				return {}
			var table_res := _resolve_loot_table(d["table"])
			if table_res == null:
				return {}
			record["table"] = d["table"]
			record["table_res"] = table_res
	return record

func _array_entry_register(section: String, id: String, data: Variant) -> bool:
	var reg := _bucket(_registry_registered, section)
	if reg.has(id):
		push_warning("[Registry] register('%s', '%s'): already registered (pick a unique handle)" % [section, id])
		return false
	var record := _array_entry_record(section, id, "register", data)
	if record.is_empty():
		return false
	var arr = _array_entry_list(section, id, "register", record)
	if arr == null:
		return false
	var entry_key := _array_entry_key(section)
	var entry = record[entry_key]
	var where := _array_entry_where(section, record)
	if not _typed_array_accepts(arr, entry):
		push_warning("[Registry] register('%s', '%s'): %s type doesn't match the typed array %s" \
				% [section, id, entry_key, where])
		return false
	if entry in arr:
		push_warning("[Registry] register('%s', '%s'): %s is already in %s; use override to swap an existing entry" \
				% [section, id, entry_key, where])
		return false
	arr.append(entry)
	reg[id] = record
	_log_debug("[Registry] registered %s '%s' in %s" % [section, id, where])
	return true

func _array_entry_override(section: String, id: String, data: Variant) -> bool:
	var ov := _bucket(_registry_overridden, section)
	if ov.has(id):
		push_warning("[Registry] override('%s', '%s'): already overridden (revert first to re-override)" \
				% [section, id])
		return false
	if not (data is Dictionary) or not data.has("replaces"):
		push_warning("[Registry] override('%s', '%s', ...) requires {%s, replaces: %s} (the entry to swap out)" \
				% [section, id, _array_entry_payload_keys(section), _ARRAY_ENTRY_SHAPES[section]["type"]])
		return false
	var record := _array_entry_record(section, id, "override", data)
	if record.is_empty():
		return false
	var arr = _array_entry_list(section, id, "override", record)
	if arr == null:
		return false
	var entry_key := _array_entry_key(section)
	var new_entry = record[entry_key]
	var old_entry = data["replaces"]
	var where := _array_entry_where(section, record)
	if not _array_entry_matches(section, old_entry):
		push_warning("[Registry] override('%s', '%s'): 'replaces' is not %s Resource" \
				% [section, id, _array_entry_kind(section)])
		return false
	if not _typed_array_accepts(arr, new_entry):
		push_warning("[Registry] override('%s', '%s'): %s type doesn't match the typed array %s" \
				% [section, id, entry_key, where])
		return false
	var idx: int = arr.find(old_entry)
	if idx < 0:
		push_warning("[Registry] override('%s', '%s'): 'replaces' is not in %s" % [section, id, where])
		return false
	if new_entry in arr:
		push_warning("[Registry] override('%s', '%s'): the new %s is already in %s; would duplicate" \
				% [section, id, entry_key, where])
		return false
	arr[idx] = new_entry
	# The handle resolves to the override (get_entry reads the registered map);
	# `registered` keeps what it named before, for revert.
	var reg := _bucket(_registry_registered, section)
	var ov_record := record.duplicate()
	ov_record["replaced"] = old_entry
	ov_record["registered"] = reg.get(id)
	ov[id] = ov_record
	reg[id] = record
	_log_debug("[Registry] overrode %s '%s' in %s" % [section, id, where])
	return true

# [entry, patch stash key] for a handle or an entry ref, nulls where it resolves to
# neither. A ref keys on "ref:<instance_id>" so distinct instances do not collide.
func _array_entry_resolve(section: String, id: Variant) -> Array:
	if id is String:
		var reg: Dictionary = _registry_registered.get(section, {})
		return [reg[id][_array_entry_key(section)] if reg.has(id) else null, id]
	if _array_entry_matches(section, id):
		return [id, "ref:%d" % id.get_instance_id()]
	return [null, null]

# [entry, stash key] for patch and the array ops, or [] after a warning naming `verb`.
func _array_entry_target(verb: String, section: String, id: Variant) -> Array:
	var resolved := _array_entry_resolve(section, id)
	if resolved[0] != null:
		return resolved
	if id is String:
		push_warning("[Registry] %s('%s', '%s'): no registered handle with that id (or pass %s Resource ref)" \
				% [verb, section, id, _array_entry_kind(section)])
	else:
		push_warning("[Registry] %s('%s', ...): id must be a String handle or %s Resource" \
				% [verb, section, _array_entry_kind(section)])
	return []

func _array_entry_patch(section: String, id: Variant, fields: Dictionary) -> bool:
	if fields.is_empty():
		push_warning("[Registry] patch('%s', ...): empty fields dict is a no-op" % section)
		return false
	var target := _array_entry_target("patch", section, id)
	if target.is_empty():
		return false
	var key = target[1]
	var stash: Dictionary = _bucket(_registry_patched, section).get_or_add(key, {})
	_patch_resource_fields(section, key, target[0], fields, stash, _ARRAY_ENTRY_SHAPES[section]["type"])
	_log_debug("[Registry] patched %s (key=%s) fields %s" % [section, key, fields.keys()])
	return true

func _array_entry_remove(section: String, id: String) -> bool:
	var reg := _bucket(_registry_registered, section)
	if not reg.has(id):
		push_warning("[Registry] remove('%s', '%s'): not a mod registration" % [section, id])
		return false
	if (_registry_overridden.get(section, {}) as Dictionary).has(id):
		push_warning("[Registry] remove('%s', '%s'): entry is an override, use revert instead" % [section, id])
		return false
	var record: Dictionary = reg[id]
	var entry_key := _array_entry_key(section)
	var arr = _array_entry_list(section, id, "remove", record)
	if arr != null:
		var idx: int = arr.find(record[entry_key])
		if idx >= 0:
			arr.remove_at(idx)
		else:
			push_warning("[Registry] remove('%s', '%s'): %s not found in %s; tracking cleared" \
					% [section, id, entry_key, _array_entry_where(section, record)])
	reg.erase(id)
	# Or a revert after a re-registration under this handle would write the old
	# entry's values onto the new one. A ref's stash tracks the Resource and stays.
	_drop_patch_stash(section, id)
	_log_debug("[Registry] removed %s '%s'" % [section, id])
	return true

func _array_entry_revert(section: String, id: Variant, fields: Array) -> bool:
	var resolved := _array_entry_resolve(section, id)
	var target: Resource = resolved[0]
	var key = resolved[1]
	# A stashed value goes back onto the entry it was read from: the override's when
	# the patch came after it, the replaced entry's when it came before.
	var restore := func(fname: String, value: Variant) -> void:
		var source: Resource = _patch_source(section, key, fname, target)
		if source != null:
			source.set(fname, value)
	if not fields.is_empty():
		if key == null or not (_registry_patched.get(section, {}) as Dictionary).has(key):
			push_warning("[Registry] revert('%s'): no patches found for that id" % section)
			return false
		if target == null:
			push_warning("[Registry] revert('%s'): patch target no longer resolves" % section)
			return false
		return _revert_stashed_fields(section, key, fields, restore)
	# A full revert drops every patch first, then undoes the override.
	var did_something := key != null and _revert_stashed_fields(section, key, [], restore)
	if id is String and _undo_array_override(section, id):
		did_something = true
	if not did_something:
		push_warning("[Registry] revert('%s'): nothing to revert for that id" % section)
	return did_something

# Puts the replaced entry back and the handle on what it named before; false when
# the handle has no override.
func _undo_array_override(section: String, id: String) -> bool:
	var ov: Dictionary = _registry_overridden.get(section, {})
	if not ov.has(id):
		return false
	var entry: Dictionary = ov[id]
	var entry_key := _array_entry_key(section)
	var arr = _array_entry_list(section, id, "revert", entry)
	if arr != null:
		# Found again: the index may have shifted since the override.
		var idx: int = arr.find(entry[entry_key])
		if idx >= 0:
			arr[idx] = entry["replaced"]
		else:
			push_warning("[Registry] revert('%s', '%s'): the override's %s left %s; original appended" \
					% [section, id, entry_key, _array_entry_where(section, entry)])
			arr.append(entry["replaced"])
	ov.erase(id)
	# Erasing the handle would orphan the registration it named before the override.
	var reg := _bucket(_registry_registered, section)
	if entry["registered"] is Dictionary:
		reg[id] = entry["registered"]
	else:
		reg.erase(id)
	return true
