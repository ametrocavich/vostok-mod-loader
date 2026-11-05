extends Node
# Declaration and body shapes the parser once misread; the runner checks each against
# EXPECTED_SHAPES. Keep each declaration on one line.

var health := 3

class Inner:
	var v := 1

# An await inside a lambda is the lambda's; the method is not a coroutine.
func BindLater() -> void:
	var cb := func():
		await (Engine.get_main_loop() as SceneTree).process_frame
		health += 1
	cb.call()

# A return with a value inside a single-line lambda is the lambda's.
func ReturnInLambda():
	var pick := func(x): return x + 1
	health = pick.call(health)

# Same, multi-line, then a bare return of the method's own.
func MultiLineLambdaReturn():
	var pick := func(x):
		if x > 1:
			return x
		return 0
	health = pick.call(health)
	return

# The detokenizer writes no space between await and a parenthesis.
func CoroNoSpace() -> int:
	await(Engine.get_main_loop() as SceneTree).process_frame
	return 1

# An identifier ending in "await" is not the keyword.
func NotAwait() -> void:
	var can_await := true
	if can_await:
		health += 1

# One-line bodies: the statement after the colon is the body.
func IsDead(): return health <= 0

func OneLineAwait(): await (Engine.get_main_loop() as SceneTree).process_frame

# Parameters named like the wrapper's own locals must not collide with them.
func Collide(_lib: int, _result: int, _repl: int, _prev_skip: int, _replret: int, _did_skip: int) -> int:
	return _lib + _result + _repl + _prev_skip + _replret + _did_skip

# Return annotations with brackets, commas, spaces and a dot.
func TypedDict() -> Dictionary[String, int]:
	return {"a": 1}

func InnerArray() -> Array[Inner]:
	return []

# An annotation on the declaration line keeps the method hookable.
@warning_ignore("unused_parameter") func Annotated(a: int) -> int:
	return health

# A one-line lambda on a block-opening line: the block below is the method's.
func PickAfterLambdaHeader():
	if [health].any(func(i): return i > 0):
		return health
	return 0

func AwaitAfterLambdaHeader():
	if [health].any(func(i): return i > 0):
		await (Engine.get_main_loop() as SceneTree).process_frame

# An annotation on its own line above the declaration belongs to it.
@warning_ignore("unused_parameter")
func AnnotatedAbove(a: int) -> int:
	return health

# A wrapper cannot forward a rest parameter: the method stays unwrapped (UNWRAPPED).
func Variadic(a: int, ...rest: Array) -> int:
	return a + rest.size()

# A typed multi-line lambda opens its own body; its await and return are its own.
func TypedLambdaAwait():
	var cb := func() -> void:
		await (Engine.get_main_loop() as SceneTree).process_frame
		health += 1
	cb.call()

func TypedLambdaReturn():
	var pick := func(x: int) -> int:
		return x + 1
	health = pick.call(health)

# A class annotation above a method is not the method's: the wrapper is a bare func.
@export_group("Debug")

func UnderGroup() -> int:
	return health

# `return func(...)` returns a value even though the lambda's body is cut away.
func ReturnsLambda(): return func(x): return x + health

# Text after a same-line lambda is the method's: its return, its await.
func ValueAfterLambda():
	if [health].any(func(i): return i > 0): return 1

func AwaitAfterLambda():
	if [health].any(func(i): return i > 0): await (Engine.get_main_loop() as SceneTree).process_frame

func ReturnOnlyInLambda():
	if [health].any(func(i): return i > 0): health += 1

# A region annotation is standalone: it stays above the vanilla body, off the wrapper.
@warning_ignore_start("unused_parameter")
func RegionStart(a: int) -> int:
	return health

@warning_ignore_restore("unused_parameter")
func RegionEnd(a: int):
	health += 1
