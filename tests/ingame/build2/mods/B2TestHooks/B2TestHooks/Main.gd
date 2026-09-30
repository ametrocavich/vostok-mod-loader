## B2 Test: Hooks. A hook-only mod (no [registry]) that declares one method
## Build 2 removed (AISpawner.SpawnWanderer) on purpose: the loader must
## report it as lost ("will NEVER fire") and keep every other hook working.
## Prints "[B2TEST] ..." lines for tests/ingame/build2/evaluate.py.
extends Node

const TAG := "[B2TEST]"
# The game log is buffered and lost on a crash at exit; flushed copy.
const PROGRESS := "user://b2test_hooks_progress.txt"


func _line(kind: String, name: String, detail: String) -> void:
	print("%s %s %s: %s" % [TAG, kind, name, detail])
	var f := FileAccess.open(PROGRESS, FileAccess.READ_WRITE if FileAccess.file_exists(PROGRESS) else FileAccess.WRITE)
	if f == null:
		return
	f.seek_end()
	f.store_line("%s %s %s: %s" % [Time.get_time_string_from_system(), kind, name, detail])
	f.flush()
	f.close()


func _ready() -> void:
	var f := FileAccess.open(PROGRESS, FileAccess.WRITE)
	if f != null:
		f.store_line("run start")
		f.close()
	var lib = Engine.get_meta("RTVModLib", null)
	if lib == null:
		_line("FAIL", "H0 hooks mod lib", "RTVModLib meta missing")
		return
	var id: int = lib.hook("menu-_ready-post", _on_menu_ready)
	_line("PASS", "H0 hooks mod registered menu-_ready-post", "id %d" % id)
	# These fire only in a map; their lines are informational.
	lib.hook("aispawner-initialize-post", func():
		var sp = lib._caller
		_line("INFO", "map AISpawner.Initialize post hook", "zone=%s enemy=%s" % [str(sp.zone) if sp != null else "?", str(sp.enemy.resource_path) if sp != null and sp.enemy != null else "?"])
	)
	lib.hook("aispawner-spawnenemy-post", func(): _line("INFO", "map AISpawner.SpawnEnemy post hook", "fired"))
	lib.hook("ai-selectweapon-post", func():
		var ai = lib._caller
		var names := PackedStringArray()
		if ai != null and ai.weapons != null:
			for c in ai.weapons.get_children():
				names.append(c.name)
		_line("INFO", "map AI.SelectWeapon post hook", "variant=%s weapons=%s" % [str(ai.variant.name) if ai != null and ai.variant != null else "?", ", ".join(names)])
	)
	lib.hook("loader-loadscene-pre", func(scene): _line("INFO", "map Loader.LoadScene pre hook", str(scene)))


func _on_menu_ready() -> void:
	var menu := get_tree().current_scene
	var ok: bool = menu != null and menu.get_script() != null and str(menu.get_script().resource_path) == "res://Scripts/Menu.gd"
	_line("PASS" if ok else "FAIL", "H1 menu-_ready-post fired from a second mod", "scene=%s" % (str(menu.name) if menu != null else "null"))
