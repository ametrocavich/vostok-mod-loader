## ----- ui_dialogs.gd -----
## Dialog plumbing shared by every tab, plus the profile dialogs.

# Borderless accept dialog with one dismiss button; backs the two helpers below.
func _show_accept_dialog(title: String, message: String, ok_text := "OK", min_w := 360) -> void:
	var d := AcceptDialog.new()
	d.title = title
	d.dialog_text = message
	d.ok_button_text = ok_text
	d.min_size = Vector2i(min_w, 0)
	_attach_ui_dialog(d)
	_wire_accept_dismiss(d)
	d.popup_centered()

# Free an AcceptDialog on both confirmed and close_requested.
func _wire_accept_dismiss(d: AcceptDialog) -> void:
	d.confirmed.connect(func(): d.queue_free())
	d.close_requested.connect(func(): d.queue_free())

# Error dialog so user-facing failures surface in the UI, not just the log.
func _show_error_dialog(title: String, message: String) -> void:
	_show_accept_dialog(title, message, "Close", 400)


# Neutral info dialog for benign confirmations ("all mods up to date").
func _show_info_toast(message: String) -> void:
	_show_accept_dialog("Mod Loader", message, "Close")


# Clamp a dialog's min_size to the live launcher window: dialogs are embedded
# sub-windows, so a larger min_size gets clipped with no way to resize. Sizes
# are in content-scaled coordinates, hence the divide.
func _dialog_fit_size(desired: Vector2i) -> Vector2i:
	if not is_instance_valid(_ui_window):
		return desired
	var scale: float = maxf(_ui_window.content_scale_factor, 0.001)
	var avail := Vector2i(Vector2(_ui_window.size) / scale) - Vector2i(24, 24)
	return Vector2i(mini(desired.x, maxi(avail.x, 200)), mini(desired.y, maxi(avail.y, 150)))

# Every launcher dialog flows through this: borderless dark card, title and
# dialog_text moved into a header, caller children reparented into one VBox.
func _attach_ui_dialog(d: Window) -> void:
	var parent: Node = _ui_window if _ui_window != null else get_tree().root
	if _ui_window != null and _ui_window.theme != null:
		d.theme = _ui_window.theme
	d.transparent = false
	d.transparent_bg = false
	d.always_on_top = true
	d.transient = true
	d.exclusive = true
	d.borderless = true
	d.add_theme_stylebox_override("panel", _make_dialog_panel_stylebox())

	# AcceptDialog's dialog_text label is absolutely positioned, so sibling
	# Labels would overlap it; clear title and dialog_text and re-emit them.
	var title_text := d.title
	var body_text := ""
	if d is AcceptDialog:
		body_text = (d as AcceptDialog).dialog_text
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


# Set all four border widths of a StyleBoxFlat to `w`.
func _sb_border(s: StyleBoxFlat, w := 1) -> void:
	s.border_width_top = w
	s.border_width_bottom = w
	s.border_width_left = w
	s.border_width_right = w

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

# ConfirmationDialog fires `canceled` on Cancel and `close_requested` on
# ESC / window-X; callers want both to behave the same.
func _connect_dialog_exits(d: ConfirmationDialog, on_confirm: Callable, on_dismiss: Callable) -> void:
	d.confirmed.connect(on_confirm)
	d.canceled.connect(on_dismiss)
	d.close_requested.connect(on_dismiss)

# Swap the bottom-bar hint label to `text` while hovered (the launcher's tooltip).
func _wire_hint(c: Control, text: String) -> void:
	if _ui_hint_label == null:
		return
	# mouse_entered/exited never fire on MOUSE_FILTER_IGNORE (the Label
	# default), so establish PASS here rather than at every caller.
	if c.mouse_filter == Control.MOUSE_FILTER_IGNORE:
		c.mouse_filter = Control.MOUSE_FILTER_PASS
	c.mouse_entered.connect(func():
		if is_instance_valid(_ui_hint_label):
			_ui_hint_label.text = text
	)
	c.mouse_exited.connect(func():
		if is_instance_valid(_ui_hint_label):
			_ui_hint_label.text = _ui_hint_default
	)

# Show an attached ConfirmationDialog and await the choice; true on confirm.
# The Array is the closure-shared state cell.
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

# Yes/no confirm when disabling a mod that registers game content; true =
# proceed. `count` > 1 switches to batch wording.
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
	style_dialog_danger_button(d.get_ok_button())
	return await _await_dialog_choice(d)

# Validate a candidate profile name (New and Rename). Returns the user-facing
# error, or "" when acceptable. `current` lets Rename accept its own name.
func _validate_profile_name(name: String, existing: Array, current := "") -> String:
	if name == "":
		return "Name cannot be empty or all invalid characters."
	if name.to_lower() == "vanilla" or name == VANILLA_PROFILE \
			or _is_modpack_managed_profile(name):
		return "That name is reserved."
	if name == current:
		return ""
	# Case-insensitive: MCM snapshot dirs are keyed by profile name on a
	# case-insensitive filesystem, so case-only twins would share a dir.
	var lowered := name.to_lower()
	for other_v in existing:
		# A case-only rename (Main -> MAIN) is not a duplicate of itself.
		if current != "" and str(other_v) == current:
			continue
		if str(other_v).to_lower() == lowered:
			return "Profile \"" + str(other_v) + "\" already exists."
	return ""

# New Profile dialog: name plus initial state. Initial state defaults to
# Empty; a fresh profile starts blank.
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

	# CheckBox + ButtonGroup = radio buttons; set button_group before button_pressed.
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
			# Mutate in-memory entries to the chosen initial state, then _create_profile
			# snapshots them. Priorities are left untouched.
			if state_all.button_pressed:
				for entry in _ui_mod_entries:
					entry["enabled"] = true
			elif state_empty.button_pressed:
				for entry in _ui_mod_entries:
					entry["enabled"] = false
			_create_profile(name, state_copy.button_pressed)
			_rebuild_mods_tab(tabs)

	name_edit.text_submitted.connect(func(_t): try_create.call())
	_connect_dialog_exits(d, try_create, func(): d.queue_free())
	d.popup_centered()
	name_edit.grab_focus()

# Rename dialog. Same validation as New; renaming to the same name is a no-op.
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

# Delete-profile confirmation; the trash button is disabled when deletion is impossible.
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
