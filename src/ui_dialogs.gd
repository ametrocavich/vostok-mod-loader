# Dialog plumbing shared by every tab, plus the profile dialogs.

func _show_accept_dialog(title: String, message: String, ok_text := "OK", min_w := 360) -> void:
	var d := AcceptDialog.new()
	d.title = title
	d.dialog_text = message
	d.ok_button_text = ok_text
	d.min_size = Vector2i(min_w, 0)
	_present_dialog(d)

# ESC emits canceled, which only hides an AcceptDialog.
func _wire_accept_dismiss(d: AcceptDialog) -> void:
	d.confirmed.connect(func(): d.queue_free())
	d.close_requested.connect(func(): d.queue_free())
	d.canceled.connect(func(): d.queue_free())

func _present_dialog(d: AcceptDialog) -> void:
	_attach_ui_dialog(d)
	_wire_accept_dismiss(d)
	d.popup_centered()

# Hide first: freeing a visible exclusive dialog took the launcher window down. Only
# for add_button buttons; the stock Cancel and OK hide before they emit.
func _close_dialog(d: Window) -> void:
	d.hide()
	d.queue_free()

const _DETAIL_DIALOG_SIZE := Vector2i(660, 540)

# Returns {d, outer, box}; `outer` holds the scroll so a caller can pin a line under it.
func _new_scroll_dialog(title: String, desired: Vector2i, separation: int = SP_M) -> Dictionary:
	var d := AcceptDialog.new()
	d.title = title
	d.ok_button_text = "Close"
	d.min_size = _dialog_fit_size(desired)
	var outer := VBoxContainer.new()
	outer.add_theme_constant_override("separation", SP_S)
	d.add_child(outer)
	var scroll := _make_scroll(outer)
	scroll.custom_minimum_size = Vector2(d.min_size - Vector2i(20, 60))
	return {"d": d, "outer": outer, "box": _make_scroll_column(scroll, separation, SP_S)}

func _show_error_dialog(title: String, message: String) -> void:
	_show_accept_dialog(title, message, "Close", 400)

func _show_info_toast(message: String) -> void:
	_show_accept_dialog("Mod Loader", message, "Close")

# Dialogs are embedded sub-windows, so a min_size larger than the launcher is
# clipped with no way to resize. Sizes are content-scaled, hence the divide.
func _dialog_fit_size(desired: Vector2i) -> Vector2i:
	if _ui_window == null:
		return desired
	var scale: float = maxf(_ui_window.content_scale_factor, 0.001)
	var avail := Vector2i(Vector2(_ui_window.size) / scale) - Vector2i(24, 24)
	return Vector2i(mini(desired.x, maxi(avail.x, 200)), mini(desired.y, maxi(avail.y, 150)))

# Every launcher dialog goes through here: a borderless dark card with the title and
# dialog_text moved into a header above the caller's children. wrap = false drops both.
func _attach_ui_dialog(d: AcceptDialog, wrap := true) -> void:
	# The harnesses keep the loader out of the tree, where get_tree() is null.
	var parent: Node = _ui_window if _ui_window != null else get_tree().root
	if _ui_window != null:
		d.theme = _ui_window.theme
	d.always_on_top = true
	d.transient = true
	d.exclusive = true
	d.borderless = true
	d.add_theme_stylebox_override("panel", _make_dialog_panel_stylebox())

	# The stock dialog_text label is absolutely positioned and would overlap
	# sibling Labels, so title and text are cleared and re-emitted.
	var title_text := d.title
	var body_text := d.dialog_text
	d.dialog_text = ""
	d.title = ""

	if wrap and (title_text != "" or body_text != ""):
		var existing := d.get_children()
		for c in existing:
			d.remove_child(c)
		var root := VBoxContainer.new()
		root.add_theme_constant_override("separation", SP_M)
		root.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		root.size_flags_vertical = Control.SIZE_EXPAND_FILL
		if title_text != "":
			var title_lbl := _make_label(title_text, COL_TEXT_HI, FS_HEAD)
			title_lbl.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
			# A mod page title can be long; it must not widen the dialog past
			# the launcher and push the buttons out of reach.
			title_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			title_lbl.clip_text = true
			title_lbl.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
			title_lbl.tooltip_text = title_text
			root.add_child(title_lbl)
		if body_text != "":
			var body_lbl := _make_label(body_text, null, FS_EMPH)
			body_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
			body_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			body_lbl.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
			body_lbl.custom_minimum_size.x = 400
			root.add_child(body_lbl)
		for c in existing:
			root.add_child(c)
		d.add_child(root)

	parent.add_child(d)

# Cancel emits canceled and ESC or the window X emits close_requested; both dismiss.
func _connect_dialog_exits(d: ConfirmationDialog, on_confirm: Callable, on_dismiss: Callable) -> void:
	d.confirmed.connect(on_confirm)
	d.canceled.connect(on_dismiss)
	d.close_requested.connect(on_dismiss)

func _show_danger_confirm(title: String, text: String, ok_text: String, on_confirm: Callable) -> void:
	var d := ConfirmationDialog.new()
	d.title = title
	d.dialog_text = text
	d.ok_button_text = ok_text
	_attach_ui_dialog(d)
	style_dialog_danger_button(d.get_ok_button())
	_connect_dialog_exits(d,
		func():
			d.queue_free()
			on_confirm.call(),
		func(): d.queue_free())
	d.popup_centered()

# The dropdown is a sub-Window: on top so the launcher cannot strand it, and
# themed by hand because theme lookup does not cross Window boundaries.
func _style_option_popup(opt: OptionButton) -> void:
	var popup := opt.get_popup()
	popup.always_on_top = true
	popup.transient = true
	if _ui_window != null:
		popup.theme = _ui_window.theme

func _wire_hint(c: Control, text: String) -> void:
	if _ui_hint_label == null:
		return
	# mouse_entered never fires on MOUSE_FILTER_IGNORE, the Label default.
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

func _await_dialog_choice(d: ConfirmationDialog) -> bool:
	var answer := []  # a lambda cannot assign a captured local
	_connect_dialog_exits(d, func(): answer.append(true), func(): answer.append(false))
	d.popup_centered()
	d.grab_focus()
	while answer.is_empty():
		await get_tree().process_frame
	d.queue_free()
	return answer.has(true)

func _confirm_disable_content_mod(mod_name: String, count: int = 1) -> bool:
	var d := ConfirmationDialog.new()
	d.title = "Disable content mod?" if count <= 1 else "Disable content mods?"
	d.ok_button_text = "Disable anyway"
	d.cancel_button_text = "Keep enabled"
	d.min_size = Vector2(520, 120)
	if count > 1:
		d.dialog_text = "%d of these mods (including \"%s\") add game content (items, recipes, and similar). Saves that use their content may not load while the mods are disabled. Your saves are not deleted -- re-enable the mods to get them back.\n\nDisable anyway?" % [count, mod_name]
	else:
		d.dialog_text = "\"%s\" adds game content (items, recipes, and similar). A save that uses this content may not load while the mod is disabled. Your save is not deleted -- re-enable the mod to get it back.\n\nDisable anyway?" % mod_name
	_attach_ui_dialog(d)
	style_dialog_danger_button(d.get_ok_button())
	return await _await_dialog_choice(d)

# `current` lets Rename keep its own name, including a case-only change.
func _validate_profile_name(name: String, existing: Array[String], current := "") -> String:
	if name == "":
		return "Name cannot be empty or all invalid characters."
	if name.to_lower() == "vanilla" or name == VANILLA_PROFILE \
			or _is_modpack_managed_profile(name):
		return "That name is reserved."
	if name == current:
		return ""
	# MCM snapshot dirs are keyed by profile name on a case-insensitive
	# filesystem, so case-only twins would share a dir.
	for other in existing:
		if other != current and other.to_lower() == name.to_lower():
			return "Profile \"" + other + "\" already exists."
	return ""

func _profile_name_dialog(title: String, ok_text: String, prompt_text: String, initial: String) -> Dictionary:
	var d := ConfirmationDialog.new()
	d.title = title
	d.ok_button_text = ok_text
	d.dialog_hide_on_ok = false  # stays open until the name validates

	var form := VBoxContainer.new()
	form.custom_minimum_size = Vector2(320, 0)
	form.add_theme_constant_override("separation", SP_M)
	d.add_child(form)
	form.add_child(_make_label(prompt_text))

	var name_edit := LineEdit.new()
	name_edit.custom_minimum_size.x = 280
	name_edit.custom_minimum_size.y = CTRL_H
	name_edit.text = initial
	form.add_child(name_edit)

	var err_lbl := _make_label("", COL_ERR, FS_BODY)
	form.add_child(err_lbl)
	return {"d": d, "form": form, "name_edit": name_edit, "err_lbl": err_lbl}

func _profile_name_dialog_open(parts: Dictionary, try_submit: Callable) -> void:
	var d: ConfirmationDialog = parts["d"]
	var name_edit: LineEdit = parts["name_edit"]
	_attach_ui_dialog(d)
	name_edit.text_submitted.connect(func(_t): try_submit.call())
	_connect_dialog_exits(d, try_submit, func(): d.queue_free())
	d.popup_centered()
	name_edit.select_all()
	name_edit.grab_focus()

func _show_new_profile_dialog(tabs: TabContainer) -> void:
	var parts := _profile_name_dialog("New profile", "Create profile",
			"Profile name (letters, digits, spaces, _-):", "")
	var d: ConfirmationDialog = parts["d"]
	var form: VBoxContainer = parts["form"]
	var name_edit: LineEdit = parts["name_edit"]
	var err_lbl: Label = parts["err_lbl"]

	form.add_child(_make_label("Initial state:"))
	# CheckBox + ButtonGroup = radio buttons; button_group goes before button_pressed.
	var state_group := ButtonGroup.new()
	var states: Array[CheckBox] = []
	for state_text: String in ["Empty (no mods enabled)", "All enabled", "Copy current selection"]:
		var state_box := CheckBox.new()
		state_box.text = state_text
		state_box.button_group = state_group
		form.add_child(state_box)
		states.append(state_box)
	states[0].button_pressed = true
	form.move_child(err_lbl, -1)

	var existing := _list_profiles()
	var try_create := func():
		var name := _sanitize_profile_name(name_edit.text)
		var err := _validate_profile_name(name, existing)
		if err != "":
			err_lbl.text = err
			return
		d.queue_free()
		# _create_profile snapshots the in-memory entries; priorities stay.
		if states[1].button_pressed:
			for entry in _ui_mod_entries:
				entry["enabled"] = true
		elif states[0].button_pressed:
			for entry in _ui_mod_entries:
				entry["enabled"] = false
		_create_profile(name)
		_rebuild_mods_tab(tabs)
	_profile_name_dialog_open(parts, try_create)

func _show_rename_profile_dialog(tabs: TabContainer) -> void:
	var current := _active_profile
	var parts := _profile_name_dialog("Rename profile", "Rename profile",
			"New name for \"" + current + "\":", current)
	var d: ConfirmationDialog = parts["d"]
	var name_edit: LineEdit = parts["name_edit"]
	var err_lbl: Label = parts["err_lbl"]

	var existing := _list_profiles()
	var try_rename := func():
		var name := _sanitize_profile_name(name_edit.text)
		var err := _validate_profile_name(name, existing, current)
		if err != "":
			err_lbl.text = err
			return
		d.queue_free()
		if name != current:
			_rename_profile(name)
			_rebuild_mods_tab(tabs)
	_profile_name_dialog_open(parts, try_rename)
