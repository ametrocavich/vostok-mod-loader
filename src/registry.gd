## ----- registry.gd -----
## Public registry API for mods to add/override/edit vanilla game content.
##
##
## Usage:
##   lib.register(lib.Registry.SCENES, "my_item", preload("res://mymod/item.tscn"))
##   lib.override(lib.Registry.SCENES, "Potato", preload("res://mymod/better_potato.tscn"))
##   lib.remove(lib.Registry.SCENES, "my_item")
##   lib.revert(lib.Registry.SCENES, "Potato")
##
## Section 1 (this file): scenes on Database. Later sections add handlers for
## items, loot, recipes, events, sounds, etc. -- each section plugs its own
## entries into the dispatch match statements without changing the API shape.

# Registry name constants. Mods use lib.Registry.SCENES etc. instead of raw
# strings so typos surface at parse time.
const Registry := {
	SCENES = "scenes",
	# Future sections populate the rest:
	# ITEMS = "items",
	# LOOT = "loot",
	# RECIPES = "recipes",
	# EVENTS = "events",
	# SOUNDS = "sounds",
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
var _registry_registered: Dictionary = {}   # scenes -> {id -> true}
var _registry_overridden: Dictionary = {}   # scenes -> {id -> original_value}
# _registry_patched reserved for Tier-2 when patch() lands.

# ---- Public verbs ----

## Register a NEW entry. Fails if the id already exists (in vanilla or prior
## mod registrations). Returns true on success.
func register(registry: String, id: String, data: Variant) -> bool:
	if id == "":
		push_warning("[Registry] register(%s, ...) called with empty id" % registry)
		return false
	match registry:
		"scenes": return _register_scene(id, data)
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
		_:
			push_warning("[Registry] override: unknown registry '%s'" % registry)
			return false

## Partial update: merge `fields` into the entry at `id`. Not all registries
## support this (a scene is a single PackedScene, so SCENES does not). Future
## tiers (items, recipes) will.
func patch(registry: String, id: String, fields: Dictionary) -> bool:
	match registry:
		"scenes":
			push_warning("[Registry] patch: 'scenes' registry doesn't support patch (scenes are monolithic PackedScenes -- use override instead)")
			return false
		_:
			push_warning("[Registry] patch: unknown registry '%s'" % registry)
			return false

## Undo a register(). Fails if the id wasn't registered by a mod (can't
## remove vanilla entries via this API -- use override with a disabled
## equivalent, or rely on the game's own toggle mechanisms).
func remove(registry: String, id: String) -> bool:
	match registry:
		"scenes": return _remove_scene(id)
		_:
			push_warning("[Registry] remove: unknown registry '%s'" % registry)
			return false

## Undo an override() (or patch() once supported). `fields` is reserved for
## per-field revert on patch registries; leave empty to revert everything.
func revert(registry: String, id: String, fields: Array = []) -> bool:
	match registry:
		"scenes": return _revert_scene(id)
		_:
			push_warning("[Registry] revert: unknown registry '%s'" % registry)
			return false

# ---- Scenes handlers (Database.gd via injected _get()) ----
#
# The rewriter injects _rtv_mod_scenes + _rtv_override_scenes + _get() into
# Database.gd at build time. Registration just writes into those dicts on
# the live Database autoload node. Vanilla game code doing Database.get(name)
# hits the injected _get() and resolves through the mod dicts before falling
# back to vanilla constants.

func _database_node() -> Node:
	var db = get_tree().root.get_node_or_null("Database")
	if db == null:
		push_warning("[Registry] Database autoload not in tree yet -- is the loader still booting?")
	return db

func _register_scene(id: String, data: Variant) -> bool:
	if not (data is PackedScene):
		push_warning("[Registry] register('scenes', '%s', ...) expects a PackedScene, got %s" % [id, typeof(data)])
		return false
	var db := _database_node()
	if db == null:
		return false
	# Collision check: vanilla const, prior mod registration, or mod override.
	if _scene_exists_in_vanilla(db, id):
		push_warning("[Registry] register('scenes', '%s'): id collides with vanilla constant; use override instead" % id)
		return false
	if db._rtv_mod_scenes.has(id):
		push_warning("[Registry] register('scenes', '%s'): already registered by a mod" % id)
		return false
	db._rtv_mod_scenes[id] = data
	_track_registered("scenes", id)
	_log_debug("[Registry] registered scene '%s'" % id)
	return true

func _override_scene(id: String, data: Variant) -> bool:
	if not (data is PackedScene):
		push_warning("[Registry] override('scenes', '%s', ...) expects a PackedScene, got %s" % [id, typeof(data)])
		return false
	var db := _database_node()
	if db == null:
		return false
	# The rewriter converts Database's `const X = preload(...)` into entries
	# in _rtv_vanilla_scenes, so db.get(id) routes through _get() -- which
	# checks _rtv_override_scenes first. Writing to that dict is enough to
	# replace the scene a vanilla id resolves to.
	var original = db.get(id)
	if original == null:
		push_warning("[Registry] override('scenes', '%s'): no existing entry to override" % id)
		return false
	var ov: Dictionary = _registry_overridden.get("scenes", {})
	if not ov.has(id):
		ov[id] = original
		_registry_overridden["scenes"] = ov
	db._rtv_override_scenes[id] = data
	_log_debug("[Registry] overrode scene '%s'" % id)
	return true

func _remove_scene(id: String) -> bool:
	var db := _database_node()
	if db == null:
		return false
	if not db._rtv_mod_scenes.has(id):
		push_warning("[Registry] remove('scenes', '%s'): not registered by a mod" % id)
		return false
	db._rtv_mod_scenes.erase(id)
	var reg: Dictionary = _registry_registered.get("scenes", {})
	reg.erase(id)
	_registry_registered["scenes"] = reg
	_log_debug("[Registry] removed scene '%s'" % id)
	return true

func _revert_scene(id: String) -> bool:
	var db := _database_node()
	if db == null:
		return false
	if not db._rtv_override_scenes.has(id):
		push_warning("[Registry] revert('scenes', '%s'): no mod override to revert" % id)
		return false
	db._rtv_override_scenes.erase(id)
	var ov: Dictionary = _registry_overridden.get("scenes", {})
	ov.erase(id)
	_registry_overridden["scenes"] = ov
	_log_debug("[Registry] reverted scene '%s'" % id)
	return true

# ---- Helpers ----

func _track_registered(registry: String, id: String) -> void:
	var reg: Dictionary = _registry_registered.get(registry, {})
	reg[id] = true
	_registry_registered[registry] = reg

# A scene id collides with vanilla if Database's rewritten _rtv_vanilla_scenes
# dict contains it. The rewriter moves every `const X = preload(...)` from
# vanilla Database.gd into that dict. get_script_constant_map() used to be
# the way to check before we rewrote the consts; now the dict is the
# canonical source of truth for "vanilla-shipped names."
func _scene_exists_in_vanilla(db: Node, id: String) -> bool:
	if not ("_rtv_vanilla_scenes" in db):
		return false
	var vs = db._rtv_vanilla_scenes as Dictionary
	return vs.has(id)
