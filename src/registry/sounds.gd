## ----- registry/sounds.gd -----
## AudioLibrary is a plain Resource (not an autoload) that scripts preload
## and read by direct property name (audioLibrary.knifeHitFleshSlash). The Resource
## cache makes every preload the same instance, so mutations propagate to
## every holder.
##
## register/override accept: an AudioEvent Resource; a bare AudioStream
## (wrapped in a default AudioEvent); or {audioClips, volume, randomPitch}.
## patch() takes a subset of those three fields.
##
## Vanilla hardcodes property names, so a newly registered id isn't
## reachable from vanilla code, and a registration never touches the
## library itself -- mods fetch it via get_entry. Use override to affect
## what vanilla plays.

const _AUDIO_LIBRARY_PATH := "res://Resources/AudioLibrary.tres"

var _audio_library_cache: Resource = null
var _audio_library_warned: bool = false

func _audio_library() -> Resource:
	if _audio_library_cache != null:
		return _audio_library_cache
	var lib = load(_AUDIO_LIBRARY_PATH)
	if lib == null:
		if not _audio_library_warned:
			push_warning("[Registry] sounds: AudioLibrary.tres missing at %s; sounds registry is inert" % _AUDIO_LIBRARY_PATH)
			_audio_library_warned = true
		return null
	_audio_library_cache = lib
	return lib

# Accept an AudioEvent, a bare AudioStream, or a Dictionary; return an
# AudioEvent Resource or null with a warning. The AudioEvent class comes
# from the live library (_audio_event_class), never a hardcoded path.
func _coerce_audio_event(id: String, verb: String, data: Variant) -> Resource:
	if data is Resource and _looks_like_audio_event(data):
		return data
	if data is AudioStream:
		var ev_class := _audio_event_class()
		if ev_class == null:
			push_warning("[Registry] %s('sounds', '%s'): couldn't locate AudioEvent class (library may be empty or unmigrated)" % [verb, id])
			return null
		var ev = ev_class.new()
		ev.set("audioClips", [data])
		ev.set("volume", 0.0)
		ev.set("randomPitch", false)
		return ev
	if data is Dictionary:
		var d: Dictionary = data
		var ev_class_d := _audio_event_class()
		if ev_class_d == null:
			push_warning("[Registry] %s('sounds', '%s'): couldn't locate AudioEvent class to construct from dict" % [verb, id])
			return null
		var ev = ev_class_d.new()
		if d.has("audioClips"):
			ev.set("audioClips", d["audioClips"])
		else:
			ev.set("audioClips", [])
		# .get's default only covers absent keys; a present-but-null value
		# would crash float()/bool(), so type-check first.
		var raw_vol = d.get("volume", 0.0)
		if raw_vol is float or raw_vol is int:
			ev.set("volume", float(raw_vol))
		else:
			if d.has("volume"):
				push_warning("[Registry] %s('sounds', '%s'): 'volume' should be a number, got %s; using 0.0" % [verb, id, typeof(raw_vol)])
			ev.set("volume", 0.0)
		var raw_rp = d.get("randomPitch", false)
		if raw_rp is bool:
			ev.set("randomPitch", raw_rp)
		else:
			if d.has("randomPitch"):
				push_warning("[Registry] %s('sounds', '%s'): 'randomPitch' should be a bool, got %s; using false" % [verb, id, typeof(raw_rp)])
			ev.set("randomPitch", false)
		return ev
	push_warning("[Registry] %s('sounds', '%s', ...) expects AudioEvent / AudioStream / Dictionary, got %s" % [verb, id, typeof(data)])
	return null

# First non-null @export AudioEvent on the live library supplies the class;
# hardcoding the AudioEvent.gd path would break if the game moves it.
func _audio_event_class() -> GDScript:
	var lib := _audio_library()
	if lib == null:
		return null
	for p in lib.get_property_list():
		var pname = p.get("name")
		if not (p.get("usage") & PROPERTY_USAGE_SCRIPT_VARIABLE):
			continue
		var val = lib.get(pname)
		if val == null or not (val is Resource):
			continue
		var s = val.get_script()
		if s != null:
			return s
	return null

func _looks_like_audio_event(res: Resource) -> bool:
	# Shape heuristic on the three canonical fields (cf _looks_like_item_data).
	return _object_has_property(res, "audioClips") \
			and _object_has_property(res, "volume") \
			and _object_has_property(res, "randomPitch")

# True if the name is a declared @export property on AudioLibrary.
func _sound_exists_in_vanilla(id: String) -> bool:
	var lib := _audio_library()
	if lib == null:
		return false
	return _object_has_property(lib, id)

# Every script property on the library, for refusal messages: a game update
# renames sound fields (Build 2 renamed most), and the refusal is where an
# author reads the current list without decompiling anything.
func _sound_field_names() -> String:
	var lib := _audio_library()
	if lib == null:
		return "(AudioLibrary not loaded)"
	var names := PackedStringArray()
	for p in lib.get_property_list():
		if int(p.get("usage", 0)) & PROPERTY_USAGE_SCRIPT_VARIABLE:
			names.append(str(p["name"]))
	return ", ".join(names)

# Overrides on vanilla names are set() mutations on the library itself, so
# the library read already sees them; the registered dict comes first only
# to cover register-only ids.
func _lookup_sound(id: String) -> Resource:
	var reg: Dictionary = _registry_registered.get("sounds", {})
	if reg.has(id):
		return reg[id]
	var lib := _audio_library()
	if lib == null:
		return null
	if _object_has_property(lib, id):
		return lib.get(id)
	return null

func _register_sound(id: String, data: Variant) -> bool:
	if _sound_exists_in_vanilla(id):
		push_warning("[Registry] register('sounds', '%s'): id collides with vanilla AudioLibrary field; use override instead" % id)
		return false
	var reg: Dictionary = _registry_registered.get("sounds", {})
	if reg.has(id):
		push_warning("[Registry] register('sounds', '%s'): already registered by a mod" % id)
		return false
	var ev := _coerce_audio_event(id, "register", data)
	if ev == null:
		return false
	reg[id] = ev
	_registry_registered["sounds"] = reg
	_log_debug("[Registry] registered sound '%s'" % id)
	return true

func _override_sound(id: String, data: Variant) -> bool:
	var lib := _audio_library()
	if lib == null:
		return false
	if not _sound_exists_in_vanilla(id):
		# Mod-registered ids can't be overridden; revert the register first.
		push_warning("[Registry] override('sounds', '%s'): no vanilla AudioLibrary field with that name (register can't be overridden; revert the register first). Current names: %s" % [id, _sound_field_names()])
		return false
	var ev := _coerce_audio_event(id, "override", data)
	if ev == null:
		return false
	# First-write-wins stash so stacked overrides revert to true vanilla.
	var ov: Dictionary = _registry_overridden.get("sounds", {})
	if not ov.has(id):
		ov[id] = lib.get(id)
		_registry_overridden["sounds"] = ov
	lib.set(id, ev)
	_log_debug("[Registry] overrode sound '%s'" % id)
	return true

# append, prepend and remove_from share one body; `op` selects the operation.
func _array_op_sound(id: String, field: String, op: String, values: Array, allow_duplicates: bool) -> bool:
	var target := _lookup_sound(id)
	if target == null:
		push_warning("[Registry] %s('sounds', '%s'): no sound with that id. Current names: %s" % [op, id, _sound_field_names()])
		return false
	return _array_op_on_resource("sounds", id, target, field, op, values, allow_duplicates)


func _patch_sound(id: String, fields: Dictionary) -> bool:
	if fields.is_empty():
		push_warning("[Registry] patch('sounds', '%s', ...): empty fields dict is a no-op" % id)
		return false
	var target := _lookup_sound(id)
	if target == null:
		push_warning("[Registry] patch('sounds', '%s'): no sound with that id. Current names: %s" % [id, _sound_field_names()])
		return false
	var patched: Dictionary = _registry_patched.get("sounds", {})
	var stash: Dictionary = patched.get(id, {})
	for field in fields.keys():
		var field_name := String(field)
		if not _object_has_property(target, field_name):
			push_warning("[Registry] patch('sounds', '%s'): field '%s' doesn't exist on AudioEvent (valid: audioClips, volume, randomPitch)" \
					% [id, field_name])
			continue
		if not stash.has(field_name):
			stash[field_name] = target.get(field_name)
			_patch_source_note("sounds", id, field_name, target)
		target.set(field_name, fields[field])
	patched[id] = stash
	_registry_patched["sounds"] = patched
	_log_debug("[Registry] patched sound '%s' fields %s" % [id, fields.keys()])
	return true

func _remove_sound(id: String) -> bool:
	var reg: Dictionary = _registry_registered.get("sounds", {})
	if not reg.has(id):
		push_warning("[Registry] remove('sounds', '%s'): not registered by a mod" % id)
		return false
	# Overrides mutate the library, not this dict, so anything in reg is a
	# plain register.
	reg.erase(id)
	_registry_registered["sounds"] = reg
	# Drop the patch stash: stale originals would poison a re-registration.
	var patched: Dictionary = _registry_patched.get("sounds", {})
	if patched.has(id):
		patched.erase(id)
		_registry_patched["sounds"] = patched
		_patch_source_forget("sounds", id)
	_log_debug("[Registry] removed sound '%s'" % id)
	return true

func _revert_sound(id: String, fields: Array) -> bool:
	var did_something := false
	var ov: Dictionary = _registry_overridden.get("sounds", {})
	var patched: Dictionary = _registry_patched.get("sounds", {})
	var lib := _audio_library()
	# Full revert: patches first, each value onto the AudioEvent it was read
	# from (see _revert_item), then the override itself.
	if fields.is_empty():
		if patched.has(id):
			var stash: Dictionary = patched[id]
			for fname in stash.keys():
				var source: Resource = _patch_source("sounds", id, fname, _lookup_sound(id))
				if source != null:
					source.set(fname, stash[fname])
			patched.erase(id)
			_registry_patched["sounds"] = patched
			_patch_source_forget("sounds", id)
			did_something = true
		if ov.has(id) and lib != null:
			lib.set(id, ov[id])
			ov.erase(id)
			_registry_overridden["sounds"] = ov
			did_something = true
		if not did_something:
			push_warning("[Registry] revert('sounds', '%s'): nothing to revert" % id)
		return did_something
	if not patched.has(id):
		push_warning("[Registry] revert('sounds', '%s', %s): no patches on this id" % [id, fields])
		return false
	var target := _lookup_sound(id)
	if target == null:
		push_warning("[Registry] revert('sounds', '%s', %s): id no longer resolves" % [id, fields])
		return false
	var stash: Dictionary = patched[id]
	for field in fields:
		var fname := String(field)
		if not stash.has(fname):
			push_warning("[Registry] revert('sounds', '%s'): field '%s' wasn't patched" % [id, fname])
			continue
		(_patch_source("sounds", id, fname, target) as Resource).set(fname, stash[fname])
		_patch_source_forget("sounds", id, fname)
		stash.erase(fname)
		did_something = true
	if stash.is_empty():
		patched.erase(id)
	else:
		patched[id] = stash
	_registry_patched["sounds"] = patched
	return did_something
