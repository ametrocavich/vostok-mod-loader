## ----- registry/loader.gd -----
## Three registries that mutate state on the Loader autoload. The rewriter
## injects into Loader.gd: _rtv_mod_scene_paths / _rtv_override_scene_paths,
## the _rtv_vanilla_shelters snapshot, `shelters` rewritten const->var, and
## a LoadScene prelude that checks the dicts and sets scenePath + gameData
## flags before the vanilla if-elif. Loader is an autoload, so the prelude
## is active from boot; registering from mod _ready() is safe.
##
## - scene_paths: named scene lookups with optional gameData flags.
##     register/override: {path: String, menu?, shelter?, permadeath?,
##     tutorial?}; patch/remove/revert: standard.
## - shelters: append-only list of shelter names. Pass {path, ...} to
##   auto-register a paired scene_paths entry, or {} if the name already
##   resolves. remove also cleans the auto-linked scene_paths entry.
## - random_scenes: append-only res:// paths on Loader.randomScenes
##   (picked by LoadSceneRandom()). register: {path: String}.

func _loader_node() -> Node:
	var ldr = get_tree().root.get_node_or_null("Loader")
	if ldr == null:
		push_warning("[Registry] Loader autoload not in tree yet; is the loader still booting?")
	return ldr

# Checks `id` against the vanilla scene-path consts on Loader.gd, read via
# get_script_constant_map() (there is no has_script_constant API).
var _vanilla_scene_const_cache: Dictionary = {}
var _vanilla_scene_const_built: bool = false
func _vanilla_scene_const_exists(ldr: Node, id: String) -> bool:
	if not _vanilla_scene_const_built:
		var script = ldr.get_script()
		if script != null:
			_vanilla_scene_const_cache = script.get_script_constant_map()
		_vanilla_scene_const_built = true
	return _vanilla_scene_const_cache.has(id)

# Reject a scene path that doesn't resolve. Registration is the last
# recoverable point: once a bad path reaches gameData.scenePath, vanilla
# discards change_scene_to_file's error, isTransitioning never clears, and
# the loading screen freezes with no way back but force-quit.
func _scene_path_exists(verb: String, kind: String, id: String, path: String) -> bool:
	if ResourceLoader.exists(path):
		return true
	push_warning("[Registry] %s('%s', '%s'): scene '%s' does not exist -- not registered. A missing scene freezes the loading screen with no way back to the menu, so this is refused rather than deferred to runtime. Check the path and that the file shipped in your mod archive." \
			% [verb, kind, id, path])
	return false

# -------- scene_paths --------

func _register_scene_path(id: String, data: Variant) -> bool:
	if not (data is Dictionary):
		push_warning("[Registry] register('scene_paths', '%s', ...) expects Dictionary, got %s" % [id, typeof(data)])
		return false
	var d: Dictionary = data
	if not d.has("path") or not (d["path"] is String):
		push_warning("[Registry] register('scene_paths', '%s'): data requires string 'path' key" % id)
		return false
	if not _scene_path_exists("register", "scene_paths", id, d["path"]):
		return false
	var ldr := _loader_node()
	if ldr == null:
		return false
	if not ("_rtv_mod_scene_paths" in ldr):
		push_warning("[Registry] register('scene_paths'): Loader.gd is missing injected scene-path fields; rewriter didn't fire, is the hook pack installed?")
		return false
	if ldr._rtv_mod_scene_paths.has(id) or ldr._rtv_override_scene_paths.has(id):
		push_warning("[Registry] register('scene_paths', '%s'): already registered/overridden by a mod" % id)
		return false
	# Vanilla scene names are const identifiers on Loader (Cabin, Attic,
	# ...); reject collisions so mods use override() instead.
	if _vanilla_scene_const_exists(ldr, id):
		push_warning("[Registry] register('scene_paths', '%s'): name collides with a vanilla scene const; use override instead" % id)
		return false
	ldr._rtv_mod_scene_paths[id] = d
	var reg: Dictionary = _registry_registered.get("scene_paths", {})
	reg[id] = d
	_registry_registered["scene_paths"] = reg
	_log_debug("[Registry] registered scene_path '%s' -> %s" % [id, d.get("path")])
	return true

func _override_scene_path(id: String, data: Variant) -> bool:
	if not (data is Dictionary):
		push_warning("[Registry] override('scene_paths', '%s', ...) expects Dictionary, got %s" % [id, typeof(data)])
		return false
	var d: Dictionary = data
	if not d.has("path") or not (d["path"] is String):
		push_warning("[Registry] override('scene_paths', '%s'): data requires string 'path' key" % id)
		return false
	if not _scene_path_exists("override", "scene_paths", id, d["path"]):
		return false
	var ldr := _loader_node()
	if ldr == null:
		return false
	if not ("_rtv_override_scene_paths" in ldr):
		push_warning("[Registry] override('scene_paths'): Loader.gd is missing injected fields")
		return false
	# Target must exist. Overriding mod entries is allowed for same-id
	# conflict resolution between mods.
	var is_vanilla_const: bool = _vanilla_scene_const_exists(ldr, id)
	var is_mod_registration: bool = ldr._rtv_mod_scene_paths.has(id)
	if not is_vanilla_const and not is_mod_registration:
		push_warning("[Registry] override('scene_paths', '%s'): no vanilla scene const or mod registration with that name" % id)
		return false
	var ov: Dictionary = _registry_overridden.get("scene_paths", {})
	if not ov.has(id):
		# Vanilla flags aren't knowable without replicating the if-elif, so
		# stash minimally; revert clears the override and vanilla restores.
		if is_vanilla_const:
			ov[id] = {"vanilla": true}
		else:
			ov[id] = {"vanilla": false, "data": ldr._rtv_mod_scene_paths[id]}
		_registry_overridden["scene_paths"] = ov
	ldr._rtv_override_scene_paths[id] = d
	_log_debug("[Registry] overrode scene_path '%s'" % id)
	return true

func _patch_scene_path(id: String, fields: Dictionary) -> bool:
	if fields.is_empty():
		push_warning("[Registry] patch('scene_paths', '%s'): empty fields is a no-op" % id)
		return false
	var ldr := _loader_node()
	if ldr == null:
		return false
	if not ("_rtv_mod_scene_paths" in ldr) or not ("_rtv_override_scene_paths" in ldr):
		push_warning("[Registry] patch('scene_paths', '%s'): Loader.gd is missing injected scene-path fields; rewriter didn't fire, is the hook pack installed?" % id)
		return false
	# Override first, then mod registration.
	var target_dict: Dictionary
	var target_store: String  # "override" or "mod"
	if ldr._rtv_override_scene_paths.has(id):
		target_dict = ldr._rtv_override_scene_paths[id]
		target_store = "override"
	elif ldr._rtv_mod_scene_paths.has(id):
		target_dict = ldr._rtv_mod_scene_paths[id]
		target_store = "mod"
	else:
		push_warning("[Registry] patch('scene_paths', '%s'): no mod registration or override to patch" % id)
		return false
	var patched: Dictionary = _registry_patched.get("scene_paths", {})
	var stash: Dictionary = patched.get(id, {})
	for field in fields.keys():
		var fname := String(field)
		if not stash.has(fname):
			# Record whether the key existed so revert can erase vs restore.
			if target_dict.has(fname):
				stash[fname] = target_dict[fname]
			else:
				stash[fname] = "__rtv_missing__"
		target_dict[fname] = fields[field]
	# Dicts are references; the re-store is redundant but explicit.
	if target_store == "override":
		ldr._rtv_override_scene_paths[id] = target_dict
	else:
		ldr._rtv_mod_scene_paths[id] = target_dict
		# Mirror into the loader-side _registry_registered for get_entry.
		var reg: Dictionary = _registry_registered.get("scene_paths", {})
		reg[id] = target_dict
		_registry_registered["scene_paths"] = reg
	patched[id] = stash
	_registry_patched["scene_paths"] = patched
	return true

func _remove_scene_path(id: String) -> bool:
	var ldr := _loader_node()
	if ldr == null:
		return false
	var reg: Dictionary = _registry_registered.get("scene_paths", {})
	if not reg.has(id):
		push_warning("[Registry] remove('scene_paths', '%s'): not a mod registration" % id)
		return false
	var ov: Dictionary = _registry_overridden.get("scene_paths", {})
	if ov.has(id):
		push_warning("[Registry] remove('scene_paths', '%s'): entry is an override, use revert instead" % id)
		return false
	ldr._rtv_mod_scene_paths.erase(id)
	reg.erase(id)
	_registry_registered["scene_paths"] = reg
	# Drop the patch stash with the entry: its originals belong to this
	# incarnation and would corrupt a later re-registration of the id.
	var patched: Dictionary = _registry_patched.get("scene_paths", {})
	if patched.has(id):
		patched.erase(id)
		_registry_patched["scene_paths"] = patched
	_log_debug("[Registry] removed scene_path '%s'" % id)
	return true

func _revert_scene_path(id: String, fields: Array) -> bool:
	var ldr := _loader_node()
	if ldr == null:
		return false
	var did_something := false
	var ov: Dictionary = _registry_overridden.get("scene_paths", {})
	var patched: Dictionary = _registry_patched.get("scene_paths", {})
	# GDScript is function-scoped: declaring these in both branches below
	# would shadow, so declare once up front.
	var target_dict: Dictionary
	var stash: Dictionary
	if fields.is_empty():
		# Patches first (onto whatever dict is current).
		if patched.has(id):
			stash = patched[id]
			if ldr._rtv_override_scene_paths.has(id):
				target_dict = ldr._rtv_override_scene_paths[id]
			elif ldr._rtv_mod_scene_paths.has(id):
				target_dict = ldr._rtv_mod_scene_paths[id]
			for fname in stash.keys():
				# Gate the sentinel check by type: bool == String raises a
				# runtime error under strict GDScript.
				var stashed_val = stash[fname]
				if stashed_val is String and stashed_val == "__rtv_missing__":
					target_dict.erase(fname)
				else:
					target_dict[fname] = stashed_val
			patched.erase(id)
			_registry_patched["scene_paths"] = patched
			did_something = true
		if ov.has(id):
			ldr._rtv_override_scene_paths.erase(id)
			ov.erase(id)
			_registry_overridden["scene_paths"] = ov
			did_something = true
		if not did_something:
			push_warning("[Registry] revert('scene_paths', '%s'): nothing to revert" % id)
		return did_something
	# Per-field patch revert.
	if not patched.has(id):
		push_warning("[Registry] revert('scene_paths', '%s', %s): no patches on this id" % [id, fields])
		return false
	if ldr._rtv_override_scene_paths.has(id):
		target_dict = ldr._rtv_override_scene_paths[id]
	elif ldr._rtv_mod_scene_paths.has(id):
		target_dict = ldr._rtv_mod_scene_paths[id]
	else:
		push_warning("[Registry] revert('scene_paths', '%s'): id no longer resolves" % id)
		return false
	stash = patched[id]
	for field in fields:
		var fname := String(field)
		if not stash.has(fname):
			push_warning("[Registry] revert('scene_paths', '%s'): field '%s' wasn't patched" % [id, fname])
			continue
		var stashed_val = stash[fname]
		if stashed_val is String and stashed_val == "__rtv_missing__":
			target_dict.erase(fname)
		else:
			target_dict[fname] = stashed_val
		stash.erase(fname)
		did_something = true
	if stash.is_empty():
		patched.erase(id)
	else:
		patched[id] = stash
	_registry_patched["scene_paths"] = patched
	return did_something

# -------- shelters / maps --------
#
# Shelters and maps share storage and differ only in the default `shelter`
# flag. That flag controls both gameData.shelter (LoadScene prelude) and
# the Loader.LoadShelter(name) call in Compiler.Spawn() that loads/saves
# per-shelter persistent state -- maps don't get the latter.
#
# Schema (all optional except `path` for newly-added scenes):
#   path             -- res:// .tscn (auto-registers scene_paths)
#   transition_text  -- "Loading X..." label override (defaults to id)
#   exit_spawn       -- transition node to spawn at when arriving
#   entrance_spawn   -- transition node in `connected_to` when leaving
#   connected_to     -- vanilla map name holding this shelter's entrance
#   connected_content -- Array of {path, position, rotation} spawned into
#                        /root/Map/Content when player enters connected_to
#   shelter          -- bool, default true for shelters / false for maps
# Mirrors the B_Loader mod's add_shelter/add_map dict so B_Loader-pattern
# mods migrate by changing one call site.

func _register_shelter(id: String, data: Variant) -> bool:
	return _register_shelter_or_map(id, data, true, "shelters")

func _register_map(id: String, data: Variant) -> bool:
	return _register_shelter_or_map(id, data, false, "maps")

func _register_shelter_or_map(id: String, data: Variant, default_shelter: bool, label: String) -> bool:
	var ldr := _loader_node()
	if ldr == null:
		return false
	if not (data is Dictionary):
		push_warning("[Registry] register('%s', '%s', ...) expects Dictionary (can be empty if scene already registered)" % [label, id])
		return false
	var d: Dictionary = data
	# Shared bucket makes cross-surface collisions fail loud (a name can
	# only resolve to one entry in Compiler.Spawn).
	var reg: Dictionary = _registry_registered.get("shelters", {})
	if reg.has(id):
		push_warning("[Registry] register('%s', '%s'): already registered as shelter or map" % [label, id])
		return false
	if id in ldr.shelters:
		push_warning("[Registry] register('%s', '%s'): name already in shelters list (vanilla?)" % [label, id])
		return false
	# Build the entry the Compiler.Spawn prelude reads. .get's default only
	# covers absent keys; a present-but-null value would crash a constructor
	# or store a null Array the prelude chokes on, hence the type checks.
	var is_shelter: bool = d.get("shelter", default_shelter) == true
	var tt = d.get("transition_text", id)
	var cc = d.get("connected_content", [])
	if not (cc is Array):
		push_warning("[Registry] register('%s', '%s'): connected_content must be an Array; ignoring" % [label, id])
		cc = []
	var entry: Dictionary = {
		"shelter": is_shelter,
		"transition_text": tt if tt is String else str(tt) if tt != null else id,
		"exit_spawn": str(d.get("exit_spawn", "")) if d.get("exit_spawn") != null else "",
		"entrance_spawn": str(d.get("entrance_spawn", "")) if d.get("entrance_spawn") != null else "",
		"connected_to": str(d.get("connected_to", "")) if d.get("connected_to") != null else "",
		"connected_content": cc,
	}
	# If `path` is given, auto-register the paired scene_paths entry so
	# LoadScene(name) resolves; forward the shelter flag and gameData fields.
	var auto_scene_path := false
	if d.has("path"):
		var sp_data: Dictionary = {}
		sp_data["path"] = d["path"]
		sp_data["shelter"] = is_shelter
		if d.has("menu"): sp_data["menu"] = d["menu"]
		if d.has("permadeath"): sp_data["permadeath"] = d["permadeath"]
		if d.has("tutorial"): sp_data["tutorial"] = d["tutorial"]
		# The LoadScene prelude reassigns the `scene` arg from
		# transition_text so vanilla's label code shows the modded label.
		sp_data["transition_text"] = entry["transition_text"]
		if not _register_scene_path(id, sp_data):
			return false
		auto_scene_path = true
	ldr.shelters.append(id)
	# Compiler.Spawn's prelude consults this injected dict.
	if "_rtv_mod_shelters" in ldr:
		ldr._rtv_mod_shelters[id] = entry
	else:
		push_warning("[Registry] register('%s', '%s'): Loader is missing _rtv_mod_shelters; rewriter didn't fire. Does any mod declare [registry]?" % [label, id])
	reg[id] = {"auto_scene_path": auto_scene_path, "entry": entry, "kind": label}
	_registry_registered["shelters"] = reg
	_log_debug("[Registry] registered %s '%s' (shelter=%s, connected_to='%s')" \
			% [label, id, is_shelter, entry["connected_to"]])
	return true

func _remove_shelter(id: String) -> bool:
	return _remove_shelter_or_map(id, "shelters")

func _remove_map(id: String) -> bool:
	return _remove_shelter_or_map(id, "maps")

func _remove_shelter_or_map(id: String, label: String) -> bool:
	var ldr := _loader_node()
	if ldr == null:
		return false
	var reg: Dictionary = _registry_registered.get("shelters", {})
	if not reg.has(id):
		push_warning("[Registry] remove('%s', '%s'): not a mod registration" % [label, id])
		return false
	var meta: Dictionary = reg[id]
	# Cross-surface guard: remove('maps', X) must not remove a shelter.
	if meta.get("kind", "shelters") != label:
		push_warning("[Registry] remove('%s', '%s'): id was registered as '%s', use that registry to remove" \
				% [label, id, meta.get("kind", "shelters")])
		return false
	var idx: int = ldr.shelters.find(id)
	if idx >= 0:
		ldr.shelters.remove_at(idx)
	if meta.get("auto_scene_path", false):
		_remove_scene_path(id)
	if "_rtv_mod_shelters" in ldr:
		ldr._rtv_mod_shelters.erase(id)
	reg.erase(id)
	_registry_registered["shelters"] = reg
	_log_debug("[Registry] removed %s '%s'" % [label, id])
	return true

# -------- random_scenes --------

func _register_random_scene(id: String, data: Variant) -> bool:
	var ldr := _loader_node()
	if ldr == null:
		return false
	if not (data is Dictionary) or not data.has("path") or not (data["path"] is String):
		push_warning("[Registry] register('random_scenes', '%s', ...) expects Dictionary with 'path' key" % id)
		return false
	if not _scene_path_exists("register", "random_scenes", id, data["path"]):
		return false
	var reg: Dictionary = _registry_registered.get("random_scenes", {})
	if reg.has(id):
		push_warning("[Registry] register('random_scenes', '%s'): already registered" % id)
		return false
	var path: String = data["path"]
	if path in ldr.randomScenes:
		push_warning("[Registry] register('random_scenes', '%s'): path already in randomScenes" % id)
		return false
	ldr.randomScenes.append(path)
	reg[id] = {"path": path}
	_registry_registered["random_scenes"] = reg
	_log_debug("[Registry] registered random_scene '%s' -> %s" % [id, path])
	return true

func _remove_random_scene(id: String) -> bool:
	var ldr := _loader_node()
	if ldr == null:
		return false
	var reg: Dictionary = _registry_registered.get("random_scenes", {})
	if not reg.has(id):
		push_warning("[Registry] remove('random_scenes', '%s'): not a mod registration" % id)
		return false
	var path: String = reg[id]["path"]
	var idx: int = ldr.randomScenes.find(path)
	if idx >= 0:
		ldr.randomScenes.remove_at(idx)
	reg.erase(id)
	_registry_registered["random_scenes"] = reg
	_log_debug("[Registry] removed random_scene '%s'" % id)
	return true
