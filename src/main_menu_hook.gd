## A "Mods" button in RTV's main menu that reopens the launcher, through the
## same menu-_ready-post hook mods use.

const _MENU_SCRIPT_PATH := "res://Scripts/Menu.gd"
const _MODS_BUTTON_NAME := "MetroMods"

func _seed_core_hooks() -> void:
	if not _hooked_methods.has(_MENU_SCRIPT_PATH):
		_hooked_methods[_MENU_SCRIPT_PATH] = {"_ready": true}
		return
	# A wildcard already covers _ready; inserting a key would narrow it.
	var mask := _hooked_methods[_MENU_SCRIPT_PATH] as Dictionary
	if _mask_is_wildcard(mask):
		return
	mask["_ready"] = true

func _register_core_hooks() -> void:
	hook("menu-_ready-post", _on_menu_ready, 100)

func _on_menu_ready() -> void:
	# -post fires inside the vanilla _ready, so the Menu node is in the tree.
	var menu_root := get_tree().current_scene
	if menu_root == null or menu_root.get_script() == null:
		return
	if menu_root.get_script().resource_path != _MENU_SCRIPT_PATH:
		return
	_inject_mods_button(menu_root)

# Vanilla node paths: no "Main/Buttons" skips with a warning, no "Quit" appends the button last.
func _inject_mods_button(menu_root: Node) -> void:
	var buttons := menu_root.get_node_or_null("Main/Buttons")
	if buttons == null:
		_log_warning("[Menu] Main menu has no Main/Buttons container -- skipping Mods button injection")
		return
	if buttons.get_node_or_null(_MODS_BUTTON_NAME) != null:
		return
	var btn := Button.new()
	btn.name = _MODS_BUTTON_NAME
	btn.text = "Mods"
	btn.custom_minimum_size = Vector2(0, 40)
	btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var quit_btn := buttons.get_node_or_null("Quit")
	buttons.add_child(btn)
	if quit_btn != null:
		buttons.move_child(btn, quit_btn.get_index())
	btn.pressed.connect(reopen_mod_ui)
	_log_info("[Menu] Injected Mods button into main menu")
