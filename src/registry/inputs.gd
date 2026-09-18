## ----- registry/inputs.gd -----
## Thin wrapper over InputMap so mods can declare input actions with a
## default keybind; registered actions work immediately via
## Input.is_action_pressed(id). The id IS the action name, so mods should
## namespace it ("mymod_heal", not "heal").
##
## register/override: {display_label: String, default_event: InputEvent,
## deadzone?: float (default 0.5)}. patch: subset of the same fields.
##
## Settings UI caveat: vanilla's Keybinds panel reads a hardcoded `inputs`
## dict in Inputs.gd, so a registered action is functional but won't appear
## in the rebind menu unless a hook on Inputs-createactions-pre merges it
## into the UI's dict; this registry doesn't install that hook.
##
## Rebinds persist in user://Preferences.tres (Preferences.actionEvents) as
## long as the mod re-registers on boot; orphans linger harmlessly.

# Matches vanilla's project.godot.
const _DEFAULT_DEADZONE := 0.5

func _validate_input_payload(id: String, verb: String, data: Variant) -> Dictionary:
	# Returns validated {display_label, default_event, deadzone} on success,
	# empty dict on error (with warning already pushed).
	if not (data is Dictionary):
		push_warning("[Registry] %s('inputs', '%s', ...) expects Dictionary {display_label, default_event, deadzone?}, got %s" \
				% [verb, id, typeof(data)])
		return {}
	var d: Dictionary = data
	if not d.has("default_event"):
		push_warning("[Registry] %s('inputs', '%s', ...) data dict missing 'default_event' key" % [verb, id])
		return {}
	var ev = d["default_event"]
	if not (ev is InputEvent):
		push_warning("[Registry] %s('inputs', '%s'): default_event is not an InputEvent (got %s)" % [verb, id, typeof(ev)])
		return {}
	var display_label = d.get("display_label", id)
	if not (display_label is String):
		push_warning("[Registry] %s('inputs', '%s'): display_label must be a String" % [verb, id])
		return {}
	var deadzone = d.get("deadzone", _DEFAULT_DEADZONE)
	if not (deadzone is float or deadzone is int):
		push_warning("[Registry] %s('inputs', '%s'): deadzone must be a number" % [verb, id])
		return {}
	return {
		"display_label": display_label,
		"default_event": ev,
		"deadzone": float(deadzone),
	}

func _register_input(id: String, data: Variant) -> bool:
	var reg: Dictionary = _registry_registered.get("inputs", {})
	if reg.has(id):
		push_warning("[Registry] register('inputs', '%s'): already registered by a mod" % id)
		return false
	if InputMap.has_action(id):
		push_warning("[Registry] register('inputs', '%s'): action already exists in InputMap (vanilla or another mod; use override instead)" % id)
		return false
	var payload := _validate_input_payload(id, "register", data)
	if payload.is_empty():
		return false
	InputMap.add_action(id, payload["deadzone"])
	InputMap.action_add_event(id, payload["default_event"])
	reg[id] = payload
	_registry_registered["inputs"] = reg
	_log_debug("[Registry] registered input '%s' (label=%s)" % [id, payload["display_label"]])
	return true

func _override_input(id: String, data: Variant) -> bool:
	if not InputMap.has_action(id):
		push_warning("[Registry] override('inputs', '%s'): no such action in InputMap" % id)
		return false
	var payload := _validate_input_payload(id, "override", data)
	if payload.is_empty():
		return false
	var ov: Dictionary = _registry_overridden.get("inputs", {})
	# Stash original event list + deadzone once so revert can restore.
	if not ov.has(id):
		var originals: Array = []
		for e in InputMap.action_get_events(id):
			originals.append(e)
		# Stash the real deadzone so revert restores it, not a forced 0.5.
		ov[id] = {
			"events": originals,
			"deadzone": InputMap.action_get_deadzone(id),
		}
		_registry_overridden["inputs"] = ov
	InputMap.action_erase_events(id)
	InputMap.action_add_event(id, payload["default_event"])
	InputMap.action_set_deadzone(id, payload["deadzone"])
	# Update the metadata dict too so get_entry/patch see the current label.
	var reg: Dictionary = _registry_registered.get("inputs", {})
	reg[id] = payload
	_registry_registered["inputs"] = reg
	_log_debug("[Registry] overrode input '%s' (label=%s)" % [id, payload["display_label"]])
	return true

func _patch_input(id: String, fields: Dictionary) -> bool:
	if fields.is_empty():
		push_warning("[Registry] patch('inputs', '%s', ...): empty fields dict is a no-op" % id)
		return false
	if not InputMap.has_action(id):
		push_warning("[Registry] patch('inputs', '%s'): no such action in InputMap" % id)
		return false
	# display_label is a UI hint on reg[id]; default_event replaces the
	# InputMap event; deadzone maps to action_set_deadzone.
	const _patchable := ["display_label", "default_event", "deadzone"]
	var reg: Dictionary = _registry_registered.get("inputs", {})
	# Patching an untouched vanilla action seeds a stub so patch/revert have
	# somewhere to stash. vanilla_stub lets remove() refuse to erase the
	# underlying vanilla InputMap action.
	if not reg.has(id):
		reg[id] = {
			"display_label": id,
			"default_event": null,
			"deadzone": InputMap.action_get_deadzone(id),
			"vanilla_stub": true,
		}
	var current: Dictionary = reg[id]
	var patched: Dictionary = _registry_patched.get("inputs", {})
	var stash: Dictionary = patched.get(id, {})
	var any_applied := false
	for field in fields.keys():
		var fname := String(field)
		if not (fname in _patchable):
			push_warning("[Registry] patch('inputs', '%s'): field '%s' not patchable (valid: %s)" % [id, fname, _patchable])
			continue
		var val = fields[field]
		match fname:
			"display_label":
				if not (val is String):
					push_warning("[Registry] patch('inputs', '%s'): display_label must be String" % id)
					continue
				if not stash.has(fname):
					stash[fname] = current.get("display_label", id)
				current["display_label"] = val
			"default_event":
				if not (val is InputEvent):
					push_warning("[Registry] patch('inputs', '%s'): default_event must be InputEvent" % id)
					continue
				if not stash.has(fname):
					# Stash the live first event so revert restores exactly
					# what was active.
					var existing := InputMap.action_get_events(id)
					stash[fname] = existing[0] if existing.size() > 0 else null
				InputMap.action_erase_events(id)
				InputMap.action_add_event(id, val)
				current["default_event"] = val
			"deadzone":
				if not (val is float or val is int):
					push_warning("[Registry] patch('inputs', '%s'): deadzone must be a number" % id)
					continue
				if not stash.has(fname):
					# The live value: the metadata of an action this registry
					# did not add starts from a default, not from InputMap.
					stash[fname] = InputMap.action_get_deadzone(id)
				InputMap.action_set_deadzone(id, float(val))
				current["deadzone"] = float(val)
		any_applied = true
	if not any_applied:
		return false
	reg[id] = current
	_registry_registered["inputs"] = reg
	patched[id] = stash
	_registry_patched["inputs"] = patched
	_log_debug("[Registry] patched input '%s' fields %s" % [id, fields.keys()])
	return true

func _remove_input(id: String) -> bool:
	var reg: Dictionary = _registry_registered.get("inputs", {})
	if not reg.has(id):
		push_warning("[Registry] remove('inputs', '%s'): not registered by a mod" % id)
		return false
	var ov: Dictionary = _registry_overridden.get("inputs", {})
	if ov.has(id):
		push_warning("[Registry] remove('inputs', '%s'): entry is an override, use revert instead" % id)
		return false
	# A patch on a vanilla action seeds a reg stub (see _patch_input); this
	# guard keeps remove() from erasing the vanilla InputMap action.
	if reg[id] is Dictionary and (reg[id] as Dictionary).get("vanilla_stub", false):
		push_warning("[Registry] remove('inputs', '%s'): vanilla action (only patched by a mod); use revert instead" % id)
		return false
	if InputMap.has_action(id):
		InputMap.erase_action(id)
	reg.erase(id)
	_registry_registered["inputs"] = reg
	# Drop the patch stash: stale originals would poison a re-registration.
	var patched: Dictionary = _registry_patched.get("inputs", {})
	if patched.has(id):
		patched.erase(id)
		_registry_patched["inputs"] = patched
	_log_debug("[Registry] removed input '%s'" % id)
	return true

func _revert_input(id: String, fields: Array) -> bool:
	var did_something := false
	var ov: Dictionary = _registry_overridden.get("inputs", {})
	var patched: Dictionary = _registry_patched.get("inputs", {})
	# Full revert: restore patch stash, then restore override events.
	if fields.is_empty():
		if patched.has(id):
			var stash: Dictionary = patched[id]
			var reg2: Dictionary = _registry_registered.get("inputs", {})
			var current: Dictionary = reg2.get(id, {})
			for fname in stash.keys():
				match fname:
					"display_label":
						current["display_label"] = stash[fname]
					"default_event":
						InputMap.action_erase_events(id)
						if stash[fname] != null:
							InputMap.action_add_event(id, stash[fname])
						current["default_event"] = stash[fname]
					"deadzone":
						InputMap.action_set_deadzone(id, float(stash[fname]))
						current["deadzone"] = stash[fname]
			if not current.is_empty():
				reg2[id] = current
				_registry_registered["inputs"] = reg2
			patched.erase(id)
			_registry_patched["inputs"] = patched
			did_something = true
		if ov.has(id):
			var entry: Dictionary = ov[id]
			InputMap.action_erase_events(id)
			for e in entry["events"]:
				InputMap.action_add_event(id, e)
			InputMap.action_set_deadzone(id, float(entry["deadzone"]))
			ov.erase(id)
			_registry_overridden["inputs"] = ov
			# reg is left intact: it now reflects vanilla state, or the
			# mod's own registration if the mod also registered the action.
			did_something = true
		if not did_something:
			push_warning("[Registry] revert('inputs', '%s'): nothing to revert" % id)
		return did_something
	# Per-field revert (patches only).
	if not patched.has(id):
		push_warning("[Registry] revert('inputs', '%s', %s): no patches on this id" % [id, fields])
		return false
	var stash2: Dictionary = patched[id]
	var reg3: Dictionary = _registry_registered.get("inputs", {})
	var current2: Dictionary = reg3.get(id, {})
	for field in fields:
		var fname := String(field)
		if not stash2.has(fname):
			push_warning("[Registry] revert('inputs', '%s'): field '%s' wasn't patched" % [id, fname])
			continue
		match fname:
			"display_label":
				current2["display_label"] = stash2[fname]
			"default_event":
				InputMap.action_erase_events(id)
				if stash2[fname] != null:
					InputMap.action_add_event(id, stash2[fname])
				current2["default_event"] = stash2[fname]
			"deadzone":
				InputMap.action_set_deadzone(id, float(stash2[fname]))
				current2["deadzone"] = stash2[fname]
		stash2.erase(fname)
		did_something = true
	if stash2.is_empty():
		patched.erase(id)
	else:
		patched[id] = stash2
	_registry_patched["inputs"] = patched
	if not current2.is_empty():
		reg3[id] = current2
		_registry_registered["inputs"] = reg3
	return did_something
