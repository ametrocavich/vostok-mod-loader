# AudioLibrary.tres sound fields. Vanilla reads them by property name, so a registered id is
# reachable only through get_entry; override and patch change what vanilla plays.

func _audio_library() -> Resource:
	return _registry_resource("res://Resources/AudioLibrary.tres", "sounds")

# An AudioEvent passes through; a bare AudioStream or a {audioClips, volume, randomPitch} dict
# becomes a new AudioEvent. null after a warning.
func _coerce_audio_event(id: String, verb: String, data: Variant) -> Resource:
	if _looks_like_audio_event(data):
		return data
	if data is AudioStream:
		data = {"audioClips": [data]}
	if not (data is Dictionary):
		push_warning("[Registry] %s('sounds', '%s', ...) expects AudioEvent / AudioStream / Dictionary, got %s" \
				% [verb, id, type_string(typeof(data))])
		return null
	var d: Dictionary = data
	var ev_class := _audio_event_class()
	if ev_class == null:
		push_warning("[Registry] %s('sounds', '%s'): couldn't locate AudioEvent class (library empty?)" % [verb, id])
		return null
	var ev = ev_class.new()
	var clips: Variant = _sound_clips_for(ev, d.get("audioClips", []), id, verb)
	if clips == null:
		return null
	ev.set("audioClips", clips)
	var volume = d.get("volume", 0.0)
	if not (volume is float or volume is int):
		if d.has("volume"):
			push_warning("[Registry] %s('sounds', '%s'): 'volume' should be a number, got %s; using 0.0" \
					% [verb, id, type_string(typeof(volume))])
		volume = 0.0
	ev.set("volume", float(volume))
	var random_pitch = d.get("randomPitch", false)
	if not (random_pitch is bool):
		if d.has("randomPitch"):
			push_warning("[Registry] %s('sounds', '%s'): 'randomPitch' should be a bool, got %s; using false" \
					% [verb, id, type_string(typeof(random_pitch))])
		random_pitch = false
	ev.set("randomPitch", random_pitch)
	return ev

# Object.set silently refuses an untyped Array for the typed audioClips, so the clips go into
# a copy of the field's own array; a clip that type refuses (OGG, MP3) returns null.
func _sound_clips_for(ev: Resource, clips: Variant, id: String, verb: String) -> Variant:
	if not (clips is Array):
		push_warning("[Registry] %s('sounds', '%s'): 'audioClips' must be an Array, got %s" \
				% [verb, id, type_string(typeof(clips))])
		return null
	var current: Variant = ev.get("audioClips")
	var typed: Array = (current as Array).duplicate() if current is Array else []
	typed.clear()
	for clip in clips:
		if not _typed_array_accepts(typed, clip):
			var got: String = (clip as Object).get_class() if clip is Object else type_string(typeof(clip))
			push_warning("[Registry] %s('sounds', '%s'): audioClips takes %s clips only, got %s" \
					% [verb, id, String(typed.get_typed_class_name()), got])
			return null
		typed.append(clip)
	return typed

# The first AudioEvent on the live library supplies the class, wherever the game keeps its script.
func _audio_event_class() -> GDScript:
	var lib := _audio_library()
	if lib == null:
		return null
	for p in lib.get_property_list():
		if not (p["usage"] & PROPERTY_USAGE_SCRIPT_VARIABLE):
			continue
		var val = lib.get(p["name"])
		if val is Resource and val.get_script() != null:
			return val.get_script()
	return null

func _looks_like_audio_event(res: Variant) -> bool:
	return res is Resource and _has_properties(res, ["audioClips", "volume", "randomPitch"])

func _sound_exists_in_vanilla(id: String) -> bool:
	var lib := _audio_library()
	return lib != null and _object_has_property(lib, id)

# The refusals print this list, so an author reads the running build's names there.
func _sound_field_names() -> String:
	var lib := _audio_library()
	if lib == null:
		return "(AudioLibrary not loaded)"
	var names := PackedStringArray()
	for p in lib.get_property_list():
		if p["usage"] & PROPERTY_USAGE_SCRIPT_VARIABLE:
			names.append(str(p["name"]))
	return ", ".join(names)

# An override is a set() on the library itself, so only register-only ids live in the dict.
func _lookup_sound(id: String) -> Resource:
	var reg: Dictionary = _registry_registered.get("sounds", {})
	if reg.has(id):
		return reg[id]
	var lib := _audio_library()
	if lib != null and _object_has_property(lib, id):
		return lib.get(id)
	return null

func _register_sound(id: String, data: Variant) -> bool:
	if _sound_exists_in_vanilla(id):
		push_warning("[Registry] register('sounds', '%s'): id is a vanilla AudioLibrary field; use override" % id)
		return false
	var reg := _bucket(_registry_registered, "sounds")
	if reg.has(id):
		push_warning("[Registry] register('sounds', '%s'): already registered by a mod" % id)
		return false
	var ev := _coerce_audio_event(id, "register", data)
	if ev == null:
		return false
	reg[id] = ev
	_log_debug("[Registry] registered sound '%s'" % id)
	return true

func _override_sound(id: String, data: Variant) -> bool:
	var lib := _audio_library()
	if lib == null:
		return false
	if not _sound_exists_in_vanilla(id):
		push_warning(("[Registry] override('sounds', '%s'): no vanilla AudioLibrary field with that name "
				+ "(register can't be overridden; revert the register first). Current names: %s") \
				% [id, _sound_field_names()])
		return false
	var ev := _coerce_audio_event(id, "override", data)
	if ev == null:
		return false
	# First write wins, so stacked overrides revert to vanilla.
	var ov := _bucket(_registry_overridden, "sounds")
	if not ov.has(id):
		ov[id] = lib.get(id)
	lib.set(id, ev)
	_log_debug("[Registry] overrode sound '%s'" % id)
	return true

func _array_op_sound(id: String, field: String, op: String, values: Array, allow_duplicates: bool) -> bool:
	var target := _lookup_sound(id)
	if target == null:
		push_warning("[Registry] %s('sounds', '%s'): no sound with that id. Current names: %s" \
				% [op, id, _sound_field_names()])
		return false
	return _array_op_on_resource("sounds", id, target, field, op, values, allow_duplicates)

func _patch_sound(id: String, fields: Dictionary) -> bool:
	if fields.is_empty():
		push_warning("[Registry] patch('sounds', '%s', ...): empty fields dict is a no-op" % id)
		return false
	var target := _lookup_sound(id)
	if target == null:
		push_warning("[Registry] patch('sounds', '%s'): no sound with that id. Current names: %s" \
				% [id, _sound_field_names()])
		return false
	var values := fields.duplicate()
	for field in fields.keys():
		if String(field) == "audioClips" and _object_has_property(target, "audioClips"):
			var clips: Variant = _sound_clips_for(target, fields[field], id, "patch")
			if clips == null:
				values.erase(field)
			else:
				values[field] = clips
	var stash: Dictionary = _bucket(_registry_patched, "sounds").get_or_add(id, {})
	_patch_resource_fields("sounds", id, target, values, stash, "AudioEvent (valid: audioClips, volume, randomPitch)")
	_log_debug("[Registry] patched sound '%s' fields %s" % [id, fields.keys()])
	return true

func _remove_sound(id: String) -> bool:
	var reg := _bucket(_registry_registered, "sounds")
	if not reg.has(id):
		push_warning("[Registry] remove('sounds', '%s'): not registered by a mod" % id)
		return false
	# Overrides mutate the library, not this dict, so an entry here is always a register.
	reg.erase(id)
	_drop_patch_stash("sounds", id)
	_log_debug("[Registry] removed sound '%s'" % id)
	return true

func _revert_sound(id: String, fields: Array) -> bool:
	var restore := func(fname: String, value: Variant) -> void:
		var source: Resource = _patch_source("sounds", id, fname, _lookup_sound(id))
		if source != null:
			source.set(fname, value)
	if fields.is_empty():
		var did_something := _revert_stashed_fields("sounds", id, [], restore)
		var ov := _bucket(_registry_overridden, "sounds")
		var lib := _audio_library()
		if ov.has(id):
			lib.set(id, ov[id])
			ov.erase(id)
			did_something = true
		if not did_something:
			push_warning("[Registry] revert('sounds', '%s'): nothing to revert" % id)
		return did_something
	if not (_registry_patched.get("sounds", {}) as Dictionary).has(id):
		push_warning("[Registry] revert('sounds', '%s', %s): no patches on this id" % [id, fields])
		return false
	if _lookup_sound(id) == null:
		push_warning("[Registry] revert('sounds', '%s', %s): id no longer resolves" % [id, fields])
		return false
	return _revert_stashed_fields("sounds", id, fields, restore)
