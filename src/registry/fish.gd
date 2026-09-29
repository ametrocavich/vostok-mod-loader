## ----- registry/fish.gd -----
## Vanilla FishPool._ready() picks random fish from an editor-populated
## `species: Array[PackedScene]`. The rewriter injects a prelude that reads
## Engine.get_meta("_rtv_fish_species") and appends matching entries to
## `species` before the spawn loop, so one registration reaches every pool.
##
## Data: {scene: PackedScene, pool_id: String} -- pool_id "all" (default)
## or a specific pool Node name like "FP_2". Verbs: register, remove,
## revert (remove alias); override/patch aren't meaningful for a flat list.
##
## Timing: FishPool._ready() fires on map-scene load, so registering from a
## mod autoload _ready() is early enough (the main menu loads first).

const _FISH_ENGINE_META_KEY := "_rtv_fish_species"

func _rebuild_fish_engine_meta() -> void:
	# Flat {scene, pool_id} list in registration order for the prelude loop;
	# order keeps behavior deterministic across mod load orders.
	var flat: Array = []
	var reg: Dictionary = _registry_registered.get("fish_species", {})
	for id in reg.keys():
		flat.append(reg[id])
	Engine.set_meta(_FISH_ENGINE_META_KEY, flat)

func _register_fish_species(id: String, data: Variant) -> bool:
	if _registry_target_inert("FishPool.gd", "register('fish_species', '%s')" % id):
		return false
	var reg: Dictionary = _registry_registered.get("fish_species", {})
	if reg.has(id):
		push_warning("[Registry] register('fish_species', '%s'): already registered (pick a unique handle)" % id)
		return false
	if not (data is Dictionary):
		push_warning("[Registry] register('fish_species', '%s', ...) expects Dictionary {scene, pool_id}, got %s" % [id, typeof(data)])
		return false
	var d: Dictionary = data
	if not d.has("scene"):
		push_warning("[Registry] register('fish_species', '%s'): data missing 'scene' key" % id)
		return false
	var scene = d["scene"]
	if not (scene is PackedScene):
		push_warning("[Registry] register('fish_species', '%s'): scene is not a PackedScene" % id)
		return false
	# pool_id defaults to "all"; most mods want their fish in every pool.
	var pool_id: String = "all"
	if d.has("pool_id"):
		if not (d["pool_id"] is String):
			push_warning("[Registry] register('fish_species', '%s'): pool_id must be a String" % id)
			return false
		pool_id = d["pool_id"]
	reg[id] = {"scene": scene, "pool_id": pool_id}
	_registry_registered["fish_species"] = reg
	_rebuild_fish_engine_meta()
	_log_debug("[Registry] registered fish_species '%s' (pool_id=%s)" % [id, pool_id])
	return true

func _remove_fish_species(id: String) -> bool:
	var reg: Dictionary = _registry_registered.get("fish_species", {})
	if not reg.has(id):
		push_warning("[Registry] remove('fish_species', '%s'): not registered by a mod" % id)
		return false
	reg.erase(id)
	_registry_registered["fish_species"] = reg
	_rebuild_fish_engine_meta()
	_log_debug("[Registry] removed fish_species '%s'" % id)
	return true
