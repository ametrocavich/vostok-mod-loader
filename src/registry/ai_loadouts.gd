## ----- registry/ai_loadouts.gd -----
##
## Per-AI-category weapon injection. Mods register entries declaring
## "this weapon scene should appear in AI of these categories N% of the
## time." Vanilla AI scenes (Bandit, Guard, Military, Punisher) bake
## their weapon list as preloaded children of a `weapons: Node3D` and
## `AI.SelectWeapon()` picks one at random. We rewrite SelectWeapon
## with a one-line prelude that consults this registry's flat list and
## injects weapon scene instances into `weapons` before vanilla picks.
##
## Architecture mirrors registry/ai.gd:
##   - Per-id dict lives in _registry_registered["ai_loadouts"]
##   - _rebuild_ai_loadouts_engine_meta() flattens active entries into
##     Engine.set_meta("_rtv_ai_loadouts", [...]) which the rewriter
##     prelude reads at runtime
##   - Override stashes the prior entry in _registry_overridden so revert
##     can restore it
##
## Data shape (input):
##   {
##     weapon_scene: PackedScene | String,  # scene ref or id resolvable via Database
##     ai_types:     Array[String],         # subset of [Bandit, Guard, Military, Punisher]
##     chance:       float,                 # optional, default 1.0; clamped [0.0, 1.0]
##     replace:      bool,                  # optional, default false
##   }
##
## Data shape (stored, post-canonicalization):
##   {
##     weapon_scene: PackedScene,           # always a ref
##     ai_types:     Array[String],         # always canonical CamelCase
##     chance:       float,                 # always clamped
##     replace:      bool,
##   }

const _AI_LOADOUTS_ENGINE_META_KEY := "_rtv_ai_loadouts"
const _VALID_AI_CATEGORIES := ["Bandit", "Guard", "Military", "Punisher"]

func _rebuild_ai_loadouts_engine_meta() -> void:
	# Flat list, not a dict -- the runtime prelude iterates and rolls
	# per-entry independently, so per-entry order doesn't carry meaning.
	# Multiple mods stacking is the expected case; entries are additive.
	var flat: Array = []
	var reg: Dictionary = _registry_registered.get("ai_loadouts", {})
	for id in reg.keys():
		flat.append(reg[id])
	Engine.set_meta(_AI_LOADOUTS_ENGINE_META_KEY, flat)

# Returns the canonical category String if `raw` matches one of the four
# valid categories case-insensitively, else "". Used for input
# normalization so mod authors can write "bandit", "BANDIT", or "Bandit".
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
# lookup vanilla code uses). Returns null on miss; caller decides how to
# handle the error.
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

# Validate + canonicalize input. Returns the stored-shape Dictionary on
# success, null on validation failure (with a push_warning already
# emitted). Verb arg is just for warn message context.
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
	# ai_types: canonicalize each string; reject the whole call on any
	# unrecognized entry so authors see typos at register time, not at
	# runtime when nothing spawns.
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
			# Help the author by showing both the raw input and what
			# capitalize-style canonicalization would have produced, so
			# they can tell whether it was a typo vs an unknown category.
			var hint: String = ""
			if raw is String:
				hint = " (canonicalized to '%s')" % (raw as String).capitalize()
			push_warning("[Registry] %s('ai_loadouts', '%s'): unknown ai_type '%s'%s; valid: %s" % [verb, id, raw, hint, _VALID_AI_CATEGORIES])
			return null
		if not (canon in canonical_types):
			canonical_types.append(canon)
	# chance: optional, clamp to [0.0, 1.0]. Out-of-range warns but
	# doesn't reject -- a 0.0 entry is a no-op (legitimate "wired but
	# disabled" pattern) and a >1.0 entry just always fires.
	var chance: float = 1.0
	if d.has("chance"):
		chance = clampf(float(d["chance"]), 0.0, 1.0)
		if float(d["chance"]) < 0.0 or float(d["chance"]) > 1.0:
			push_warning("[Registry] %s('ai_loadouts', '%s'): chance %s clamped to %s" % [verb, id, d["chance"], chance])
	# replace: optional, default false. Document as a sharp edge in the
	# plan but don't reject -- some mods want to override a vanilla AI's
	# loadout entirely.
	var replace: bool = bool(d.get("replace", false))
	return {
		"weapon_scene": scene,
		"ai_types": canonical_types,
		"chance": chance,
		"replace": replace,
	}

func _register_ai_loadout(id: String, data: Variant) -> bool:
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
