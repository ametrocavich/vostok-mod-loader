## ai_loadouts: weapon scenes the injected AI.SelectWeapon prelude adds to an AI's `weapons` before
## vanilla picks; an AI matches when any of its categories (AIData faction or variant) is listed.

# The prelude rolls per entry independently, so the list order carries no
# meaning and several mods stack additively.
const _AI_LOADOUTS_ENGINE_META_KEY := "_rtv_ai_loadouts"
const _VALID_AI_CATEGORIES := ["Nomad", "Bandit", "Guard", "Military", "Boss", "Punisher", "Bogeyman"]

# The stored entry (scene resolved, categories canonical, chance clamped), or {} after a warning.
func _ai_loadout_entry(id: String, verb: String, data: Variant) -> Dictionary:
	if not (data is Dictionary):
		push_warning("[Registry] %s('ai_loadouts', '%s', ...) expects Dictionary, got %s" % [verb, id, type_string(typeof(data))])
		return {}
	var d: Dictionary = data
	for required in ["weapon_scene", "ai_types"]:
		if not d.has(required):
			push_warning("[Registry] %s('ai_loadouts', '%s'): missing required key '%s'" % [verb, id, required])
			return {}
	var scene: Variant = d["weapon_scene"]
	if scene is String:
		var db := _autoload_node("Database", false)
		scene = db.get(scene) if db != null else null
	if not (scene is PackedScene):
		push_warning("[Registry] %s('ai_loadouts', '%s'): weapon_scene didn't resolve to a PackedScene (got %s)" % [verb, id, d["weapon_scene"]])
		return {}
	var raw_types: Variant = d["ai_types"]
	if not (raw_types is Array):
		push_warning("[Registry] %s('ai_loadouts', '%s'): ai_types must be an Array of Strings" % [verb, id])
		return {}
	if raw_types.is_empty():
		push_warning("[Registry] %s('ai_loadouts', '%s'): ai_types is empty (must contain at least one of: %s)" % [verb, id, _VALID_AI_CATEGORIES])
		return {}
	var ai_types: Array[String] = []
	for raw in raw_types:
		var canon := ""
		if raw is String:
			var lowered: String = raw.strip_edges().to_lower()
			for category in _VALID_AI_CATEGORIES:
				if lowered == category.to_lower():
					canon = category
		if canon == "":
			push_warning("[Registry] %s('ai_loadouts', '%s'): unknown ai_type '%s'; valid: %s" % [verb, id, raw, _VALID_AI_CATEGORIES])
			return {}
		if not (canon in ai_types):
			ai_types.append(canon)
	var chance: float = _parse_ai_chance(d["chance"], id, verb) if d.has("chance") else 1.0
	var replace: Variant = d.get("replace", false)
	if not (replace is bool or replace is int or replace is float):
		push_warning("[Registry] %s('ai_loadouts', '%s'): replace must be a bool; using false" % [verb, id])
		replace = false
	return {
		"weapon_scene": scene,
		"ai_types": ai_types,
		"chance": chance,
		"replace": bool(replace),
	}

# Out of range warns and clamps: 0.0 is a wired-but-disabled entry, above 1.0 always fires.
func _parse_ai_chance(raw: Variant, id: String, verb: String) -> float:
	if raw is String:
		# Junk parses as 0.0 ("50%" as 50.0, clamped): the 1.0 default would make it always fire.
		var chance_str := (raw as String).strip_edges()
		if not chance_str.is_valid_float():
			push_warning("[Registry] %s('ai_loadouts', '%s'): non-numeric chance string '%s' -- parsed as %s" % [verb, id, raw, chance_str.to_float()])
		raw = chance_str.to_float()
	# bool included: `chance: false` is the disabled pattern, and bool does not
	# match `is int` in GDScript.
	if raw is float or raw is int or raw is bool:
		var chance := clampf(float(raw), 0.0, 1.0)
		if float(raw) < 0.0 or float(raw) > 1.0:
			push_warning("[Registry] %s('ai_loadouts', '%s'): chance %s clamped to %s" % [verb, id, raw, chance])
		return chance
	push_warning("[Registry] %s('ai_loadouts', '%s'): chance must be a number, got %s; using 1.0" % [verb, id, type_string(typeof(raw))])
	return 1.0

func _register_ai_loadout(id: String, data: Variant) -> bool:
	if _registry_target_inert("AI.gd", "register('ai_loadouts', '%s')" % id):
		return false
	var reg := _bucket(_registry_registered, "ai_loadouts")
	if reg.has(id):
		push_warning("[Registry] register('ai_loadouts', '%s'): already registered (pick a unique id or use override)" % id)
		return false
	var entry := _ai_loadout_entry(id, "register", data)
	if entry.is_empty():
		return false
	reg[id] = entry
	_publish_registry_meta("ai_loadouts", _AI_LOADOUTS_ENGINE_META_KEY)
	_log_debug("[Registry] registered ai_loadout '%s' (ai_types=%s, chance=%.2f, replace=%s)" % [id, entry["ai_types"], entry["chance"], entry["replace"]])
	return true

func _override_ai_loadout(id: String, data: Variant) -> bool:
	if _registry_target_inert("AI.gd", "override('ai_loadouts', '%s')" % id):
		return false
	var reg := _bucket(_registry_registered, "ai_loadouts")
	if not reg.has(id):
		push_warning("[Registry] override('ai_loadouts', '%s'): no existing entry to override" % id)
		return false
	var ov := _bucket(_registry_overridden, "ai_loadouts")
	if ov.has(id):
		push_warning("[Registry] override('ai_loadouts', '%s'): already overridden (revert first)" % id)
		return false
	var entry := _ai_loadout_entry(id, "override", data)
	if entry.is_empty():
		return false
	ov[id] = reg[id]
	reg[id] = entry
	_publish_registry_meta("ai_loadouts", _AI_LOADOUTS_ENGINE_META_KEY)
	_log_debug("[Registry] overrode ai_loadout '%s'" % id)
	return true

func _remove_ai_loadout(id: String) -> bool:
	var reg := _bucket(_registry_registered, "ai_loadouts")
	if not reg.has(id):
		push_warning("[Registry] remove('ai_loadouts', '%s'): not registered by a mod" % id)
		return false
	if _registry_overridden.get("ai_loadouts", {}).has(id):
		push_warning("[Registry] remove('ai_loadouts', '%s'): entry is overridden, use revert instead" % id)
		return false
	reg.erase(id)
	_publish_registry_meta("ai_loadouts", _AI_LOADOUTS_ENGINE_META_KEY)
	_log_debug("[Registry] removed ai_loadout '%s'" % id)
	return true

func _revert_ai_loadout(id: String) -> bool:
	var ov := _bucket(_registry_overridden, "ai_loadouts")
	if not ov.has(id):
		push_warning("[Registry] revert('ai_loadouts', '%s'): no override to revert" % id)
		return false
	_bucket(_registry_registered, "ai_loadouts")[id] = ov[id]
	ov.erase(id)
	_publish_registry_meta("ai_loadouts", _AI_LOADOUTS_ENGINE_META_KEY)
	_log_debug("[Registry] reverted ai_loadout '%s'" % id)
	return true
