## weapons, magazines, attachments and the register_item / register_furniture bundles: no state
## of their own; each fans out to the primitive registries and reports every step in its result.

func _register_weapon(id: String, data: Variant) -> Dictionary:
	var result: Dictionary = {
		"ok": false,
		"items": false,
		"scene": false,
		"rig": false,
		"magazines": [],
		"fits_attachments": [],
		"fits_attachments_failed": [],
		"loot_count": 0,
		"ai_loadout": null,
	}
	var what := "register('weapons', '%s'" % id
	var d := _bundle_data(what, data, ["item_path", "scene_path", "rig_path"])
	if d.is_empty():
		return result
	var weapon_item := _load_bundle_item(id, d, what)
	if weapon_item == null:
		return result
	result["items"] = _register_item(id, weapon_item)
	if not result["items"]:
		return result
	var world_scene := _load_bundle_scene(what, d["scene_path"])
	if world_scene != null:
		result["scene"] = _register_scene(id, world_scene)
	var rig_scene := _load_bundle_scene(what, d["rig_path"])
	if rig_scene != null:
		result["rig"] = _register_scene(id + "_Rig", rig_scene)
	var compatible_additions: Array = []
	if d.get("magazines") is Array:
		for entry in d["magazines"]:
			var mag := _weapon_magazine(entry)
			result["magazines"].append(mag)
			if mag["item_data"] != null:
				compatible_additions.append(mag["item_data"])
	if d.get("fits_attachments") is Array:
		for att_id in d["fits_attachments"]:
			if not (att_id is String):
				continue
			var att_item: Resource = _lookup_item(att_id)
			if att_item == null:
				result["fits_attachments_failed"].append(att_id)
				push_warning("[Registry] %s): fits_attachments id '%s' didn't resolve" % [what, att_id])
				continue
			result["fits_attachments"].append(att_id)
			if not (att_item in compatible_additions):
				compatible_additions.append(att_item)
	if not compatible_additions.is_empty():
		_extend_compatible(id, weapon_item, compatible_additions)
	result["loot_count"] = _register_bundle_loot(id, weapon_item, d)
	if d.has("ai_loadout"):
		var al: Variant = d["ai_loadout"]
		if al is Dictionary:
			var loadout: Dictionary = al.duplicate()
			loadout["weapon_scene"] = world_scene
			result["ai_loadout"] = _register_ai_loadout(id, loadout)
		else:
			push_warning("[Registry] %s): ai_loadout must be a Dictionary, got %s" % [what, type_string(typeof(al))])
			result["ai_loadout"] = false
	result["ok"] = result["items"] and result["scene"] and result["rig"] \
			and result["fits_attachments_failed"].is_empty()
	_log_debug("[Registry] register_weapon('%s') result: %s" % [id, result])
	return result

# One entry of a weapon's `magazines`: an inline magazine bundle or an item id.
func _weapon_magazine(entry: Variant) -> Dictionary:
	if entry is String:
		var mag: Resource = _lookup_item(entry)
		if mag == null:
			push_warning("[Registry] register_weapon: magazine id '%s' didn't resolve (typo? not registered yet?)" % entry)
		return {"id": entry, "ok": mag != null, "item_data": mag}
	if not (entry is Dictionary):
		push_warning("[Registry] register_weapon: magazine entry must be a Dictionary or String id, got %s" % type_string(typeof(entry)))
		return {"id": "", "ok": false, "item_data": null}
	if not (entry.get("id") is String):
		push_warning("[Registry] register_weapon: inline magazine missing 'id' string key")
		return {"id": "", "ok": false, "item_data": null}
	var mag_id: String = entry["id"]
	var sub := _register_magazine(mag_id, entry)
	# Look the item up only when it registered: on an id collision _lookup_item
	# would wire the unrelated colliding item into compatible.
	return {
		"id": mag_id,
		"ok": sub["ok"],
		"item_data": _lookup_item(mag_id) if sub["items"] else null,
		"items": sub["items"],
		"scene": sub["scene"],
		"loot_count": sub["loot_count"],
	}

func _register_magazine(id: String, data: Variant) -> Dictionary:
	return _register_compat_item(id, data, "magazines")

func _register_attachment(id: String, data: Variant) -> Dictionary:
	return _register_compat_item(id, data, "attachments")

func _register_compat_item(id: String, data: Variant, label: String) -> Dictionary:
	var result: Dictionary = {
		"ok": false,
		"items": false,
		"scene": false,
		"fits_weapons": [],
		"fits_weapons_failed": [],
		"loot_count": 0,
	}
	var what := "register('%s', '%s'" % [label, id]
	var d := _bundle_data(what, data, ["item_path", "scene_path"])
	if d.is_empty():
		return result
	var item_data := _load_bundle_item(id, d, what)
	if item_data == null:
		return result
	result["items"] = _register_item(id, item_data)
	if not result["items"]:
		return result
	var scene := _load_bundle_scene(what, d["scene_path"])
	if scene != null:
		result["scene"] = _register_scene(id, scene)
	if d.get("fits_weapons") is Array:
		for weapon_id in d["fits_weapons"]:
			if not (weapon_id is String):
				continue
			var weapon_item: Resource = _lookup_item(weapon_id)
			if weapon_item == null:
				result["fits_weapons_failed"].append(weapon_id)
				push_warning("[Registry] %s): fits_weapons id '%s' didn't resolve" % [what, weapon_id])
			elif _extend_compatible(weapon_id, weapon_item, [item_data]):
				result["fits_weapons"].append(weapon_id)
			else:
				result["fits_weapons_failed"].append(weapon_id)
	result["loot_count"] = _register_bundle_loot(id, item_data, d)
	result["ok"] = result["items"] and result["scene"] and result["fits_weapons_failed"].is_empty()
	_log_debug("[Registry] register_%s('%s') result: %s" % [label.trim_suffix("s"), id, result])
	return result

func _register_item_bundle(id: String, data: Variant) -> Dictionary:
	var result: Dictionary = {
		"ok": false,
		"items": false,
		"scene": true,
		"loot_count": 0,
		"trader_pool_count": 0,
		"trader_pools": [],
		"trader_pools_failed": [],
	}
	var what := "register_item('%s'" % id
	var d := _bundle_data(what, data, ["item_path"])
	if d.is_empty():
		return result
	var item_data := _load_bundle_item(id, d, what)
	if item_data == null:
		return result
	result["items"] = _register_item(id, item_data)
	if not result["items"]:
		return result
	if d.has("scene_path"):
		var scene := _load_bundle_scene(what, d["scene_path"])
		result["scene"] = scene != null and _register_scene(id, scene)
	result["loot_count"] = _register_bundle_loot(id, item_data, d)
	if d.get("trader_pools") is Array:
		_register_bundle_pools(id, item_data, d["trader_pools"], result)
	result["ok"] = result["items"] and result["scene"] and result["trader_pools_failed"].is_empty()
	_log_debug("[Registry] register_item('%s') result: %s" % [id, result])
	return result

func _register_furniture_bundle(id: String, data: Variant) -> Dictionary:
	var result: Dictionary = {
		"ok": false,
		"items": false,
		"scene": false,
		"trader_pool_count": 0,
		"trader_pools": [],
		"trader_pools_failed": [],
		"recipe": null,
	}
	var what := "register_furniture('%s'" % id
	var d := _bundle_data(what, data, ["item_path", "scene_path"])
	if d.is_empty():
		return result
	if d.has("loot_tables"):
		push_warning("[Registry] %s): loot_tables ignored; furniture only comes from trader_pools" % what)
	var item_data := _load_bundle_item(id, d, what)
	if item_data == null:
		return result
	result["items"] = _register_item(id, item_data)
	if "type" in item_data and str(item_data.get("type")) != "Furniture":
		push_warning("[Registry] %s): ItemData.type '%s' is not 'Furniture'; it skips the catalog" % [what, item_data.get("type")])
	if not result["items"]:
		return result
	var scene := _load_bundle_scene(what, d["scene_path"])
	if scene != null:
		result["scene"] = _register_scene(id, scene)
	var pools: Array = ["Generalist"]
	if d.get("trader_pools") is Array and not d["trader_pools"].is_empty():
		pools = d["trader_pools"]
	else:
		push_warning("[Registry] %s): no trader_pools; defaulting to ['Generalist']" % what)
	_register_bundle_pools(id, item_data, pools, result)
	if d.has("recipe"):
		result["recipe"] = _register_furniture_recipe(id, item_data, d["recipe"])
	result["ok"] = result["items"] and result["scene"] and result["trader_pools_failed"].is_empty()
	_log_debug("[Registry] register_furniture('%s') result: %s" % [id, result])
	return result

# A RecipeData filed under Recipes.furniture, the item as its output.
func _register_furniture_recipe(id: String, output_item: Resource, raw: Variant) -> bool:
	if not (raw is Dictionary):
		push_warning("[Registry] register_furniture('%s'): recipe must be a Dictionary, got %s" % [id, type_string(typeof(raw))])
		return false
	var rd: Dictionary = raw
	if not (rd.get("input") is Array) or rd["input"].is_empty():
		push_warning("[Registry] register_furniture('%s'): recipe.input must be a non-empty array of ItemData" % id)
		return false
	var script := load("res://Scripts/RecipeData.gd") as GDScript
	if script == null:
		push_warning("[Registry] register_furniture('%s'): failed to load RecipeData.gd; recipe skipped" % id)
		return false
	var recipe: Resource = script.new()
	# rd is mod-supplied, often from JSON where nulls are ordinary; .get()'s
	# default only covers an absent key, so type-check before every coercion.
	var name_raw: Variant = rd.get("name")
	recipe.set("name", name_raw if name_raw is String else id)
	var time_raw: Variant = rd.get("time")
	recipe.set("time", float(time_raw) if (time_raw is int or time_raw is float) else 1.0)
	if rd.has("audio"):
		recipe.set("audio", rd["audio"])
	# Build the typed input array without naming ItemData: referencing the game
	# class would force-compile vanilla ItemData.gd before hook-pack activation.
	var typed_input: Array = []
	var declared_input: Variant = recipe.get("input")
	if declared_input is Array:
		typed_input = declared_input.duplicate()
	for it in rd["input"]:
		if _looks_like_item_data(it) and _typed_array_accepts(typed_input, it):
			typed_input.append(it)
		else:
			push_warning("[Registry] register_furniture('%s'): recipe.input contains non-ItemData entry; skipped" % id)
	if typed_input.is_empty():
		return false
	recipe.set("input", typed_input)
	var typed_output: Array = []
	var declared_output: Variant = recipe.get("output")
	if declared_output is Array:
		typed_output = declared_output.duplicate()
	if not (_looks_like_item_data(output_item) and _typed_array_accepts(typed_output, output_item)):
		push_warning("[Registry] register_furniture('%s'): output ItemData isn't typed as ItemData; recipe skipped" % id)
		return false
	typed_output.append(output_item)
	recipe.set("output", typed_output)
	for flag in ["heat", "workbench", "testbench", "shelter"]:
		if rd.has(flag):
			recipe.set(flag, _json_truthy(rd[flag]))
	return _register_recipe("%s_recipe" % id, {"recipe": recipe, "category": "furniture"})

# The bundle's payload, or {} after a warning; `what` is the call text up to the id.
func _bundle_data(what: String, data: Variant, required: Array) -> Dictionary:
	if not (data is Dictionary):
		push_warning("[Registry] %s, ...) expects Dictionary" % what)
		return {}
	for key in required:
		if not data.has(key):
			push_warning("[Registry] %s): missing required key '%s'" % [what, key])
			return {}
	return data

# d.item_path with d.icon_path applied, or null after a warning; the caller registers it.
func _load_bundle_item(id: String, d: Dictionary, what: String) -> Resource:
	var item: Resource = load(d["item_path"])
	if item == null:
		push_warning("[Registry] %s): failed to load item from '%s'" % [what, d["item_path"]])
		return null
	if d.has("icon_path") and _object_has_property(item, "icon"):
		var icon_path: String = d["icon_path"]
		var img := Image.new()
		if img.load(icon_path) != OK:
			push_warning("[Registry] register: '%s' icon load failed for '%s'" % [id, icon_path])
		elif img.get_size().x == 0 or img.get_size().y == 0:
			push_warning("[Registry] register: '%s' icon loaded but is empty (path resolved but size 0)" % id)
		else:
			item.icon = ImageTexture.create_from_image(img)
	return item

func _load_bundle_scene(what: String, path: Variant) -> Resource:
	var scene: Resource = load(path)
	if scene == null:
		push_warning("[Registry] %s): failed to load scene from '%s'" % [what, path])
	return scene

# Registry.md documents the "<id>_in_<table>" handle.
func _register_bundle_loot(id: String, item: Resource, d: Dictionary) -> int:
	var count := 0
	if d.get("loot_tables") is Array:
		for table_name in d["loot_tables"]:
			if table_name is String and _array_entry_register("loot", "%s_in_%s" % [id, table_name],
					{"item": item, "table": table_name}):
				count += 1
	return count

func _register_bundle_pools(id: String, item: Resource, pools: Array, result: Dictionary) -> void:
	for pool_name in pools:
		if not (pool_name is String):
			continue
		if _register_trader_pool("%s_in_pool_%s" % [id, pool_name], {"item": item, "trader": pool_name}):
			result["trader_pools"].append(pool_name)
			result["trader_pool_count"] += 1
		else:
			result["trader_pools_failed"].append(pool_name)

# One _patch_item for all additions, so a revert restores the whole array.
func _extend_compatible(item_id: String, item: Resource, additions: Array) -> bool:
	var existing: Array = []
	if "compatible" in item and item.get("compatible") is Array:
		existing = item.get("compatible").duplicate()
	for add in additions:
		if not (add in existing):
			existing.append(add)
	return _patch_item(item_id, {"compatible": existing})
