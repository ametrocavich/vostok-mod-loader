func _show_accept_dialog(title: String, message: String, ok_text := "OK", min_w := 360) -> void:
	var d := AcceptDialog.new()
	d.title = title
	d.dialog_text = message
	d.ok_button_text = ok_text
	d.min_size = Vector2i(min_w, 0)
	_attach_ui_dialog(d)
	_wire_accept_dismiss(d)
	d.popup_centered()

# Free an AcceptDialog on both OK (confirmed) and the window close button
# (close_requested). The AcceptDialog analog of _connect_dialog_exits; the
# connect order matches the hand-rolled dismiss sites it replaces.
func _wire_accept_dismiss(d: AcceptDialog) -> void:
	d.confirmed.connect(func(): d.queue_free())
	d.close_requested.connect(func(): d.queue_free())

# Show a simple error dialog. Replaces ad-hoc push_warning calls in user-
# facing flows so failures actually surface in the UI instead of just the
# log. Used by modpack apply/unload, profile import, etc.
func _show_error_dialog(title: String, message: String) -> void:
	_show_accept_dialog(title, message, "Close", 400)


# Neutral one-line info dialog. Same shape as _show_error_dialog but framed
# without the "error" connotation -- used for benign confirmations like
# "all mods up to date" after a check.
func _show_info_toast(message: String) -> void:
	_show_accept_dialog("Mod Loader", message, "Close")


# Clamp a dialog's desired min_size to fit inside the live launcher window.
# Dialogs are embedded sub-windows (gui_embed_subwindows) so they can never
# be larger than the launcher: a fixed min_size above the launcher's own
# minimum size (640x420 logical) gets clipped by the embedder near that
# minimum, cutting off content and the bottom button bar with no way to
# resize the borderless dialog. Sizes here are in the launcher's LOGICAL
# (content-scaled) coordinates -- the same space embedded windows are laid
# out in -- so divide the physical window size by content_scale_factor.
func _dialog_fit_size(desired: Vector2i) -> Vector2i:
	if _ui_window == null or not is_instance_valid(_ui_window):
		return desired
	var scale: float = maxf(_ui_window.content_scale_factor, 0.001)
	var avail := Vector2i(Vector2(_ui_window.size) / scale) - Vector2i(24, 24)
	return Vector2i(mini(desired.x, maxi(avail.x, 200)), mini(desired.y, maxi(avail.y, 150)))

# All launcher dialogs flow through this. Renders as a borderless dark
# card: theme applied, OS chrome dropped, title + dialog_text consumed
# into a labeled header, and every caller-added child reparented into a
# single root VBox so layout flows unambiguously regardless of size_flags
# quirks in AcceptDialog's content area.
func _attach_ui_dialog(d: Window) -> void:
	var parent: Node = _ui_window if _ui_window != null else get_tree().root
	# Theme before add_child so the first draw is styled (set-after-add
	# sometimes lands the first frame with default chrome).
	if _ui_window != null and _ui_window.theme != null:
		d.theme = _ui_window.theme
	d.transparent = false
	d.transparent_bg = false
	d.always_on_top = true
	d.transient = true
	d.exclusive = true
	d.borderless = true
	d.add_theme_stylebox_override("panel", _make_dialog_panel_stylebox())

	# Consume title + dialog_text into a single header VBox. AcceptDialog's
	# internal dialog_text label is absolutely positioned -- leaving it
	# active and adding sibling Labels at "child index 0" makes them
	# render at the same y. So we clear both and re-emit them in a
	# regular VBox where flow layout is honored.
	var title_text := str(d.title)
	var body_text := ""
	if d is AcceptDialog:
		body_text = str((d as AcceptDialog).dialog_text)
		(d as AcceptDialog).dialog_text = ""
	d.title = ""

	if title_text != "" or body_text != "":
		var existing := d.get_children()
		for c in existing:
			d.remove_child(c)
		var root := VBoxContainer.new()
		root.add_theme_constant_override("separation", SP_M)
		root.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		root.size_flags_vertical = Control.SIZE_EXPAND_FILL
		if title_text != "":
			var title_lbl := Label.new()
			title_lbl.text = title_text
			title_lbl.add_theme_font_size_override("font_size", FS_HEAD)
			title_lbl.add_theme_color_override("font_color", COL_TEXT_HI)
			title_lbl.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
			root.add_child(title_lbl)
		if body_text != "":
			var body_lbl := Label.new()
			body_lbl.text = body_text
			body_lbl.add_theme_font_size_override("font_size", FS_EMPH)
			body_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
			body_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			body_lbl.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
			body_lbl.custom_minimum_size.x = 400
			root.add_child(body_lbl)
		for c in existing:
			root.add_child(c)
		d.add_child(root)

	parent.add_child(d)


# Set all four border widths of a freshly-built StyleBoxFlat to `w`. Covers the
# uniform 1px-border idiom repeated across the theme styleboxes; non-uniform
# borders (e.g. the TabContainer's bottom=0) stay inline.
func _sb_border(s: StyleBoxFlat, w := 1) -> void:
	s.border_width_top = w
	s.border_width_bottom = w
	s.border_width_left = w
	s.border_width_right = w

# Dialog panel background. Centralized so _attach_ui_dialog and any future
# place that needs a matching look (e.g. inline cards) use the same style.
func _make_dialog_panel_stylebox() -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = COL_SURFACE
	s.border_color = COL_BORDER
	_sb_border(s)
	s.content_margin_left = SP_XL
	s.content_margin_right = SP_XL
	s.content_margin_top = SP_L
	s.content_margin_bottom = SP_L
	return s

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
	# mouse_entered/exited never fire on a MOUSE_FILTER_IGNORE control (Labels
	# default to IGNORE), so guarantee our own precondition rather than relying
	# on every caller to have set PASS.
	if c.mouse_filter == Control.MOUSE_FILTER_IGNORE:
		c.mouse_filter = Control.MOUSE_FILTER_PASS
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
	body.add_theme_constant_override("separation", SP_L)
	scroll.add_child(body)

	var intro := Label.new()
	intro.text = "The scanner found patterns in this mod's code that are commonly used by malware " \
			+ "(obfuscated string decoding combined with process spawning, anti-debug calls, etc.). " \
			+ "If you don't trust this mod, do not enable it."
	intro.add_theme_color_override("font_color", COL_ERR)
	intro.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	intro.add_theme_font_size_override("font_size", FS_BODY)
	body.add_child(intro)

	body.add_child(HSeparator.new())

	for f: Dictionary in findings:
		var card := VBoxContainer.new()
		card.add_theme_constant_override("separation", SP_S)
		body.add_child(card)

		var rule_lbl := Label.new()
		rule_lbl.text = str(f.get("rule", "?"))
		rule_lbl.add_theme_color_override("font_color", COL_ERR)
		rule_lbl.add_theme_font_size_override("font_size", FS_HEAD)
		card.add_child(rule_lbl)

		var desc_lbl := Label.new()
		desc_lbl.text = str(f.get("description", ""))
		desc_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		desc_lbl.add_theme_font_size_override("font_size", FS_BODY)
		card.add_child(desc_lbl)

		var loc := str(f.get("file", "?"))
		if int(f.get("line", 0)) > 0:
			loc += ":" + str(f.get("line"))
		var loc_lbl := Label.new()
		loc_lbl.text = loc
		loc_lbl.add_theme_color_override("font_color", COL_TEXT_DIM)
		loc_lbl.add_theme_font_size_override("font_size", FS_META)
		card.add_child(loc_lbl)

		var preview := str(f.get("preview", ""))
		if not preview.is_empty():
			var pre_lbl := Label.new()
			pre_lbl.text = "  " + preview
			pre_lbl.add_theme_color_override("font_color", COL_OK)
			pre_lbl.add_theme_font_size_override("font_size", FS_BODY)
			pre_lbl.autowrap_mode = TextServer.AUTOWRAP_OFF
			pre_lbl.clip_text = true
			pre_lbl.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
			pre_lbl.tooltip_text = preview
			pre_lbl.mouse_filter = Control.MOUSE_FILTER_PASS
			card.add_child(pre_lbl)

		body.add_child(HSeparator.new())

	_attach_ui_dialog(d)
	_wire_accept_dismiss(d)
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
	# risky option. Dialog OK buttons stay on modulate -- a theme
	# font-color override didn't take effect here when tried (see
	# style_dialog_danger_button for the shared rationale).
	style_dialog_danger_button(d.get_ok_button())

	return await _await_dialog_choice(d)

# Show an already-attached ConfirmationDialog and await the user's choice.
# Single-result polling: lambdas mark done + capture the choice; an Array is
# used because GDScript closures hold object references. Frees the dialog
# and returns true on confirm, false on cancel/close.
func _await_dialog_choice(d: ConfirmationDialog) -> bool:
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

# Yes/no confirm shown when the user disables a mod that registers game content.
# Returns true to proceed with the disable, false to keep it enabled. Modeled on
# _confirm_red_launch's flow; the shared await-poll lives in _await_dialog_choice.
# `count` > 1 switches to batch wording for bulk actions (the None button);
# `mod_name` then names one affected mod as an example.
func _confirm_disable_content_mod(mod_name: String, count: int = 1) -> bool:
	var d := ConfirmationDialog.new()
	d.title = "Disable content mod?" if count <= 1 else "Disable content mods?"
	d.ok_button_text = "Disable anyway"
	d.cancel_button_text = "Keep enabled"
	d.dialog_autowrap = true
	d.min_size = Vector2(520, 120)
	if count > 1:
		d.dialog_text = "%d of these mods (including \"%s\") add game content (items, recipes, and similar). Saves that use their content may not load while the mods are disabled. Your saves are not deleted -- re-enable the mods to get them back.\n\nDisable anyway?" % [count, mod_name]
	else:
		d.dialog_text = "\"%s\" adds game content (items, recipes, and similar). A save that uses this content may not load while the mod is disabled. Your save is not deleted -- re-enable the mod to get it back.\n\nDisable anyway?" % mod_name
	_attach_ui_dialog(d)
	d.exclusive = true
	d.always_on_top = true
	# Red "Disable anyway" button: the spec assigns this confirm the DANGER
	# voice (same as Delete/Unload). Uses the modulate path like the other
	# dialog OK buttons (see style_dialog_danger_button's rationale).
	style_dialog_danger_button(d.get_ok_button())
	return await _await_dialog_choice(d)

# Validate a candidate profile name against the rules shared by the New and
# Rename dialogs. Returns the user-facing error string, or "" when the name is
# acceptable. `current` lets Rename treat renaming to its own name as valid here
# (the caller turns that into a silent no-op rather than a commit).
func _validate_profile_name(name: String, existing: Array, current := "") -> String:
	if name == "":
		return "Name cannot be empty or all invalid characters."
	if name.to_lower() == "vanilla" or name == VANILLA_PROFILE \
			or _is_modpack_managed_profile(name):
		return "That name is reserved."
	if name == current:
		return ""
	# Case-insensitive, matching the vanilla check above: MCM snapshot dirs
	# are keyed by profile name on a case-insensitive filesystem (Windows),
	# so two profiles differing only by case would share one snapshot dir
	# and deleting one would wipe the other's MCM state.
	var lowered := name.to_lower()
	for other_v in existing:
		# Skip the profile being renamed: a case-only rename (Main -> MAIN)
		# is safe -- it keeps ONE profile and one snapshot dir, and
		# DirAccess.rename handles a case-only rename on NTFS -- so it must
		# not be rejected as a duplicate of itself. New Profile passes
		# current == "", so collision blocking there is unchanged.
		if current != "" and str(other_v) == current:
			continue
		if str(other_v).to_lower() == lowered:
			return "Profile \"" + str(other_v) + "\" already exists."
	return ""

# New Profile dialog: prompt for a name + initial state, validate, write the
# chosen state into the new profile, switch to it. Cancel leaves everything
# unchanged. Initial state radio defaults to Empty -- "fresh profile = nothing
# on" matches the mental model wyldbylli flagged on MWS (creating a profile
# previously cloned the current selection silently, which surprised users
# expecting a blank slate).
func _show_new_profile_dialog(tabs: TabContainer) -> void:
	var d := ConfirmationDialog.new()
	d.title = "New profile"
	d.ok_button_text = "Create profile"
	d.dialog_hide_on_ok = false  # keep open until we validate the name

	var form := VBoxContainer.new()
	form.custom_minimum_size = Vector2(320, 0)
	form.add_theme_constant_override("separation", SP_M)
	d.add_child(form)

	var prompt := Label.new()
	prompt.text = "Profile name (letters, digits, spaces, _-):"
	form.add_child(prompt)

	var name_edit := LineEdit.new()
	name_edit.custom_minimum_size.x = 280
	name_edit.custom_minimum_size.y = CTRL_H
	form.add_child(name_edit)

	var state_lbl := Label.new()
	state_lbl.text = "Initial state:"
	form.add_child(state_lbl)

	# CheckBox + ButtonGroup is the Godot 4 idiom for radio buttons. Set
	# button_group BEFORE button_pressed so the group registers the default.
	var state_group := ButtonGroup.new()

	var state_empty := CheckBox.new()
	state_empty.text = "Empty (no mods enabled)"
	state_empty.button_group = state_group
	state_empty.button_pressed = true
	form.add_child(state_empty)

	var state_all := CheckBox.new()
	state_all.text = "All enabled"
	state_all.button_group = state_group
	form.add_child(state_all)

	var state_copy := CheckBox.new()
	state_copy.text = "Copy current selection"
	state_copy.button_group = state_group
	form.add_child(state_copy)

	var err_lbl := Label.new()
	err_lbl.add_theme_color_override("font_color", COL_ERR)
	err_lbl.add_theme_font_size_override("font_size", FS_BODY)
	form.add_child(err_lbl)

	_attach_ui_dialog(d)

	var existing := _list_profiles()
	var try_create := func():
		var name := _sanitize_profile_name(name_edit.text)
		var err := _validate_profile_name(name, existing)
		if err != "":
			err_lbl.text = err
		else:
			d.queue_free()
			# Mutate in-memory entries to match the chosen initial state, then
			# _create_profile snapshots them into profile.<name>.* sections.
			# Priorities are intentionally left untouched -- they're a load-
			# order preference that survives an enable-state reset.
			if state_all.button_pressed:
				for entry in _ui_mod_entries:
					entry["enabled"] = true
			elif state_empty.button_pressed:
				for entry in _ui_mod_entries:
					entry["enabled"] = false
			# state_copy: leave _ui_mod_entries as-is so the new profile
			# inherits whatever was visible when the user clicked +.
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
	d.title = "Rename profile"
	d.ok_button_text = "Rename profile"
	d.dialog_hide_on_ok = false

	var form := VBoxContainer.new()
	form.custom_minimum_size = Vector2(320, 0)
	form.add_theme_constant_override("separation", SP_M)
	d.add_child(form)

	var prompt := Label.new()
	prompt.text = "New name for \"" + current + "\":"
	form.add_child(prompt)

	var name_edit := LineEdit.new()
	name_edit.custom_minimum_size.x = 280
	name_edit.custom_minimum_size.y = CTRL_H
	name_edit.text = current
	form.add_child(name_edit)

	var err_lbl := Label.new()
	err_lbl.add_theme_color_override("font_color", COL_ERR)
	err_lbl.add_theme_font_size_override("font_size", FS_BODY)
	form.add_child(err_lbl)

	_attach_ui_dialog(d)

	var existing := _list_profiles()
	var try_rename := func():
		var name := _sanitize_profile_name(name_edit.text)
		var err := _validate_profile_name(name, existing, current)
		if err != "":
			err_lbl.text = err
		elif name == current:
			d.queue_free()  # no-op
		else:
			d.queue_free()
			_rename_profile(name)
			_rebuild_mods_tab(tabs)

	name_edit.text_submitted.connect(func(_t): try_rename.call())
	_connect_dialog_exits(d, try_rename, func(): d.queue_free())
	d.popup_centered()
	name_edit.select_all()
	name_edit.grab_focus()

# Modpacks tab. Lists modpack zips discovered in <game>/mods/, each with an
# Apply / Unload button. A modpack is a curated profile + MCM bundle in zip
# form (profile.json at root, MCM/ tree). Drop the file in /mods/ and it
# shows up here. Apply runs the modpack's profile + MCM and backs up the
# user's previous state; Unload restores the backup. Edits while a modpack
# is active save into the modpack's profile slot and persist across applies.
# The standard 8/8/6/6 outer margin shared by ALL top-level tab builders
# (Mods, Modpacks, Browse, Updates).
func _show_delete_confirm(tabs: TabContainer) -> void:
	var target := _active_profile
	var d := ConfirmationDialog.new()
	d.title = "Delete profile"
	d.dialog_text = "Delete profile \"" + target + "\"?\n\nThe mod selection stored in this profile will be discarded. Your other profiles are not affected."
	d.ok_button_text = "Delete profile"
	_attach_ui_dialog(d)
	style_dialog_danger_button(d.get_ok_button())
	_connect_dialog_exits(d,
		func():
			d.queue_free()
			_delete_active_profile()
			_rebuild_mods_tab(tabs),
		func(): d.queue_free())
	d.popup_centered()


# Remove a mod file from disk and strip its profile entries from every
# profile in mod_config.cfg. profile_key (not file_name) drives the cleanup
# so a renamed archive's profile state still gets cleaned up correctly.
# Returns true on a successful file delete, false otherwise -- caller decides
# whether to surface the failure or carry on.
func _delete_mod_file_and_cleanup(entry: Dictionary) -> bool:
	var path: String = str(entry["full_path"])
	if FileAccess.file_exists(path):
		if DirAccess.remove_absolute(path) != OK:
			return false
	var profile_key: String = str(entry["profile_key"])
	var cfg := ConfigFile.new()
	if cfg.load(UI_CONFIG_PATH) == OK:
		for section in cfg.get_sections():
			if not section.begins_with("profile."):
				continue
			if not (section.ends_with(".enabled") or section.ends_with(".priority") \
					or section.ends_with(".dep_ignore")):
				continue
			if cfg.has_section_key(section, profile_key):
				cfg.erase_section_key(section, profile_key)
		_persist_ui_cfg(cfg)
	return true


# Per-row Remove confirmation. Shows mod name + filename + size so the user
# can sanity-check before committing. On Delete: deletes the file, strips
# profile state across all profiles, re-runs discovery, and rebuilds the
# Mods tab in place so the row vanishes immediately.
func _show_remove_mod_confirm(entry: Dictionary, tabs: TabContainer) -> void:
	var d := ConfirmationDialog.new()
	d.title = "Remove mod"
	var size_line := ""
	var path: String = str(entry.get("full_path", ""))
	if FileAccess.file_exists(path):
		var f := FileAccess.open(path, FileAccess.READ)
		if f != null:
			size_line = "\nSize: " + _format_size(f.get_length())
			f.close()
	d.dialog_text = "Permanently delete \"%s\"?\n\nFile: %s%s\n\nThis will:\n  - Delete the file from disk\n  - Remove the mod from EVERY profile, not just \"%s\"\n\nThis cannot be undone." % [
		str(entry.get("mod_name", "?")),
		str(entry.get("file_name", "?")),
		size_line,
		_active_profile,
	]
	d.ok_button_text = "Delete mod"
	style_dialog_danger_button(d.get_ok_button())
	_attach_ui_dialog(d)
	_connect_dialog_exits(d,
		func():
			d.queue_free()
			if _delete_mod_file_and_cleanup(entry):
				_reload_entries_for_active_profile()
				_rebuild_mods_tab(tabs),
		func(): d.queue_free())
	d.popup_centered()


# UI

