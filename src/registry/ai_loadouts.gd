## ----- registry/ai_loadouts.gd -----
## Per-AI-category weapon injection. Vanilla AI scenes bake their weapon
## list as preloaded children of `weapons: Node3D` and AI.SelectWeapon()
## picks one; the rewriter adds a SelectWeapon prelude that reads
## Engine.get_meta("_rtv_ai_loadouts") (a flat list rebuilt by
## _rebuild_ai_loadouts_engine_meta) and injects weapon scene instances
## into `weapons` before vanilla picks. Mirrors registry/ai.gd.
##
## Input shape: {weapon_scene: PackedScene|String (Database id),
##   ai_types: Array[String] subset of [Bandit, Guard, Military, Punisher],
##   chance?: float clamped [0,1] (default 1.0), replace?: bool}.
## Stored shape is the same, canonicalized: weapon_scene always a ref,
## ai_types canonical CamelCase, chance clamped.

const _AI_LOADOUTS_ENGINE_META_KEY := "_rtv_ai_loadouts"
const _VALID_AI_CATEGORIES := ["Bandit", "Guard", "Military", "Punisher"]

func _rebuild_ai_loadouts_engine_meta() -> void:
	# Flat list: the prelude rolls per-entry independently, so order carries
	# no meaning and multiple mods stack additively.
	var flat: Array = []
	var reg: Dictionary = _registry_registered.get("ai_loadouts", {})
	for id in reg.keys():
		flat.append(reg[id])
	Engine.set_meta(_AI_LOADOUTS_ENGINE_META_KEY, flat)

# Case-insensitive match against the valid categories; returns the
# canonical String or "".
func _canonicalize_ai_category(raw: Variant) -> String:
	if not (raw is String):
		return ""
	var s: String = (raw as String).strip_edges()
	if s == "":
		return ""
	for canon in _VALID_AI_CATEGORIES:
		if s.to_lower() == canon.to_lower():
			return canon
	return ""

# Resolve a String id to a PackedScene via the Database autoload (the same
# lookup vanilla uses). Returns null on miss.
func _resolve_scene_ref(ref: Variant) -> PackedScene:
	if ref is PackedScene:
		return ref
	if ref is String:
		var db = get_tree().root.get_node_or_null("Database")
		if db == null:
			return null
		var resolved = db.get(ref as String)
		if resolved is PackedScene:
			return resolved
	return null

# Validate + canonicalize input. Returns the stored-shape Dictionary, or
# null after warning. `verb` is warn-message context only.
func _validate_ai_loadout_data(id: String, verb: String, data: Variant):
	if not (data is Dictionary):
		push_warning("[Registry] %s('ai_loadouts', '%s', ...) expects Dictionary, got %s" % [verb, id, typeof(data)])
		return null
	var d: Dictionary = data
	for required in ["weapon_scene", "ai_types"]:
		if not d.has(required):
			push_warning("[Registry] %s('ai_loadouts', '%s'): missing required key '%s'" % [verb, id, required])
			return null
	var scene := _resolve_scene_ref(d["weapon_scene"])
	if scene == null:
		push_warning("[Registry] %s('ai_loadouts', '%s'): weapon_scene didn't resolve to a PackedScene (got %s)" % [verb, id, d["weapon_scene"]])
		return null
	# Reject the whole call on any unrecognized ai_type so authors see typos
	# at register time, not at runtime when nothing spawns.
	var raw_types: Variant = d["ai_types"]
	if not (raw_types is Array):
		push_warning("[Registry] %s('ai_loadouts', '%s'): ai_types must be an Array of Strings" % [verb, id])
		return null
	if (raw_types as Array).is_empty():
		push_warning("[Registry] %s('ai_loadouts', '%s'): ai_types is empty (must contain at least one of: %s)" % [verb, id, _VALID_AI_CATEGORIES])
		return null
	var canonical_types: Array[String] = []
	for raw in (raw_types as Array):
		var canon := _canonicalize_ai_category(raw)
		if canon == "":
			# Show what capitalization would have produced so the author can
			# tell a typo from an unknown category.
			var hint: String = ""
			if raw is String:
				hint = " (canonicalized to '%s')" % (raw as String).capitalize()
			push_warning("[Registry] %s('ai_loadouts', '%s'): unknown ai_type '%s'%s; valid: %s" % [verb, id, raw, hint, _VALID_AI_CATEGORIES])
			return null
		if not (canon in canonical_types):
			canonical_types.append(canon)
	# chance: out-of-range warns but doesn't reject. 0.0 is a legitimate
	# "wired but disabled" entry; >1.0 just always fires.
	var chance: float = 1.0
	if d.has("chance"):
		# Type-check first: float(null) is a runtime error in Godot 4, and
		# JSON-derived data routinely carries present-but-null keys.
		var raw_chance = d["chance"]
		if raw_chance is String:
			# String chances take String.to_float() semantics: whitespace-
			# tolerant, junk degrades ("abc" -> 0.0, "50%" -> 50.0, clamped
			# below). Falling back to the 1.0 default instead would turn
			# malformed input into always-fires.
			var chance_str := (raw_chance as String).strip_edges()
			if not chance_str.is_valid_float():
				push_warning("[Registry] %s('ai_loadouts', '%s'): non-numeric chance string '%s' -- parsed as %s" % [verb, id, raw_chance, chance_str.to_float()])
			raw_chance = chance_str.to_float()
		if raw_chance is float or raw_chance is int or raw_chance is bool:
			# bool included: chance: false -> 0.0 is the disabled pattern
			# above, and bool is not matched by `is int` in GDScript.
			chance = clampf(float(raw_chance), 0.0, 1.0)
			if float(raw_chance) < 0.0 or float(raw_chance) > 1.0:
				push_warning("[Registry] %s('ai_loadouts', '%s'): chance %s clamped to %s" % [verb, id, raw_chance, chance])
		else:
			push_warning("[Registry] %s('ai_loadouts', '%s'): chance must be a number, got %s; using 1.0" % [verb, id, typeof(raw_chance)])
	# replace is a sharp edge but legitimate (override a vanilla AI's
	# loadout entirely). Same present-but-null hole as chance.
	var replace: bool = false
	var raw_replace = d.get("replace", false)
	if raw_replace is bool:
		replace = raw_replace
	elif raw_replace is int or raw_replace is float:
		replace = bool(raw_replace)
	else:
		push_warning("[Registry] %s('ai_loadouts', '%s'): replace must be a bool; using false" % [verb, id])
	return {
		"weapon_scene": scene,
		"ai_types": canonical_types,
		"chance": chance,
		"replace": replace,
	}

func _register_ai_loadout(id: String, data: Variant) -> bool:
	if _registry_target_inert("AI.gd", "register('ai_loadouts', '%s')" % id):
		return false
	var reg: Dictionary = _registry_registered.get("ai_loadouts", {})
	if reg.has(id):
		push_warning("[Registry] register('ai_loadouts', '%s'): already registered (pick a unique id or use override)" % id)
		return false
	var entry = _validate_ai_loadout_data(id, "register", data)
	if entry == null:
		return false
	reg[id] = entry
	_registry_registered["ai_loadouts"] = reg
	_rebuild_ai_loadouts_engine_meta()
	_log_debug("[Registry] registered ai_loadout '%s' (ai_types=%s, chance=%.2f, replace=%s)" % [id, entry.ai_types, entry.chance, entry.replace])
	return true

func _override_ai_loadout(id: String, data: Variant) -> bool:
	if _registry_target_inert("AI.gd", "override('ai_loadouts', '%s')" % id):
		return false
	var reg: Dictionary = _registry_registered.get("ai_loadouts", {})
	if not reg.has(id):
		push_warning("[Registry] override('ai_loadouts', '%s'): no existing entry to override" % id)
		return false
	var ov: Dictionary = _registry_overridden.get("ai_loadouts", {})
	if ov.has(id):
		push_warning("[Registry] override('ai_loadouts', '%s'): already overridden (revert first)" % id)
		return false
	var entry = _validate_ai_loadout_data(id, "override", data)
	if entry == null:
		return false
	ov[id] = reg[id]
	_registry_overridden["ai_loadouts"] = ov
	reg[id] = entry
	_registry_registered["ai_loadouts"] = reg
	_rebuild_ai_loadouts_engine_meta()
	_log_debug("[Registry] overrode ai_loadout '%s'" % id)
	return true

func _remove_ai_loadout(id: String) -> bool:
	var reg: Dictionary = _registry_registered.get("ai_loadouts", {})
	if not reg.has(id):
		push_warning("[Registry] remove('ai_loadouts', '%s'): not registered by a mod" % id)
		return false
	var ov: Dictionary = _registry_overridden.get("ai_loadouts", {})
	if ov.has(id):
		push_warning("[Registry] remove('ai_loadouts', '%s'): entry is overridden, use revert instead" % id)
		return false
	reg.erase(id)
	_registry_registered["ai_loadouts"] = reg
	_rebuild_ai_loadouts_engine_meta()
	_log_debug("[Registry] removed ai_loadout '%s'" % id)
	return true

func _revert_ai_loadout(id: String) -> bool:
	var ov: Dictionary = _registry_overridden.get("ai_loadouts", {})
	if not ov.has(id):
		push_warning("[Registry] revert('ai_loadouts', '%s'): no override to revert" % id)
		return false
	var reg: Dictionary = _registry_registered.get("ai_loadouts", {})
	reg[id] = ov[id]
	_registry_registered["ai_loadouts"] = reg
	ov.erase(id)
	_registry_overridden["ai_loadouts"] = ov
	_rebuild_ai_loadouts_engine_meta()
	_log_debug("[Registry] reverted ai_loadout '%s'" % id)
	return true
