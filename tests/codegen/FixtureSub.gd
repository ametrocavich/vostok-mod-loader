extends "res://Scripts/FixtureDefaults.gd"
# Synthetic codegen fixture -- an extends-by-path subclass with bare super()
# calls, the pattern _rewrite_bare_super must rewrite once the enclosing
# method is renamed (a bare super() inside _rtv_vanilla_<name> would look for
# _rtv_vanilla_<name> on the parent, which does not exist -- Gotcha #2 in
# the GDScript-rewrite gotchas memory). Processed AFTER FixtureDefaults.gd,
# so this also proves a subclass compiles against the REWRITTEN parent.

func PlainVoid() -> void:
	super()
	counter += 2

func DefaultsSimple(count: int = 3, label: String = "x") -> int:
	return super(count, label) + 1
