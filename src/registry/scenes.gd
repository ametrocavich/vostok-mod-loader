## scenes: the Database autoload's mod and override dicts; its injected _get() checks
## overrides, then mod scenes, then the vanilla consts kept in _rtv_vanilla_scenes.

func _database_node() -> Node:
	return _autoload_node("Database", true)

# Without the injection a write would land in an ad-hoc property Database.get(id)
# never reads, and an id naming a real Node property ("name") would look present.
func _scene_db(verb: String, id: String) -> Node:
	var db := _database_node()
	if db != null and not ("_rtv_mod_scenes" in db and "_rtv_override_scenes" in db):
		push_warning(("[Registry] %s('scenes', '%s'): Database.gd is missing injected scene fields (rewriter didn't fire). " \
				+ "Does your mod.txt include a [registry] section?") % [verb, id])
		return null
	return db

func _register_scene(id: String, data: Variant) -> bool:
	if not (data is PackedScene):
		push_warning("[Registry] register('scenes', '%s', ...) expects a PackedScene, got %s" % [id, type_string(typeof(data))])
		return false
	var db := _scene_db("register", id)
	if db == null:
		return false
	if "_rtv_vanilla_scenes" in db and db._rtv_vanilla_scenes.has(id):
		push_warning("[Registry] register('scenes', '%s'): id collides with vanilla constant; use override instead" % id)
		return false
	if db._rtv_mod_scenes.has(id):
		push_warning("[Registry] register('scenes', '%s'): already registered by a mod" % id)
		return false
	db._rtv_mod_scenes[id] = data
	_log_debug("[Registry] registered scene '%s'" % id)
	return true

func _override_scene(id: String, data: Variant) -> bool:
	if not (data is PackedScene):
		push_warning("[Registry] override('scenes', '%s', ...) expects a PackedScene, got %s" % [id, type_string(typeof(data))])
		return false
	var db := _scene_db("override", id)
	if db == null:
		return false
	if db.get(id) == null:
		push_warning("[Registry] override('scenes', '%s'): no existing entry to override" % id)
		return false
	var ov := _bucket(_registry_overridden, "scenes")
	if ov.has(id):
		push_warning("[Registry] override('scenes', '%s'): already overridden (revert first to re-override)" % id)
		return false
	ov[id] = true
	# The injected _get() reads _rtv_override_scenes first.
	db._rtv_override_scenes[id] = data
	_log_debug("[Registry] overrode scene '%s'" % id)
	return true

func _remove_scene(id: String) -> bool:
	var db := _scene_db("remove", id)
	if db == null:
		return false
	if not db._rtv_mod_scenes.has(id):
		push_warning("[Registry] remove('scenes', '%s'): not registered by a mod" % id)
		return false
	# An override on the registration has this scene as its revert target.
	if db._rtv_override_scenes.has(id):
		push_warning("[Registry] remove('scenes', '%s'): entry is an override, use revert instead" % id)
		return false
	db._rtv_mod_scenes.erase(id)
	_log_debug("[Registry] removed scene '%s'" % id)
	return true

func _revert_scene(id: String) -> bool:
	var db := _scene_db("revert", id)
	if db == null:
		return false
	if not db._rtv_override_scenes.has(id):
		push_warning("[Registry] revert('scenes', '%s'): no mod override to revert" % id)
		return false
	db._rtv_override_scenes.erase(id)
	_bucket(_registry_overridden, "scenes").erase(id)
	_log_debug("[Registry] reverted scene '%s'" % id)
	return true
