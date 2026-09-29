## dispatch_runner.gd -- RUNTIME dispatch harness. NOT part of the shipped
## loader. Executed by check_dispatch.sh inside a THROWAWAY Godot project
## assembled under the system temp dir; never run it against this repo or
## against the Road to Vostok install.
##
## What it proves that check_codegen.sh cannot: the generated hook wrappers
## BEHAVE. A wrapper can compile perfectly and still dispatch the wrong
## callback, in the wrong order, with the wrong arguments, or fail to
## suppress vanilla. This harness:
##   1. loads the NEUTERED modloader copy (static-init boot line replaced
##      by {} -- same recipe as check_codegen.sh, asserted on prep),
##   2. registers it through the REAL registration path
##      (_register_rtv_modlib_meta -> Engine.meta "RTVModLib"),
##   3. runs the REAL rewriter (_rtv_parse_script +
##      _rtv_rewrite_vanilla_source, empty mask) over FixtureDispatch.gd,
##   4. compiles the rewritten output and attaches it to real Nodes in the
##      tree,
##   5. registers hooks through the REAL public API
##      (Engine.get_meta("RTVModLib").hook(...)),
##   6. CALLS the wrapped methods and asserts on the recorded execution
##      log (fixture bodies append to the Array at Engine meta
##      "RTVDispatchLog").
##
## Contract under test is docs/wiki/Hooks.md (the "Hook names" table,
## "Replace hooks", "Post hooks and result mutation", "Priorities and
## dispatch order") plus src/hooks_api.gd. Test ids:
##   T1  -pre fires before vanilla, with the vanilla arguments
##   T2  replace: runs before vanilla; without skip_super() vanilla runs
##       and vanilla's return wins; with skip_super() vanilla is suppressed
##       and the callback's return is the result (value + void templates)
##   T3  -post (non-void): trailing _result arg; non-null replaces the
##       result, null passes through; legacy 2-arg form observes only;
##       multiple post hooks chain in ascending priority
##   T4  -callback is deferred until after the method returned
##   T5  full ordering: pre -> replace-or-vanilla -> post -> deferred, and
##       ascending priority within the pre stage
##   T6  replace slot is single-owner: second registration returns -1 and
##       the first owner still runs
##   T7  unhook(id) stops that callback, leaves others intact
##   T8  _lib._caller is the dispatching node and is restored around
##       NESTED wrapped calls (wrapped method calling a wrapped method on
##       another node), including for the outer method's post stage
##   T9  re-entrancy: a hook callback calling the SAME wrapped method on
##       the SAME instance does not recurse into dispatch, and the hook
##       STILL fires on the next call (a leaked guard key would silently
##       disable it -- the exact regression --prove reintroduces)
##   T10 two instances of one wrapped script dispatch independently, even
##       when one instance's hook calls into the other instance
##   T11 a coroutine vanilla method still awaits and returns its value,
##       with pre/post dispatch intact
##   T12 defaulted parameters flow through when omitted at the call site
##   T13 registry inputs: an override's deadzone reaches InputMap, and revert
##       restores the deadzone the action had
##   T14 registry inputs: revert brings back every event of a patched
##       action, and a reverted override leaves nothing for remove() to take
##   T15 registry scenes: remove() refuses an id that carries an override
##   T16 registry items and scene_paths: a patch made before an override is
##       reverted onto the object it changed
##   T17 registry scene_paths: get_entry returns an override, and a patch
##       cannot point a scene at a file that does not exist
##   T18 setup(): a when-predicate returning null or a String reads as false
##       and the rest of the plan still runs
##   T19 has_mod(id, min_version) reads a v-prefixed version
##   T20 a hook whose owner was freed is dropped at dispatch, and a replace
##       slot it held can be taken
##   T21 hook_many, patch_many and find() report a bad value and carry on
##   T22 registry scene_nodes: a per-field revert reports whether it reverted
##       anything
##   T23 coroutine detection ignores `await` inside strings and comments
extends SceneTree

const FIXTURE_PATH := "res://Scripts/FixtureDispatch.gd"
const WRAPPER_MARKER := "# --- Metro mod loader inline hook dispatch wrappers ---"
## Frames before the watchdog declares a hang (a lost await / never-resumed
## coroutine). Headless frames are ~instant; a clean run needs well under 20.
const MAX_FRAMES := 2000

var _started := false
var _done := false
var _frames := 0
var _failures: PackedStringArray = []
var _checks := 0
var _log: Array = []
var _ml = null          # neutered modloader instance
var _lib = null         # Engine.get_meta("RTVModLib") -- same object, via the real lookup
var _node_a: Node = null
var _node_b: Node = null
var _fake_db: Node = null      # stand-in Database autoload, see _registry_tree
var _fake_loader: Node = null  # stand-in Loader autoload
var _t0 := 0

func _process(_delta: float) -> bool:
	_frames += 1
	if not _started:
		_started = true
		_t0 = Time.get_ticks_msec()
		_run()
	elif not _done and _frames > MAX_FRAMES:
		printerr("[dispatch] FAIL watchdog: harness did not finish within %d frames -- a coroutine never resumed" % MAX_FRAMES)
		quit(1)
		return true
	return false

func _run() -> void:
	print("[dispatch] harness start")
	if _setup():
		await _run_tests()
	_teardown()
	_finish()

func _finish() -> void:
	_done = true
	var ms := Time.get_ticks_msec() - _t0
	if _failures.is_empty():
		print("[dispatch] PASS: %d assertion(s) across T1..T23, %d frame(s), %d ms in-engine" % [_checks, _frames, ms])
		quit(0)
	else:
		printerr("[dispatch] FAILED: %d of %d assertion(s) (%d ms in-engine); first: %s" % [_failures.size(), _checks, ms, _failures[0]])
		quit(1)

# --- assertion helpers -------------------------------------------------------

func _fail(id: String, msg: String) -> void:
	_failures.append(id + ": " + msg)
	printerr("[dispatch] FAIL " + id + ": " + msg)

func _expect(cond: bool, id: String, msg: String) -> bool:
	_checks += 1
	if not cond:
		_fail(id, msg)
	return cond

func _expect_eq(got, want, id: String, what: String) -> bool:
	_checks += 1
	if not is_same(typeof(got), typeof(want)) or got != want:
		_fail(id, "%s: got %s, want %s" % [what, str(got), str(want)])
		return false
	return true

## Compare the execution log captured since the last clear against an exact
## expected sequence. Exactness is the point: extra, missing or reordered
## entries are all dispatch bugs.
func _expect_log(id: String, expected: Array) -> bool:
	_checks += 1
	if _log != expected:
		_fail(id, "execution order mismatch:\n    got:  %s\n    want: %s" % [str(_log), str(expected)])
		return false
	return true

func _wait_frames(n: int) -> void:
	for i in n:
		await process_frame

func _unhook_all(ids: Array) -> void:
	for id in ids:
		if int(id) != -1:
			_lib.unhook(int(id))
	_log.clear()

# --- setup -------------------------------------------------------------------

func _setup() -> bool:
	var ml_script: GDScript = load("res://modloader_neutered.gd")
	if ml_script == null:
		_fail("setup", "could not load res://modloader_neutered.gd -- check_dispatch.sh prep failed")
		return false
	_ml = ml_script.new()
	# Belt and braces (same as codegen runner): the static-init boot line was
	# replaced by {}. If boot code ran anyway, refuse to continue.
	var mounted = _ml.get("_filescope_mounted")
	if not (mounted is Dictionary) or not (mounted as Dictionary).is_empty():
		_fail("setup", "_filescope_mounted is not an empty Dictionary -- static-init boot code RAN; the neutering failed")
		return false

	# Real registration path, then the real lookup mods use.
	_ml._register_rtv_modlib_meta()
	_lib = Engine.get_meta("RTVModLib")
	if not _expect(_lib == _ml, "setup", "Engine.get_meta('RTVModLib') is not the registered loader instance"):
		return false

	# The fixture bodies record into this shared Array.
	Engine.set_meta("RTVDispatchLog", _log)

	# Run the REAL rewriter over the pristine fixture, wrap-all mask.
	var f := FileAccess.open(FIXTURE_PATH, FileAccess.READ)
	if f == null:
		_fail("setup", "fixture missing at " + FIXTURE_PATH)
		return false
	var raw := f.get_as_text()
	f.close()
	var parsed: Dictionary = _ml._rtv_parse_script("FixtureDispatch.gd", raw)
	var coro_seen := false
	for fe in parsed["functions"]:
		if fe["name"] == "CoroValue" and bool(fe["is_coroutine"]):
			coro_seen = true
	if not _expect(coro_seen, "setup", "parser did not mark CoroValue a coroutine -- fixture or parser drifted"):
		return false
	var rewritten: String = _ml._rtv_rewrite_vanilla_source(raw, parsed, {})
	if not _expect(WRAPPER_MARKER in rewritten, "setup", "rewritten fixture lacks the wrapper marker"):
		return false
	if not _expect("\"fixturedispatch-add\"" in rewritten, "setup", "wrapper hook_base 'fixturedispatch-add' not emitted -- prefix derivation drifted"):
		return false

	var wf := FileAccess.open(FIXTURE_PATH, FileAccess.WRITE)
	wf.store_string(rewritten)
	wf.close()
	var scr = ResourceLoader.load(FIXTURE_PATH, "", ResourceLoader.CACHE_MODE_IGNORE)
	if scr == null or not (scr as Script).can_instantiate():
		_fail("setup", "REWRITTEN fixture does not compile (see SCRIPT ERROR lines above)")
		return false

	_node_a = (scr as GDScript).new()
	_node_a.name = "A"
	_node_b = (scr as GDScript).new()
	_node_b.name = "B"
	root.add_child(_node_a)
	root.add_child(_node_b)
	return true

func _teardown() -> void:
	if _node_a != null:
		_node_a.queue_free()
	if _node_b != null:
		_node_b.queue_free()
	for stand_in in [_fake_db, _fake_loader]:
		if stand_in != null:
			stand_in.queue_free()
	if _ml != null:
		if Engine.has_meta("RTVModLib"):
			Engine.remove_meta("RTVModLib")
		_ml.free()

# --- tests -------------------------------------------------------------------

func _run_tests() -> void:
	_t1_pre()
	_t2_replace()
	_t3_post()
	await _t4_deferred()
	await _t5_ordering()
	_t6_replace_single_owner()
	_t7_unhook()
	_t8_caller_nested()
	_t9_reentrancy()
	_t10_two_instances()
	await _t11_coroutine()
	_t12_defaults()
	_t13_input_deadzone()
	_t14_input_action_comes_back_whole()
	_t15_scene_override_blocks_remove()
	_t16_revert_reaches_the_patched_object()
	_t17_scene_path_reads_and_checks()
	_t18_when_predicate_cannot_abort_a_plan()
	_t19_has_mod_reads_a_v_prefix()
	_t20_freed_hook_owner()
	_t21_batch_verbs_survive_bad_values()
	_t22_scene_node_revert_reports_what_it_did()
	_t23_await_in_a_string_is_not_a_coroutine()

func _t1_pre() -> void:
	var id: int = _lib.hook("fixturedispatch-add-pre", func(x, y): _log.append("pre:add:%d:%d" % [x, y]))
	_expect(id != -1, "T1", "hook() returned -1 for a -pre registration")
	var r = _node_a.Add(2, 3)
	_expect_eq(r, 5, "T1", "Add(2,3) return value with only a pre hook")
	_expect_log("T1", ["pre:add:2:3", "vanilla:Add:2:3"])
	_unhook_all([id])

func _t2_replace() -> void:
	# 2a: value template, no skip_super -> callback runs FIRST, vanilla still
	# runs, and VANILLA's return wins (callback's 999 is discarded).
	var id: int = _lib.hook("fixturedispatch-add", func(x, y):
		_log.append("repl:%d:%d:caller=%s" % [x, y, str(_lib._caller.name)])
		return 999)
	var r = _node_a.Add(2, 3)
	_expect_eq(r, 5, "T2a", "without skip_super vanilla's return value must win")
	_expect_log("T2a", ["repl:2:3:caller=A", "vanilla:Add:2:3"])
	_unhook_all([id])

	# 2b: value template, skip_super -> vanilla suppressed, callback's return
	# becomes the result. This is the assertion --prove mutation A must break.
	id = _lib.hook("fixturedispatch-add", func(_x, _y):
		_lib.skip_super()
		_log.append("replskip")
		return 999)
	r = _node_a.Add(2, 3)
	_expect_eq(r, 999, "T2b", "with skip_super the replace callback's return must be the result")
	_expect_log("T2b", ["replskip"])
	_unhook_all([id])

	# 2c: void template, no skip -> vanilla still runs after the callback.
	id = _lib.hook("fixturedispatch-note", func(_m): _log.append("vrepl"))
	_node_a.Note("q")
	_expect_log("T2c", ["vrepl", "vanilla:Note:q"])
	_unhook_all([id])

	# 2d: void template, skip_super -> vanilla suppressed.
	id = _lib.hook("fixturedispatch-note", func(_m):
		_lib.skip_super()
		_log.append("vreplskip"))
	_node_a.Note("q")
	_expect_log("T2d", ["vreplskip"])
	_unhook_all([id])

func _t3_post() -> void:
	# 3a: trailing-_result form, non-null return replaces the result. This is
	# the assertion --prove mutation B must break.
	var id: int = _lib.hook("fixturedispatch-add-post", func(_x, _y, res): return res + 100)
	var r = _node_a.Add(2, 3)
	_expect_eq(r, 105, "T3a", "post hook returning non-null must replace the result")
	_unhook_all([id])

	# 3b: null return is the pass-through sentinel; callback still sees the
	# running result.
	id = _lib.hook("fixturedispatch-add-post", func(_x, _y, res):
		_log.append("post_saw:%s" % str(res))
		return null)
	r = _node_a.Add(2, 3)
	_expect_eq(r, 5, "T3b", "post hook returning null must leave the result untouched")
	_expect_log("T3b", ["vanilla:Add:2:3", "post_saw:5"])
	_unhook_all([id])

	# 3c: legacy 2-arg form (vanilla args only) still runs as an observer;
	# its return is ignored. (The one-shot deprecation warning it triggers is
	# expected console noise.)
	id = _lib.hook("fixturedispatch-add-post", func(x, y):
		_log.append("legacy:%d:%d" % [x, y])
		return 12345)
	r = _node_a.Add(2, 3)
	_expect_eq(r, 5, "T3c", "legacy 2-arg post hook must not affect the result")
	_expect_log("T3c", ["vanilla:Add:2:3", "legacy:2:3"])
	_unhook_all([id])

	# 3d: multiple post hooks chain in ascending priority; each sees the
	# previous transformation. p50 doubles, p100 adds 1: (2+3)*2+1 = 11.
	# The reversed order would give (2+3+1)*2 = 12.
	var ida: int = _lib.hook("fixturedispatch-add-post", func(_x, _y, res): return res * 2, 50)
	var idb: int = _lib.hook("fixturedispatch-add-post", func(_x, _y, res): return res + 1, 100)
	r = _node_a.Add(2, 3)
	_expect_eq(r, 11, "T3d", "post hooks must chain in ascending priority order")
	_unhook_all([ida, idb])

func _t4_deferred() -> void:
	var id: int = _lib.hook("fixturedispatch-note-callback", func(m): _log.append("cb:" + str(m)))
	_node_a.Note("hi")
	_expect_log("T4-immediate", ["vanilla:Note:hi"])
	await _wait_frames(2)
	_expect_log("T4-deferred", ["vanilla:Note:hi", "cb:hi"])
	_unhook_all([id])

func _t5_ordering() -> void:
	# Register the pre hooks in DESCENDING priority order so a pass can only
	# come from actual priority sorting, not registration order.
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
	var r = _node_a.Add(1, 1)
	_expect_eq(r, 2, "T5", "no skip_super: vanilla's return survives the full pipeline")
	_expect_log("T5-immediate", ["pre10", "pre20", "repl", "vanilla:Add:1:1", "post"])
	await _wait_frames(2)
	_expect_log("T5-deferred", ["pre10", "pre20", "repl", "vanilla:Add:1:1", "post", "cb:1:1"])
	_unhook_all(ids)

func _t6_replace_single_owner() -> void:
	var id1: int = _lib.hook("fixturedispatch-add", func(_x, _y):
		_log.append("owner1")
		return 0)
	var id2: int = _lib.hook("fixturedispatch-add", func(_x, _y):
		_log.append("owner2")
		return 0)
	_expect(id1 != -1, "T6", "first replace registration must succeed")
	_expect_eq(id2, -1, "T6", "second replace registration return code")
	_expect_eq(_lib.get_replace_owner("fixturedispatch-add"), id1, "T6", "get_replace_owner")
	_expect(_lib.has_replace("fixturedispatch-add"), "T6", "has_replace must be true while owned")
	var r = _node_a.Add(2, 3)
	_expect_eq(r, 5, "T6", "Add() result with an occupied replace slot (no skip)")
	_expect_log("T6", ["owner1", "vanilla:Add:2:3"])
	_unhook_all([id1, id2])
	_expect(not _lib.has_replace("fixturedispatch-add"), "T6", "has_replace must be false after unhook")

func _t7_unhook() -> void:
	var ida: int = _lib.hook("fixturedispatch-add-pre", func(_x, _y): _log.append("keepme_NOT"), 10)
	var idb: int = _lib.hook("fixturedispatch-add-pre", func(_x, _y): _log.append("survivor"), 20)
	_lib.unhook(ida)
	_node_a.Add(1, 1)
	_expect_log("T7", ["survivor", "vanilla:Add:1:1"])
	_unhook_all([idb])

func _t8_caller_nested() -> void:
	# A.Outer(B) -> vanilla Outer body calls B.Inner() (a nested wrapped call
	# on a DIFFERENT node). _caller must read A in Outer's pre, B in Inner's
	# pre, and A AGAIN in Outer's post (the wrapper re-sets it after the body).
	var ids: Array = [
		_lib.hook("fixturedispatch-outer-pre", func(_peer): _log.append("pre:outer:caller=" + str(_lib._caller.name))),
		_lib.hook("fixturedispatch-inner-pre", func(): _log.append("pre:inner:caller=" + str(_lib._caller.name))),
		_lib.hook("fixturedispatch-outer-post", func(_peer, _res):
			_log.append("post:outer:caller=" + str(_lib._caller.name))
			return null),
	]
	var r = _node_a.Outer(_node_b)
	_expect_eq(r, 6, "T8", "Outer(B) return value through nested wrapped dispatch")
	_expect_log("T8", [
		"pre:outer:caller=A",
		"vanilla:Outer:start",
		"pre:inner:caller=B",
		"vanilla:Inner",
		"vanilla:Outer:end",
		"post:outer:caller=A",
	])
	_expect(_lib._caller == null, "T8", "_caller must be restored to its pre-dispatch value (null) after the call")
	_unhook_all(ids)

func _t9_reentrancy() -> void:
	# A pre hook that calls the SAME wrapped method on the SAME instance. The
	# re-entry guard must route the nested call straight to vanilla (no
	# recursive dispatch), and -- the leak check -- the guard key must be
	# RELEASED afterward so the hook still fires on the NEXT call. --prove
	# mutation C removes the key erase; the second half of this test is what
	# catches it.
	var reent := func(x, y):
		_log.append("pre:add:%d:%d" % [x, y])
		if x == 2:
			var nested = _node_a.Add(1, 1)
			_log.append("nested_returned:" + str(nested))
	var id: int = _lib.hook("fixturedispatch-add-pre", reent)
	var r = _node_a.Add(2, 3)
	_expect_eq(r, 5, "T9", "outer Add(2,3) return value with a re-entrant pre hook")
	_expect_log("T9-first", [
		"pre:add:2:3",
		"vanilla:Add:1:1",
		"nested_returned:2",
		"vanilla:Add:2:3",
	])
	_log.clear()
	var r2 = _node_a.Add(4, 4)
	_expect_eq(r2, 8, "T9", "Add(4,4) return value on the call AFTER re-entrancy")
	_expect_log("T9-second", ["pre:add:4:4", "vanilla:Add:4:4"])
	_unhook_all([id])

func _t10_two_instances() -> void:
	# The guard is keyed per instance: while A's dispatch is in flight, a hook
	# calling the same method on B must get B's FULL dispatch (pre fires for
	# B too), with _caller correct for each.
	var cross := func(x, y):
		_log.append("pre:%s:%d:%d" % [str(_lib._caller.name), x, y])
		if _lib._caller == _node_a:
			_node_b.Add(9, 9)
	var id: int = _lib.hook("fixturedispatch-add-pre", cross)
	var r = _node_a.Add(1, 2)
	_expect_eq(r, 3, "T10", "A.Add(1,2) return value")
	_expect_log("T10", [
		"pre:A:1:2",
		"pre:B:9:9",
		"vanilla:Add:9:9",
		"vanilla:Add:1:2",
	])
	_expect(_lib._caller == null, "T10", "_caller restored to null after cross-instance dispatch")
	_unhook_all([id])

func _t11_coroutine() -> void:
	var ids: Array = [
		_lib.hook("fixturedispatch-corovalue-pre", func(x): _log.append("pre:cv:%d" % x)),
		_lib.hook("fixturedispatch-corovalue-post", func(_x, res):
			_log.append("post_saw:" + str(res))
			return res + 1),
	]
	var r = await _node_a.CoroValue(4)
	_expect_eq(r, 41, "T11", "await CoroValue(4): vanilla 40, +1 from the post hook")
	_expect_log("T11", [
		"pre:cv:4",
		"vanilla:CoroValue:start:4",
		"vanilla:CoroValue:end:4",
		"post_saw:40",
	])
	_unhook_all(ids)

func _t12_defaults() -> void:
	var id: int = _lib.hook("fixturedispatch-withdefaults-pre", func(a, b): _log.append("pre:wd:%d:%d" % [a, b]))
	var r = _node_a.WithDefaults(3)
	_expect_eq(r, 10, "T12", "WithDefaults(3) with the omitted default (7) applied")
	_expect_log("T12-omitted", ["pre:wd:3:7", "vanilla:WithDefaults:3:7"])
	_log.clear()
	r = _node_a.WithDefaults(3, 1)
	_expect_eq(r, 4, "T12", "WithDefaults(3,1) with the default overridden")
	_expect_log("T12-explicit", ["pre:wd:3:1", "vanilla:WithDefaults:3:1"])
	_unhook_all([id])

# --- registry -----------------------------------------------------------------
# T13 on reach the registry through the same Engine meta the hooks use.

## An InputMap action the registry did not add, with two key events and a
## deadzone that is not the engine default.
func _vanilla_action(action: String) -> void:
	if InputMap.has_action(action):
		InputMap.erase_action(action)
	InputMap.add_action(action, 0.2)
	for code in [KEY_A, KEY_B]:
		var ev := InputEventKey.new()
		ev.keycode = code
		InputMap.action_add_event(action, ev)

func _key_event(code: Key) -> InputEventKey:
	var ev := InputEventKey.new()
	ev.keycode = code
	return ev

func _t13_input_deadzone() -> void:
	var action := "rtv_dispatch_deadzone_action"
	_vanilla_action(action)
	_expect(_lib.override("inputs", action, {"default_event": _key_event(KEY_C), "deadzone": 0.8}), "T13", "override of an existing action succeeds")
	_expect(is_equal_approx(InputMap.action_get_deadzone(action), 0.8), "T13",
			"the deadzone an override asks for reaches InputMap (got %f)" % InputMap.action_get_deadzone(action))
	_expect(_lib.revert("inputs", action), "T13", "revert of the override succeeds")
	_expect(is_equal_approx(InputMap.action_get_deadzone(action), 0.2), "T13",
			"reverting the override restores the action's own deadzone (got %f)" % InputMap.action_get_deadzone(action))
	_expect(_lib.patch("inputs", action, {"deadzone": 0.9}), "T13", "a deadzone patch succeeds")
	_expect(is_equal_approx(InputMap.action_get_deadzone(action), 0.9), "T13", "the patched deadzone reaches InputMap")
	_expect(_lib.revert("inputs", action), "T13", "revert of the patch succeeds")
	_expect(is_equal_approx(InputMap.action_get_deadzone(action), 0.2), "T13",
			"reverting a deadzone patch restores the live value, not the engine default (got %f)" % InputMap.action_get_deadzone(action))
	InputMap.erase_action(action)

func _t14_input_action_comes_back_whole() -> void:
	var action := "rtv_dispatch_two_event_action"
	_vanilla_action(action)
	_expect(_lib.patch("inputs", action, {"default_event": _key_event(KEY_C)}), "T14", "an event patch succeeds")
	_expect_eq(InputMap.action_get_events(action).size(), 1, "T14", "events while patched")
	_expect(_lib.revert("inputs", action), "T14", "revert of the event patch succeeds")
	var codes: Array = []
	for ev in InputMap.action_get_events(action):
		codes.append((ev as InputEventKey).keycode)
	_expect_eq(codes, [KEY_A, KEY_B], "T14", "every event the action had is back after the revert")

	# An override that was reverted leaves nothing of the registry's on the
	# action, so remove() has nothing to take away.
	_expect(_lib.override("inputs", action, {"default_event": _key_event(KEY_C)}), "T14", "override succeeds")
	_expect(_lib.revert("inputs", action), "T14", "revert of the override succeeds")
	_expect(_lib.get_entry("inputs", action) == null, "T14", "a reverted override leaves no registry entry on an action the registry did not add")
	_expect(not _lib.remove("inputs", action), "T14", "remove() refuses an action the registry did not add")
	_expect(InputMap.has_action(action), "T14", "the action is still in InputMap")

	# A mod's own registration gets its payload back when an override on it is reverted.
	var own := "rtv_dispatch_registered_action"
	if InputMap.has_action(own):
		InputMap.erase_action(own)
	_expect(_lib.register("inputs", own, {"display_label": "Mine", "default_event": _key_event(KEY_A)}), "T14", "register succeeds")
	_expect(_lib.override("inputs", own, {"display_label": "Theirs", "default_event": _key_event(KEY_B)}), "T14", "override of a registration succeeds")
	_expect(_lib.revert("inputs", own), "T14", "revert of that override succeeds")
	var entry = _lib.get_entry("inputs", own)
	_expect(entry is Dictionary and str((entry as Dictionary).get("display_label", "")) == "Mine", "T14",
			"the registration's own payload is back after the revert (got %s)" % str(entry))
	_expect(_lib.remove("inputs", own), "T14", "the mod's own registration can still be removed")
	_expect(not InputMap.has_action(own), "T14", "and its action leaves InputMap")
	if InputMap.has_action(action):
		InputMap.erase_action(action)

## The registry reaches the Database and Loader autoloads through the scene
## tree. _has_loaded makes the loader's _ready return at once, so it can join
## the tree without booting. The two stand-ins carry the fields the rewriter
## injects into the real scripts.
func _registry_tree() -> void:
	if _ml.is_inside_tree():
		return
	_ml.set("_has_loaded", true)
	root.add_child(_ml)
	_fake_db = _stand_in("Database", "extends Node\n" \
			+ "var _rtv_mod_scenes: Dictionary = {}\n" \
			+ "var _rtv_override_scenes: Dictionary = {}\n" \
			+ "var _rtv_vanilla_scenes: Dictionary = {}\n" \
			+ "func _get(property: StringName):\n" \
			+ "\tvar key := String(property)\n" \
			+ "\tif _rtv_override_scenes.has(key):\n\t\treturn _rtv_override_scenes[key]\n" \
			+ "\tif _rtv_mod_scenes.has(key):\n\t\treturn _rtv_mod_scenes[key]\n" \
			+ "\tif _rtv_vanilla_scenes.has(key):\n\t\treturn _rtv_vanilla_scenes[key]\n" \
			+ "\treturn null\n")
	_fake_loader = _stand_in("Loader", "extends Node\n" \
			+ "const Cabin = \"res://Scripts/FixtureDispatch.gd\"\n" \
			+ "var _rtv_mod_scene_paths: Dictionary = {}\n" \
			+ "var _rtv_override_scene_paths: Dictionary = {}\n")

func _stand_in(node_name: String, source: String) -> Node:
	var script := GDScript.new()
	script.source_code = source
	script.reload()
	var node: Node = script.new()
	node.name = node_name
	root.add_child(node)
	return node

func _t15_scene_override_blocks_remove() -> void:
	_registry_tree()
	var mine := PackedScene.new()
	var theirs := PackedScene.new()
	_expect(_lib.register("scenes", "rtv_test_scene", mine), "T15", "register of a new scene id succeeds")
	_expect(_lib.override("scenes", "rtv_test_scene", theirs), "T15", "override of that registration succeeds")
	_expect(not _lib.remove("scenes", "rtv_test_scene"), "T15", "remove() refuses an id that carries an override")
	_expect(_lib.get_entry("scenes", "rtv_test_scene") == theirs, "T15", "the override still resolves")
	_expect(_lib.revert("scenes", "rtv_test_scene"), "T15", "revert drops the override")
	_expect(_lib.get_entry("scenes", "rtv_test_scene") == mine, "T15", "the registration resolves again, it was not removed from under the override")
	_expect(_lib.remove("scenes", "rtv_test_scene"), "T15", "remove() takes the registration once the override is gone")
	_expect(_lib.get_entry("scenes", "rtv_test_scene") == null, "T15", "and the id no longer resolves")

func _item_like(file_name: String, weight: float) -> Resource:
	var script := GDScript.new()
	script.source_code = "extends Resource\nvar file: String = \"\"\nvar weight: float = 0.0\nvar tags: Array = []\n"
	script.reload()
	var res: Resource = script.new()
	res.set("file", file_name)
	res.set("weight", weight)
	return res

func _t16_revert_reaches_the_patched_object() -> void:
	_registry_tree()
	# An item: patched, then overridden, then reverted. The patch goes back
	# onto the object it changed, not onto the override.
	var first := _item_like("rtv_test_item", 1.0)
	var second := _item_like("rtv_test_item", 7.0)
	_expect(_lib.register("items", "rtv_test_item", first), "T16", "register of an item succeeds")
	_expect(_lib.patch("items", "rtv_test_item", {"weight": 5.0}), "T16", "patch succeeds")
	_expect(_lib.append("items", "rtv_test_item", "tags", "heavy"), "T16", "append succeeds")
	_expect(_lib.override("items", "rtv_test_item", second), "T16", "override after the patch succeeds")
	_expect(_lib.revert("items", "rtv_test_item"), "T16", "full revert succeeds")
	_expect_eq(first.get("weight"), 1.0, "T16", "the patched item has its own weight back")
	_expect_eq((first.get("tags") as Array).size(), 0, "T16", "and its own array back")
	_expect_eq(second.get("weight"), 7.0, "T16", "the override object was not written to")
	_expect(_lib.get_entry("items", "rtv_test_item") == first, "T16", "the id resolves to the registration again")
	_lib.remove("items", "rtv_test_item")

	# The same order of calls on a scene path.
	var path := "res://Scripts/FixtureDispatch.gd"
	_expect(_lib.register("scene_paths", "rtv_test_path", {"path": path, "shelter": false}), "T16", "register of a scene path succeeds")
	_expect(_lib.patch("scene_paths", "rtv_test_path", {"shelter": true}), "T16", "scene path patch succeeds")
	_expect(_lib.override("scene_paths", "rtv_test_path", {"path": path, "shelter": false, "menu": true}), "T16", "scene path override succeeds")
	_expect(_lib.revert("scene_paths", "rtv_test_path"), "T16", "scene path full revert succeeds")
	var registered: Dictionary = _fake_loader.get("_rtv_mod_scene_paths").get("rtv_test_path", {})
	_expect_eq(registered.get("shelter"), false, "T16", "the registered scene path has its own flag back")
	_lib.remove("scene_paths", "rtv_test_path")

func _t17_scene_path_reads_and_checks() -> void:
	_registry_tree()
	var path := "res://Scripts/FixtureDispatch.gd"
	_expect(_lib.register("scene_paths", "rtv_test_read", {"path": path}), "T17", "register succeeds")
	_expect(_lib.override("scene_paths", "rtv_test_read", {"path": path, "menu": true}), "T17", "override succeeds")
	var entry = _lib.get_entry("scene_paths", "rtv_test_read")
	_expect(entry is Dictionary and bool((entry as Dictionary).get("menu", false)), "T17",
			"get_entry returns the override, which is what the game loads (got %s)" % str(entry))
	_expect(_lib.override("scene_paths", "Cabin", {"path": path, "menu": true}), "T17", "override of a vanilla scene name succeeds")
	entry = _lib.get_entry("scene_paths", "Cabin")
	_expect(entry is Dictionary and bool((entry as Dictionary).get("menu", false)), "T17", "get_entry sees an override of a vanilla name")
	_expect(not _lib.patch("scene_paths", "Cabin", {"path": "res://Scenes/NoSuchScene.tscn"}), "T17",
			"a patch cannot point a scene path at a file that does not exist")
	_expect_eq((_fake_loader.get("_rtv_override_scene_paths")["Cabin"] as Dictionary).get("path"), path, "T17", "the refused patch changed nothing")
	_expect(_lib.patch("scene_paths", "Cabin", {"path": path, "tutorial": true}), "T17", "a patch to an existing file still applies")
	_lib.revert("scene_paths", "Cabin")
	_lib.revert("scene_paths", "rtv_test_read")
	_lib.remove("scene_paths", "rtv_test_read")

func _t18_when_predicate_cannot_abort_a_plan() -> void:
	var own := "rtv_dispatch_plan_action"
	if InputMap.has_action(own):
		InputMap.erase_action(own)
	var plan: Array = [
		["when", func(): return null, [["remove", "inputs", ["never_runs"]]]],
		["when", func(): return "yes", [["remove", "inputs", ["never_runs"]]]],
		["when", func(): return 1, [["register", "inputs", {own: {"default_event": _key_event(KEY_A)}}]]],
	]
	var res = _lib.setup(plan)
	if not _expect(res is Dictionary, "T18", "setup() returns its result dict when a predicate returns null or a String (got %s)" % str(res)):
		return
	var results: Array = (res as Dictionary).get("results", [])
	if not _expect_eq(results.size(), 3, "T18", "one result per entry"):
		return
	_expect_eq((results[0] as Dictionary).get("evaluated"), false, "T18", "a predicate returning null reads as false")
	_expect_eq((results[1] as Dictionary).get("evaluated"), false, "T18", "a predicate returning a String reads as false")
	_expect_eq((results[2] as Dictionary).get("evaluated"), true, "T18", "a predicate returning 1 reads as true")
	_expect(InputMap.has_action(own), "T18", "the entry after the bad predicates still ran")
	_lib.remove("inputs", own)

func _t19_has_mod_reads_a_v_prefix() -> void:
	var loaded: Dictionary = _ml.get("_loaded_mod_ids")
	loaded["rtv_test_mod"] = {"mod_id": "rtv_test_mod", "version": "v1.3.0"}
	_expect(_lib.has_mod("rtv_test_mod", "1.2"), "T19", "a mod at v1.3.0 satisfies min_version 1.2")
	_expect(_lib.has_mod("rtv_test_mod", "v1.3"), "T19", "a v-prefixed min_version compares the same")
	_expect(not _lib.has_mod("rtv_test_mod", "1.4"), "T19", "and it does not satisfy 1.4")
	loaded["rtv_test_mod"] = {"mod_id": "rtv_test_mod", "version": ""}
	_expect(_lib.has_mod("rtv_test_mod", "0"), "T19", "a mod with no version still satisfies min_version 0")
	_expect(not _lib.has_mod("rtv_test_mod", "0.1"), "T19", "and nothing stricter")
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
	_expect(pre_id != -1 and replace_id != -1, "T20", "both hooks register")
	gone.free()
	_log.clear()
	var r = _node_a.Add(2, 3)
	_expect_eq(r, 5, "T20", "Add(2,3) with only a freed owner's hooks")
	_expect_log("T20", ["vanilla:Add:2:3"])
	_expect(not _lib.has_hooks("fixturedispatch-add-pre"), "T20", "the freed owner's pre hook is dropped at dispatch")
	var other_id: int = _lib.hook("fixturedispatch-add", func(_x, _y): return 0)
	_expect(other_id != -1, "T20", "a replace slot whose owner was freed can be taken")
	_expect_eq(_lib.get_replace_owner("fixturedispatch-add"), other_id, "T20", "and reports its new owner")
	_unhook_all([other_id])

func _t21_batch_verbs_survive_bad_values() -> void:
	var hooked = _lib.hook_many({"fixturedispatch-add-pre": null, "fixturedispatch-add-post": func(_x, _y, res): return res})
	if _expect(hooked is Dictionary, "T21", "hook_many returns its result dict when a value is not a Callable (got %s)" % str(hooked)):
		var results: Dictionary = (hooked as Dictionary).get("results", {})
		_expect_eq(results.get("fixturedispatch-add-pre"), -1, "T21", "the entry that is not a Callable reports -1")
		_expect(int(results.get("fixturedispatch-add-post", -1)) != -1, "T21", "the entry after it still registers")
		_expect_eq((hooked as Dictionary).get("ok"), false, "T21", "and ok is false")
		_unhook_all([int(results.get("fixturedispatch-add-post", -1))])
	var own := "rtv_dispatch_batch_action"
	if InputMap.has_action(own):
		InputMap.erase_action(own)
	_lib.register("inputs", own, {"default_event": _key_event(KEY_A)})
	var patched = _lib.patch_many("inputs", {"rtv_no_such_action": "display_label", own: {"display_label": "Batch"}})
	if _expect(patched is Dictionary, "T21", "patch_many returns its result dict when a value is not a Dictionary (got %s)" % str(patched)):
		var presults: Dictionary = (patched as Dictionary).get("results", {})
		_expect_eq(presults.get("rtv_no_such_action"), false, "T21", "the entry that is not a Dictionary reports false")
		_expect_eq(presults.get(own), true, "T21", "the entry after it still applies")
	var found = _lib.find("inputs", func(_entry): return null, false)
	_expect(found is Array and (found as Array).is_empty(), "T21", "find() with a predicate returning null matches nothing (got %s)" % str(found))
	found = _lib.find("inputs", func(entry): return entry.get("display_label") == "Batch", false)
	_expect(found is Array and (found as Array).size() == 1, "T21", "find() with a bool predicate still matches")
	_lib.remove("inputs", own)

func _t22_scene_node_revert_reports_what_it_did() -> void:
	_registry_tree()
	var scene_root := Node.new()
	scene_root.name = "Fixture"
	var packed := PackedScene.new()
	packed.pack(scene_root)
	scene_root.free()
	var scene_path := "res://Scripts/rtv_test_scene.tscn"
	if not _expect_eq(ResourceSaver.save(packed, scene_path), OK, "T22", "the fixture scene saves"):
		return
	var id := scene_path + "#."
	_expect(_lib.patch("scene_nodes", id, {"process_priority": 7}), "T22", "patch of a real property succeeds")
	_expect(not _lib.revert("scene_nodes", id, ["process_physics_priority"]), "T22", "reverting a field that was never patched reports false")
	_expect(_lib.revert("scene_nodes", id, ["process_priority"]), "T22", "reverting the patched field reports true")
	_expect(not _lib.revert("scene_nodes", id), "T22", "and nothing is left to revert")

# --- coroutine detection reads code, not text -----------------------------------

# The wrapper awaits the vanilla body only when that body is a coroutine. A
# method flagged by mistake turns its wrapper into a coroutine and every
# caller fails to parse ("must be called with await"): the 3.3.0 failure.
func _t23_await_in_a_string_is_not_a_coroutine() -> void:
	var src := "extends Node
" 			+ "func says() -> void:
	print(\"please await the signal\")
" 			+ "func noted() -> void:
	var x := 1 # await later
	print(x)
" 			+ "func waits() -> void:
	await get_tree().process_frame
" 			+ "func both() -> void:
	print(\"await \"); await get_tree().process_frame
"
	var parsed: Dictionary = _ml._rtv_parse_script("T23.gd", src)
	var coro := {}
	for fe in parsed["functions"]:
		coro[str(fe["name"])] = bool(fe["is_coroutine"])
	_expect_eq(bool(coro.get("says", true)), false, "T23", "await inside a string literal")
	_expect_eq(bool(coro.get("noted", true)), false, "T23", "await inside a trailing comment")
	_expect_eq(bool(coro.get("waits", false)), true, "T23", "a real await")
	_expect_eq(bool(coro.get("both", false)), true, "T23", "a real await after a string that also says await")
