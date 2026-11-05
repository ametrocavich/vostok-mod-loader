## fish_species: {scene, pool_id} entries the injected FishPool._ready prelude appends to `species`;
## pool_id "all" (the default) or a pool node name like "FP_2". Register and remove only.

# The prelude walks the {scene, pool_id} list in registration order, which
# keeps behavior deterministic across mod load orders.
const _FISH_ENGINE_META_KEY := "_rtv_fish_species"

func _register_fish_species(id: String, data: Variant) -> bool:
	if _registry_target_inert("FishPool.gd", "register('fish_species', '%s')" % id):
		return false
	var reg := _bucket(_registry_registered, "fish_species")
	if reg.has(id):
		push_warning("[Registry] register('fish_species', '%s'): already registered (pick a unique handle)" % id)
		return false
	if not (data is Dictionary):
		push_warning("[Registry] register('fish_species', '%s', ...) expects Dictionary {scene, pool_id}, got %s" % [id, type_string(typeof(data))])
		return false
	if not data.has("scene"):
		push_warning("[Registry] register('fish_species', '%s'): data missing 'scene' key" % id)
		return false
	if not (data["scene"] is PackedScene):
		push_warning("[Registry] register('fish_species', '%s'): scene is not a PackedScene" % id)
		return false
	var pool_id: Variant = data.get("pool_id", "all")
	if not (pool_id is String):
		push_warning("[Registry] register('fish_species', '%s'): pool_id must be a String" % id)
		return false
	reg[id] = {"scene": data["scene"], "pool_id": pool_id}
	_publish_registry_meta("fish_species", _FISH_ENGINE_META_KEY)
	_log_debug("[Registry] registered fish_species '%s' (pool_id=%s)" % [id, pool_id])
	return true

func _remove_fish_species(id: String) -> bool:
	var reg := _bucket(_registry_registered, "fish_species")
	if not reg.has(id):
		push_warning("[Registry] remove('fish_species', '%s'): not registered by a mod" % id)
		return false
	reg.erase(id)
	_publish_registry_meta("fish_species", _FISH_ENGINE_META_KEY)
	_log_debug("[Registry] removed fish_species '%s'" % id)
	return true
