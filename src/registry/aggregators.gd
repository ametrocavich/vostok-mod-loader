## ----- registry/aggregators.gd -----
##
## Pure-aggregator helpers that fan out to primitive registries (ITEMS,
## SCENES, LOOT, TRADER_POOLS) and patch related vanilla state. No new
## state -- mods can drop down to primitives any time. The helpers exist
## to compress the typical 5-10 calls a content mod ends up making into
## a single declarative dict.
##
## Helpers:
##   - register_item(id, dict)       -- generic item with optional scene/icon/loot/trader_pools
##   - register_weapon(id, dict)     -- weapon + rig + inline magazines + fits_attachments
##   - register_magazine(id, dict)   -- standalone mag with fits_weapons
##   - register_attachment(id, dict) -- standalone attachment with fits_weapons
##
## Three of these (weapon/magazine/attachment) also have Registry consts
## (WEAPONS / MAGAZINES / ATTACHMENTS) for symmetry with primitive
## registries. register_item is method-only -- the bare-Resource form of
## register('items', ...) already exists, so the bundle helper has a
## different name to avoid arg-shape polymorphism.
##
## Magazine and attachment share an implementation (_register_compat_item)
## because the vanilla `compatible` field on weapon ItemData accepts both
## interchangeably. The API split is for mod-author readability.
##
## Cross-relationship resolution: `magazines`, `fits_attachments`,
## `fits_weapons` accept id strings. Lookup goes through _lookup_item,
## which sees both mod-registered and vanilla items. Inline magazine
## bundles (Dictionary instead of String) get registered first, then
## their ItemData ref is appended to the parent weapon's compatible.
##
## All helpers return a Dictionary with granular per-step success bools
## so mod authors can debug partial failures without parsing logs.

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
	}
	if not (data is Dictionary):
		push_warning("[Registry] register('weapons', '%s', ...) expects Dictionary" % id)
		return result
	var d: Dictionary = data
	for required in ["item_path", "scene_path", "rig_path"]:
		if not d.has(required):
			push_warning("[Registry] register('weapons', '%s'): missing required key '%s'" % [id, required])
			return result
	# Step 1: load + register the weapon ItemData.
	var weapon_item: Resource = load(d["item_path"])
	if weapon_item == null:
		push_warning("[Registry] register('weapons', '%s'): failed to load item from '%s'" % [id, d["item_path"]])
		return result
	# Optional icon load + assign before registering.
	if d.has("icon_path"):
		_apply_icon(weapon_item, d["icon_path"], id)
	result["items"] = _register_item(id, weapon_item)
	if not result["items"]:
		# Item registration is the foundation; if it failed, abort -- the
		# rest of the fan-out has nothing to attach `compatible` to.
		return result
	# Step 2: world scene.
	var world_scene: Resource = load(d["scene_path"])
	if world_scene != null:
		result["scene"] = _register_scene(id, world_scene)
	# Step 3: rig scene. Rig id convention: "<weapon_id>_Rig".
	var rig_scene: Resource = load(d["rig_path"])
	if rig_scene != null:
		result["rig"] = _register_scene(id + "_Rig", rig_scene)
	# Step 4: magazines. Mixed array of inline bundles + id strings.
	# Track ItemData refs to append to compatible later.
	var compatible_additions: Array = []
	if d.has("magazines") and d["magazines"] is Array:
		for entry in d["magazines"]:
			var mag_result: Dictionary = _register_weapon_magazine_entry(entry)
			result["magazines"].append(mag_result)
			if mag_result.get("item_data") != null:
				compatible_additions.append(mag_result["item_data"])
	# Step 5: fits_attachments -- id-only refs. Resolve through _lookup_item
	# (covers vanilla + mod items). Failures don't abort; append what we can.
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
	# Step 6: patch the weapon's compatible array in one shot. Read current,
	# extend with additions, write back via _patch_item so revert tracking
	# still works.
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
	# Step 7: loot tables. Each entry becomes one register(LOOT, ...) call.
	if d.has("loot_tables") and d["loot_tables"] is Array:
		for table_name in d["loot_tables"]:
			if not (table_name is String):
				continue
			var loot_id: String = "%s_in_%s" % [id, table_name]
			if _register_loot(loot_id, {"item": weapon_item, "table": String(table_name)}):
				result["loot_count"] = int(result["loot_count"]) + 1
	# Final ok: items+scene+rig succeeded, no fits failures (magazines
	# tracked separately -- caller can drill in).
	result["ok"] = result["items"] and result["scene"] and result["rig"] \
			and result["fits_attachments_failed"].is_empty()
	_log_debug("[Registry] register_weapon('%s') result: %s" % [id, result])
	return result

# Per-magazine processing inside register_weapon. Accepts either a
# Dictionary (inline bundle) or a String (id ref). Returns:
#   {id, ok, item_data, items?, scene?, loot_count?}
# `item_data` is the ItemData ref to append to the weapon's compatible.
# It's null on resolution failure.
func _register_weapon_magazine_entry(entry: Variant) -> Dictionary:
	if entry is String:
		# id ref to existing mod or vanilla item. Resolve, return ref-only.
		var mag: Resource = _lookup_item(entry)
		if mag == null:
			push_warning("[Registry] register_weapon: magazine id '%s' didn't resolve (typo? not registered yet?)" % entry)
			return {"id": entry, "ok": false, "item_data": null}
		return {"id": entry, "ok": true, "item_data": mag}
	if entry is Dictionary:
		# Inline bundle. Register as a fresh magazine.
		var d: Dictionary = entry
		if not d.has("id") or not (d["id"] is String):
			push_warning("[Registry] register_weapon: inline magazine missing 'id' string key")
			return {"id": "", "ok": false, "item_data": null}
		var sub: Dictionary = _register_magazine(d["id"], d)
		var sub_item: Resource = _lookup_item(d["id"])
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

# Standalone magazine. Required: item_path, scene_path. Optional:
# icon_path, fits_weapons (id list), loot_tables. Returns:
# {ok, items, scene, fits_weapons: [String], fits_weapons_failed: [String],
#  loot_count}
func _register_magazine(id: String, data: Variant) -> Dictionary:
	return _register_compat_item(id, data, "magazines")

# -------- attachments --------

# Same shape as magazine. The split exists for mod-author readability;
# vanilla's `compatible` field doesn't distinguish.
func _register_attachment(id: String, data: Variant) -> Dictionary:
	return _register_compat_item(id, data, "attachments")

# Shared implementation for magazines + attachments. Both register an item
# + scene + optional loot, then patch `compatible` on each weapon listed
# in fits_weapons.
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
	# fits_weapons: patch each target weapon's `compatible` to include this item.
	if d.has("fits_weapons") and d["fits_weapons"] is Array:
		for weapon_id in d["fits_weapons"]:
			if not (weapon_id is String):
				continue
			var weapon_item: Resource = _lookup_item(weapon_id)
			if weapon_item == null:
				result["fits_weapons_failed"].append(weapon_id)
				push_warning("[Registry] register('%s', '%s'): fits_weapons id '%s' didn't resolve" % [label, id, weapon_id])
				continue
			# Read current compatible, append, write back.
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
	# Loot tables.
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

# Single-item bundle for content that doesn't fit the weapon/mag/attachment
# split (consumables, keys, tools, ammo, etc). Schema:
#   item_path     -- required, res:// to the .tres ItemData
#   scene_path    -- optional, res:// to the world .tscn (skip for items
#                    that only ever exist as inventory entries / refs)
#   icon_path     -- optional, image path; loaded + assigned to item.icon
#   loot_tables   -- optional, list of table names to add the item to
#                    (one register('loot', ...) per name)
#   trader_pools  -- optional, list of trader names ("Generalist",
#                    "Doctor", "Gunsmith", "Grandma") to flip the
#                    matching ItemData boolean flag for trader supply
#
# Returns:
#   {ok, items, scene, loot_count, trader_pool_count,
#    trader_pools: [String], trader_pools_failed: [String]}
# `scene` is true when no scene_path was provided (vacuously satisfied).
# `result.ok` requires items+scene success and no trader_pool failures.
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
	# Step 1: load + register the ItemData.
	var item_data: Resource = load(d["item_path"])
	if item_data == null:
		push_warning("[Registry] register_item('%s'): failed to load item from '%s'" % [id, d["item_path"]])
		return result
	if d.has("icon_path"):
		_apply_icon(item_data, d["icon_path"], id)
	result["items"] = _register_item(id, item_data)
	if not result["items"]:
		return result
	# Step 2: world scene (optional). Only override the default-true `scene`
	# when a path was provided -- no path means "intentionally skipped."
	if d.has("scene_path"):
		var scene: Resource = load(d["scene_path"])
		if scene != null:
			result["scene"] = _register_scene(id, scene)
		else:
			result["scene"] = false
			push_warning("[Registry] register_item('%s'): failed to load scene from '%s'" % [id, d["scene_path"]])
	# Step 3: loot tables (optional).
	if d.has("loot_tables") and d["loot_tables"] is Array:
		for table_name in d["loot_tables"]:
			if not (table_name is String):
				continue
			var loot_id: String = "%s_in_%s" % [id, table_name]
			if _register_loot(loot_id, {"item": item_data, "table": String(table_name)}):
				result["loot_count"] = int(result["loot_count"]) + 1
	# Step 4: trader pools (optional). Each name fans to one
	# register('trader_pools', ...) call. Failures (unknown trader name,
	# missing flag field on ItemData) get tracked per-pool.
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

# -------- shared helpers --------

# Load an icon image, convert to ImageTexture, assign to item_data.icon if
# the field exists. Best-effort: failures warn but don't abort the parent
# registration -- icons are cosmetic.
func _apply_icon(item_data: Resource, icon_path: String, owner_id: String) -> void:
	if not _resource_has_property(item_data, "icon"):
		return
	var img := Image.new()
	if img.load(icon_path) != OK:
		push_warning("[Registry] register: '%s' icon load failed for '%s'" % [owner_id, icon_path])
		return
	if img.get_size().x == 0 or img.get_size().y == 0:
		push_warning("[Registry] register: '%s' icon loaded but is empty (path resolved but size 0)" % owner_id)
		return
	item_data.icon = ImageTexture.create_from_image(img)
