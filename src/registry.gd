## ----- registry.gd -----
## Public registry API for mods to add/override/edit vanilla game content.
##
## Usage:
##   lib.register(lib.Registry.SCENES, "my_item", preload("res://mymod/item.tscn"))
##   lib.override(lib.Registry.SCENES, "Potato", preload("res://mymod/better_potato.tscn"))
##
## Owns the Registry const, the rollback dicts, the verb dispatchers and
## their *_many forms, and the read API (get_entry / has / keys / list /
## find). Per-registry handlers live in src/registry/*.gd.
##
## Adding a section touches: the Registry.FOO const; a match arm in every
## dispatcher here (a forgotten arm is not a compile error and lands in the
## `_:` default at runtime, so unsupported verbs need an explicit refusing arm);
## the src/registry/foo.gd handlers; the build.sh FILES entry; any injection in
## rewriter_registry_inject.gd + hook_pack.gd; and docs/wiki/Registry.md.
##
## Timing: Trader / LootContainer / LootSimulation fill local buckets from
## LootTables in _ready() and never re-read, so mods must register loot
## during their own _ready() or earlier in the autoload order.

# Mods use lib.Registry.SCENES etc. instead of raw strings so typos surface at parse time.
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
	AI_LOADOUTS = "ai_loadouts",
}

# Rollback tracking, reg -> {id -> per-verb data}. Populated by register/
# override/patch, consumed by remove/revert. Patch stashes each field's
# pre-first-patch value, so revert restores the true original.
var _registry_registered: Dictionary = {}
var _registry_overridden: Dictionary = {}
var _registry_patched: Dictionary = {}
# Where each stashed value was read from: reg -> {key -> {field -> Resource or
# Dictionary}}. An override placed after a patch changes what the id resolves
# to, and revert has to reach the object the patch changed. Read by items,
# sounds and scene_paths, the slots where an override can do that.
var _registry_patch_sources: Dictionary = {}

# Default-arm diagnostic: a mod typo, or a Registry const with no match arm
# for this verb, which is a loader bug nothing else flags.
func _warn_unknown_registry(verb: String, registry: String) -> void:
	if registry in Registry.values():
		push_warning("[Registry] %s: '%s' is declared in the Registry const but has no match arm in %s -- unwired section (loader bug, see \"Adding a registry section\" in CONTRIBUTING.md), not a mod typo" \
				% [verb, registry, verb])
	else:
		push_warning("[Registry] %s: unknown registry '%s'" % [verb, registry])

# ---- Aggregator helpers (weapons / magazines / attachments) ----
# Wrap several primitive registries into one call and return per-step success
# bools; the standard verbs collapse that to one bool.

## Register generic item bundles (ItemData + optional scene/icon/loot/
## trader_pools). Always takes {id: data}, even for one entry. Returns
## {ok, results: {id: granular_dict}}; schema in registry/aggregators.gd.
func register_item(entries: Dictionary) -> Dictionary:
	return _register_aggregator_batch("item", entries)

## Register furniture bundles (ItemData with type='Furniture' + placed scene
## + trader_pools, optional crafting recipe). Not loot-pool spawnable;
## trader_pools defaults to ['Generalist'] with a warn if missing.
func register_furniture(entries: Dictionary) -> Dictionary:
	return _register_aggregator_batch("furniture", entries)

## Register weapon bundles (item + scene + rig, optional magazines /
## fits_attachments / loot_tables). result.results has per-id sub-results.
func register_weapon(entries: Dictionary) -> Dictionary:
	return _register_aggregator_batch("weapon", entries)

## Register magazine bundles (item + scene, optional fits_weapons /
## loot_tables). Patches each fits_weapons target's compatible array.
func register_magazine(entries: Dictionary) -> Dictionary:
	return _register_aggregator_batch("magazine", entries)

## Register attachment bundles. Same shape as register_magazine; the split
## is only for readability (vanilla `compatible` doesn't distinguish).
func register_attachment(entries: Dictionary) -> Dictionary:
	return _register_aggregator_batch("attachment", entries)

## Register AI loadout entries: which AI categories carry which weapon
## scenes. Per-entry data: {weapon_scene, ai_types[], chance?, replace?};
## see registry/ai_loadouts.gd. Weapons being registered anyway can use
## register_weapon's ai_loadout field instead.
func register_ai_loadout(entries: Dictionary) -> Dictionary:
	return _register_aggregator_batch("ai_loadout", entries)


# Shared loop for all aggregator helpers. Wraps per-id granular results in
# {ok, results}; one bad entry doesn't stop the next.
func _register_aggregator_batch(kind: String, entries: Dictionary) -> Dictionary:
	var results: Dictionary = {}
	var all_ok := true
	for id in entries.keys():
		# str(), not String(): String() is the non-converting constructor and a
		# non-String key would abort the batch mid-way. Same everywhere a batch verb stringifies keys.
		var sid := str(id)
		var per: Dictionary
		match kind:
			"item":       per = _register_item_bundle(sid, entries[id])
			"furniture":  per = _register_furniture_bundle(sid, entries[id])
			"weapon":     per = _register_weapon(sid, entries[id])
			"magazine":   per = _register_magazine(sid, entries[id])
			"attachment": per = _register_attachment(sid, entries[id])
			"ai_loadout":
				# ai_loadouts is a primitive registry; wrap its bool in the shared shape.
				var ok: bool = _register_ai_loadout(sid, entries[id])
				per = {"ok": ok}
			_:
				per = {"ok": false, "error": "internal: unknown aggregator kind '%s'" % kind}
		results[sid] = per
		if not bool(per.get("ok", false)):
			all_ok = false
	return {"ok": all_ok, "results": results}

# ---- Public verbs ----

## Register a new entry. Fails if the id already exists (in vanilla or prior
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
		"ai_loadouts": return _register_ai_loadout(id, data)
		"fish_species": return _register_fish_species(id, data)
		"resources":
			push_warning("[Registry] register: 'resources' doesn't support register (the target .tres already exists in vanilla; use patch to mutate its fields)")
			return false
		"scene_nodes":
			push_warning("[Registry] register: 'scene_nodes' doesn't support register (nodes are positional inside a scene; use override('scenes', ...) to replace the whole scene or patch('scene_nodes', ...) to mutate node properties)")
			return false
		"weapons":
			# Collapse the aggregator's granular dict to a bool.
			return bool(_register_weapon(id, data).get("ok", false))
		"magazines":
			return bool(_register_magazine(id, data).get("ok", false))
		"attachments":
			return bool(_register_attachment(id, data).get("ok", false))
		_:
			_warn_unknown_registry("register", registry)
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
		"ai_loadouts": return _override_ai_loadout(id, data)
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
			_warn_unknown_registry("override", registry)
			return false

## Partial update: merge `fields` into the entry at `id`. Unsupported
## registries return false with guidance. 'recipes', 'events', and
## 'trader_tasks' also accept a direct Resource ref as `id`.
##
## Return contract varies by handler: items/sounds/recipes/events/
## trader_tasks return true whenever the id resolves, even if every field
## was rejected (bad fields warn and skip); resources and inputs need at
## least one field applied; scene_nodes validates up front and applies
## nothing if any field is missing; scene_paths entries are open dicts, any
## field is accepted. All return false when the id doesn't resolve.
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
		"ai_loadouts":
			push_warning("[Registry] patch: 'ai_loadouts' doesn't support patch (entries are flat dicts; use override to replace)")
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
			_warn_unknown_registry("patch", registry)
			return false

## Append values (one or an Array) to an Array field. De-duplicates by
## default; pass allow_duplicates=true to permit repeats. Shares patch()'s
## first-write-wins stash, so revert() restores the pre-mutation array.
func append(registry: String, id: Variant, field: String, values: Variant, allow_duplicates: bool = false) -> bool:
	return _array_op_dispatch(registry, id, field, "append", values, allow_duplicates)


## Prepend values to an Array field. Same de-dup semantics as append;
## prepend([a, b]) on [c] yields [a, b, c].
func prepend(registry: String, id: Variant, field: String, values: Variant, allow_duplicates: bool = false) -> bool:
	return _array_op_dispatch(registry, id, field, "prepend", values, allow_duplicates)


## Remove values from an Array field. Removes all matching occurrences.
## Silent skip if a value isn't present (idempotent).
func remove_from(registry: String, id: Variant, field: String, values: Variant) -> bool:
	return _array_op_dispatch(registry, id, field, "remove_from", values, false)


# Shared dispatcher for append/prepend/remove_from; mirrors patch()'s routing.
func _array_op_dispatch(registry: String, id: Variant, field: String, op: String, values: Variant, allow_duplicates: bool) -> bool:
	if id is String and id == "":
		push_warning("[Registry] %s(%s, ...) called with empty id" % [op, registry])
		return false
	if field == "":
		push_warning("[Registry] %s(%s, ...) called with empty field" % [op, registry])
		return false
	# Reject null up front: _coerce_to_array(null) yields [null] and a misleading error later.
	if values == null:
		push_warning("[Registry] %s('%s', %s): null is not a valid value (pass a value or an Array of values)" \
				% [op, registry, str(id)])
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
			return _array_op_item(id, field, op, arr, allow_duplicates)
		"sounds":
			if not (id is String):
				push_warning("[Registry] %s('sounds', ...): id must be a String" % op)
				return false
			return _array_op_sound(id, field, op, arr, allow_duplicates)
		"recipes":
			return _array_op_recipe(id, field, op, arr, allow_duplicates)
		"events":
			return _array_op_event(id, field, op, arr, allow_duplicates)
		"trader_tasks":
			return _array_op_trader_task(id, field, op, arr, allow_duplicates)
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
			return _array_op_resource(id, field, op, arr, allow_duplicates)
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
		"maps":
			push_warning("[Registry] %s: 'maps' doesn't support array ops (entries are bare strings)" % op)
			return false
		"random_scenes":
			push_warning("[Registry] %s: 'random_scenes' doesn't support array ops (entries are bare paths)" % op)
			return false
		"ai_types":
			push_warning("[Registry] %s: 'ai_types' doesn't support array ops (entries are {scene, zone} refs)" % op)
			return false
		"ai_loadouts":
			push_warning("[Registry] %s: 'ai_loadouts' doesn't support array ops (entries are flat dicts; use override to replace)" % op)
			return false
		"fish_species":
			push_warning("[Registry] %s: 'fish_species' doesn't support array ops (entries are {scene, pool_id} refs)" % op)
			return false
		"weapons", "magazines", "attachments":
			push_warning("[Registry] %s: '%s' is a pure aggregator -- use the underlying primitive (e.g. %s('items', ...))" % [op, registry, op])
			return false
		_:
			_warn_unknown_registry(op, registry)
			return false
	return false


## Undo a register(). Fails if the id wasn't registered by a mod; vanilla
## entries can't be removed, only overridden.
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
		"ai_loadouts": return _remove_ai_loadout(id)
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
			_warn_unknown_registry("remove", registry)
			return false

## Undo an override() or patch(). `fields` selects per-field revert; leave
## empty to revert everything on the id. As with patch(), 'recipes',
## 'events', and 'trader_tasks' also accept a Resource ref as `id`.
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
		"ai_loadouts":
			if not (id is String):
				push_warning("[Registry] revert('ai_loadouts', ...): id must be a String")
				return false
			return _revert_ai_loadout(id)
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
			_warn_unknown_registry("revert", registry)
			return false

## Batched form of register(). `entries` is `{id: data, ...}`. Failures are
## isolated per entry. Returns `{ok: bool, results: {id: bool, ...}}`; `ok`
## is true only when every entry succeeded.
func register_many(registry: String, entries: Dictionary) -> Dictionary:
	var results: Dictionary = {}
	var all_ok := true
	for id in entries.keys():
		var ok: bool = register(registry, str(id), entries[id])
		results[id] = ok
		if not ok:
			all_ok = false
	return {"ok": all_ok, "results": results}


## Batched form of override(). Same shape as register_many.
func override_many(registry: String, entries: Dictionary) -> Dictionary:
	var results: Dictionary = {}
	var all_ok := true
	for id in entries.keys():
		var ok: bool = override(registry, str(id), entries[id])
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
## use individual append() calls when entries need different fields.
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
		var v: Variant = entries[id]
		# A non-Array value ({id: "field"} for {id: ["field"]}) would coerce to []
		# and full-revert, losing unrelated patches; reject so the typo surfaces.
		if not (v is Array):
			push_warning("[Registry] revert_many('%s', '%s'): value must be an Array of field names (use [] for full revert); got %s. Skipping." \
					% [registry, str(id), type_string(typeof(v))])
			results[id] = false
			all_ok = false
			continue
		var ok: bool = revert(registry, id, v)
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
		var sid := str(id)
		var ok: bool = remove(registry, sid)
		results[sid] = ok
		if not ok:
			all_ok = false
	return {"ok": all_ok, "results": results}


## Read API: resolve an id to its current value (vanilla, mod-registered, or
## mod-overridden, in the same priority the game sees). Returns null if the
## id doesn't resolve.
func get_entry(registry: String, id: String) -> Variant:
	match registry:
		"scenes":
			var db := _database_node()
			return null if db == null else db.get(id)
		"items":
			return _lookup_item(id)
		"loot":
			# The {item, table} dict the mod registered under id, or null.
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
			return _lookup_scene_path(id)
		"shelters":
			var reg: Dictionary = _registry_registered.get("shelters", {})
			var entry = reg.get(id)
			# Ids registered via 'maps' don't surface here (shared bucket).
			if entry is Dictionary and entry.get("kind", "shelters") != "shelters":
				return null
			return entry
		"maps":
			# Maps share the 'shelters' bucket; only kind=="maps" surfaces.
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
		"ai_loadouts":
			var reg: Dictionary = _registry_registered.get("ai_loadouts", {})
			return reg.get(id)
		"fish_species":
			var reg: Dictionary = _registry_registered.get("fish_species", {})
			return reg.get(id)
		"resources":
			# `id` is a res:// path; returns the loaded Resource with live patches, or null.
			if not (id is String):
				return null
			return load(id)
		"scene_nodes":
			push_warning("[Registry] get_entry: 'scene_nodes' is patch-only; there is no stored entry to read (inspect the live node in a hook instead)")
			return null
		"weapons", "magazines", "attachments":
			push_warning("[Registry] get_entry: '%s' is a pure aggregator -- read the underlying primitives instead (get_entry('items', ...) / get_entry('scenes', ...))" % registry)
			return null
		_:
			_warn_unknown_registry("get_entry", registry)
			return null

# ---- Bulk read API ----
# Companion to get_entry. include_vanilla chooses between everything visible
# to gameplay and only what mods added; on collision the mod entry wins.

# Mod-side entries. 'shelters' and 'maps' share one bucket with a 'kind' tag;
# filter so each surface reports only its own registrations.
func _bulk_mod_entries(registry: String) -> Dictionary:
	if registry == "scenes":
		# Real PackedScene values live on the Database node; _registry_registered
		# holds only rollback markers. Merge the real values, overrides last.
		var scene_out: Dictionary = {}
		var db := _database_node()
		if db != null:
			if "_rtv_mod_scenes" in db and db._rtv_mod_scenes is Dictionary:
				for id in db._rtv_mod_scenes.keys():
					scene_out[String(id)] = db._rtv_mod_scenes[id]
			if "_rtv_override_scenes" in db and db._rtv_override_scenes is Dictionary:
				for id in db._rtv_override_scenes.keys():
					scene_out[String(id)] = db._rtv_override_scenes[id]
		return scene_out
	if registry == "shelters" or registry == "maps":
		var shared: Dictionary = _registry_registered.get("shelters", {})
		var out: Dictionary = {}
		for id in shared.keys():
			var meta = shared[id]
			var kind: String = String(meta.get("kind", "shelters")) if meta is Dictionary else "shelters"
			if kind == registry:
				out[id] = meta
		return out
	return _registry_registered.get(registry, {})

## Cheap membership check: true if the id resolves in this registry.
func has(registry: String, id: String, include_vanilla: bool = true) -> bool:
	var reg: Dictionary = _bulk_mod_entries(registry)
	if reg.has(id):
		return true
	if not include_vanilla:
		return false
	var vanilla: Dictionary = _enumerate_vanilla(registry)
	return vanilla.has(id)

## The ids in this registry, as a typed String array. Cheaper than
## list().keys() -- no merged values dict is materialized.
func keys(registry: String, include_vanilla: bool = true) -> Array[String]:
	var out: Array[String] = []
	var seen: Dictionary = {}
	if include_vanilla:
		var vanilla: Dictionary = _enumerate_vanilla(registry)
		for k in vanilla.keys():
			out.append(String(k))
			seen[k] = true
	var reg: Dictionary = _bulk_mod_entries(registry)
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
	var reg: Dictionary = _bulk_mod_entries(registry)
	for k in reg.keys():
		out[k] = reg[k]
	return out

## Filtered iteration. Predicate: func(entry) -> bool. Returns an Array of
## {id, entry} pairs for every match.
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

# Per-registry vanilla source enumerator: id -> entry. Pure-mod registries
# return {}.
func _enumerate_vanilla(registry: String) -> Dictionary:
	match registry:
		"items":
			# Vanilla items: LT_Master.items by .file. Repeats the cache walk, since enumeration must not warn.
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
			# With [registry] declared the rewriter moved Database.gd's preload consts
			# into _rtv_vanilla_scenes; read that first, else walk the const map.
			var out: Dictionary = {}
			var db := _database_node()
			if db == null:
				return out
			if "_rtv_vanilla_scenes" in db and db._rtv_vanilla_scenes is Dictionary:
				for k in db._rtv_vanilla_scenes.keys():
					out[String(k)] = db._rtv_vanilla_scenes[k]
				return out
			if db.get_script() == null:
				return out
			var consts: Dictionary = db.get_script().get_script_constant_map()
			for k in consts.keys():
				var v = consts[k]
				if v is PackedScene:
					out[String(k)] = v
			return out
		"scene_paths":
			# Vanilla scene-path consts on Loader.gd (String res:// values).
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
			# _rtv_vanilla_shelters snapshots Loader.shelters; a shelter entry is its name.
			var out: Dictionary = {}
			var ldr = get_tree().root.get_node_or_null("Loader")
			if ldr == null or not ("_rtv_vanilla_shelters" in ldr):
				return out
			for name in ldr._rtv_vanilla_shelters:
				out[String(name)] = String(name)
			return out
		"maps":
			# No vanilla snapshot for maps; the mod side is in _bulk_mod_entries.
			return {}
		"recipes":
			# RecipeData has no id; synthesize "<category>:<name>" so categories do not collide.
			var out: Dictionary = {}
			var recipes = load(_RECIPES_PATH)
			if recipes == null:
				return out
			for cat in _RECIPE_CATEGORIES:
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
		# Pure-mod registries: vanilla side is empty.
		"loot", "trader_pools", "trader_tasks", "events", "sounds", \
		"inputs", "random_scenes", "ai_types", "fish_species", "resources", \
		"scene_nodes", "weapons", "magazines", "attachments", "ai_loadouts":
			return {}
		_:
			_warn_unknown_registry("_enumerate_vanilla (has/keys/list/find)", registry)
			return {}
