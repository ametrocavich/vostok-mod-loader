# InputMap actions with a default keybind; the id is the action name. Vanilla's rebind menu
# reads a hardcoded dict in Inputs.gd, so a registered action works but is not listed there.

func _validate_input_payload(id: String, verb: String, data: Variant) -> Dictionary:
	if not (data is Dictionary):
		push_warning("[Registry] %s('inputs', '%s') expects Dictionary {display_label, default_event, deadzone?}, got %s" \
				% [verb, id, type_string(typeof(data))])
		return {}
	var d: Dictionary = data
	if not d.has("default_event"):
		push_warning("[Registry] %s('inputs', '%s', ...) data dict missing 'default_event' key" % [verb, id])
		return {}
	var ev = d["default_event"]
	if not (ev is InputEvent):
		push_warning("[Registry] %s('inputs', '%s'): default_event is not an InputEvent (got %s)" % [verb, id, type_string(typeof(ev))])
		return {}
	var display_label = d.get("display_label", id)
	if not (display_label is String):
		push_warning("[Registry] %s('inputs', '%s'): display_label must be a String" % [verb, id])
		return {}
	# 0.5 is vanilla project.godot's deadzone.
	var deadzone = d.get("deadzone", 0.5)
	if not (deadzone is float or deadzone is int):
		push_warning("[Registry] %s('inputs', '%s'): deadzone must be a number" % [verb, id])
		return {}
	return {"display_label": display_label, "default_event": ev, "deadzone": float(deadzone)}

func _set_input_events(id: String, events: Array) -> void:
	InputMap.action_erase_events(id)
	for e in events:
		InputMap.action_add_event(id, e)

func _register_input(id: String, data: Variant) -> bool:
	var reg := _bucket(_registry_registered, "inputs")
	if reg.has(id):
		push_warning("[Registry] register('inputs', '%s'): already registered by a mod" % id)
		return false
	if InputMap.has_action(id):
		push_warning("[Registry] register('inputs', '%s'): action already in InputMap; use override instead" % id)
		return false
	var payload := _validate_input_payload(id, "register", data)
	if payload.is_empty():
		return false
	InputMap.add_action(id, payload["deadzone"])
	InputMap.action_add_event(id, payload["default_event"])
	reg[id] = payload
	_log_debug("[Registry] registered input '%s' (label=%s)" % [id, payload["display_label"]])
	return true

func _override_input(id: String, data: Variant) -> bool:
	if not InputMap.has_action(id):
		push_warning("[Registry] override('inputs', '%s'): no such action in InputMap" % id)
		return false
	var payload := _validate_input_payload(id, "override", data)
	if payload.is_empty():
		return false
	var ov := _bucket(_registry_overridden, "inputs")
	var reg := _bucket(_registry_registered, "inputs")
	# Revert restores all three: the events, the deadzone and this registry's own entry
	# (null for an action it did not add).
	if not ov.has(id):
		ov[id] = {
			"events": InputMap.action_get_events(id).duplicate(),
			"deadzone": InputMap.action_get_deadzone(id),
			"registered": reg.get(id),
		}
	_set_input_events(id, [payload["default_event"]])
	InputMap.action_set_deadzone(id, payload["deadzone"])
	reg[id] = payload
	_log_debug("[Registry] overrode input '%s' (label=%s)" % [id, payload["display_label"]])
	return true

func _patch_input(id: String, fields: Dictionary) -> bool:
	if fields.is_empty():
		push_warning("[Registry] patch('inputs', '%s', ...): empty fields dict is a no-op" % id)
		return false
	if not InputMap.has_action(id):
		push_warning("[Registry] patch('inputs', '%s'): no such action in InputMap" % id)
		return false
	var reg := _bucket(_registry_registered, "inputs")
	# A patch on an action this registry did not add seeds a stub to stash on;
	# vanilla_stub keeps remove() from erasing the vanilla action.
	var current: Dictionary = reg[id] if reg.has(id) else {
		"display_label": id,
		"default_event": null,
		"deadzone": InputMap.action_get_deadzone(id),
		"vanilla_stub": true,
	}
	var stash: Dictionary = (_registry_patched.get("inputs", {}) as Dictionary).get(id, {})
	var any_applied := false
	for field in fields.keys():
		var fname := String(field)
		var val = fields[field]
		match fname:
			"display_label":
				if not (val is String):
					push_warning("[Registry] patch('inputs', '%s'): display_label must be String" % id)
					continue
				if not stash.has(fname):
					stash[fname] = current["display_label"]
				current["display_label"] = val
			"default_event":
				if not (val is InputEvent):
					push_warning("[Registry] patch('inputs', '%s'): default_event must be InputEvent" % id)
					continue
				if not stash.has(fname):
					stash[fname] = InputMap.action_get_events(id).duplicate()
				_set_input_events(id, [val])
				current["default_event"] = val
			"deadzone":
				if not (val is float or val is int):
					push_warning("[Registry] patch('inputs', '%s'): deadzone must be a number" % id)
					continue
				if not stash.has(fname):
					stash[fname] = InputMap.action_get_deadzone(id)
				InputMap.action_set_deadzone(id, float(val))
				current["deadzone"] = float(val)
			_:
				push_warning("[Registry] patch('inputs', '%s'): field '%s' not patchable (valid: %s)" \
						% [id, fname, ["display_label", "default_event", "deadzone"]])
				continue
		any_applied = true
	if not any_applied:
		return false
	reg[id] = current
	_bucket(_registry_patched, "inputs")[id] = stash
	_log_debug("[Registry] patched input '%s' fields %s" % [id, fields.keys()])
	return true

# Writes `entry` back as the id's registration; {} means it had none. A vanilla stub
# exists only to carry patch stashes, so it goes once no patch is left on the id.
func _store_reverted_input(id: String, entry: Dictionary, still_patched: bool) -> void:
	var reg := _bucket(_registry_registered, "inputs")
	if entry.is_empty() or (entry.get("vanilla_stub", false) and not still_patched):
		reg.erase(id)
	else:
		reg[id] = entry

func _remove_input(id: String) -> bool:
	var reg := _bucket(_registry_registered, "inputs")
	if not reg.has(id):
		push_warning("[Registry] remove('inputs', '%s'): not registered by a mod" % id)
		return false
	var ov: Dictionary = _registry_overridden.get("inputs", {})
	if ov.has(id):
		push_warning("[Registry] remove('inputs', '%s'): entry is an override, use revert instead" % id)
		return false
	if reg[id].get("vanilla_stub", false):
		push_warning("[Registry] remove('inputs', '%s'): vanilla action (only patched by a mod); use revert instead" % id)
		return false
	if InputMap.has_action(id):
		InputMap.erase_action(id)
	reg.erase(id)
	_drop_patch_stash("inputs", id)
	_log_debug("[Registry] removed input '%s'" % id)
	return true

func _revert_input(id: String, fields: Array) -> bool:
	var did_something := false
	var ov := _bucket(_registry_overridden, "inputs")
	var patched: Dictionary = _registry_patched.get("inputs", {})
	# A patched or overridden id always has an entry, so `current` is {} only when
	# there is nothing to revert and restore never runs.
	var current: Dictionary = (_registry_registered.get("inputs", {}) as Dictionary).get(id, {})
	var restore := func(fname: String, value: Variant) -> void:
		match fname:
			"display_label":
				current["display_label"] = value
			"default_event":
				_set_input_events(id, value)
				current["default_event"] = value[0] if value.size() > 0 else null
			"deadzone":
				InputMap.action_set_deadzone(id, float(value))
				current["deadzone"] = value
	if fields.is_empty():
		if _revert_stashed_fields("inputs", id, [], restore):
			_store_reverted_input(id, current, false)
			did_something = true
		if ov.has(id):
			var entry: Dictionary = ov[id]
			_set_input_events(id, entry["events"])
			InputMap.action_set_deadzone(id, float(entry["deadzone"]))
			var before: Dictionary = entry["registered"] if entry["registered"] is Dictionary else {}
			_store_reverted_input(id, before, patched.has(id))
			ov.erase(id)
			did_something = true
		if not did_something:
			push_warning("[Registry] revert('inputs', '%s'): nothing to revert" % id)
		return did_something
	if not patched.has(id):
		push_warning("[Registry] revert('inputs', '%s', %s): no patches on this id" % [id, fields])
		return false
	did_something = _revert_stashed_fields("inputs", id, fields, restore)
	_store_reverted_input(id, current, patched.has(id))
	return did_something
