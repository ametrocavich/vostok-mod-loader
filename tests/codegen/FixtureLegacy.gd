extends Node
# Synthetic codegen fixture -- Godot-3-era / sloppy syntax that Godot 4's
# parser rejects outright. The PRISTINE file deliberately does NOT compile
# (baseline=false in runner.gd's fixture table); the rewriter's
# _rtv_autofix_legacy_syntax pass must repair it (onready var -> @onready,
# export var -> @export, `pass` injected into bodyless blocks) and the
# REWRITTEN output must compile.

onready var late_node = get_node_or_null("Missing")
export var tunable = 4

func BodylessBranch(value: int) -> int:
	if value > 0:
	return value

func EmptyLoop() -> void:
	for i in range(3):
	tunable += 1
