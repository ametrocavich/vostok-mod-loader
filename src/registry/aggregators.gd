## ----- registry/aggregators.gd -----
## Aggregator helpers (item/weapon/magazine/attachment/furniture bundles) that
## fan out to the primitive registries and patch related vanilla state; no
## state of their own. Magazine and attachment share _register_compat_item
## (vanilla's `compatible` accepts both). Id strings resolve via _lookup_item;
## inline magazine bundles register first. All return per-step success bools.

# -------- weapons --------

# Required keys: item_path, scene_path, rig_path. Returns:
# {
#   ok: bool,                  # all sub-registrations succeeded
#   items: bool,               # weapon ItemData registered
#   scene: bool,               # weapon world scene registered
#   rig: bool,                 # weapon rig scene registered
#   magazines: [{id, ok, items?, scene?, loot_count?}],
#   fits_attachments: [String], # ids successfully appended to compatible
#   fits_attachments_failed: [String], # ids that didn't resolve
#   loot_count: int,           # tables successfully populated
# }
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
		# null = AI loadout not requested; bool = requested + outcome.
		"ai_loadout": null,
	}
	if not (data is Dictionary):
		push_warning("[Registry] register('weapons', '%s', ...) expects Dictionary" % id)
		return result
	var d: Dictionary = data
	for required in ["item_path", "scene_path", "rig_path"]:
		if not d.has(required):
			push_warning("[Registry] register('weapons', '%s'): missing required key '%s'" % [id, required])
			return result
	var weapon_item: Resource = load(d["item_path"])
	if weapon_item == null:
		push_warning("[Registry] register('weapons', '%s'): failed to load item from '%s'" % [id, d["item_path"]])
		return result
	if d.has("icon_path"):
		_apply_icon(weapon_item, d["icon_path"], id)
	result["items"] = _register_item(id, weapon_item)
	if not result["items"]:
		# Without the item the rest has nothing to attach `compatible` to.
		return result
	var world_scene: Resource = load(d["scene_path"])
	if world_scene != null:
		result["scene"] = _register_scene(id, world_scene)
	# Rig id convention: "<weapon_id>_Rig".
	var rig_scene: Resource = load(d["rig_path"])
	if rig_scene != null:
		result["rig"] = _register_scene(id + "_Rig", rig_scene)
	# Magazines: a mixed array of inline bundles and id strings.
	var compatible_additions: Array = []
	if d.has("magazines") and d["magazines"] is Array:
		for entry in d["magazines"]:
			var mag_result: Dictionary = _register_weapon_magazine_entry(entry)
			result["magazines"].append(mag_result)
			if mag_result.get("item_data") != null:
				compatible_additions.append(mag_result["item_data"])
	# fits_attachments: failures do not abort; append what resolves.
	if d.has("fits_attachments") and d["fits_attachments"] is Array:
		for att_id in d["fits_attachments"]:
			if not (att_id is String):
				continue
			var att_item: Resource = _lookup_item(att_id)
			if att_item == null:
				result["fits_attachments_failed"].append(att_id)
				push_warning("[Registry] register('weapons', '%s'): fits_attachments id '%s' didn't resolve to any item (typo? not registered yet?)" % [id, att_id])
				continue
			result["fits_attachments"].append(att_id)
			if not (att_item in compatible_additions):
				compatible_additions.append(att_item)
	# Extend the weapon's compatible array in one shot via _patch_item so revert tracking works.
	if not compatible_additions.is_empty():
		var existing: Array = []
		if "compatible" in weapon_item:
			var cur = weapon_item.get("compatible")
			if cur is Array:
				existing = (cur as Array).duplicate()
		for add in compatible_additions:
			if not (add in existing):
				existing.append(add)
		_patch_item(id, {"compatible": existing})
	# Loot tables: one register(LOOT, ...) call each.
	if d.has("loot_tables") and d["loot_tables"] is Array:
		for table_name in d["loot_tables"]:
			if not (table_name is String):
				continue
			var loot_id: String = "%s_in_%s" % [id, table_name]
			if _register_loot(loot_id, {"item": weapon_item, "table": String(table_name)}):
				result["loot_count"] = int(result["loot_count"]) + 1
	# Optional AI loadout using this weapon's scene and id. Failure is reported
	# in result.ai_loadout but does not fail the weapon.
	if d.has("ai_loadout"):
		var al: Variant = d["ai_loadout"]
		if not (al is Dictionary):
			push_warning("[Registry] register('weapons', '%s'): ai_loadout must be a Dictionary, got %s" % [id, typeof(al)])
			result["ai_loadout"] = false
		else:
			# Pin weapon_scene to the loaded resource; avoids a re-load and a scene-id miss.
			var loadout_data: Dictionary = (al as Dictionary).duplicate()
			loadout_data["weapon_scene"] = world_scene
			result["ai_loadout"] = _register_ai_loadout(id, loadout_data)
	# Magazines and ai_loadout don't gate ok; caller can drill in.
	result["ok"] = result["items"] and result["scene"] and result["rig"] \
			and result["fits_attachments_failed"].is_empty()
	_log_debug("[Registry] register_weapon('%s') result: %s" % [id, result])
	return result

# Per-magazine processing inside register_weapon: an inline bundle or an id
# ref. Returns {id, ok, item_data, items?, scene?, loot_count?}.
func _register_weapon_magazine_entry(entry: Variant) -> Dictionary:
	if entry is String:
		var mag: Resource = _lookup_item(entry)
		if mag == null:
			push_warning("[Registry] register_weapon: magazine id '%s' didn't resolve (typo? not registered yet?)" % entry)
			return {"id": entry, "ok": false, "item_data": null}
		return {"id": entry, "ok": true, "item_data": mag}
	if entry is Dictionary:
		var d: Dictionary = entry
		if not d.has("id") or not (d["id"] is String):
			push_warning("[Registry] register_weapon: inline magazine missing 'id' string key")
			return {"id": "", "ok": false, "item_data": null}
		var sub: Dictionary = _register_magazine(d["id"], d)
		# Only resolve item_data when the inline item registered: on an id collision
		# _lookup_item would wire the unrelated colliding item into compatible.
		var sub_item: Resource = null
		if sub.get("items", false):
			sub_item = _lookup_item(d["id"])
		return {
			"id": d["id"],
			"ok": sub["ok"],
			"item_data": sub_item,
			"items": sub.get("items", false),
			"scene": sub.get("scene", false),
			"loot_count": sub.get("loot_count", 0),
		}
	push_warning("[Registry] register_weapon: magazine entry must be a Dictionary or String id, got %s" % typeof(entry))
	return {"id": "", "ok": false, "item_data": null}

# -------- magazines --------

# Standalone magazine. Required: item_path, scene_path; optional icon_path,
# fits_weapons, loot_tables. Returns {ok, items, scene, fits_weapons, fits_weapons_failed, loot_count}.
func _register_magazine(id: String, data: Variant) -> Dictionary:
	return _register_compat_item(id, data, "magazines")

# -------- attachments --------

# Same shape as magazine.
func _register_attachment(id: String, data: Variant) -> Dictionary:
	return _register_compat_item(id, data, "attachments")

# Shared body for magazines and attachments: item, scene, optional loot, then patch `compatible` on each fits_weapons target.
func _register_compat_item(id: String, data: Variant, label: String) -> Dictionary:
	var result: Dictionary = {
		"ok": false,
		"items": false,
		"scene": false,
		"fits_weapons": [],
		"fits_weapons_failed": [],
		"loot_count": 0,
	}
	if not (data is Dictionary):
		push_warning("[Registry] register('%s', '%s', ...) expects Dictionary" % [label, id])
		return result
	var d: Dictionary = data
	for required in ["item_path", "scene_path"]:
		if not d.has(required):
			push_warning("[Registry] register('%s', '%s'): missing required key '%s'" % [label, id, required])
			return result
	var item_data: Resource = load(d["item_path"])
	if item_data == null:
		push_warning("[Registry] register('%s', '%s'): failed to load item from '%s'" % [label, id, d["item_path"]])
		return result
	if d.has("icon_path"):
		_apply_icon(item_data, d["icon_path"], id)
	result["items"] = _register_item(id, item_data)
	if not result["items"]:
		return result
	var scene: Resource = load(d["scene_path"])
	if scene != null:
		result["scene"] = _register_scene(id, scene)
	if d.has("fits_weapons") and d["fits_weapons"] is Array:
		for weapon_id in d["fits_weapons"]:
			if not (weapon_id is String):
				continue
			var weapon_item: Resource = _lookup_item(weapon_id)
			if weapon_item == null:
				result["fits_weapons_failed"].append(weapon_id)
				push_warning("[Registry] register('%s', '%s'): fits_weapons id '%s' didn't resolve" % [label, id, weapon_id])
				continue
			var existing: Array = []
			if "compatible" in weapon_item:
				var cur = weapon_item.get("compatible")
				if cur is Array:
					existing = (cur as Array).duplicate()
			if not (item_data in existing):
				existing.append(item_data)
			if _patch_item(weapon_id, {"compatible": existing}):
				result["fits_weapons"].append(weapon_id)
			else:
				result["fits_weapons_failed"].append(weapon_id)
	if d.has("loot_tables") and d["loot_tables"] is Array:
		for table_name in d["loot_tables"]:
			if not (table_name is String):
				continue
			var loot_id: String = "%s_in_%s" % [id, table_name]
			if _register_loot(loot_id, {"item": item_data, "table": String(table_name)}):
				result["loot_count"] = int(result["loot_count"]) + 1
	result["ok"] = result["items"] and result["scene"] and result["fits_weapons_failed"].is_empty()
	_log_debug("[Registry] register_%s('%s') result: %s" % [label.trim_suffix("s"), id, result])
	return result

# -------- generic items --------

# Generic item bundle (consumables, keys, tools, ammo, ...). Schema:
#   item_path      required, res:// to the .tres ItemData
#   scene_path     optional world .tscn (`scene` is true when omitted)
#   icon_path      optional, assigned to item.icon
#   loot_tables    optional table names, one register('loot', ...) each
#   trader_pools   optional trader names; flips the ItemData flag
# Returns {ok, items, scene, loot_count, trader_pool_count, trader_pools, trader_pools_failed}.
func _register_item_bundle(id: String, data: Variant) -> Dictionary:
	var result: Dictionary = {
		"ok": false,
		"items": false,
		"scene": true,  # default true so missing scene_path doesn't fail ok
		"loot_count": 0,
		"trader_pool_count": 0,
		"trader_pools": [],
		"trader_pools_failed": [],
	}
	if not (data is Dictionary):
		push_warning("[Registry] register_item('%s', ...) expects Dictionary" % id)
		return result
	var d: Dictionary = data
	if not d.has("item_path"):
		push_warning("[Registry] register_item('%s'): missing required key 'item_path'" % id)
		return result
	var item_data: Resource = load(d["item_path"])
	if item_data == null:
		push_warning("[Registry] register_item('%s'): failed to load item from '%s'" % [id, d["item_path"]])
		return result
	if d.has("icon_path"):
		_apply_icon(item_data, d["icon_path"], id)
	result["items"] = _register_item(id, item_data)
	if not result["items"]:
		return result
	if d.has("scene_path"):
		var scene: Resource = load(d["scene_path"])
		if scene != null:
			result["scene"] = _register_scene(id, scene)
		else:
			result["scene"] = false
			push_warning("[Registry] register_item('%s'): failed to load scene from '%s'" % [id, d["scene_path"]])
	if d.has("loot_tables") and d["loot_tables"] is Array:
		for table_name in d["loot_tables"]:
			if not (table_name is String):
				continue
			var loot_id: String = "%s_in_%s" % [id, table_name]
			if _register_loot(loot_id, {"item": item_data, "table": String(table_name)}):
				result["loot_count"] = int(result["loot_count"]) + 1
	# Trader pools: one register per name; failures tracked per pool.
	if d.has("trader_pools") and d["trader_pools"] is Array:
		for pool_name in d["trader_pools"]:
			if not (pool_name is String):
				continue
			var pool_id: String = "%s_in_pool_%s" % [id, pool_name]
			if _register_trader_pool(pool_id, {"item": item_data, "trader": String(pool_name)}):
				result["trader_pools"].append(String(pool_name))
				result["trader_pool_count"] = int(result["trader_pool_count"]) + 1
			else:
				result["trader_pools_failed"].append(String(pool_name))
	result["ok"] = result["items"] and result["scene"] and result["trader_pools_failed"].is_empty()
	_log_debug("[Registry] register_item('%s') result: %s" % [id, result])
	return result

# -------- furniture --------

# Furniture: ItemData with type="Furniture" plus a placed world scene. Never
# spawns from loot pools; bought from traders, where vanilla routes it to the
# catalog grid by itemData.type. So: scene_path required, loot_tables
# forbidden, trader_pools defaults to ["Generalist"] with a warning, optional
# inline recipe filed under Recipes.furniture.
# Schema: item_path, scene_path (both required), icon_path?, trader_pools?,
#   recipe? {input: Array[ItemData], time: float, audio?: AudioEvent}.
# Returns {ok, items, scene, trader_pool_count, trader_pools, trader_pools_failed, recipe}.
func _register_furniture_bundle(id: String, data: Variant) -> Dictionary:
	var result: Dictionary = {
		"ok": false,
		"items": false,
		"scene": false,
		"trader_pool_count": 0,
		"trader_pools": [],
		"trader_pools_failed": [],
		# null = recipe not requested; bool = requested + outcome.
		"recipe": null,
	}
	if not (data is Dictionary):
		push_warning("[Registry] register_furniture('%s', ...) expects Dictionary" % id)
		return result
	var d: Dictionary = data
	for required in ["item_path", "scene_path"]:
		if not d.has(required):
			push_warning("[Registry] register_furniture('%s'): missing required key '%s'" % [id, required])
			return result
	if d.has("loot_tables"):
		push_warning("[Registry] register_furniture('%s'): loot_tables is not supported (furniture isn't loot-pool spawnable in vanilla; use trader_pools instead). Ignored." % id)
	# Wrong ItemData.type warns but does not fail; the item just misses the catalog.
	var item_data: Resource = load(d["item_path"])
	if item_data == null:
		push_warning("[Registry] register_furniture('%s'): failed to load item from '%s'" % [id, d["item_path"]])
		return result
	if "type" in item_data and str(item_data.get("type")) != "Furniture":
		push_warning("[Registry] register_furniture('%s'): ItemData.type is '%s', expected 'Furniture'. Item won't be routed to the catalog grid on purchase. Fix the .tres or the player will get inventory items instead." % [id, item_data.get("type")])
	if d.has("icon_path"):
		_apply_icon(item_data, d["icon_path"], id)
	result["items"] = _register_item(id, item_data)
	if not result["items"]:
		return result
	var scene: Resource = load(d["scene_path"])
	if scene == null:
		push_warning("[Registry] register_furniture('%s'): failed to load scene from '%s'" % [id, d["scene_path"]])
	else:
		result["scene"] = _register_scene(id, scene)
	# Default to ["Generalist"] with a warning so unobtainable furniture surfaces now.
	var pools: Array = []
	if d.has("trader_pools") and d["trader_pools"] is Array and not (d["trader_pools"] as Array).is_empty():
		pools = d["trader_pools"]
	else:
		pools = ["Generalist"]
		push_warning("[Registry] register_furniture('%s'): no trader_pools specified -- defaulting to ['Generalist']. Furniture is only obtainable via traders, so omitting this would make the item unreachable." % id)
	for pool_name in pools:
		if not (pool_name is String):
			continue
		var pool_id: String = "%s_in_pool_%s" % [id, pool_name]
		if _register_trader_pool(pool_id, {"item": item_data, "trader": String(pool_name)}):
			result["trader_pools"].append(String(pool_name))
			result["trader_pool_count"] = int(result["trader_pool_count"]) + 1
		else:
			result["trader_pools_failed"].append(String(pool_name))
	if d.has("recipe"):
		# Every requested-but-failed path sets result["recipe"] = false (null-vs-bool contract).
		if not (d["recipe"] is Dictionary):
			push_warning("[Registry] register_furniture('%s'): recipe must be a Dictionary, got %s" % [id, typeof(d["recipe"])])
			result["recipe"] = false
		else:
			var rd: Dictionary = d["recipe"]
			if not (rd.has("input") and rd["input"] is Array) or (rd["input"] as Array).is_empty():
				push_warning("[Registry] register_furniture('%s'): recipe.input must be a non-empty array of ItemData" % id)
				result["recipe"] = false
			else:
				var recipe := _build_furniture_recipe(id, item_data, rd)
				if recipe != null:
					var recipe_id: String = "%s_recipe" % id
					result["recipe"] = _register_recipe(recipe_id, {"recipe": recipe, "category": "furniture"})
				else:
					result["recipe"] = false
	result["ok"] = result["items"] and result["scene"] and result["trader_pools_failed"].is_empty()
	_log_debug("[Registry] register_furniture('%s') result: %s" % [id, result])
	return result

# A fresh RecipeData from the recipe dict; output is implicit. null if coercion fails.
func _build_furniture_recipe(id: String, output_item: Resource, rd: Dictionary) -> Resource:
	var script: GDScript = load("res://Scripts/RecipeData.gd") as GDScript
	if script == null:
		push_warning("[Registry] register_furniture('%s'): failed to load RecipeData.gd; recipe skipped" % id)
		return null
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
	var declared_input = recipe.get("input")
	if declared_input is Array:
		typed_input = (declared_input as Array).duplicate()
	for it in rd["input"]:
		if it is Resource and _looks_like_item_data(it) and _typed_array_accepts(typed_input, it):
			typed_input.append(it)
		else:
			push_warning("[Registry] register_furniture('%s'): recipe.input contains non-ItemData entry; skipped" % id)
	if typed_input.is_empty():
		return null
	recipe.set("input", typed_input)
	var typed_output: Array = []
	var declared_output = recipe.get("output")
	if declared_output is Array:
		typed_output = (declared_output as Array).duplicate()
	if output_item is Resource and _looks_like_item_data(output_item) and _typed_array_accepts(typed_output, output_item):
		typed_output.append(output_item)
	else:
		push_warning("[Registry] register_furniture('%s'): output ItemData isn't typed as ItemData; recipe skipped" % id)
		return null
	recipe.set("output", typed_output)
	for flag in ["heat", "workbench", "testbench", "shelter"]:
		if rd.has(flag):
			recipe.set(flag, _json_truthy(rd[flag]))
	return recipe

# -------- shared helpers --------

# Load an icon into item_data.icon if the field exists; best-effort.
func _apply_icon(item_data: Resource, icon_path: String, owner_id: String) -> void:
	if not _object_has_property(item_data, "icon"):
		return
	var img := Image.new()
	if img.load(icon_path) != OK:
		push_warning("[Registry] register: '%s' icon load failed for '%s'" % [owner_id, icon_path])
		return
	if img.get_size().x == 0 or img.get_size().y == 0:
		push_warning("[Registry] register: '%s' icon loaded but is empty (path resolved but size 0)" % owner_id)
		return
	item_data.icon = ImageTexture.create_from_image(img)
