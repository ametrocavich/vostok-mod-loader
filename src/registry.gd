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
	RANDOM_SCENES = "random_scenes",
	AI_TYPES = "ai_types",
	FISH_SPECIES = "fish_species",
	RESOURCES = "resources",
	SCENE_NODES = "scene_nodes",
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
		"random_scenes": return _register_random_scene(id, data)
		"ai_types": return _register_ai_type(id, data)
		"fish_species": return _register_fish_species(id, data)
		"resources":
			push_warning("[Registry] register: 'resources' doesn't support register (the target .tres already exists in vanilla; use patch to mutate its fields)")
			return false
		"scene_nodes":
			push_warning("[Registry] register: 'scene_nodes' doesn't support register (nodes are positional inside a scene; use override('scenes', ...) to replace the whole scene or patch('scene_nodes', ...) to mutate node properties)")
			return false
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
			push_warning("[Registry] patch: 'shelters' doesn't support patch (entries are bare strings)")
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
		_:
			push_warning("[Registry] patch: unknown registry '%s'" % registry)
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
		"random_scenes": return _remove_random_scene(id)
		"ai_types": return _remove_ai_type(id)
		"fish_species": return _remove_fish_species(id)
		"resources":
			push_warning("[Registry] remove: 'resources' doesn't support remove (use revert to undo patches)")
			return false
		"scene_nodes":
			push_warning("[Registry] remove: 'scene_nodes' doesn't support remove (use revert to undo a property patch)")
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
		_:
			push_warning("[Registry] revert: unknown registry '%s'" % registry)
			return false

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
			return reg.get(id)
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
