## FixtureDispatch.gd -- synthetic vanilla-shaped script for the runtime
## dispatch harness (tests/codegen/dispatch_runner.gd, driven by
## check_dispatch.sh). NOT part of the shipped loader. check_codegen.sh's
## Fixture*.gd glob copies this file into its project too, but it is not in
## runner.gd's FIXTURES table, so the compile-only harness never touches it.
##
## Every method body records what actually executed into the Array stored
## at Engine meta "RTVDispatchLog", so the runner can assert on real
## execution order after the REAL rewriter wraps these methods.
##
## Shape notes (each method exists to exercise one wrapper template path):
##   Add           sync value return       -> non-void template
##   Note          void                    -> void template
##   WithDefaults  defaulted parameter     -> default passthrough
##   CoroValue     real coroutine (await)  -> is_coro template variant
##   Outer/Inner   nested wrapped calls    -> _caller save/restore
## _rec is static ON PURPOSE: static funcs are outside the wrap surface,
## so the recorder itself can never be renamed or dispatched through.
extends Node

static func _rec(tag: String) -> void:
	if Engine.has_meta("RTVDispatchLog"):
		(Engine.get_meta("RTVDispatchLog") as Array).append(tag)

func Add(a: int, b: int) -> int:
	_rec("vanilla:Add:%d:%d" % [a, b])
	return a + b

func Note(msg: String) -> void:
	_rec("vanilla:Note:" + msg)

func WithDefaults(a: int, b: int = 7) -> int:
	_rec("vanilla:WithDefaults:%d:%d" % [a, b])
	return a + b

func CoroValue(x: int) -> int:
	_rec("vanilla:CoroValue:start:%d" % x)
	await (Engine.get_main_loop() as SceneTree).process_frame
	_rec("vanilla:CoroValue:end:%d" % x)
	return x * 10

func Outer(peer: Node) -> int:
	_rec("vanilla:Outer:start")
	var inner_val: int = peer.Inner()
	_rec("vanilla:Outer:end")
	return inner_val + 1

func Inner() -> int:
	_rec("vanilla:Inner")
	return 5
