## ai_types: one enemy scene per AISpawner zone, so register and override share a slot. The nomad
## pool is zone-independent and not routed; only `enemy = <name>` goes through the resolver.

const _VALID_ZONES := ["Area05", "BorderZone", "Vostok", "Debug"]

# The injected _rtv_resolve_ai_type reads {zone name: scene} here (AISpawner has many
# instances, so not a node field) and maps its Zone int through Zone.keys().
const _AI_ENGINE_META_KEY := "_rtv_ai_overrides"

func _rebuild_ai_engine_meta() -> void:
	var flat: Dictionary = {}
	var reg: Dictionary = _registry_registered["ai_types"]
	for id in reg.keys():
		flat[reg[id]["zone"]] = reg[id]["scene"]
	Engine.set_meta(_AI_ENGINE_META_KEY, flat)

# The stored {scene, zone} entry, or {} after a warning.
func _ai_type_entry(id: String, verb: String, data: Variant) -> Dictionary:
	if not (data is Dictionary):
		push_warning("[Registry] %s('ai_types', '%s', ...) expects Dictionary {scene, zone}, got %s" % [verb, id, type_string(typeof(data))])
		return {}
	if not data.has("scene") or not data.has("zone"):
		push_warning("[Registry] %s('ai_types', '%s', ...) data dict missing 'scene' or 'zone' key" % [verb, id])
		return {}
	var scene: Variant = data["scene"]
	if not (scene is PackedScene):
		push_warning("[Registry] %s('ai_types', '%s'): scene is not a PackedScene" % [verb, id])
		return {}
	var zone: Variant = data["zone"]
	if not (zone is String):
		push_warning("[Registry] %s('ai_types', '%s'): zone must be a String (e.g. 'Area05')" % [verb, id])
		return {}
	if not (zone in _VALID_ZONES):
		push_warning("[Registry] %s('ai_types', '%s'): unknown zone '%s' (valid: %s)" % [verb, id, zone, _VALID_ZONES])
		return {}
	return {"scene": scene, "zone": zone}

func _register_ai_type(id: String, data: Variant) -> bool:
	if _registry_target_inert("AISpawner.gd", "register('ai_types', '%s')" % id):
		return false
	var reg := _bucket(_registry_registered, "ai_types")
	if reg.has(id):
		push_warning("[Registry] register('ai_types', '%s'): already registered (pick a unique handle or use override)" % id)
		return false
	var entry := _ai_type_entry(id, "register", data)
	if entry.is_empty():
		return false
	for existing_id in reg.keys():
		if reg[existing_id]["zone"] == entry["zone"]:
			push_warning("[Registry] register('ai_types', '%s'): zone '%s' already claimed by '%s'; use override to replace" % [id, entry["zone"], existing_id])
			return false
	reg[id] = entry
	_rebuild_ai_engine_meta()
	_log_debug("[Registry] registered ai_type '%s' (zone=%s)" % [id, entry["zone"]])
	return true

func _override_ai_type(id: String, data: Variant) -> bool:
	if _registry_target_inert("AISpawner.gd", "override('ai_types', '%s')" % id):
		return false
	var ov := _bucket(_registry_overridden, "ai_types")
	if ov.has(id):
		push_warning("[Registry] override('ai_types', '%s'): already overridden (revert first)" % id)
		return false
	var entry := _ai_type_entry(id, "override", data)
	if entry.is_empty():
		return false
	var reg := _bucket(_registry_registered, "ai_types")
	var displaced: Array = []
	for existing_id in reg.keys():
		if reg[existing_id]["zone"] == entry["zone"]:
			displaced.append({"id": existing_id, "entry": reg[existing_id]})
	for d in displaced:
		reg.erase(d["id"])
	ov[id] = {"displaced": displaced, "previous": reg.get(id)}
	reg[id] = entry
	_rebuild_ai_engine_meta()
	_log_debug("[Registry] overrode ai_type '%s' (zone=%s, displaced %d entry/entries)" % [id, entry["zone"], displaced.size()])
	return true

func _remove_ai_type(id: String) -> bool:
	var reg := _bucket(_registry_registered, "ai_types")
	if not reg.has(id):
		push_warning("[Registry] remove('ai_types', '%s'): not registered by a mod" % id)
		return false
	if _registry_overridden.get("ai_types", {}).has(id):
		push_warning("[Registry] remove('ai_types', '%s'): entry is an override, use revert instead" % id)
		return false
	reg.erase(id)
	_rebuild_ai_engine_meta()
	_log_debug("[Registry] removed ai_type '%s'" % id)
	return true

func _revert_ai_type(id: String) -> bool:
	var ov := _bucket(_registry_overridden, "ai_types")
	if not ov.has(id):
		push_warning("[Registry] revert('ai_types', '%s'): no override to revert" % id)
		return false
	var entry: Dictionary = ov[id]
	var reg := _bucket(_registry_registered, "ai_types")
	reg.erase(id)
	for d in entry["displaced"]:
		reg[d["id"]] = d["entry"]
	if entry["previous"] is Dictionary:
		reg[id] = entry["previous"]
	ov.erase(id)
	_rebuild_ai_engine_meta()
	_log_debug("[Registry] reverted ai_type '%s' (restored %d displaced)" % [id, entry["displaced"].size()])
	return true
