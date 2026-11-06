## scene_paths, shelters, maps and random_scenes: state on the Loader autoload, read
## by the LoadScene and Compiler.Spawn preludes the rewriter injects.

func _loader_node() -> Node:
	return _autoload_node("Loader", true)

# get_script_constant_map() lists only the script's own constants, and a mod that
# replaces Loader.gd with a subclass leaves the scene consts on the base script.
func _script_constants(script: Script) -> Dictionary:
	var consts: Dictionary = {}
	while script != null:
		consts.merge(script.get_script_constant_map())
		script = script.get_base_script()
	return consts

var _loader_consts = null

func _vanilla_scene_const_exists(ldr: Node, id: String) -> bool:
	if _loader_consts == null:
		_loader_consts = _script_constants(ldr.get_script())
	return _loader_consts.has(id)

# Vanilla drops change_scene_to_file's error, so a bad scenePath freezes the loading
# screen for good; registration is the last point where it can be refused.
func _scene_path_exists(verb: String, kind: String, id: String, path: String) -> bool:
	if ResourceLoader.exists(path):
		return true
	push_warning("[Registry] %s('%s', '%s'): scene '%s' does not exist; did it ship in your mod?" \
			% [verb, kind, id, path])
	return false

# The Loader, or null after a warning when the rewriter did not inject the dicts.
func _injected_loader(verb: String, id: String) -> Node:
	var ldr := _loader_node()
	if ldr == null:
		return null
	if not ("_rtv_mod_scene_paths" in ldr and "_rtv_override_scene_paths" in ldr):
		push_warning("[Registry] %s('scene_paths', '%s'): Loader.gd is missing injected scene-path fields" \
				% [verb, id])
		return null
	return ldr

func _scene_path_target(verb: String, id: String, data: Variant) -> Node:
	if not (data is Dictionary):
		push_warning("[Registry] %s('scene_paths', '%s', ...) expects Dictionary, got %s" % [verb, id, type_string(typeof(data))])
		return null
	if not data.has("path") or not (data["path"] is String):
		push_warning("[Registry] %s('scene_paths', '%s'): data requires string 'path' key" % [verb, id])
		return null
	if not _scene_path_exists(verb, "scene_paths", id, data["path"]):
		return null
	return _injected_loader(verb, id)

# The override when there is one, since that is what Loader.LoadScene reads.
func _lookup_scene_path(id: String) -> Variant:
	var ldr := _autoload_node("Loader", false)
	if ldr != null and "_rtv_override_scene_paths" in ldr and ldr._rtv_override_scene_paths.has(id):
		return ldr._rtv_override_scene_paths[id]
	var reg: Dictionary = _registry_registered.get("scene_paths", {})
	return reg.get(id)

func _register_scene_path(id: String, data: Variant) -> bool:
	var ldr := _scene_path_target("register", id, data)
	if ldr == null:
		return false
	if ldr._rtv_mod_scene_paths.has(id) or ldr._rtv_override_scene_paths.has(id):
		push_warning("[Registry] register('scene_paths', '%s'): already registered/overridden by a mod" % id)
		return false
	if _vanilla_scene_const_exists(ldr, id):
		push_warning("[Registry] register('scene_paths', '%s'): name collides with a vanilla scene const; use override instead" \
				% id)
		return false
	ldr._rtv_mod_scene_paths[id] = data
	_bucket(_registry_registered, "scene_paths")[id] = data
	_log_debug("[Registry] registered scene_path '%s' -> %s" % [id, data["path"]])
	return true

func _override_scene_path(id: String, data: Variant) -> bool:
	var ldr := _scene_path_target("override", id, data)
	if ldr == null:
		return false
	if not _vanilla_scene_const_exists(ldr, id) and not ldr._rtv_mod_scene_paths.has(id):
		push_warning("[Registry] override('scene_paths', '%s'): no vanilla scene const or mod registration" % id)
		return false
	# A marker only: revert erases the override and what it covered shows through.
	_bucket(_registry_overridden, "scene_paths")[id] = true
	ldr._rtv_override_scene_paths[id] = data
	_log_debug("[Registry] overrode scene_path '%s'" % id)
	return true

func _patch_scene_path(id: String, fields: Dictionary) -> bool:
	if fields.is_empty():
		push_warning("[Registry] patch('scene_paths', '%s'): empty fields is a no-op" % id)
		return false
	var ldr := _injected_loader("patch", id)
	if ldr == null:
		return false
	var target_dict: Dictionary
	var patches_registration := false
	if ldr._rtv_override_scene_paths.has(id):
		target_dict = ldr._rtv_override_scene_paths[id]
	elif ldr._rtv_mod_scene_paths.has(id):
		target_dict = ldr._rtv_mod_scene_paths[id]
		patches_registration = true
	else:
		push_warning("[Registry] patch('scene_paths', '%s'): no mod registration or override to patch" % id)
		return false
	if fields.has("path"):
		if not (fields["path"] is String):
			push_warning("[Registry] patch('scene_paths', '%s'): 'path' must be a String" % id)
			return false
		if not _scene_path_exists("patch", "scene_paths", id, fields["path"]):
			return false
	var stash: Dictionary = _bucket(_registry_patched, "scene_paths").get_or_add(id, {})
	for field in fields.keys():
		var fname := String(field)
		if not stash.has(fname):
			stash[fname] = target_dict[fname] if target_dict.has(fname) else "__rtv_missing__"
			_patch_source_note("scene_paths", id, fname, target_dict)
		target_dict[fname] = fields[field]
	# Adopts a dict the generated add_shelter / add_map shim wrote straight into the
	# Loader, so get_entry and remove see it.
	if patches_registration:
		_bucket(_registry_registered, "scene_paths")[id] = target_dict
	return true

func _remove_scene_path(id: String) -> bool:
	var ldr := _loader_node()
	if ldr == null:
		return false
	var reg := _bucket(_registry_registered, "scene_paths")
	if not reg.has(id):
		push_warning("[Registry] remove('scene_paths', '%s'): not a mod registration" % id)
		return false
	if (_registry_overridden.get("scene_paths", {}) as Dictionary).has(id):
		push_warning("[Registry] remove('scene_paths', '%s'): entry is an override, use revert instead" % id)
		return false
	ldr._rtv_mod_scene_paths.erase(id)
	reg.erase(id)
	# The stashed originals belong to this registration, not a later one under the id.
	_drop_patch_stash("scene_paths", id)
	_log_debug("[Registry] removed scene_path '%s'" % id)
	return true

func _revert_scene_path(id: String, fields: Array) -> bool:
	var ldr := _loader_node()
	if ldr == null:
		return false
	var resolves := false
	var target_dict: Dictionary = {}
	if "_rtv_override_scene_paths" in ldr and "_rtv_mod_scene_paths" in ldr:
		resolves = ldr._rtv_override_scene_paths.has(id) or ldr._rtv_mod_scene_paths.has(id)
		target_dict = ldr._rtv_override_scene_paths.get(id, ldr._rtv_mod_scene_paths.get(id, {}))
	# Each value goes back onto the dict it was read from, even when an override came
	# later. bool == String is a runtime error, hence the type gate on the sentinel.
	var restore := func(fname: String, value: Variant) -> void:
		var target: Dictionary = _patch_source("scene_paths", id, fname, target_dict)
		if value is String and value == "__rtv_missing__":
			target.erase(fname)
		else:
			target[fname] = value
	if fields.is_empty():
		var did_something := _revert_stashed_fields("scene_paths", id, [], restore)
		var ov := _bucket(_registry_overridden, "scene_paths")
		if ov.has(id):
			ldr._rtv_override_scene_paths.erase(id)
			ov.erase(id)
			did_something = true
		if not did_something:
			push_warning("[Registry] revert('scene_paths', '%s'): nothing to revert" % id)
		return did_something
	if not (_registry_patched.get("scene_paths", {}) as Dictionary).has(id):
		push_warning("[Registry] revert('scene_paths', '%s', %s): no patches on this id" % [id, fields])
		return false
	if not resolves:
		push_warning("[Registry] revert('scene_paths', '%s'): id no longer resolves" % id)
		return false
	return _revert_stashed_fields("scene_paths", id, fields, restore)

func _register_shelter(id: String, data: Variant) -> bool:
	return _register_shelter_or_map(id, data, true, "shelters")

func _register_map(id: String, data: Variant) -> bool:
	return _register_shelter_or_map(id, data, false, "maps")

func _str_field(d: Dictionary, key: String, default: String) -> String:
	var v = d.get(key)
	return default if v == null else str(v)

# Shelters and maps share one bucket, so a name resolves to one Compiler.Spawn
# entry; they differ only in the default `shelter` flag. Every refusal comes before
# the paired scene path registers, or it would leave half a registration behind.
func _register_shelter_or_map(id: String, data: Variant, default_shelter: bool, label: String) -> bool:
	if _registry_target_inert("Compiler.gd", "register('%s', '%s')" % [label, id]):
		return false
	var ldr := _loader_node()
	if ldr == null:
		return false
	if not (data is Dictionary):
		push_warning("[Registry] register('%s', '%s', ...) expects Dictionary ({} if the scene is registered)" \
				% [label, id])
		return false
	var d: Dictionary = data
	var reg := _bucket(_registry_registered, "shelters")
	if reg.has(id):
		push_warning("[Registry] register('%s', '%s'): already registered as shelter or map" % [label, id])
		return false
	if id in ldr.shelters:
		push_warning("[Registry] register('%s', '%s'): name already in shelters list (vanilla?)" % [label, id])
		return false
	var entry := _shelter_entry(id, d, default_shelter, label)
	# Without the rewrite `shelters` is still a const Array.
	if not ("_rtv_mod_shelters" in ldr):
		push_warning("[Registry] register('%s', '%s'): Loader is missing _rtv_mod_shelters" % [label, id])
		return false
	var auto_scene_path := d.has("path")
	if auto_scene_path and not _register_scene_path(id, _shelter_scene_path(d, entry)):
		return false
	ldr.shelters.append(id)
	ldr._rtv_mod_shelters[id] = entry
	reg[id] = {"auto_scene_path": auto_scene_path, "entry": entry, "kind": label}
	_log_debug("[Registry] registered %s '%s' (shelter=%s, connected_to='%s')" \
			% [label, id, entry["shelter"], entry["connected_to"]])
	return true

# The Compiler.Spawn record the injected prelude reads for a shelter or map.
func _shelter_entry(id: String, d: Dictionary, default_shelter: bool, label: String) -> Dictionary:
	var cc = d.get("connected_content", [])
	if not (cc is Array):
		push_warning("[Registry] register('%s', '%s'): connected_content must be an Array; ignoring" % [label, id])
		cc = []
	return {
		"shelter": d.get("shelter", default_shelter) == true,
		"transition_text": _str_field(d, "transition_text", id),
		"exit_spawn": _str_field(d, "exit_spawn", ""),
		"entrance_spawn": _str_field(d, "entrance_spawn", ""),
		"connected_to": _str_field(d, "connected_to", ""),
		"connected_content": cc,
	}

# The scene_paths payload paired with a shelter or map that ships a `path`.
func _shelter_scene_path(d: Dictionary, entry: Dictionary) -> Dictionary:
	var sp_data: Dictionary = {"path": d["path"], "shelter": entry["shelter"]}
	for key in ["menu", "permadeath", "tutorial"]:
		if d.has(key):
			sp_data[key] = d[key]
	# The LoadScene prelude shows this label in place of the scene name.
	sp_data["transition_text"] = entry["transition_text"]
	return sp_data

func _remove_shelter(id: String) -> bool:
	return _remove_shelter_or_map(id, "shelters")

func _remove_map(id: String) -> bool:
	return _remove_shelter_or_map(id, "maps")

func _remove_shelter_or_map(id: String, label: String) -> bool:
	var ldr := _loader_node()
	if ldr == null:
		return false
	var reg := _bucket(_registry_registered, "shelters")
	if not reg.has(id):
		push_warning("[Registry] remove('%s', '%s'): not a mod registration" % [label, id])
		return false
	var meta: Dictionary = reg[id]
	if meta["kind"] != label:
		push_warning("[Registry] remove('%s', '%s'): id was registered as '%s', use that registry to remove" \
				% [label, id, meta["kind"]])
		return false
	var idx: int = ldr.shelters.find(id)
	if idx >= 0:
		ldr.shelters.remove_at(idx)
	if meta["auto_scene_path"] and not _remove_scene_path(id):
		push_warning("[Registry] remove('%s', '%s'): its scene path is overridden and stays registered" % [label, id])
	ldr._rtv_mod_shelters.erase(id)
	reg.erase(id)
	_log_debug("[Registry] removed %s '%s'" % [label, id])
	return true

func _register_random_scene(id: String, data: Variant) -> bool:
	var ldr := _loader_node()
	if ldr == null:
		return false
	if not (data is Dictionary) or not data.has("path") or not (data["path"] is String):
		push_warning("[Registry] register('random_scenes', '%s', ...) expects Dictionary with 'path' key" % id)
		return false
	if not _scene_path_exists("register", "random_scenes", id, data["path"]):
		return false
	var reg := _bucket(_registry_registered, "random_scenes")
	if reg.has(id):
		push_warning("[Registry] register('random_scenes', '%s'): already registered" % id)
		return false
	var path: String = data["path"]
	if path in ldr.randomScenes:
		push_warning("[Registry] register('random_scenes', '%s'): path already in randomScenes" % id)
		return false
	ldr.randomScenes.append(path)
	reg[id] = {"path": path}
	_log_debug("[Registry] registered random_scene '%s' -> %s" % [id, path])
	return true

func _remove_random_scene(id: String) -> bool:
	var ldr := _loader_node()
	if ldr == null:
		return false
	var reg := _bucket(_registry_registered, "random_scenes")
	if not reg.has(id):
		push_warning("[Registry] remove('random_scenes', '%s'): not a mod registration" % id)
		return false
	var idx: int = ldr.randomScenes.find(reg[id]["path"])
	if idx >= 0:
		ldr.randomScenes.remove_at(idx)
	reg.erase(id)
	_log_debug("[Registry] removed random_scene '%s'" % id)
	return true
