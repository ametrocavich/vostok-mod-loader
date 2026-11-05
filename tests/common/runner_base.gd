## Base of a runner (extends "res://runner_base.gd"; _init calls super(tag, scope)).
## Override _tests(ml) or _run(); begin, _assert, check_eq, check_num, _fail, boot_loader, _finish.
extends SceneTree

const H := preload("res://harness.gd")
const MODLOADER_PATH := "res://modloader_neutered.gd"

var _report: H.Report
## Frames _run may take before the watchdog fails it; one for a runner whose
## awaits never suspend.
var max_frames := 1
var _frames := 0
var _done := false

func _init(tag: String, scope: String) -> void:
	_report = H.Report.new(tag, scope)
	print("[%s] harness start" % tag)

func _process(_delta: float) -> bool:
	_frames += 1
	if _frames == 1:
		_run()
	if not _done and _frames >= max_frames:
		printerr("[%s] FAIL: the run suspended on an await and never reached _finish" % _report.prefix)
		quit(1)
		return true
	return _done

func _run() -> void:
	var ml := boot_loader()
	if ml != null:
		await _tests(ml)
	_finish()

func _tests(_ml: Object) -> void:
	pass

## A new neutered loader, or null after a report failure when it does not
## load or its boot static-init still ran.
func boot_loader() -> Object:
	var script := load(MODLOADER_PATH) as GDScript
	if script == null:
		_fail("could not load " + MODLOADER_PATH)
		return null
	var ml: Object = script.new()
	var mounted: Variant = ml.get("_filescope_mounted")
	if typeof(mounted) != TYPE_DICTIONARY or not (mounted as Dictionary).is_empty():
		_fail("modloader boot static-init was NOT neutralized -- refusing to run")
		return null
	return ml

func begin(id: String) -> void:
	_report.begin(id)

func _assert(cond: bool, msg: String) -> bool:
	return _report.check(cond, msg)

func check_eq(got: Variant, want: Variant, what: String) -> bool:
	return _report.check_eq(got, want, what)

func check_num(got: Variant, want: Variant, what: String) -> bool:
	return _report.check_num(got, want, what)

func _fail(msg: String) -> void:
	_report.fail(msg)

func _finish() -> void:
	_done = true
	_report.finish(self)
