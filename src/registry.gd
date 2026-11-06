# Public registry API: the Registry const, the rollback dicts, the verbs, their
# *_many forms and the read API. Per-section handlers live in src/registry/*.gd.

# Mods pass lib.Registry.SCENES rather than "scenes", so a typo fails loudly. A new
# section joins every verb's match (register, override, patch, _array_op_dispatch,
# remove, revert, get_entry) or that verb's _VERB_REFUSALS row, and _enumerate_vanilla;
# _bulk_mod_entries too when its entries live outside _registry_registered.
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

# section -> {id -> record}. patch stashes each field's value from before its
# first patch, so revert restores the true original.
var _registry_registered: Dictionary = {}
var _registry_overridden: Dictionary = {}
var _registry_patched: Dictionary = {}
# section -> {key -> {field -> object}}: where a stashed value was read from, since
# an override placed after a patch changes what the id resolves to.
var _registry_patch_sources: Dictionary = {}

func _require_string_id(verb: String, registry: String, id: Variant) -> bool:
	if id is String:
		return true
	var hint := "a String"
	if registry == "resources":
		hint = "a res:// path String"
	elif registry == "scene_nodes":
		hint = "a String in the form '<scene_path>#<node_path>'"
	push_warning("[Registry] %s('%s', ...): id must be %s" % [verb, registry, hint])
	return false

# The "aggregators" row stands for weapons, magazines and attachments; "array_op"
# for append, prepend and remove_from.
const _VERB_REFUSALS := {
	"register": {
		"resources": "doesn't support register (the target .tres already exists in vanilla; use patch to mutate its fields)",
		"scene_nodes": "doesn't support register (nodes are positional inside a scene; use override('scenes', ...) to replace the whole scene or patch('scene_nodes', ...) to mutate node properties)",
	},
	"override": {
		"trader_pools": "doesn't support override (pool entries are boolean flags on ItemData; just register/remove)",
		"shelters": "doesn't support override (it's an append-only list; use register/remove)",
		"maps": "doesn't support override (append-only; use register/remove, or override('scenes', ...) to swap the underlying scene)",
		"random_scenes": "doesn't support override (append-only list; use register/remove)",
		"fish_species": "doesn't support override (append-only list; use register/remove)",
		"resources": "doesn't support override (vanilla .tres already exists; use patch to mutate fields)",
		"scene_nodes": "doesn't support override (whole-scene swap goes through override('scenes', ...); scene_nodes is patch-only)",
		"aggregators": "is a pure aggregator -- override the underlying primitives instead (override('items', ...) for the ItemData, override('scenes', ...) for the world/rig scene)",
	},
	"patch": {
		"scenes": "doesn't support patch (scenes are monolithic PackedScenes; use override instead)",
		"loot": "doesn't support patch (loot entries are ItemData references; patch the ItemData via the 'items' registry instead)",
		"trader_pools": "doesn't support patch (entries are boolean flags; use register/remove)",
		"shelters": "doesn't support patch (use remove + register to change fields, or patch('scene_paths', ...) for path-only edits)",
		"maps": "doesn't support patch (use remove + register to change fields, or patch('scene_paths', ...) for path-only edits)",
		"random_scenes": "doesn't support patch (entries are bare paths)",
		"ai_types": "doesn't support patch (entries are {scene, zone} refs; use override to swap the scene)",
		"ai_loadouts": "doesn't support patch (entries are flat dicts; use override to replace)",
		"fish_species": "doesn't support patch (entries are {scene, pool_id} refs)",
		"aggregators": "is a pure aggregator -- patch the underlying primitive instead (patch('items', ...) for ItemData fields like compatible/damage/etc)",
	},
	"array_op": {
		"inputs": "has no Array-typed fields (display_label/default_event/deadzone are scalars; use patch instead)",
		"scene_paths": "has no Array-typed fields (entries are path/Resource scalars; use patch instead)",
		"scene_nodes": "patches store literal property values applied on scene-load; Array-merge isn't supported (read the property in a hook and patch the merged value instead)",
		"scenes": "doesn't support array ops (scenes are monolithic PackedScenes)",
		"loot": "doesn't support array ops (loot entries are ItemData references; use the items registry instead)",
		"trader_pools": "doesn't support array ops (entries are boolean flags)",
		"shelters": "doesn't support array ops (entries are bare strings)",
		"maps": "doesn't support array ops (entries are bare strings)",
		"random_scenes": "doesn't support array ops (entries are bare paths)",
		"ai_types": "doesn't support array ops (entries are {scene, zone} refs)",
		"ai_loadouts": "doesn't support array ops (entries are flat dicts; use override to replace)",
		"fish_species": "doesn't support array ops (entries are {scene, pool_id} refs)",
		"aggregators": "is a pure aggregator -- use the same verb on the underlying primitive (e.g. on 'items')",
	},
	"remove": {
		"resources": "doesn't support remove (use revert to undo patches)",
		"scene_nodes": "doesn't support remove (use revert to undo a property patch)",
		"aggregators": "is a pure aggregator -- remove the underlying primitives instead (remove('items', ...), remove('scenes', ...), remove('loot', ...))",
	},
	"revert": {
		"aggregators": "is a pure aggregator -- revert the underlying primitives instead",
	},
	"get_entry": {
		"scene_nodes": "is patch-only; there is no stored entry to read (inspect the live node in a hook instead)",
		"aggregators": "is a pure aggregator -- read the underlying primitives instead (get_entry('items', ...) / get_entry('scenes', ...))",
	},
}

# Every dispatcher's default arm; `called` is the verb as the mod called it when
# that is not `verb` (the array ops).
func _refuse_verb(verb: String, registry: String, called: String = "") -> bool:
	var label := verb if called == "" else called
	var refusals: Dictionary = _VERB_REFUSALS[verb]
	var key := "aggregators" if registry in ["weapons", "magazines", "attachments"] else registry
	if refusals.has(key):
		push_warning("[Registry] %s: '%s' %s" % [label, registry, refusals[key]])
	else:
		_warn_unknown_registry(label, registry)
	return false

# A declared section that a verb neither handles nor refuses is a loader bug.
func _warn_unknown_registry(verb: String, registry: String) -> void:
	if registry in Registry.values():
		push_warning("[Registry] %s: '%s' is declared but unwired (loader bug)" % [verb, registry])
	else:
		push_warning("[Registry] %s: unknown registry '%s'" % [verb, registry])

func register_item(entries: Dictionary) -> Dictionary:
	return _register_aggregator_batch(_register_item_bundle, entries)

func register_furniture(entries: Dictionary) -> Dictionary:
	return _register_aggregator_batch(_register_furniture_bundle, entries)

func register_weapon(entries: Dictionary) -> Dictionary:
	return _register_aggregator_batch(_register_weapon, entries)

func register_magazine(entries: Dictionary) -> Dictionary:
	return _register_aggregator_batch(_register_magazine, entries)

func register_attachment(entries: Dictionary) -> Dictionary:
	return _register_aggregator_batch(_register_attachment, entries)

func register_ai_loadout(entries: Dictionary) -> Dictionary:
	return _register_aggregator_batch(
			func(sid: String, data: Variant) -> Dictionary: return {"ok": _register_ai_loadout(sid, data)}, entries)

func _register_aggregator_batch(worker: Callable, entries: Dictionary) -> Dictionary:
	var results: Dictionary = {}
	var all_ok := true
	for id in entries.keys():
		# str(), not String(): String() does not convert, and a non-String key
		# would abort the batch. The same holds wherever a batch verb stringifies.
		var sid := str(id)
		var per: Dictionary = worker.call(sid, entries[id])
		results[sid] = per
		if not per["ok"]:
			all_ok = false
	return {"ok": all_ok, "results": results}

# Trader, LootContainer and LootSimulation copy LootTables into local buckets in
# _ready() and never re-read, so loot must be registered from a mod's _ready().
func register(registry: String, id: String, data: Variant) -> bool:
	if id == "":
		push_warning("[Registry] register(%s, ...) called with empty id" % registry)
		return false
	match registry:
		"scenes": return _register_scene(id, data)
		"items": return _register_item(id, data)
		"loot", "events", "trader_tasks": return _array_entry_register(registry, id, data)
		"sounds": return _register_sound(id, data)
		"recipes": return _register_recipe(id, data)
		"trader_pools": return _register_trader_pool(id, data)
		"inputs": return _register_input(id, data)
		"scene_paths": return _register_scene_path(id, data)
		"shelters": return _register_shelter(id, data)
		"maps": return _register_map(id, data)
		"random_scenes": return _register_random_scene(id, data)
		"ai_types": return _register_ai_type(id, data)
		"ai_loadouts": return _register_ai_loadout(id, data)
		"fish_species": return _register_fish_species(id, data)
		"weapons": return _register_weapon(id, data)["ok"]
		"magazines": return _register_magazine(id, data)["ok"]
		"attachments": return _register_attachment(id, data)["ok"]
		_: return _refuse_verb("register", registry)

func override(registry: String, id: String, data: Variant) -> bool:
	if id == "":
		push_warning("[Registry] override(%s, ...) called with empty id" % registry)
		return false
	match registry:
		"scenes": return _override_scene(id, data)
		"items": return _override_item(id, data)
		"loot", "recipes", "events", "trader_tasks": return _array_entry_override(registry, id, data)
		"sounds": return _override_sound(id, data)
		"inputs": return _override_input(id, data)
		"scene_paths": return _override_scene_path(id, data)
		"ai_types": return _override_ai_type(id, data)
		"ai_loadouts": return _override_ai_loadout(id, data)
		_: return _refuse_verb("override", registry)

# recipes, events and trader_tasks also take the entry Resource itself as `id`.
func patch(registry: String, id: Variant, fields: Dictionary) -> bool:
	if id is String and id == "":
		push_warning("[Registry] patch(%s, ...) called with empty id" % registry)
		return false
	match registry:
		"items": return _require_string_id("patch", registry, id) and _patch_item(id, fields)
		"sounds": return _require_string_id("patch", registry, id) and _patch_sound(id, fields)
		"recipes", "events", "trader_tasks": return _array_entry_patch(registry, id, fields)
		"inputs": return _require_string_id("patch", registry, id) and _patch_input(id, fields)
		"scene_paths": return _require_string_id("patch", registry, id) and _patch_scene_path(id, fields)
		"resources": return _require_string_id("patch", registry, id) and _patch_resource(id, fields)
		"scene_nodes": return _require_string_id("patch", registry, id) and _patch_scene_node(id, fields)
		_: return _refuse_verb("patch", registry)

func append(registry: String, id: Variant, field: String, values: Variant, allow_duplicates: bool = false) -> bool:
	return _array_op_dispatch(registry, id, field, "append", values, allow_duplicates)

func prepend(registry: String, id: Variant, field: String, values: Variant, allow_duplicates: bool = false) -> bool:
	return _array_op_dispatch(registry, id, field, "prepend", values, allow_duplicates)

func remove_from(registry: String, id: Variant, field: String, values: Variant) -> bool:
	return _array_op_dispatch(registry, id, field, "remove_from", values, false)

func _array_op_dispatch(registry: String, id: Variant, field: String, op: String, values: Variant,
		allow_duplicates: bool) -> bool:
	if id is String and id == "":
		push_warning("[Registry] %s(%s, ...) called with empty id" % [op, registry])
		return false
	if field == "":
		push_warning("[Registry] %s(%s, ...) called with empty field" % [op, registry])
		return false
	if values == null:
		push_warning("[Registry] %s('%s', %s): null is not a valid value (pass a value or an Array of values)" \
				% [op, registry, str(id)])
		return false
	var arr: Array = values if values is Array else [values]
	if arr.is_empty():
		push_warning("[Registry] %s('%s', ...): empty values is a no-op" % [op, registry])
		return false
	match registry:
		"items":
			return _require_string_id(op, registry, id) and _array_op_item(id, field, op, arr, allow_duplicates)
		"sounds":
			return _require_string_id(op, registry, id) and _array_op_sound(id, field, op, arr, allow_duplicates)
		"recipes", "events", "trader_tasks":
			var target := _array_entry_target(op, registry, id)
			if target.is_empty():
				return false
			var entry: Resource = target[0]
			var stash_key: Variant = target[1]
			return _array_op_on_resource(registry, stash_key, entry, field, op, arr, allow_duplicates)
		"resources":
			return _require_string_id(op, registry, id) and _array_op_resource(id, field, op, arr, allow_duplicates)
		_: return _refuse_verb("array_op", registry, op)

func remove(registry: String, id: String) -> bool:
	match registry:
		"scenes": return _remove_scene(id)
		"items": return _remove_item(id)
		"loot", "recipes", "events", "trader_tasks": return _array_entry_remove(registry, id)
		"sounds": return _remove_sound(id)
		"trader_pools": return _remove_trader_pool(id)
		"inputs": return _remove_input(id)
		"scene_paths": return _remove_scene_path(id)
		"shelters": return _remove_shelter(id)
		"maps": return _remove_map(id)
		"random_scenes": return _remove_random_scene(id)
		"ai_types": return _remove_ai_type(id)
		"ai_loadouts": return _remove_ai_loadout(id)
		"fish_species": return _remove_fish_species(id)
		_: return _refuse_verb("remove", registry)

# Empty `fields` reverts everything on the id.
func revert(registry: String, id: Variant, fields: Array = []) -> bool:
	match registry:
		"scenes": return _require_string_id("revert", registry, id) and _revert_scene(id)
		"items": return _require_string_id("revert", registry, id) and _revert_item(id, fields)
		# loot has no patches; revert undoes the override whatever `fields` says.
		"loot": return _require_string_id("revert", registry, id) and _array_entry_revert("loot", id, [])
		"sounds": return _require_string_id("revert", registry, id) and _revert_sound(id, fields)
		"recipes", "events", "trader_tasks": return _array_entry_revert(registry, id, fields)
		"trader_pools": return _require_string_id("revert", registry, id) and _revert_trader_pool(id)
		"inputs": return _require_string_id("revert", registry, id) and _revert_input(id, fields)
		"scene_paths": return _require_string_id("revert", registry, id) and _revert_scene_path(id, fields)
		"shelters": return _require_string_id("revert", registry, id) and _remove_shelter(id)
		"maps": return _require_string_id("revert", registry, id) and _remove_map(id)
		"random_scenes": return _require_string_id("revert", registry, id) and _remove_random_scene(id)
		"ai_types": return _require_string_id("revert", registry, id) and _revert_ai_type(id)
		"ai_loadouts": return _require_string_id("revert", registry, id) and _revert_ai_loadout(id)
		"fish_species": return _require_string_id("revert", registry, id) and _remove_fish_species(id)
		"resources": return _require_string_id("revert", registry, id) and _revert_resource(id, fields)
		"scene_nodes": return _require_string_id("revert", registry, id) and _revert_scene_node(id, fields)
		_: return _refuse_verb("revert", registry)

func _run_batch(ids: Array, apply: Callable) -> Dictionary:
	var results: Dictionary = {}
	var all_ok := true
	for id in ids:
		var ok: bool = apply.call(id)
		results[id] = ok
		if not ok:
			all_ok = false
	return {"ok": all_ok, "results": results}

func register_many(registry: String, entries: Dictionary) -> Dictionary:
	return _run_batch(entries.keys(), func(id) -> bool: return register(registry, str(id), entries[id]))

func override_many(registry: String, entries: Dictionary) -> Dictionary:
	return _run_batch(entries.keys(), func(id) -> bool: return override(registry, str(id), entries[id]))

# The type checks in patch_many and revert_many keep a bad value from raising a
# script error that would end the batch.
func patch_many(registry: String, entries: Dictionary) -> Dictionary:
	return _run_batch(entries.keys(), func(id) -> bool:
		var fields: Variant = entries[id]
		if not (fields is Dictionary):
			push_warning("[Registry] patch_many('%s', '%s'): value must be a Dictionary of fields, got %s" \
					% [registry, str(id), type_string(typeof(fields))])
			return false
		return patch(registry, id, fields))

func append_many(registry: String, field: String, entries: Dictionary, allow_duplicates: bool = false) -> Dictionary:
	return _run_batch(entries.keys(),
			func(id) -> bool: return append(registry, id, field, entries[id], allow_duplicates))

func prepend_many(registry: String, field: String, entries: Dictionary, allow_duplicates: bool = false) -> Dictionary:
	return _run_batch(entries.keys(),
			func(id) -> bool: return prepend(registry, id, field, entries[id], allow_duplicates))

func remove_from_many(registry: String, field: String, entries: Dictionary) -> Dictionary:
	return _run_batch(entries.keys(), func(id) -> bool: return remove_from(registry, id, field, entries[id]))

func revert_many(registry: String, entries: Dictionary) -> Dictionary:
	return _run_batch(entries.keys(), func(id) -> bool:
		var v: Variant = entries[id]
		# {id: "field"} meant as {id: ["field"]} would otherwise full-revert the id.
		if not (v is Array):
			push_warning("[Registry] revert_many('%s', '%s'): value must be an Array of field names, got %s" \
					% [registry, str(id), type_string(typeof(v))])
			return false
		return revert(registry, id, v))

func remove_many(registry: String, ids: Array) -> Dictionary:
	return _run_batch(ids, func(id) -> bool: return remove(registry, str(id)))

func get_entry(registry: String, id: String) -> Variant:
	match registry:
		"scenes":
			var db := _database_node()
			return null if db == null else db.get(id)
		"items":
			return _lookup_item(id)
		"sounds":
			return _lookup_sound(id)
		"scene_paths":
			return _lookup_scene_path(id)
		"loot", "recipes", "events", "trader_pools", "trader_tasks", "inputs", \
		"random_scenes", "ai_types", "ai_loadouts", "fish_species":
			return (_registry_registered.get(registry, {}) as Dictionary).get(id)
		"shelters", "maps":
			# Shelters and maps share the "shelters" bucket; `kind` tells them apart.
			var entry = (_registry_registered.get("shelters", {}) as Dictionary).get(id)
			return entry if entry != null and entry["kind"] == registry else null
		"resources":
			return load(id)
		_:
			_refuse_verb("get_entry", registry)
			return null

func _bulk_mod_entries(registry: String) -> Dictionary:
	if registry == "scenes":
		var out: Dictionary = {}
		var db := _database_node()
		if db != null:
			if "_rtv_mod_scenes" in db:
				for id in db._rtv_mod_scenes.keys():
					out[String(id)] = db._rtv_mod_scenes[id]
			if "_rtv_override_scenes" in db:
				for id in db._rtv_override_scenes.keys():
					out[String(id)] = db._rtv_override_scenes[id]
		return out
	if registry == "shelters" or registry == "maps":
		var shared: Dictionary = _registry_registered.get("shelters", {})
		var out: Dictionary = {}
		for id in shared.keys():
			if shared[id]["kind"] == registry:
				out[id] = shared[id]
		return out
	return _registry_registered.get(registry, {})

func has(registry: String, id: String, include_vanilla: bool = true) -> bool:
	if _bulk_mod_entries(registry).has(id):
		return true
	return include_vanilla and _enumerate_vanilla(registry).has(id)

func keys(registry: String, include_vanilla: bool = true) -> Array[String]:
	var out: Array[String] = []
	var seen: Dictionary = {}
	if include_vanilla:
		for k in _enumerate_vanilla(registry).keys():
			out.append(String(k))
			seen[k] = true
	for k in _bulk_mod_entries(registry).keys():
		if not seen.has(k):
			out.append(String(k))
	return out

# On an id in both, the mod entry wins, as in get_entry.
func list(registry: String, include_vanilla: bool = true) -> Dictionary:
	var out: Dictionary = {}
	if include_vanilla:
		out = _enumerate_vanilla(registry).duplicate()
	var reg: Dictionary = _bulk_mod_entries(registry)
	for k in reg.keys():
		out[k] = reg[k]
	return out

func find(registry: String, predicate: Callable, include_vanilla: bool = true) -> Array:
	var out: Array = []
	var entries: Dictionary = list(registry, include_vanilla)
	for id in entries.keys():
		var entry = entries[id]
		if entry == null:
			continue
		# bool() on a predicate that returned null is a script error.
		if _json_truthy(predicate.call(entry)):
			out.append({"id": String(id), "entry": entry})
	return out

func _enumerate_vanilla(registry: String) -> Dictionary:
	match registry:
		"items":
			# Read fresh: the lookup cache warns once when LT_Master is missing,
			# and enumeration must not.
			var by_file = _lt_master_items_by_file()
			return {} if by_file == null else by_file
		"scenes":
			# With [registry] declared the rewriter moved Database.gd's preload
			# consts into _rtv_vanilla_scenes; without it, walk the const map.
			var out: Dictionary = {}
			var db := _database_node()
			if db == null:
				return out
			if "_rtv_vanilla_scenes" in db:
				for k in db._rtv_vanilla_scenes.keys():
					out[String(k)] = db._rtv_vanilla_scenes[k]
				return out
			if db.get_script() == null:
				return out
			var consts := _script_constants(db.get_script())
			for k in consts.keys():
				if consts[k] is PackedScene:
					out[String(k)] = consts[k]
			return out
		"scene_paths":
			var out: Dictionary = {}
			var ldr := _autoload_node("Loader", false)
			if ldr == null or ldr.get_script() == null:
				return out
			var consts := _script_constants(ldr.get_script())
			for k in consts.keys():
				var v = consts[k]
				if v is String and String(v).begins_with("res://"):
					out[String(k)] = v
			return out
		"shelters":
			var out: Dictionary = {}
			var ldr := _autoload_node("Loader", false)
			if ldr == null or not ("_rtv_vanilla_shelters" in ldr):
				return out
			for name in ldr._rtv_vanilla_shelters:
				out[String(name)] = String(name)
			return out
		"recipes":
			# RecipeData has no id; "<category>:<name>" keeps categories apart.
			var out: Dictionary = {}
			var recipes := _registry_resource(_RECIPES_PATH, "")
			if recipes == null:
				return out
			for cat in _RECIPE_CATEGORIES:
				var arr = recipes.get(cat)
				if not (arr is Array):
					continue
				for r in arr:
					if r == null:
						continue
					var rname = r.get("name")
					out["%s:%s" % [cat, String(rname) if rname != null else "<unnamed>"]] = r
			return out
		"maps", "loot", "trader_pools", "trader_tasks", "events", "sounds", "inputs", "random_scenes", \
		"ai_types", "fish_species", "resources", "scene_nodes", "weapons", "magazines", "attachments", \
		"ai_loadouts":
			return {}
		_:
			_warn_unknown_registry("_enumerate_vanilla (has/keys/list/find)", registry)
			return {}
