## ----- registry/loot.gd -----
## Loot registrations mutate `items: Array[ItemData]` on loaded LootTable
## Resources; the Resource cache propagates that to any consumer that
## hasn't already copied the array into a local bucket (see registry.gd's
## timing constraint: register during mod _ready()).
##
## Data: {item: ItemData, table: String}; override additionally requires
## `replaces: ItemData`, the existing entry to swap out. `table` is a
## vanilla table name ("LT_Master") or an absolute res:// path.
## remove() strips the exact (table, item) pair tracked per-id; override
## stashes the displaced ItemData so revert can put it back.

# Short table names -> res:// paths; absolute paths pass through as-is.
const _LOOT_TABLE_PATHS := {
	"LT_Master": "res://Loot/LT_Master.tres",
	# Custom tables (event-driven): res://Loot/Custom/
	"LT_Airdrop": "res://Loot/Custom/LT_Airdrop.tres",
	"LT_Patient_Report": "res://Loot/Custom/LT_Patient_Report.tres",
	"LT_Punisher": "res://Loot/Custom/LT_Punisher.tres",
	"LT_Oil_Sample": "res://Loot/Custom/LT_Oil_Sample.tres",
	# Tutorial tables: res://Loot/Tutorial/
	"LT_Weapons_01": "res://Loot/Tutorial/LT_Weapons_01.tres",
	"LT_Weapons_02": "res://Loot/Tutorial/LT_Weapons_02.tres",
	"LT_Weapons_03": "res://Loot/Tutorial/LT_Weapons_03.tres",
	"LT_Weapons_04": "res://Loot/Tutorial/LT_Weapons_04.tres",
	"LT_Ammo": "res://Loot/Tutorial/LT_Ammo.tres",
	"LT_Medical": "res://Loot/Tutorial/LT_Medical.tres",
	"LT_Equipment": "res://Loot/Tutorial/LT_Equipment.tres",
	"LT_Armor": "res://Loot/Tutorial/LT_Armor.tres",
	"LT_Grenades": "res://Loot/Tutorial/LT_Grenades.tres",
	"LT_Attachments": "res://Loot/Tutorial/LT_Attachments.tres",
	"LT_Items": "res://Loot/Tutorial/LT_Items.tres",
	# Kit tables: res://Loot/Kits/
	"Kit_Colt": "res://Loot/Kits/Kit_Colt.tres",
	"Kit_Glock": "res://Loot/Kits/Kit_Glock.tres",
	"Kit_MP5K": "res://Loot/Kits/Kit_MP5K.tres",
	"Kit_Makarov": "res://Loot/Kits/Kit_Makarov.tres",
	"Kit_Mosin": "res://Loot/Kits/Kit_Mosin.tres",
	"Kit_Remington": "res://Loot/Kits/Kit_Remington.tres",
}

# Returns the loaded LootTable Resource or null + warning. Accepts bare
# names and absolute paths (the escape hatch for user-authored tables).
func _resolve_loot_table(table_ref: String) -> Resource:
	if table_ref == "":
		push_warning("[Registry] loot: empty table name")
		return null
	var path := table_ref
	if _LOOT_TABLE_PATHS.has(table_ref):
		path = _LOOT_TABLE_PATHS[table_ref]
	elif not table_ref.begins_with("res://"):
		push_warning("[Registry] loot: unknown table '%s' (not a known vanilla table name and not an absolute res:// path)" % table_ref)
		return null
	var res = load(path)
	if res == null:
		push_warning("[Registry] loot: couldn't load table at '%s'" % path)
		return null
	if not ("items" in res):
		push_warning("[Registry] loot: resource at '%s' has no `items` array (not a LootTable?)" % path)
		return null
	return res

# Validates the {item, table} payload. Returns [item, table_res] or
# [null, null] on error (with a warning already issued).
func _validate_loot_data(id: String, verb: String, data: Variant) -> Array:
	if not (data is Dictionary):
		push_warning("[Registry] %s('loot', '%s', ...) expects Dictionary {item, table}, got %s" % [verb, id, typeof(data)])
		return [null, null]
	var d: Dictionary = data
	if not d.has("item") or not d.has("table"):
		push_warning("[Registry] %s('loot', '%s', ...) data dict missing 'item' or 'table' key" % [verb, id])
		return [null, null]
	var item = d["item"]
	if not (item is Resource) or not _looks_like_item_data(item):
		push_warning("[Registry] %s('loot', '%s'): item is not an ItemData Resource" % [verb, id])
		return [null, null]
	var table = d["table"]
	if not (table is String):
		push_warning("[Registry] %s('loot', '%s'): table must be a String (name or res:// path)" % [verb, id])
		return [null, null]
	var table_res := _resolve_loot_table(table)
	if table_res == null:
		return [null, null]
	return [item, table_res]

func _register_loot(id: String, data: Variant) -> bool:
	var reg: Dictionary = _registry_registered.get("loot", {})
	if reg.has(id):
		push_warning("[Registry] register('loot', '%s'): already registered (ids are mod-chosen handles, pick a unique one)" % id)
		return false
	var parts := _validate_loot_data(id, "register", data)
	var item = parts[0]
	var table_res = parts[1]
	if item == null or table_res == null:
		return false
	if not _typed_array_accepts(table_res.items, item):
		push_warning("[Registry] register('loot', '%s'): item type doesn't match table's typed array (table wants ItemData or subclass; got a Resource with a different script)" % id)
		return false
	# An item already in the table is refused rather than double-inserted;
	# use override to swap an existing entry.
	if item in table_res.items:
		push_warning("[Registry] register('loot', '%s'): item is already present in table; use override to swap an existing entry" % id)
		return false
	table_res.items.append(item)
	reg[id] = {"item": item, "table": data["table"], "table_res": table_res}
	_registry_registered["loot"] = reg
	_log_debug("[Registry] registered loot '%s' (%s -> %s)" % [id, data["table"], item.get("file")])
	return true

# Override swaps an ItemData already present in a table for a new one:
# {item, table, replaces: ItemData}. The displaced entry is restored on
# revert.
func _override_loot(id: String, data: Variant) -> bool:
	var ov: Dictionary = _registry_overridden.get("loot", {})
	if ov.has(id):
		push_warning("[Registry] override('loot', '%s'): already overridden (revert first to re-override)" % id)
		return false
	if not (data is Dictionary) or not data.has("replaces"):
		push_warning("[Registry] override('loot', '%s', ...) requires {item, table, replaces: ItemData}; 'replaces' is the existing entry to swap out" % id)
		return false
	var parts := _validate_loot_data(id, "override", data)
	var new_item = parts[0]
	var table_res = parts[1]
	if new_item == null or table_res == null:
		return false
	var old_item = data["replaces"]
	if not (old_item is Resource) or not _looks_like_item_data(old_item):
		push_warning("[Registry] override('loot', '%s'): 'replaces' is not an ItemData Resource" % id)
		return false
	if not _typed_array_accepts(table_res.items, new_item):
		push_warning("[Registry] override('loot', '%s'): item type doesn't match table's typed array (table wants ItemData or subclass)" % id)
		return false
	var idx: int = table_res.items.find(old_item)
	if idx < 0:
		push_warning("[Registry] override('loot', '%s'): 'replaces' item not present in table" % id)
		return false
	if new_item in table_res.items:
		push_warning("[Registry] override('loot', '%s'): new item is already in the table; would duplicate" % id)
		return false
	table_res.items[idx] = new_item
	ov[id] = {
		"item": new_item,
		"table": data["table"],
		"table_res": table_res,
		"replaced": old_item,
		"index": idx,
	}
	_registry_overridden["loot"] = ov
	# Mirror into the registered map so get_entry() surfaces the override.
	var reg: Dictionary = _registry_registered.get("loot", {})
	(ov[id] as Dictionary)["registered"] = reg.get(id)
	reg[id] = {"item": new_item, "table": data["table"], "table_res": table_res}
	_registry_registered["loot"] = reg
	_log_debug("[Registry] overrode loot '%s' in %s (%s -> %s)" \
			% [id, data["table"], old_item.get("file"), new_item.get("file")])
	return true

func _remove_loot(id: String) -> bool:
	var reg: Dictionary = _registry_registered.get("loot", {})
	if not reg.has(id):
		push_warning("[Registry] remove('loot', '%s'): not a mod loot registration" % id)
		return false
	# Override-backed entries must be reverted, not removed.
	var ov: Dictionary = _registry_overridden.get("loot", {})
	if ov.has(id):
		push_warning("[Registry] remove('loot', '%s'): this id is an override, use revert instead" % id)
		return false
	var entry: Dictionary = reg[id]
	var table_res: Resource = entry["table_res"]
	var item: Resource = entry["item"]
	var idx: int = table_res.items.find(item)
	if idx >= 0:
		table_res.items.remove_at(idx)
	else:
		# Something else stripped it from the table; clear tracking anyway.
		push_warning("[Registry] remove('loot', '%s'): item not found in table; tracking cleared" % id)
	reg.erase(id)
	_registry_registered["loot"] = reg
	_log_debug("[Registry] removed loot '%s'" % id)
	return true

func _revert_loot(id: String) -> bool:
	var ov: Dictionary = _registry_overridden.get("loot", {})
	if not ov.has(id):
		push_warning("[Registry] revert('loot', '%s'): no override to revert" % id)
		return false
	var entry: Dictionary = ov[id]
	var table_res: Resource = entry["table_res"]
	var current_item: Resource = entry["item"]
	var old_item: Resource = entry["replaced"]
	# Re-find the override (the index may have shifted since) and put the
	# original back.
	var idx: int = table_res.items.find(current_item)
	if idx >= 0:
		table_res.items[idx] = old_item
	else:
		# Override entry is gone; append the original rather than nothing.
		push_warning("[Registry] revert('loot', '%s'): override entry missing from table, appending original at end" % id)
		table_res.items.append(old_item)
	ov.erase(id)
	_registry_overridden["loot"] = ov
	_restore_override_handle("loot", id, entry)
	_log_debug("[Registry] reverted loot '%s'" % id)
	return true
