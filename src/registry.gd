## ----- registry.gd -----
## Public registry API for mods to add/override/edit vanilla game content.
##
## Usage:
##   lib.register(lib.Registry.SCENES, "my_item", preload("res://mymod/item.tscn"))
##   lib.override(lib.Registry.SCENES, "Potato", preload("res://mymod/better_potato.tscn"))
##   lib.remove(lib.Registry.SCENES, "my_item")
##   lib.revert(lib.Registry.SCENES, "Potato")
##
## This file owns:
##   - the Registry const (canonical registry names)
##   - rollback tracking dicts shared across sections
##   - the five public verb dispatchers + get_entry() read API
##
## Per-registry handlers live in src/registry/*.gd. Adding a new registry is:
##   1. Add a Registry.FOO constant below
##   2. Add a match-arm per verb in this file
##   3. Create src/registry/foo.gd with _register_foo / _override_foo etc.
##   4. List the new file in build.sh's FILES array
## No other file changes.
##
## Timing constraint: Trader / LootContainer / LootSimulation fill local
## buckets from LootTables in their `_ready()` and never re-read. Mod authors
## MUST register loot during their own mod `_ready()`; earlier in the
## autoload order; or their entries won't propagate to world loot and
## traders. Runtime re-registration after scene load is invisible.

# Registry name constants. Mods use lib.Registry.SCENES etc. instead of raw
# strings so typos surface at parse time.
const Registry := {
	SCENES = "scenes",
	ITEMS = "items",
	LOOT = "loot",
	SOUNDS = "sounds",
	RECIPES = "recipes",
	EVENTS = "events",
	TRADER_POOLS = "trader_pools",
	TRADER_TASKS = "trader_tasks",
	INPUTS = "inputs",
	SCENE_PATHS = "scene_paths",
	SHELTERS = "shelters",
	MAPS = "maps",
	RANDOM_SCENES = "random_scenes",
	AI_TYPES = "ai_types",
	FISH_SPECIES = "fish_species",
	RESOURCES = "resources",
	SCENE_NODES = "scene_nodes",
	WEAPONS = "weapons",
	MAGAZINES = "magazines",
	ATTACHMENTS = "attachments",
	# Future sections populate the rest:
	# TRADER_POOLS = "trader_pools",
	# TRADER_TASKS = "trader_tasks",
	# INPUTS = "inputs",
	# SHELTERS = "shelters",
	# SCENE_PATHS = "scene_paths",
	# AI_TYPES = "ai_types",
	# FISH_SPECIES = "fish_species",
	# TRACKS = "tracks",
	# RESOURCES = "resources",
}

# Rollback tracking. Populated by register/override/patch, consumed by
# remove/revert. Structure: reg -> {id -> {...per-verb data}}.
#   _registry_registered: reg -> {id -> data}         (newly created entries)
#   _registry_overridden: reg -> {id -> original}     (full-entry replacements)
#   _registry_patched:    reg -> {id -> {field -> original_value}}
# Per-field patch tracking stores the value as it was BEFORE the first patch
# to that field; subsequent patches to the same field don't overwrite the
# stash, so revert restores true original state.
var _registry_registered: Dictionary = {}
var _registry_overridden: Dictionary = {}
var _registry_patched: Dictionary = {}

# ---- Aggregator helpers (weapons / magazines / attachments) ----
# These wrap several primitive registries (ITEMS + SCENES + LOOT +
# TRADER_POOLS, plus patches to vanilla weapons' `compatible`) into a
# single call. Return a Dictionary with per-step success bools so mods
# can inspect partial failures. The weapon/magazine/attachment standard
# verbs collapse the dict to a single bool; call the public methods
# below directly when you want the granular result. register_item is
# method-only (no Registry const) since the bare-Resource form of
# register('items', ...) already exists.

## Register a generic item bundle (ItemData + optional scene/icon/loot/
## trader_pools). Use this for content that doesn't fit the
## weapon/mag/attachment helpers (consumables, keys, tools, ammo).
## See registry/aggregators.gd for the full schema.
func register_item(id: String, data: Variant) -> Dictionary:
	return _register_item_bundle(id, data)

## Register a furniture bundle (ItemData with type='Furniture' + placed
## scene + trader_pools, optional crafting recipe). Furniture is
## intentionally not loot-pool spawnable; trader_pools defaults to
## ['Generalist'] with a warn if missing. See registry/aggregators.gd.
func register_furniture(id: String, data: Variant) -> Dictionary:
	return _register_furniture_bundle(id, data)

## Register a weapon bundle (item + scene + rig, optional magazines /
## fits_attachments / loot_tables). See registry/aggregators.gd for the
## full schema. Returns a Dictionary; check result.ok for overall success.
func register_weapon(id: String, data: Variant) -> Dictionary:
	return _register_weapon(id, data)

## Register a magazine bundle (item + scene, optional fits_weapons /
## loot_tables). Patches each fits_weapons target's compatible array.
func register_magazine(id: String, data: Variant) -> Dictionary:
	return _register_magazine(id, data)

## Register an attachment bundle. Same shape as register_magazine; the
## split is for mod-author readability (vanilla's `compatible` field
## doesn't distinguish mag from attachment).
func register_attachment(id: String, data: Variant) -> Dictionary:
	return _register_attachment(id, data)

# ---- Public verbs ----

## Register a NEW entry. Fails if the id already exists (in vanilla or prior
## mod registrations). Returns true on success.
func register(registry: String, id: String, data: Variant) -> bool:
	if id == "":
		push_warning("[Registry] register(%s, ...) called with empty id" % registry)
		return false
	match registry:
		"scenes": return _register_scene(id, data)
		"items": return _register_item(id, data)
		"loot": return _register_loot(id, data)
		"sounds": return _register_sound(id, data)
		"recipes": return _register_recipe(id, data)
		"events": return _register_event(id, data)
		"trader_pools": return _register_trader_pool(id, data)
		"trader_tasks": return _register_trader_task(id, data)
		"inputs": return _register_input(id, data)
		"scene_paths": return _register_scene_path(id, data)
		"shelters": return _register_shelter(id, data)
		"maps": return _register_map(id, data)
		"random_scenes": return _register_random_scene(id, data)
		"ai_types": return _register_ai_type(id, data)
		"fish_species": return _register_fish_species(id, data)
		"resources":
			push_warning("[Registry] register: 'resources' doesn't support register (the target .tres already exists in vanilla; use patch to mutate its fields)")
			return false
		"scene_nodes":
			push_warning("[Registry] register: 'scene_nodes' doesn't support register (nodes are positional inside a scene; use override('scenes', ...) to replace the whole scene or patch('scene_nodes', ...) to mutate node properties)")
			return false
		"weapons":
			# Aggregator helper returns a granular Dictionary. register()
			# collapses to the bool "did everything succeed" view; mods that
			# want per-step success should call lib.register_weapon(id, data)
			# directly to get the full dict.
			return bool(_register_weapon(id, data).get("ok", false))
		"magazines":
			return bool(_register_magazine(id, data).get("ok", false))
		"attachments":
			return bool(_register_attachment(id, data).get("ok", false))
		_:
			push_warning("[Registry] register: unknown registry '%s'" % registry)
			return false

## Replace an existing entry. Preserves the original so revert() can restore.
## Fails if the id doesn't currently resolve.
func override(registry: String, id: String, data: Variant) -> bool:
	if id == "":
		push_warning("[Registry] override(%s, ...) called with empty id" % registry)
		return false
	match registry:
		"scenes": return _override_scene(id, data)
		"items": return _override_item(id, data)
		"loot": return _override_loot(id, data)
		"sounds": return _override_sound(id, data)
		"recipes": return _override_recipe(id, data)
		"events": return _override_event(id, data)
		"trader_pools":
			push_warning("[Registry] override: 'trader_pools' doesn't support override (pool entries are boolean flags on ItemData; just register/remove)")
			return false
		"trader_tasks": return _override_trader_task(id, data)
		"inputs": return _override_input(id, data)
		"scene_paths": return _override_scene_path(id, data)
		"shelters":
			push_warning("[Registry] override: 'shelters' doesn't support override (it's an append-only list; use register/remove)")
			return false
		"maps":
			push_warning("[Registry] override: 'maps' doesn't support override (append-only; use register/remove, or override('scenes', ...) to swap the underlying scene)")
			return false
		"random_scenes":
			push_warning("[Registry] override: 'random_scenes' doesn't support override (append-only list; use register/remove)")
			return false
		"ai_types": return _override_ai_type(id, data)
		"fish_species":
			push_warning("[Registry] override: 'fish_species' doesn't support override (append-only list; use register/remove)")
			return false
		"resources":
			push_warning("[Registry] override: 'resources' doesn't support override (vanilla .tres already exists; use patch to mutate fields)")
			return false
		"scene_nodes":
			push_warning("[Registry] override: 'scene_nodes' doesn't support override (whole-scene swap goes through override('scenes', ...); scene_nodes is patch-only)")
			return false
		"weapons", "magazines", "attachments":
			push_warning("[Registry] override: '%s' is a pure aggregator -- override the underlying primitives instead (override('items', ...) for the ItemData, override('scenes', ...) for the world/rig scene)" % registry)
			return false
		_:
			push_warning("[Registry] override: unknown registry '%s'" % registry)
			return false

## Partial update: merge `fields` into the entry at `id`. Not every registry
## supports patch; scenes are monolithic PackedScenes, loot entries are
## bare ItemData references (patch via the items registry instead). Returns
## false with guidance on unsupported registries.
##
## `id` is String for most registries. The 'recipes' and 'events' registries
## also accept a direct Resource ref (RecipeData / EventData) so mods can
## patch vanilla entries without first registering a handle; same
## semantics, just skips the indirection when the mod already holds the ref.
func patch(registry: String, id: Variant, fields: Dictionary) -> bool:
	if id is String and id == "":
		push_warning("[Registry] patch(%s, ...) called with empty id" % registry)
		return false
	match registry:
		"scenes":
			push_warning("[Registry] patch: 'scenes' registry doesn't support patch (scenes are monolithic PackedScenes; use override instead)")
			return false
		"items":
			if not (id is String):
				push_warning("[Registry] patch('items', ...): id must be a String")
				return false
			return _patch_item(id, fields)
		"loot":
			push_warning("[Registry] patch: 'loot' registry doesn't support patch (loot entries are ItemData references; patch the ItemData via the 'items' registry instead)")
			return false
		"sounds":
			if not (id is String):
				push_warning("[Registry] patch('sounds', ...): id must be a String")
				return false
			return _patch_sound(id, fields)
		"recipes": return _patch_recipe(id, fields)
		"events": return _patch_event(id, fields)
		"trader_pools":
			push_warning("[Registry] patch: 'trader_pools' doesn't support patch (entries are boolean flags; use register/remove)")
			return false
		"trader_tasks": return _patch_trader_task(id, fields)
		"inputs":
			if not (id is String):
				push_warning("[Registry] patch('inputs', ...): id must be a String")
				return false
			return _patch_input(id, fields)
		"scene_paths":
			if not (id is String):
				push_warning("[Registry] patch('scene_paths', ...): id must be a String")
				return false
			return _patch_scene_path(id, fields)
		"shelters":
			push_warning("[Registry] patch: 'shelters' doesn't support patch (use remove + register to change fields, or patch('scene_paths', ...) for path-only edits)")
			return false
		"maps":
			push_warning("[Registry] patch: 'maps' doesn't support patch (use remove + register to change fields, or patch('scene_paths', ...) for path-only edits)")
			return false
		"random_scenes":
			push_warning("[Registry] patch: 'random_scenes' doesn't support patch (entries are bare paths)")
			return false
		"ai_types":
			push_warning("[Registry] patch: 'ai_types' doesn't support patch (entries are {scene, zone} refs; use override to swap the scene)")
			return false
		"fish_species":
			push_warning("[Registry] patch: 'fish_species' doesn't support patch (entries are {scene, pool_id} refs)")
			return false
		"resources":
			if not (id is String):
				push_warning("[Registry] patch('resources', ...): id must be a res:// path String")
				return false
			return _patch_resource(id, fields)
		"scene_nodes":
			if not (id is String):
				push_warning("[Registry] patch('scene_nodes', ...): id must be a String in the form '<scene_path>#<node_path>'")
				return false
			return _patch_scene_node(id, fields)
		"weapons", "magazines", "attachments":
			push_warning("[Registry] patch: '%s' is a pure aggregator -- patch the underlying primitive instead (patch('items', ...) for ItemData fields like compatible/damage/etc)" % registry)
			return false
		_:
			push_warning("[Registry] patch: unknown registry '%s'" % registry)
			return false

## Append values to an Array field on a registry entry. Array-only.
## De-duplicates by default (matches typical mod intent for compatibility lists);
## pass allow_duplicates=true to permit repeats. `values` accepts a single value
## or an Array. First-write-wins stash is shared with patch(), so revert()
## restores the true pre-any-mutation array even after multiple ops.
func append(registry: String, id: Variant, field: String, values: Variant, allow_duplicates: bool = false) -> bool:
	return _array_op_dispatch(registry, id, field, "append", values, allow_duplicates)


## Prepend values to an Array field. Same de-dup semantics as append; the
## resulting prefix order matches the input order (prepend([a, b]) on [c]
## yields [a, b, c]).
func prepend(registry: String, id: Variant, field: String, values: Variant, allow_duplicates: bool = false) -> bool:
	return _array_op_dispatch(registry, id, field, "prepend", values, allow_duplicates)


## Remove values from an Array field. Removes ALL matching occurrences.
## Silent skip if a value isn't present (idempotent).
func remove_from(registry: String, id: Variant, field: String, values: Variant) -> bool:
	return _array_op_dispatch(registry, id, field, "remove_from", values, false)


# Shared dispatcher for append/prepend/remove_from. Mirrors patch()'s
# registry-by-registry routing exactly: registries that support patch on
# Resource fields get a per-registry helper here; registries with non-Resource
# entries (scenes, loot, shelters, etc.) get a warn-and-return-false branch.
func _array_op_dispatch(registry: String, id: Variant, field: String, op: String, values: Variant, allow_duplicates: bool) -> bool:
	if id is String and id == "":
		push_warning("[Registry] %s(%s, ...) called with empty id" % [op, registry])
		return false
	if field == "":
		push_warning("[Registry] %s(%s, ...) called with empty field" % [op, registry])
		return false
	var arr: Array = _coerce_to_array(values)
	if arr.is_empty():
		push_warning("[Registry] %s('%s', ...): empty values is a no-op" % [op, registry])
		return false
	match registry:
		"items":
			if not (id is String):
				push_warning("[Registry] %s('items', ...): id must be a String" % op)
				return false
			match op:
				"append":      return _append_item(id, field, arr, allow_duplicates)
				"prepend":     return _prepend_item(id, field, arr, allow_duplicates)
				"remove_from": return _remove_from_item(id, field, arr)
		"sounds":
			if not (id is String):
				push_warning("[Registry] %s('sounds', ...): id must be a String" % op)
				return false
			match op:
				"append":      return _append_sound(id, field, arr, allow_duplicates)
				"prepend":     return _prepend_sound(id, field, arr, allow_duplicates)
				"remove_from": return _remove_from_sound(id, field, arr)
		"recipes":
			match op:
				"append":      return _append_recipe(id, field, arr, allow_duplicates)
				"prepend":     return _prepend_recipe(id, field, arr, allow_duplicates)
				"remove_from": return _remove_from_recipe(id, field, arr)
		"events":
			match op:
				"append":      return _append_event(id, field, arr, allow_duplicates)
				"prepend":     return _prepend_event(id, field, arr, allow_duplicates)
				"remove_from": return _remove_from_event(id, field, arr)
		"trader_tasks":
			match op:
				"append":      return _append_trader_task(id, field, arr, allow_duplicates)
				"prepend":     return _prepend_trader_task(id, field, arr, allow_duplicates)
				"remove_from": return _remove_from_trader_task(id, field, arr)
		"inputs":
			push_warning("[Registry] %s: 'inputs' has no Array-typed fields (display_label/default_event/deadzone are scalars; use patch instead)" % op)
			return false
		"scene_paths":
			push_warning("[Registry] %s: 'scene_paths' has no Array-typed fields (entries are path/Resource scalars; use patch instead)" % op)
			return false
		"resources":
			if not (id is String):
				push_warning("[Registry] %s('resources', ...): id must be a res:// path String" % op)
				return false
			match op:
				"append":      return _append_resource(id, field, arr, allow_duplicates)
				"prepend":     return _prepend_resource(id, field, arr, allow_duplicates)
				"remove_from": return _remove_from_resource(id, field, arr)
		"scene_nodes":
			push_warning("[Registry] %s: 'scene_nodes' patches store literal property values applied on scene-load; Array-merge isn't supported (read the property in a hook and patch the merged value instead)" % op)
			return false
		"scenes":
			push_warning("[Registry] %s: 'scenes' doesn't support array ops (scenes are monolithic PackedScenes)" % op)
			return false
		"loot":
			push_warning("[Registry] %s: 'loot' doesn't support array ops (loot entries are ItemData references; use the items registry instead)" % op)
			return false
		"trader_pools":
			push_warning("[Registry] %s: 'trader_pools' doesn't support array ops (entries are boolean flags)" % op)
			return false
		"shelters":
			push_warning("[Registry] %s: 'shelters' doesn't support array ops (entries are bare strings)" % op)
			return false
		"random_scenes":
			push_warning("[Registry] %s: 'random_scenes' doesn't support array ops (entries are bare paths)" % op)
			return false
		"ai_types":
			push_warning("[Registry] %s: 'ai_types' doesn't support array ops (entries are {scene, zone} refs)" % op)
			return false
		"fish_species":
			push_warning("[Registry] %s: 'fish_species' doesn't support array ops (entries are {scene, pool_id} refs)" % op)
			return false
		"weapons", "magazines", "attachments":
			push_warning("[Registry] %s: '%s' is a pure aggregator -- use the underlying primitive (e.g. %s('items', ...))" % [op, registry, op])
			return false
		_:
			push_warning("[Registry] %s: unknown registry '%s'" % [op, registry])
			return false
	return false


## Undo a register(). Fails if the id wasn't registered by a mod (can't
## remove vanilla entries via this API; use override with a disabled
## equivalent, or rely on the game's own toggle mechanisms).
func remove(registry: String, id: String) -> bool:
	match registry:
		"scenes": return _remove_scene(id)
		"items": return _remove_item(id)
		"loot": return _remove_loot(id)
		"sounds": return _remove_sound(id)
		"recipes": return _remove_recipe(id)
		"events": return _remove_event(id)
		"trader_pools": return _remove_trader_pool(id)
		"trader_tasks": return _remove_trader_task(id)
		"inputs": return _remove_input(id)
		"scene_paths": return _remove_scene_path(id)
		"shelters": return _remove_shelter(id)
		"maps": return _remove_map(id)
		"random_scenes": return _remove_random_scene(id)
		"ai_types": return _remove_ai_type(id)
		"fish_species": return _remove_fish_species(id)
		"resources":
			push_warning("[Registry] remove: 'resources' doesn't support remove (use revert to undo patches)")
			return false
		"scene_nodes":
			push_warning("[Registry] remove: 'scene_nodes' doesn't support remove (use revert to undo a property patch)")
			return false
		"weapons", "magazines", "attachments":
			push_warning("[Registry] remove: '%s' is a pure aggregator -- remove the underlying primitives instead (remove('items', ...), remove('scenes', ...), remove('loot', ...))" % registry)
			return false
		_:
			push_warning("[Registry] remove: unknown registry '%s'" % registry)
			return false

## Undo an override() or patch(). `fields` is for per-field revert on patch
## registries; leave empty to revert everything (both override and all
## accumulated patches on the id).
##
## `id` widens to Variant for symmetry with patch(): the 'recipes' and
## 'events' registries accept either a String handle or a Resource ref.
## Other registries require String.
func revert(registry: String, id: Variant, fields: Array = []) -> bool:
	match registry:
		"scenes":
			if not (id is String):
				push_warning("[Registry] revert('scenes', ...): id must be a String")
				return false
			return _revert_scene(id)
		"items":
			if not (id is String):
				push_warning("[Registry] revert('items', ...): id must be a String")
				return false
			return _revert_item(id, fields)
		"loot":
			if not (id is String):
				push_warning("[Registry] revert('loot', ...): id must be a String")
				return false
			return _revert_loot(id)
		"sounds":
			if not (id is String):
				push_warning("[Registry] revert('sounds', ...): id must be a String")
				return false
			return _revert_sound(id, fields)
		"recipes": return _revert_recipe(id, fields)
		"events": return _revert_event(id, fields)
		"trader_pools":
			if not (id is String):
				push_warning("[Registry] revert('trader_pools', ...): id must be a String")
				return false
			return _revert_trader_pool(id)
		"trader_tasks": return _revert_trader_task(id, fields)
		"inputs":
			if not (id is String):
				push_warning("[Registry] revert('inputs', ...): id must be a String")
				return false
			return _revert_input(id, fields)
		"scene_paths":
			if not (id is String):
				push_warning("[Registry] revert('scene_paths', ...): id must be a String")
				return false
			return _revert_scene_path(id, fields)
		"shelters":
			if not (id is String):
				push_warning("[Registry] revert('shelters', ...): id must be a String")
				return false
			return _remove_shelter(id)
		"maps":
			if not (id is String):
				push_warning("[Registry] revert('maps', ...): id must be a String")
				return false
			return _remove_map(id)
		"random_scenes":
			if not (id is String):
				push_warning("[Registry] revert('random_scenes', ...): id must be a String")
				return false
			return _remove_random_scene(id)
		"ai_types":
			if not (id is String):
				push_warning("[Registry] revert('ai_types', ...): id must be a String")
				return false
			return _revert_ai_type(id)
		"fish_species":
			if not (id is String):
				push_warning("[Registry] revert('fish_species', ...): id must be a String")
				return false
			return _remove_fish_species(id)
		"resources":
			if not (id is String):
				push_warning("[Registry] revert('resources', ...): id must be a res:// path String")
				return false
			return _revert_resource(id, fields)
		"scene_nodes":
			if not (id is String):
				push_warning("[Registry] revert('scene_nodes', ...): id must be a String in the form '<scene_path>#<node_path>'")
				return false
			return _revert_scene_node(id, fields)
		"weapons", "magazines", "attachments":
			push_warning("[Registry] revert: '%s' is a pure aggregator -- revert the underlying primitives instead" % registry)
			return false
		_:
			push_warning("[Registry] revert: unknown registry '%s'" % registry)
			return false

## Batched form of register(). `entries` is `{id: data, ...}`. Fans out to
## register() per entry; failures are isolated (one bad id doesn't stop the
## others). Returns `{ok: bool, results: {id: bool, ...}}`. `ok` is true only
## when every entry succeeded.
func register_many(registry: String, entries: Dictionary) -> Dictionary:
	var results: Dictionary = {}
	var all_ok := true
	for id in entries.keys():
		var ok: bool = register(registry, id, entries[id])
		results[id] = ok
		if not ok:
			all_ok = false
	return {"ok": all_ok, "results": results}


## Batched form of override(). Same shape as register_many.
func override_many(registry: String, entries: Dictionary) -> Dictionary:
	var results: Dictionary = {}
	var all_ok := true
	for id in entries.keys():
		var ok: bool = override(registry, id, entries[id])
		results[id] = ok
		if not ok:
			all_ok = false
	return {"ok": all_ok, "results": results}


## Batched form of patch(). `entries` is `{id: fields_dict, ...}`.
func patch_many(registry: String, entries: Dictionary) -> Dictionary:
	var results: Dictionary = {}
	var all_ok := true
	for id in entries.keys():
		var ok: bool = patch(registry, id, entries[id])
		results[id] = ok
		if not ok:
			all_ok = false
	return {"ok": all_ok, "results": results}


## Batched form of append(). `entries` is `{id: values, ...}` where values is
## a single value or Array. Same field across all entries (most common case);
## use individual append() calls if you need different fields per id.
func append_many(registry: String, field: String, entries: Dictionary, allow_duplicates: bool = false) -> Dictionary:
	var results: Dictionary = {}
	var all_ok := true
	for id in entries.keys():
		var ok: bool = append(registry, id, field, entries[id], allow_duplicates)
		results[id] = ok
		if not ok:
			all_ok = false
	return {"ok": all_ok, "results": results}


## Batched form of prepend(). Same shape as append_many.
func prepend_many(registry: String, field: String, entries: Dictionary, allow_duplicates: bool = false) -> Dictionary:
	var results: Dictionary = {}
	var all_ok := true
	for id in entries.keys():
		var ok: bool = prepend(registry, id, field, entries[id], allow_duplicates)
		results[id] = ok
		if not ok:
			all_ok = false
	return {"ok": all_ok, "results": results}


## Batched form of remove_from(). Same shape as append_many.
func remove_from_many(registry: String, field: String, entries: Dictionary) -> Dictionary:
	var results: Dictionary = {}
	var all_ok := true
	for id in entries.keys():
		var ok: bool = remove_from(registry, id, field, entries[id])
		results[id] = ok
		if not ok:
			all_ok = false
	return {"ok": all_ok, "results": results}


## Batched form of revert(). `entries` is `{id: fields_array, ...}` where
## fields_array can be empty (full revert of that id) or a list of field names.
func revert_many(registry: String, entries: Dictionary) -> Dictionary:
	var results: Dictionary = {}
	var all_ok := true
	for id in entries.keys():
		var fields_arg: Array = entries[id] if entries[id] is Array else []
		var ok: bool = revert(registry, id, fields_arg)
		results[id] = ok
		if not ok:
			all_ok = false
	return {"ok": all_ok, "results": results}


## Batched form of remove(). `ids` is an Array of String ids. Per-id results
## keyed by id.
func remove_many(registry: String, ids: Array) -> Dictionary:
	var results: Dictionary = {}
	var all_ok := true
	for id in ids:
		var sid := String(id)
		var ok: bool = remove(registry, sid)
		results[sid] = ok
		if not ok:
			all_ok = false
	return {"ok": all_ok, "results": results}


## Read API: resolve an id to its current value (vanilla, mod-registered, or
## mod-overridden, in the same priority the game itself sees). Useful for
## debugging and for mods that want to introspect what's registered. Returns
## null if the id doesn't resolve.
func get_entry(registry: String, id: String) -> Variant:
	match registry:
		"scenes":
			var db := _database_node()
			return null if db == null else db.get(id)
		"items":
			return _lookup_item(id)
		"loot":
			# Returns the {item, table} dict the mod registered under id, or
			# null if the id isn't a mod loot registration. Reads through
			# overrides first (matches lookup precedence elsewhere).
			var reg: Dictionary = _registry_registered.get("loot", {})
			return reg.get(id)
		"sounds":
			return _lookup_sound(id)
		"recipes":
			var reg: Dictionary = _registry_registered.get("recipes", {})
			return reg.get(id)
		"events":
			var reg: Dictionary = _registry_registered.get("events", {})
			return reg.get(id)
		"trader_pools":
			var reg: Dictionary = _registry_registered.get("trader_pools", {})
			return reg.get(id)
		"trader_tasks":
			var reg: Dictionary = _registry_registered.get("trader_tasks", {})
			return reg.get(id)
		"inputs":
			var reg: Dictionary = _registry_registered.get("inputs", {})
			return reg.get(id)
		"scene_paths":
			var reg: Dictionary = _registry_registered.get("scene_paths", {})
			return reg.get(id)
		"shelters":
			var reg: Dictionary = _registry_registered.get("shelters", {})
			var entry = reg.get(id)
			# Filter cross-surface lookups: shelters get_entry returns null
			# for ids that were registered via 'maps'.
			if entry is Dictionary and entry.get("kind", "shelters") != "shelters":
				return null
			return entry
		"maps":
			# Maps share the 'shelters' storage bucket but only surface
			# entries whose kind is "maps" through get_entry('maps').
			var reg: Dictionary = _registry_registered.get("shelters", {})
			var entry = reg.get(id)
			if entry is Dictionary and entry.get("kind", "shelters") != "maps":
				return null
			return entry
		"random_scenes":
			var reg: Dictionary = _registry_registered.get("random_scenes", {})
			return reg.get(id)
		"ai_types":
			var reg: Dictionary = _registry_registered.get("ai_types", {})
			return reg.get(id)
		"fish_species":
			var reg: Dictionary = _registry_registered.get("fish_species", {})
			return reg.get(id)
		"resources":
			# For the raw-resource escape hatch, `id` is a res:// path.
			# Returns the loaded Resource (with any live patches applied),
			# or null if the path doesn't resolve.
			if not (id is String):
				return null
			return load(id)
		_:
			push_warning("[Registry] get_entry: unknown registry '%s'" % registry)
			return null

# ---- Bulk read API ----
# Companion to get_entry for "what's in this registry?" queries. All four
# methods accept include_vanilla (default true) so modders can choose
# between "everything visible to gameplay" and "only what mods added."
#
# Per-registry vanilla-source dispatch lives in _enumerate_vanilla; mod
# entries are read from _registry_registered. On id collision the mod
# entry wins (matches get_entry precedence: override > register > vanilla).

## True if the id resolves to anything in this registry. Skips the entry
## construction get_entry would do; cheap membership check.
func has(registry: String, id: String, include_vanilla: bool = true) -> bool:
	var reg: Dictionary = _registry_registered.get(registry, {})
	if reg.has(id):
		return true
	if not include_vanilla:
		return false
	var vanilla: Dictionary = _enumerate_vanilla(registry)
	return vanilla.has(id)

## Just the ids in this registry, as a typed String array. Cheaper than
## list().keys() because we don't materialize the merged values dict when
## the caller doesn't need it.
func keys(registry: String, include_vanilla: bool = true) -> Array[String]:
	var out: Array[String] = []
	var seen: Dictionary = {}
	if include_vanilla:
		var vanilla: Dictionary = _enumerate_vanilla(registry)
		for k in vanilla.keys():
			out.append(String(k))
			seen[k] = true
	var reg: Dictionary = _registry_registered.get(registry, {})
	for k in reg.keys():
		if not seen.has(k):
			out.append(String(k))
	return out

## Full id -> entry mapping for this registry. Mod entries override
## vanilla on id collision (matches get_entry precedence).
func list(registry: String, include_vanilla: bool = true) -> Dictionary:
	var out: Dictionary = {}
	if include_vanilla:
		out = _enumerate_vanilla(registry).duplicate()
	var reg: Dictionary = _registry_registered.get(registry, {})
	for k in reg.keys():
		out[k] = reg[k]
	return out

## Filtered iteration. Predicate signature: func(entry) -> bool. Returns
## an Array of Dictionary {id, entry} pairs for every match. The id is
## included in the result so callers don't need to lookup separately.
func find(registry: String, predicate: Callable, include_vanilla: bool = true) -> Array:
	var out: Array = []
	var entries: Dictionary = list(registry, include_vanilla)
	for id in entries.keys():
		var entry = entries[id]
		if entry == null:
			continue
		if bool(predicate.call(entry)):
			out.append({"id": String(id), "entry": entry})
	return out

# Per-registry vanilla source enumerator. Returns id -> entry for every
# vanilla content item the registry tracks. Pure-mod registries (loot,
# trader_pools, scene_paths-mod-only, etc.) return {} -- their entries
# are inherently mod-side only.
func _enumerate_vanilla(registry: String) -> Dictionary:
	match registry:
		"items":
			# Vanilla items live in LT_Master.items, indexed by their .file
			# string. The items registry's _build_vanilla_item_cache does
			# this same walk; reuse via _lookup_item for consistency.
			var out: Dictionary = {}
			var master = load("res://Loot/LT_Master.tres")
			if master == null or not ("items" in master):
				return out
			for it in master.items:
				if it == null:
					continue
				var f = it.get("file")
				if f != null and String(f) != "":
					out[String(f)] = it
			return out
		"scenes":
			# Vanilla scenes are const declarations on Database.gd. Walk
			# the script's constant map.
			var out: Dictionary = {}
			var db := _database_node()
			if db == null or db.get_script() == null:
				return out
			var consts: Dictionary = db.get_script().get_script_constant_map()
			for k in consts.keys():
				var v = consts[k]
				if v is PackedScene:
					out[String(k)] = v
			return out
		"scene_paths":
			# Vanilla scene-path consts on Loader.gd. Same const-map walk
			# but values are Strings (res:// paths) rather than PackedScenes.
			var out: Dictionary = {}
			var ldr = get_tree().root.get_node_or_null("Loader")
			if ldr == null or ldr.get_script() == null:
				return out
			var consts: Dictionary = ldr.get_script().get_script_constant_map()
			for k in consts.keys():
				var v = consts[k]
				if v is String and String(v).begins_with("res://"):
					out[String(k)] = v
			return out
		"shelters":
			# Vanilla shelters are the entries in Loader.shelters that pre-
			# date any mod additions. _rtv_vanilla_shelters captures this
			# at @onready time. Each shelter "entry" is just its name; we
			# return name -> name for shape consistency.
			var out: Dictionary = {}
			var ldr = get_tree().root.get_node_or_null("Loader")
			if ldr == null or not ("_rtv_vanilla_shelters" in ldr):
				return out
			for name in ldr._rtv_vanilla_shelters:
				out[String(name)] = String(name)
			return out
		"recipes":
			# Vanilla recipes live in Recipes.tres across seven category
			# arrays. RecipeData has no inherent id -- we synthesize one
			# from "<category>:<recipe.name>" so two recipes with the same
			# display name in different categories don't collide.
			var out: Dictionary = {}
			var recipes = load("res://Crafting/Recipes.tres")
			if recipes == null:
				return out
			var cats: Array = ["consumables", "medical", "equipment", "weapons", "electronics", "misc", "furniture"]
			for cat in cats:
				var arr = recipes.get(cat)
				if not (arr is Array):
					continue
				for r in arr:
					if r == null:
						continue
					var rname = r.get("name") if r.has_method("get") else null
					var key: String = "%s:%s" % [cat, String(rname) if rname != null else "<unnamed>"]
					out[key] = r
			return out
		# Pure-mod registries: vanilla side is empty. The mod-entries dict
		# in _registry_registered is the complete picture for these.
		"loot", "trader_pools", "trader_tasks", "events", "sounds", \
		"inputs", "random_scenes", "ai_types", "fish_species", "resources", \
		"scene_nodes", "weapons", "magazines", "attachments":
			return {}
		_:
			push_warning("[Registry] _enumerate_vanilla: unknown registry '%s'" % registry)
			return {}
