## ----- ui.gd -----
## The launcher window shown before the game starts.
##   - Mods tab: per-mod enable checkbox + load-order spin, profile selector
##     (switch / create / delete) with a Vanilla entry that confirms then
##     resets + restarts, and a live load-order preview.
##   - Updates tab: ModWorkshop version checking + downloads.
##   - Profiles live in UI_CONFIG_PATH under `profile.<name>.enabled` and
##     `profile.<name>.priority`; the active profile is stored in
##     `[settings] active_profile`. VANILLA_PROFILE is a sentinel meaning
##     "all mods off" and keeps stored profiles untouched on reset.
## Closing the window (or clicking Launch Game) hands control back to
## _run_pass_1.

func _load_developer_mode_setting() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(UI_CONFIG_PATH) != OK:
		return
	_developer_mode = bool(cfg.get_value("settings", "developer_mode", false))
	if _developer_mode:
		_log_info("Developer mode: ON")

func _load_ui_config() -> void:
	_active_profile = "Default"
	var cfg := ConfigFile.new()
	if cfg.load(UI_CONFIG_PATH) != OK:
		# Fresh install, no config file yet. Materialize the placeholder
		# Default profile so it's a real on-disk profile from the first UI
		# render (see comment at the tail of this function for rationale).
		_save_ui_config()
		return

	# Migrate legacy flat [enabled]/[priority] layout into profile.Default.* on
	# the first post-upgrade load. The next _save_ui_config writes the file back
	# without the flat sections, so the migration only runs once per install.
	var has_any_profile := false
	for sec: String in cfg.get_sections():
		if sec.begins_with("profile."):
			has_any_profile = true
			break
	if not has_any_profile:
		if cfg.has_section("enabled"):
			for key: String in cfg.get_section_keys("enabled"):
				cfg.set_value("profile.Default.enabled", key, cfg.get_value("enabled", key))
		if cfg.has_section("priority"):
			for key: String in cfg.get_section_keys("priority"):
				cfg.set_value("profile.Default.priority", key, cfg.get_value("priority", key))

	var stored := str(cfg.get_value("settings", "active_profile", "Default"))
	var profiles := _list_profiles_in_cfg(cfg)
	if stored == VANILLA_PROFILE:
		_active_profile = VANILLA_PROFILE
	elif stored in profiles:
		_active_profile = stored
	elif not profiles.is_empty():
		_active_profile = profiles[0]
	else:
		_active_profile = "Default"

	_apply_profile_to_entries(cfg, _active_profile)

	# Materialize the placeholder Default profile when it's the resolved
	# active and wasn't on disk at load time. Without this, "Default"
	# appears in the dropdown only as a UI-level placeholder (see the
	# profile selector build in build_mods_tab) and vanishes the first
	# time the user creates a named profile -- confusing, and also leaves
	# a silent-overwrite gap where an imported profile named "Default"
	# would write without the overwrite confirm (since _list_profiles()
	# wouldn't yet include the untoggled placeholder). Writing the section
	# here makes Default a persistent profile like every other launcher
	# (Firefox, Minecraft, Steam). Users can rename or delete it if they
	# want.
	#
	# Uses the has_any_profile flag captured BEFORE migration rather than
	# cfg.has_section, because the legacy [enabled]/[priority] migration
	# populates profile.Default.* in-memory -- cfg.has_section would
	# return true from the in-memory state and we'd skip the save,
	# leaving disk still without the section.
	if _active_profile == "Default" and not has_any_profile:
		_save_ui_config()

func _apply_profile_to_entries(cfg: ConfigFile, profile: String) -> void:
	# VANILLA_PROFILE has no stored sections -- treating it as "all mods off"
	# lets Reset to Vanilla avoid touching the user's other profiles.
	var is_vanilla := profile == VANILLA_PROFILE
	var en_sec := "profile." + profile + ".enabled"
	var pr_sec := "profile." + profile + ".priority"
	for entry in _ui_mod_entries:
		var pk: String = entry["profile_key"]
		entry.erase("profile_version_mismatch")
		# Resolve once, reuse for both enabled and priority lookups. Exact
		# profile_key match first; if missing, fall back to id-prefix match
		# ("<mod_id>@*") so a version bump doesn't silently drop the entry --
		# we carry over the stored state and flag the mismatch for the UI.
		var resolved_key := ""
		if cfg.has_section_key(en_sec, pk) or cfg.has_section_key(pr_sec, pk):
			resolved_key = pk
		elif not pk.begins_with("zip:"):
			resolved_key = _find_stored_key_for_mod_id(cfg, profile, entry["mod_id"])
			if resolved_key != "" and resolved_key != pk:
				entry["profile_version_mismatch"] = {
					"stored":  _version_from_profile_key(resolved_key),
					"current": entry["version"],
				}
		if is_vanilla:
			entry["enabled"] = false
		elif resolved_key != "" and cfg.has_section_key(en_sec, resolved_key):
			entry["enabled"] = bool(cfg.get_value(en_sec, resolved_key))
		else:
			entry["enabled"] = true
		if entry["ext"] == "zip":
			entry["enabled"] = false
		if resolved_key != "" and cfg.has_section_key(pr_sec, resolved_key):
			entry["priority"] = int(str(cfg.get_value(pr_sec, resolved_key)))

# Find a stored profile key matching an entry's mod_id but with a different
# version, so a version bump doesn't orphan the profile entry. Returns "" if
# no such key exists. The "@" sentinel guards against partial-id collisions
# (e.g., "foo" matching "foobar@1.0").
func _find_stored_key_for_mod_id(cfg: ConfigFile, profile: String, mod_id: String) -> String:
	var prefix := mod_id + "@"
	for suffix: String in [".enabled", ".priority"]:
		var sec := "profile." + profile + suffix
		if cfg.has_section(sec):
			for key: String in cfg.get_section_keys(sec):
				if key.begins_with(prefix):
					return key
	return ""

func _version_from_profile_key(key: String) -> String:
	var at := key.find("@")
	if at < 0:
		return ""
	return key.substr(at + 1)

func _list_profiles_in_cfg(cfg: ConfigFile) -> Array[String]:
	var names: Array[String] = []
	var prefix := "profile."
	var suffix := ".enabled"
	for sec: String in cfg.get_sections():
		if sec.begins_with(prefix) and sec.ends_with(suffix):
			var name: String = sec.substr(prefix.length(), sec.length() - prefix.length() - suffix.length())
			# Skip VANILLA_PROFILE -- it's a sentinel, not a real profile, and
			# leaked ghost sections (e.g. from pre-guard auto-save bugs) must
			# not appear in the dropdown.
			if name != "" and name != VANILLA_PROFILE and not (name in names):
				names.append(name)
	# Also include profiles that only have a priority section (shouldn't happen
	# in practice, but guards against partial state).
	var pr_suffix := ".priority"
	for sec: String in cfg.get_sections():
		if sec.begins_with(prefix) and sec.ends_with(pr_suffix):
			var name: String = sec.substr(prefix.length(), sec.length() - prefix.length() - pr_suffix.length())
			if name != "" and name != VANILLA_PROFILE and not (name in names):
				names.append(name)
	names.sort()
	return names

func _list_profiles() -> Array[String]:
	var cfg := ConfigFile.new()
	if cfg.load(UI_CONFIG_PATH) != OK:
		return []
	return _list_profiles_in_cfg(cfg)

func _save_ui_config() -> void:
	var cfg := ConfigFile.new()
	cfg.load(UI_CONFIG_PATH)

	# Drop legacy flat sections if they linger after migration.
	if cfg.has_section("enabled"):
		cfg.erase_section("enabled")
	if cfg.has_section("priority"):
		cfg.erase_section("priority")

	# Skip profile-section writes while the Vanilla sentinel is active -- it's
	# not a real profile and must not materialize stored sections, even from
	# the Launch-time save in lifecycle.gd.
	if _active_profile != VANILLA_PROFILE:
		# Rewrite the active profile's sections fresh so removed mods don't linger.
		var en_sec := "profile." + _active_profile + ".enabled"
		var pr_sec := "profile." + _active_profile + ".priority"
		# Snapshot stored state for folder mods that dev-mode-off filtered out
		# of _ui_mod_entries -- otherwise the erase+rewrite below would drop
		# their enabled/priority entries and the user loses those settings the
		# moment they save with dev mode disabled.
		var preserved_enabled: Dictionary = {}
		var preserved_priority: Dictionary = {}
		if not _hidden_folder_profile_keys.is_empty() and cfg.has_section(en_sec):
			for key: String in cfg.get_section_keys(en_sec):
				if _hidden_folder_profile_keys.has(key):
					preserved_enabled[key] = cfg.get_value(en_sec, key)
		if not _hidden_folder_profile_keys.is_empty() and cfg.has_section(pr_sec):
			for key: String in cfg.get_section_keys(pr_sec):
				if _hidden_folder_profile_keys.has(key):
					preserved_priority[key] = cfg.get_value(pr_sec, key)
		if cfg.has_section(en_sec):
			cfg.erase_section(en_sec)
		if cfg.has_section(pr_sec):
			cfg.erase_section(pr_sec)
		for entry in _ui_mod_entries:
			var pk: String = entry["profile_key"]
			cfg.set_value(en_sec, pk, entry["enabled"])
			cfg.set_value(pr_sec, pk, entry["priority"])
		for k in preserved_enabled.keys():
			cfg.set_value(en_sec, k, preserved_enabled[k])
		for k in preserved_priority.keys():
			cfg.set_value(pr_sec, k, preserved_priority[k])

	cfg.set_value("settings", "developer_mode", _developer_mode)
	cfg.set_value("settings", "active_profile", _active_profile)
	cfg.save(UI_CONFIG_PATH)
	if _boot_complete:
		_dirty_since_boot = true

# Profile management: snapshot the current in-memory state to a new profile
# and switch to it. Caller is responsible for validating `name` (unique,
# non-empty, not "Vanilla").
func _create_profile(name: String) -> void:
	_active_profile = name
	_save_ui_config()

# Delete the active profile's sections and switch to whichever profile remains
# first in alphabetical order. Caller must ensure at least one other profile
# exists before calling this.
func _delete_active_profile() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(UI_CONFIG_PATH) != OK:
		return
	var target := _active_profile
	for suffix: String in [".enabled", ".priority"]:
		var sec := "profile." + target + suffix
		if cfg.has_section(sec):
			cfg.erase_section(sec)
	var remaining := _list_profiles_in_cfg(cfg)
	if remaining.is_empty():
		_active_profile = "Default"
	else:
		_active_profile = remaining[0]
	cfg.set_value("settings", "active_profile", _active_profile)
	cfg.save(UI_CONFIG_PATH)
	_apply_profile_to_entries(cfg, _active_profile)
	if _boot_complete:
		_dirty_since_boot = true

# Swap in-memory mod state to an existing profile. Does not write to disk
# beyond updating the active_profile pointer -- mod enabled/priority values
# already live in the profile sections.
func _switch_profile(name: String) -> void:
	_active_profile = name
	var cfg := ConfigFile.new()
	cfg.load(UI_CONFIG_PATH)
	cfg.set_value("settings", "active_profile", _active_profile)
	cfg.save(UI_CONFIG_PATH)
	_apply_profile_to_entries(cfg, _active_profile)
	if _boot_complete:
		_dirty_since_boot = true

# Rename the active profile. We just save under the new name (which materializes
# the sections from current in-memory state, matching what the old profile
# held), then erase the old sections. Handles fresh-install placeholder cleanly
# since _save_ui_config doesn't care whether sections existed previously.
func _rename_profile(new_name: String) -> void:
	var old := _active_profile
	if old == new_name:
		return
	_active_profile = new_name
	_save_ui_config()
	var cfg := ConfigFile.new()
	if cfg.load(UI_CONFIG_PATH) != OK:
		return
	for suffix: String in [".enabled", ".priority"]:
		var sec := "profile." + old + suffix
		if cfg.has_section(sec):
			cfg.erase_section(sec)
	cfg.save(UI_CONFIG_PATH)

# Parse a shared payload back into the fields needed to reconstruct a profile.
# Returns either {"error": "..."} on failure or the parsed metroprofile dict
# on success. Validates the MTRPRF1 magic, checksum, and JSON shape.
func _parse_profile_payload(raw: String) -> Dictionary:
	var parts := raw.strip_edges().split(".")
	if parts.size() != 3:
		return {"error": "Invalid format -- expected MTRPRF1.<body>.<checksum>"}
	if parts[0] != "MTRPRF1":
		return {"error": "Unknown payload type \"" + parts[0] + "\""}
	var body: String = parts[1]
	var check: String = parts[2]
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	ctx.update(body.to_utf8_buffer())
	if check != ctx.finish().hex_encode().substr(0, 8):
		return {"error": "Payload is corrupted -- checksum mismatch"}
	var json_str := Marshalls.base64_to_utf8(body)
	if json_str == "":
		return {"error": "Payload body is not valid base64"}
	var obj = JSON.parse_string(json_str)
	if typeof(obj) != TYPE_DICTIONARY:
		return {"error": "Payload JSON is not an object"}
	var d: Dictionary = obj
	if int(d.get("metroprofile", 0)) != 1:
		return {"error": "Unsupported metroprofile schema version"}
	if not (d.get("name") is String):
		return {"error": "Payload missing name"}
	if not (d.get("enabled") is Dictionary):
		return {"error": "Payload missing enabled data"}
	return d

# Apply a parsed payload as a profile. Overwrites any existing profile with
# the same name (caller is expected to have confirmed), switches to it, and
# syncs in-memory entries.
func _import_profile_from_parsed(parsed: Dictionary) -> void:
	var name := _sanitize_profile_name(parsed["name"])
	if name == "" or name.to_lower() == "vanilla" or name == VANILLA_PROFILE:
		return
	var cfg := ConfigFile.new()
	cfg.load(UI_CONFIG_PATH)
	var en_sec := "profile." + name + ".enabled"
	var pr_sec := "profile." + name + ".priority"
	if cfg.has_section(en_sec):
		cfg.erase_section(en_sec)
	if cfg.has_section(pr_sec):
		cfg.erase_section(pr_sec)
	var enabled_dict: Dictionary = parsed["enabled"]
	for key in enabled_dict.keys():
		cfg.set_value(en_sec, str(key), bool(enabled_dict[key]))
	var priority_dict: Dictionary = parsed.get("priority", {})
	for key in priority_dict.keys():
		# Clamp defensively -- payload came from the clipboard and a crafted
		# or corrupted entry could set an out-of-range priority that breaks
		# load-order invariants (UI spinbox is [-999, 999]; anything outside
		# that range couldn't have been authored through the UI anyway).
		var pv := int(priority_dict[key])
		cfg.set_value(pr_sec, str(key), clampi(pv, PRIORITY_MIN, PRIORITY_MAX))
	# Explicit manifest: any local mod NOT in the imported payload is written
	# as disabled. Without this, _apply_profile_to_entries falls through to
	# its default-true branch for unknown keys (ergonomic for "newly-dropped
	# mod in existing profile") and imports would silently enable every
	# local mod the exporter didn't have -- including dev folders, which is
	# the opposite of what a shared profile means. Handles id-prefix matches
	# (foo@2.0 local resolving to foo@1.0 in payload) so version bumps
	# inherit the payload's state rather than getting disabled.
	var payload_mod_ids: Dictionary = {}
	for key in enabled_dict.keys():
		var key_str := str(key)
		var at := key_str.find("@")
		if at > 0:
			payload_mod_ids[key_str.substr(0, at)] = true
	for entry in _ui_mod_entries:
		var pk: String = entry["profile_key"]
		if enabled_dict.has(pk):
			continue
		if not pk.begins_with("zip:") and payload_mod_ids.has(entry["mod_id"]):
			continue
		cfg.set_value(en_sec, pk, false)
	_active_profile = name
	cfg.set_value("settings", "active_profile", _active_profile)
	cfg.save(UI_CONFIG_PATH)
	_apply_profile_to_entries(cfg, _active_profile)
	if _boot_complete:
		_dirty_since_boot = true

# Metroprofile v1 schema is LOCKED at 3.0.1. Full spec (wrapper format, JSON
# shape, profile key format, forward-compat rules, round-trip guarantees) is
# in the wiki: docs/wiki/Profile-Format.md. Changes to the export/import
# shape require bumping the schema version so old parsers reject cleanly.

# Build the shareable opaque payload for the given profile. Shape:
#     MTRPRF1.<base64-encoded JSON>.<first 8 hex chars of SHA-256(body)>
# The magic prefix identifies the schema version, the body is the profile's
# JSON, and the suffix lets a future import path detect copy/paste corruption
# without full cryptographic verification. Empty string if the profile has
# nothing to export.
func _profile_to_payload(profile_name: String) -> String:
	var json := _profile_to_json_string(profile_name)
	if json == "":
		return ""
	var body := Marshalls.utf8_to_base64(json)
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	ctx.update(body.to_utf8_buffer())
	var check := ctx.finish().hex_encode().substr(0, 8)
	return "MTRPRF1." + body + "." + check

# Serialize the named profile to a JSON string. Used as the inner layer of
# _profile_to_payload; exposed separately in case we need it for debugging
# or tests. Empty string if the profile has no stored sections.
func _profile_to_json_string(profile_name: String) -> String:
	var src := ConfigFile.new()
	if src.load(UI_CONFIG_PATH) != OK:
		return ""
	var en_sec := "profile." + profile_name + ".enabled"
	var pr_sec := "profile." + profile_name + ".priority"
	if not src.has_section(en_sec):
		return ""
	var enabled: Dictionary = {}
	for key: String in src.get_section_keys(en_sec):
		enabled[key] = bool(src.get_value(en_sec, key))
	var priority: Dictionary = {}
	if src.has_section(pr_sec):
		for key: String in src.get_section_keys(pr_sec):
			priority[key] = int(str(src.get_value(pr_sec, key)))
	return JSON.stringify({
		"metroprofile":      1,
		"name":              profile_name,
		"modloader_version": MODLOADER_VERSION,
		"exported_at":       Time.get_datetime_string_from_system(),
		"enabled":           enabled,
		"priority":          priority,
	}, "  ")

# Profile keys that the active profile references but whose mod isn't in
# _ui_mod_entries (archives deleted, or renamed ZIPs for mods without a
# mod.txt id). Keys whose id prefix matches an installed mod with a different
# version are treated as present -- _apply_profile_to_entries resolves those
# via id-prefix fallback and flags the mismatch. Rendered as red stub rows.
func _missing_mods_in_active_profile() -> Array[String]:
	var cfg := ConfigFile.new()
	if cfg.load(UI_CONFIG_PATH) != OK:
		return []
	var en_sec := "profile." + _active_profile + ".enabled"
	if not cfg.has_section(en_sec):
		return []
	var present: Dictionary = {}
	var ids_installed: Dictionary = {}
	for entry in _ui_mod_entries:
		present[entry["profile_key"]] = true
		if not entry["profile_key"].begins_with("zip:"):
			ids_installed[entry["mod_id"]] = true
	# Folder mods filtered out by dev-mode-off are on disk but hidden from
	# _ui_mod_entries; treat them as present so the user doesn't see every
	# dev mod flagged as deleted when they toggle the setting.
	for key in _hidden_folder_profile_keys.keys():
		present[key] = true
	for mid in _hidden_folder_ids.keys():
		ids_installed[mid] = true
	var missing: Array[String] = []
	for key: String in cfg.get_section_keys(en_sec):
		if present.has(key):
			continue
		var at := key.find("@")
		if at > 0 and ids_installed.has(key.substr(0, at)):
			continue
		missing.append(key)
	missing.sort()
	return missing

# Strip an orphaned stored key from the active profile's sections. Called
# from the "Remove" button on a missing-mod stub row.
func _remove_missing_entry_from_profile(stored_key: String) -> void:
	var cfg := ConfigFile.new()
	if cfg.load(UI_CONFIG_PATH) != OK:
		return
	for suffix: String in [".enabled", ".priority"]:
		var sec := "profile." + _active_profile + suffix
		if cfg.has_section(sec) and cfg.has_section_key(sec, stored_key):
			cfg.erase_section_key(sec, stored_key)
	cfg.save(UI_CONFIG_PATH)

# Keep only letters, digits, space, underscore, hyphen. Strip edges. Reject
# dots (they would collide with the `profile.<name>.enabled` section path).
func _sanitize_profile_name(raw: String) -> String:
	var trimmed := raw.strip_edges()
	var out := ""
	for i in trimmed.length():
		var c := trimmed.substr(i, 1)
		var u := trimmed.unicode_at(i)
		var is_alpha := (u >= 65 and u <= 90) or (u >= 97 and u <= 122)
		var is_digit := u >= 48 and u <= 57
		if is_alpha or is_digit or c == " " or c == "-" or c == "_":
			out += c
	return out

# Reset to Vanilla: switch the active profile to VANILLA_PROFILE, wipe the
# hook pack + override.cfg, and restart the game clean. The active profile
# pointer is the ONLY thing we touch in the config -- stored profiles survive
# so the user can switch back and restore their selection.
#
# Important: we do NOT call _save_ui_config here. That would rewrite the
# currently-active profile's sections from the in-memory _ui_mod_entries
# state, which callers often set to all-disabled before invoking us.

func _reset_to_vanilla_and_restart(win: Window) -> void:
	_log_info("[Reset] User triggered Reset to Vanilla")
	var cfg := ConfigFile.new()
	cfg.load(UI_CONFIG_PATH)
	cfg.set_value("settings", "active_profile", VANILLA_PROFILE)
	cfg.set_value("settings", "developer_mode", _developer_mode)
	cfg.save(UI_CONFIG_PATH)
	var log_lines := PackedStringArray()
	_static_force_vanilla_state("UI reset button", log_lines)
	for line in log_lines:
		_log_info(line)
	if is_instance_valid(win):
		win.queue_free()
	# Strip --modloader-restart so the relaunch is a clean Pass 1, not a Pass 2
	# that would expect pass state we just deleted.
	_modloader_restart(true)

# Tear down and rebuild the Mods tab in place. Called whenever profile state
# changes (switch, create, delete) or Developer Mode toggles, so rows and the
# profile bar reflect fresh _ui_mod_entries + _active_profile state.
func _rebuild_mods_tab(tabs: TabContainer) -> void:
	var old := tabs.get_node_or_null("Mods")
	if old == null:
		return
	var idx := old.get_index()
	tabs.remove_child(old)
	old.queue_free()
	var new_tab := build_mods_tab(tabs)
	new_tab.name = "Mods"
	tabs.add_child(new_tab)
	tabs.move_child(new_tab, idx)
	tabs.current_tab = idx

# Parent a dialog on the launcher window (fallback: tree root) so it layers
# over our always_on_top Window, and copy our dark theme onto it since theme
# lookup doesn't cross Window boundaries reliably.
func _attach_ui_dialog(d: Window) -> void:
	var parent: Node = _ui_window if _ui_window != null else get_tree().root
	parent.add_child(d)
	if _ui_window != null and _ui_window.theme != null:
		d.theme = _ui_window.theme

# Connect the same handler to both signals and a shared free-and-forget exit
# path. ConfirmationDialog fires `canceled` on Cancel and `close_requested` on
# ESC / window-X -- callers want both to behave the same.
func _connect_dialog_exits(d: ConfirmationDialog, on_confirm: Callable, on_dismiss: Callable) -> void:
	d.confirmed.connect(on_confirm)
	d.canceled.connect(on_dismiss)
	d.close_requested.connect(on_dismiss)

# Make a Control swap the bottom-bar hint label to `text` while hovered and
# restore the original on exit. Stand-in for Godot tooltips, which are popups
# that render behind our always_on_top launcher window.
func _wire_hint(c: Control, text: String) -> void:
	if _ui_hint_label == null:
		return
	var default_text := _ui_hint_label.text
	c.mouse_entered.connect(func():
		if is_instance_valid(_ui_hint_label):
			_ui_hint_label.text = text
	)
	c.mouse_exited.connect(func():
		if is_instance_valid(_ui_hint_label):
			_ui_hint_label.text = default_text
	)

# Modal opens from the red "suspicious code" tag on a mod row. Lists the
# specific patterns the scanner matched. Dismiss-only -- the actual
# launch-time gate lives in _confirm_red_launch.
func _show_security_findings_dialog(entry: Dictionary) -> void:
	var findings: Array = entry.get("security_findings", [])
	if findings.is_empty():
		return
	var d := AcceptDialog.new()
	var mod_name := str(entry.get("mod_name", "?"))
	d.title = "Suspicious code in " + mod_name
	d.ok_button_text = "Close"
	d.min_size = Vector2(580, 420)

	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size = Vector2(560, 380)
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	d.add_child(scroll)

	var body := VBoxContainer.new()
	body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	body.add_theme_constant_override("separation", 12)
	scroll.add_child(body)

	var intro := Label.new()
	intro.text = "The scanner found patterns in this mod's code that are commonly used by malware " \
			+ "(obfuscated string decoding combined with process spawning, anti-debug calls, etc.). " \
			+ "If you don't trust this mod, do not enable it."
	intro.modulate = Color(0.95, 0.6, 0.6)
	intro.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	intro.add_theme_font_size_override("font_size", 11)
	body.add_child(intro)

	body.add_child(HSeparator.new())

	var rule_color := Color(0.95, 0.4, 0.4)
	for f: Dictionary in findings:
		var card := VBoxContainer.new()
		card.add_theme_constant_override("separation", 4)
		body.add_child(card)

		var rule_lbl := Label.new()
		rule_lbl.text = str(f.get("rule", "?"))
		rule_lbl.modulate = rule_color
		rule_lbl.add_theme_font_size_override("font_size", 13)
		card.add_child(rule_lbl)

		var desc_lbl := Label.new()
		desc_lbl.text = str(f.get("description", ""))
		desc_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		desc_lbl.add_theme_font_size_override("font_size", 11)
		card.add_child(desc_lbl)

		var loc := str(f.get("file", "?"))
		if int(f.get("line", 0)) > 0:
			loc += ":" + str(f.get("line"))
		var loc_lbl := Label.new()
		loc_lbl.text = loc
		loc_lbl.modulate = Color(0.55, 0.55, 0.55)
		loc_lbl.add_theme_font_size_override("font_size", 10)
		card.add_child(loc_lbl)

		var preview := str(f.get("preview", ""))
		if not preview.is_empty():
			var pre_lbl := Label.new()
			pre_lbl.text = "  " + preview
			pre_lbl.modulate = Color(0.78, 0.85, 0.6)
			pre_lbl.add_theme_font_size_override("font_size", 11)
			pre_lbl.autowrap_mode = TextServer.AUTOWRAP_OFF
			pre_lbl.clip_text = true
			card.add_child(pre_lbl)

		body.add_child(HSeparator.new())

	_attach_ui_dialog(d)
	d.confirmed.connect(d.queue_free)
	d.close_requested.connect(d.queue_free)
	d.popup_centered()

# Mod entries that are currently enabled AND scored RED by the scanner.
# Used to gate Launch when the user has any of these toggled on.
func _enabled_red_mods() -> Array:
	var out: Array = []
	for entry in _ui_mod_entries:
		if entry.get("enabled", false) and int(entry.get("risk_level", 0)) == 2:
			out.append(entry)
	return out

# Launch-time confirmation when one or more enabled mods are scored RED.
# Returns true if the user confirms launch, false if they go back. Loading
# is never silently bypassed; the user must explicitly acknowledge.
#
# Uses plain dialog_text so Godot auto-sizes the window to its content.
# A custom VBoxContainer body would let the window grow off-screen.
func _confirm_red_launch(red_mods: Array) -> bool:
	var d := ConfirmationDialog.new()
	d.title = "Suspicious mods enabled"
	d.ok_button_text = "Launch anyway"
	d.cancel_button_text = "Go back"
	d.dialog_autowrap = true
	# Width floor so the autowrap doesn't squeeze the text into a narrow
	# column; height left to grow with the mod list.
	d.min_size = Vector2(560, 120)

	var lines := PackedStringArray()
	lines.append("The scanner found patterns in the following mod(s) that are commonly used by malware. If you don't trust them, go back and disable them before launching.")
	lines.append("")
	for entry: Dictionary in red_mods:
		lines.append("    " + str(entry.get("mod_name", "?")))
	d.dialog_text = "\n".join(lines)

	_attach_ui_dialog(d)
	# Force dialog above the always_on_top launcher. Without this, clicking
	# the launcher's X (which routes to the same Launch handler) sometimes
	# parents-off the dialog behind the launcher and leaves input frozen.
	d.exclusive = true
	d.always_on_top = true
	# Red text on the destructive button so "Launch anyway" reads as the
	# risky option. Same modulate trick as _show_vanilla_confirm.
	d.get_ok_button().modulate = Color(1.0, 0.55, 0.55)

	# Single-result polling: lambdas mark done + capture the choice.
	# Array used because GDScript closures hold object references.
	var state := [false, false]  # [done, confirmed]
	d.confirmed.connect(func():
		state[0] = true
		state[1] = true)
	d.canceled.connect(func(): state[0] = true)
	d.close_requested.connect(func(): state[0] = true)
	d.popup_centered()
	d.grab_focus()
	while not state[0]:
		await get_tree().process_frame
	d.queue_free()
	return state[1]

# Vanilla dropdown entry: confirm, then run the full reset-and-restart flow.
# Cancel rebuilds the Mods tab so the dropdown reverts from "Vanilla" back to
# the currently-active profile.
func _show_vanilla_confirm(tabs: TabContainer) -> void:
	var d := ConfirmationDialog.new()
	d.title = "Reset to Vanilla"
	d.dialog_text = "This will disable all mods, wipe the hook cache and override.cfg, and restart the game clean.\n\nYour saved profiles are kept -- switch back to any of them later to re-enable those mods.\n\nContinue?"
	d.ok_button_text = "Reset and Restart"
	_attach_ui_dialog(d)
	# Red text on the destructive button. theme_color_override on the OK
	# button didn't take effect for reasons I haven't chased; modulate works
	# because dark bg (~0.06) tints imperceptibly while light text (~0.84)
	# multiplies into a clear red.
	d.get_ok_button().modulate = Color(1.0, 0.55, 0.55)
	var win_ref := _ui_window
	_connect_dialog_exits(d,
		func():
			d.queue_free()
			_reset_to_vanilla_and_restart(win_ref),
		func():
			d.queue_free()
			_rebuild_mods_tab(tabs))
	d.popup_centered()

# New Profile dialog: prompt for a name, validate, snapshot current state
# into the new profile, switch to it. Cancel leaves everything unchanged.
func _show_new_profile_dialog(tabs: TabContainer) -> void:
	var d := ConfirmationDialog.new()
	d.title = "New Profile"
	d.ok_button_text = "Create"
	d.dialog_hide_on_ok = false  # keep open until we validate the name

	var form := VBoxContainer.new()
	form.custom_minimum_size = Vector2(320, 0)
	form.add_theme_constant_override("separation", 6)
	d.add_child(form)

	var prompt := Label.new()
	prompt.text = "Profile name (letters, digits, spaces, _-):"
	form.add_child(prompt)

	var name_edit := LineEdit.new()
	name_edit.custom_minimum_size.x = 280
	form.add_child(name_edit)

	var err_lbl := Label.new()
	err_lbl.modulate = Color(1.0, 0.5, 0.5)
	err_lbl.add_theme_font_size_override("font_size", 11)
	form.add_child(err_lbl)

	_attach_ui_dialog(d)

	var existing := _list_profiles()
	var try_create := func():
		var name := _sanitize_profile_name(name_edit.text)
		if name == "":
			err_lbl.text = "Name cannot be empty or all invalid characters."
		elif name.to_lower() == "vanilla" or name == VANILLA_PROFILE:
			err_lbl.text = "That name is reserved."
		elif name in existing:
			err_lbl.text = "Profile \"" + name + "\" already exists."
		else:
			d.queue_free()
			_create_profile(name)
			_rebuild_mods_tab(tabs)

	name_edit.text_submitted.connect(func(_t): try_create.call())
	_connect_dialog_exits(d, try_create, func(): d.queue_free())
	d.popup_centered()
	name_edit.grab_focus()

# Rename dialog. Same validation rules as New (letters/digits/space/_-, not
# empty, not "Vanilla", not colliding with another profile). Renaming to the
# same name is a silent no-op.
func _show_rename_profile_dialog(tabs: TabContainer) -> void:
	var current := _active_profile
	var d := ConfirmationDialog.new()
	d.title = "Rename Profile"
	d.ok_button_text = "Rename"
	d.dialog_hide_on_ok = false

	var form := VBoxContainer.new()
	form.custom_minimum_size = Vector2(320, 0)
	form.add_theme_constant_override("separation", 6)
	d.add_child(form)

	var prompt := Label.new()
	prompt.text = "New name for \"" + current + "\":"
	form.add_child(prompt)

	var name_edit := LineEdit.new()
	name_edit.custom_minimum_size.x = 280
	name_edit.text = current
	form.add_child(name_edit)

	var err_lbl := Label.new()
	err_lbl.modulate = Color(1.0, 0.5, 0.5)
	err_lbl.add_theme_font_size_override("font_size", 11)
	form.add_child(err_lbl)

	_attach_ui_dialog(d)

	var existing := _list_profiles()
	var try_rename := func():
		var name := _sanitize_profile_name(name_edit.text)
		if name == "":
			err_lbl.text = "Name cannot be empty or all invalid characters."
		elif name.to_lower() == "vanilla" or name == VANILLA_PROFILE:
			err_lbl.text = "That name is reserved."
		elif name == current:
			d.queue_free()  # no-op
		elif name in existing:
			err_lbl.text = "Profile \"" + name + "\" already exists."
		else:
			d.queue_free()
			_rename_profile(name)
			_rebuild_mods_tab(tabs)

	name_edit.text_submitted.connect(func(_t): try_rename.call())
	_connect_dialog_exits(d, try_rename, func(): d.queue_free())
	d.popup_centered()
	name_edit.select_all()
	name_edit.grab_focus()

# Combined Import / Export dialog. Top half shows the active profile's
# checksummed payload with a Copy button; bottom half is a paste area +
# Import button. Name collisions prompt for an overwrite confirm.
func _show_share_profile_dialog(tabs: TabContainer) -> void:
	var current := _active_profile
	var payload := _profile_to_payload(current)

	var d := AcceptDialog.new()
	d.title = "Import / Export Profile"
	d.ok_button_text = "Close"

	var box := VBoxContainer.new()
	box.custom_minimum_size = Vector2(560, 500)
	box.add_theme_constant_override("separation", 8)
	d.add_child(box)

	# -- Export half -----------------------------------------------------------
	var export_lbl := Label.new()
	if payload != "":
		export_lbl.text = "Profile \"" + current + "\" -- copy and share this payload:"
	else:
		export_lbl.text = "Nothing to export (active profile has no saved data yet)."
		export_lbl.modulate = Color(0.55, 0.55, 0.55)
	box.add_child(export_lbl)

	var export_text := TextEdit.new()
	export_text.text = payload
	export_text.editable = false
	export_text.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
	export_text.custom_minimum_size.y = 120
	box.add_child(export_text)

	var copy_btn := Button.new()
	copy_btn.text = "Copy to Clipboard"
	copy_btn.disabled = payload == ""
	box.add_child(copy_btn)
	copy_btn.pressed.connect(func():
		DisplayServer.clipboard_set(payload)
		copy_btn.text = "Copied!"
	)

	box.add_child(HSeparator.new())

	# -- Import half -----------------------------------------------------------
	var import_lbl := Label.new()
	import_lbl.text = "Or paste someone else's payload to import their profile:"
	box.add_child(import_lbl)

	var import_text := TextEdit.new()
	import_text.editable = true
	import_text.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
	import_text.custom_minimum_size.y = 100
	box.add_child(import_text)

	var err_lbl := Label.new()
	err_lbl.modulate = Color(1.0, 0.5, 0.5)
	err_lbl.add_theme_font_size_override("font_size", 11)
	box.add_child(err_lbl)

	var import_btn := Button.new()
	import_btn.text = "Import"
	box.add_child(import_btn)

	_attach_ui_dialog(d)

	# Import flow: parse, validate, prompt-to-overwrite if name collides,
	# otherwise apply + switch + rebuild in one step.
	var do_import := func():
		var parsed := _parse_profile_payload(import_text.text)
		if parsed.has("error"):
			err_lbl.text = parsed["error"]
			return
		var name := _sanitize_profile_name(parsed["name"])
		if name == "" or name.to_lower() == "vanilla" or name == VANILLA_PROFILE:
			err_lbl.text = "Payload contains an invalid profile name."
			return
		var apply := func():
			_import_profile_from_parsed(parsed)
			d.queue_free()
			_rebuild_mods_tab(tabs)
		if name in _list_profiles():
			var cd := ConfirmationDialog.new()
			cd.title = "Overwrite Profile"
			cd.dialog_text = "Profile \"" + name + "\" already exists. Overwrite it with the pasted payload?"
			cd.ok_button_text = "Overwrite"
			_attach_ui_dialog(cd)
			_connect_dialog_exits(cd,
				func():
					cd.queue_free()
					apply.call(),
				func(): cd.queue_free())
			cd.popup_centered()
		else:
			apply.call()

	import_btn.pressed.connect(do_import)

	var dismiss := func(): d.queue_free()
	d.confirmed.connect(dismiss)
	d.close_requested.connect(dismiss)
	d.popup_centered()

# Delete-profile confirmation. The trash button is already disabled when the
# active profile is Vanilla or the last remaining user profile; the guard in
# _delete_active_profile is belt-and-suspenders.
func _show_delete_confirm(tabs: TabContainer) -> void:
	var target := _active_profile
	var d := ConfirmationDialog.new()
	d.title = "Delete Profile"
	d.dialog_text = "Delete profile \"" + target + "\"?\n\nThe mod selection stored in this profile will be discarded. Your other profiles are not affected."
	d.ok_button_text = "Delete"
	_attach_ui_dialog(d)
	_connect_dialog_exits(d,
		func():
			d.queue_free()
			_delete_active_profile()
			_rebuild_mods_tab(tabs),
		func(): d.queue_free())
	d.popup_centered()

# UI

func show_mod_ui() -> void:
	var win := Window.new()
	win.title = "Road to Vostok -- Mod Loader"
	win.size = Vector2i(960, 640)
	win.min_size = Vector2i(640, 420)
	win.wrap_controls = false
	win.always_on_top = true
	win.transparent = true
	win.transparent_bg = true
	get_tree().root.add_child(win)
	win.popup_centered()
	# Stash for dialogs triggered by profile-bar controls. Cleared on close.
	_ui_window = win

	# Kill the default Godot gray on the Window itself (embedded_border is the
	# stylebox that paints the window's own background area).
	var win_style := StyleBoxFlat.new()
	win_style.bg_color = Color(0.0, 0.0, 0.0)
	win.add_theme_stylebox_override("panel",                    win_style)
	win.add_theme_stylebox_override("embedded_border",          win_style.duplicate())
	win.add_theme_stylebox_override("embedded_unfocused_border", win_style.duplicate())

	# Solid dark background so Godot's default gray theme doesn't show through.
	var bg := Panel.new()
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var bg_s := StyleBoxFlat.new()
	bg_s.bg_color = Color(0.0, 0.0, 0.0, 0.6)
	bg_s.border_color = Color(1.0, 1.0, 1.0)
	bg_s.border_width_top    = 1
	bg_s.border_width_bottom = 1
	bg_s.border_width_left   = 1
	bg_s.border_width_right  = 1
	bg.add_theme_stylebox_override("panel", bg_s)
	win.add_child(bg)

	# Assign the dark theme on the Window itself so child Windows (OptionButton
	# popup + dialogs spawned from the profile bar) inherit it via the scene
	# tree. Setting it only on the MarginContainer misses sub-Windows.
	var dark_theme := make_dark_theme()
	win.theme = dark_theme

	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 10)
	margin.add_theme_constant_override("margin_right", 10)
	margin.add_theme_constant_override("margin_top", 8)
	margin.add_theme_constant_override("margin_bottom", 10)
	margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	margin.theme = dark_theme
	win.add_child(margin)

	var root := VBoxContainer.new()
	root.add_theme_constant_override("separation", 6)
	margin.add_child(root)

	var tabs := TabContainer.new()
	tabs.size_flags_vertical = Control.SIZE_EXPAND_FILL
	root.add_child(tabs)

	root.add_child(HSeparator.new())

	# Bottom bar: instructions + launch button
	var bottom := HBoxContainer.new()
	bottom.add_theme_constant_override("separation", 10)
	root.add_child(bottom)

	var hint := Label.new()
	hint.text = "Higher number loads later and wins when mods share files.\n" \
			+ "Developer Mode: verbose logging, conflict report, and loose folder loading."
	hint.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	hint.add_theme_font_size_override("font_size", 11)
	hint.modulate = Color(0.45, 0.45, 0.45)
	bottom.add_child(hint)
	# Expose for _wire_hint so toolbar/dropdown hovers can temporarily repurpose
	# this label as a status-line substitute for broken Godot tooltips.
	_ui_hint_label = hint

	var launch_btn := Button.new()
	launch_btn.text = "  Launch Game  "
	launch_btn.custom_minimum_size = Vector2(130, 36)
	var ls_n := StyleBoxFlat.new()
	ls_n.bg_color = Color(0.05, 0.05, 0.05)
	ls_n.border_color = Color(0.28, 0.28, 0.28)
	ls_n.border_width_top = 1; ls_n.border_width_bottom = 1
	ls_n.border_width_left = 1; ls_n.border_width_right = 1
	ls_n.content_margin_left = 10; ls_n.content_margin_right = 10
	launch_btn.add_theme_stylebox_override("normal", ls_n)
	var ls_h := ls_n.duplicate()
	ls_h.bg_color = Color(0.10, 0.10, 0.10)
	ls_h.border_color = Color(0.55, 0.55, 0.55)
	launch_btn.add_theme_stylebox_override("hover", ls_h)
	var ls_p := ls_n.duplicate()
	ls_p.bg_color = Color(0.03, 0.03, 0.03)
	launch_btn.add_theme_stylebox_override("pressed", ls_p)
	launch_btn.add_theme_color_override("font_color", Color(0.88, 0.88, 0.88))
	launch_btn.add_theme_color_override("font_hover_color", Color(1.0, 1.0, 1.0))
	bottom.add_child(launch_btn)

	# Closing the window with X should behave the same as clicking Launch.
	win.close_requested.connect(func(): launch_btn.pressed.emit())

	var mods_tab := build_mods_tab(tabs)
	mods_tab.name = "Mods"
	tabs.add_child(mods_tab)

	var updates_tab := build_updates_tab()
	updates_tab.name = "Updates"
	tabs.add_child(updates_tab)

	# Launch loop. If any enabled mod has the scanner's RED risk_level,
	# show a confirmation dialog before proceeding. Cancel returns the
	# user to the launcher so they can disable the flagged mod or
	# reconsider; confirm proceeds. No gate when no red mods are enabled.
	while true:
		await launch_btn.pressed
		var red_mods := _enabled_red_mods()
		if red_mods.is_empty():
			break
		var proceed: bool = await _confirm_red_launch(red_mods)
		if proceed:
			break
		# else: loop and wait for Launch again
	_ui_window = null
	_ui_hint_label = null
	win.queue_free()

# Runtime-generated 16x16 pencil icon. Monochrome outline in button-text
# gray so it matches the rest of the UI -- a colored pencil looks like an
# emoji in this context.
func _make_pencil_icon() -> ImageTexture:
	var img := Image.create(16, 16, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))
	var line := Color(0.84, 0.84, 0.84)  # matches C_TEXT in make_dark_theme
	# Body outline: rectangle from (1,5) to (12,9).
	for x in range(1, 13):
		img.set_pixel(x, 5, line)
		img.set_pixel(x, 9, line)
	for y in range(5, 10):
		img.set_pixel(1, y, line)
		img.set_pixel(12, y, line)
	# Divider between eraser compartment and main body.
	for y in range(5, 10):
		img.set_pixel(4, y, line)
	# Triangular tip sticking off the right side.
	img.set_pixel(13, 6, line)
	img.set_pixel(13, 7, line)
	img.set_pixel(13, 8, line)
	img.set_pixel(14, 7, line)
	return ImageTexture.create_from_image(img)

# Runtime-generated 16x16 trashcan: lid handle on top, rectangular body with
# three vertical slots.
func _make_trashcan_icon() -> ImageTexture:
	var img := Image.create(16, 16, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))
	var line := Color(0.84, 0.84, 0.84)  # matches C_TEXT in make_dark_theme
	# Lid handle (short bar on top).
	for x in range(6, 10):
		img.set_pixel(x, 2, line)
	# Lid (wider bar).
	for x in range(3, 13):
		img.set_pixel(x, 4, line)
	# Body sides + floor.
	for y in range(5, 14):
		img.set_pixel(4, y, line)
		img.set_pixel(11, y, line)
	for x in range(5, 11):
		img.set_pixel(x, 13, line)
	# Three vertical slots for texture.
	for y in range(6, 12):
		img.set_pixel(6, y, line)
		img.set_pixel(8, y, line)
		img.set_pixel(10, y, line)
	return ImageTexture.create_from_image(img)

func make_dark_theme() -> Theme:
	var t := Theme.new()

	const C_PANEL := Color(0.04, 0.04, 0.04)
	const C_BTN   := Color(0.07, 0.07, 0.07)
	const C_BORD  := Color(0.18, 0.18, 0.18)
	const C_HI    := Color(0.90, 0.90, 0.90)
	const C_TEXT  := Color(0.84, 0.84, 0.84)
	const C_DIM   := Color(0.42, 0.42, 0.42)

	# -- Button ----------------------------------------------------------------
	var bn := StyleBoxFlat.new()
	bn.bg_color = C_BTN
	bn.border_color = C_BORD
	bn.border_width_top = 1; bn.border_width_bottom = 1
	bn.border_width_left = 1; bn.border_width_right = 1
	bn.content_margin_left = 8; bn.content_margin_right = 8
	bn.content_margin_top = 3; bn.content_margin_bottom = 3
	var bh := bn.duplicate()
	bh.bg_color = Color(0.10, 0.10, 0.10); bh.border_color = C_HI
	var bp := bn.duplicate(); bp.bg_color = Color(0.03, 0.03, 0.03)
	var bd := bn.duplicate()
	bd.bg_color = Color(0.04, 0.04, 0.04); bd.border_color = Color(0.12, 0.12, 0.12)
	t.set_stylebox("normal",   "Button", bn)
	t.set_stylebox("hover",    "Button", bh)
	t.set_stylebox("pressed",  "Button", bp)
	t.set_stylebox("disabled", "Button", bd)
	t.set_stylebox("focus",    "Button", StyleBoxEmpty.new())
	t.set_color("font_color",          "Button", C_TEXT)
	t.set_color("font_hover_color",    "Button", Color(1.0, 1.0, 1.0))
	t.set_color("font_pressed_color",  "Button", C_TEXT)
	t.set_color("font_disabled_color", "Button", C_DIM)

	# -- CheckBox (font only -- box glyph needs texture to restyle) -------------
	t.set_color("font_color",       "CheckBox", C_TEXT)
	t.set_color("font_hover_color", "CheckBox", Color(1.0, 1.0, 1.0))

	# -- Label -----------------------------------------------------------------
	t.set_color("font_color", "Label", C_TEXT)

	# -- Panel / PanelContainer ------------------------------------------------
	var ps := StyleBoxFlat.new(); ps.bg_color = C_PANEL
	t.set_stylebox("panel", "Panel",          ps)
	t.set_stylebox("panel", "PanelContainer", ps.duplicate())

	# -- TabContainer ----------------------------------------------------------
	var ts := StyleBoxFlat.new()   # selected tab
	ts.bg_color = C_PANEL
	ts.border_color = C_BORD
	ts.border_width_top = 1; ts.border_width_left = 1; ts.border_width_right = 1
	ts.border_width_bottom = 0
	ts.content_margin_left = 12; ts.content_margin_right = 12
	ts.content_margin_top = 5;   ts.content_margin_bottom = 5
	var tu := ts.duplicate()      # unselected tab
	tu.bg_color = Color(0.02, 0.02, 0.02)
	tu.border_color = Color(0.12, 0.12, 0.12)
	tu.border_width_bottom = 1
	var tc_panel := StyleBoxFlat.new(); tc_panel.bg_color = C_PANEL
	tc_panel.content_margin_left   = 10
	tc_panel.content_margin_right  = 10
	tc_panel.content_margin_top    = 8
	tc_panel.content_margin_bottom = 8
	t.set_stylebox("tab_selected",   "TabContainer", ts)
	t.set_stylebox("tab_unselected", "TabContainer", tu)
	t.set_stylebox("tab_hovered",    "TabContainer", tu.duplicate())
	t.set_stylebox("panel",          "TabContainer", tc_panel)
	t.set_color("font_selected_color",   "TabContainer", C_HI)
	t.set_color("font_unselected_color", "TabContainer", C_DIM)
	t.set_color("font_hovered_color",    "TabContainer", C_TEXT)

	# -- HSeparator ------------------------------------------------------------
	var sep := StyleBoxFlat.new(); sep.bg_color = Color(0.14, 0.14, 0.14)
	t.set_stylebox("separator", "HSeparator", sep)
	t.set_constant("separation", "HSeparator", 1)

	# -- LineEdit (SpinBox uses this internally) --------------------------------
	var le := StyleBoxFlat.new()
	le.bg_color = Color(0.04, 0.04, 0.04)
	le.border_color = C_BORD
	le.border_width_top = 1; le.border_width_bottom = 1
	le.border_width_left = 1; le.border_width_right = 1
	le.content_margin_left = 6; le.content_margin_right = 6
	le.content_margin_top = 3; le.content_margin_bottom = 3
	t.set_stylebox("normal", "LineEdit", le)
	t.set_stylebox("focus",  "LineEdit", le.duplicate())
	t.set_color("font_color", "LineEdit", C_TEXT)

	# -- ScrollContainer (transparent, scrollbars inherit) ---------------------
	t.set_stylebox("panel", "ScrollContainer", StyleBoxEmpty.new())

	# -- PopupMenu (OptionButton dropdown) -------------------------------------
	var pm_panel := StyleBoxFlat.new()
	pm_panel.bg_color = Color(0.06, 0.06, 0.06)
	pm_panel.border_color = C_BORD
	pm_panel.border_width_top = 1; pm_panel.border_width_bottom = 1
	pm_panel.border_width_left = 1; pm_panel.border_width_right = 1
	pm_panel.content_margin_left = 4; pm_panel.content_margin_right = 4
	pm_panel.content_margin_top = 4;  pm_panel.content_margin_bottom = 4
	t.set_stylebox("panel", "PopupMenu", pm_panel)
	var pm_hover := StyleBoxFlat.new()
	pm_hover.bg_color = Color(0.14, 0.14, 0.14)
	t.set_stylebox("hover", "PopupMenu", pm_hover)
	var pm_sep := StyleBoxFlat.new()
	pm_sep.bg_color = C_BORD
	pm_sep.content_margin_top = 1; pm_sep.content_margin_bottom = 1
	t.set_stylebox("separator", "PopupMenu", pm_sep)
	t.set_color("font_color",           "PopupMenu", C_TEXT)
	t.set_color("font_hover_color",     "PopupMenu", Color(1.0, 1.0, 1.0))
	t.set_color("font_disabled_color",  "PopupMenu", C_DIM)
	t.set_color("font_separator_color", "PopupMenu", C_DIM)

	# -- OptionButton (themed like Button but needs its own panel stylebox
	#    because OptionButton uses a separate theme type from Button) ----------
	t.set_stylebox("normal",   "OptionButton", bn.duplicate())
	t.set_stylebox("hover",    "OptionButton", bh.duplicate())
	t.set_stylebox("pressed",  "OptionButton", bp.duplicate())
	t.set_stylebox("disabled", "OptionButton", bd.duplicate())
	t.set_stylebox("focus",    "OptionButton", StyleBoxEmpty.new())
	t.set_color("font_color",         "OptionButton", C_TEXT)
	t.set_color("font_hover_color",   "OptionButton", Color(1.0, 1.0, 1.0))
	t.set_color("font_pressed_color", "OptionButton", C_TEXT)

	# -- Tooltip (hover hint panel) --------------------------------------------
	# Without these our tooltips render with the default light theme and get
	# lost behind the always_on_top launcher window.
	var tt_panel := StyleBoxFlat.new()
	tt_panel.bg_color = Color(0.10, 0.10, 0.10)
	tt_panel.border_color = C_BORD
	tt_panel.border_width_top = 1; tt_panel.border_width_bottom = 1
	tt_panel.border_width_left = 1; tt_panel.border_width_right = 1
	tt_panel.content_margin_left = 8; tt_panel.content_margin_right = 8
	tt_panel.content_margin_top = 4;  tt_panel.content_margin_bottom = 4
	t.set_stylebox("panel", "TooltipPanel", tt_panel)
	t.set_color("font_color", "TooltipLabel", C_TEXT)

	# -- AcceptDialog / ConfirmationDialog -------------------------------------
	# The dialog's own panel background + embedded-window border styleboxes.
	var dlg_panel := StyleBoxFlat.new()
	dlg_panel.bg_color = Color(0.06, 0.06, 0.06)
	dlg_panel.border_color = C_BORD
	dlg_panel.border_width_top = 1; dlg_panel.border_width_bottom = 1
	dlg_panel.border_width_left = 1; dlg_panel.border_width_right = 1
	dlg_panel.content_margin_left = 10; dlg_panel.content_margin_right = 10
	dlg_panel.content_margin_top = 8;   dlg_panel.content_margin_bottom = 8
	t.set_stylebox("panel", "AcceptDialog", dlg_panel)
	t.set_stylebox("panel", "ConfirmationDialog", dlg_panel.duplicate())
	t.set_stylebox("embedded_border",           "Window", dlg_panel.duplicate())
	t.set_stylebox("embedded_unfocused_border", "Window", dlg_panel.duplicate())
	t.set_color("title_color", "Window", C_HI)

	return t

func build_mods_tab(tabs: TabContainer) -> Control:
	var outer := VBoxContainer.new()
	outer.size_flags_vertical = Control.SIZE_EXPAND_FILL

	# -- Toolbar (profile selector + folder shortcut + dev toggle) ------------
	# Single row: Open Mods Folder | Profile: [dropdown] [+] [pencil] [trash] [Share] | ... | Developer Mode

	var toolbar := HBoxContainer.new()
	toolbar.add_theme_constant_override("separation", 8)
	outer.add_child(toolbar)

	var open_btn := Button.new()
	open_btn.text = "Open Mods Folder"
	toolbar.add_child(open_btn)
	open_btn.pressed.connect(func():
		OS.shell_open(ProjectSettings.globalize_path(_mods_dir))
	)
	_wire_hint(open_btn, "Open the game's mods folder in your file manager.")

	# Small visual gap between folder button and profile controls.
	var pre_profile_gap := Control.new()
	pre_profile_gap.custom_minimum_size.x = 12
	toolbar.add_child(pre_profile_gap)

	var profile_lbl := Label.new()
	profile_lbl.text = "Profile:"
	toolbar.add_child(profile_lbl)

	var profile_opt := OptionButton.new()
	profile_opt.custom_minimum_size.x = 180
	toolbar.add_child(profile_opt)

	# The dropdown popup is a sub-Window. Our modloader Window is always_on_top,
	# which leaves the popup stranded behind it (invisible on click). Mark the
	# popup always_on_top and transient so it layers over us correctly. Theme
	# assignment is explicit -- theme lookup doesn't always cross Window boundaries.
	var profile_popup := profile_opt.get_popup()
	profile_popup.always_on_top = true
	profile_popup.transient = true
	if _ui_window != null and _ui_window.theme != null:
		profile_popup.theme = _ui_window.theme

	# Item 0 is Vanilla; selecting it shows the reset-and-restart confirm.
	# Godot 4 PopupMenu has no per-item text color, so the danger cue lives
	# in the confirmation dialog's red OK button rather than on this entry.
	profile_opt.add_item("Vanilla")
	profile_opt.set_item_metadata(0, VANILLA_PROFILE)

	# Fresh install has no profile sections yet -- show Default as a placeholder
	# that gets materialized on the first _save_ui_config (Launch or any toggle).
	var profiles := _list_profiles()
	if profiles.is_empty():
		profiles = ["Default"]
	var active_idx := 0  # fall back to Vanilla if no user profile matches
	for name: String in profiles:
		profile_opt.add_item(name)
		var idx := profile_opt.item_count - 1
		profile_opt.set_item_metadata(idx, name)
		if name == _active_profile:
			active_idx = idx
	profile_opt.selected = active_idx

	# Profile-mutation buttons. Rename/Delete guard against Vanilla (sentinel
	# has no underlying profile); Delete additionally needs at least one
	# other profile to switch to.
	var on_vanilla := _active_profile == VANILLA_PROFILE

	var new_profile_btn := Button.new()
	new_profile_btn.text = "+"
	new_profile_btn.tooltip_text = "New profile from current mod selection"
	new_profile_btn.custom_minimum_size.x = 28
	toolbar.add_child(new_profile_btn)
	_wire_hint(new_profile_btn, "New profile from current mod selection.")

	var rename_btn := Button.new()
	rename_btn.icon = _make_pencil_icon()
	rename_btn.tooltip_text = "Rename the active profile"
	rename_btn.disabled = on_vanilla
	rename_btn.custom_minimum_size.x = 28
	toolbar.add_child(rename_btn)
	_wire_hint(rename_btn, "Rename the active profile.")

	# Delete is disabled on Vanilla (nothing concrete to delete) and when only
	# one user profile exists (we always need at least one to switch to).
	var del_profile_btn := Button.new()
	del_profile_btn.icon = _make_trashcan_icon()
	del_profile_btn.tooltip_text = "Delete the active profile"
	del_profile_btn.disabled = on_vanilla or profiles.size() <= 1
	del_profile_btn.custom_minimum_size.x = 28
	toolbar.add_child(del_profile_btn)
	_wire_hint(del_profile_btn, "Delete the active profile.")

	# Always enabled: even on Vanilla or an empty profile, users may want to
	# paste in someone else's shared payload.
	var share_btn := Button.new()
	share_btn.text = "Share"
	share_btn.tooltip_text = "Copy this profile to share, or paste one from someone else"
	toolbar.add_child(share_btn)
	_wire_hint(share_btn, "Copy this profile to share, or paste one from someone else.")

	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	toolbar.add_child(spacer)

	var dev_check := CheckBox.new()
	dev_check.text = "Developer Mode"
	dev_check.tooltip_text = "Enables verbose logging, conflict report, and loose folder loading"
	dev_check.button_pressed = _developer_mode
	dev_check.add_theme_font_size_override("font_size", 11)
	dev_check.modulate = Color(0.45, 0.45, 0.45)
	toolbar.add_child(dev_check)
	_wire_hint(dev_check, "Developer Mode: verbose logging, conflict report, and loose folder loading.")

	profile_opt.item_selected.connect(func(idx: int):
		var meta = profile_opt.get_item_metadata(idx)
		if meta == VANILLA_PROFILE:
			_show_vanilla_confirm(tabs)
		else:
			_switch_profile(str(meta))
			_rebuild_mods_tab(tabs)
	)
	new_profile_btn.pressed.connect(func(): _show_new_profile_dialog(tabs))
	rename_btn.pressed.connect(func(): _show_rename_profile_dialog(tabs))
	del_profile_btn.pressed.connect(func(): _show_delete_confirm(tabs))
	share_btn.pressed.connect(func(): _show_share_profile_dialog(tabs))

	dev_check.toggled.connect(func(on: bool):
		_developer_mode = on
		_ui_mod_entries = collect_mod_metadata()
		_load_ui_config()
		_rebuild_mods_tab(tabs)
	)

	outer.add_child(HSeparator.new())

	var split := HSplitContainer.new()
	split.split_offset = 560
	split.size_flags_vertical = Control.SIZE_EXPAND_FILL
	outer.add_child(split)

	# -- Left: mod list --------------------------------------------------------

	var left_scroll := ScrollContainer.new()
	left_scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	left_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	split.add_child(left_scroll)

	# Right padding keeps the load-order SpinBox arrows from sitting flush
	# against the vertical scrollbar -- users were hitting the spin arrows
	# while trying to drag the scrollbar handle.
	var list_pad := MarginContainer.new()
	list_pad.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	list_pad.add_theme_constant_override("margin_right", 16)
	left_scroll.add_child(list_pad)

	var list := VBoxContainer.new()
	list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	list_pad.add_child(list)

	# -- Right: live load order preview ----------------------------------------

	var right := VBoxContainer.new()
	right.custom_minimum_size.x = 220
	split.add_child(right)

	var order_header := Label.new()
	order_header.text = "Load Order"
	order_header.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	right.add_child(order_header)
	right.add_child(HSeparator.new())

	# Dark panel behind the load order list for visual separation.
	var order_panel := PanelContainer.new()
	order_panel.size_flags_vertical = Control.SIZE_EXPAND_FILL
	var panel_style := StyleBoxFlat.new()
	panel_style.bg_color = Color(0.09, 0.09, 0.09)
	panel_style.content_margin_left = 8
	panel_style.content_margin_right = 8
	panel_style.content_margin_top = 6
	panel_style.content_margin_bottom = 6
	order_panel.add_theme_stylebox_override("panel", panel_style)
	right.add_child(order_panel)

	var order_scroll := ScrollContainer.new()
	order_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	order_panel.add_child(order_scroll)

	var order_list := VBoxContainer.new()
	order_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	order_scroll.add_child(order_list)

	# Rebuilds the right-side order list from current entry state.
	var refresh_order := func():
		for child in order_list.get_children():
			child.queue_free()
		var sorted := _ui_mod_entries.filter(func(e): return e["enabled"])
		sorted.sort_custom(_compare_load_order)
		if sorted.is_empty():
			var lbl := Label.new()
			lbl.text = "(none enabled)"
			lbl.modulate = Color(0.5, 0.5, 0.5)
			order_list.add_child(lbl)
			return
		for i in sorted.size():
			var e: Dictionary = sorted[i]
			var lbl := Label.new()
			lbl.text = str(i + 1) + ".  " + e["mod_name"]
			lbl.add_theme_font_size_override("font_size", 12)
			lbl.modulate = Color(0.80, 0.80, 0.80)
			lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
			order_list.add_child(lbl)

	# -- Missing from this profile --------------------------------------------
	# Mods the active profile references but that aren't on disk. Shown at the
	# top of the list so they get attention before the regular mod rows; each
	# has a Remove button to strip the orphaned keys from the profile. Future:
	# offer to download via modworkshop if an id is stored.
	var missing_files := _missing_mods_in_active_profile()
	if not missing_files.is_empty():
		var missing_hdr := Label.new()
		missing_hdr.text = "Missing from this profile"
		missing_hdr.modulate = Color(1.0, 0.55, 0.55)
		missing_hdr.add_theme_font_size_override("font_size", 11)
		list.add_child(missing_hdr)
		list.add_child(HSeparator.new())
		for fn: String in missing_files:
			var miss_row := HBoxContainer.new()
			list.add_child(miss_row)
			var miss_lbl := Label.new()
			var display := fn.trim_prefix("zip:")
			miss_lbl.text = display + "  --  not installed"
			miss_lbl.modulate = Color(1.0, 0.45, 0.45)
			miss_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			miss_row.add_child(miss_lbl)
			var remove_btn := Button.new()
			remove_btn.text = "Remove"
			remove_btn.tooltip_text = "Strip this entry from the active profile"
			miss_row.add_child(remove_btn)
			var captured := fn
			remove_btn.pressed.connect(func():
				_remove_missing_entry_from_profile(captured)
				_rebuild_mods_tab(tabs)
			)
			list.add_child(HSeparator.new())

	# -- Column headers --------------------------------------------------------

	var header_row := HBoxContainer.new()
	list.add_child(header_row)

	var h_on := Label.new()
	h_on.text = "On"
	h_on.custom_minimum_size.x = 30
	header_row.add_child(h_on)

	var h_name := Label.new()
	h_name.text = "Mod"
	h_name.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header_row.add_child(h_name)

	var h_prio := Label.new()
	h_prio.text = "Load Order"
	h_prio.custom_minimum_size.x = 100
	h_prio.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	header_row.add_child(h_prio)

	list.add_child(HSeparator.new())

	# -- One row per mod -------------------------------------------------------

	# Vanilla has no editable state; hint users to pick a profile before they
	# try to toggle anything. Controls below are disabled alongside this note.
	if on_vanilla and not _ui_mod_entries.is_empty():
		var vanilla_note := Label.new()
		vanilla_note.text = "Vanilla active -- switch to a profile to edit mods."
		vanilla_note.modulate = Color(1.0, 0.55, 0.55)
		vanilla_note.add_theme_font_size_override("font_size", 11)
		list.add_child(vanilla_note)
		list.add_child(HSeparator.new())

	if _ui_mod_entries.is_empty():
		var empty := Label.new()
		empty.text = "No mods found.\n\nPlace .vmz or .pck files in:\n" \
				+ ProjectSettings.globalize_path(_mods_dir)
		empty.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		empty.modulate = Color(0.5, 0.5, 0.5)
		empty.add_theme_font_size_override("font_size", 12)
		list.add_child(empty)

	for entry in _ui_mod_entries:
		var row := HBoxContainer.new()
		list.add_child(row)

		var check := CheckBox.new()
		check.button_pressed = entry["enabled"]
		check.custom_minimum_size.x = 30
		row.add_child(check)

		var name_col := VBoxContainer.new()
		name_col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(name_col)

		var name_lbl := Label.new()
		name_lbl.text = entry["mod_name"]
		name_lbl.clip_text = true
		name_lbl.modulate = Color(0.58, 0.82, 0.38) if entry["enabled"] else Color(0.5, 0.5, 0.5)
		name_col.add_child(name_lbl)

		if entry["ext"] == "folder":
			var dev_lbl := Label.new()
			dev_lbl.text = "[dev folder]"
			dev_lbl.modulate = Color(0.9, 0.3, 0.3)
			dev_lbl.add_theme_font_size_override("font_size", 11)
			name_col.add_child(dev_lbl)
		for warn_text: String in entry.get("warnings", []):
			var warn := Label.new()
			warn.text = warn_text
			warn.modulate = Color(1.0, 0.6, 0.2)
			warn.add_theme_font_size_override("font_size", 11)
			name_col.add_child(warn)

		# Profile was saved with a different version of this mod. Surface the
		# change so the user knows their enabled/priority state was carried
		# over across the upgrade/downgrade rather than silently re-defaulted.
		var vm: Dictionary = entry.get("profile_version_mismatch", {})
		if not vm.is_empty():
			var stored_v: String = str(vm.get("stored", ""))
			var current_v: String = str(vm.get("current", ""))
			var stored_disp := stored_v if stored_v != "" else "(unset)"
			var current_disp := current_v if current_v != "" else "(unset)"
			var vm_lbl := Label.new()
			vm_lbl.text = "profile version: " + stored_disp + " -> " + current_disp
			vm_lbl.modulate = Color(1.0, 0.6, 0.2)
			vm_lbl.add_theme_font_size_override("font_size", 11)
			name_col.add_child(vm_lbl)

		# Scanner indicator. Only renders for RED risk -- mods whose source
		# combines patterns that are nearly diagnostic of malware (dropper
		# trinity, anti-debug crash, ransomware setup). Yellow ("uses
		# notable APIs") is computed and logged but deliberately not shown
		# in the UI: most legit mods have at least one elevated API and
		# surfacing every one would just generate help-channel noise.
		# Loading is never blocked either way; the user judges.
		var risk: int = int(entry.get("risk_level", 0))
		if risk == 2:
			var sec_btn := Button.new()
			sec_btn.text = "suspicious code"
			sec_btn.flat = true
			sec_btn.modulate = Color(0.95, 0.4, 0.4)
			sec_btn.add_theme_font_size_override("font_size", 11)
			sec_btn.alignment = HORIZONTAL_ALIGNMENT_LEFT
			sec_btn.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
			name_col.add_child(sec_btn)
			var captured_entry := entry
			sec_btn.pressed.connect(func(): _show_security_findings_dialog(captured_entry))

		# Vanilla has no stored profile; disable editing so auto-save can't
		# create a ghost `profile.__vanilla__.*` section.
		if entry["ext"] == "zip" or on_vanilla:
			check.disabled = true

		var spin := SpinBox.new()
		spin.min_value = PRIORITY_MIN
		spin.max_value = PRIORITY_MAX
		spin.value = entry["priority"]
		spin.custom_minimum_size.x = 100
		if entry["ext"] == "zip" or on_vanilla:
			spin.editable = false
		row.add_child(spin)

		list.add_child(HSeparator.new())

		# Capture entry by reference (Dictionaries are reference types in GDScript)
		var e := entry
		var nlbl := name_lbl
		check.toggled.connect(func(on: bool):
			e["enabled"] = on
			nlbl.modulate = Color(0.58, 0.82, 0.38) if on else Color(0.5, 0.5, 0.5)
			refresh_order.call()
			_save_ui_config()
		)
		spin.value_changed.connect(func(val: float):
			e["priority"] = int(val)
			refresh_order.call()
			_save_ui_config()
		)

	refresh_order.call()
	return outer

func build_updates_tab() -> Control:
	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 8)
	margin.add_theme_constant_override("margin_right", 8)
	margin.add_theme_constant_override("margin_top", 6)
	margin.add_theme_constant_override("margin_bottom", 6)

	var container := VBoxContainer.new()
	container.add_theme_constant_override("separation", 6)
	margin.add_child(container)

	var toolbar := HBoxContainer.new()
	toolbar.add_theme_constant_override("separation", 8)
	container.add_child(toolbar)

	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	toolbar.add_child(spacer)

	var check_btn := Button.new()
	check_btn.text = "Check for Updates"
	toolbar.add_child(check_btn)

	container.add_child(HSeparator.new())

	# Column headers
	var header_row := HBoxContainer.new()
	container.add_child(header_row)

	var h_mod := Label.new()
	h_mod.text = "Mod"
	h_mod.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header_row.add_child(h_mod)

	var h_ver := Label.new()
	h_ver.text = "Version"
	h_ver.custom_minimum_size.x = 90
	header_row.add_child(h_ver)

	var h_status := Label.new()
	h_status.text = "Status"
	h_status.custom_minimum_size.x = 160
	header_row.add_child(h_status)

	var h_action := Label.new()
	h_action.text = "Action"
	h_action.custom_minimum_size.x = 90
	header_row.add_child(h_action)

	container.add_child(HSeparator.new())

	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	container.add_child(scroll)

	var list := VBoxContainer.new()
	list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(list)

	# { label, version, mw_id, dl_btn, full_path, mod_name }
	var status_info: Dictionary = {}

	for entry in _ui_mod_entries:
		var cfg: ConfigFile = entry["cfg"]
		if cfg == null:
			continue
		var version := str(cfg.get_value("mod", "version", ""))
		var mw_id := 0
		if cfg.has_section_key("updates", "modworkshop"):
			mw_id = int(str(cfg.get_value("updates", "modworkshop", "")))

		var row := HBoxContainer.new()
		list.add_child(row)

		# Name column: mod name + last-modified date sub-label.
		var name_col := VBoxContainer.new()
		name_col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(name_col)

		var name_lbl := Label.new()
		name_lbl.text = entry["mod_name"]
		name_lbl.clip_text = true
		name_col.add_child(name_lbl)

		var mtime := FileAccess.get_modified_time(entry["full_path"])
		if mtime > 0:
			var dt := Time.get_datetime_dict_from_unix_time(mtime)
			var date_str := "%04d-%02d-%02d" % [dt["year"], dt["month"], dt["day"]]
			var mod_lbl := Label.new()
			mod_lbl.text = "modified " + date_str
			mod_lbl.add_theme_font_size_override("font_size", 11)
			mod_lbl.modulate = Color(0.5, 0.5, 0.5)
			name_col.add_child(mod_lbl)

		var ver_lbl := Label.new()
		ver_lbl.text = "v" + version if version != "" else "--"
		ver_lbl.custom_minimum_size.x = 90
		row.add_child(ver_lbl)

		var status_lbl := Label.new()
		status_lbl.custom_minimum_size.x = 160
		status_lbl.text = "no update info" if mw_id == 0 or version == "" else "--"
		row.add_child(status_lbl)

		# Always add dl_btn to preserve column width. Use modulate.a to
		# hide it visually without collapsing its layout slot.
		var dl_btn := Button.new()
		dl_btn.text = "Download"
		dl_btn.custom_minimum_size.x = 90
		dl_btn.modulate.a = 0.0
		dl_btn.disabled = true
		dl_btn.mouse_filter = Control.MOUSE_FILTER_IGNORE
		row.add_child(dl_btn)

		list.add_child(HSeparator.new())

		if mw_id > 0 and version != "":
			status_info[entry["file_name"]] = {
				"label": status_lbl, "ver_lbl": ver_lbl, "version": version, "mw_id": mw_id,
				"dl_btn": dl_btn, "full_path": entry["full_path"],
				"mod_name": entry["mod_name"],
			}

	if list.get_child_count() == 0:
		var lbl := Label.new()
		lbl.text = "No mods with update information found.\nAdd [updates] modworkshop=<id> and version=<x.y.z> to mod.txt to enable this."
		lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		list.add_child(lbl)

	# -- Activity log ----------------------------------------------------------

	container.add_child(HSeparator.new())

	var log_hdr := Label.new()
	log_hdr.text = "Activity"
	log_hdr.add_theme_font_size_override("font_size", 11)
	log_hdr.modulate = Color(0.65, 0.65, 0.65)
	container.add_child(log_hdr)

	var log_bg := PanelContainer.new()
	log_bg.custom_minimum_size.y = 72
	var log_style := StyleBoxFlat.new()
	log_style.bg_color = Color(0.09, 0.09, 0.09)
	log_style.content_margin_left = 6
	log_style.content_margin_right = 6
	log_style.content_margin_top = 4
	log_style.content_margin_bottom = 4
	log_bg.add_theme_stylebox_override("panel", log_style)
	container.add_child(log_bg)

	var log_scroll := ScrollContainer.new()
	log_bg.add_child(log_scroll)

	var log_list := VBoxContainer.new()
	log_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	log_scroll.add_child(log_list)

	var add_log := func(msg: String):
		var t := Time.get_time_string_from_system()
		var lbl := Label.new()
		lbl.text = "[" + t + "] " + msg
		lbl.add_theme_font_size_override("font_size", 11)
		lbl.modulate = Color(0.8, 0.8, 0.8)
		lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		log_list.add_child(lbl)
		log_scroll.scroll_vertical = 999999

	check_btn.pressed.connect(func():
		check_btn.disabled = true
		check_btn.text = "Checking..."
		for fn in status_info:
			var info: Dictionary = status_info[fn]
			(info["label"] as Label).text = "checking..."
			(info["label"] as Label).modulate = Color(1.0, 1.0, 1.0)
			var btn: Button = info["dl_btn"]
			btn.modulate.a = 0.0
			btn.disabled = true
			btn.mouse_filter = Control.MOUSE_FILTER_IGNORE
			btn.text = "Download"
		await check_updates_for_ui(status_info, add_log, check_btn)
		check_btn.disabled = false
		check_btn.text = "Check for Updates"
	)

	return margin

func check_updates_for_ui(status_info: Dictionary, add_log: Callable, check_btn: Button) -> void:
	var ids: Array[int] = []
	for fn in status_info:
		ids.append(status_info[fn]["mw_id"])
	if ids.is_empty():
		return

	var latest := await fetch_latest_modworkshop_versions(ids)

	if not is_instance_valid(check_btn):
		return

	for fn: String in status_info:
		var info: Dictionary = status_info[fn]
		var lbl: Label = info["label"]
		var dl_btn: Button = info["dl_btn"]
		var latest_v = latest.get(str(info["mw_id"]), null)
		if latest_v == null:
			lbl.text = "no data"
			lbl.modulate = Color(1.0, 1.0, 1.0)
			continue

		var cmp := compare_versions(info["version"], str(latest_v))
		if cmp >= 0:
			# Local is same version or newer than what's on the server.
			lbl.text = "up to date"
			lbl.modulate = Color(0.6, 0.6, 0.6)
		else:
			# Server has a newer version.
			lbl.text = "update: v" + str(latest_v)
			lbl.modulate = Color(0.90, 0.90, 0.90)
			dl_btn.modulate.a = 1.0
			dl_btn.disabled = false
			dl_btn.mouse_filter = Control.MOUSE_FILTER_STOP
			var full_path: String = info["full_path"]
			var mw_id: int = info["mw_id"]
			var mod_name: String = info["mod_name"]
			var new_ver: String = str(latest_v)
			# Disconnect previous connections so repeated checks don't stack callbacks.
			for c in dl_btn.pressed.get_connections():
				dl_btn.pressed.disconnect(c["callable"])
			dl_btn.pressed.connect(func():
				dl_btn.disabled = true
				dl_btn.text = "Downloading..."
				lbl.text = "downloading..."
				check_btn.disabled = true
				var ok := await download_and_replace_mod(full_path, mw_id)
				if not is_instance_valid(check_btn):
					return
				if not is_instance_valid(dl_btn):
					return
				check_btn.disabled = false
				if ok:
					lbl.text = "updated -- restart to apply"
					lbl.modulate = Color(0.80, 0.80, 0.80)
					dl_btn.modulate.a = 0.0
					dl_btn.disabled = true
					dl_btn.mouse_filter = Control.MOUSE_FILTER_IGNORE
					dl_btn.text = "Download"
					# Update cached version so next Check won't re-flag this mod.
					info["version"] = new_ver
					(info["ver_lbl"] as Label).text = "v" + new_ver
					add_log.call(mod_name + " -- updated to v" + new_ver + ". Restart game to apply.")
				else:
					lbl.text = "download failed"
					lbl.modulate = Color(1.0, 0.4, 0.4)
					dl_btn.disabled = false
					dl_btn.text = "Retry"
					add_log.call(mod_name + " -- download failed.")
			)
