extends Node
# Synthetic codegen fixture -- exercises signature shapes the vanilla RTV
# corpus does not contain (the 4.6.1 game ships no default parameter values
# at all). Compiled pristine as a baseline, then rewritten + recompiled by
# tests/codegen/runner.gd. Keep every func declaration on a single line with
# " -> " return-annotation spacing: the harness asserts the wrapper
# reproduces the declaration line byte-for-byte.

var counter := 0

static func StaticHelper(x: int = 2) -> int:
	return x * 2

class Inner:
	func InnerOnly(a := 1) -> int:
		return a

func PlainVoid() -> void:
	counter += 1

func ImplicitVoid():
	counter += 1

func SyncValue() -> String:
	return "shelter"

func DefaultsSimple(count: int = 3, label: String = "x") -> int:
	return count + label.length()

func DefaultsTricky(offset: Vector2 = Vector2(1, 2), tags: Array = ["a, (b)", "c"], data: Dictionary = {"k": 1}) -> Vector2:
	return offset + Vector2(tags.size(), data.size())

func UntypedDefaults(a = 5, b = "s"):
	return [a, b]

func TypedArrayValue() -> Array[String]:
	return ["a"]

func CoroutineValue(ticks: int = 1) -> int:
	await Engine.get_main_loop().process_frame
	return ticks * 2

func CoroutineVoid() -> void:
	await Engine.get_main_loop().process_frame
	counter += 1
