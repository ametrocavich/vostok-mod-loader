## B2 Test: Hooks. A hook-only mod (no [registry]) that declares one method
## Build 2 removed (AISpawner.SpawnWanderer) on purpose: the loader must
## report it as lost ("will NEVER fire") and keep every other hook working.
## Prints "[B2TEST] ..." lines for tests/ingame/build2/evaluate.py.
extends Node

const TAG := "[B2TEST]"


func _ready() -> void:
	var lib = Engine.get_meta("RTVModLib", null)
	if lib == null:
		print("%s FAIL H0 hooks mod lib: RTVModLib meta missing" % TAG)
		return
	var id: int = lib.hook("menu-_ready-post", _on_menu_ready)
	print("%s PASS H0 hooks mod registered menu-_ready-post: id %d" % [TAG, id])
	# These fire only in a map; their lines are informational.
	lib.hook("aispawner-initialize-post", func(): print("%s INFO AISpawner.Initialize post hook fired" % TAG))
	lib.hook("aispawner-spawnenemy-post", func(): print("%s INFO AISpawner.SpawnEnemy post hook fired" % TAG))
	lib.hook("ai-selectweapon-post", func():
		var ai = lib._caller
		var names := PackedStringArray()
		if ai != null and ai.weapons != null:
			for c in ai.weapons.get_children():
				names.append(c.name)
		print("%s INFO AI.SelectWeapon post hook: variant=%s weapons=%s" % [TAG, str(ai.variant.name) if ai != null and ai.variant != null else "?", ", ".join(names)])
	)
	lib.hook("loader-loadscene-pre", func(scene): print("%s INFO Loader.LoadScene pre hook: %s" % [TAG, str(scene)]))


func _on_menu_ready() -> void:
	var menu := get_tree().current_scene
	var ok: bool = menu != null and menu.get_script() != null and str(menu.get_script().resource_path) == "res://Scripts/Menu.gd"
	print("%s %s H1 menu-_ready-post fired from a second mod: scene=%s" % [TAG, "PASS" if ok else "FAIL", str(menu.name) if menu != null else "null"])
