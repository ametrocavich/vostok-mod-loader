## runner.gd -- boot-state / crash-loop-breaker harness.
## NOT part of the shipped loader. Executed by check_boot_state.sh inside a
## THROWAWAY Godot project assembled under the system temp dir; never run it
## against this repo or against the Road to Vostok install.
##
## Asserts the invariant the crash-loop breaker provides. It was written
## before the breaker was fixed and failed against that tree; it is the
## regression gate that keeps the breaker working now.
##
## The bug it guards against, precisely (as it stood in src/lifecycle.gd and
## src/boot.gd before the fix):
##   1. Pass 2 writes PASS2_DIRTY_PATH first thing (lifecycle.gd, top of
##      _run_pass_2), then calls _clear_restart_counter() -- BEFORE
##      load_all_mods and autoload instantiation, which is exactly where a
##      third-party mod crashes the process.
##   2. The next launch's static init sees the dirty marker
##      (boot.gd _mount_previous_session, the PASS2_DIRTY_PATH branch) and
##      calls _static_force_vanilla_state, which DELETES PASS_STATE_PATH --
##      the file the restart counter lives in.
##   3. Pass 1 then runs _check_crash_recovery (boot.gd). It loads
##      PASS_STATE_PATH, finds nothing, and skips its MAX_RESTART_COUNT body
##      entirely. The counter is therefore zero forever and the breaker never
##      trips: a mod that crashes Pass 2 gives the player a permanent
##      crash-to-desktop loop with no way out but manual file deletion.
##
## WHAT THIS HARNESS PROVES, AND WHAT IT DOES NOT:
##   PROVES  -- the pure file-based state machine: that a crash streak
##              survives the dirty-marker wipe, that MAX_RESTART_COUNT
##              consecutive crashed Pass-2 launches make the loader refuse the
##              two-pass restart, that a clean finish resets the streak to
##              ZERO (not merely decrements it), and that one bad launch does
##              NOT trip the breaker.
##   DOES NOT PROVE -- that _run_pass_1 actually honors the refusal. The
##              restart decision is inline in _run_pass_1 and cannot run
##              without the engine's boot sequence (it shows the launcher
##              window, mounts archives and relaunches the process), so the
##              refusal is asserted through the breaker predicate and through
##              the state files the boot path reads and writes, NOT by
##              observing a suppressed OS.set_restart_on_exit. T6 covers the
##              one ordering fact that is only visible in the source.
##
## THE CONTRACT THE FIX MUST SATISFY (this is the API the harness binds to):
##   - The existing functions keep their existing roles:
##       _write_pass_state()      Pass 1 arming a two-pass restart; counts
##                                the attempt.
##       _clear_restart_counter() a clean finish; resets the streak to zero.
##       _check_crash_recovery()  Pass 1 boot-time check.
##       _static_force_vanilla_state()  the dirty-marker wipe.
##   - The streak must NOT live anywhere _static_force_vanilla_state deletes.
##   - ONE new zero-argument method must expose the refusal decision, named
##     any of PREDICATE_NAMES below (or, failing that, a streak reader named
##     any of STREAK_NAMES, which the harness compares against
##     MAX_RESTART_COUNT). If the fix uses a different name, add it to the
##     list -- do not weaken an assertion.
##
## No network, no RTV corpus, no game install, so it runs on any machine and
## can NEVER skip. Every file it touches is either inside the throwaway
## project's own user:// or is refused outright (see the override.cfg guard in
## _run).
extends SceneTree

const MODLOADER_PATH := "res://modloader_neutered.gd"

# The refusal decision. Zero-arg, returns something truthy when the loader
# must NOT attempt another two-pass restart. First match wins.
const PREDICATE_NAMES := [
	"_crash_breaker_tripped",
	"_two_pass_blocked",
	"_should_refuse_two_pass",
	"_crash_loop_detected",
	"_restart_loop_tripped",
]
# Fallback: a plain streak reader. Compared against MAX_RESTART_COUNT.
const STREAK_NAMES := [
	"_crash_streak",
	"_restart_streak",
	"_read_restart_counter",
]

# Fixture pass-state payload. Nothing here is ever mounted -- _write_pass_state
# only records the strings.
const FIXTURE_HASH := "boot-state-harness-fixture-hash"

var _failures: PackedStringArray = []
var _assertions := 0

var _ml: Object = null
var _ml_script: GDScript = null
var _consts: Dictionary = {}

var _max_restarts := 0
var _pass_state_path := ""
var _pass2_dirty_path := ""
var _heartbeat_path := ""

# How the refusal decision is reached: "predicate", "streak", or "" (absent).
var _breaker_kind := ""
var _breaker_name := ""

# override.cfg next to the GODOT BINARY. _restore_clean_override_cfg (reached
# from _check_crash_recovery once the breaker trips) CREATES this file, so the
# harness refuses to run when one already exists and deletes the one it caused.
var _exe_cfg_path := ""

func _init() -> void:
	print("[boot-state] harness start")

func _process(_delta: float) -> bool:
	_run()
	return true

func _run() -> void:
	_ml_script = load(MODLOADER_PATH) as GDScript
	if _ml_script == null:
		_fail("could not load " + MODLOADER_PATH)
		_finish()
		return
	_ml = _ml_script.new()
	# Same guard the codegen/detok/host harnesses use: prove the boot
	# static-init really was neutralized before we touch anything. This one
	# matters more than usual -- an un-neutered static init would run the very
	# boot sequence these tests drive by hand.
	var mounted: Variant = _ml.get("_filescope_mounted")
	if typeof(mounted) != TYPE_DICTIONARY or not (mounted as Dictionary).is_empty():
		_fail("modloader boot static-init was NOT neutralized -- refusing to run")
		_finish()
		return

	_exe_cfg_path = OS.get_executable_path().get_base_dir().path_join("override.cfg")
	if FileAccess.file_exists(_exe_cfg_path):
		_fail("refusing to run: an override.cfg already exists next to the Godot "
				+ "binary (" + _exe_cfg_path + "). _restore_clean_override_cfg and "
				+ "_static_reset_override_cfg rewrite that exact path, and this "
				+ "harness will not touch a file it did not create. Move it aside, "
				+ "or point GODOT at another binary.")
		_finish()
		return

	_t1_preconditions()
	if not _failures.is_empty():
		# Every later test drives production functions and constants that T1
		# just proved absent. Running them would report cascading noise.
		_finish()
		return

	_resolve_breaker()
	_t2_streak_survives_the_wipe()
	_t3_one_crash_does_not_trip()
	_t4_max_crashes_trip_and_stay_tripped()
	_t5_clean_finish_resets_to_zero()
	_t6_pass2_clears_after_the_crash_window()
	_t7_hook_status_reaches_the_launcher()
	_t8_pass_state_reads_coerce()
	_t9_load_all_mods_keeps_applied_overrides()
	_t10_persisted_wrapped_paths_exclude_deferred()
	_t11_removed_feature_state_is_swept()
	_t12_game_update_is_seen_through_the_pck()
	_t13_missing_config_recovers_from_backup()
	_t14_state_hash_follows_load_order()
	_t15_state_hash_reads_an_unquoted_version()
	_t16_early_hooks_survive_load_all_mods()
	_t17_modlib_meta_registers_once()
	_t18_pack_failures_reach_the_launcher()
	_t19_wrap_surface_counts_each_script_once()
	_t20_lost_registry_target_names_its_declarers()
	_t21_cfg_write_failure_names_its_step()
	_t22_remove_tree_leaves_a_link_target_alone()

	_finish()

# --- T1: preconditions -------------------------------------------------------

# Not invariants -- these are the things every other test needs in order to
# mean anything. A rename here must fail loudly rather than silently turn the
# rest of the harness into a rubber stamp.
func _t1_preconditions() -> void:
	_consts = _ml_script.get_script_constant_map()
	for cname in ["MAX_RESTART_COUNT", "PASS_STATE_PATH", "PASS2_DIRTY_PATH", "HEARTBEAT_PATH"]:
		_assert(_consts.has(cname),
				"T1: constants.gd must still define %s (harness binds to it)" % cname)
	if not _failures.is_empty():
		return
	_max_restarts = int(_consts["MAX_RESTART_COUNT"])
	_pass_state_path = str(_consts["PASS_STATE_PATH"])
	_pass2_dirty_path = str(_consts["PASS2_DIRTY_PATH"])
	_heartbeat_path = str(_consts["HEARTBEAT_PATH"])
	_assert(_max_restarts >= 2,
			"T1: MAX_RESTART_COUNT must be >= 2 or 'one crash must not trip' and "
			+ "'MAX crashes must trip' collapse into the same case (got %d)" % _max_restarts)
	for fname in ["_write_pass_state", "_write_heartbeat", "_delete_heartbeat",
			"_check_crash_recovery", "_clear_restart_counter"]:
		_assert(_ml.has_method(fname),
				"T1: the loader must still have %s() -- the harness drives the real "
				% fname + "boot functions, not a copy of them")
	_assert(_ml_script.has_method("_static_force_vanilla_state")
					or _ml.has_method("_static_force_vanilla_state"),
			"T1: the loader must still have _static_force_vanilla_state() -- it is "
			+ "the dirty-marker wipe this harness fires")

# --- T2: the streak must outlive the wipe ------------------------------------

# BLACK BOX, on purpose: the harness does not care WHERE the streak lives, only
# that a second crashed restart attempt leaves persistently different state
# than a first one. Two arm-and-wipe sequences are run from a pristine user://
# and the resulting trees are compared.
#
# Deliberately NOT part of this sequence: _write_heartbeat. The heartbeat file
# already survives _static_force_vanilla_state, so including it would make this
# assertion pass vacuously -- and a heartbeat is a boolean ("something did not
# finish"), never a count.
#
# TODAY: both sequences leave an empty user:// -- the wipe deletes
# PASS_STATE_PATH, the only place restart_count exists -- so the trees are
# identical and this fails. That is W4.2.
func _t2_streak_survives_the_wipe() -> void:
	_reset_user_state()
	_count_restart_attempt()
	var armed := _snapshot_user()
	_assert(armed.has(_rel_user(_pass_state_path)),
			"T2: _write_pass_state must write %s (harness sanity)" % _pass_state_path)
	_fire_dirty_marker_wipe()
	var after_one := _snapshot_user()
	# Pins the mechanism itself, and passes today: the wipe really does delete
	# pass state. If this ever stops being true the rest of T2 needs rereading.
	_assert(not after_one.has(_rel_user(_pass_state_path)),
			"T2: _static_force_vanilla_state deletes pass state (mechanism pin) -- "
			+ "if this fails, W4.2's premise changed")

	_reset_user_state()
	_count_restart_attempt()
	_fire_dirty_marker_wipe()
	_count_restart_attempt()
	_fire_dirty_marker_wipe()
	var after_two := _snapshot_user()

	_assert(after_one != after_two,
			"T2: two crashed restart attempts must leave DIFFERENT persistent state "
			+ "than one -- the streak has to live somewhere the dirty-marker wipe "
			+ "does not erase. after 1: %s | after 2: %s"
					% [_describe(after_one), _describe(after_two)])

# --- T3: no false positive on a single bad launch ----------------------------

func _t3_one_crash_does_not_trip() -> void:
	_reset_user_state()
	_crashed_launch()
	# Precondition pin: a crashed launch leaves the heartbeat behind. That file
	# is the "the previous launch did not finish" evidence _check_crash_recovery
	# keys off, and every later step assumes a crash looks like this on disk.
	_assert(FileAccess.file_exists(_heartbeat_path),
			"T3: a crashed launch must leave the heartbeat at %s behind" % _heartbeat_path)
	_next_launch_boot()
	if _breaker_kind.is_empty():
		_missing_breaker("T3")
		return
	_assert(not _breaker_tripped(),
			"T3: ONE crashed Pass 2 must not trip the breaker (MAX_RESTART_COUNT "
			+ "is %d). A single bad launch -- a power cut, an alt-F4 during the "
					% _max_restarts
			+ "restart -- must not put the player into no-mods mode")

# --- T4: MAX consecutive crashes refuse the restart --------------------------

func _t4_max_crashes_trip_and_stay_tripped() -> void:
	if _breaker_kind.is_empty():
		_missing_breaker("T4")
		return
	_reset_user_state()
	for _i in _max_restarts:
		_crashed_launch()
	_next_launch_boot()
	_assert(_breaker_tripped(),
			"T4: after %d consecutive crashed Pass-2 launches the loader must "
					% _max_restarts
			+ "refuse the two-pass restart. Today the counter is cleared at the "
			+ "top of Pass 2 and its file is deleted by the dirty-marker wipe, so "
			+ "the breaker never trips and the player crash-loops to desktop")
	# The refusal itself has to be durable. Every crashed launch fires another
	# wipe, so a refusal that the wipe erases buys exactly one calm launch and
	# then the loop resumes.
	_fire_dirty_marker_wipe()
	_assert(_breaker_tripped(),
			"T4: the refusal must survive _static_force_vanilla_state too -- a "
			+ "breaker the wipe resets just re-arms the same loop")

# --- T5: a clean finish resets the streak to zero ----------------------------

# Two halves, because "reset" must mean ZERO, not "minus one". A decrementing
# breaker leaves the player one crash away from no-mods mode forever after a
# single bad afternoon.
func _t5_clean_finish_resets_to_zero() -> void:
	if _breaker_kind.is_empty():
		_missing_breaker("T5")
		return
	_reset_user_state()
	for _i in _max_restarts:
		_crashed_launch()
	_next_launch_boot()
	_clean_finish()
	_assert(not _breaker_tripped(),
			"T5: a clean finish must clear the breaker -- the player fixed the mod "
			+ "set and the loader came up; refusing forever would strand them in "
			+ "no-mods mode")
	for _i in range(_max_restarts - 1):
		_crashed_launch()
	_next_launch_boot()
	_assert(not _breaker_tripped(),
			"T5: the clean finish must reset the streak to ZERO, not decrement it: "
			+ "%d crash(es) after a clean launch is still below MAX_RESTART_COUNT "
					% (_max_restarts - 1)
			+ "(%d)" % _max_restarts)

# --- T6: the counter must not be cleared before the crash window -------------

# SOURCE-TEXT CHECK, and it says so out loud. The order of calls inside
# _run_pass_2 is not reachable headlessly: the function mounts archives,
# rewrites vanilla scripts, instantiates mod autoloads and reloads the current
# scene. Running it here would need the whole engine boot plus a real game
# install. The one fact W4.2 turns on -- that the streak is NOT cleared before
# the code that crashes -- is visible in the built source, so it is checked
# there rather than faked into a pass.
#
# Both drift guards below fail loudly rather than vacuously: a renamed
# _run_pass_2, or a body with no load_all_mods call, is reported as a failure,
# never as "nothing to check".
func _t6_pass2_clears_after_the_crash_window() -> void:
	var src := FileAccess.get_file_as_string(MODLOADER_PATH)
	if src.is_empty():
		_fail("T6: could not read " + MODLOADER_PATH + " as text")
		return
	var lines := src.split("\n")
	var start := -1
	var headers := 0
	for i in lines.size():
		if lines[i].begins_with("func _run_pass_2("):
			headers += 1
			if start < 0:
				start = i
	_assert(headers == 1,
			"T6: expected exactly 1 'func _run_pass_2(' in the built loader, found "
			+ "%d -- the Pass-2 entry point was renamed; update this test rather "
					% headers
			+ "than letting it pass on nothing")
	if start < 0:
		return
	var end := lines.size()
	for i in range(start + 1, lines.size()):
		var l: String = lines[i]
		if l.begins_with("func ") or l.begins_with("static func "):
			end = i
			break
	var i_load := -1
	var i_clear := -1
	var i_finish := -1
	for i in range(start, end):
		var l: String = lines[i]
		if i_load < 0 and l.contains("load_all_mods("):
			i_load = i
		if i_clear < 0 and l.contains("_clear_restart_counter("):
			i_clear = i
		if i_finish < 0 and l.contains("_finish_boot("):
			i_finish = i
	_assert(i_load >= 0,
			"T6: _run_pass_2's body no longer calls load_all_mods() -- the crash "
			+ "window this test is anchored to moved; re-anchor it")
	if i_load < 0:
		return
	if i_clear >= 0:
		_assert(i_clear > i_load,
				"T6: _run_pass_2 clears the restart counter at line %d, BEFORE "
						% (i_clear + 1)
				+ "load_all_mods() at line %d. A mod crashing during load or autoload "
						% (i_load + 1)
				+ "instantiation therefore leaves a streak of zero. The clear belongs "
				+ "with the other end-of-pass cleanup, next to the dirty-marker "
				+ "removal")
		return
	# The clear lives in the shared finish: it must be called after
	# load_all_mods, and its body must still hold the clear.
	_assert(i_finish > i_load,
			"T6: _run_pass_2 neither clears the restart counter itself nor calls "
			+ "_finish_boot after load_all_mods(); the streak would stay at zero "
			+ "or be cleared before the crash window")
	var finish_start := -1
	for i in lines.size():
		if lines[i].begins_with("func _finish_boot("):
			finish_start = i
			break
	_assert(finish_start >= 0, "T6: expected 'func _finish_boot(' in the built loader")
	if finish_start < 0:
		return
	var clears_in_finish := false
	for i in range(finish_start + 1, lines.size()):
		var l: String = lines[i]
		if l.begins_with("func ") or l.begins_with("static func "):
			break
		if l.contains("_clear_restart_counter("):
			clears_in_finish = true
			break
	_assert(clears_in_finish,
			"T6: _finish_boot no longer calls _clear_restart_counter; the streak is "
			+ "never reset after a clean Pass 2")

# --- Production-order drivers ------------------------------------------------

# One complete crashed launch, in the order the shipped code runs it. Each step
# either calls the real function or, where the code is inline in a function
# that needs the engine, writes exactly the file that code writes.
#
#   a) static init: the previous launch's PASS2_DIRTY_PATH is still on disk, so
#      _mount_previous_session takes its crashed-Pass-2 branch and calls
#      _static_force_vanilla_state (boot.gd).
#   b) Pass 1 _ready: _check_crash_recovery() (called at the top of
#      _run_pass_1, lifecycle.gd).
#   c) Pass 1 arms the two-pass restart: _write_heartbeat() then
#      _write_pass_state() (the archive_paths branch of _run_pass_1), then
#      relaunches.
#   d) Pass 2 entry writes PASS2_DIRTY_PATH. That write is inline at the top of
#      _run_pass_2 rather than a callable function, so the harness performs the
#      identical write.
#   e) A mod crashes the process inside load_all_mods / autoload
#      instantiation. Nothing after that point runs: the dirty marker stays,
#      the heartbeat stays.
#
# NOTE, and this is deliberate: step (e) does NOT call _clear_restart_counter,
# even though today's _run_pass_2 calls it BEFORE the crash window. Baking that
# call in here would pin the bug and make the harness unfixable. The call-site
# ordering is T6's job.
# --- T8: pass-state reads never raise ---------------------------------------

# mod_pass_state.cfg is hand-editable and can be half-written by a crash. A
# wrong-typed value used to raise inside the static initializer that mounts
# the previous session, which nothing could catch, so the loader stopped
# before any of its own recovery branches. Every read now coerces.
func _t8_pass_state_reads_coerce() -> void:
	var cfg := ConfigFile.new()
	cfg.set_value("state", "modloader_version", 3.31)          # number, not text
	cfg.set_value("state", "exe_mtime", "1699999999")           # text, not int
	cfg.set_value("state", "restart_count", null)               # nothing at all
	cfg.set_value("state", "archive_paths", "just/one/path.zip") # a string, not an array
	cfg.set_value("state", "hook_pack_wrapped_paths", ["res://Scripts/A.gd", 7, "res://Scripts/B.gd"])
	_assert(str(_ml._state_str(cfg, "modloader_version", "")) == "",
			"T8: a non-string version reads as the default")
	_assert(int(_ml._state_int(cfg, "exe_mtime", 0)) == 1699999999,
			"T8: an integer written as text still reads as that integer")
	_assert(int(_ml._state_int(cfg, "restart_count", 0)) == 0,
			"T8: a null count reads as 0")
	_assert((_ml._state_paths(cfg, "archive_paths") as PackedStringArray).is_empty(),
			"T8: a non-array path list reads as empty (boot then skips the mount)")
	var wrapped: PackedStringArray = _ml._state_paths(cfg, "hook_pack_wrapped_paths")
	_assert(wrapped.size() == 2 and wrapped[0] == "res://Scripts/A.gd",
			"T8: an untyped array keeps its string entries and drops the rest")
	_assert(int(_ml._state_int(cfg, "absent", 42)) == 42 and str(_ml._state_str(cfg, "absent", "d")) == "d",
			"T8: missing keys read as their defaults")

# --- T7: hook health record ----------------------------------------------------

# Hook-pack generation runs after the launcher closes, so the only way a
# player learns a game update broke the rewriter is the record generation
# leaves behind. Pins: a failure record produces a launcher notice; a record
# from another loader build or another game build is ignored; the
# game-updated marker produces a notice on its own and only a healthy
# activation clears it.
func _t7_hook_status_reaches_the_launcher() -> void:
	var status_path := str(_ml.HOOK_STATUS_PATH)
	var marker_path := str(_ml.GAME_UPDATED_MARKER_PATH)
	var clear := func():
		for p in [status_path, marker_path]:
			if FileAccess.file_exists(p):
				DirAccess.remove_absolute(ProjectSettings.globalize_path(p))
	clear.call()
	_assert((_ml._hook_status_problem() as Dictionary).is_empty(),
			"T7: no record and no marker -> nothing to show")

	_ml._hook_status_write({"state": "all_failed", "attempted": 12, "ok": 0})
	var problem: Dictionary = _ml._hook_status_problem()
	_assert(str(problem.get("severity", "")) == "error" and str(problem.get("text", "")).contains("12"),
			"T7: an all-failed record is an error notice naming the count (got %s)" % str(problem))

	_ml._hook_status_write({"state": "critical_failed", "attempted": 12, "ok": 9,
			"critical_failures": ["res://Scripts/Controller.gd", "res://Scripts/Camera.gd"]})
	problem = _ml._hook_status_problem()
	_assert(str(problem.get("text", "")).contains("Controller.gd") and str(problem.get("text", "")).contains("Camera.gd"),
			"T7: a critical-failure record names the scripts")

	_ml._hook_status_write({"state": "unsupported_gdsc", "gdsc_version": 102})
	problem = _ml._hook_status_problem()
	_assert(str(problem.get("severity", "")) == "error" and str(problem.get("text", "")).contains("v102"),
			"T7: an unsupported-format record names the version")

	# Another loader build wrote it: a loader update may have fixed it, so
	# the record is ignored until this build writes its own.
	var f := FileAccess.open(status_path, FileAccess.WRITE)
	f.store_string(JSON.stringify({"state": "all_failed", "attempted": 3, "loader_version": "0.0.0",
			"exe_mtime": FileAccess.get_modified_time(OS.get_executable_path())}))
	f.close()
	_assert((_ml._hook_status_problem() as Dictionary).is_empty(),
			"T7: a record from another loader version is ignored")
	# Another game build wrote it: the exe changed since.
	f = FileAccess.open(status_path, FileAccess.WRITE)
	f.store_string(JSON.stringify({"state": "all_failed", "attempted": 3, "loader_version": str(_ml.MODLOADER_VERSION),
			"exe_mtime": 12345}))
	f.close()
	_assert((_ml._hook_status_problem() as Dictionary).is_empty(),
			"T7: a record from another game build is ignored")

	# The game-updated marker alone is a notice, not an error.
	clear.call()
	_ml._static_mark_game_updated()
	problem = _ml._hook_status_problem()
	_assert(str(problem.get("severity", "")) == "notice" and str(problem.get("text", "")).contains("updated"),
			"T7: the game-updated marker shows a notice (got %s)" % str(problem))
	# A no-mods session does not prove hooks work on the new build.
	_ml._hook_status_write({"state": "ok", "attempted": 0})
	_assert(FileAccess.file_exists(marker_path), "T7: an empty session keeps the marker")
	# A healthy activation does.
	_ml._hook_status_write({"state": "ok", "attempted": 5, "ok": 5})
	_assert(not FileAccess.file_exists(marker_path), "T7: a healthy activation clears the marker")
	_assert((_ml._hook_status_problem() as Dictionary).is_empty(), "T7: nothing to show after a healthy activation")
	clear.call()

# --- T12: a game update is seen through the PCK as well as the executable ------

# A content patch can replace the game's PCK and leave the executable
# untouched. Pass state and the hook status record carry the PCK's stamp, and
# static init treats a moved stamp like a moved executable mtime. Pins: the
# decision static init takes, that _write_pass_state records the stamp, and
# that a hook status record from another PCK is ignored.
func _t12_game_update_is_seen_through_the_pck() -> void:
	for m in ["_static_game_build_changed", "_static_game_pck_stamp", "_game_pck_stamp"]:
		_assert(_ml.has_method(m), "T12: the loader has %s" % m)
		if not _ml.has_method(m):
			return
	var cfg := ConfigFile.new()
	cfg.set_value("state", "exe_mtime", 100)
	cfg.set_value("state", "pck_stamp", "200:3000")
	_assert(not bool(_ml._static_game_build_changed(cfg, 100, "200:3000")), "T12: same executable, same PCK -> unchanged")
	_assert(bool(_ml._static_game_build_changed(cfg, 101, "200:3000")), "T12: a moved executable mtime -> changed")
	_assert(bool(_ml._static_game_build_changed(cfg, 100, "201:3000")), "T12: a moved PCK mtime -> changed")
	_assert(bool(_ml._static_game_build_changed(cfg, 100, "200:3001")), "T12: a resized PCK -> changed")
	_assert(not bool(_ml._static_game_build_changed(cfg, 100, "")), "T12: no PCK beside the executable -> unchanged")
	var older := ConfigFile.new()
	older.set_value("state", "exe_mtime", 100)
	_assert(not bool(_ml._static_game_build_changed(older, 100, "200:3000")),
			"T12: pass state that recorded no stamp -> unchanged")
	_assert(not bool(_ml._static_game_build_changed(ConfigFile.new(), 100, "200:3000")),
			"T12: empty pass state -> unchanged")

	# The instance side reads the PCK through the same override the detokenizer uses.
	var pck := "user://harness_game.pck"
	var pck_abs := ProjectSettings.globalize_path(pck)
	_write_file(pck, "first build")
	_ml.set("_game_pck_path_override", pck_abs)
	var stamp := str(_ml._game_pck_stamp())
	_assert(stamp != "", "T12: the stamp of an existing PCK is not empty")
	_ml._write_pass_state(PackedStringArray(["user://harness_fixture_mod.zip"]), FIXTURE_HASH)
	var state := ConfigFile.new()
	_assert(state.load(str(_ml.PASS_STATE_PATH)) == OK and str(state.get_value("state", "pck_stamp", "")) == stamp,
			"T12: _write_pass_state records the PCK stamp")

	var status_path := str(_ml.HOOK_STATUS_PATH)
	_ml._hook_status_write({"state": "all_failed", "attempted": 4, "ok": 0})
	_assert(not (_ml._hook_status_problem() as Dictionary).is_empty(), "T12: a failure record from this PCK shows")
	_write_file(pck, "second build, a different size")
	_assert((_ml._hook_status_problem() as Dictionary).is_empty(), "T12: a record from another PCK is ignored")

	_ml.set("_game_pck_path_override", "")
	for p in [status_path, pck, str(_ml.PASS_STATE_PATH), str(_ml.CRASH_STREAK_PATH)]:
		if FileAccess.file_exists(p):
			DirAccess.remove_absolute(ProjectSettings.globalize_path(p))

# --- T13: a missing mod_config.cfg recovers from its backup ------------------

# Pass 1 scans the mods folder before it loads the launcher config, and the
# scan persists each mod's declared source into mod_config.cfg. With the live
# file missing and a .bak present, that write would create a fresh file, the
# load would then find nothing to recover, and the next save would copy the
# near-empty file over the backup. Pins: the scan-time persist stands down,
# the load recovers every profile, and the backup survives.
func _t13_missing_config_recovers_from_backup() -> void:
	_reset_user_state()
	var cfg_path := str(_ml.UI_CONFIG_PATH)
	var bak_path := cfg_path + ".bak"
	var good := ConfigFile.new()
	good.set_value("settings", "active_profile", "Hardcore")
	good.set_value("profile.Default.enabled", "a@1.0", true)
	good.set_value("profile.Hardcore.enabled", "a@1.0", false)
	good.set_value("profile.Hardcore.priority", "a@1.0", 40)
	_assert(good.save(bak_path) == OK, "T13: wrote the backup")
	_assert(not FileAccess.file_exists(cfg_path), "T13: the live config is missing")

	var mod_txt := ConfigFile.new()
	mod_txt.parse("[mod]\nname=\"A\"\nid=\"a\"\nversion=\"1.0\"\n\n[updates]\nsource=\"vostokmods:a\"\n")
	var entries: Array[Dictionary] = [{"profile_key": "a@1.0", "cfg": mod_txt}]
	_ml._persist_mod_sources_for_entries(entries)
	_assert(not FileAccess.file_exists(cfg_path),
			"T13: the scan-time persist does not create mod_config.cfg while a backup waits to be recovered")

	var empty: Array[Dictionary] = []
	_ml.set("_ui_mod_entries", empty)
	_ml._load_ui_config()
	_assert(str(_ml.get("_active_profile")) == "Hardcore",
			"T13: the load recovers the active profile from the backup (got '%s')" % str(_ml.get("_active_profile")))
	var profiles: Array = _ml._list_profiles()
	_assert(profiles.has("Default") and profiles.has("Hardcore"),
			"T13: every profile is back (got %s)" % str(profiles))
	var bak := ConfigFile.new()
	_assert(bak.load(bak_path) == OK and bak.has_section("profile.Hardcore.priority"),
			"T13: the backup still holds the profiles after the recovery")

	# With no backup a missing file is a fresh install, and the persist writes.
	_reset_user_state()
	_ml._persist_mod_sources_for_entries(entries)
	_assert(FileAccess.file_exists(cfg_path), "T13: with no backup the persist creates the file as before")
	_reset_user_state()

# --- T14: the state hash follows the load order --------------------------------

# Pass 1 skips the restart when the state hash matches the previous session's,
# and static init then keeps that session's mount order. Mount order decides
# which mod wins a file both ship, so a priority change that reorders the
# archives has to change the hash, or it never takes effect.
func _t14_state_hash_follows_load_order() -> void:
	_reset_user_state()
	_write_file("user://hash_a.zip", "a")
	_write_file("user://hash_b.zip", "b")
	var a := ProjectSettings.globalize_path("user://hash_a.zip")
	var b := ProjectSettings.globalize_path("user://hash_b.zip")
	var none: Array[Dictionary] = []
	_ml.set("_ui_mod_entries", none)
	var ab := str(_ml._compute_state_hash(PackedStringArray([a, b]), none))
	var ba := str(_ml._compute_state_hash(PackedStringArray([b, a]), none))
	_assert(ab != "" and ba != "", "T14: a non-empty archive list hashes to something")
	_assert(ab == str(_ml._compute_state_hash(PackedStringArray([a, b]), none)), "T14: the same order hashes the same")
	_assert(ab != ba, "T14: the same archives in another load order hash differently")
	_assert(str(_ml._compute_state_hash(PackedStringArray(), none)) == "", "T14: nothing to mount hashes to the empty string")
	_reset_user_state()

# --- T15: the state hash reads any mod.txt version ------------------------------

# ConfigFile reads an unquoted `version=1.5` as a float. The hash folds each
# enabled mod's version in, and must do so whatever type the value arrived as.
func _t15_state_hash_reads_an_unquoted_version() -> void:
	_reset_user_state()
	_write_file("user://hash_a.zip", "a")
	var a := ProjectSettings.globalize_path("user://hash_a.zip")
	var none: Array[Dictionary] = []
	var unquoted := ConfigFile.new()
	unquoted.parse("[mod]\nname=\"M\"\nid=\"m\"\nversion=1.5\n")
	_assert(typeof(unquoted.get_value("mod", "version")) == TYPE_FLOAT, "T15: the fixture version arrives as a float")
	var newer := ConfigFile.new()
	newer.parse("[mod]\nname=\"M\"\nid=\"m\"\nversion=1.6\n")
	var entries: Array[Dictionary] = [{"enabled": true, "mod_id": "m", "cfg": unquoted}]
	_ml.set("_ui_mod_entries", entries)
	var h15: Variant = _ml._compute_state_hash(PackedStringArray([a]), none)
	_assert(h15 is String and str(h15) != "", "T15: an unquoted version does not abort the hash (got %s)" % str(h15))
	entries[0]["cfg"] = newer
	var h16: Variant = _ml._compute_state_hash(PackedStringArray([a]), none)
	_assert(h16 is String and str(h16) != str(h15), "T15: the unquoted version is part of the hash")
	_ml.set("_ui_mod_entries", none)
	_reset_user_state()

# --- T16: hooks registered before load_all_mods survive it ---------------------

# A `!` early autoload is instantiated by the engine before the loader's
# _ready resumes, so its hook() and add_hook() calls land before load_all_mods
# runs. add_hook() also enrolls the vanilla path in the wrap mask, which pack
# generation reads afterwards. Both have to survive load_all_mods.
func _t16_early_hooks_survive_load_all_mods() -> void:
	var cb := func(): pass
	var hook_id: int = _ml.add_hook("Controller.gd", "Jump", cb, true)
	_assert(hook_id > 0, "T16: add_hook registers (got %d)" % hook_id)
	_assert(bool(_ml.has_hooks("controller-jump-pre")), "T16: the callback is registered under the native name")
	var none: Array[Dictionary] = []
	_ml.set("_ui_mod_entries", none)
	_ml.load_all_mods("Pass 2")
	_assert(bool(_ml.has_hooks("controller-jump-pre")), "T16: the callback survives load_all_mods")
	var mask: Dictionary = _ml.get("_hooked_methods")
	_assert(mask.has("res://Scripts/Controller.gd") and (mask["res://Scripts/Controller.gd"] as Dictionary).has("jump"),
			"T16: the wrap-mask enrollment survives load_all_mods (got %s)" % str(mask))
	_ml.unhook(hook_id)
	mask.erase("res://Scripts/Controller.gd")

# --- T17: the RTVModLib meta is registered once, by the loader ----------------

# The meta is registered before the launcher opens so an early autoload's
# _ready finds it, and every boot path registers it again on the way out.
# Registering twice is silent; finding another object there is reported.
func _t17_modlib_meta_registers_once() -> void:
	if Engine.has_meta("RTVModLib"):
		Engine.remove_meta("RTVModLib")
	var lines: Array = _ml.get("_report_lines")
	lines.clear()
	_ml._register_rtv_modlib_meta()
	_assert(Engine.has_meta("RTVModLib") and Engine.get_meta("RTVModLib") == _ml, "T17: the loader registers itself")
	_ml._register_rtv_modlib_meta()
	var complained := false
	for line in lines:
		if str(line).contains("already set"):
			complained = true
	_assert(not complained, "T17: registering again is silent when the meta is the loader itself")
	var stranger := RefCounted.new()
	Engine.set_meta("RTVModLib", stranger)
	_ml._register_rtv_modlib_meta()
	complained = false
	for line in lines:
		if str(line).contains("already set"):
			complained = true
	_assert(complained and Engine.get_meta("RTVModLib") == stranger,
			"T17: another object under the meta is reported and left alone")
	Engine.remove_meta("RTVModLib")
	lines.clear()

# --- T18: a hook pack that cannot be built or mounted is reported ---------------

# The hook status record is how the next launcher learns hooks did not work.
# A pack that cannot be written, or that will not mount, must leave its own
# record: without one the record of the last healthy session stays in place
# and the launcher says nothing.
func _t18_pack_failures_reach_the_launcher() -> void:
	var status_path := str(_ml.HOOK_STATUS_PATH)
	_assert("HOOK_STATE_PACK_FAILED" in _ml, "T18: the loader has HOOK_STATE_PACK_FAILED")
	if not ("HOOK_STATE_PACK_FAILED" in _ml):
		return
	var healthy := func():
		_ml._hook_status_write({"state": "ok", "attempted": 5, "ok": 5})
	var no_paths: Array[String] = []

	# The zip cannot be created: its directory does not exist.
	healthy.call()
	var packed: Array[String] = []
	var wrote: int = _ml._hook_pack_write_zip("user://no_such_dir/framework_pack_1.zip", no_paths, {}, {}, {}, {}, packed)
	_assert(wrote == -1, "T18: a zip that cannot be created returns -1 (got %d)" % wrote)
	var problem: Dictionary = _ml._hook_status_problem()
	_assert(str(problem.get("severity", "")) == "error" and str(problem.get("text", "")).contains("hook pack"),
			"T18: a pack that cannot be written is an error notice (got %s)" % str(problem))

	# The zip will not mount: there is no such file.
	healthy.call()
	_assert((_ml._hook_status_problem() as Dictionary).is_empty(), "T18: a healthy record shows nothing")
	var wrapped: Array[String] = ["res://Scripts/Controller.gd"]
	var mounted := str(_ml._hook_pack_mount_and_activate("user://framework_pack_missing.zip", wrapped, 4, {}, false))
	_assert(mounted == "", "T18: a pack that will not mount returns no path")
	problem = _ml._hook_status_problem()
	_assert(str(problem.get("severity", "")) == "error" and str(problem.get("text", "")).contains("hook pack"),
			"T18: a pack that will not mount is an error notice (got %s)" % str(problem))
	if FileAccess.file_exists(status_path):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(status_path))

# --- T19: the wrap surface and its ledger --------------------------------------

# The wrap surface is every vanilla script some mod declared, through [hooks],
# a .hook() call or [registry]. A registry target a mod also hooks by method
# is widened to a whole-script wrap, is counted once, and its ledger entry
# says both declarations reached it.
func _t19_wrap_surface_counts_each_script_once() -> void:
	var hooked: Dictionary = _ml.get("_hooked_methods")
	hooked.clear()
	hooked["res://Scripts/Database.gd"] = {"_ready": true}
	hooked["res://Scripts/Controller.gd"] = {"jump": true}
	_ml.set("_any_mod_declared_registry", true)
	var lines: Array = _ml.get("_report_lines")
	lines.clear()
	var scripts: Array[String] = ["res://Scripts/Menu.gd", "res://Scripts/Controller.gd"]
	for rt in _ml.REGISTRY_TARGETS:
		scripts.append("res://Scripts/" + str(rt))
	var needed: Dictionary = {}
	var mask: Dictionary = {}
	var ledger: Dictionary = _ml._hook_pack_wrap_surface(scripts, needed, mask)
	# Controller and Menu by method, Database by method and by [registry], five more by [registry].
	_assert(needed.size() == 8, "T19: eight scripts are in the wrap surface (got %d)" % needed.size())
	var surface_line := ""
	for line in lines:
		if str(line).contains("Wrap surface:"):
			surface_line = str(line)
	_assert(surface_line.contains("8 vanilla script(s) declared (3 via [hooks]/.hook(), 5 more via [registry])"),
			"T19: the summary counts a script declared both ways once (got '%s')" % surface_line)
	_assert((mask.get("res://Scripts/Database.gd", {"x": true}) as Dictionary).is_empty(),
			"T19: a registry target hooked by method is widened to the whole script")
	_assert((mask.get("res://Scripts/Controller.gd", {}) as Dictionary).has("jump"),
			"T19: a script hooked by method only keeps its method mask")
	_assert(str((ledger.get("res://Scripts/Database.gd", {}) as Dictionary).get("declared", "")) == "[hooks]+[registry]",
			"T19: the ledger records both declarations")
	_assert(str((ledger.get("res://Scripts/Loader.gd", {}) as Dictionary).get("declared", "")) == "[registry]",
			"T19: a registry-only target is recorded as such")
	hooked.clear()
	_ml.set("_any_mod_declared_registry", false)
	lines.clear()

# --- T20: a lost hook target names who declared it ------------------------------

# The reconciliation report names the mods behind a target that did not make
# it into the pack. A registry target has no [hooks] declarer; the mods that
# declared [registry] are named, not an add_hook() call that never happened.
func _t20_lost_registry_target_names_its_declarers() -> void:
	_assert("_registry_declared_by" in _ml, "T20: the loader has _registry_declared_by")
	if not ("_registry_declared_by" in _ml):
		return
	var by: Dictionary = _ml.get("_registry_declared_by")
	by.clear()
	by["Loot Overhaul"] = true
	_ml.set("_any_mod_declared_registry", true)
	var label := str(_ml._hook_declarers_label("res://Scripts/Loader.gd"))
	_assert(label.contains("Loot Overhaul") and not label.contains("add_hook"),
			"T20: a registry target is attributed to the mods that declared [registry] (got '%s')" % label)
	_assert(str(_ml._hook_declarers_label("res://Scripts/Controller.gd")).contains("add_hook"),
			"T20: a path nobody declared statically is still attributed to add_hook")
	_assert(str(_ml._hook_declarers_label("res://Scripts/Menu.gd")).contains("the mod loader itself"),
			"T20: the core Menu.gd wrap is attributed to the loader")
	by.clear()
	_ml.set("_any_mod_declared_registry", false)

# --- T21: a failed override.cfg write says which step failed ---------------------

# The write is tmp file, park the live file, rename into place. A report from
# a player whose game folder is read-only or locked by antivirus is only
# useful when the log names the step and the engine's error code.
func _t21_cfg_write_failure_names_its_step() -> void:
	_assert("_static_cfg_write_error" in _ml, "T21: the loader has _static_cfg_write_error")
	if not ("_static_cfg_write_error" in _ml):
		return
	var good := ProjectSettings.globalize_path("user://t21_override.cfg")
	_assert(bool(_ml._static_write_cfg_atomic(good, "[autoload]\n")), "T21: a write into user:// succeeds")
	_assert(str(_ml.get("_static_cfg_write_error")) == "", "T21: a success leaves no error text")
	var bad := ProjectSettings.globalize_path("user://t21_no_such_dir/override.cfg")
	_assert(not bool(_ml._static_write_cfg_atomic(bad, "[autoload]\n")), "T21: a write into a missing folder fails")
	var why := str(_ml.get("_static_cfg_write_error"))
	_assert(why.contains("override.cfg.tmp") and why.contains("error "),
			"T21: the failure names the step and the error code (got '%s')" % why)
	DirAccess.remove_absolute(good)

# --- T22: the recursive delete does not follow a link ----------------------------

# _remove_tree refuses any path outside user://, but that check is on the
# path's text. A symlink or junction inside the tree points somewhere else:
# the link is removed, and what it points at is left alone.
func _t22_remove_tree_leaves_a_link_target_alone() -> void:
	var outside := ProjectSettings.globalize_path("user://t22_outside")
	var tree := ProjectSettings.globalize_path("user://t22_tree")
	DirAccess.make_dir_recursive_absolute(outside)
	DirAccess.make_dir_recursive_absolute(tree)
	_write_file("user://t22_outside/keep.txt", "keep")
	_write_file("user://t22_tree/own.txt", "own")
	var dir := DirAccess.open(tree)
	var linked := dir != null and dir.create_link(outside, tree.path_join("link")) == OK
	if not linked and OS.get_name() == "Windows":
		# A symlink needs a privilege most accounts lack; a junction needs none
		# and a recursive delete follows it the same way.
		linked = OS.execute("cmd", ["/c", "mklink", "/J", tree.path_join("link").replace("/", "\\"), outside.replace("/", "\\")]) == 0
	_ml._remove_tree("user://t22_tree", false)
	_assert(not DirAccess.dir_exists_absolute(tree), "T22: the tree itself is removed")
	if linked:
		_assert(FileAccess.file_exists("user://t22_outside/keep.txt"), "T22: a file behind a link inside the tree survives")
	else:
		print("[boot-state] T22: this platform would not create a link; the link case was not exercised")
	_ml._remove_tree("user://t22_outside", false)

# --- T9: Pass 2 keeps the applied-override map through load_all_mods --------

# Pass 2 applies [script_extend] / [script_overrides] from pass state before
# load_all_mods runs, and _generate_hook_pack reads _applied_script_overrides
# afterwards to warn when a rewrite displaces a mod's replacement script. A
# load_all_mods that clears the map silences that warning on every Pass 2.
# With no mod entries the call takes its no-mods return right after the
# clears at its top, which is all this needs to reach.
func _t9_load_all_mods_keeps_applied_overrides() -> void:
	_ml._applied_script_overrides["res://Scripts/Menu.gd"] = true
	_ml.load_all_mods("Pass 2")
	var applied: Dictionary = _ml._applied_script_overrides
	_assert(applied.has("res://Scripts/Menu.gd"),
			"T9: load_all_mods must not clear _applied_script_overrides -- Pass 2 "
			+ "fills it before the call and the hook pack reads it after")
	_ml._applied_script_overrides.clear()

# --- T10: deferred scripts stay out of the persisted wrapped-path list -------

# A rewritten vanilla script with a module-scope scene preload is deferred to
# lazy compile so mod overrides land before its scenes bake. Static init
# force-compiles every path listed in hook_pack_wrapped_paths before any
# override runs, so listing a deferred script undoes the deferral on the
# next launch. The generator and the activator cannot run headlessly (they
# need the vanilla corpus and a mounted pack), so this drives the subset
# helper and the persist step, then checks in the built source that both
# call sites go through the helper. Both drift guards fail loudly.
func _t10_persisted_wrapped_paths_exclude_deferred() -> void:
	_assert(_ml.has_method("_eager_wrapped_paths"),
			"T10: the loader must expose _eager_wrapped_paths(paths) -- the eager subset "
			+ "the persist step writes; a script error here would skip every assertion below")
	if not _ml.has_method("_eager_wrapped_paths"):
		return
	_reset_user_state()
	_ml._scripts_with_scene_preloads.clear()
	_ml._scripts_with_scene_preloads["res://Scripts/Deferred.gd"] = ["res://Scenes/X.tscn"]
	var all_paths: Array[String] = ["res://Scripts/Menu.gd", "res://Scripts/Deferred.gd", "res://Scripts/AI.gd"]
	var eager: PackedStringArray = _ml._eager_wrapped_paths(all_paths)
	_assert(eager == PackedStringArray(["res://Scripts/Menu.gd", "res://Scripts/AI.gd"]),
			"T10: the eager subset drops the deferred script and keeps order (got %s)" % str(eager))
	_ml._persist_hook_pack_state("user://modloader_hooks/framework_pack_1.zip", eager)
	var cfg := ConfigFile.new()
	_assert(cfg.load(_pass_state_path) == OK, "T10: _persist_hook_pack_state wrote pass state")
	var wrapped: PackedStringArray = _ml._state_paths(cfg, "hook_pack_wrapped_paths")
	_assert(wrapped.has("res://Scripts/Menu.gd") and not wrapped.has("res://Scripts/Deferred.gd"),
			"T10: the persisted list holds the eager scripts and not the deferred one (got %s)" % str(wrapped))
	_ml._scripts_with_scene_preloads.clear()
	_reset_user_state()

	var src := FileAccess.get_file_as_string(MODLOADER_PATH)
	if src.is_empty():
		_fail("T10: could not read " + MODLOADER_PATH + " as text")
		return
	var call_lines := 0
	for line in src.split("\n"):
		if not line.contains("_persist_hook_pack_state(") or line.contains("func _persist_hook_pack_state("):
			continue
		call_lines += 1
		_assert(line.contains("_eager_wrapped_paths("),
				"T10: a _persist_hook_pack_state call passes a path list that did not go "
				+ "through _eager_wrapped_paths: " + line.strip_edges())
	_assert(call_lines >= 2,
			"T10: expected the deferred-activation and activation call sites of "
			+ "_persist_hook_pack_state in the built loader, found %d -- re-anchor this test" % call_lines)

# --- T11: state that nothing reads is removed ------------------------------

# Restore points under user://.modpack_backups and the [settings]
# preferred_author key have no reader or writer, and a profile snapshot slot
# can hold an overrides/ tree and a manifest beside MCM/. Each is removed by
# code that runs anyway: the Pass 1 sweep, the next config save, and the
# slot delete when a profile goes.
func _t11_removed_feature_state_is_swept() -> void:
	_reset_user_state()
	_assert(_ml.has_method("_remove_retired_state"),
			"T11: the loader must expose _remove_retired_state(), the Pass 1 sweep")
	if _ml.has_method("_remove_retired_state"):
		_write_file("user://.modpack_backups/pack_1/profile.json", "{}")
		_ml._remove_retired_state()
		_assert(not DirAccess.dir_exists_absolute(ProjectSettings.globalize_path("user://.modpack_backups")),
				"T11: the Pass 1 sweep removes user://.modpack_backups")

	var cfg_path := str(_ml.UI_CONFIG_PATH)
	var cfg := ConfigFile.new()
	cfg.set_value("settings", "preferred_author", "someone")
	cfg.set_value("settings", "active_profile", "Default")
	cfg.set_value("profile.Default.enabled", "kept@1", true)
	_assert(cfg.save(cfg_path) == OK, "T11: seeded mod_config.cfg")
	_ml._save_ui_config()
	var again := ConfigFile.new()
	_assert(again.load(cfg_path) == OK, "T11: mod_config.cfg reloads after the save")
	_assert(not again.has_section_key("settings", "preferred_author"),
			"T11: the next config save drops [settings] preferred_author")
	_assert(again.has_section_key("profile.Default.enabled", "kept@1"),
			"T11: the save keeps a stored profile key with no live entry")

	_write_file("user://.profile_snapshots/p/MCM/a.ini", "[a]\n")
	_write_file("user://.profile_snapshots/p/overrides/b.txt", "b")
	_write_file("user://.profile_snapshots/p/overrides_manifest.json", "{}")
	_ml._delete_mcm_snapshot("p")
	_assert(not DirAccess.dir_exists_absolute(ProjectSettings.globalize_path("user://.profile_snapshots/p")),
			"T11: deleting a snapshot slot removes the files beside MCM/ too")
	_reset_user_state()

func _write_file(path: String, text: String) -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(path.get_base_dir()))
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		_fail("harness could not write " + path)
		return
	f.store_string(text)
	f.close()

func _crashed_launch() -> void:
	_next_launch_boot()
	_arm_two_pass_restart()
	_write_dirty_marker()

# Steps (a) and (b): what every fresh launch does before it decides anything.
func _next_launch_boot() -> void:
	if FileAccess.file_exists(_pass2_dirty_path):
		_fire_dirty_marker_wipe()
	_ml._check_crash_recovery()

# Step (c).
func _arm_two_pass_restart() -> void:
	_ml._write_heartbeat()
	_count_restart_attempt()

# Just the counting half of step (c). T2 uses this instead of the whole arm
# because _write_heartbeat's file ALREADY survives _static_force_vanilla_state
# and carries a wall-clock timestamp: including it would make T2's snapshot
# comparison pass on a second boundary rather than on a surviving counter.
func _count_restart_attempt() -> void:
	var paths := PackedStringArray(["user://harness_fixture_mod.zip"])
	_ml._write_pass_state(paths, FIXTURE_HASH)

# Step (d) -- mirrors the top of _run_pass_2 byte for byte in behavior.
func _write_dirty_marker() -> void:
	var f := FileAccess.open(_pass2_dirty_path, FileAccess.WRITE)
	if f == null:
		_fail("harness could not write the pass-2 dirty marker at " + _pass2_dirty_path)
		return
	f.store_string(str(Time.get_unix_time_from_system()))
	f.close()

# The real wipe, as static init fires it on a crashed Pass 2.
func _fire_dirty_marker_wipe() -> void:
	var log_lines: PackedStringArray = []
	# A GDScript instance dispatches static functions too, so the instance
	# route is the reliable one; the script route is the fallback in case a
	# future refactor moves the wipe onto the script only.
	if _ml.has_method("_static_force_vanilla_state"):
		_ml.call("_static_force_vanilla_state", "pass 2 crashed mid-run", log_lines)
	else:
		_ml_script.call("_static_force_vanilla_state", "pass 2 crashed mid-run", log_lines)

# What every finish path does once a launch actually completes: Pass 2 clears
# the dirty marker at its end, and all three finish paths delete the heartbeat
# and clear the restart counter.
func _clean_finish() -> void:
	if FileAccess.file_exists(_pass2_dirty_path):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(_pass2_dirty_path))
	_ml._delete_heartbeat()
	_ml._clear_restart_counter()

# --- Breaker binding ---------------------------------------------------------

func _resolve_breaker() -> void:
	for n in PREDICATE_NAMES:
		if _ml.has_method(n):
			_breaker_kind = "predicate"
			_breaker_name = n
			return
	for n in STREAK_NAMES:
		if _ml.has_method(n):
			_breaker_kind = "streak"
			_breaker_name = n
			return

func _breaker_tripped() -> bool:
	if _breaker_kind == "predicate":
		return bool(_ml.call(_breaker_name))
	if _breaker_kind == "streak":
		return int(_ml.call(_breaker_name)) >= _max_restarts
	return false

func _missing_breaker(label: String) -> void:
	_fail(label + ": the loader exposes no way to ask whether the two-pass restart "
			+ "must be refused. Add a zero-arg method named one of "
			+ str(PREDICATE_NAMES) + " (returning true once the crash streak "
			+ "reaches MAX_RESTART_COUNT), or a streak reader named one of "
			+ str(STREAK_NAMES) + ". Nothing in the tree answers that question "
			+ "today, which is precisely why the loop cannot be broken.")

# --- user:// snapshot + reset ------------------------------------------------

# The throwaway project's own user:// is this harness's scratch space; nothing
# else writes there. Reset it between tests so each one starts from a pristine
# machine. Godot's own logs/ dir is left alone (the engine holds it open).
func _reset_user_state() -> void:
	_wipe_dir(ProjectSettings.globalize_path("user://"), "")

func _wipe_dir(abs_dir: String, rel: String) -> void:
	var d := DirAccess.open(abs_dir)
	if d == null:
		return
	var entries: PackedStringArray = []
	d.list_dir_begin()
	while true:
		var e := d.get_next()
		if e == "":
			break
		if e == "." or e == "..":
			continue
		entries.append(e)
	d.list_dir_end()
	for e in entries:
		var child_rel: String = e if rel == "" else rel + "/" + e
		if child_rel == "logs":
			continue
		var child_abs: String = abs_dir.path_join(e)
		if DirAccess.dir_exists_absolute(child_abs):
			_wipe_dir(child_abs, child_rel)
		DirAccess.remove_absolute(child_abs)

func _snapshot_user() -> Dictionary:
	var out: Dictionary = {}
	_snapshot_dir(ProjectSettings.globalize_path("user://"), "", out)
	return out

func _snapshot_dir(abs_dir: String, rel: String, out: Dictionary) -> void:
	var d := DirAccess.open(abs_dir)
	if d == null:
		return
	var entries: PackedStringArray = []
	d.list_dir_begin()
	while true:
		var e := d.get_next()
		if e == "":
			break
		if e == "." or e == "..":
			continue
		entries.append(e)
	d.list_dir_end()
	for e in entries:
		var child_rel: String = e if rel == "" else rel + "/" + e
		if child_rel == "logs":
			continue
		var child_abs: String = abs_dir.path_join(e)
		if DirAccess.dir_exists_absolute(child_abs):
			out[child_rel + "/"] = "<dir>"
			_snapshot_dir(child_abs, child_rel, out)
		else:
			var bytes := FileAccess.get_file_as_bytes(child_abs)
			out[child_rel] = "%d:%s" % [bytes.size(), Marshalls.raw_to_base64(bytes)]

# user:// path -> the key _snapshot_user would file it under.
func _rel_user(user_path: String) -> String:
	return user_path.trim_prefix("user://")

func _describe(snap: Dictionary) -> String:
	if snap.is_empty():
		return "(nothing persisted)"
	var names: Array = snap.keys()
	names.sort()
	return str(names)

# --- Reporting ---------------------------------------------------------------

func _assert(cond: bool, msg: String) -> void:
	_assertions += 1
	if not cond:
		_failures.append(msg)

func _fail(msg: String) -> void:
	_failures.append(msg)

# Delete the override.cfg the breaker path creates next to the Godot binary.
# _run refuses to start when one already exists, so anything here is ours.
func _cleanup_exe_cfg() -> void:
	if _exe_cfg_path.is_empty():
		return
	for p in [_exe_cfg_path, _exe_cfg_path + ".old", _exe_cfg_path + ".tmp"]:
		if FileAccess.file_exists(p):
			DirAccess.remove_absolute(p)
			print("[boot-state] cleaned up harness-created " + p)

func _finish() -> void:
	_cleanup_exe_cfg()
	if _failures.is_empty():
		print("[boot-state] PASS: %d assertion(s) across T1..T22" % _assertions)
		quit(0)
		return
	for m in _failures:
		printerr("[boot-state] FAIL: " + m)
	printerr("[boot-state] FAILED: %d of %d assertion(s)" % [_failures.size(), _assertions])
	printerr("[boot-state] NOTE: W4.2 is an OPEN backlog item and this harness was")
	printerr("[boot-state]       written test-first against the invariant, not against")
	printerr("[boot-state]       today's behavior. Failures here are expected until the")
	printerr("[boot-state]       crash-loop breaker is fixed. The harness is not broken.")
	quit(1)
