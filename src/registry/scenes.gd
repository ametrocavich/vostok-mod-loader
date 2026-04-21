## ----- registry/scenes.gd -----
##
## The rewriter injects _rtv_mod_scenes + _rtv_override_scenes + _get() into
## Database.gd at build time. Registration writes into those dicts on the
## live Database autoload node. Vanilla game code doing Database.get(name)
## hits the injected _get() and resolves through the mod dicts before falling
## back to vanilla constants (now rewritten into _rtv_vanilla_scenes).

func _database_node() -> Node:
	var db = get_tree().root.get_node_or_null("Database")
	if db == null:
		push_warning("[Registry] Database autoload not in tree yet; is the loader still booting?")
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
	# in _rtv_vanilla_scenes, so db.get(id) routes through _get(); which
	# checks _rtv_override_scenes first. Writing to that dict is enough to
	# replace the scene a vanilla id resolves to.
	var original = db.get(id)
	if original == null:
		push_warning("[Registry] override('scenes', '%s'): no existing entry to override" % id)
		return false
	# Reject second override of the same scene id to match every other
	# registry's behavior. Without this guard, a later mod silently displaces
	# an earlier mod's override and the earlier mod has no signal that their
	# work was clobbered. The second mod should revert first (if it wants to
	# drop the earlier override) or target the registered id explicitly.
	var ov: Dictionary = _registry_overridden.get("scenes", {})
	if ov.has(id):
		push_warning("[Registry] override('scenes', '%s'): already overridden (revert first to re-override)" % id)
		return false
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

# A scene id collides with vanilla if Database's rewritten _rtv_vanilla_scenes
# dict contains it. The rewriter moves every `const X = preload(...)` from
# vanilla Database.gd into that dict; it's the canonical source of truth
# for "vanilla-shipped names."
func _scene_exists_in_vanilla(db: Node, id: String) -> bool:
	if not ("_rtv_vanilla_scenes" in db):
		return false
	var vs = db._rtv_vanilla_scenes as Dictionary
	return vs.has(id)
