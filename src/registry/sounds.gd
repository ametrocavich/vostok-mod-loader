## ----- registry/sounds.gd -----
##
## AudioLibrary is a plain Resource at res://Resources/AudioLibrary.tres, not
## an autoload. Every script that uses audio does `preload("res://Resources/
## AudioLibrary.tres")` and accesses events by direct property name, e.g.
## `audioLibrary.knifeSlash`. Godot's Resource cache means every preload
## returns the same instance, so mutating fields on that one instance
## propagates to every holder.
##
## Data shape accepted by register/override:
##   - AudioEvent Resource instance (direct)
##   - AudioStream directly (wrapped in a default AudioEvent: volume=0, randomPitch=false)
##   - Dictionary {audioClips: Array[AudioStream], volume: float, randomPitch: bool}
##     (missing keys default sensibly)
##
## patch() takes {volume, randomPitch, audioClips} subset.
##
## register() limitation (mirrors scenes): registrations live in a mod-only
## lookup dict. Vanilla scripts hardcode property names like `audioLibrary
## .knifeSlash`, so a newly registered id isn't reachable from vanilla code.
## Mods wanting to play their own sounds must fetch via
## `lib.get_entry(lib.Registry.SOUNDS, "mymod_pickup")` or, equivalently,
## `audioLibrary.get("mymod_pickup")`; both resolve through the same
## storage (see _lookup_sound). Use override to affect what vanilla plays.

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

# Accept an AudioEvent, a bare AudioStream, or a Dictionary, and return an
# AudioEvent Resource (or null with warning on bad input).
#
# AudioEvent's class script is loaded dynamically from the existing library
#; we don't know its res:// path up front and don't want to hardcode it.
# Pull the class from any existing @export AudioEvent on the library. This
# also tolerates the game renaming or moving AudioEvent.gd.
func _coerce_audio_event(id: String, verb: String, data: Variant) -> Resource:
	# Direct pass-through: already an AudioEvent-shaped Resource.
	if data is Resource and _looks_like_audio_event(data):
		return data
	# Bare AudioStream: wrap in a default-constructed AudioEvent.
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
	# Dictionary shorthand.
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
		ev.set("volume", float(d.get("volume", 0.0)))
		ev.set("randomPitch", bool(d.get("randomPitch", false)))
		return ev
	push_warning("[Registry] %s('sounds', '%s', ...) expects AudioEvent / AudioStream / Dictionary, got %s" % [verb, id, typeof(data)])
	return null

# Walk the live AudioLibrary for the first non-null @export AudioEvent and
# use its script as the AudioEvent class reference. Avoids hardcoding the
# AudioEvent.gd path (which the game could move).
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
	# AudioEvent is identified by its three canonical fields. Same heuristic
	# shape as _looks_like_item_data for ItemData.
	return _resource_has_property(res, "audioClips") \
			and _resource_has_property(res, "volume") \
			and _resource_has_property(res, "randomPitch")

# True if the name is a declared @export property on AudioLibrary. Used to
# distinguish "override vanilla sound" from "register new sound".
func _sound_exists_in_vanilla(id: String) -> bool:
	var lib := _audio_library()
	if lib == null:
		return false
	return _resource_has_property(lib, id)

# Lookup precedence: mod overrides > mod registrations > vanilla library
# field. Overrides on vanilla names live as set() mutations on the library
# itself; lookups via audioLibrary.get(id) would find them there. To keep
# the registry self-contained and work for register-only ids too, we route
# through _registry_registered first, falling back to the library.
func _lookup_sound(id: String) -> Resource:
	var reg: Dictionary = _registry_registered.get("sounds", {})
	if reg.has(id):
		return reg[id]
	var lib := _audio_library()
	if lib == null:
		return null
	if _resource_has_property(lib, id):
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
		# Mod-registered ids can't be overridden; that's what a second
		# register call would be conceptually, but we reject re-register.
		# Force mods to revert first.
		push_warning("[Registry] override('sounds', '%s'): no vanilla AudioLibrary field with that name (register can't be overridden; revert the register first)" % id)
		return false
	var ev := _coerce_audio_event(id, "override", data)
	if ev == null:
		return false
	# First-write-wins stash so multiple overrides on the same id still
	# restore to true vanilla on revert.
	var ov: Dictionary = _registry_overridden.get("sounds", {})
	if not ov.has(id):
		ov[id] = lib.get(id)
		_registry_overridden["sounds"] = ov
	lib.set(id, ev)
	_log_debug("[Registry] overrode sound '%s'" % id)
	return true

func _patch_sound(id: String, fields: Dictionary) -> bool:
	if fields.is_empty():
		push_warning("[Registry] patch('sounds', '%s', ...): empty fields dict is a no-op" % id)
		return false
	var target := _lookup_sound(id)
	if target == null:
		push_warning("[Registry] patch('sounds', '%s'): no sound with that id" % id)
		return false
	var patched: Dictionary = _registry_patched.get("sounds", {})
	var stash: Dictionary = patched.get(id, {})
	for field in fields.keys():
		var field_name := String(field)
		if not _resource_has_property(target, field_name):
			push_warning("[Registry] patch('sounds', '%s'): field '%s' doesn't exist on AudioEvent (valid: audioClips, volume, randomPitch)" \
					% [id, field_name])
			continue
		if not stash.has(field_name):
			stash[field_name] = target.get(field_name)
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
	# Sounds don't have the items-style override-lives-in-registered dual
	# storage; overrides mutate the library directly, not this dict. So
	# anything in reg is a plain register.
	reg.erase(id)
	_registry_registered["sounds"] = reg
	_log_debug("[Registry] removed sound '%s'" % id)
	return true

func _revert_sound(id: String, fields: Array) -> bool:
	var did_something := false
	var ov: Dictionary = _registry_overridden.get("sounds", {})
	var patched: Dictionary = _registry_patched.get("sounds", {})
	var lib := _audio_library()
	# Full revert: undo override AND clear patches. Order: patches first
	# (onto whatever's currently resolving, which may be an override), then
	# override (replaces whole entry with the stashed vanilla).
	if fields.is_empty():
		if patched.has(id):
			var target := _lookup_sound(id)
			if target != null:
				var stash: Dictionary = patched[id]
				for fname in stash.keys():
					target.set(fname, stash[fname])
			patched.erase(id)
			_registry_patched["sounds"] = patched
			did_something = true
		if ov.has(id) and lib != null:
			lib.set(id, ov[id])
			ov.erase(id)
			_registry_overridden["sounds"] = ov
			did_something = true
		if not did_something:
			push_warning("[Registry] revert('sounds', '%s'): nothing to revert" % id)
		return did_something
	# Per-field revert: only undo named fields on a patch.
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
		target.set(fname, stash[fname])
		stash.erase(fname)
		did_something = true
	if stash.is_empty():
		patched.erase(id)
	else:
		patched[id] = stash
	_registry_patched["sounds"] = patched
	return did_something
