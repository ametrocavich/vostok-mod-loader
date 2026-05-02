## ----- registry/events.gd -----
##
## Events.tres holds a single `events: Array[EventData]` that EventSystem.gd
## const-preloads and filters into per-type buckets (dynamic/trader/special)
## at _ready(). Same timing constraint as loot / recipes: mods must register
## during their own _ready() for additions to propagate into EventSystem's
## buckets before the first GetAvailableEvents() call.
##
## EventData has no unique id (name isn't unique; vanilla can have duplicate
## names across days). Registry uses mod-chosen handles like loot / recipes.
##
## Data shapes:
##   register: {event: EventData}
##   override: {event: EventData, replaces: EventData}
##   patch:    id can be a String handle OR an EventData Resource ref
##             directly; lets mods patch vanilla events in one call
##             without registering a handle first.
##
## Caveat for mod authors: EventData.function is a method name resolved on
## EventSystem via Callable(self, event.function). Registering a new event
## whose function string refers to a method EventSystem doesn't have will
## make that event a no-op when it fires. Either reuse a vanilla function
## name (FighterJet, ActivateTrader, etc.) or hook EventSystem to inject
## your own handler.

const _EVENTS_PATH := "res://Events/Events.tres"

var _events_cache: Resource = null
var _events_warned: bool = false

func _events_resource() -> Resource:
	if _events_cache != null:
		return _events_cache
	var res = load(_EVENTS_PATH)
	if res == null:
		if not _events_warned:
			push_warning("[Registry] events: Events.tres missing at %s; events registry is inert" % _EVENTS_PATH)
			_events_warned = true
		return null
	_events_cache = res
	return res

# Shape check: consistent with other registries' _looks_like_* helpers.
# EventData's canonical fields are name, type, function, possibility.
func _looks_like_event_data(res: Resource) -> bool:
	return _resource_has_property(res, "function") \
			and _resource_has_property(res, "possibility") \
			and _resource_has_property(res, "day")

# Validates {event} payload. Returns [event, arr] or [null, null] on error.
func _validate_event_data(id: String, verb: String, data: Variant) -> Array:
	if not (data is Dictionary):
		push_warning("[Registry] %s('events', '%s', ...) expects Dictionary {event}, got %s" % [verb, id, typeof(data)])
		return [null, null]
	var d: Dictionary = data
	if not d.has("event"):
		push_warning("[Registry] %s('events', '%s', ...) data dict missing 'event' key" % [verb, id])
		return [null, null]
	var event = d["event"]
	if not (event is Resource) or not _looks_like_event_data(event):
		push_warning("[Registry] %s('events', '%s'): event is not an EventData Resource" % [verb, id])
		return [null, null]
	var events_res := _events_resource()
	if events_res == null:
		return [null, null]
	var arr = events_res.get("events")
	if not (arr is Array):
		push_warning("[Registry] %s('events', '%s'): Events.events is not an Array" % [verb, id])
		return [null, null]
	return [event, arr]

func _register_event(id: String, data: Variant) -> bool:
	var reg: Dictionary = _registry_registered.get("events", {})
	if reg.has(id):
		push_warning("[Registry] register('events', '%s'): already registered (pick a unique handle)" % id)
		return false
	var parts := _validate_event_data(id, "register", data)
	var event = parts[0]
	var arr = parts[1]
	if event == null or arr == null:
		return false
	if not _typed_array_accepts(arr, event):
		push_warning("[Registry] register('events', '%s'): event type doesn't match Events.events typed array" % id)
		return false
	if event in arr:
		push_warning("[Registry] register('events', '%s'): event is already present in the array; use override instead" % id)
		return false
	arr.append(event)
	reg[id] = {"event": event}
	_registry_registered["events"] = reg
	_log_debug("[Registry] registered event '%s' (name=%s)" % [id, event.get("name")])
	return true

func _override_event(id: String, data: Variant) -> bool:
	var ov: Dictionary = _registry_overridden.get("events", {})
	if ov.has(id):
		push_warning("[Registry] override('events', '%s'): already overridden (revert first to re-override)" % id)
		return false
	if not (data is Dictionary) or not data.has("replaces"):
		push_warning("[Registry] override('events', '%s', ...) requires {event, replaces: EventData}" % id)
		return false
	var parts := _validate_event_data(id, "override", data)
	var new_event = parts[0]
	var arr = parts[1]
	if new_event == null or arr == null:
		return false
	var old_event = data["replaces"]
	if not (old_event is Resource) or not _looks_like_event_data(old_event):
		push_warning("[Registry] override('events', '%s'): 'replaces' is not an EventData Resource" % id)
		return false
	if not _typed_array_accepts(arr, new_event):
		push_warning("[Registry] override('events', '%s'): event type doesn't match Events.events typed array" % id)
		return false
	var idx: int = arr.find(old_event)
	if idx < 0:
		push_warning("[Registry] override('events', '%s'): 'replaces' not present in Events.events" % id)
		return false
	if new_event in arr:
		push_warning("[Registry] override('events', '%s'): new event already in array; would duplicate" % id)
		return false
	arr[idx] = new_event
	ov[id] = {
		"event": new_event,
		"replaced": old_event,
		"index": idx,
	}
	_registry_overridden["events"] = ov
	var reg: Dictionary = _registry_registered.get("events", {})
	reg[id] = {"event": new_event}
	_registry_registered["events"] = reg
	_log_debug("[Registry] overrode event '%s'" % id)
	return true

# Resolves whatever the mod passed (String handle or EventData ref) to:
#   [event, patch_key]
# where patch_key is the stable Variant used in _registry_patched to track
# per-field original values. For handles it's the String; for direct refs
# it's "ref:<instance_id>" so distinct Resource instances don't collide.
func _resolve_event_patch_target(id: Variant) -> Array:
	if id is String:
		var reg: Dictionary = _registry_registered.get("events", {})
		if reg.has(id):
			return [reg[id]["event"], id]
		push_warning("[Registry] patch('events', '%s'): no registered handle with that id (register first, or pass an EventData Resource ref directly)" % id)
		return [null, null]
	if id is Resource and _looks_like_event_data(id):
		return [id, "ref:%d" % id.get_instance_id()]
	push_warning("[Registry] patch('events', ...): id must be a String handle or an EventData Resource")
	return [null, null]

func _append_event(id: Variant, field: String, values: Array, allow_duplicates: bool) -> bool:
	var resolved := _resolve_event_patch_target(id)
	var target: Resource = resolved[0]
	var key = resolved[1]
	if target == null:
		return false
	return _array_op_on_resource("events", key, target, field, "append", values, allow_duplicates)

func _prepend_event(id: Variant, field: String, values: Array, allow_duplicates: bool) -> bool:
	var resolved := _resolve_event_patch_target(id)
	var target: Resource = resolved[0]
	var key = resolved[1]
	if target == null:
		return false
	return _array_op_on_resource("events", key, target, field, "prepend", values, allow_duplicates)

func _remove_from_event(id: Variant, field: String, values: Array) -> bool:
	var resolved := _resolve_event_patch_target(id)
	var target: Resource = resolved[0]
	var key = resolved[1]
	if target == null:
		return false
	return _array_op_on_resource("events", key, target, field, "remove_from", values, false)


func _patch_event(id: Variant, fields: Dictionary) -> bool:
	if fields.is_empty():
		push_warning("[Registry] patch('events', ...): empty fields dict is a no-op")
		return false
	var resolved := _resolve_event_patch_target(id)
	var target: Resource = resolved[0]
	var key = resolved[1]
	if target == null:
		return false
	var patched: Dictionary = _registry_patched.get("events", {})
	var stash: Dictionary = patched.get(key, {})
	for field in fields.keys():
		var fname := String(field)
		if not _resource_has_property(target, fname):
			push_warning("[Registry] patch('events'): field '%s' doesn't exist on EventData" % fname)
			continue
		if not stash.has(fname):
			stash[fname] = target.get(fname)
		target.set(fname, fields[field])
	patched[key] = stash
	_registry_patched["events"] = patched
	_log_debug("[Registry] patched event (key=%s) fields %s" % [key, fields.keys()])
	return true

func _remove_event(id: String) -> bool:
	var reg: Dictionary = _registry_registered.get("events", {})
	if not reg.has(id):
		push_warning("[Registry] remove('events', '%s'): not a mod event registration" % id)
		return false
	var ov: Dictionary = _registry_overridden.get("events", {})
	if ov.has(id):
		push_warning("[Registry] remove('events', '%s'): entry is an override, use revert instead" % id)
		return false
	var entry: Dictionary = reg[id]
	var event: Resource = entry["event"]
	var events_res := _events_resource()
	if events_res != null:
		var arr = events_res.get("events")
		if arr is Array:
			var idx: int = arr.find(event)
			if idx >= 0:
				arr.remove_at(idx)
			else:
				push_warning("[Registry] remove('events', '%s'): event not found in array; tracking cleared" % id)
	reg.erase(id)
	_registry_registered["events"] = reg
	_log_debug("[Registry] removed event '%s'" % id)
	return true

func _revert_event(id: Variant, fields: Array) -> bool:
	var did_something := false
	var ov: Dictionary = _registry_overridden.get("events", {})
	var patched: Dictionary = _registry_patched.get("events", {})
	# Resolve patch key + target (matches _resolve_event_patch_target).
	var patch_key = null
	var patch_target: Resource = null
	if id is String:
		patch_key = id
		var reg: Dictionary = _registry_registered.get("events", {})
		if reg.has(id):
			patch_target = reg[id]["event"]
	elif id is Resource and _looks_like_event_data(id):
		patch_key = "ref:%d" % id.get_instance_id()
		patch_target = id
	# Full revert: patches first, then override.
	if fields.is_empty():
		if patch_key != null and patched.has(patch_key):
			if patch_target != null:
				var stash: Dictionary = patched[patch_key]
				for fname in stash.keys():
					patch_target.set(fname, stash[fname])
			patched.erase(patch_key)
			_registry_patched["events"] = patched
			did_something = true
		if id is String and ov.has(id):
			var entry: Dictionary = ov[id]
			var events_res := _events_resource()
			if events_res != null:
				var arr = events_res.get("events")
				if arr is Array:
					var current_idx: int = arr.find(entry["event"])
					if current_idx >= 0:
						arr[current_idx] = entry["replaced"]
					else:
						push_warning("[Registry] revert('events', '%s'): override's event missing from array, appending original at end" % id)
						arr.append(entry["replaced"])
			ov.erase(id)
			_registry_overridden["events"] = ov
			var reg2: Dictionary = _registry_registered.get("events", {})
			reg2.erase(id)
			_registry_registered["events"] = reg2
			did_something = true
		if not did_something:
			push_warning("[Registry] revert('events'): nothing to revert for that id")
		return did_something
	# Per-field revert: patches only.
	if patch_key == null or not patched.has(patch_key):
		push_warning("[Registry] revert('events'): no patches found for that id")
		return false
	if patch_target == null:
		push_warning("[Registry] revert('events'): patch target no longer resolves")
		return false
	var stash2: Dictionary = patched[patch_key]
	for field in fields:
		var fname := String(field)
		if not stash2.has(fname):
			push_warning("[Registry] revert('events'): field '%s' wasn't patched" % fname)
			continue
		patch_target.set(fname, stash2[fname])
		stash2.erase(fname)
		did_something = true
	if stash2.is_empty():
		patched.erase(patch_key)
	else:
		patched[patch_key] = stash2
	_registry_patched["events"] = patched
	return did_something
