## ----- registry/fish.gd -----
##
## Vanilla FishPool.gd is a MeshInstance3D placed in scenes (several per map)
## with an `@export var species: Array[PackedScene]` populated in the editor.
## At _ready() it picks 1-10 random fish from species and instantiates them.
##
## The rewriter injects a prelude at the top of FishPool._ready() that
## reads Engine.get_meta("_rtv_fish_species", []) and appends matching
## entries to the local `species` array before the random-spawn loop. So
## mods register once and every pool picks it up without editor edits.
##
## Data shape:
##   {scene: PackedScene, pool_id: String}
## where pool_id is either "all" (every FishPool instance gets this scene)
## or a specific Node name like "FP_2" (only that one pool).
##
## Verbs: register, remove, revert (remove alias). Override/patch not
## meaningful for a flat list of {scene, pool_id} tuples.
##
## Timing: FishPool is a scene Node, not an autoload. Its _ready() fires
## when its containing scene loads. Mods must register before entering the
## map scene; mod autoload _ready() is fine, as the main menu loads
## first and any map scene comes later.

const _FISH_ENGINE_META_KEY := "_rtv_fish_species"

func _rebuild_fish_engine_meta() -> void:
	# Flatten all id registrations into a flat Array for the prelude loop.
	# Each entry is {scene, pool_id}. Preserving registration order keeps
	# behavior deterministic across mod load orders (prelude appends in
	# array order; dedupe by scene ensures same scene via multiple ids
	# doesn't multiply spawn weight).
	var flat: Array = []
	var reg: Dictionary = _registry_registered.get("fish_species", {})
	for id in reg.keys():
		flat.append(reg[id])
	Engine.set_meta(_FISH_ENGINE_META_KEY, flat)

func _register_fish_species(id: String, data: Variant) -> bool:
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
	# Default pool_id to "all" if not given; most mods want their fish
	# in every pool. Explicit pool names override for fine-grained placement.
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
