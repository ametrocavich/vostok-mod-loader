## ----- registry/ai.gd -----
##
## Vanilla AISpawner.gd hardcodes a zone -> agent-scene mapping:
##   if zone == Zone.Area05: agent = bandit
##   elif zone == Zone.BorderZone: agent = guard
##   elif zone == Zone.Vostok: agent = military
##
## The rewriter transforms each `agent = <name>` into
##   agent = _rtv_resolve_ai_type(zone, <name>)
## where the resolver (injected into AISpawner.gd) reads
##   Engine.get_meta("_rtv_ai_overrides", {})
## and returns the mod-registered PackedScene for the current zone (or the
## vanilla scene if no override is registered).
##
## Design choices:
##   - AISpawner is a per-scene Node3D, not an autoload. There can be many
##     instances, each running _ready() independently. We use Engine.meta
##     to broadcast overrides to all of them.
##   - Zone keys are String names matching the Zone enum ("Area05",
##     "BorderZone", "Vostok"). The resolver uses Zone.keys()[zone_int] to
##     convert back at lookup time.
##   - Only override is meaningful here: a single agent scene per zone.
##     Register "adds a new entry" is semantically the same as override
##     for this registry, so we expose both verbs but they share a slot.
##
## Data shape:
##   {scene: PackedScene, zone: String}

const _VALID_ZONES := ["Area05", "BorderZone", "Vostok"]

# Keep the overrides we install in Engine meta, keyed by zone name, so the
# injected resolver on every AISpawner instance finds them. Each id in
# _registry_registered tracks a {scene, zone} payload; the engine-meta dict
# is derived from those registrations at each write.
const _AI_ENGINE_META_KEY := "_rtv_ai_overrides"

func _rebuild_ai_engine_meta() -> void:
	# Collapse all active id registrations into a single zone -> scene dict
	# for the resolver. If multiple mods register/override the same zone,
	# the last write wins; same semantics as other registries that share
	# a slot.
	var flat: Dictionary = {}
	var reg: Dictionary = _registry_registered.get("ai_types", {})
	for id in reg.keys():
		var entry: Dictionary = reg[id]
		flat[entry["zone"]] = entry["scene"]
	Engine.set_meta(_AI_ENGINE_META_KEY, flat)

func _validate_ai_type_data(id: String, verb: String, data: Variant) -> Array:
	# Returns [scene, zone] on success, [null, ""] on error.
	if not (data is Dictionary):
		push_warning("[Registry] %s('ai_types', '%s', ...) expects Dictionary {scene, zone}, got %s" % [verb, id, typeof(data)])
		return [null, ""]
	var d: Dictionary = data
	if not d.has("scene") or not d.has("zone"):
		push_warning("[Registry] %s('ai_types', '%s', ...) data dict missing 'scene' or 'zone' key" % [verb, id])
		return [null, ""]
	var scene = d["scene"]
	if not (scene is PackedScene):
		push_warning("[Registry] %s('ai_types', '%s'): scene is not a PackedScene" % [verb, id])
		return [null, ""]
	var zone = d["zone"]
	if not (zone is String):
		push_warning("[Registry] %s('ai_types', '%s'): zone must be a String (e.g. 'Area05')" % [verb, id])
		return [null, ""]
	if not (zone in _VALID_ZONES):
		push_warning("[Registry] %s('ai_types', '%s'): unknown zone '%s' (valid: %s)" % [verb, id, zone, _VALID_ZONES])
		return [null, ""]
	return [scene, zone]

func _register_ai_type(id: String, data: Variant) -> bool:
	var reg: Dictionary = _registry_registered.get("ai_types", {})
	if reg.has(id):
		push_warning("[Registry] register('ai_types', '%s'): already registered (pick a unique handle or use override)" % id)
		return false
	var parts := _validate_ai_type_data(id, "register", data)
	var scene = parts[0]
	var zone: String = parts[1]
	if scene == null:
		return false
	# Collision: another mod already claimed this zone. Register is one-per-
	# zone; use override to forcibly replace someone else's claim.
	for existing_id in reg.keys():
		if reg[existing_id]["zone"] == zone:
			push_warning("[Registry] register('ai_types', '%s'): zone '%s' already claimed by '%s'; use override to replace" % [id, zone, existing_id])
			return false
	reg[id] = {"scene": scene, "zone": zone}
	_registry_registered["ai_types"] = reg
	_rebuild_ai_engine_meta()
	_log_debug("[Registry] registered ai_type '%s' (zone=%s)" % [id, zone])
	return true

func _override_ai_type(id: String, data: Variant) -> bool:
	# Override is semantically "claim this zone even if another mod did."
	# It drops any conflicting registrations from other mods and installs
	# this one. On revert, the displaced registrations come back.
	var ov: Dictionary = _registry_overridden.get("ai_types", {})
	if ov.has(id):
		push_warning("[Registry] override('ai_types', '%s'): already overridden (revert first)" % id)
		return false
	var parts := _validate_ai_type_data(id, "override", data)
	var scene = parts[0]
	var zone: String = parts[1]
	if scene == null:
		return false
	var reg: Dictionary = _registry_registered.get("ai_types", {})
	# Stash displaced registrations so revert can restore them.
	var displaced: Array = []
	for existing_id in reg.keys():
		if reg[existing_id]["zone"] == zone:
			displaced.append({"id": existing_id, "entry": reg[existing_id]})
	for entry in displaced:
		reg.erase(entry["id"])
	reg[id] = {"scene": scene, "zone": zone}
	_registry_registered["ai_types"] = reg
	ov[id] = {"displaced": displaced, "zone": zone}
	_registry_overridden["ai_types"] = ov
	_rebuild_ai_engine_meta()
	_log_debug("[Registry] overrode ai_type '%s' (zone=%s, displaced %d entry/entries)" % [id, zone, displaced.size()])
	return true

func _remove_ai_type(id: String) -> bool:
	var reg: Dictionary = _registry_registered.get("ai_types", {})
	if not reg.has(id):
		push_warning("[Registry] remove('ai_types', '%s'): not registered by a mod" % id)
		return false
	var ov: Dictionary = _registry_overridden.get("ai_types", {})
	if ov.has(id):
		push_warning("[Registry] remove('ai_types', '%s'): entry is an override, use revert instead" % id)
		return false
	reg.erase(id)
	_registry_registered["ai_types"] = reg
	_rebuild_ai_engine_meta()
	_log_debug("[Registry] removed ai_type '%s'" % id)
	return true

func _revert_ai_type(id: String) -> bool:
	var ov: Dictionary = _registry_overridden.get("ai_types", {})
	if not ov.has(id):
		push_warning("[Registry] revert('ai_types', '%s'): no override to revert" % id)
		return false
	var entry: Dictionary = ov[id]
	var reg: Dictionary = _registry_registered.get("ai_types", {})
	# Drop the override entry and restore anything it displaced.
	reg.erase(id)
	var displaced: Array = entry["displaced"]
	for d in displaced:
		reg[d["id"]] = d["entry"]
	_registry_registered["ai_types"] = reg
	ov.erase(id)
	_registry_overridden["ai_types"] = ov
	_rebuild_ai_engine_meta()
	_log_debug("[Registry] reverted ai_type '%s' (restored %d displaced)" % [id, displaced.size()])
	return true
