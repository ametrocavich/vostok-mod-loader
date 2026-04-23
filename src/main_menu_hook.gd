## ----- main_menu_hook.gd -----
## Injects a "Mods" button into RTV's main menu (res://Scripts/Menu.gd) that
## re-opens the launcher UI post-boot. Any mutation to mod_config.cfg while
## the UI is open flips _dirty_since_boot; on close we restart into a clean
## Pass 1 so the new mod set takes effect.
##
## Implementation uses the same hook machinery mods use:
##   1. _seed_core_hooks pre-populates _hooked_methods so the rewriter wraps
##      Menu.gd's _ready even when no user mod asked for it. Called from each
##      finish path + Pass 1's pre-restart generation so every code path that
##      produces a hook pack includes our wrap.
##   2. _register_core_hooks subscribes our injector to menu-_ready-post via
##      the public hook() API. Fired from _emit_frameworks_ready.

const _MENU_SCRIPT_PATH := "res://Scripts/Menu.gd"
const _MENU_HOOK_NAME := "menu-_ready-post"
const _MODS_BUTTON_NAME := "MetroMods"

func _seed_core_hooks() -> void:
	if not _hooked_methods.has(_MENU_SCRIPT_PATH):
		_hooked_methods[_MENU_SCRIPT_PATH] = {}
	(_hooked_methods[_MENU_SCRIPT_PATH] as Dictionary)["_ready"] = true

func _register_core_hooks() -> void:
	hook(_MENU_HOOK_NAME, _on_menu_ready, 100)

func _on_menu_ready() -> void:
	# Resolve the menu root via current_scene. The dispatcher fires -post from
	# the vanilla _ready body, so at this point the Menu node is in the tree
	# and @onready vars are populated.
	var menu_root := get_tree().current_scene
	if menu_root == null or menu_root.get_script() == null:
		return
	if menu_root.get_script().resource_path != _MENU_SCRIPT_PATH:
		return
	_inject_mods_button(menu_root)

func _inject_mods_button(menu_root: Node) -> void:
	var buttons := menu_root.get_node_or_null("Main/Buttons")
	if buttons == null:
		_log_warning("[ModLoader] Main menu has no Main/Buttons container skipping Mods button injection")
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
	btn.pressed.connect(_on_mods_button_pressed)
	_log_info("[ModLoader] Injected Mods button into main menu")

func _on_mods_button_pressed() -> void:
	reopen_mod_ui()
