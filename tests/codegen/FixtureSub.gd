extends "res://Scripts/FixtureDefaults.gd"
# Bare super() calls, which must reach the parent once the method is renamed. The harness
# runs it after FixtureDefaults.gd, so it compiles against the rewritten parent.

func PlainVoid() -> void:
	super()
	counter += 2

func DefaultsSimple(count: int = 3, label: String = "x") -> int:
	return super(count, label) + 1

# A bare super() in a one-line body is rewritten like an indented one.
func ImplicitVoid(): super()
