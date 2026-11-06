# Synthetic vanilla script for dispatch_runner.gd: each body logs to Engine meta "RTVDispatchLog".
# _rec is static because static funcs are outside the wrap surface: the recorder is never hooked.
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
