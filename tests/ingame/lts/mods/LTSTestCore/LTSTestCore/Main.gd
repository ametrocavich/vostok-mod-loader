## LTS Test: Core, the self-checking mod of tests/ingame/lts: boot checks in _ready, the
## menu phase from a Menu._ready hook; evaluate.py grades the lines. Never ships to players.
extends "res://LTSTestCore/Kit.gd"

const LT_MASTER_PATH := "res://Loot/LT_Master.tres"
const RECIPE_DATA_SCRIPT := "res://Scripts/RecipeData.gd"
const MENU_SCRIPT := "res://Scripts/Menu.gd"
const DEP_READY_META := "lts_dep_ready_ticks"
const RECIPE_CATEGORY := "consumables"
const BACK_TO_GAME := "Back to game"

var _menu_started := false
var _menu_node = null

func _ready() -> void:
	var f := FileAccess.open(PROGRESS, FileAccess.WRITE)
	if f != null:
		f.store_line("run start")
		f.close()
	_lib = Engine.get_meta("RTVModLib", null)
	var checks := [["L0", "lib", _check_lib]]
	if _lib != null:
		checks += [["D1", "dependency order", _check_dep_order], ["D2", "has_mod", _check_has_mod],
				["D3", "mod_info and loaded_mods", _check_mod_info], ["D4", "required beats optional",
				_check_required_wins], ["A1", "active_profile", _check_active_profile],
				["G1", "array-entry revert order", _check_array_entry_revert], ["G2", "trader_pools two handles",
				_check_trader_pools], ["G3", "resources cache", _check_resources_cache], ["G4", "enumeration",
				_check_enumeration], ["G5", "refusals and shapes", _check_refusals], ["G6", "setup plan",
				_check_setup_plan], ["H1", "menu hook registered", _check_hook_registered]]
	await _run_all(checks)
	_drain("registry")
	_summary("boot")

func _check_lib() -> void:
	var version := str(_lib.version()) if _lib != null else "missing: no Engine meta RTVModLib"
	_report(version.begins_with("3."), "version() %s" % version)

func _check_dep_order() -> void:
	var now := Time.get_ticks_msec()
	var dep := int(Engine.get_meta(DEP_READY_META, -1))
	_report(dep >= 0 and dep <= now, "lts_dep ready at %d ms (-1: never), lts_core at %d ms" % [dep, now])

func _check_has_mod() -> void:
	var got := [_lib.has_mod("lts_dep"), _lib.has_mod("lts_dep", "1.0.0"), _lib.has_mod("lts_dep", "9.9.9"),
			_lib.has_mod("lts_nobody")]
	_report(got == [true, true, false, false], "lts_dep, >=1.0.0, >=9.9.9, lts_nobody: %s" % str(got))

func _check_mod_info() -> void:
	var info: Dictionary = _lib.mod_info("lts_core")
	var req: Array = info.get("required_dependencies", [])
	var mods: Array = _lib.loaded_mods()
	var ok: bool = info.has_all(["mod_id", "version", "file_name", "required_dependencies"]) and req.has("lts_dep") \
			and info.get("mod_id") == "lts_core" and str(info.get("version")) == "1.0.0" \
			and mods.find("lts_dep") >= 0 and mods.find("lts_dep") < mods.find("lts_core")
	_report(ok, "keys %s, required %s, loaded_mods %s" % [str(info.keys()), str(req), str(mods)])

func _check_required_wins() -> void:
	var core: Dictionary = _lib.mod_info("lts_core")
	var req: Array = core.get("required_dependencies", [])
	# The other half of D4, no dependency-loop warning naming lts_, is graded
	# from the log, so no line printed here may contain that word.
	_report(req.has("lts_dep"), "lts_core required %s, optional %s; lts_dep optional %s" % [str(req),
			str(core.get("optional_dependencies")), str(_lib.mod_info("lts_dep").get("optional_dependencies"))])

func _check_active_profile() -> void:
	var name := str(_lib.active_profile())
	_report(name == TEST_PROFILE, "active_profile() = \"%s\" (want \"%s\")" % [name, TEST_PROFILE])

func _recipes() -> Variant:
	var book = load(_lib._RECIPES_PATH)
	return book.get(RECIPE_CATEGORY) if book != null else null

# A RecipeData built the way registry/aggregators.gd builds one, else a copy of a vanilla recipe.
func _new_recipe(recipe_name: String) -> Resource:
	var script = load(RECIPE_DATA_SCRIPT) if ResourceLoader.exists(RECIPE_DATA_SCRIPT) else null
	var r: Resource = script.new() if script is GDScript else null
	if r == null:
		var arr = _recipes()
		if arr is Array and not arr.is_empty() and arr[0] is Resource:
			r = arr[0].duplicate()
	if r != null:
		r.set("name", recipe_name)
	return r

# Dispatch T43 against Recipes.tres: revert puts the patch back on the entry it changed,
# the original back in the array and the override's entry out of it.
func _check_array_entry_revert() -> void:
	var first := _new_recipe("lts_r1_first")
	var second := _new_recipe("lts_r1_second")
	if first == null or second == null:
		_report(false, "could not build a RecipeData (%s missing)" % RECIPE_DATA_SCRIPT)
		return
	var id := "lts_r1"
	if not _verb("register", "recipes", id, {"recipe": first, "category": RECIPE_CATEGORY}):
		_report(false, "register false")
		return
	var arr = _recipes()
	var got := [arr is Array and first in arr,
			_verb("patch", "recipes", id, {"name": "lts_r1_patched"}) and str(first.get("name")) == "lts_r1_patched",
			_verb("override", "recipes", id, {"recipe": second, "category": RECIPE_CATEGORY, "replaces": first}),
			arr is Array and second in arr and not (first in arr), _verb("revert", "recipes", id),
			arr is Array and first in arr and not (second in arr),
			str(first.get("name")) == "lts_r1_first" and str(second.get("name")) == "lts_r1_second"]
	# revert gives the handle back to its registration; remove ends it.
	var record = _lib.get_entry("recipes", id)
	got += [record is Dictionary and record.get("recipe") == first, _verb("remove", "recipes", id),
			not _lib.has("recipes", id) and not (arr is Array and first in arr)]
	_report(false not in got, "register patch override swap revert back names handle remove gone %s" % str(got))

func _check_trader_pools() -> void:
	var master = load(LT_MASTER_PATH)
	var item: Resource = null
	# An item whose `driver` flag is off, so a stuck flag shows.
	for it in (master.get("items") if master != null and master.get("items") is Array else []):
		if item == null and it is Resource and it.get("driver") == false:
			item = it
	if item == null:
		_report(false, "no LT_Master item with driver=false to test with")
		return
	var got := [_verb("register", "trader_pools", "lts_tp_a", {"item": item, "trader": "Driver"}),
			_verb("register", "trader_pools", "lts_tp_b", {"item": item, "trader": "Driver"}),
			item.get("driver") == true, _verb("remove", "trader_pools", "lts_tp_a"), item.get("driver") == true,
			_verb("remove", "trader_pools", "lts_tp_b"), item.get("driver") == false]
	_report(false not in got, "%s: add a b, set, rm a, still set, rm b, clear %s" % [str(item.get("file")), str(got)])

func _check_resources_cache() -> void:
	var res = load(LT_MASTER_PATH)
	if res == null:
		_report(false, "%s does not load" % LT_MASTER_PATH)
		return
	var original := str(res.resource_name)
	var p1 := _verb("patch", "resources", LT_MASTER_PATH, {"resource_name": "lts_g3_first"})
	var e1 = _lib.get_entry("resources", LT_MASTER_PATH)
	var p2 := _verb("patch", "resources", LT_MASTER_PATH, {"resource_name": "lts_g3_second"})
	var e2 = _lib.get_entry("resources", LT_MASTER_PATH)
	var got := [p1, p2, e1 is Resource and e2 is Resource and e1.get_instance_id() == e2.get_instance_id(),
			e2 is Resource and str(e2.resource_name) == "lts_g3_second", _verb("revert", "resources", LT_MASTER_PATH),
			str(load(LT_MASTER_PATH).resource_name) == original]
	_report(false not in got, "patched twice, one instance, value, reverted, back to \"%s\": %s" % [original, str(got)])

func _check_enumeration() -> void:
	var scene_keys: Array = _lib.keys("scenes")
	var has_first: bool = not scene_keys.is_empty() and _lib.has("scenes", str(scene_keys[0]))
	var recipe_keys: Array = _lib.keys("recipes")
	var listed: Dictionary = _lib.list("recipes")
	var bad := PackedStringArray()
	for k in listed:
		# Registry.md: vanilla recipe ids are "<category>:<recipe name>", values RecipeData.
		if not str(k).contains(":") or str(k).get_slice(":", 0) not in _lib._RECIPE_CATEGORIES \
				or not (listed[k] is Resource and listed[k].get("name") != null):
			bad.append(str(k))
	_report(has_first and not recipe_keys.is_empty() and not listed.is_empty() and bad.is_empty(),
			"scenes %d (first found %s), recipe keys %d, list %d, malformed %s" \
			% [scene_keys.size(), str(has_first), recipe_keys.size(), listed.size(), str(bad)])

func _check_refusals() -> void:
	var ids := ["lts_missing_a", "lts_missing_b"]
	var got := [_lib.patch("scenes", "x", {}), _lib.revert("weapons", "x"), _lib.register_many("recipes", {}),
			_lib.remove_many("recipes", ids)]
	var keys: Array = got[3].get("results", {}).keys() if got[3] is Dictionary else []
	keys.sort()
	_report(got[0] == false and got[1] == false and got[2] is Dictionary and got[2].has_all(["ok", "results"])
			and keys == ids, "patch scenes, revert weapons, register_many {}, remove_many: %s" % str(got))

func _check_setup_plan() -> void:
	var recipe := _new_recipe("lts_setup_recipe")
	if recipe == null:
		_report(false, "could not build a RecipeData")
		return
	var id := "lts_setup_r"
	_track("remove", "recipes", id, true)
	_track("revert", "recipes", id, true)
	var res = _lib.setup([["register", "recipes", {id: {"recipe": recipe, "category": RECIPE_CATEGORY}}],
			["patch", "recipes", {id: {"name": "lts_setup_patched"}}], ["revert", "recipes", {id: []}],
			["remove", "recipes", [id]]])
	var ok: bool = res is Dictionary and bool(res.get("ok", false))
	_track("remove", "recipes", id, not ok)
	_track("revert", "recipes", id, not ok)
	var arr = _recipes()
	var clean: bool = str(recipe.get("name")) == "lts_setup_recipe" and not (arr is Array and recipe in arr)
	var bad = _lib.setup([["register", "recipes"]])
	var results: Array = bad.get("results", []) if bad is Dictionary else []
	var error := str(results[0].get("error", "")) if not results.is_empty() and results[0] is Dictionary else ""
	var bad_ok: bool = bad is Dictionary and not bool(bad.get("ok", true)) and error != ""
	_report(ok and clean and bad_ok, "plan ok %s, restored %s; bad step error \"%s\"" % [str(ok), str(clean), error])

func _check_hook_registered() -> void:
	var id: int = _lib.hook("menu-_ready-post", _on_menu_ready)
	_report(id > 0, "hook id %d" % id)

func _script_path(node) -> String:
	return str(node.get_script().resource_path) if node != null and node.get_script() != null else ""

func _on_menu_ready() -> void:
	# The wrapper sets _caller to the Menu instance; the current scene is the fallback.
	var node = null
	for c in [_lib._caller, get_tree().current_scene]:
		if is_instance_valid(c) and c is Node and _script_path(node) != MENU_SCRIPT \
				and (node == null or _script_path(c) == MENU_SCRIPT):
			node = c
	var script_path := _script_path(node)
	_begin("H1", "menu hook fired")
	_report(script_path == MENU_SCRIPT, "scene %s, script %s" \
			% [str(node.scene_file_path) if node != null else "null", script_path])
	if not _menu_started:
		_menu_started = true
		_menu_node = node
		# Let Menu._ready and the loader's own menu hook finish first.
		_menu_phase.call_deferred()

func _menu_phase() -> void:
	_mark("menu phase start")
	# The launcher first, so no profile or pack change is pending when it closes.
	_undo["profiles"] = _restore_profiles
	await _run_all([["U1", "launcher opens", _check_launcher_opens], ["U2", "tabs render", _check_tabs_render],
			["U3", "dialog opens and closes", _check_dialog], ["U4", "Mods tab rebuild keeps the tab",
			_check_mods_rebuild], ["U5", "close without restart", _check_close], ["P1", "create profile post-boot",
			_check_create_profile], ["P2", "switch back", _check_switch_back], ["P3", "delete", _check_delete_profile]])
	_drain("profiles")
	_undo["pack"] = _restore_pack
	await _run_all([["K1", "apply a local pack", _check_apply_pack], ["K2", "unload", _check_unload_pack]])
	_drain("pack")
	await _network_phase()
	_emit("INFO", "S1", "summary", "%d pass %d fail" % [_pass, _fail])
	_summary("menu")
	_mark("menu tests done")

func _check_launcher_opens() -> void:
	if _ui_window() != null:
		_report(false, "the launcher window was already open before reopen_mod_ui()")
		return
	# Deferred: reopen_mod_ui returns only when the window closes (U5).
	Callable(_lib, "reopen_mod_ui").call_deferred()
	for i in 30:
		await get_tree().process_frame
		if _ui_window() != null:
			break
	var win = _ui_window()
	if win == null:
		_report(false, "no valid _ui_window after 30 frames")
		return
	var found: Array = win.find_children("*", "TabContainer", true, false)
	_tabs = found[0] if not found.is_empty() else null
	if _tabs == null:
		_report(false, "window open but no TabContainer in it")
		return
	var names := []
	for i in _tabs.get_tab_count():
		names.append(str(_tabs.get_tab_control(i).name))
	var want := [_lib.UI_TAB_MODS, _lib.UI_TAB_BROWSE, _lib.UI_TAB_MODPACKS]
	_report(names == want, "window %s, tabs %s (want %s)" % [str(win.name), str(names), str(want)])

func _check_tabs_render() -> void:
	if not _need_ui("U1 failed"):
		return
	var counts := PackedStringArray()
	var ok := true
	for i in _tabs.get_tab_count():
		_tabs.current_tab = i
		await _frames(2)
		if not is_instance_valid(_tabs):
			_report(false, "the TabContainer was freed while showing tab %d" % i)
			return
		var ctrl = _tabs.get_tab_control(i)
		counts.append("%s=%d (%d nodes)" % [str(ctrl.name), ctrl.get_child_count(),
				ctrl.find_children("*", "", true, false).size()])
		ok = ok and ctrl.get_child_count() >= 1
	_tabs.current_tab = 0
	await _frames(1)
	_report(ok, "children per tab: %s" % ", ".join(counts))

func _check_dialog() -> void:
	if not _need_ui("U1 failed"):
		return
	var before = _newest_confirmation(_ui_window())
	_lib._show_new_profile_dialog(_tabs)
	await _frames(1)
	var win = _ui_window()
	if win == null:
		_report(false, "the launcher window went away after opening the dialog")
		return
	var d = _newest_confirmation(win)
	if d == null or d == before:
		_report(false, "no new ConfirmationDialog under the launcher window")
		return
	var shown: bool = d.visible
	d.get_cancel_button().pressed.emit()
	await _frames(2)
	var gone: bool = not is_instance_valid(d) or not d.is_inside_tree()
	_report(shown and gone, "dialog shown %s, gone after Cancel %s" % [str(shown), str(gone)])

func _check_mods_rebuild() -> void:
	if not _need_ui("U1 failed"):
		return
	var mods_name := str(_lib.UI_TAB_MODS)
	var page = _tabs.find_child(mods_name, false, false)
	if page == null:
		_report(false, "no %s tab" % mods_name)
		return
	_tabs.current_tab = _tabs.get_tab_idx_from_control(page)
	await _frames(1)
	if not _need_ui("gone before the rebuild"):
		return
	_lib._rebuild_mods_tab(_tabs)
	await _frames(2)
	if not _need_ui("gone during the rebuild"):
		return
	var current := str(_tabs.get_tab_control(_tabs.current_tab).name)
	_report(current == mods_name, "current tab after rebuild \"%s\" (want \"%s\")" % [current, mods_name])

func _check_close() -> void:
	var win = _ui_window()
	if win == null:
		_report(false, "no launcher window to close (U1 failed)")
		return
	if _lib._post_boot_restart_needed():
		# Pressing now would restart the game mid-run; leave the window for the player.
		_report(false, "_post_boot_restart_needed() is true; the window is left open")
		return
	var btn = _lib._ui_launch_btn
	var via := "_ui_launch_btn"
	for b in win.find_children("*", "Button", true, false):
		if via != BACK_TO_GAME and str(b.text) == BACK_TO_GAME:
			btn = b
			via = BACK_TO_GAME
	if not is_instance_valid(btn):
		_report(false, "no launch/back button found")
		return
	btn.pressed.emit()
	await _frames(5)
	var closed: bool = _ui_window() == null
	var still_menu: bool = is_instance_valid(_menu_node) and get_tree().current_scene == _menu_node
	_report(closed and still_menu, "via %s: window gone %s, menu stays %s" % [via, str(closed), str(still_menu)])

func _check_create_profile() -> void:
	var sig := str(_lib._loaded_set_signature())
	var existed := _cfg_has_profile(_cfg(), TEMP_PROFILE)
	_lib._create_profile(TEMP_PROFILE)
	var cfg := _cfg()
	var got := [_cfg_has_profile(cfg, TEMP_PROFILE), _lib._mcm_switch_pending(),
			str(_lib.active_profile()) == TEST_PROFILE, str(_lib._loaded_set_signature()) == sig]
	_report(false not in got, "sections, swap pending, still %s, same load set %s; to %s%s" % [TEST_PROFILE, str(got),
			str(cfg.get_value("settings", "mcm_pending_to", "")), " (left over)" if existed else ""])

# Switching back to the profile whose MCM is live cancels the swap; a record
# that points at the booted profile also passes.
func _check_switch_back() -> void:
	_lib._switch_profile(TEST_PROFILE)
	var cfg := _cfg()
	var to := str(cfg.get_value("settings", "mcm_pending_to", ""))
	var pending: bool = _lib._mcm_switch_pending()
	var restart: bool = _lib._post_boot_restart_needed()
	_report((to == "" or to == TEST_PROFILE) and restart == pending, "swap to \"%s\", pending %s, restart %s" \
			% [to, str(pending), str(restart)])

func _check_delete_profile() -> void:
	_lib._switch_profile(TEMP_PROFILE)
	if str(_lib._active_profile) != TEMP_PROFILE:
		_report(false, "could not switch to %s (active is %s)" % [TEMP_PROFILE, str(_lib._active_profile)])
		return
	_lib._delete_active_profile()
	var cfg := _cfg()
	var slot := str(_lib.MCM_SNAPSHOT_BASE).path_join(TEMP_PROFILE)
	var now := str(_lib._active_profile)
	var cfg_active := str(cfg.get_value("settings", "active_profile", ""))
	var got := [not _cfg_has_profile(cfg, TEMP_PROFILE), not DirAccess.dir_exists_absolute(slot),
			now != TEMP_PROFILE and now == cfg_active and (now == "Default" or _cfg_has_profile(cfg, now))]
	_report(false not in got, "sections, slot gone, landed on \"%s\" (config \"%s\"): %s" % [now, cfg_active, str(got)])

func _check_apply_pack() -> void:
	for e in _lib.collect_modpack_metadata():
		if _pack_entry.is_empty() and (str(e.get("file_name", "")) == PACK_FILE
				or str(e.get("raw_name", "")) == PACK_NAME):
			_pack_entry = e
	if _pack_entry.is_empty():
		_report(false, "collect_modpack_metadata() does not list %s" % PACK_FILE)
		return
	var res = await _lib.apply_modpack(_pack_entry, null)
	if not (res is Dictionary):
		_report(false, "apply_modpack returned %s" % str(res))
		return
	var sanitized := str(_pack_entry.get("sanitized_name", ""))
	var pack_set := sanitized != "" and str(_cfg().get_value("settings", "active_modpack", "")) == sanitized
	var got := [bool(res.get("ok", false)), int(res.get("downloaded", -1)) == 0,
			int(res.get("failed_downloads", -1)) == 0, res.get("failures", []).is_empty(),
			str(_lib.active_profile()) == TEST_PROFILE, pack_set, _lib._mcm_switch_pending()]
	_report(false not in got, "ok, none downloaded or failed, still %s, pack set, swap pending %s; %s %s" \
			% [TEST_PROFILE, str(got), str(res.get("error", "")), str(res.get("failures", []))])

func _check_unload_pack() -> void:
	var res = _lib.unload_modpack(null)
	var cfg := _cfg()
	var active_pack := str(cfg.get_value("settings", "active_modpack", ""))
	var cfg_active := str(cfg.get_value("settings", "active_profile", ""))
	var ok: bool = res is Dictionary and bool(res.get("ok", false)) and active_pack == "" and cfg_active == TEST_PROFILE
	_report(ok, "unload %s; pack \"%s\"; profile \"%s\"; swap pending %s; restart %s" % [str(res), active_pack,
			cfg_active, str(_lib._mcm_switch_pending()), str(_lib._post_boot_restart_needed())])
