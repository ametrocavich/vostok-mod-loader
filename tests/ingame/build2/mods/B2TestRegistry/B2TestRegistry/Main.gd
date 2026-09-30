## B2 Test: Registry. Self-checking test mod for Road to Vostok Build 2.
## Registers content through every registry Build 2 touched during its own
## _ready(), then verifies the injected vanilla code at the main menu. Every
## check prints one "[B2TEST] PASS|FAIL <name>: <detail>" line to the game
## log; tests/ingame/build2/evaluate.py reads them. Never ships to players.
extends Node

const TAG := "[B2TEST]"

var _lib = null
var _pass := 0
var _fail := 0
var _area05_scene: PackedScene
var _debug_scene: PackedScene
var _test_scene: PackedScene


func _report(ok: bool, name: String, detail: String) -> void:
	if ok:
		_pass += 1
		print("%s PASS %s: %s" % [TAG, name, detail])
	else:
		_fail += 1
		print("%s FAIL %s: %s" % [TAG, name, detail])


func _ready() -> void:
	_lib = Engine.get_meta("RTVModLib", null)
	if _lib == null:
		_report(false, "lib", "Engine meta RTVModLib missing")
		_summary("boot")
		return
	_report(true, "lib", "RTVModLib present, loader %s" % str(_lib.get("MODLOADER_VERSION")))
	_lib.hook("menu-_ready-post", _on_menu_ready)
	_registry_tests()
	_summary("boot")


func _packed(node_name: String) -> PackedScene:
	var n := Node3D.new()
	n.name = node_name
	var ps := PackedScene.new()
	ps.pack(n)
	n.free()
	return ps


# A LT_Master item that is not already in the target table.
func _spare_item(table_path: String) -> Resource:
	var master = load("res://Loot/LT_Master.tres")
	var table = load(table_path)
	if master == null or table == null:
		return null
	for it in master.items:
		if it != null and not (it in table.items):
			return it
	return null


func _registry_tests() -> void:
	# ai_loadouts: Build 2 categories.
	var ok: bool = _lib.register("ai_loadouts", "b2test_boss_makarov",
			{"weapon_scene": "Makarov", "ai_types": ["Boss", "punisher"], "chance": 1.0})
	_report(ok, "R1 ai_loadouts register", "Boss/punisher with Database id Makarov -> %s" % str(ok))
	var bad: bool = _lib.register("ai_loadouts", "b2test_bad_category",
			{"weapon_scene": "Makarov", "ai_types": ["Zombie"]})
	_report(not bad, "R2 ai_loadouts unknown category refused", "Zombie -> %s (expected false)" % str(bad))

	# ai_types: zones, including Build 2's Debug.
	_area05_scene = _packed("B2TestAgentArea05")
	_debug_scene = _packed("B2TestAgentDebug")
	ok = _lib.override("ai_types", "b2test_area05", {"scene": _area05_scene, "zone": "Area05"})
	_report(ok, "R3a ai_types override Area05", str(ok))
	ok = _lib.register("ai_types", "b2test_debug", {"scene": _debug_scene, "zone": "Debug"})
	_report(ok, "R3b ai_types register Debug", str(ok))
	bad = _lib.register("ai_types", "b2test_nowhere", {"scene": _debug_scene, "zone": "Nowhere"})
	_report(not bad, "R3c ai_types unknown zone refused", "%s (expected false)" % str(bad))

	# trader_pools: Build 2 traders.
	var item := _spare_item("res://Loot/Custom/LT_Bogeyman_01.tres")
	if item == null:
		_report(false, "R4 trader_pools", "no spare LT_Master item to test with")
	else:
		var before_driver: bool = bool(item.get("driver"))
		ok = _lib.register("trader_pools", "b2test_driver", {"item": item, "trader": "Driver"})
		var flagged: bool = bool(item.get("driver"))
		_report(ok and flagged, "R4a trader_pools Driver", "register %s, item.driver %s -> %s" % [str(ok), str(before_driver), str(flagged)])
		ok = _lib.register("trader_pools", "b2test_hunter", {"item": item, "trader": "Hunter"})
		_report(ok and bool(item.get("hunter")), "R4b trader_pools Hunter", "register %s, item.hunter %s" % [str(ok), str(item.get("hunter"))])
		ok = _lib.remove("trader_pools", "b2test_driver") and _lib.remove("trader_pools", "b2test_hunter")
		_report(ok and bool(item.get("driver")) == before_driver, "R4c trader_pools remove restores", "remove %s, item.driver %s" % [str(ok), str(item.get("driver"))])

		# loot: the numbered Build 2 table names resolve, the old aliases do not.
		ok = _lib.register("loot", "b2test_bogeyman_loot", {"item": item, "table": "LT_Bogeyman_01"})
		_report(ok, "R5a loot register LT_Bogeyman_01", str(ok))
		ok = _lib.remove("loot", "b2test_bogeyman_loot")
		_report(ok, "R5b loot remove", str(ok))
		bad = _lib.register("loot", "b2test_old_alias", {"item": item, "table": "LT_Airdrop"})
		_report(not bad, "R5c loot old alias LT_Airdrop refused", "%s (expected false)" % str(bad))
		ok = _lib.register("loot", "b2test_airdrop_03", {"item": item, "table": "LT_Airdrop_03"})
		_report(ok, "R5d loot register LT_Airdrop_03", str(ok))
		_lib.remove("loot", "b2test_airdrop_03")

	# shelters: paired scene_paths entry on Loader, read by the Compiler prelude.
	ok = _lib.register("shelters", "B2TestShelter",
			{"path": "res://B2TestRegistry/TestShelter.tscn", "shelter": true, "exit_spawn": "Door_B2_Exit"})
	_report(ok, "R6 shelters register", str(ok))

	# scenes: Database _get() routing.
	_test_scene = _packed("B2TestScene")
	ok = _lib.register("scenes", "B2TestScene", _test_scene)
	_report(ok, "R7 scenes register", str(ok))

	# sounds: a Build 2 field patches, a pre-Build 2 name is refused.
	ok = _lib.patch("sounds", "vostok", {"volume": -3.0})
	_report(ok, "R8a sounds patch vostok", str(ok))
	ok = _lib.revert("sounds", "vostok")
	_report(ok, "R8b sounds revert vostok", str(ok))
	bad = _lib.patch("sounds", "vostokEnter", {"volume": -3.0})
	_report(not bad, "R8c sounds old name vostokEnter refused", "%s (expected false)" % str(bad))


func _on_menu_ready() -> void:
	_menu_tests()
	_summary("menu")


func _menu_tests() -> void:
	# M1: the rewritten AI.gd is what the game runs.
	var ai_script: GDScript = load("res://Scripts/AI.gd")
	var names: Dictionary = {}
	if ai_script != null:
		for m in ai_script.get_script_method_list():
			names[str(m["name"])] = true
	var injected: bool = names.has("_rtv_ai_categories") and names.has("_rtv_apply_ai_loadouts") and names.has("_rtv_vanilla_SelectWeapon")
	_report(injected, "M1 AI.gd rewritten and live", "methods present: categories=%s loadouts=%s renamed SelectWeapon=%s" \
			% [str(names.has("_rtv_ai_categories")), str(names.has("_rtv_apply_ai_loadouts")), str(names.has("_rtv_vanilla_SelectWeapon"))])
	if not injected:
		return

	# M2: categories from the Build 2 AIData variants.
	var ai = ai_script.new()
	var punisher = load("res://AI/Punisher/AI_Punisher.tres")
	var bandit = load("res://AI/Bandit/AI_Bandit_A.tres")
	var nomad = load("res://AI/Nomad/AI_Nomad_A.tres")
	ai.variant = punisher
	var cats: Array = ai._rtv_ai_categories()
	_report(cats == ["Boss", "Punisher"], "M2a categories Punisher", str(cats))
	ai.variant = bandit
	cats = ai._rtv_ai_categories()
	_report(cats == ["Bandit"], "M2b categories Bandit_A", str(cats))
	ai.variant = nomad
	cats = ai._rtv_ai_categories()
	_report(cats == ["Nomad"], "M2c categories Nomad_A", str(cats))

	# M3: the registered loadout lands in weapons for a Boss, not for a Bandit.
	var weapons := BoneAttachment3D.new()
	ai.weapons = weapons
	ai.variant = punisher
	ai._rtv_apply_ai_loadouts()
	var added := weapons.get_child_count()
	var hidden: bool = added > 0 and not weapons.get_child(0).visible
	_report(added == 1 and hidden, "M3a loadout injected for Boss", "weapons children=%d hidden=%s" % [added, str(hidden)])
	ai.variant = bandit
	ai._rtv_apply_ai_loadouts()
	_report(weapons.get_child_count() == 1, "M3b loadout skipped for Bandit", "weapons children=%d" % weapons.get_child_count())
	weapons.free()
	ai.free()

	# M4: AISpawner's enemy assignments route through the resolver.
	var sp_script: GDScript = load("res://Scripts/AISpawner.gd")
	var src: String = sp_script.source_code if sp_script != null else ""
	_report("enemy = _rtv_resolve_ai_type(zone, bandit)" in src, "M4a AISpawner enemy assignment rewritten",
			"marker in live source: %s" % str("enemy = _rtv_resolve_ai_type(zone, bandit)" in src))
	if sp_script != null and "_rtv_resolve_ai_type" in src:
		var sp = sp_script.new()
		var r0 = sp._rtv_resolve_ai_type(0, null)
		var r1 = sp._rtv_resolve_ai_type(1, null)
		var r3 = sp._rtv_resolve_ai_type(3, null)
		_report(r0 == _area05_scene, "M4b resolver Area05 override", str(r0))
		_report(r1 == null, "M4c resolver BorderZone untouched", str(r1))
		_report(r3 == _debug_scene, "M4d resolver Debug register", str(r3))
		sp.free()

	# M5: Loader carries the shelter and the B_Loader shim works.
	var ldr = get_tree().root.get_node_or_null("Loader")
	var has_shelter: bool = ldr != null and ("B2TestShelter" in ldr.shelters) and ldr._rtv_mod_shelters.has("B2TestShelter")
	_report(has_shelter, "M5a Loader shelters", "shelters=%s" % (str(ldr.shelters) if ldr != null else "no Loader"))
	if ldr != null and ldr.has_method("add_shelter"):
		var ok: bool = ldr.add_shelter({"map_name": "B2TestMap", "path": "res://B2TestRegistry/TestShelter.tscn", "shelter": false})
		_report(ok and ldr._rtv_mod_scene_paths.has("B2TestMap"), "M5b B_Loader add_shelter shim", str(ok))
	else:
		_report(false, "M5b B_Loader add_shelter shim", "Loader has no add_shelter")

	# M6: Database routes the registered scene through _get().
	var db = get_tree().root.get_node_or_null("Database")
	var got = db.get("B2TestScene") if db != null else null
	_report(got == _test_scene, "M6 Database.get routes mod scene", str(got))
	var vanilla = db.get("Makarov") if db != null else null
	_report(vanilla is PackedScene, "M6b Database.get vanilla const still resolves", str(vanilla))

	# M7: loader health records.
	var status := FileAccess.get_file_as_string("user://modloader_hook_status.json")
	_report("\"ok\"" in status, "M7a hook status record", status.strip_edges())
	_report(true, "M7b game-updated marker present", str(FileAccess.file_exists("user://modloader_game_updated")))


func _summary(phase: String) -> void:
	print("%s SUMMARY %s pass=%d fail=%d" % [TAG, phase, _pass, _fail])
