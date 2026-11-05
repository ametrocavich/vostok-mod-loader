## Dispatch harness: the real rewriter wraps FixtureDispatch.gd, then hooks and registry calls run through RTVModLib.
## It does not prove the game's own scripts rewrite or compile; check_codegen.sh does.
extends "res://runner_base.gd"

const FIXTURE_PATH := "res://Scripts/FixtureDispatch.gd"
const WRAPPER_MARKER := "# --- Metro mod loader inline hook dispatch wrappers ---"
const BUNDLE_DIR := "res://rtv_test"
const RECIPES_PATH := "res://Crafting/Recipes.tres"
const EVENTS_PATH := "res://Events/Events.tres"
const TRADER_PATH := "res://Traders/Generalist/Generalist.tres"
const NOT_STRING_REG := "registry name (2nd element) must be a String"
## Script fields of the stand-ins for the game's Resource types (_stub).
const FIELDS := {
	"item": {"file: String": "\"\"", "weight: float": "0.0", "tags: Array": "[]"},
	"recipe": {"name": "\"\"", "input": "[]", "output": "[]", "time": "1.0"},
	"event": {"name": "\"\"", "function": "\"\"", "possibility": "0.0", "day": "0"},
	"task": {"name": "\"\"", "trader": "\"\"", "deliver": "[]", "receive": "[]"},
	"recipes": {"consumables": "[]", "medical": "[]", "equipment": "[]", "weapons": "[]",
			"electronics": "[]", "misc": "[]", "furniture": "[]"},
	"events": {"events": "[]"},
	"tasks": {"tasks": "[]"},
	"loot": {"items": "[]"},
}

## The fixture bodies append to this Array (Engine meta "RTVDispatchLog").
var _log: Array = []
var _ml
var _lib
var _node_a: Node
var _node_b: Node
var _fake_db: Node
var _fake_loader: Node

func _init() -> void:
	super("dispatch", "T1..T46")
	# A coroutine that never resumes hangs the run; a clean one needs under 20 frames.
	max_frames = 2000

func _run() -> void:
	_ml = boot_loader()
	if _ml != null and _setup():
		var tests: Array[Callable] = [
			_t1_pre, _t2_replace, _t3_post, _t4_deferred, _t5_ordering, _t6_replace_single_owner, _t7_unhook,
			_t8_caller_nested, _t9_reentrancy, _t10_two_instances, _t11_coroutine, _t12_defaults,
			_t13_input_deadzone, _t14_input_events_restored, _t15_override_blocks_remove,
			_t16_revert_patched_object, _t17_scene_path_checks, _t18_when_predicate_types,
			_t19_has_mod_reads_a_v_prefix, _t20_freed_hook_owner, _t21_batch_bad_values, _t22_scene_node_revert,
			_t23_await_in_a_string, _t24_typed_sound_clips, _t25_active_profile, _t26_freed_replace_owner,
			_t27_awaiting_post_hook, _t28_resource_script, _t29_aggregator_batches, _t30_non_string_ids,
			_t31_bad_resource_refs, _t32_field_parsers, _t33_shape_heuristics, _t34_recipes_are_array_entries,
			_t35_events_are_array_entries, _t36_trader_task_entries, _t37_loot_is_an_array_entry,
			_t38_batch_verbs_report_per_id, _t39_unsupported_verbs_refuse, _t40_bundles_report_each_step,
			_t41_setup_runs_every_verb, _t42_trader_pool_flags, _t43_revert_order, _t44_one_resource_instance,
			_t45_vanilla_enumeration, _t46_registry_parity,
		]
		for t in tests:
			begin("T" + String(t.get_method()).get_slice("_", 1).substr(1))
			await t.call()
	_finish()

func _finish() -> void:
	for n in [_node_a, _node_b, _fake_db, _fake_loader]:
		if n != null:
			n.queue_free()
	if _ml != null:
		if Engine.has_meta("RTVModLib"):
			Engine.remove_meta("RTVModLib")
		_ml.free()
	super()

## Registers the loader as RTVModLib, rewrites the fixture in place and adds
## two nodes running it (A and B) to the tree.
func _setup() -> bool:
	begin("setup")
	_ml._register_rtv_modlib_meta()
	_lib = Engine.get_meta("RTVModLib")
	if not _assert(_lib == _ml, "RTVModLib is the registered loader"):
		return false
	Engine.set_meta("RTVDispatchLog", _log)
	var raw := FileAccess.get_file_as_string(FIXTURE_PATH)
	if raw == "":
		_fail("fixture missing at " + FIXTURE_PATH)
		return false
	var parsed: Dictionary = _ml._rtv_parse_script("FixtureDispatch.gd", raw)
	var coro: bool = parsed["functions"].any(func(fe): return fe["name"] == "CoroValue" and bool(fe["is_coroutine"]))
	if not _assert(coro, "the parser marks CoroValue a coroutine"):
		return false
	var rewritten: String = _ml._rtv_rewrite_vanilla_source(raw, parsed, {})
	if not _assert(WRAPPER_MARKER in rewritten, "the rewritten fixture has the wrapper marker"):
		return false
	if not _assert("\"fixturedispatch-add\"" in rewritten, "hook base fixturedispatch-add is emitted"):
		return false
	H.write_text(FIXTURE_PATH, rewritten)
	var scr := ResourceLoader.load(FIXTURE_PATH, "", ResourceLoader.CACHE_MODE_IGNORE) as GDScript
	if scr == null or not scr.can_instantiate():
		_fail("the rewritten fixture does not compile")
		return false
	_node_a = scr.new()
	_node_a.name = "A"
	_node_b = scr.new()
	_node_b.name = "B"
	root.add_child(_node_a)
	root.add_child(_node_b)
	return true

func _unhook_all(ids: Array) -> void:
	for id in ids:
		if int(id) != -1:
			_lib.unhook(int(id))
	_log.clear()

func _script(source: String) -> GDScript:
	var script := GDScript.new()
	script.source_code = source
	script.reload()
	return script

## A fresh script declaring FIELDS[kind], so every call is a type of its own.
func _stub_script(kind: String) -> GDScript:
	var source := "extends Resource\n"
	for field in FIELDS[kind]:
		source += "var %s = %s\n" % [field, FIELDS[kind][field]]
	return _script(source)

func _stub(kind: String, values := {}) -> Resource:
	var res: Resource = _stub_script(kind).new()
	for k in values:
		res.set(k, values[k])
	return res

func _key_event(code: Key) -> InputEventKey:
	var ev := InputEventKey.new()
	ev.keycode = code
	return ev

func _drop_action(action: String) -> void:
	if InputMap.has_action(action):
		InputMap.erase_action(action)

## An action the registry did not add: deadzone 0.2, keys A and B.
func _vanilla_action(action: String) -> void:
	_drop_action(action)
	InputMap.add_action(action, 0.2)
	for code in [KEY_A, KEY_B]:
		InputMap.action_add_event(action, _key_event(code))

func _save_scene(path: String, root_name: String) -> Error:
	var scene_root := Node.new()
	scene_root.name = root_name
	var packed := PackedScene.new()
	packed.pack(scene_root)
	scene_root.free()
	return ResourceSaver.save(packed, path)

## The registry reaches the Database and Loader autoloads through the tree.
## _has_loaded makes the loader's _ready return before it boots anything.
func _registry_tree() -> void:
	if _ml.is_inside_tree():
		return
	_ml.set("_has_loaded", true)
	root.add_child(_ml)
	_fake_db = _script("extends Node\n" \
			+ "var _rtv_mod_scenes: Dictionary = {}\n" \
			+ "var _rtv_override_scenes: Dictionary = {}\n" \
			+ "var _rtv_vanilla_scenes: Dictionary = {}\n" \
			+ "func _get(property: StringName):\n" \
			+ "\tvar key := String(property)\n" \
			+ "\tif _rtv_override_scenes.has(key):\n\t\treturn _rtv_override_scenes[key]\n" \
			+ "\tif _rtv_mod_scenes.has(key):\n\t\treturn _rtv_mod_scenes[key]\n" \
			+ "\tif _rtv_vanilla_scenes.has(key):\n\t\treturn _rtv_vanilla_scenes[key]\n" \
			+ "\treturn null\n").new()
	_fake_db.name = "Database"
	root.add_child(_fake_db)
	_fake_loader = _script("extends Node\n" \
			+ "const Cabin = \"res://Scripts/FixtureDispatch.gd\"\n" \
			+ "var _rtv_mod_scene_paths: Dictionary = {}\n" \
			+ "var _rtv_override_scene_paths: Dictionary = {}\n" \
			+ "var shelters: Array = [\"Attic\"]\n" \
			+ "var _rtv_vanilla_shelters: Array = [\"Attic\"]\n" \
			+ "var _rtv_mod_shelters: Dictionary = {}\n" \
			+ "var randomScenes: Array = []\n").new()
	_fake_loader.name = "Loader"
	root.add_child(_fake_loader)

func _t1_pre() -> void:
	var id: int = _lib.hook("fixturedispatch-add-pre", func(x, y): _log.append("pre:add:%d:%d" % [x, y]))
	_assert(id != -1, "a -pre hook registers")
	check_eq(_node_a.Add(2, 3), 5, "Add(2,3) with a pre hook")
	check_eq(_log, ["pre:add:2:3", "vanilla:Add:2:3"], "call log")
	_unhook_all([id])

func _t2_replace() -> void:
	begin("T2a")
	var id: int = _lib.hook("fixturedispatch-add", func(x, y):
		_log.append("repl:%d:%d:caller=%s" % [x, y, str(_lib._caller.name)])
		return 999)
	check_eq(_node_a.Add(2, 3), 5, "without skip_super vanilla's return wins")
	check_eq(_log, ["repl:2:3:caller=A", "vanilla:Add:2:3"], "call log")
	_unhook_all([id])

	# check_dispatch.sh --prove A (skip_super ignored) must fail T2b.
	begin("T2b")
	id = _lib.hook("fixturedispatch-add", func(_x, _y):
		_lib.skip_super()
		_log.append("replskip")
		return 999)
	check_eq(_node_a.Add(2, 3), 999, "with skip_super the callback's return wins")
	check_eq(_log, ["replskip"], "call log")
	_unhook_all([id])

	begin("T2c")
	id = _lib.hook("fixturedispatch-note", func(_m): _log.append("vrepl"))
	_node_a.Note("q")
	check_eq(_log, ["vrepl", "vanilla:Note:q"], "void replace, vanilla still runs")
	_unhook_all([id])

	begin("T2d")
	id = _lib.hook("fixturedispatch-note", func(_m):
		_lib.skip_super()
		_log.append("vreplskip"))
	_node_a.Note("q")
	check_eq(_log, ["vreplskip"], "void replace with skip_super")
	_unhook_all([id])

func _t3_post() -> void:
	# check_dispatch.sh --prove B (post result mutation dropped) must fail T3a.
	begin("T3a")
	var id: int = _lib.hook("fixturedispatch-add-post", func(_x, _y, res): return res + 100)
	check_eq(_node_a.Add(2, 3), 105, "a non-null post return replaces the result")
	_unhook_all([id])

	begin("T3b")
	id = _lib.hook("fixturedispatch-add-post", func(_x, _y, res):
		_log.append("post_saw:%s" % str(res))
		return null)
	check_eq(_node_a.Add(2, 3), 5, "a null post return passes through")
	check_eq(_log, ["vanilla:Add:2:3", "post_saw:5"], "call log")
	_unhook_all([id])

	# The 2-arg form logs a one-shot deprecation warning; that is expected.
	begin("T3c")
	id = _lib.hook("fixturedispatch-add-post", func(x, y):
		_log.append("legacy:%d:%d" % [x, y])
		return 12345)
	check_eq(_node_a.Add(2, 3), 5, "a legacy 2-arg post hook only observes")
	check_eq(_log, ["vanilla:Add:2:3", "legacy:2:3"], "call log")
	_unhook_all([id])

	# p50 doubles, p100 adds 1: (2+3)*2+1 = 11; the reverse order gives 12.
	begin("T3d")
	var ida: int = _lib.hook("fixturedispatch-add-post", func(_x, _y, res): return res * 2, 50)
	var idb: int = _lib.hook("fixturedispatch-add-post", func(_x, _y, res): return res + 1, 100)
	check_eq(_node_a.Add(2, 3), 11, "post hooks chain in ascending priority")
	_unhook_all([ida, idb])

func _t4_deferred() -> void:
	var id: int = _lib.hook("fixturedispatch-note-callback", func(m): _log.append("cb:" + str(m)))
	_node_a.Note("hi")
	check_eq(_log, ["vanilla:Note:hi"], "log before the deferred call")
	for i in 2:
		await process_frame
	check_eq(_log, ["vanilla:Note:hi", "cb:hi"], "log two frames later")
	_unhook_all([id])

func _t5_ordering() -> void:
	# Registered in descending priority, so only sorting can put pre10 first.
	var ids: Array = [
		_lib.hook("fixturedispatch-add-pre", func(_x, _y): _log.append("pre20"), 20),
		_lib.hook("fixturedispatch-add-pre", func(_x, _y): _log.append("pre10"), 10),
		_lib.hook("fixturedispatch-add", func(_x, _y):
			_log.append("repl")
			return 0),
		_lib.hook("fixturedispatch-add-post", func(_x, _y, _res):
			_log.append("post")
			return null),
		_lib.hook("fixturedispatch-add-callback", func(x, y): _log.append("cb:%d:%d" % [x, y])),
	]
	check_eq(_node_a.Add(1, 1), 2, "vanilla's return survives the full pipeline")
	var stages := ["pre10", "pre20", "repl", "vanilla:Add:1:1", "post"]
	check_eq(_log, stages, "log before the deferred call")
	for i in 2:
		await process_frame
	check_eq(_log, stages + ["cb:1:1"], "log two frames later")
	_unhook_all(ids)

func _t6_replace_single_owner() -> void:
	var id1: int = _lib.hook("fixturedispatch-add", func(_x, _y):
		_log.append("owner1")
		return 0)
	var id2: int = _lib.hook("fixturedispatch-add", func(_x, _y):
		_log.append("owner2")
		return 0)
	_assert(id1 != -1, "the first replace registers")
	check_eq(id2, -1, "the second replace registration")
	check_eq(_lib.get_replace_owner("fixturedispatch-add"), id1, "get_replace_owner")
	_assert(_lib.has_replace("fixturedispatch-add"), "has_replace while owned")
	check_eq(_node_a.Add(2, 3), 5, "Add(2,3) with the slot taken")
	check_eq(_log, ["owner1", "vanilla:Add:2:3"], "call log")
	_unhook_all([id1, id2])
	_assert(not _lib.has_replace("fixturedispatch-add"), "has_replace after unhook")

func _t7_unhook() -> void:
	var ida: int = _lib.hook("fixturedispatch-add-pre", func(_x, _y): _log.append("keepme_NOT"), 10)
	var idb: int = _lib.hook("fixturedispatch-add-pre", func(_x, _y): _log.append("survivor"), 20)
	_lib.unhook(ida)
	_node_a.Add(1, 1)
	check_eq(_log, ["survivor", "vanilla:Add:1:1"], "call log after one unhook")
	_unhook_all([idb])

func _t8_caller_nested() -> void:
	# A.Outer(B) calls B.Inner(); Outer's post runs after the nested call returned.
	var ids: Array = [
		_lib.hook("fixturedispatch-outer-pre", func(_peer): _log.append("pre:outer:caller=" + str(_lib._caller.name))),
		_lib.hook("fixturedispatch-inner-pre", func(): _log.append("pre:inner:caller=" + str(_lib._caller.name))),
		_lib.hook("fixturedispatch-outer-post", func(_peer, _res):
			_log.append("post:outer:caller=" + str(_lib._caller.name))
			return null),
	]
	check_eq(_node_a.Outer(_node_b), 6, "Outer(B) through nested dispatch")
	check_eq(_log, ["pre:outer:caller=A", "vanilla:Outer:start", "pre:inner:caller=B",
			"vanilla:Inner", "vanilla:Outer:end", "post:outer:caller=A"], "call log")
	_assert(_lib._caller == null, "_caller is null again after the call")
	_unhook_all(ids)

func _t9_reentrancy() -> void:
	# check_dispatch.sh --prove C (the guard key is never erased) must fail T9:
	# the nested call goes straight to vanilla, and the hook fires on the next call.
	var reent := func(x, y):
		_log.append("pre:add:%d:%d" % [x, y])
		if x == 2:
			_log.append("nested_returned:" + str(_node_a.Add(1, 1)))
	var id: int = _lib.hook("fixturedispatch-add-pre", reent)
	check_eq(_node_a.Add(2, 3), 5, "Add(2,3) with a re-entrant pre hook")
	check_eq(_log, ["pre:add:2:3", "vanilla:Add:1:1", "nested_returned:2", "vanilla:Add:2:3"], "first call log")
	_log.clear()
	check_eq(_node_a.Add(4, 4), 8, "Add(4,4) after the re-entrant call")
	check_eq(_log, ["pre:add:4:4", "vanilla:Add:4:4"], "next call log")
	_unhook_all([id])

func _t10_two_instances() -> void:
	# The re-entry guard is per instance: B gets its full dispatch inside A's.
	var cross := func(x, y):
		_log.append("pre:%s:%d:%d" % [str(_lib._caller.name), x, y])
		if _lib._caller == _node_a:
			_node_b.Add(9, 9)
	var id: int = _lib.hook("fixturedispatch-add-pre", cross)
	check_eq(_node_a.Add(1, 2), 3, "A.Add(1,2)")
	check_eq(_log, ["pre:A:1:2", "pre:B:9:9", "vanilla:Add:9:9", "vanilla:Add:1:2"], "call log")
	_assert(_lib._caller == null, "_caller is null again after the call")
	_unhook_all([id])

func _t11_coroutine() -> void:
	var ids: Array = [
		_lib.hook("fixturedispatch-corovalue-pre", func(x): _log.append("pre:cv:%d" % x)),
		_lib.hook("fixturedispatch-corovalue-post", func(_x, res):
			_log.append("post_saw:" + str(res))
			return res + 1),
	]
	var r = await _node_a.CoroValue(4)
	check_eq(r, 41, "await CoroValue(4) plus the post hook")
	check_eq(_log, ["pre:cv:4", "vanilla:CoroValue:start:4", "vanilla:CoroValue:end:4", "post_saw:40"], "call log")
	_unhook_all(ids)

func _t12_defaults() -> void:
	var id: int = _lib.hook("fixturedispatch-withdefaults-pre", func(a, b): _log.append("pre:wd:%d:%d" % [a, b]))
	check_eq(_node_a.WithDefaults(3), 10, "WithDefaults(3) applies the default 7")
	check_eq(_log, ["pre:wd:3:7", "vanilla:WithDefaults:3:7"], "call log, default omitted")
	_log.clear()
	check_eq(_node_a.WithDefaults(3, 1), 4, "WithDefaults(3,1)")
	check_eq(_log, ["pre:wd:3:1", "vanilla:WithDefaults:3:1"], "call log, default given")
	_unhook_all([id])

func _t13_input_deadzone() -> void:
	var action := "rtv_dispatch_deadzone_action"
	var deadzone := func() -> float: return InputMap.action_get_deadzone(action)
	_vanilla_action(action)
	_assert(_lib.override("inputs", action, {"default_event": _key_event(KEY_C), "deadzone": 0.8}), "override of an existing action")
	_assert(is_equal_approx(deadzone.call(), 0.8), "the override's deadzone reaches InputMap (got %f)" % deadzone.call())
	_assert(_lib.revert("inputs", action), "revert of the override")
	_assert(is_equal_approx(deadzone.call(), 0.2), "revert restores the action's deadzone (got %f)" % deadzone.call())
	_assert(_lib.patch("inputs", action, {"deadzone": 0.9}), "a deadzone patch")
	_assert(is_equal_approx(deadzone.call(), 0.9), "the patched deadzone reaches InputMap")
	_assert(_lib.revert("inputs", action), "revert of the patch")
	_assert(is_equal_approx(deadzone.call(), 0.2), "revert restores the live deadzone (got %f)" % deadzone.call())
	InputMap.erase_action(action)

func _t14_input_events_restored() -> void:
	var action := "rtv_dispatch_two_event_action"
	_vanilla_action(action)
	_assert(_lib.patch("inputs", action, {"default_event": _key_event(KEY_C)}), "an event patch")
	check_eq(InputMap.action_get_events(action).size(), 1, "events while patched")
	_assert(_lib.revert("inputs", action), "revert of the event patch")
	var codes: Array = InputMap.action_get_events(action).map(func(ev): return (ev as InputEventKey).keycode)
	check_eq(codes, [KEY_A, KEY_B], "events after the revert")

	_assert(_lib.override("inputs", action, {"default_event": _key_event(KEY_C)}), "override")
	_assert(_lib.revert("inputs", action), "revert of the override")
	_assert(_lib.get_entry("inputs", action) == null, "the reverted override leaves no entry")
	_assert(not _lib.remove("inputs", action), "remove refuses an action it did not add")
	_assert(InputMap.has_action(action), "the action stays in InputMap")

	var own := "rtv_dispatch_registered_action"
	_drop_action(own)
	_assert(_lib.register("inputs", own, {"display_label": "Mine", "default_event": _key_event(KEY_A)}), "register")
	_assert(_lib.override("inputs", own, {"display_label": "Theirs", "default_event": _key_event(KEY_B)}), "override of a registration")
	_assert(_lib.revert("inputs", own), "revert of that override")
	var entry = _lib.get_entry("inputs", own)
	_assert(entry is Dictionary and str(entry.get("display_label", "")) == "Mine",
			"the registration's payload is back (got %s)" % str(entry))
	_assert(_lib.remove("inputs", own), "the registration can still be removed")
	_assert(not InputMap.has_action(own), "and its action leaves InputMap")
	_drop_action(action)

func _t15_override_blocks_remove() -> void:
	_registry_tree()
	var mine := PackedScene.new()
	var theirs := PackedScene.new()
	_assert(_lib.register("scenes", "rtv_test_scene", mine), "register of a new scene id")
	_assert(_lib.override("scenes", "rtv_test_scene", theirs), "override of that registration")
	_assert(not _lib.remove("scenes", "rtv_test_scene"), "remove refuses an overridden id")
	_assert(_lib.get_entry("scenes", "rtv_test_scene") == theirs, "the override still resolves")
	_assert(_lib.revert("scenes", "rtv_test_scene"), "revert drops the override")
	_assert(_lib.get_entry("scenes", "rtv_test_scene") == mine, "the registration resolves again")
	_assert(_lib.remove("scenes", "rtv_test_scene"), "remove takes the registration")
	_assert(_lib.get_entry("scenes", "rtv_test_scene") == null, "and the id no longer resolves")

func _t16_revert_patched_object() -> void:
	_registry_tree()
	var first := _stub("item", {"file": "rtv_test_item", "weight": 1.0})
	var second := _stub("item", {"file": "rtv_test_item", "weight": 7.0})
	_assert(_lib.register("items", "rtv_test_item", first), "register of an item")
	_assert(_lib.patch("items", "rtv_test_item", {"weight": 5.0}), "patch")
	_assert(_lib.append("items", "rtv_test_item", "tags", "heavy"), "append")
	_assert(_lib.override("items", "rtv_test_item", second), "override after the patch")
	_assert(_lib.revert("items", "rtv_test_item"), "full revert")
	check_eq(first.get("weight"), 1.0, "the patched item's own weight")
	check_eq((first.get("tags") as Array).size(), 0, "the patched item's own array")
	check_eq(second.get("weight"), 7.0, "the override's weight is untouched")
	_assert(_lib.get_entry("items", "rtv_test_item") == first, "the id resolves to the registration")
	_lib.remove("items", "rtv_test_item")

	var path := FIXTURE_PATH
	_assert(_lib.register("scene_paths", "rtv_test_path", {"path": path, "shelter": false}), "register of a scene path")
	_assert(_lib.patch("scene_paths", "rtv_test_path", {"shelter": true}), "scene path patch")
	_assert(_lib.override("scene_paths", "rtv_test_path", {"path": path, "shelter": false, "menu": true}), "scene path override")
	_assert(_lib.revert("scene_paths", "rtv_test_path"), "scene path full revert")
	var registered: Dictionary = _fake_loader.get("_rtv_mod_scene_paths").get("rtv_test_path", {})
	check_eq(registered.get("shelter"), false, "the scene path's own flag")
	_lib.remove("scene_paths", "rtv_test_path")

func _t17_scene_path_checks() -> void:
	_registry_tree()
	var path := FIXTURE_PATH
	_assert(_lib.register("scene_paths", "rtv_test_read", {"path": path}), "register")
	_assert(_lib.override("scene_paths", "rtv_test_read", {"path": path, "menu": true}), "override")
	var entry = _lib.get_entry("scene_paths", "rtv_test_read")
	_assert(entry is Dictionary and bool(entry.get("menu", false)), "get_entry returns the override (got %s)" % str(entry))
	_assert(_lib.override("scene_paths", "Cabin", {"path": path, "menu": true}), "override of a vanilla scene name")
	entry = _lib.get_entry("scene_paths", "Cabin")
	_assert(entry is Dictionary and bool(entry.get("menu", false)), "get_entry sees the vanilla name's override")
	_assert(not _lib.patch("scene_paths", "Cabin", {"path": "res://Scenes/NoSuchScene.tscn"}), "a patch to a missing file is refused")
	check_eq(_fake_loader.get("_rtv_override_scene_paths")["Cabin"].get("path"), path, "the refused patch changed nothing")
	_assert(_lib.patch("scene_paths", "Cabin", {"path": path, "tutorial": true}), "a patch to an existing file")
	_lib.revert("scene_paths", "Cabin")
	_lib.revert("scene_paths", "rtv_test_read")
	_lib.remove("scene_paths", "rtv_test_read")

func _t18_when_predicate_types() -> void:
	var own := "rtv_dispatch_plan_action"
	_drop_action(own)
	var res = _lib.setup([
		["when", func(): return null, [["remove", "inputs", ["never_runs"]]]],
		["when", func(): return "yes", [["remove", "inputs", ["never_runs"]]]],
		["when", func(): return 1, [["register", "inputs", {own: {"default_event": _key_event(KEY_A)}}]]],
	])
	if not _assert(res is Dictionary, "setup() returns its result dict (got %s)" % str(res)):
		return
	var results: Array = res.get("results", [])
	if not check_eq(results.size(), 3, "one result per entry"):
		return
	check_eq(results[0].get("evaluated"), false, "a null predicate reads as false")
	check_eq(results[1].get("evaluated"), false, "a String predicate reads as false")
	check_eq(results[2].get("evaluated"), true, "a predicate returning 1 reads true")
	_assert(InputMap.has_action(own), "the entry after them still ran")
	_lib.remove("inputs", own)

func _t19_has_mod_reads_a_v_prefix() -> void:
	var loaded: Dictionary = _ml.get("_loaded_mod_ids")
	loaded["rtv_test_mod"] = {"mod_id": "rtv_test_mod", "version": "v1.3.0"}
	_assert(_lib.has_mod("rtv_test_mod", "1.2"), "v1.3.0 satisfies min_version 1.2")
	_assert(_lib.has_mod("rtv_test_mod", "v1.3"), "a v-prefixed min_version compares the same")
	_assert(not _lib.has_mod("rtv_test_mod", "1.4"), "v1.3.0 does not satisfy 1.4")
	loaded["rtv_test_mod"] = {"mod_id": "rtv_test_mod", "version": ""}
	_assert(_lib.has_mod("rtv_test_mod", "0"), "no version satisfies min_version 0")
	_assert(not _lib.has_mod("rtv_test_mod", "0.1"), "and nothing stricter")
	var record := {"mod_id": "rtv_test_mod", "mod_name": "RTV Test Mod", "version": "1.0.0",
			"file_name": "RTVTestMod.vmz", "priority": 0,
			"required_dependencies": ["rtv_base"], "optional_dependencies": []}
	loaded["rtv_test_mod"] = record
	var info: Dictionary = _lib.mod_info("rtv_test_mod")
	check_eq(info, record, "mod_info returns the loaded record")
	(info["required_dependencies"] as Array).append("rtv_other")
	info["version"] = "9.9.9"
	check_eq(record["required_dependencies"], ["rtv_base"], "mod_info copies nested arrays")
	check_eq(record["version"], "1.0.0", "mod_info copies the top level")
	check_eq(_lib.mod_info("rtv_no_such_mod"), {}, "mod_info of an unknown id")
	loaded.erase("rtv_test_mod")

class _HookOwner extends Node:
	var seen: Array = []
	func on_pre(x, y) -> void:
		seen.append([x, y])
	func on_replace(_x, _y) -> int:
		return -1

func _t20_freed_hook_owner() -> void:
	var gone := _HookOwner.new()
	var pre_id: int = _lib.hook("fixturedispatch-add-pre", gone.on_pre)
	var replace_id: int = _lib.hook("fixturedispatch-add", gone.on_replace)
	_assert(pre_id != -1 and replace_id != -1, "both hooks register")
	gone.free()
	_log.clear()
	check_eq(_node_a.Add(2, 3), 5, "Add(2,3) with only freed hooks")
	check_eq(_log, ["vanilla:Add:2:3"], "call log")
	_assert(not _lib.has_hooks("fixturedispatch-add-pre"), "dispatch drops the freed owner's pre hook")
	var other_id: int = _lib.hook("fixturedispatch-add", func(_x, _y): return 0)
	_assert(other_id != -1, "a freed owner's replace slot can be taken")
	check_eq(_lib.get_replace_owner("fixturedispatch-add"), other_id, "the slot's new owner")
	_unhook_all([other_id])

func _t21_batch_bad_values() -> void:
	var hooked = _lib.hook_many({"fixturedispatch-add-pre": null, "fixturedispatch-add-post": func(_x, _y, res): return res})
	if _assert(hooked is Dictionary, "hook_many returns its result dict (got %s)" % str(hooked)):
		var results: Dictionary = hooked.get("results", {})
		check_eq(results.get("fixturedispatch-add-pre"), -1, "a value that is not a Callable")
		_assert(int(results.get("fixturedispatch-add-post", -1)) != -1, "the entry after it still registers")
		check_eq(hooked.get("ok"), false, "hook_many ok")
		_unhook_all([int(results.get("fixturedispatch-add-post", -1))])
	var own := "rtv_dispatch_batch_action"
	_drop_action(own)
	_lib.register("inputs", own, {"default_event": _key_event(KEY_A)})
	var patched = _lib.patch_many("inputs", {"rtv_no_such_action": "display_label", own: {"display_label": "Batch"}})
	if _assert(patched is Dictionary, "patch_many returns its result dict (got %s)" % str(patched)):
		var presults: Dictionary = patched.get("results", {})
		check_eq(presults.get("rtv_no_such_action"), false, "a value that is not a Dictionary")
		check_eq(presults.get(own), true, "the entry after it still applies")
	var found = _lib.find("inputs", func(_entry): return null, false)
	_assert(found is Array and found.is_empty(), "a null predicate matches nothing (got %s)" % str(found))
	found = _lib.find("inputs", func(entry): return entry.get("display_label") == "Batch", false)
	_assert(found is Array and found.size() == 1, "a bool predicate still matches")
	_lib.remove("inputs", own)

func _t22_scene_node_revert() -> void:
	_registry_tree()
	var scene_path := "res://Scripts/rtv_test_scene.tscn"
	if not check_eq(_save_scene(scene_path, "Fixture"), OK, "the fixture scene saves"):
		return
	var id := scene_path + "#."
	_assert(_lib.patch("scene_nodes", id, {"process_priority": 7}), "patch of a real property")
	_assert(not _lib.revert("scene_nodes", id, ["process_physics_priority"]), "revert of an unpatched field is false")
	_assert(_lib.revert("scene_nodes", id, ["process_priority"]), "revert of the patched field is true")
	_assert(not _lib.revert("scene_nodes", id), "and nothing is left to revert")

# A body flagged by mistake makes its wrapper a coroutine, and every caller
# then fails to parse ("must be called with await").
func _t23_await_in_a_string() -> void:
	var src := "extends Node\n" \
			+ "func says() -> void:\n\tprint(\"please await the signal\")\n" \
			+ "func noted() -> void:\n\tvar x := 1 # await later\n\tprint(x)\n" \
			+ "func waits() -> void:\n\tawait get_tree().process_frame\n" \
			+ "func both() -> void:\n\tprint(\"await \"); await get_tree().process_frame\n"
	var coro := {}
	for fe in _ml._rtv_parse_script("T23.gd", src)["functions"]:
		coro[str(fe["name"])] = bool(fe["is_coroutine"])
	for c in [["says", false, "await inside a string literal"], ["noted", false, "await inside a trailing comment"],
			["waits", true, "a real await"], ["both", true, "a real await after a string"]]:
		check_eq(bool(coro.get(c[0], not c[1])), c[1], c[2])

# The game types AudioEvent.audioClips as Array[AudioStreamWAV], and Object.set
# silently refuses an untyped Array for it: the event would play nothing.
func _t24_typed_sound_clips() -> void:
	var ev_script := _script("extends Resource\n@export var audioClips: Array[AudioStreamWAV]\n" \
			+ "@export var volume: float = 0.0\n@export var randomPitch: bool = false\n")
	var library: Resource = _script("extends Resource\n@export var transition: Resource\n").new()
	var vanilla_event: Resource = ev_script.new()
	library.set("transition", vanilla_event)
	_ml._registry_resource_cache["res://Resources/AudioLibrary.tres"] = library
	var clips := func() -> Array: return library.get("transition").get("audioClips")
	var wav := AudioStreamWAV.new()
	_assert(_lib.override("sounds", "transition", wav), "a bare WAV override")
	_assert(clips.call() == [wav], "the bare WAV is the clip (got %s)" % str(clips.call()))
	_assert(_lib.override("sounds", "transition", {"audioClips": [wav], "volume": 3}), "a dict override")
	_assert(clips.call() == [wav], "the dict's clip lands (got %s)" % str(clips.call()))
	_assert(not _lib.override("sounds", "transition", AudioStreamGenerator.new()), "a clip the array refuses fails")
	_assert(clips.call() == [wav], "and the earlier override stays")
	var wav2 := AudioStreamWAV.new()
	_lib.patch("sounds", "transition", {"audioClips": [wav2]})
	_assert(clips.call() == [wav2], "a patch of audioClips lands (got %s)" % str(clips.call()))
	_assert(_lib.revert("sounds", "transition"), "the override reverts")
	_assert(library.get("transition") == vanilla_event, "and the vanilla event is back")
	_ml._registry_resource_cache.erase("res://Resources/AudioLibrary.tres")

# Mods key per-profile data on this. The launcher reopened from the menu moves
# _active_profile on a switch, but the mods keep running until the restart.
func _t25_active_profile() -> void:
	check_eq(_lib.active_profile(), "", "before the mods load")
	_ml.set("_active_profile", "Hardcore")
	_ml.load_all_mods()
	check_eq(_lib.active_profile(), "Hardcore", "after the mods load")
	_ml.set("_active_profile", "Casual")
	check_eq(_lib.active_profile(), "Hardcore", "after a switch in the reopened launcher")

# A mod asks has_replace() before registering its own replace and falls back
# to pre/post on a yes, so the queries must skip a freed owner too.
func _t26_freed_replace_owner() -> void:
	var gone := _HookOwner.new()
	var replace_id: int = _lib.hook("fixturedispatch-add", gone.on_replace)
	_assert(replace_id != -1, "the replace registers")
	_assert(_lib.has_replace("fixturedispatch-add"), "has_replace while the owner lives")
	check_eq(_lib.get_replace_owner("fixturedispatch-add"), replace_id, "get_replace_owner while the owner lives")
	gone.free()
	_assert(not _lib.has_replace("fixturedispatch-add"), "has_replace once the owner is freed")
	check_eq(_lib.get_replace_owner("fixturedispatch-add"), -1, "get_replace_owner once the owner is freed")
	_assert(not _lib.has_hooks("fixturedispatch-add"), "has_hooks agrees")

# A post hook that awaits returns a function state, which must not become the
# typed method's result.
func _t27_awaiting_post_hook() -> void:
	var id: int = _lib.hook("fixturedispatch-add-post", func(_x, _y, _res):
		await process_frame
		return 999)
	check_eq(_node_a.Add(2, 3), 5, "an awaiting post hook keeps vanilla's value")
	await process_frame
	await process_frame
	_unhook_all([id])

# The wrapper assigns self to _caller, so _caller must take a Resource: a
# Node-typed one aborts the wrapper after the re-entry guard is set.
func _t28_resource_script() -> void:
	var src := "extends Resource\nvar reset_count := 0\nfunc Reset():\n\treset_count += 1\n"
	var script := GDScript.new()
	script.source_code = _ml._rtv_rewrite_vanilla_source(src, _ml._rtv_parse_script("FixtureData.gd", src), {})
	if not _assert(script.reload() == OK, "the rewritten Resource script compiles"):
		return
	var data: Resource = script.new()
	var seen: Array = []
	var id: int = _lib.hook("fixturedata-reset-pre", func(): seen.append(str(_lib._caller.get("reset_count"))))
	data.call("Reset")
	check_eq(int(data.get("reset_count")), 1, "the body ran once under the wrapper")
	check_eq(seen, ["0"], "the pre hook saw the Resource as _caller")
	_assert(_lib._wrapper_active.is_empty(), "the re-entry guard was released")
	data.call("Reset")
	check_eq(int(data.get("reset_count")), 2, "the second call runs the body")
	check_eq(seen.size(), 2, "and the hook fired again")
	_unhook_all([id])

func _t29_aggregator_batches() -> void:
	check_eq(_lib.register_ai_loadout({}), {"ok": true, "results": {}}, "an empty batch")
	check_eq(_lib.register_ai_loadout({"a": {}}), {"ok": false, "results": {"a": {"ok": false}}}, "the primitive's bool wrapped in {ok}")
	var r: Dictionary = _lib.register_item({7: 5})
	_assert(not r["ok"] and r["results"].has("7") and not r["results"]["7"]["ok"], "a non-String key reported as str(key) (got %s)" % str(r))
	r = _lib.register_weapon({"w": 1})
	_assert(not r["ok"] and r["results"]["w"].has("fits_attachments_failed"), "a bad weapon reports every key (got %s)" % str(r))

func _t30_non_string_ids() -> void:
	for c in [["patch", ["items", 5, {"a": 1}]], ["revert", ["resources", 5]], ["revert", ["fish_species", 5]],
			["append", ["items", 5, "f", [1]]], ["append", ["recipes", 5, "f", [1]]]]:
		_assert(not _lib.callv(c[0], c[1]), "%s on %s refuses an int id" % [c[0], c[1][0]])

func _t31_bad_resource_refs() -> void:
	_assert(_ml._resolve_loot_table("") == null, "an empty table name")
	_assert(_ml._resolve_loot_table("LT_Nope") == null, "an unknown table name")
	_assert(_ml._resolve_loot_table("res://nope_t31.tres") == null, "a table path that does not load")
	_assert(_ml._resolve_trader_data("Nope") == null, "an unknown trader")
	_assert(_ml._registry_resource("res://nope_t31.tres", "") == null, "a missing resource, no section")
	_assert(_ml._registry_resource("res://nope_t31.tres", "t31") == null, "a missing resource warns once")
	_assert(_ml._registry_resource("res://nope_t31.tres", "t31") == null, "and stays null on the next call")

func _t32_field_parsers() -> void:
	for c in [[{"a": null}, "d", "a null field"], [{"a": 3}, "3", "an int field"],
			[{}, "d", "an absent field"], [{"a": "x"}, "x", "a String field"]]:
		check_eq(_ml._str_field(c[0], "a", "d"), c[1], c[2])
	for c in [["0.5", 0.5, "a numeric String"], [2, 1.0, "above 1 is clamped"], [null, 1.0, "null is the default"],
			[false, 0.0, "false disables"], ["abc", 0.0, "a junk String parses as 0"]]:
		_assert(is_equal_approx(_ml._parse_ai_chance(c[0], "x", "register"), c[1]), "chance: " + c[2])

func _t33_shape_heuristics() -> void:
	_assert(_lib.get_entry("recipes", "nope") == null, "get_entry on recipes")
	_assert(_lib.get_entry("random_scenes", "nope") == null, "get_entry on random_scenes")
	_assert(not _ml._looks_like_item_data(5) and not _ml._looks_like_recipe_data(null) \
			and not _ml._looks_like_audio_event("x"), "a non-Resource never matches")
	var res := Resource.new()
	_assert(not _ml._looks_like_task_data(res) and not _ml._looks_like_event_data(res), "a plain Resource does not match")
	_assert(_ml._has_properties(res, ["resource_name", "resource_path"]) \
			and not _ml._has_properties(res, ["resource_name", "nope"]), "_has_properties needs every property")

func _t34_recipes_are_array_entries() -> void:
	var book := _stub("recipes")
	_ml._registry_resource_cache[RECIPES_PATH] = book
	var shelf: Array = book.get("consumables")
	var vanilla := _stub("recipe", {"name": "Vanilla"})
	shelf.append(vanilla)
	var mine := _stub("recipe", {"name": "Mine"})
	var theirs := _stub("recipe", {"name": "Theirs"})
	var other := _stub("recipe", {"name": "Other"})

	_assert(_lib.register("recipes", "rtv_r_mine", {"recipe": mine, "category": "consumables"}), "register appends to the category")
	check_eq(shelf, [vanilla, mine], "the category after register")
	check_eq(_lib.get_entry("recipes", "rtv_r_mine"), {"recipe": mine, "category": "consumables"}, "get_entry returns the record")
	for c in [["rtv_r_mine", {"recipe": theirs, "category": "consumables"}, "a taken handle"],
			["rtv_r_dup", {"recipe": vanilla, "category": "consumables"}, "a recipe already there"],
			["rtv_r_bad", {"recipe": theirs, "category": "snacks"}, "an unknown category"],
			["rtv_r_bad", {"recipe": theirs}, "a payload without a category"],
			["rtv_r_bad", {"recipe": Resource.new(), "category": "consumables"}, "a non-RecipeData Resource"],
			["rtv_r_bad", theirs, "a payload that is not a Dictionary"]]:
		_assert(not _lib.register("recipes", c[0], c[1]), "register refuses " + c[2])
	check_eq(shelf, [vanilla, mine], "the refusals changed nothing")
	_assert(_lib.get_entry("recipes", "rtv_r_bad") == null, "and recorded nothing")
	# The misc category ships locked; unlocking its button is best-effort.
	_assert(_lib.register("recipes", "rtv_r_misc", {"recipe": theirs, "category": "misc"}), "a locked category registers")
	_assert(_lib.remove("recipes", "rtv_r_misc"), "and removes")
	check_eq(book.get("misc").size(), 0, "the misc category after remove")
	_assert(not _lib.remove("recipes", "rtv_r_none"), "remove refuses an unknown handle")

	_assert(_lib.patch("recipes", "rtv_r_mine", {"time": 5.0}), "patch by handle")
	check_eq(mine.get("time"), 5.0, "the field patched by handle")
	# Registry.md: a patch whose every field is unknown still reports true.
	_assert(_lib.patch("recipes", "rtv_r_mine", {"nope": 1}), "an all-unknown patch reports true")
	_assert(not _lib.patch("recipes", "rtv_r_mine", {}), "an empty patch is refused")
	_assert(not _lib.patch("recipes", "rtv_r_none", {"time": 2.0}), "patch refuses an unknown handle")
	_assert(_lib.patch("recipes", vanilla, {"time": 9.0}), "patch by ref without a handle")
	check_eq(vanilla.get("time"), 9.0, "the field patched by ref")
	var x := _stub("item", {"file": "rtv_in_x", "weight": 1.0})
	var y := _stub("item", {"file": "rtv_in_y", "weight": 1.0})
	_assert(_lib.append("recipes", "rtv_r_mine", "input", [x, y]), "append by handle")
	_assert(_lib.prepend("recipes", "rtv_r_mine", "input", y), "prepend of a present value adds nothing")
	_assert(_lib.remove_from("recipes", "rtv_r_mine", "input", x), "remove_from by handle")
	check_eq(mine.get("input"), [y], "the array after the three ops")
	_assert(_lib.append("recipes", vanilla, "output", x), "append by ref")
	_assert(not _lib.append("recipes", vanilla, "time", x), "an array op on a scalar is refused")
	_assert(not _lib.append("recipes", "rtv_r_none", "input", x), "an array op on an unknown handle")

	_assert(_lib.revert("recipes", vanilla, ["time"]), "per-field revert by ref")
	check_eq(vanilla.get("time"), 1.0, "the reverted field's original")
	check_eq(vanilla.get("output"), [x], "the other patched field stays")
	_assert(not _lib.revert("recipes", vanilla, ["time"]), "an unpatched field reports false")
	_assert(_lib.revert("recipes", vanilla), "full revert by ref")
	check_eq(vanilla.get("output"), [], "full revert restores the array")
	_assert(not _lib.revert("recipes", vanilla), "and leaves nothing to revert")

	_assert(not _lib.override("recipes", "rtv_r_ov", {"recipe": other, "category": "consumables"}), "an override without replaces is refused")
	_assert(not _lib.override("recipes", "rtv_r_ov", {"recipe": other, "category": "consumables",
			"replaces": _stub("recipe", {"name": "Absent"})}), "replaces must be in the category")
	_assert(not _lib.override("recipes", "rtv_r_ov", {"recipe": mine, "category": "consumables", "replaces": vanilla}),
			"the new recipe must not be there")
	_assert(_lib.override("recipes", "rtv_r_ov", {"recipe": other, "category": "consumables", "replaces": vanilla}), "override swaps the recipe")
	check_eq(shelf, [other, mine], "the category after the override")
	_assert(not _lib.override("recipes", "rtv_r_ov", {"recipe": theirs, "category": "consumables", "replaces": mine}),
			"a second override of one id")
	check_eq(_lib.get_entry("recipes", "rtv_r_ov"), {"recipe": other, "category": "consumables"}, "get_entry returns the override's record")
	_assert(not _lib.remove("recipes", "rtv_r_ov"), "remove refuses an override-backed id")
	_assert(_lib.revert("recipes", "rtv_r_ov"), "revert of the override")
	check_eq(shelf, [vanilla, mine], "the replaced recipe is back in place")
	_assert(_lib.get_entry("recipes", "rtv_r_ov") == null, "and the override's handle is gone")
	_assert(not _lib.revert("recipes", "rtv_r_ov"), "nothing is left to revert")
	_assert(_lib.override("recipes", "rtv_r_ov", {"recipe": other, "category": "consumables", "replaces": vanilla}), "override again")
	shelf.erase(other)
	_assert(_lib.revert("recipes", "rtv_r_ov"), "revert after the override's recipe left")
	check_eq(shelf, [mine, vanilla], "the replaced recipe is appended")

	_assert(_lib.revert("recipes", "rtv_r_mine"), "full revert of the handle's patches")
	_assert(mine.get("time") == 1.0 and mine.get("input").is_empty(), "restores every patched field")
	_assert(_lib.override("recipes", "rtv_r_mine", {"recipe": theirs, "category": "consumables", "replaces": mine}), "override of a registration")
	check_eq(_lib.get_entry("recipes", "rtv_r_mine"), {"recipe": theirs, "category": "consumables"}, "the handle resolves to the override")
	_assert(_lib.revert("recipes", "rtv_r_mine"), "revert of that override")
	check_eq(_lib.get_entry("recipes", "rtv_r_mine"), {"recipe": mine, "category": "consumables"}, "the handle is the registration's again")
	check_eq(shelf, [mine, vanilla], "and its recipe is back")

	_assert(_lib.patch("recipes", "rtv_r_mine", {"time": 4.0}), "patch before a remove")
	_assert(_lib.remove("recipes", "rtv_r_mine"), "remove of the registration")
	check_eq(shelf, [vanilla], "the category after remove")
	var again := _stub("recipe", {"name": "Again"})
	_assert(_lib.register("recipes", "rtv_r_mine", {"recipe": again, "category": "consumables"}), "the handle registers again")
	_assert(not _lib.revert("recipes", "rtv_r_mine"), "remove dropped the handle's patch stash")
	check_eq(again.get("time"), 1.0, "nothing was written onto the new recipe")
	_lib.remove("recipes", "rtv_r_mine")
	_ml._registry_resource_cache.erase(RECIPES_PATH)

func _t35_events_are_array_entries() -> void:
	var ev_script := _stub_script("event")
	var holder := _stub("events")
	holder.set("events", Array([], TYPE_OBJECT, &"Resource", ev_script))
	var list: Array = holder.get("events")
	_ml._registry_resource_cache[EVENTS_PATH] = holder
	var vanilla: Resource = ev_script.new()
	list.append(vanilla)
	var mine: Resource = ev_script.new()
	var other: Resource = ev_script.new()

	_assert(not _lib.register("events", "rtv_e_stranger", {"event": _stub("event")}), "the typed array refuses another script")
	_assert(not _lib.register("events", "rtv_e_bad", {"name": "x"}), "a payload without an event is refused")
	_assert(_lib.register("events", "rtv_e_mine", {"event": mine}), "register")
	_assert(list.size() == 2 and list[1] == mine, "register appends to the array")
	check_eq(_lib.get_entry("events", "rtv_e_mine"), {"event": mine}, "get_entry returns the record")
	_assert(not _lib.register("events", "rtv_e_again", {"event": mine}), "an event already there is refused")

	_assert(_lib.patch("events", "rtv_e_mine", {"day": 3}), "patch by handle")
	_assert(_lib.patch("events", vanilla, {"possibility": 0.5}), "patch by ref")
	_assert(mine.get("day") == 3 and is_equal_approx(vanilla.get("possibility"), 0.5), "both fields land")
	_assert(_lib.revert("events", "rtv_e_mine", ["day"]), "per-field revert by handle")
	check_eq(mine.get("day"), 0, "the reverted field's original")
	_assert(_lib.revert("events", vanilla), "full revert by ref")
	_assert(is_equal_approx(vanilla.get("possibility"), 0.0), "restores the ref's field")

	_assert(_lib.override("events", "rtv_e_ov", {"event": other, "replaces": vanilla}), "override")
	_assert(list.size() == 2 and list[0] == other, "override swaps in place")
	_assert(not _lib.override("events", "rtv_e_ov", {"event": vanilla, "replaces": other}), "a second override of one id")
	_assert(not _lib.remove("events", "rtv_e_ov"), "remove refuses an override-backed id")
	_assert(_lib.revert("events", "rtv_e_ov"), "revert of the override")
	_assert(list.size() == 2 and list[0] == vanilla, "the replaced event is back in place")
	_assert(_lib.remove("events", "rtv_e_mine"), "remove")
	_assert(list.size() == 1 and list[0] == vanilla, "remove takes the event out")
	_ml._registry_resource_cache.erase(EVENTS_PATH)

func _t36_trader_task_entries() -> void:
	var trader := _stub("tasks")
	_ml._registry_resource_cache[TRADER_PATH] = trader
	var list: Array = trader.get("tasks")
	var vanilla := _stub("task")
	list.append(vanilla)
	var mine := _stub("task")
	var other := _stub("task")

	for c in [[{"task": mine, "trader": "Nobody"}, "an unknown trader"], [{"task": mine, "trader": 3}, "a trader that is not a String"],
			[{"task": Resource.new(), "trader": "Generalist"}, "a non-TaskData Resource"]]:
		_assert(not _lib.register("trader_tasks", "rtv_t_bad", c[0]), "register refuses " + c[1])
	_assert(_lib.register("trader_tasks", "rtv_t_mine", {"task": mine, "trader": "Generalist"}), "register")
	check_eq(list, [vanilla, mine], "register appends to the tasks")
	check_eq(_lib.get_entry("trader_tasks", "rtv_t_mine"), {"task": mine, "trader": "Generalist"}, "get_entry returns the record")

	_assert(_lib.patch("trader_tasks", vanilla, {"name": "Patched"}), "patch by ref")
	_assert(_lib.append("trader_tasks", "rtv_t_mine", "deliver", [vanilla]), "append by handle")
	_assert(_lib.revert("trader_tasks", vanilla, ["name"]), "per-field revert by ref")
	check_eq(vanilla.get("name"), "", "the reverted field's original")
	_assert(_lib.revert("trader_tasks", "rtv_t_mine"), "full revert by handle")
	check_eq(mine.get("deliver"), [], "full revert restores the array")

	_assert(_lib.override("trader_tasks", "rtv_t_ov", {"task": other, "trader": "Generalist", "replaces": vanilla}), "override")
	check_eq(list, [other, mine], "override swaps in place")
	check_eq(_lib.get_entry("trader_tasks", "rtv_t_ov"), {"task": other, "trader": "Generalist"}, "get_entry returns the override's record")
	_assert(not _lib.override("trader_tasks", "rtv_t_ov", {"task": vanilla, "trader": "Generalist", "replaces": other}),
			"a second override of one id")
	_assert(not _lib.remove("trader_tasks", "rtv_t_ov"), "remove refuses an override-backed id")
	list.erase(other)
	_assert(_lib.revert("trader_tasks", "rtv_t_ov"), "revert after the override's task left")
	check_eq(list, [mine, vanilla], "the replaced task is appended")
	_assert(_lib.remove("trader_tasks", "rtv_t_mine"), "remove")
	check_eq(list, [vanilla], "remove takes the task out")
	_ml._registry_resource_cache.erase(TRADER_PATH)

func _t37_loot_is_an_array_entry() -> void:
	var path := "res://rtv_test/LT_Test.tres"
	var table := _stub("loot")
	_ml._registry_resource_cache[path] = table
	var list: Array = table.get("items")
	var vanilla := _stub("item", {"file": "rtv_loot_vanilla", "weight": 1.0})
	list.append(vanilla)
	var mine := _stub("item", {"file": "rtv_loot_mine", "weight": 1.0})
	var other := _stub("item", {"file": "rtv_loot_other", "weight": 1.0})

	for c in [[{"item": mine, "table": "LT_Nope"}, "an unknown table name"], [{"item": mine, "table": 5}, "a table that is not a String"],
			[{"item": Resource.new(), "table": path}, "a non-ItemData Resource"]]:
		_assert(not _lib.register("loot", "rtv_l_bad", c[0]), "register refuses " + c[1])
	_assert(_lib.register("loot", "rtv_l_mine", {"item": mine, "table": path}), "register by table path")
	check_eq(list, [vanilla, mine], "register appends to the table")
	check_eq(_lib.get_entry("loot", "rtv_l_mine"), {"item": mine, "table": path, "table_res": table}, "get_entry returns the record")
	_assert(not _lib.register("loot", "rtv_l_twice", {"item": mine, "table": path}), "an item already there is refused")
	_assert(not _lib.register("loot", "rtv_l_mine", {"item": other, "table": path}), "a taken handle is refused")
	_assert(not _lib.patch("loot", "rtv_l_mine", {"weight": 2.0}), "patch is refused")
	_assert(not _lib.append("loot", "rtv_l_mine", "tags", "x"), "the array ops are refused")
	_assert(not _lib.revert("loot", "rtv_l_mine"), "a registration has nothing to revert")

	_assert(not _lib.override("loot", "rtv_l_ov", {"item": other, "table": path}), "an override without replaces is refused")
	_assert(_lib.override("loot", "rtv_l_ov", {"item": other, "table": path, "replaces": vanilla}), "override")
	check_eq(list, [other, mine], "override swaps in place")
	check_eq(_lib.get_entry("loot", "rtv_l_ov"), {"item": other, "table": path, "table_res": table}, "get_entry returns the override's record")
	_assert(not _lib.override("loot", "rtv_l_ov", {"item": vanilla, "table": path, "replaces": other}), "a second override of one id")
	_assert(not _lib.remove("loot", "rtv_l_ov"), "remove refuses an override-backed id")
	_assert(_lib.revert("loot", "rtv_l_ov", ["ignored"]), "revert of the override ignores fields")
	check_eq(list, [vanilla, mine], "the replaced item is back in place")
	_assert(_lib.get_entry("loot", "rtv_l_ov") == null, "and the override's handle is gone")
	_assert(_lib.override("loot", "rtv_l_ov", {"item": other, "table": path, "replaces": vanilla}), "override again")
	list.erase(other)
	_assert(_lib.revert("loot", "rtv_l_ov"), "revert after the override's item left")
	check_eq(list, [mine, vanilla], "the replaced item is appended")
	_assert(_lib.remove("loot", "rtv_l_mine"), "remove")
	check_eq(list, [vanilla], "remove takes the item out")
	_assert(not _lib.remove("loot", "rtv_l_mine"), "and a second remove is refused")
	_ml._registry_resource_cache.erase(path)

func _t38_batch_verbs_report_per_id() -> void:
	_registry_tree()
	var a := "rtv_batch_a"
	var b := "rtv_batch_b"
	_drop_action(a)
	_drop_action(b)
	var r: Dictionary = _lib.register_many("inputs", {a: {"default_event": _key_event(KEY_A)}, 7: "bad", b: {"default_event": _key_event(KEY_B)}})
	check_eq(r, {"ok": false, "results": {a: true, 7: false, b: true}}, "register_many keys results by the given id")
	r = _lib.override_many("inputs", {"rtv_batch_none": {"default_event": _key_event(KEY_C)}, a: {"default_event": _key_event(KEY_C)}})
	check_eq(r, {"ok": false, "results": {"rtv_batch_none": false, a: true}}, "override_many")
	check_eq(_lib.patch_many("inputs", {b: {"display_label": "B"}}), {"ok": true, "results": {b: true}}, "patch_many")
	r = _lib.revert_many("inputs", {b: "display_label", a: []})
	check_eq(r, {"ok": false, "results": {b: false, a: true}}, "revert_many refuses a non-Array and continues")
	check_eq(_lib.revert_many("inputs", {b: ["display_label"]}), {"ok": true, "results": {b: true}}, "revert_many with a field list")
	r = _lib.remove_many("inputs", ["rtv_batch_none", a, b, 9])
	check_eq(r, {"ok": false, "results": {"rtv_batch_none": false, a: true, b: true, 9: false}}, "remove_many keys results by the given id")
	_assert(not InputMap.has_action(a) and not InputMap.has_action(b), "remove_many took both actions out")

	var item := _stub("item", {"file": "rtv_batch_item", "weight": 1.0})
	_lib.register("items", "rtv_batch_item", item)
	r = _lib.append_many("items", "tags", {"rtv_batch_missing": "x", "rtv_batch_item": ["x", "y"]})
	check_eq(r, {"ok": false, "results": {"rtv_batch_missing": false, "rtv_batch_item": true}}, "append_many")
	var ok_item := {"ok": true, "results": {"rtv_batch_item": true}}
	check_eq(_lib.prepend_many("items", "tags", {"rtv_batch_item": "w"}), ok_item, "prepend_many")
	check_eq(_lib.remove_from_many("items", "tags", {"rtv_batch_item": ["x"]}), ok_item, "remove_from_many")
	check_eq(_lib.append_many("items", "tags", {"rtv_batch_item": "w"}, true), ok_item, "append_many with allow_duplicates")
	check_eq(item.get("tags"), ["w", "y", "w"], "the array after the batched ops")
	check_eq(_lib.register_many("items", {}), {"ok": true, "results": {}}, "an empty batch is ok")
	_lib.revert("items", "rtv_batch_item")
	_lib.remove("items", "rtv_batch_item")

func _t39_unsupported_verbs_refuse() -> void:
	var aggregators := ["weapons", "magazines", "attachments"]
	var refuses := {
		"register": ["resources", "scene_nodes"],
		"override": ["trader_pools", "shelters", "maps", "random_scenes", "fish_species", "resources", "scene_nodes"] + aggregators,
		"patch": ["scenes", "loot", "trader_pools", "shelters", "maps", "random_scenes", "ai_types", "ai_loadouts", "fish_species"] + aggregators,
		"array_op": ["scenes", "loot", "trader_pools", "inputs", "scene_paths", "shelters", "maps", "random_scenes",
				"ai_types", "ai_loadouts", "fish_species", "scene_nodes"] + aggregators,
		"remove": ["resources", "scene_nodes"] + aggregators,
		"revert": aggregators,
	}
	for verb in refuses:
		for section in refuses[verb] + ["rtv_no_such_section"]:
			var calls: Array = [[verb, [section, "rtv_refused", {}]]]
			if verb == "array_op":
				calls = ["append", "prepend", "remove_from"].map(func(op): return [op, [section, "rtv_refused", "f", 1]])
			elif verb == "patch":
				calls = [[verb, [section, "rtv_refused", {"f": 1}]]]
			elif verb == "remove" or verb == "revert":
				calls = [[verb, [section, "rtv_refused"]]]
			for c in calls:
				check_eq(_lib.callv(c[0], c[1]), false, "%s('%s', ...) is refused" % [c[0], section])
	for section in ["scene_nodes", "rtv_no_such_section"] + aggregators:
		_assert(_lib.get_entry(section, "rtv_refused") == null, "get_entry('%s', ...) is refused" % section)

func _bundle_item(file_name: String, type_name: String) -> String:
	var path := "%s/%s.tres" % [BUNDLE_DIR, file_name]
	var res: Resource = (load(BUNDLE_DIR + "/rtv_item.gd") as GDScript).new()
	res.set("file", file_name)
	res.set("type", type_name)
	ResourceSaver.save(res, path)
	return path

# The bundles load their ItemData and scenes by path, so the fixtures are files.
func _t40_bundles_report_each_step() -> void:
	_registry_tree()
	H.write_text(BUNDLE_DIR + "/rtv_item.gd", "extends Resource\nvar file: String = \"\"\nvar type: String = \"\"\nvar compatible: Array = []\n" \
			+ "var generalist := false\nvar doctor := false\nvar gunsmith := false\nvar grandma := false\nvar driver := false\nvar hunter := false\n")
	H.write_text("res://Scripts/RecipeData.gd", "extends Resource\nvar name: String = \"\"\nvar input: Array = []\nvar output: Array = []\nvar time: float = 1.0\n" \
			+ "var audio: Resource\nvar heat := false\nvar workbench := false\nvar testbench := false\nvar shelter := false\n")
	var scene := BUNDLE_DIR + "/rtv_scene.tscn"
	_save_scene(scene, "BundleScene")
	var table_path := BUNDLE_DIR + "/LT_Bundle.tres"
	var table := _stub("loot")
	_ml._registry_resource_cache[table_path] = table
	var book := _stub("recipes")
	_ml._registry_resource_cache[RECIPES_PATH] = book
	var att := load(_bundle_item("rtv_att", "Attachment")) as Resource
	_assert(_lib.register("items", "rtv_att", att), "an attachment item to fit")

	var r: Dictionary = _lib.register_weapon({"rtv_w": {
		"item_path": _bundle_item("rtv_w", "Weapon"), "scene_path": scene, "rig_path": scene,
		"magazines": [{"id": "rtv_w_mag", "item_path": _bundle_item("rtv_w_mag", "Magazine"), "scene_path": scene}, "rtv_no_such_mag"],
		"fits_attachments": ["rtv_att", "rtv_no_such_att"],
		"loot_tables": [table_path],
		"ai_loadout": {"ai_types": ["Bandit"]},
	}})
	var weapon = _lib.get_entry("items", "rtv_w")
	var mag = _lib.get_entry("items", "rtv_w_mag")
	check_eq(r, {"ok": false, "results": {"rtv_w": {
		"ok": false, "items": true, "scene": true, "rig": true,
		"magazines": [
			{"id": "rtv_w_mag", "ok": true, "item_data": mag, "items": true, "scene": true, "loot_count": 0},
			{"id": "rtv_no_such_mag", "ok": false, "item_data": null},
		],
		"fits_attachments": ["rtv_att"], "fits_attachments_failed": ["rtv_no_such_att"],
		"loot_count": 1, "ai_loadout": true,
	}}}, "register_weapon")
	_assert(weapon != null and mag != null and weapon.get("compatible") == [mag, att], "compatible holds the magazine and attachment")
	_assert(_lib.get_entry("scenes", "rtv_w_Rig") != null, "the rig registers under <id>_Rig")
	_assert(table.get("items") == [weapon], "the weapon joins the loot table")
	_assert(_lib.get_entry("ai_loadouts", "rtv_w") is Dictionary, "the AI loadout registers under the weapon's id")
	r = _lib.register_weapon({"rtv_w_bad": {"item_path": "x"}})
	check_eq(r["results"]["rtv_w_bad"], {"ok": false, "items": false, "scene": false, "rig": false, "magazines": [],
			"fits_attachments": [], "fits_attachments_failed": [], "loot_count": 0, "ai_loadout": null}, "a weapon missing a required key")

	r = _lib.register_magazine({"rtv_mag2": {"item_path": _bundle_item("rtv_mag2", "Magazine"), "scene_path": scene,
			"fits_weapons": ["rtv_w", "rtv_no_such_weapon"], "loot_tables": [table_path]}})
	var mag2 = _lib.get_entry("items", "rtv_mag2")
	check_eq(r, {"ok": false, "results": {"rtv_mag2": {"ok": false, "items": true, "scene": true,
			"fits_weapons": ["rtv_w"], "fits_weapons_failed": ["rtv_no_such_weapon"], "loot_count": 1}}}, "register_magazine")
	_assert(weapon.get("compatible") == [mag, att, mag2], "the magazine joins its weapon's compatible")
	r = _lib.register_attachment({"rtv_att2": {"item_path": _bundle_item("rtv_att2", "Attachment"), "scene_path": scene, "fits_weapons": ["rtv_w"]}})
	check_eq(r, {"ok": true, "results": {"rtv_att2": {"ok": true, "items": true, "scene": true,
			"fits_weapons": ["rtv_w"], "fits_weapons_failed": [], "loot_count": 0}}}, "register_attachment")
	r = _lib.register_magazine({"rtv_mag_bad": {"item_path": "x"}})
	check_eq(r["results"]["rtv_mag_bad"], {"ok": false, "items": false, "scene": false,
			"fits_weapons": [], "fits_weapons_failed": [], "loot_count": 0}, "a magazine missing a required key")

	r = _lib.register_item({"rtv_ib": {"item_path": _bundle_item("rtv_ib", "Consumable"), "scene_path": scene,
			"loot_tables": [table_path], "trader_pools": ["Generalist", "Nobody"]}})
	var ib = _lib.get_entry("items", "rtv_ib")
	check_eq(r, {"ok": false, "results": {"rtv_ib": {"ok": false, "items": true, "scene": true, "loot_count": 1,
			"trader_pool_count": 1, "trader_pools": ["Generalist"], "trader_pools_failed": ["Nobody"]}}}, "register_item")
	_assert(ib != null and bool(ib.get("generalist")), "the item joins the Generalist's pool")
	r = _lib.register_item({"rtv_ib2": {"item_path": _bundle_item("rtv_ib2", "Consumable")}})
	check_eq(r, {"ok": true, "results": {"rtv_ib2": {"ok": true, "items": true, "scene": true, "loot_count": 0,
			"trader_pool_count": 0, "trader_pools": [], "trader_pools_failed": []}}}, "register_item without a scene")

	r = _lib.register_furniture({"rtv_f": {"item_path": _bundle_item("rtv_f", "Furniture"), "scene_path": scene,
			"recipe": {"input": [att], "time": 2}}})
	var furniture = _lib.get_entry("items", "rtv_f")
	check_eq(r, {"ok": true, "results": {"rtv_f": {"ok": true, "items": true, "scene": true, "trader_pool_count": 1,
			"trader_pools": ["Generalist"], "trader_pools_failed": [], "recipe": true}}}, "register_furniture defaults to the Generalist")
	var shelf: Array = book.get("furniture")
	_assert(shelf.size() == 1 and shelf[0].get("output") == [furniture] and shelf[0].get("input") == [att] \
			and is_equal_approx(shelf[0].get("time"), 2.0), "the recipe lands in Recipes.furniture")
	r = _lib.register_furniture({"rtv_f2": {"item_path": _bundle_item("rtv_f2", "Furniture"), "scene_path": scene,
			"trader_pools": ["Doctor"], "recipe": "bad"}})
	check_eq(r["results"]["rtv_f2"], {"ok": true, "items": true, "scene": true, "trader_pool_count": 1,
			"trader_pools": ["Doctor"], "trader_pools_failed": [], "recipe": false}, "a bad recipe fails only the recipe")

	_lib.remove("ai_loadouts", "rtv_w")
	_lib.remove("recipes", "rtv_f_recipe")
	_ml._registry_resource_cache.erase(table_path)
	_ml._registry_resource_cache.erase(RECIPES_PATH)

## The result setup() reports for a plan of one entry.
func _setup_entry(entry: Array) -> Dictionary:
	return _lib.setup([entry])["results"][0]

func _t41_setup_runs_every_verb() -> void:
	_registry_tree()
	var own := "rtv_setup_action"
	_drop_action(own)
	var it := "rtv_setup_item"
	var item := _stub("item", {"file": it, "weight": 1.0})
	_lib.register("items", it, item)

	for c in [[["register", "inputs", {own: {"default_event": _key_event(KEY_A)}}], own, "register"],
			[["override", "inputs", {own: {"default_event": _key_event(KEY_B)}}], own, "override"],
			[["revert", "inputs", {own: []}], own, "revert"],
			[["patch", "inputs", {own: {"display_label": "Setup"}}], own, "patch"],
			[["append", "items", "tags", {it: ["a", "b"]}], it, "append"],
			[["prepend", "items", "tags", {it: "a"}, true], it, "prepend with allow_duplicates"],
			[["remove_from", "items", "tags", {it: "b"}], it, "remove_from"],
			[["append", "items", "tags", {it: "c"}, null], it, "a null allow_duplicates reads false"]]:
		check_eq(_setup_entry(c[0]), {"verb": c[0][0], "ok": true, "results": {c[1]: true}}, c[2])
	check_eq(item.get("tags"), ["a", "a", "c"], "the array after the plan's ops")
	check_eq(_setup_entry(["remove", "inputs", [own]]), {"verb": "remove", "ok": true, "results": {own: true}}, "remove")
	var hooked := _setup_entry(["hooks", {"fixturedispatch-add-pre": func(_x, _y): pass}])
	var hook_id := int(hooked.get("results", {}).get("fixturedispatch-add-pre", -1))
	_assert(hooked.get("verb") == "hooks" and hooked.get("ok") == true and hook_id != -1, "hooks (got %s)" % str(hooked))
	_unhook_all([hook_id])
	check_eq(_setup_entry(["when", false, [["remove", "inputs", [own]]]]),
			{"verb": "when", "evaluated": false, "ok": true}, "a when that does not run")
	check_eq(_setup_entry(["when", true, [["remove", "inputs", ["rtv_setup_none"]]]]),
			{"verb": "when", "evaluated": true, "ok": false, "results": [{"verb": "remove", "ok": false, "results": {"rtv_setup_none": false}}]},
			"a when that runs reports its sub-plan")

	var scene := BUNDLE_DIR + "/rtv_scene.tscn"
	for c in [["register_item", {"rtv_setup_ib": {"item_path": _bundle_item("rtv_setup_ib", "Consumable")}}],
			["register_weapon", {"rtv_setup_w": {"item_path": _bundle_item("rtv_setup_w", "Weapon"), "scene_path": scene, "rig_path": scene}}],
			["register_magazine", {"rtv_setup_m": {"item_path": _bundle_item("rtv_setup_m", "Magazine"), "scene_path": scene,
					"fits_weapons": ["rtv_setup_w"]}}],
			["register_attachment", {"rtv_setup_a": {"item_path": _bundle_item("rtv_setup_a", "Attachment"), "scene_path": scene}}],
			["register_furniture", {"rtv_setup_f": {"item_path": _bundle_item("rtv_setup_f", "Furniture"), "scene_path": scene,
					"trader_pools": ["Doctor"]}}]]:
		check_eq(_setup_entry(c)["ok"], true, c[0])
	check_eq(_setup_entry(["register_ai_loadout", {"rtv_setup_l": {"weapon_scene": load(scene), "ai_types": ["Guard"]}}]),
			{"verb": "register_ai_loadout", "ok": true, "results": {"rtv_setup_l": {"ok": true}}}, "register_ai_loadout")
	_lib.remove("ai_loadouts", "rtv_setup_l")

	var bad: Array = []
	for verb in ["register", "override", "patch", "revert"]:
		bad += [[[verb, "inputs"], "expected [\"%s\", reg, {id: payload}]" % verb, "wrong arity"],
				[[verb, 5, {}], NOT_STRING_REG, "registry not a String"],
				[[verb, "inputs", []], "expected payload dict as 3rd arg", "payload not a Dictionary"]]
	for verb in ["append", "prepend", "remove_from"]:
		var usage := "expected [\"%s\", reg, field, {id: values}, allow_duplicates?]" % verb
		bad += [[[verb, "items", "tags"], usage, "too few arguments"],
				[[verb, "items", "tags", {}, false, 1], usage, "too many arguments"],
				[[verb, 5, "tags", {}], NOT_STRING_REG, "registry not a String"],
				[[verb, "items", 5, {}], "field name (3rd element) must be a String", "field not a String"],
				[[verb, "items", "tags", []], "expected payload dict as 4th arg", "payload not a Dictionary"]]
	bad += [[["remove", "inputs"], "expected [\"remove\", reg, [ids]]", "wrong arity"],
			[["remove", 5, []], NOT_STRING_REG, "registry not a String"],
			[["remove", "inputs", {}], "expected ids Array as 3rd arg", "ids not an Array"],
			[["hooks"], "expected [\"hooks\", {name: cb, ...}]", "wrong arity"],
			[["hooks", []], "expected hooks dict as 2nd arg", "payload not a Dictionary"],
			[["when", true], "expected [\"when\", predicate, sub_plan]", "wrong arity"],
			[["when", true, {}], "sub_plan must be an Array", "sub-plan not an Array"]]
	for verb in ["register_item", "register_weapon", "register_magazine", "register_attachment", "register_furniture", "register_ai_loadout"]:
		bad += [[[verb], "expected [\"%s\", {id: data, ...}]" % verb, "wrong arity"],
				[[verb, []], "expected payload dict as 2nd arg", "payload not a Dictionary"]]
	for b in bad:
		check_eq(_setup_entry(b[0]), {"verb": b[0][0], "ok": false, "error": b[1]}, "%s: %s" % [b[0][0], b[2]])
	check_eq(_setup_entry([]), {"verb": "<empty>", "ok": false, "error": "entry is empty"}, "an empty entry")
	check_eq(_setup_entry([5, "inputs", {}]), {"verb": "<malformed>", "ok": false, "error": "verb (1st element) must be a String"},
			"a verb that is not a String")
	check_eq(_setup_entry(["regster", "inputs", {}]), {"verb": "regster", "ok": false, "error": "unknown verb"}, "an unknown verb")
	check_eq(_lib.setup(["not an entry", ["remove", "inputs", ["rtv_setup_none"]]]),
			{"ok": false, "results": [{"verb": "<malformed>", "ok": false, "error": "entry is not an Array"},
			{"verb": "remove", "ok": false, "results": {"rtv_setup_none": false}}]}, "the plan runs past a malformed entry")
	_lib.revert("items", it)
	_lib.remove("items", it)

func _t42_trader_pool_flags() -> void:
	var item: Resource = (load(BUNDLE_DIR + "/rtv_item.gd") as GDScript).new()
	_assert(not _lib.register("trader_pools", "rtv_pool_bad", {"item": item, "trader": "Nobody"}), "an unknown trader is refused")
	_assert(_lib.register("trader_pools", "rtv_pool_a", {"item": item, "trader": "Doctor"}), "register")
	check_eq(item.get("doctor"), true, "register sets the trader's flag")
	check_eq(_lib.get_entry("trader_pools", "rtv_pool_a"), {"item": item, "trader": "Doctor", "flag": "doctor", "original": false},
			"get_entry returns the record")
	_assert(_lib.revert("trader_pools", "rtv_pool_a"), "revert is an alias of remove")
	check_eq(item.get("doctor"), false, "revert puts the original back")

	# Two handles on one pair: the last one to go puts the original back.
	_assert(_lib.register("trader_pools", "rtv_pool_a", {"item": item, "trader": "Doctor"}), "a first handle on the pair")
	_assert(_lib.register("trader_pools", "rtv_pool_b", {"item": item, "trader": "doctor"}), "a second handle on the pair")
	check_eq(_lib.get_entry("trader_pools", "rtv_pool_b").get("original"), false, "the second stashes the first's original")
	_assert(_lib.remove("trader_pools", "rtv_pool_b"), "remove of the later handle")
	check_eq(item.get("doctor"), true, "the flag stays for the first handle")
	_assert(_lib.remove("trader_pools", "rtv_pool_a"), "remove of the first")
	check_eq(item.get("doctor"), false, "the last remove puts the original back")
	_lib.register("trader_pools", "rtv_pool_a", {"item": item, "trader": "Doctor"})
	_lib.register("trader_pools", "rtv_pool_b", {"item": item, "trader": "Doctor"})
	_assert(_lib.remove("trader_pools", "rtv_pool_a"), "remove of the first of two")
	check_eq(item.get("doctor"), true, "the flag stays for the second handle")
	_assert(_lib.revert("trader_pools", "rtv_pool_b"), "revert of the second")
	check_eq(item.get("doctor"), false, "the last revert puts the original back")
	_lib.register("trader_pools", "rtv_pool_a", {"item": item, "trader": "Doctor"})
	_lib.register("trader_pools", "rtv_pool_g", {"item": item, "trader": "Generalist"})
	_lib.remove("trader_pools", "rtv_pool_a")
	_assert(item.get("doctor") == false and item.get("generalist") == true, "another trader's flag is left alone")
	_lib.remove("trader_pools", "rtv_pool_g")
	check_eq(item.get("generalist"), false, "that handle puts its own original back")
	item.set("hunter", true)
	_lib.register("trader_pools", "rtv_pool_h", {"item": item, "trader": "Hunter"})
	_lib.remove("trader_pools", "rtv_pool_h")
	check_eq(item.get("hunter"), true, "a flag that was already set stays")

## Registers first, patches it by handle, overrides the handle with second,
## then reverts: each entry keeps its own values and first is back in list.
func _override_after_patch(section: String, where: Dictionary, entry_key: String, list: Array,
		first: Resource, second: Resource, field: String, value: Variant, array_field: String, array_value: Variant) -> void:
	var handle := "rtv_order_" + section
	var first_value = first.get(field)
	var second_value = second.get(field)
	var second_array = second.get(array_field) if array_field != "" else null
	var payload := where.duplicate()
	payload[entry_key] = first
	_assert(_lib.register(section, handle, payload), "%s: register" % section)
	_assert(_lib.patch(section, handle, {field: value}), "%s: patch by handle" % section)
	if array_field != "":
		_assert(_lib.append(section, handle, array_field, [array_value]), "%s: append by handle" % section)
	var ov := where.duplicate()
	ov[entry_key] = second
	ov["replaces"] = first
	_assert(_lib.override(section, handle, ov), "%s: override of the patched registration" % section)
	_assert(_lib.revert(section, handle), "%s: full revert" % section)
	check_eq(first.get(field), first_value, "%s: the patched entry's own %s" % [section, field])
	check_eq(second.get(field), second_value, "%s: the override's own %s" % [section, field])
	if array_field != "":
		check_eq(first.get(array_field), [], "%s: the patched entry's own %s" % [section, array_field])
		check_eq(second.get(array_field), second_array, "%s: the override's own %s" % [section, array_field])
	_assert(first in list and not (second in list), "%s: the original entry is back" % section)
	var record = _lib.get_entry(section, handle)
	_assert(record is Dictionary and record[entry_key] == first, "%s: the handle is the registration's again" % section)
	_assert(not _lib.revert(section, handle), "%s: nothing is left to revert" % section)
	_lib.remove(section, handle)

func _t43_revert_order() -> void:
	var x := _stub("item", {"file": "rtv_order_x", "weight": 1.0})
	var book := _stub("recipes")
	_ml._registry_resource_cache[RECIPES_PATH] = book
	_override_after_patch("recipes", {"category": "consumables"}, "recipe", book.get("consumables"),
			_stub("recipe", {"name": "First"}), _stub("recipe", {"name": "Second", "time": 7.0, "input": [x, x]}),
			"time", 5.0, "input", x)
	_ml._registry_resource_cache.erase(RECIPES_PATH)

	var ev_script := _stub_script("event")
	var holder := _stub("events")
	holder.set("events", Array([], TYPE_OBJECT, &"Resource", ev_script))
	_ml._registry_resource_cache[EVENTS_PATH] = holder
	var event_second: Resource = ev_script.new()
	event_second.set("day", 9)
	_override_after_patch("events", {}, "event", holder.get("events"), ev_script.new(), event_second, "day", 3, "", null)
	_ml._registry_resource_cache.erase(EVENTS_PATH)

	var trader := _stub("tasks")
	_ml._registry_resource_cache[TRADER_PATH] = trader
	_override_after_patch("trader_tasks", {"trader": "Generalist"}, "task", trader.get("tasks"),
			_stub("task", {"name": "First"}), _stub("task", {"name": "Second", "deliver": [x]}), "name", "Patched", "deliver", x)
	_ml._registry_resource_cache.erase(TRADER_PATH)

## The loaded Resource is dropped on return, so only the registry can keep it cached.
func _resource_instance_id(path: String) -> int:
	var res := load(path)
	return res.get_instance_id() if res != null else 0

func _t44_one_resource_instance() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(BUNDLE_DIR))
	var path := BUNDLE_DIR + "/rtv_patch_target.tres"
	var original := Resource.new()
	original.resource_name = "Original"
	ResourceSaver.save(original, path)
	original = null  # only the registry may hold the .tres from here on
	_assert(_lib.patch("resources", path, {"resource_name": "First"}), "patch of a .tres by path")
	var patched := _resource_instance_id(path)
	_assert(_lib.revert("resources", path), "full revert")
	_assert(_lib.patch("resources", path, {"resource_name": "Second"}), "a second patch after the revert")
	check_eq(_resource_instance_id(path), patched, "the patch lands on the same instance")
	check_eq(String(load(path).resource_name), "Second", "load() sees the patch")
	_assert(_lib.revert("resources", path), "revert of the second patch")
	check_eq(String(load(path).resource_name), "Original", "revert puts the original back")

func _t45_vanilla_enumeration() -> void:
	_registry_tree()
	# A Database that extends another script and was not rewritten (no
	# _rtv_vanilla_scenes): both scripts' PackedScene consts are vanilla scenes.
	H.write_text(BUNDLE_DIR + "/rtv_db_base.gd", "extends Node\nconst RTVBaseScene = preload(\"%s/rtv_scene.tscn\")\n" % BUNDLE_DIR)
	var db_script := GDScript.new()
	db_script.source_code = "extends \"%s/rtv_db_base.gd\"\nconst RTVOwnScene = preload(\"%s/rtv_scene.tscn\")\n" % [BUNDLE_DIR, BUNDLE_DIR]
	check_eq(db_script.reload(), OK, "the subclass Database script compiles")
	var db: Node = db_script.new()
	root.remove_child(_fake_db)
	db.name = "Database"
	root.add_child(db)
	var scene_keys: Array[String] = _lib.keys("scenes")
	_assert("RTVOwnScene" in scene_keys, "the Database's own scene const (got %s)" % str(scene_keys))
	_assert("RTVBaseScene" in scene_keys, "its base script's scene const (got %s)" % str(scene_keys))
	root.remove_child(db)
	db.free()
	root.add_child(_fake_db)
	check_eq(String(_fake_db.name), "Database", "the stand-in Database is back")

	var book := _stub("recipes")
	book.get("medical").append(_stub("recipe", {"name": "Bandage"}))
	_ml._registry_resource_cache[RECIPES_PATH] = book
	_assert(_lib.has("recipes", "medical:Bandage"), "a recipe in the registry's Recipes.tres")
	_ml._registry_resource_cache.erase(RECIPES_PATH)

## Every section's verbs, expected from the 3.4.2 handlers; a DELTA row expects a ledger-accepted change.
## A row is [label, call, return, state delta]; the delta "vanilla" resets the expected state.
func _t46_registry_parity() -> void:
	_registry_tree()
	var vanilla_scenes: Dictionary = _fake_db.get("_rtv_vanilla_scenes")
	vanilla_scenes["RTV46Vanilla"] = PackedScene.new()
	for section in [_p46_scenes, _p46_items, _p46_loot, _p46_sounds, _p46_recipes, _p46_events,
			_p46_trader_pools, _p46_trader_tasks, _p46_inputs, _p46_scene_paths, _p46_shelters_maps,
			_p46_random_scenes, _p46_ai_types, _p46_fish_species, _p46_resources, _p46_scene_nodes,
			_p46_aggregators, _p46_ai_loadouts]:
		begin("T46 " + String(section.get_method()).trim_prefix("_p46_"))
		section.call()
	vanilla_scenes.erase("RTV46Vanilla")

func _parity(section: String, snap: Callable, rows: Array, ends_vanilla := true) -> void:
	var vanilla: Dictionary = snap.call()
	var want := vanilla.duplicate()
	for row in rows:
		check_eq(row[1].call(), row[2], "%s %s: return" % [section, row[0]])
		if row[3] is String:
			want = vanilla.duplicate()
		else:
			want.merge(row[3], true)
		check_eq(snap.call(), want, "%s %s: state" % [section, row[0]])
	if ends_vanilla:
		check_eq(snap.call(), vanilla, "%s: vanilla restored" % section)

func _plain(arr: Variant) -> Variant:
	if not (arr is Array):
		return arr
	var out: Array = []
	out.append_array(arr)
	return out

func _p46_scenes() -> void:
	var z1 := "rtv46_scene"
	var z2 := "RTV46Vanilla"
	var mine := PackedScene.new()
	var theirs := PackedScene.new()
	var van: PackedScene = _fake_db.get("_rtv_vanilla_scenes")[z2]
	var van_ov := PackedScene.new()
	var snap := func() -> Dictionary:
		return {"z1": _lib.get_entry("scenes", z1), "z2": _lib.get_entry("scenes", z2),
				"mod1": _lib.has("scenes", z1, false), "ov2": _lib.has("scenes", z2, false)}
	_parity("scenes", snap, [
		["z1 register", func(): return _lib.register("scenes", z1, mine), true, {"z1": mine, "mod1": true}],
		["z2 register refused", func(): return _lib.register("scenes", z2, theirs), false, {}],
		["z1 override", func(): return _lib.override("scenes", z1, theirs), true, {"z1": theirs}],
		["z2 override", func(): return _lib.override("scenes", z2, van_ov), true, {"z2": van_ov, "ov2": true}],
		["z1 override again", func(): return _lib.override("scenes", z1, mine), false, {}],
		["z1 remove refused", func(): return _lib.remove("scenes", z1), false, {}],
		["z1 patch refused", func(): return _lib.patch("scenes", z1, {"a": 1}), false, {}],
		["z1 revert", func(): return _lib.revert("scenes", z1), true, {"z1": mine}],
		["z2 revert", func(): return _lib.revert("scenes", z2), true, {"z2": van, "ov2": false}],
		["z2 revert again", func(): return _lib.revert("scenes", z2), false, {}],
		["z1 remove", func(): return _lib.remove("scenes", z1), true, {"z1": null, "mod1": false}],
		["z2 remove refused", func(): return _lib.remove("scenes", z2), false, {}],
	])

func _p46_items() -> void:
	var z1 := "rtv46_item"
	var z2 := "rtv46_vanilla_item"
	var mine := _stub("item", {"file": z1, "weight": 1.0})
	var theirs := _stub("item", {"file": z1, "weight": 7.0})
	var van := _stub("item", {"file": z2, "weight": 1.0})
	var van_ov := _stub("item", {"file": z2, "weight": 4.0})
	var saved = _ml.get("_vanilla_items")
	_ml.set("_vanilla_items", {z2: van})
	var fields := func(res: Resource) -> Array: return [res.get("weight"), (res.get("tags") as Array).duplicate()]
	var snap := func() -> Dictionary:
		var e1 = _lib.get_entry("items", z1)
		return {"z1": e1, "z2": _lib.get_entry("items", z2), "z1w": e1.get("weight") if e1 != null else null,
				"mine": fields.call(mine), "van": fields.call(van)}
	_parity("items", snap, [
		["z1 register", func(): return _lib.register("items", z1, mine), true, {"z1": mine, "z1w": 1.0}],
		["z2 register refused", func(): return _lib.register("items", z2, _stub("item", {"file": z2})), false, {}],
		["z1 patch", func(): return _lib.patch("items", z1, {"weight": 5.0}), true, {"z1w": 5.0, "mine": [5.0, []]}],
		["z1 append", func(): return _lib.append("items", z1, "tags", ["a", "b"]), true, {"mine": [5.0, ["a", "b"]]}],
		["z1 prepend", func(): return _lib.prepend("items", z1, "tags", "c"), true, {"mine": [5.0, ["c", "a", "b"]]}],
		["z1 remove_from", func(): return _lib.remove_from("items", z1, "tags", "a"), true, {"mine": [5.0, ["c", "b"]]}],
		["z2 patch", func(): return _lib.patch("items", z2, {"weight": 2.0}), true, {"van": [2.0, []]}],
		["z2 append", func(): return _lib.append("items", z2, "tags", "v"), true, {"van": [2.0, ["v"]]}],
		["z1 override", func(): return _lib.override("items", z1, theirs), true, {"z1": theirs, "z1w": 7.0}],
		["z2 override", func(): return _lib.override("items", z2, van_ov), true, {"z2": van_ov}],
		["z1 patch the override", func(): return _lib.patch("items", z1, {"weight": 9.0}), true, {"z1w": 9.0}],
		# The stash holds mine's weight, so it goes back onto mine.
		["z1 revert weight", func(): return _lib.revert("items", z1, ["weight"]), true, {"mine": [1.0, ["c", "b"]]}],
		["z1 revert weight again", func(): return _lib.revert("items", z1, ["weight"]), false, {}],
		["z1 revert all", func(): return _lib.revert("items", z1), true, {"z1": mine, "z1w": 1.0, "mine": [1.0, []]}],
		["z2 revert all", func(): return _lib.revert("items", z2), true, {"z2": van, "van": [1.0, []]}],
		["z2 revert again", func(): return _lib.revert("items", z2), false, {}],
		["z1 remove", func(): return _lib.remove("items", z1), true, {"z1": null, "z1w": null}],
		["z2 remove refused", func(): return _lib.remove("items", z2), false, {}],
	])
	_ml.set("_vanilla_items", saved)

func _p46_loot() -> void:
	var z1 := "rtv46_loot"
	var z2 := "rtv46_loot_ov"
	var path_a := "res://rtv_test/LT_T46a.tres"
	var path_b := "res://rtv_test/LT_T46b.tres"
	var ta := _stub("loot")
	var tb := _stub("loot")
	_ml._registry_resource_cache[path_a] = ta
	_ml._registry_resource_cache[path_b] = tb
	var va := _stub("item", {"file": "rtv46_va"})
	var vb := _stub("item", {"file": "rtv46_vb"})
	ta.get("items").append(va)
	tb.get("items").append(vb)
	var mine := _stub("item", {"file": "rtv46_mine"})
	var theirs := _stub("item", {"file": "rtv46_theirs"})
	var other := _stub("item", {"file": "rtv46_other"})
	var snap := func() -> Dictionary:
		return {"a": (ta.get("items") as Array).duplicate(), "b": (tb.get("items") as Array).duplicate(),
				"z1": _lib.get_entry("loot", z1), "z2": _lib.get_entry("loot", z2)}
	_parity("loot", snap, [
		["z1 register", func(): return _lib.register("loot", z1, {"item": mine, "table": path_a}), true,
				{"a": [va, mine], "z1": {"item": mine, "table": path_a, "table_res": ta}}],
		["z2 override", func(): return _lib.override("loot", z2, {"item": other, "table": path_b, "replaces": vb}), true,
				{"b": [other], "z2": {"item": other, "table": path_b, "table_res": tb}}],
		["z1 override", func(): return _lib.override("loot", z1, {"item": theirs, "table": path_a, "replaces": mine}), true,
				{"a": [va, theirs], "z1": {"item": theirs, "table": path_a, "table_res": ta}}],
		["z1 remove refused", func(): return _lib.remove("loot", z1), false, {}],
		["z1 patch refused", func(): return _lib.patch("loot", z1, {"weight": 2.0}), false, {}],
		["z1 revert", func(): return _lib.revert("loot", z1), true,
				{"a": [va, mine], "z1": {"item": mine, "table": path_a, "table_res": ta}}],
		["z2 revert", func(): return _lib.revert("loot", z2), true, {"b": [vb], "z2": null}],
		["z2 revert again", func(): return _lib.revert("loot", z2), false, {}],
		["z1 remove", func(): return _lib.remove("loot", z1), true, {"a": [va], "z1": null}],
		["z2 remove refused", func(): return _lib.remove("loot", z2), false, {}],
	])
	_ml._registry_resource_cache.erase(path_a)
	_ml._registry_resource_cache.erase(path_b)

func _p46_sounds() -> void:
	var lib_path := "res://Resources/AudioLibrary.tres"
	var z1 := "rtv46_sound"
	var z2 := "transition"
	var ev_script := _script("extends Resource\n@export var audioClips: Array[AudioStreamWAV]\n" \
			+ "@export var volume: float = 0.0\n@export var randomPitch: bool = false\n")
	var library: Resource = _script("extends Resource\n@export var transition: Resource\n").new()
	var van: Resource = ev_script.new()
	library.set("transition", van)
	_ml._registry_resource_cache[lib_path] = library
	var mine: Resource = ev_script.new()
	var van_ov: Resource = ev_script.new()
	var wav := AudioStreamWAV.new()
	var fields := func(ev: Resource) -> Array: return [ev.get("volume"), _plain(ev.get("audioClips"))]
	var snap := func() -> Dictionary:
		return {"z1": _lib.get_entry("sounds", z1), "z2": _lib.get_entry("sounds", z2),
				"mine": fields.call(mine), "van": fields.call(van)}
	_parity("sounds", snap, [
		["z1 register", func(): return _lib.register("sounds", z1, mine), true, {"z1": mine}],
		["z2 register refused", func(): return _lib.register("sounds", z2, ev_script.new()), false, {}],
		["z1 patch", func(): return _lib.patch("sounds", z1, {"volume": 3.0}), true, {"mine": [3.0, []]}],
		["z1 append", func(): return _lib.append("sounds", z1, "audioClips", wav), true, {"mine": [3.0, [wav]]}],
		["z2 patch", func(): return _lib.patch("sounds", z2, {"volume": 2.0}), true, {"van": [2.0, []]}],
		["z2 prepend", func(): return _lib.prepend("sounds", z2, "audioClips", wav), true, {"van": [2.0, [wav]]}],
		["z1 override refused", func(): return _lib.override("sounds", z1, ev_script.new()), false, {}],
		["z2 override", func(): return _lib.override("sounds", z2, van_ov), true, {"z2": van_ov}],
		["z2 revert volume", func(): return _lib.revert("sounds", z2, ["volume"]), true, {"van": [0.0, [wav]]}],
		["z2 revert all", func(): return _lib.revert("sounds", z2), true, {"z2": van, "van": [0.0, []]}],
		["z1 remove_from", func(): return _lib.remove_from("sounds", z1, "audioClips", wav), true, {"mine": [3.0, []]}],
		["z1 revert volume", func(): return _lib.revert("sounds", z1, ["volume"]), true, {"mine": [0.0, []]}],
		["z1 revert all", func(): return _lib.revert("sounds", z1), true, {}],
		["z1 revert again", func(): return _lib.revert("sounds", z1), false, {}],
		["z1 remove", func(): return _lib.remove("sounds", z1), true, {"z1": null}],
		["z2 remove refused", func(): return _lib.remove("sounds", z2), false, {}],
	])
	_ml._registry_resource_cache.erase(lib_path)

func _p46_recipes() -> void:
	var z1 := "rtv46_recipe"
	var z2 := "rtv46_recipe_ov"
	var book := _stub("recipes")
	_ml._registry_resource_cache[RECIPES_PATH] = book
	var shelf: Array = book.get("consumables")
	var van := _stub("recipe", {"name": "Vanilla46"})
	shelf.append(van)
	var mine := _stub("recipe", {"name": "Mine46"})
	var theirs := _stub("recipe", {"name": "Theirs46"})
	var other := _stub("recipe", {"name": "Other46"})
	var x := _stub("item", {"file": "rtv46_x"})
	var y := _stub("item", {"file": "rtv46_y"})
	var rec := func(r: Resource) -> Dictionary: return {"recipe": r, "category": "consumables"}
	var snap := func() -> Dictionary:
		return {"shelf": shelf.duplicate(), "z1": _lib.get_entry("recipes", z1), "z2": _lib.get_entry("recipes", z2),
				"mine": [mine.get("time"), mine.get("input").duplicate()], "van": [van.get("time"), van.get("output").duplicate()]}
	_parity("recipes", snap, [
		["z1 register", func(): return _lib.register("recipes", z1, rec.call(mine)), true,
				{"shelf": [van, mine], "z1": rec.call(mine)}],
		["z1 patch", func(): return _lib.patch("recipes", z1, {"time": 5.0}), true, {"mine": [5.0, []]}],
		["z1 append", func(): return _lib.append("recipes", z1, "input", x), true, {"mine": [5.0, [x]]}],
		["z1 prepend", func(): return _lib.prepend("recipes", z1, "input", y), true, {"mine": [5.0, [y, x]]}],
		["z1 remove_from", func(): return _lib.remove_from("recipes", z1, "input", x), true, {"mine": [5.0, [y]]}],
		["ref patch", func(): return _lib.patch("recipes", van, {"time": 3.0}), true, {"van": [3.0, []]}],
		["ref append", func(): return _lib.append("recipes", van, "output", x), true, {"van": [3.0, [x]]}],
		["z2 override", func(): return _lib.override("recipes", z2, {"recipe": other, "category": "consumables", "replaces": van}),
				true, {"shelf": [other, mine], "z2": rec.call(other)}],
		["z1 override", func(): return _lib.override("recipes", z1, {"recipe": theirs, "category": "consumables", "replaces": mine}),
				true, {"shelf": [other, theirs], "z1": rec.call(theirs)}],
		["z1 remove refused", func(): return _lib.remove("recipes", z1), false, {}],
		# DELTA (2026-10-29, T43): 3.4.2 wrote the stash onto theirs, the override.
		["z1 revert time", func(): return _lib.revert("recipes", z1, ["time"]), true, {"mine": [1.0, [y]]}],
		["z1 revert all", func(): return _lib.revert("recipes", z1), true,
				{"mine": [1.0, []], "shelf": [other, mine], "z1": rec.call(mine)}],
		["ref revert time", func(): return _lib.revert("recipes", van, ["time"]), true, {"van": [1.0, [x]]}],
		["ref revert all", func(): return _lib.revert("recipes", van), true, {"van": [1.0, []]}],
		["z2 revert", func(): return _lib.revert("recipes", z2), true, {"shelf": [van, mine], "z2": null}],
		["z2 revert again", func(): return _lib.revert("recipes", z2), false, {}],
		["z1 remove", func(): return _lib.remove("recipes", z1), true, {"shelf": [van], "z1": null}],
	])
	_ml._registry_resource_cache.erase(RECIPES_PATH)

func _p46_events() -> void:
	var z1 := "rtv46_event"
	var z2 := "rtv46_event_ov"
	var ev_script := _stub_script("event")
	var holder := _stub("events")
	holder.set("events", Array([], TYPE_OBJECT, &"Resource", ev_script))
	_ml._registry_resource_cache[EVENTS_PATH] = holder
	var list: Array = holder.get("events")
	var van: Resource = ev_script.new()
	list.append(van)
	var mine: Resource = ev_script.new()
	var other: Resource = ev_script.new()
	var snap := func() -> Dictionary:
		return {"list": _plain(list), "z1": _lib.get_entry("events", z1), "z2": _lib.get_entry("events", z2),
				"mine": [mine.get("day"), mine.get("possibility")], "van": [van.get("day"), van.get("possibility")]}
	_parity("events", snap, [
		["z1 register", func(): return _lib.register("events", z1, {"event": mine}), true,
				{"list": [van, mine], "z1": {"event": mine}}],
		["z1 patch", func(): return _lib.patch("events", z1, {"day": 3}), true, {"mine": [3, 0.0]}],
		["z1 append on scalar", func(): return _lib.append("events", z1, "day", 1), false, {}],
		["ref patch", func(): return _lib.patch("events", van, {"possibility": 0.5}), true, {"van": [0, 0.5]}],
		["z2 override", func(): return _lib.override("events", z2, {"event": other, "replaces": van}), true,
				{"list": [other, mine], "z2": {"event": other}}],
		["z2 override again", func(): return _lib.override("events", z2, {"event": van, "replaces": other}), false, {}],
		["z1 revert day", func(): return _lib.revert("events", z1, ["day"]), true, {"mine": [0, 0.0]}],
		["z1 revert all", func(): return _lib.revert("events", z1), false, {}],
		["ref revert all", func(): return _lib.revert("events", van), true, {"van": [0, 0.0]}],
		["z2 revert", func(): return _lib.revert("events", z2), true, {"list": [van, mine], "z2": null}],
		["z2 remove refused", func(): return _lib.remove("events", z2), false, {}],
		["z1 remove", func(): return _lib.remove("events", z1), true, {"list": [van], "z1": null}],
	])
	_ml._registry_resource_cache.erase(EVENTS_PATH)

func _p46_trader_pools() -> void:
	var item: Resource = _script("extends Resource\nvar file := \"rtv46_pool\"\nvar doctor := false\nvar hunter := true\n").new()
	var rec := func(trader: String, flag: String, original: bool) -> Dictionary:
		return {"item": item, "trader": trader, "flag": flag, "original": original}
	var snap := func() -> Dictionary:
		return {"doctor": item.get("doctor"), "hunter": item.get("hunter"), "h1": _lib.get_entry("trader_pools", "rtv46_h1"),
				"h2": _lib.get_entry("trader_pools", "rtv46_h2"), "h3": _lib.get_entry("trader_pools", "rtv46_h3")}
	_parity("trader_pools", snap, [
		["h1 register", func(): return _lib.register("trader_pools", "rtv46_h1", {"item": item, "trader": "Doctor"}), true,
				{"doctor": true, "h1": rec.call("Doctor", "doctor", false)}],
		["h2 same pair", func(): return _lib.register("trader_pools", "rtv46_h2", {"item": item, "trader": "doctor"}), true,
				{"h2": rec.call("doctor", "doctor", false)}],
		["h1 override refused", func(): return _lib.override("trader_pools", "rtv46_h1", {}), false, {}],
		["h1 patch refused", func(): return _lib.patch("trader_pools", "rtv46_h1", {"a": 1}), false, {}],
		# DELTA (2026-10-29, T42): 3.4.2 set doctor false while h2 still held it.
		["h1 remove", func(): return _lib.remove("trader_pools", "rtv46_h1"), true, {"h1": null}],
		["h2 revert", func(): return _lib.revert("trader_pools", "rtv46_h2"), true, {"doctor": false, "h2": null}],
		["h3 flag already set", func(): return _lib.register("trader_pools", "rtv46_h3", {"item": item, "trader": "Hunter"}), true,
				{"h3": rec.call("Hunter", "hunter", true)}],
		["h3 remove", func(): return _lib.remove("trader_pools", "rtv46_h3"), true, {"h3": null}],
		["h3 remove again", func(): return _lib.remove("trader_pools", "rtv46_h3"), false, {}],
	])

func _p46_trader_tasks() -> void:
	var z1 := "rtv46_task"
	var z2 := "rtv46_task_ov"
	var trader := _stub("tasks")
	_ml._registry_resource_cache[TRADER_PATH] = trader
	var list: Array = trader.get("tasks")
	var van := _stub("task", {"name": "Vanilla46"})
	list.append(van)
	var mine := _stub("task")
	var other := _stub("task")
	var x := _stub("item", {"file": "rtv46_tx"})
	var y := _stub("item", {"file": "rtv46_ty"})
	var rec := func(t: Resource) -> Dictionary: return {"task": t, "trader": "Generalist"}
	var snap := func() -> Dictionary:
		return {"list": list.duplicate(), "z1": _lib.get_entry("trader_tasks", z1), "z2": _lib.get_entry("trader_tasks", z2),
				"mine": [mine.get("name"), mine.get("deliver").duplicate()], "van": van.get("name")}
	_parity("trader_tasks", snap, [
		["z1 register", func(): return _lib.register("trader_tasks", z1, rec.call(mine)), true,
				{"list": [van, mine], "z1": rec.call(mine)}],
		["z1 patch", func(): return _lib.patch("trader_tasks", z1, {"name": "P"}), true, {"mine": ["P", []]}],
		["z1 append", func(): return _lib.append("trader_tasks", z1, "deliver", [x, y]), true, {"mine": ["P", [x, y]]}],
		["z1 prepend present", func(): return _lib.prepend("trader_tasks", z1, "deliver", y), true, {}],
		["z1 remove_from", func(): return _lib.remove_from("trader_tasks", z1, "deliver", x), true, {"mine": ["P", [y]]}],
		["z2 override", func(): return _lib.override("trader_tasks", z2, {"task": other, "trader": "Generalist", "replaces": van}),
				true, {"list": [other, mine], "z2": rec.call(other)}],
		["ref patch", func(): return _lib.patch("trader_tasks", van, {"name": "V2"}), true, {"van": "V2"}],
		["z2 revert", func(): return _lib.revert("trader_tasks", z2), true, {"list": [van, mine], "z2": null}],
		["z1 revert deliver", func(): return _lib.revert("trader_tasks", z1, ["deliver"]), true, {"mine": ["P", []]}],
		["z1 revert all", func(): return _lib.revert("trader_tasks", z1), true, {"mine": ["", []]}],
		["ref revert all", func(): return _lib.revert("trader_tasks", van), true, {"van": "Vanilla46"}],
		["z1 remove", func(): return _lib.remove("trader_tasks", z1), true, {"list": [van], "z1": null}],
		["z1 remove again", func(): return _lib.remove("trader_tasks", z1), false, {}],
	])
	_ml._registry_resource_cache.erase(TRADER_PATH)

func _codes(action: String) -> Array:
	if not InputMap.has_action(action):
		return []
	return InputMap.action_get_events(action).map(func(ev): return (ev as InputEventKey).keycode)

## Deadzones in hundredths, so float32 storage compares exactly; -1 when absent.
func _deadzone(action: String) -> int:
	return roundi(InputMap.action_get_deadzone(action) * 100) if InputMap.has_action(action) else -1

func _input_entry(action: String) -> Variant:
	var entry = _lib.get_entry("inputs", action)
	if entry == null:
		return null
	var out: Dictionary = entry.duplicate()
	out["deadzone"] = roundi(float(entry["deadzone"]) * 100)
	return out

func _p46_inputs() -> void:
	var z1 := "rtv46_own_action"
	var z2 := "rtv46_vanilla_action"
	_drop_action(z1)
	_vanilla_action(z2)
	var ev := {}
	for code in [KEY_A, KEY_B, KEY_C, KEY_D]:
		ev[code] = _key_event(code)
	var rec := func(label: String, code: Key, dz: int) -> Dictionary:
		return {"display_label": label, "default_event": ev[code], "deadzone": dz}
	var snap := func() -> Dictionary:
		return {"ev1": _codes(z1), "dz1": _deadzone(z1), "e1": _input_entry(z1),
				"ev2": _codes(z2), "dz2": _deadzone(z2), "e2": _input_entry(z2)}
	var stub := {"display_label": z2, "default_event": ev[KEY_C], "deadzone": 90, "vanilla_stub": true}
	_parity("inputs", snap, [
		["z1 register", func(): return _lib.register("inputs", z1, {"display_label": "Mine", "default_event": ev[KEY_A], "deadzone": 0.3}),
				true, {"ev1": [KEY_A], "dz1": 30, "e1": rec.call("Mine", KEY_A, 30)}],
		["z2 register refused", func(): return _lib.register("inputs", z2, {"default_event": ev[KEY_A]}), false, {}],
		["z1 patch", func(): return _lib.patch("inputs", z1, {"display_label": "P", "deadzone": 0.4}), true,
				{"dz1": 40, "e1": rec.call("P", KEY_A, 40)}],
		# DELTA (2026-10-29, inputs vanilla_stub leak): 3.4.2 left a stub entry here.
		["z2 unknown field patch", func(): return _lib.patch("inputs", z2, {"nope": 1}), false, {}],
		["z2 patch", func(): return _lib.patch("inputs", z2, {"deadzone": 0.9, "default_event": ev[KEY_C]}), true,
				{"ev2": [KEY_C], "dz2": 90, "e2": stub}],
		["z1 append refused", func(): return _lib.append("inputs", z1, "x", 1), false, {}],
		["z1 override", func(): return _lib.override("inputs", z1, {"display_label": "T", "default_event": ev[KEY_B], "deadzone": 0.6}),
				true, {"ev1": [KEY_B], "dz1": 60, "e1": rec.call("T", KEY_B, 60)}],
		["z2 override", func(): return _lib.override("inputs", z2, {"display_label": "O", "default_event": ev[KEY_D], "deadzone": 0.7}),
				true, {"ev2": [KEY_D], "dz2": 70, "e2": rec.call("O", KEY_D, 70)}],
		["z1 remove refused", func(): return _lib.remove("inputs", z1), false, {}],
		["z2 revert deadzone", func(): return _lib.revert("inputs", z2, ["deadzone"]), true, {"dz2": 20, "e2": rec.call("O", KEY_D, 20)}],
		# 3.4.2 too: the override's snapshot holds the patched events and deadzone,
		# so a patch made before an override outlives the full revert.
		["z2 revert all", func(): return _lib.revert("inputs", z2), true, {"ev2": [KEY_C], "dz2": 90, "e2": null}],
		["z1 revert label", func(): return _lib.revert("inputs", z1, ["display_label"]), true, {"e1": rec.call("Mine", KEY_B, 60)}],
		["z1 revert all", func(): return _lib.revert("inputs", z1), true, {"ev1": [KEY_A], "dz1": 40, "e1": rec.call("P", KEY_A, 40)}],
		["z1 revert again", func(): return _lib.revert("inputs", z1), false, {}],
		["z1 remove", func(): return _lib.remove("inputs", z1), true, {"ev1": [], "dz1": -1, "e1": null}],
		["z2 remove refused", func(): return _lib.remove("inputs", z2), false, {}],
	], false)
	_drop_action(z2)

func _p46_scene_paths() -> void:
	var z1 := "rtv46_path"
	var z2 := "Cabin"
	var p := FIXTURE_PATH
	var q := BUNDLE_DIR + "/rtv_scene.tscn"
	var snap := func() -> Dictionary:
		return {"mod": (_fake_loader.get("_rtv_mod_scene_paths") as Dictionary).duplicate(true),
				"ov": (_fake_loader.get("_rtv_override_scene_paths") as Dictionary).duplicate(true),
				"z1": _lib.get_entry("scene_paths", z1), "z2": _lib.get_entry("scene_paths", z2)}
	_parity("scene_paths", snap, [
		["z1 register", func(): return _lib.register("scene_paths", z1, {"path": p}), true,
				{"mod": {z1: {"path": p}}, "z1": {"path": p}}],
		["z2 register refused", func(): return _lib.register("scene_paths", z2, {"path": p}), false, {}],
		["z1 patch", func(): return _lib.patch("scene_paths", z1, {"shelter": true}), true,
				{"mod": {z1: {"path": p, "shelter": true}}, "z1": {"path": p, "shelter": true}}],
		["z1 missing file patch", func(): return _lib.patch("scene_paths", z1, {"path": "res://nope46.tscn"}), false, {}],
		["z1 override", func(): return _lib.override("scene_paths", z1, {"path": q, "menu": true}), true,
				{"ov": {z1: {"path": q, "menu": true}}, "z1": {"path": q, "menu": true}}],
		["z1 patch the override", func(): return _lib.patch("scene_paths", z1, {"menu": false, "tutorial": true}), true,
				{"ov": {z1: {"path": q, "menu": false, "tutorial": true}}, "z1": {"path": q, "menu": false, "tutorial": true}}],
		["z2 override", func(): return _lib.override("scene_paths", z2, {"path": p, "menu": true}), true,
				{"ov": {z1: {"path": q, "menu": false, "tutorial": true}, z2: {"path": p, "menu": true}}, "z2": {"path": p, "menu": true}}],
		["z2 patch", func(): return _lib.patch("scene_paths", z2, {"permadeath": true}), true,
				{"ov": {z1: {"path": q, "menu": false, "tutorial": true}, z2: {"path": p, "menu": true, "permadeath": true}},
				"z2": {"path": p, "menu": true, "permadeath": true}}],
		["z1 revert shelter", func(): return _lib.revert("scene_paths", z1, ["shelter"]), true, {"mod": {z1: {"path": p}}}],
		["z1 revert all", func(): return _lib.revert("scene_paths", z1), true,
				{"ov": {z2: {"path": p, "menu": true, "permadeath": true}}, "z1": {"path": p}}],
		["z2 revert all", func(): return _lib.revert("scene_paths", z2), true, {"ov": {}, "z2": null}],
		["z2 revert again", func(): return _lib.revert("scene_paths", z2), false, {}],
		["z1 remove", func(): return _lib.remove("scene_paths", z1), true, {"mod": {}, "z1": null}],
		["z2 remove refused", func(): return _lib.remove("scene_paths", z2), false, {}],
	])

func _p46_shelters_maps() -> void:
	var s1 := "rtv46_shelter"
	var m1 := "rtv46_map"
	var snap := func() -> Dictionary:
		return {"list": (_fake_loader.get("shelters") as Array).duplicate(),
				"mod": (_fake_loader.get("_rtv_mod_shelters") as Dictionary).duplicate(true),
				"path": (_fake_loader.get("_rtv_mod_scene_paths") as Dictionary).get(s1),
				"s1": _lib.get_entry("shelters", s1), "m1": _lib.get_entry("maps", m1), "m1_as_shelter": _lib.get_entry("shelters", m1),
				"ks": _plain(_lib.keys("shelters", false)), "km": _plain(_lib.keys("maps", false))}
	var es := {"shelter": true, "transition_text": s1, "exit_spawn": "", "entrance_spawn": "", "connected_to": "Attic",
			"connected_content": []}
	var em := {"shelter": false, "transition_text": "5", "exit_spawn": "", "entrance_spawn": "", "connected_to": "",
			"connected_content": []}
	_parity("shelters", snap, [
		["s1 register", func(): return _lib.register("shelters", s1, {"path": FIXTURE_PATH, "connected_to": "Attic"}), true,
				{"list": ["Attic", s1], "mod": {s1: es}, "path": {"path": FIXTURE_PATH, "shelter": true, "transition_text": s1},
				"s1": {"auto_scene_path": true, "entry": es, "kind": "shelters"}, "ks": [s1]}],
		["vanilla name refused", func(): return _lib.register("shelters", "Attic", {}), false, {}],
		["missing scene refused", func(): return _lib.register("shelters", "rtv46_bad", {"path": "res://nope46.tscn"}), false, {}],
		["m1 register map", func(): return _lib.register("maps", m1, {"transition_text": 5, "exit_spawn": null}), true,
				{"list": ["Attic", s1, m1], "mod": {s1: es, m1: em}, "m1": {"auto_scene_path": false, "entry": em, "kind": "maps"},
				"km": [m1]}],
		["map id as shelter", func(): return _lib.register("maps", s1, {}), false, {}],
		["cross kind remove", func(): return _lib.remove("maps", s1), false, {}],
		["s1 override refused", func(): return _lib.override("shelters", s1, {}), false, {}],
		["s1 patch refused", func(): return _lib.patch("shelters", s1, {"a": 1}), false, {}],
		["s1 revert", func(): return _lib.revert("shelters", s1), true,
				{"list": ["Attic", m1], "mod": {m1: em}, "path": null, "s1": null, "ks": []}],
		["m1 revert", func(): return _lib.revert("maps", m1), true, "vanilla"],
		["s1 remove again", func(): return _lib.remove("shelters", s1), false, {}],
	])

func _p46_random_scenes() -> void:
	var z1 := "rtv46_random"
	var q := BUNDLE_DIR + "/rtv_scene.tscn"
	var list: Array = _fake_loader.get("randomScenes")
	list.append(q)
	var snap := func() -> Dictionary:
		return {"list": list.duplicate(), "z1": _lib.get_entry("random_scenes", z1)}
	_parity("random_scenes", snap, [
		["z1 register", func(): return _lib.register("random_scenes", z1, {"path": FIXTURE_PATH}), true,
				{"list": [q, FIXTURE_PATH], "z1": {"path": FIXTURE_PATH}}],
		["vanilla path refused", func(): return _lib.register("random_scenes", "rtv46_random2", {"path": q}), false, {}],
		["z1 register again", func(): return _lib.register("random_scenes", z1, {"path": FIXTURE_PATH}), false, {}],
		["z1 patch refused", func(): return _lib.patch("random_scenes", z1, {"path": q}), false, {}],
		["z1 revert", func(): return _lib.revert("random_scenes", z1), true, "vanilla"],
		["z1 remove again", func(): return _lib.remove("random_scenes", z1), false, {}],
		["z1 register anew", func(): return _lib.register("random_scenes", z1, {"path": FIXTURE_PATH}), true,
				{"list": [q, FIXTURE_PATH], "z1": {"path": FIXTURE_PATH}}],
		["z1 remove", func(): return _lib.remove("random_scenes", z1), true, "vanilla"],
	])
	list.erase(q)

func _p46_ai_types() -> void:
	var a := PackedScene.new()
	var b := PackedScene.new()
	var c := PackedScene.new()
	var d := PackedScene.new()
	var snap := func() -> Dictionary:
		return {"e1": _lib.get_entry("ai_types", "rtv46_ai1"), "e2": _lib.get_entry("ai_types", "rtv46_ai2"),
				"e3": _lib.get_entry("ai_types", "rtv46_ai3"), "meta": (Engine.get_meta("_rtv_ai_overrides", {}) as Dictionary).duplicate()}
	_parity("ai_types", snap, [
		["z1 register", func(): return _lib.register("ai_types", "rtv46_ai1", {"scene": a, "zone": "Area05"}), true,
				{"e1": {"scene": a, "zone": "Area05"}, "meta": {"Area05": a}}],
		["z2 register", func(): return _lib.register("ai_types", "rtv46_ai2", {"scene": b, "zone": "Vostok"}), true,
				{"e2": {"scene": b, "zone": "Vostok"}, "meta": {"Area05": a, "Vostok": b}}],
		["claimed zone refused", func(): return _lib.register("ai_types", "rtv46_ai3", {"scene": c, "zone": "Area05"}), false, {}],
		["z3 override displaces", func(): return _lib.override("ai_types", "rtv46_ai3", {"scene": c, "zone": "Area05"}), true,
				{"e1": null, "e3": {"scene": c, "zone": "Area05"}, "meta": {"Area05": c, "Vostok": b}}],
		["z2 override moves zone", func(): return _lib.override("ai_types", "rtv46_ai2", {"scene": d, "zone": "BorderZone"}), true,
				{"e2": {"scene": d, "zone": "BorderZone"}, "meta": {"Area05": c, "BorderZone": d}}],
		["z3 remove refused", func(): return _lib.remove("ai_types", "rtv46_ai3"), false, {}],
		["z3 patch refused", func(): return _lib.patch("ai_types", "rtv46_ai3", {"zone": "Vostok"}), false, {}],
		# DELTA (2026-10-28 ledger, "an ai_types revert dropped a displaced same-id
		# entry"): 3.4.2 erased rtv46_ai2 here, leaving e2 null and no Vostok.
		["z2 revert", func(): return _lib.revert("ai_types", "rtv46_ai2"), true,
				{"e2": {"scene": b, "zone": "Vostok"}, "meta": {"Area05": c, "Vostok": b}}],
		["z3 revert", func(): return _lib.revert("ai_types", "rtv46_ai3"), true,
				{"e1": {"scene": a, "zone": "Area05"}, "e3": null, "meta": {"Area05": a, "Vostok": b}}],
		["z3 revert again", func(): return _lib.revert("ai_types", "rtv46_ai3"), false, {}],
		["z1 remove", func(): return _lib.remove("ai_types", "rtv46_ai1"), true, {"e1": null, "meta": {"Vostok": b}}],
		["z2 remove", func(): return _lib.remove("ai_types", "rtv46_ai2"), true, "vanilla"],
	])

func _p46_fish_species() -> void:
	var a := PackedScene.new()
	var b := PackedScene.new()
	var snap := func() -> Dictionary:
		return {"e1": _lib.get_entry("fish_species", "rtv46_fish1"), "e2": _lib.get_entry("fish_species", "rtv46_fish2"),
				"meta": (Engine.get_meta("_rtv_fish_species", []) as Array).duplicate()}
	_parity("fish_species", snap, [
		["z1 register", func(): return _lib.register("fish_species", "rtv46_fish1", {"scene": a}), true,
				{"e1": {"scene": a, "pool_id": "all"}, "meta": [{"scene": a, "pool_id": "all"}]}],
		["z2 register", func(): return _lib.register("fish_species", "rtv46_fish2", {"scene": b, "pool_id": "FP_2"}), true,
				{"e2": {"scene": b, "pool_id": "FP_2"}, "meta": [{"scene": a, "pool_id": "all"}, {"scene": b, "pool_id": "FP_2"}]}],
		["bad pool refused", func(): return _lib.register("fish_species", "rtv46_fish3", {"scene": b, "pool_id": 5}), false, {}],
		["z1 override refused", func(): return _lib.override("fish_species", "rtv46_fish1", {"scene": b}), false, {}],
		["z1 revert", func(): return _lib.revert("fish_species", "rtv46_fish1"), true,
				{"e1": null, "meta": [{"scene": b, "pool_id": "FP_2"}]}],
		["z2 remove", func(): return _lib.remove("fish_species", "rtv46_fish2"), true, "vanilla"],
		["z2 remove again", func(): return _lib.remove("fish_species", "rtv46_fish2"), false, {}],
	])

func _p46_resources() -> void:
	var script_path := BUNDLE_DIR + "/rtv46_res.gd"
	H.write_text(script_path, "extends Resource\n@export var weight := 1.0\n@export var tags: Array = []\n")
	var paths: Array[String] = [BUNDLE_DIR + "/rtv46_res_a.tres", BUNDLE_DIR + "/rtv46_res_b.tres"]
	for path in paths:
		ResourceSaver.save((load(script_path) as GDScript).new(), path)
	var ra: Resource = load(paths[0])
	var rb: Resource = load(paths[1])
	var za := paths[0]
	var zb := paths[1]
	var snap := func() -> Dictionary:
		return {"a": [ra.get("weight"), ra.get("tags").duplicate()], "b": [rb.get("weight"), rb.get("tags").duplicate()],
				"entry": _lib.get_entry("resources", za) == ra}
	_parity("resources", snap, [
		["a patch", func(): return _lib.patch("resources", za, {"weight": 5.0}), true, {"a": [5.0, []]}],
		["a unknown field patch", func(): return _lib.patch("resources", za, {"nope": 1}), false, {}],
		["a append", func(): return _lib.append("resources", za, "tags", ["x", "y"]), true, {"a": [5.0, ["x", "y"]]}],
		["a remove_from", func(): return _lib.remove_from("resources", za, "tags", "x"), true, {"a": [5.0, ["y"]]}],
		["b prepend", func(): return _lib.prepend("resources", zb, "tags", "z"), true, {"b": [1.0, ["z"]]}],
		["b partly known patch", func(): return _lib.patch("resources", zb, {"weight": 2.0, "nope": 1}), true, {"b": [2.0, ["z"]]}],
		["a revert weight", func(): return _lib.revert("resources", za, ["weight"]), true, {"a": [1.0, ["y"]]}],
		["a revert weight again", func(): return _lib.revert("resources", za, ["weight"]), false, {}],
		["a revert all", func(): return _lib.revert("resources", za), true, {"a": [1.0, []]}],
		["b revert all", func(): return _lib.revert("resources", zb), true, "vanilla"],
		["b revert again", func(): return _lib.revert("resources", zb), false, {}],
		["a register refused", func(): return _lib.register("resources", za, ra), false, {}],
		["a remove refused", func(): return _lib.remove("resources", za), false, {}],
	])

func _p46_scene_nodes() -> void:
	var path := BUNDLE_DIR + "/rtv46_nodes.tscn"
	var scene_root := Node.new()
	scene_root.name = "Fixture46"
	var kid := Node.new()
	kid.name = "Kid"
	scene_root.add_child(kid)
	kid.owner = scene_root
	var packed := PackedScene.new()
	packed.pack(scene_root)
	scene_root.free()
	if not check_eq(ResourceSaver.save(packed, path), OK, "scene_nodes fixture saves"):
		return
	var live: Node = (load(path) as PackedScene).instantiate()
	var late: Node = (load(path) as PackedScene).instantiate()
	root.add_child(live)
	var z1 := path + "#."
	var z2 := path + "#Kid"
	var props := func(n: Node) -> Array:
		var k: Node = n.get_node("Kid")
		return [n.process_priority, k.process_priority, k.editor_description]
	var snap := func() -> Dictionary: return {"live": props.call(live), "late": props.call(late)}
	_parity("scene_nodes", snap, [
		["z1 patch", func(): return _lib.patch("scene_nodes", z1, {"process_priority": 7}), true, {"live": [7, 0, ""]}],
		["z2 patch", func(): return _lib.patch("scene_nodes", z2, {"process_priority": 3, "editor_description": "k"}), true,
				{"live": [7, 3, "k"]}],
		["z2 unknown field patch", func(): return _lib.patch("scene_nodes", z2, {"nope": 1}), false, {}],
		["late instance enters", func(): root.add_child(late), null, {"late": [7, 3, "k"]}],
		["z1 revert unpatched field", func(): return _lib.revert("scene_nodes", z1, ["process_physics_priority"]), false, {}],
		["z2 revert description", func(): return _lib.revert("scene_nodes", z2, ["editor_description"]), true,
				{"live": [7, 3, ""], "late": [7, 3, ""]}],
		["z2 revert all", func(): return _lib.revert("scene_nodes", z2), true, {"live": [7, 0, ""], "late": [7, 0, ""]}],
		["z1 revert all", func(): return _lib.revert("scene_nodes", z1), true, "vanilla"],
		["z1 revert again", func(): return _lib.revert("scene_nodes", z1), false, {}],
		["z1 remove refused", func(): return _lib.remove("scene_nodes", z1), false, {}],
		["z1 register refused", func(): return _lib.register("scene_nodes", z1, {}), false, {}],
	])
	live.queue_free()
	late.queue_free()

func _p46_aggregators() -> void:
	var scene := BUNDLE_DIR + "/rtv_scene.tscn"
	var w_item: Resource = load(_bundle_item("rtv46_w", "Weapon"))
	var m_item: Resource = load(_bundle_item("rtv46_m", "Magazine"))
	var a_item: Resource = load(_bundle_item("rtv46_a", "Attachment"))
	var snap := func() -> Dictionary:
		var out := {"compat": w_item.get("compatible").duplicate()}
		for id in ["rtv46_w", "rtv46_m", "rtv46_a"]:
			out[id] = _lib.get_entry("items", id)
		for id in ["rtv46_w", "rtv46_w_Rig", "rtv46_m", "rtv46_a"]:
			out["scene " + id] = _lib.get_entry("scenes", id) != null
		return out
	var rows: Array = [
		["weapon register", func(): return _lib.register("weapons", "rtv46_w", {"item_path": w_item.resource_path,
				"scene_path": scene, "rig_path": scene}), true, {"rtv46_w": w_item, "scene rtv46_w": true, "scene rtv46_w_Rig": true}],
		["weapon register again", func(): return _lib.register("weapons", "rtv46_w", {"item_path": w_item.resource_path,
				"scene_path": scene, "rig_path": scene}), false, {}],
		["magazine register", func(): return _lib.register("magazines", "rtv46_m", {"item_path": m_item.resource_path,
				"scene_path": scene, "fits_weapons": ["rtv46_w"]}), true, {"rtv46_m": m_item, "scene rtv46_m": true, "compat": [m_item]}],
		["attachment unknown fit", func(): return _lib.register("attachments", "rtv46_a", {"item_path": a_item.resource_path,
				"scene_path": scene, "fits_weapons": ["rtv46_nope"]}), false, {"rtv46_a": a_item, "scene rtv46_a": true}],
	]
	for verb in ["override", "patch", "remove", "revert"]:
		var args: Array = ["weapons", "rtv46_w"] + ([] if verb in ["remove", "revert"] else [{}])
		rows.append(["weapon %s refused" % verb, func(): return _lib.callv(verb, args), false, {}])
	rows.append(["items revert compatible", func(): return _lib.revert("items", "rtv46_w"), true, {"compat": []}])
	for id in ["rtv46_w", "rtv46_m", "rtv46_a"]:
		rows.append(["items remove " + id, func(): return _lib.remove("items", id), true, {id: null}])
	for id in ["rtv46_w", "rtv46_w_Rig", "rtv46_m", "rtv46_a"]:
		rows.append(["scenes remove " + id, func(): return _lib.remove("scenes", id), true, {"scene " + id: false}])
	_parity("aggregators", snap, rows)

func _p46_ai_loadouts() -> void:
	var a := PackedScene.new()
	var b := PackedScene.new()
	var van: PackedScene = _fake_db.get("_rtv_vanilla_scenes")["RTV46Vanilla"]
	var e1 := {"weapon_scene": a, "ai_types": ["Bandit"], "chance": 0.5, "replace": false}
	var e2 := {"weapon_scene": van, "ai_types": ["Guard"], "chance": 1.0, "replace": true}
	var e1o := {"weapon_scene": b, "ai_types": ["Nomad", "Boss"], "chance": 1.0, "replace": false}
	var plain := func(entry) -> Variant:
		if entry == null:
			return null
		var out: Dictionary = entry.duplicate()
		out["ai_types"] = _plain(entry["ai_types"])
		return out
	var snap := func() -> Dictionary:
		return {"e1": plain.call(_lib.get_entry("ai_loadouts", "rtv46_l1")), "e2": plain.call(_lib.get_entry("ai_loadouts", "rtv46_l2")),
				"meta": (Engine.get_meta("_rtv_ai_loadouts", []) as Array).map(plain)}
	_parity("ai_loadouts", snap, [
		["z1 register", func(): return _lib.register("ai_loadouts", "rtv46_l1", {"weapon_scene": a, "ai_types": [" bandit"], "chance": 0.5}),
				true, {"e1": e1, "meta": [e1]}],
		["z2 register by name", func(): return _lib.register("ai_loadouts", "rtv46_l2", {"weapon_scene": "RTV46Vanilla",
				"ai_types": ["Guard", "guard"], "chance": "2", "replace": 1}), true, {"e2": e2, "meta": [e1, e2]}],
		["unknown type refused", func(): return _lib.register("ai_loadouts", "rtv46_l3", {"weapon_scene": a, "ai_types": ["Cat"]}),
				false, {}],
		["z1 override", func(): return _lib.override("ai_loadouts", "rtv46_l1", {"weapon_scene": b, "ai_types": ["nomad", "BOSS"]}),
				true, {"e1": e1o, "meta": [e1o, e2]}],
		["z1 override again", func(): return _lib.override("ai_loadouts", "rtv46_l1", {"weapon_scene": a, "ai_types": ["Bandit"]}),
				false, {}],
		["unregistered override refused", func(): return _lib.override("ai_loadouts", "rtv46_l3", {"weapon_scene": a, "ai_types": ["Bandit"]}),
				false, {}],
		["z1 remove refused", func(): return _lib.remove("ai_loadouts", "rtv46_l1"), false, {}],
		["z1 patch refused", func(): return _lib.patch("ai_loadouts", "rtv46_l1", {"chance": 0.1}), false, {}],
		["z1 revert", func(): return _lib.revert("ai_loadouts", "rtv46_l1"), true, {"e1": e1, "meta": [e1, e2]}],
		["z1 revert again", func(): return _lib.revert("ai_loadouts", "rtv46_l1"), false, {}],
		["z1 remove", func(): return _lib.remove("ai_loadouts", "rtv46_l1"), true, {"e1": null, "meta": [e2]}],
		["z2 remove", func(): return _lib.remove("ai_loadouts", "rtv46_l2"), true, "vanilla"],
	])
