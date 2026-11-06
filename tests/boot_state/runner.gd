## Boot-state and crash-loop-breaker harness, run by check_boot_state.sh.
## Does not run _run_pass_1/_run_pass_2; T6, T32, T33, T35 read their call order in the built source.
extends "res://runner_base.gd"

# Recorded by _write_pass_state only; nothing is mounted.
const FIXTURE_HASH := "boot-state-harness-fixture-hash"
const T39_DIR := "res://Scripts/"
const T39_SOURCES := {
	"T39Hooked.gd": "extends Node\nfunc Jump(a):\n\treturn a\n\n@rpc(\"any_peer\")\nfunc Sync(x):\n\treturn x\n\nfunc Rest(...args):\n\tpass\n\nstatic func Helper():\n\tpass\n",
	"T39Rpc.gd": "extends Node\n@rpc(\"any_peer\")\nfunc Sync(x):\n\treturn x\n",
	"T39Typo.gd": "extends Node\nfunc Jump():\n\tpass\n",
	"T39Excluded.gd": "extends Node\nfunc Jump():\n\tpass\n",
	"T39Deferred.gd": "extends Node\nvar room = preload(\"res://T39/Room.tscn\")\nfunc Open():\n\tpass\n",
	"Database.gd": "extends Node\nfunc _ready():\n\tpass\n",
	"Compiler.gd": "extends Node\nfunc Spawn():\n\tpass\n",
}

var _ml: Object
var _max := 0
var _state_path := ""
var _dirty_path := ""
var _heartbeat_path := ""
# override.cfg beside the Godot binary: the breaker path creates it, _finish removes it.
var _exe_cfg := ""
var _built: PackedStringArray = []

func _init() -> void:
	super("boot-state", "T1..T50")

func _run() -> void:
	_ml = boot_loader()
	if _ml == null:
		_finish()
		return
	var exe_cfg := OS.get_executable_path().get_base_dir().path_join("override.cfg")
	if FileAccess.file_exists(exe_cfg):
		_fail("refusing to run: %s exists, and _restore_clean_override_cfg and _reset_override_cfg"
				% exe_cfg + " rewrite it; move it aside or point GODOT at another binary")
		_finish()
		return
	_exe_cfg = exe_cfg
	begin("T1")
	_t1_preconditions()
	if _report.ok():
		for t in [_t2_streak_survives_wipe, _t3_one_crash_no_trip, _t4_max_crashes_trip, _t5_clean_finish_resets,
				_t6_pass2_clear_order, _t7_hook_status, _t8_pass_state_coerces, _t9_overrides_kept,
				_t10_eager_wrapped_paths, _t11_retired_state_swept, _t12_game_update_via_pck,
				_t13_missing_cfg_recovers, _t14_hash_follows_order, _t15_hash_unquoted_version,
				_t16_early_hooks_survive, _t17_modlib_meta_once, _t18_pack_failures_shown,
				_t19_wrap_surface, _t20_lost_target_declarers, _t21_cfg_write_failure,
				_t22_remove_tree_links, _t23_unmodded_cleanup, _t24_aispawner_deferred,
				_t25_scene_remap_mount, _t26_pack_has_no_mod_scripts, _t27_probe_verdicts_persist,
				_t28_blank_cfg_recovers, _t29_no_pack_forgets_pack, _t30_skip_ui_flag,
				_t31_update_keeps_mounts, _t32_restart_dirty_at_init, _t33_streak_after_reload,
				_t34_force_vanilla_early, _t35_crash_notice, _t36_hook_pack_sweeps,
				_t37_dynamic_override_targets, _t38_rewrite_detection, _t39_pack_records_scripts,
				_t40_deferred_watchdog, _t41_compile_proof, _t42_pck_v4_warning, _t43_lost_target_causes,
				_t44_trip_at_max, _t45_pack_path_sane, _t46_deleted_folder_mod, _t47_stale_cache_sweep,
				_t48_deferred_probe, _t49_banner_more, _t50_menu_hook_seed, _t51_streak_banner_launch,
				_t52_partial_registry_banner]:
			begin(str(t.get_method()).get_slice("_", 1).to_upper())
			t.call()
	_finish()

func _finish() -> void:
	if _exe_cfg != "":
		for p in [_exe_cfg, _exe_cfg + ".old", _exe_cfg + ".tmp"]:
			if FileAccess.file_exists(p):
				DirAccess.remove_absolute(p)
				print("[boot-state] cleaned up harness-created " + p)
	super()

func _t1_preconditions() -> void:
	var consts: Dictionary = _ml.get_script().get_script_constant_map()
	for c in ["MAX_RESTART_COUNT", "PASS_STATE_PATH", "PASS2_DIRTY_PATH", "HEARTBEAT_PATH",
			"HOOK_PACK_DIR", "HOOK_PACK_PREFIX", "VANILLA_CACHE_DIR", "MODLOADER_VERSION"]:
		_assert(consts.has(c), "constants.gd defines %s" % c)
	if not _report.ok():
		return
	_max = int(consts["MAX_RESTART_COUNT"])
	_state_path = str(consts["PASS_STATE_PATH"])
	_dirty_path = str(consts["PASS2_DIRTY_PATH"])
	_heartbeat_path = str(consts["HEARTBEAT_PATH"])
	# Below 2, "one crash does not trip" and "MAX crashes trip" are one case.
	_assert(_max >= 2, "MAX_RESTART_COUNT is at least 2 (got %d)" % _max)
	for f in ["_write_pass_state", "_write_heartbeat", "_delete_heartbeat", "_check_crash_recovery",
			"_clear_restart_counter", "_static_force_vanilla_state", "_crash_breaker_tripped"]:
		_assert(_ml.has_method(f), "the loader has %s()" % f)

# Wherever the streak lives, the dirty-marker wipe must not erase it. The
# heartbeat is left out: it survives the wipe anyway and is no count.
func _t2_streak_survives_wipe() -> void:
	var state_key := _state_path.trim_prefix("user://")
	H.wipe_user()
	_count_attempt()
	_assert(H.snapshot_user().has(state_key), "_write_pass_state writes pass state")
	_wipe()
	var after_one := H.snapshot_user()
	_assert(not after_one.has(state_key), "the wipe deletes pass state")
	H.wipe_user()
	for i in 2:
		_count_attempt()
		_wipe()
	var after_two := H.snapshot_user()
	_assert(after_one != after_two, "two crashes leave other state than one: %s | %s"
			% [str(after_one.keys()), str(after_two.keys())])

func _t3_one_crash_no_trip() -> void:
	H.wipe_user()
	_crashed_launch()
	_assert(FileAccess.file_exists(_heartbeat_path), "a crashed launch leaves the heartbeat")
	_next_launch_boot()
	_assert(not bool(_ml._crash_breaker_tripped()), "one crash does not trip the breaker")

func _t4_max_crashes_trip() -> void:
	H.wipe_user()
	for i in _max:
		_crashed_launch()
	_next_launch_boot()
	_assert(bool(_ml._crash_breaker_tripped()), "%d crashes trip the breaker" % _max)
	# Every crashed launch fires the wipe; a trip it erased would re-arm the loop.
	_wipe()
	_assert(bool(_ml._crash_breaker_tripped()), "the trip survives the dirty-marker wipe")

# A clean finish resets the streak to zero, not minus one.
func _t5_clean_finish_resets() -> void:
	H.wipe_user()
	for i in _max:
		_crashed_launch()
	_next_launch_boot()
	H.remove_user_file(_dirty_path)
	_ml._delete_heartbeat()
	_ml._clear_restart_counter()
	_assert(not bool(_ml._crash_breaker_tripped()), "a clean finish clears the breaker")
	for i in _max - 1:
		_crashed_launch()
	_next_launch_boot()
	_assert(not bool(_ml._crash_breaker_tripped()), "a clean finish resets the streak to zero")

# Pass 2 clears the streak through _finish_boot (T33), after load_all_mods.
func _t6_pass2_clear_order() -> void:
	var body := _function_body("func _run_pass_2(")
	if body.is_empty():
		return
	var i_load := _first_line(body, "load_all_mods(")
	var i_clear := _first_line(body, "_clear_restart_counter(")
	if not _assert(i_load >= 0, "_run_pass_2 calls load_all_mods()"):
		return
	_assert(i_clear < 0 or i_clear > i_load, "streak cleared (line %d) before load (line %d)" % [i_clear + 1, i_load + 1])
	_assert(_first_line(body, "_finish_boot(") > i_load, "_finish_boot comes after load_all_mods()")

# The record pack generation leaves is how the launcher learns hooks broke.
func _t7_hook_status() -> void:
	var status_path := str(_ml.HOOK_STATUS_PATH)
	H.remove_user_file(status_path)
	_assert(_ml._hook_status_problem().is_empty(), "no record, nothing to show")
	_ml._hook_status_write({"state": "all_failed", "attempted": 12, "ok": 0})
	var problem: Dictionary = _ml._hook_status_problem()
	_assert(_is_error(problem, "12"), "all-failed is an error naming the count (got %s)" % str(problem))
	_ml._hook_status_write({"state": "critical_failed", "attempted": 12, "ok": 9,
			"critical_failures": ["res://Scripts/Controller.gd", "res://Scripts/Camera.gd"]})
	var text := str(_ml._hook_status_problem().get("text", ""))
	_assert(text.contains("Controller.gd") and text.contains("Camera.gd"), "a critical failure names the scripts")
	_ml._hook_status_write({"state": "unsupported_gdsc", "gdsc_version": 102})
	_assert(_is_error(_ml._hook_status_problem(), "v102"), "an unsupported format names the version")
	# A loader update may have fixed it; an exe change means another game build.
	var exe_mtime := FileAccess.get_modified_time(OS.get_executable_path())
	for c in [["0.0.0", exe_mtime, "another loader version"], [str(_ml.MODLOADER_VERSION), 12345, "another game build"]]:
		H.write_text(status_path, JSON.stringify({"state": "all_failed", "attempted": 3, "loader_version": c[0],
				"exe_mtime": c[1]}))
		_assert(_ml._hook_status_problem().is_empty(), "a record from %s is ignored" % c[2])
	# A hand-edited record missing its state's key shows 0 or an empty list.
	for c in [["unsupported_gdsc", "(v0)"], ["all_failed", "none of the loader's 0 script"],
			["critical_failed", "hooks did not work on . "], ["demoted", "changes to  do not fit"]]:
		H.write_text(status_path, JSON.stringify({"state": c[0], "loader_version": str(_ml.MODLOADER_VERSION),
				"exe_mtime": exe_mtime, "critical_failures": "x", "demoted": 7}))
		_assert(_is_error(_ml._hook_status_problem(), c[1]), "%s without its key still shows" % c[0])
	H.write_text(status_path, JSON.stringify({"state": "ok", "loader_version": str(_ml.MODLOADER_VERSION),
			"exe_mtime": exe_mtime, "lost": "x"}))
	_assert(_ml._hook_status_problem().is_empty(), "a non-list lost shows nothing")
	_ml._hook_status_write({"state": "ok", "attempted": 5, "ok": 5})
	_assert(_ml._hook_status_problem().is_empty(), "nothing to show after a healthy activation")
	H.remove_user_file(status_path)

# Pass state is hand-editable and half-written by crashes; a raise inside
# static init could not be caught, so every read coerces.
func _t8_pass_state_coerces() -> void:
	var cfg := ConfigFile.new()
	cfg.set_value("state", "modloader_version", 3.31)
	cfg.set_value("state", "exe_mtime", "1699999999")
	cfg.set_value("state", "restart_count", null)
	cfg.set_value("state", "archive_paths", "just/one/path.zip")
	cfg.set_value("state", "hook_pack_wrapped_paths", ["res://Scripts/A.gd", 7, "res://Scripts/B.gd"])
	check_eq(str(_ml._state_str(cfg, "modloader_version", "")), "", "a numeric version reads as default")
	check_eq(int(_ml._state_int(cfg, "exe_mtime", 0)), 1699999999, "an integer written as text")
	check_eq(int(_ml._state_int(cfg, "restart_count", 0)), 0, "a null count")
	_assert(_ml._state_paths(cfg, "archive_paths").is_empty(), "a non-array path list reads empty")
	var wrapped: PackedStringArray = _ml._state_paths(cfg, "hook_pack_wrapped_paths")
	_assert(wrapped.size() == 2 and wrapped[0] == "res://Scripts/A.gd", "an untyped array keeps only its strings")
	_assert(int(_ml._state_int(cfg, "absent", 42)) == 42 and str(_ml._state_str(cfg, "absent", "d")) == "d",
			"missing keys read as their defaults")

# Pass 2 fills the map before load_all_mods; the hook pack reads it after.
func _t9_overrides_kept() -> void:
	_ml._applied_script_overrides["res://Scripts/Menu.gd"] = true
	_ml.load_all_mods("Pass 2")
	_assert(_ml._applied_script_overrides.has("res://Scripts/Menu.gd"), "load_all_mods keeps _applied_script_overrides")
	_ml._applied_script_overrides.clear()

# Static init force-compiles every persisted wrapped path, which would undo
# the lazy compile of a script with a module-scope scene preload.
func _t10_eager_wrapped_paths() -> void:
	if not _assert(_ml.has_method("_eager_wrapped_paths"), "the loader has _eager_wrapped_paths"):
		return
	H.wipe_user()
	_ml._scripts_with_scene_preloads.clear()
	_ml._scripts_with_scene_preloads["res://Scripts/Deferred.gd"] = ["res://Scenes/X.tscn"]
	var all_paths: Array[String] = ["res://Scripts/Menu.gd", "res://Scripts/Deferred.gd", "res://Scripts/AI.gd"]
	var eager: PackedStringArray = _ml._eager_wrapped_paths(all_paths)
	check_eq(eager, PackedStringArray(["res://Scripts/Menu.gd", "res://Scripts/AI.gd"]), "the eager subset, in order")
	_ml._persist_hook_pack_state("user://modloader_hooks/framework_pack_1.zip", eager)
	var cfg := ConfigFile.new()
	_assert(cfg.load(_state_path) == OK, "_persist_hook_pack_state wrote pass state")
	var wrapped: PackedStringArray = _ml._state_paths(cfg, "hook_pack_wrapped_paths")
	_assert(wrapped.has("res://Scripts/Menu.gd") and not wrapped.has("res://Scripts/Deferred.gd"),
			"the persisted list leaves deferred out (got %s)" % str(wrapped))
	_ml._scripts_with_scene_preloads.clear()
	H.wipe_user()
	var calls := 0
	for line in _source():
		if line.contains("_persist_hook_pack_state(") and not line.contains("func _persist_hook_pack_state("):
			calls += 1
			_assert(line.contains("_eager_wrapped_paths("), "call skips _eager_wrapped_paths: " + line.strip_edges())
	_assert(calls >= 2, "two _persist_hook_pack_state call sites (found %d)" % calls)

# Retired state goes through code that runs anyway: the Pass 1 sweep, the
# next config save, the snapshot slot delete.
func _t11_retired_state_swept() -> void:
	H.wipe_user()
	if _assert(_ml.has_method("_remove_retired_state"), "the loader has _remove_retired_state"):
		_write_file("user://.modpack_backups/pack_1/profile.json", "{}")
		_ml._remove_retired_state()
		_assert(not DirAccess.dir_exists_absolute(ProjectSettings.globalize_path("user://.modpack_backups")),
				"the Pass 1 sweep removes .modpack_backups")
	var cfg_path := str(_ml.UI_CONFIG_PATH)
	var cfg := ConfigFile.new()
	cfg.set_value("settings", "preferred_author", "someone")
	cfg.set_value("settings", "active_profile", "Default")
	cfg.set_value("profile.Default.enabled", "kept@1", true)
	_assert(cfg.save(cfg_path) == OK, "seeded mod_config.cfg")
	_ml._save_ui_config()
	var again := ConfigFile.new()
	_assert(again.load(cfg_path) == OK, "mod_config.cfg reloads after the save")
	_assert(not again.has_section_key("settings", "preferred_author"), "the save drops preferred_author")
	_assert(again.has_section_key("profile.Default.enabled", "kept@1"), "the save keeps a key with no entry")
	for f in ["MCM/a.ini", "overrides/b.txt", "overrides_manifest.json"]:
		_write_file("user://.profile_snapshots/p/" + f, "x")
	_ml._delete_mcm_snapshot("p")
	_assert(not DirAccess.dir_exists_absolute(ProjectSettings.globalize_path("user://.profile_snapshots/p")),
			"a slot delete removes files beside MCM/")
	H.wipe_user()

# A content patch can replace the PCK and leave the executable alone.
func _t12_game_update_via_pck() -> void:
	for m in ["_static_game_build_changed", "_static_game_pck_stamp", "_game_pck_stamp"]:
		if not _assert(_ml.has_method(m), "the loader has %s" % m):
			return
	var cfg := ConfigFile.new()
	cfg.set_value("state", "exe_mtime", 100)
	cfg.set_value("state", "pck_stamp", "200:3000")
	var older := ConfigFile.new()
	older.set_value("state", "exe_mtime", 100)
	for c in [[cfg, 100, "200:3000", false, "the same executable and PCK"],
			[cfg, 101, "200:3000", true, "a moved executable mtime"], [cfg, 100, "201:3000", true, "a moved PCK mtime"],
			[cfg, 100, "200:3001", true, "a resized PCK"], [cfg, 100, "", false, "no PCK beside the executable"],
			[older, 100, "200:3000", false, "pass state with no stamp"],
			[ConfigFile.new(), 100, "200:3000", false, "empty pass state"]]:
		check_eq(bool(_ml._static_game_build_changed(c[0], c[1], c[2])), c[3], "%s reads as changed" % c[4])
	var pck := "user://harness_game.pck"
	_write_file(pck, "first build")
	_ml.set("_game_pck_path_override", ProjectSettings.globalize_path(pck))
	var stamp := str(_ml._game_pck_stamp())
	_assert(stamp != "", "an existing PCK has a stamp")
	_count_attempt()
	var state := ConfigFile.new()
	_assert(state.load(_state_path) == OK and str(state.get_value("state", "pck_stamp", "")) == stamp,
			"_write_pass_state records the PCK stamp")
	_ml._hook_status_write({"state": "all_failed", "attempted": 4, "ok": 0})
	_assert(not _ml._hook_status_problem().is_empty(), "a failure record from this PCK shows")
	_write_file(pck, "second build, a different size")
	_assert(_ml._hook_status_problem().is_empty(), "a record from another PCK is ignored")
	_ml.set("_game_pck_path_override", "")
	for p in [str(_ml.HOOK_STATUS_PATH), pck, _state_path, str(_ml.CRASH_STREAK_PATH)]:
		H.remove_user_file(p)

# The Pass 1 scan persists mod sources before the config loads; with the
# live file missing that write would make the next save roll over the backup.
func _t13_missing_cfg_recovers() -> void:
	H.wipe_user()
	var cfg_path := str(_ml.UI_CONFIG_PATH)
	_assert(_profiles_backup().save(cfg_path + ".bak") == OK, "wrote the backup")
	_assert(not FileAccess.file_exists(cfg_path), "the live config is missing")
	var entries := _source_entries()
	_ml._persist_mod_sources_for_entries(entries)
	_assert(not FileAccess.file_exists(cfg_path), "the persist waits for the backup recovery")
	var empty: Array[Dictionary] = []
	_ml.set("_ui_mod_entries", empty)
	_ml._load_ui_config()
	check_eq(str(_ml.get("_active_profile")), "Hardcore", "the recovered active profile")
	var profiles: Array = _ml._list_profiles()
	_assert(profiles.has("Default") and profiles.has("Hardcore"), "every profile is back (got %s)" % str(profiles))
	var bak := ConfigFile.new()
	_assert(bak.load(cfg_path + ".bak") == OK and bak.has_section("profile.Hardcore.priority"),
			"the backup still holds the profiles")
	H.wipe_user()
	_ml._persist_mod_sources_for_entries(entries)
	_assert(FileAccess.file_exists(cfg_path), "with no backup the persist creates it")
	H.wipe_user()

# Mount order decides which mod wins a shared file, so it is in the hash.
func _t14_hash_follows_order() -> void:
	H.wipe_user()
	_write_file("user://hash_a.zip", "a")
	_write_file("user://hash_b.zip", "b")
	var a := ProjectSettings.globalize_path("user://hash_a.zip")
	var b := ProjectSettings.globalize_path("user://hash_b.zip")
	var none: Array[Dictionary] = []
	_ml.set("_ui_mod_entries", none)
	var ab := str(_ml._compute_state_hash(PackedStringArray([a, b]), none))
	var ba := str(_ml._compute_state_hash(PackedStringArray([b, a]), none))
	_assert(ab != "" and ba != "", "an archive list hashes to something")
	check_eq(str(_ml._compute_state_hash(PackedStringArray([a, b]), none)), ab, "the same order's hash")
	_assert(ab != ba, "another load order hashes differently")
	check_eq(str(_ml._compute_state_hash(PackedStringArray(), none)), "", "the hash of nothing to mount")
	H.wipe_user()

# ConfigFile reads an unquoted version=1.5 as a float.
func _t15_hash_unquoted_version() -> void:
	H.wipe_user()
	_write_file("user://hash_a.zip", "a")
	var a := ProjectSettings.globalize_path("user://hash_a.zip")
	var none: Array[Dictionary] = []
	var unquoted := ConfigFile.new()
	unquoted.parse("[mod]\nname=\"M\"\nid=\"m\"\nversion=1.5\n")
	_assert(typeof(unquoted.get_value("mod", "version")) == TYPE_FLOAT, "the fixture version arrives as a float")
	var newer := ConfigFile.new()
	newer.parse("[mod]\nname=\"M\"\nid=\"m\"\nversion=1.6\n")
	var entries: Array[Dictionary] = [{"enabled": true, "mod_id": "m", "cfg": unquoted}]
	_ml.set("_ui_mod_entries", entries)
	var h15: Variant = _ml._compute_state_hash(PackedStringArray([a]), none)
	_assert(h15 is String and str(h15) != "", "an unquoted version hashes (got %s)" % str(h15))
	entries[0]["cfg"] = newer
	var h16: Variant = _ml._compute_state_hash(PackedStringArray([a]), none)
	_assert(h16 is String and str(h16) != str(h15), "the unquoted version is in the hash")
	_ml.set("_ui_mod_entries", none)
	H.wipe_user()

# A "!" early autoload hooks before load_all_mods runs; add_hook() also
# enrolls the path in the wrap mask pack generation reads afterwards.
func _t16_early_hooks_survive() -> void:
	var cb := func(): pass
	var hook_id: int = _ml.add_hook("Controller.gd", "Jump", cb, true)
	_assert(hook_id > 0, "add_hook registers (got %d)" % hook_id)
	_assert(bool(_ml.has_hooks("controller-jump-pre")), "registered under the native name")
	var none: Array[Dictionary] = []
	_ml.set("_ui_mod_entries", none)
	_ml.load_all_mods("Pass 2")
	_assert(bool(_ml.has_hooks("controller-jump-pre")), "the callback survives load_all_mods")
	var mask: Dictionary = _ml.get("_hooked_methods")
	_assert(mask.has("res://Scripts/Controller.gd") and (mask["res://Scripts/Controller.gd"] as Dictionary).has("jump"),
			"the wrap mask survives load_all_mods (got %s)" % str(mask))
	_ml.unhook(hook_id)
	mask.erase("res://Scripts/Controller.gd")

func _t17_modlib_meta_once() -> void:
	if Engine.has_meta("RTVModLib"):
		Engine.remove_meta("RTVModLib")
	var lines: Array = _ml.get("_report_lines")
	var complained := func() -> bool: return lines.any(func(l): return str(l).contains("already set"))
	lines.clear()
	_ml._register_rtv_modlib_meta()
	_assert(Engine.has_meta("RTVModLib") and Engine.get_meta("RTVModLib") == _ml, "the loader registers itself")
	_ml._register_rtv_modlib_meta()
	_assert(not complained.call(), "registering again is silent")
	var stranger := RefCounted.new()
	Engine.set_meta("RTVModLib", stranger)
	_ml._register_rtv_modlib_meta()
	_assert(complained.call() and Engine.get_meta("RTVModLib") == stranger, "another object is reported, left alone")
	Engine.remove_meta("RTVModLib")
	lines.clear()

# Without its own record a failed pack leaves the last healthy one in place.
func _t18_pack_failures_shown() -> void:
	if not _assert("HOOK_STATE_PACK_FAILED" in _ml, "the loader has HOOK_STATE_PACK_FAILED"):
		return
	var healthy := {"state": "ok", "attempted": 5, "ok": 5}
	var no_paths: Array[String] = []
	_ml._hook_status_write(healthy.duplicate())
	var packed: Array[String] = []
	var wrote: int = _ml._hook_pack_write_zip("user://no_such_dir/framework_pack_1.zip", no_paths, {}, {}, {}, packed)
	check_eq(wrote, -1, "a zip that cannot be created")
	var problem: Dictionary = _ml._hook_status_problem()
	_assert(_is_error(problem, "hook pack"), "an unwritable pack is an error (got %s)" % str(problem))
	_ml._hook_status_write(healthy.duplicate())
	_assert(_ml._hook_status_problem().is_empty(), "a healthy record shows nothing")
	var wrapped: Array[String] = ["res://Scripts/Controller.gd"]
	check_eq(str(_ml._hook_pack_mount_and_activate("user://framework_pack_missing.zip", wrapped, 4, {}, false)), "",
			"the path an unmountable pack returns")
	problem = _ml._hook_status_problem()
	_assert(_is_error(problem, "hook pack"), "an unmountable pack is an error (got %s)" % str(problem))
	H.remove_user_file(str(_ml.HOOK_STATUS_PATH))

# A registry target a mod also hooks by method is widened to the whole
# script, counted once, and its ledger names both declarations.
func _t19_wrap_surface() -> void:
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
	var needed := {}
	var mask := {}
	var ledger: Dictionary = _ml._hook_pack_wrap_surface(scripts, needed, mask)
	# Controller and Menu by method, Database both ways, five more by [registry].
	check_eq(needed.size(), 8, "scripts in the wrap surface")
	var surface := ""
	for line in lines:
		if str(line).contains("Wrap surface:"):
			surface = str(line)
	_assert(surface.contains("8 vanilla script(s) declared (3 via [hooks]/.hook(), 5 more via [registry])"),
			"a script declared both ways counts once (got '%s')" % surface)
	_assert((mask.get("res://Scripts/Database.gd", {"x": true}) as Dictionary).is_empty(),
			"a hooked registry target is widened")
	_assert((mask.get("res://Scripts/Controller.gd", {}) as Dictionary).has("jump"), "a method-only script keeps its mask")
	check_eq(str(ledger.get("res://Scripts/Database.gd", {}).get("declared", "")), "[hooks]+[registry]",
			"the ledger's declarations for both")
	check_eq(str(ledger.get("res://Scripts/Loader.gd", {}).get("declared", "")), "[registry]",
			"the ledger's registry-only declaration")
	# The pack-time marker check alone notices a transform that no-oped.
	var markers: Dictionary = _ml.get("REGISTRY_EXPECTED_MARKERS")
	for rt in _ml.REGISTRY_TARGETS:
		_assert(str(markers.get(rt, "")) != "", "%s has a REGISTRY_EXPECTED_MARKERS entry" % str(rt))
	hooked.clear()
	_ml.set("_any_mod_declared_registry", false)
	lines.clear()

# A registry target has no [hooks] declarer: the [registry] mods are named.
func _t20_lost_target_declarers() -> void:
	if not _assert("_registry_declared_by" in _ml, "the loader has _registry_declared_by"):
		return
	var by: Dictionary = _ml.get("_registry_declared_by")
	by.clear()
	by["Loot Overhaul"] = true
	_ml.set("_any_mod_declared_registry", true)
	var label := str(_ml._hook_declarers_label("res://Scripts/Loader.gd"))
	_assert(label.contains("Loot Overhaul") and not label.contains("add_hook"),
			"a registry target names [registry] mods (got '%s')" % label)
	_assert(str(_ml._hook_declarers_label("res://Scripts/Controller.gd")).contains("add_hook"),
			"an undeclared path is attributed to add_hook")
	_assert(str(_ml._hook_declarers_label("res://Scripts/Menu.gd")).contains("the mod loader itself"),
			"the core Menu.gd wrap is the loader's")
	by.clear()
	_ml.set("_any_mod_declared_registry", false)

# A read-only or locked game folder is only diagnosable with step and code.
func _t21_cfg_write_failure() -> void:
	if not _assert("_static_cfg_write_error" in _ml, "the loader has _static_cfg_write_error"):
		return
	var good := ProjectSettings.globalize_path("user://t21_override.cfg")
	_assert(bool(_ml._static_write_cfg_atomic(good, "[autoload]\n")), "a write into user:// succeeds")
	check_eq(str(_ml.get("_static_cfg_write_error")), "", "the error text after a success")
	var bad := ProjectSettings.globalize_path("user://t21_no_such_dir/override.cfg")
	_assert(not bool(_ml._static_write_cfg_atomic(bad, "[autoload]\n")), "a write into a missing folder fails")
	var why := str(_ml.get("_static_cfg_write_error"))
	_assert(why.contains("override.cfg.tmp") and why.contains("error "), "the failure names step and code (got '%s')" % why)
	DirAccess.remove_absolute(good)

# The user:// check in _remove_tree is on the path's text; a link inside
# the tree points elsewhere and only the link may go.
func _t22_remove_tree_links() -> void:
	var outside := ProjectSettings.globalize_path("user://t22_outside")
	var tree := ProjectSettings.globalize_path("user://t22_tree")
	_write_file("user://t22_outside/keep.txt", "keep")
	_write_file("user://t22_tree/own.txt", "own")
	var linked := _make_link(outside, tree.path_join("link"))
	_ml._remove_tree("user://t22_tree", false)
	_assert(not DirAccess.dir_exists_absolute(tree), "the tree itself is removed")
	if linked:
		_assert(FileAccess.file_exists("user://t22_outside/keep.txt"), "a file behind a link survives")
	else:
		print("[boot-state] T22: this platform would not create a link; the link case was not exercised")
	var root_link := ProjectSettings.globalize_path("user://t22_root_link")
	_write_file("user://t22_outside/sub/keep.txt", "keep")
	if _make_link(outside, root_link):
		_ml._remove_tree(root_link.path_join("sub"), false)
		_assert(FileAccess.file_exists("user://t22_outside/sub/keep.txt"), "a linked ancestor is not traversed")
		_ml._remove_tree(root_link, true)
		_assert(FileAccess.file_exists("user://t22_outside/keep.txt"), "keeping a linked root keeps its target")
		_ml._remove_tree(root_link, false)
		_assert(FileAccess.file_exists("user://t22_outside/keep.txt"), "removing a linked root keeps its target")
		_assert(not DirAccess.open("user://").is_link(root_link), "removing a linked root removes the link")
	_ml._remove_tree("user://t22_outside", false)
	var exe_side := ProjectSettings.globalize_path("res://t22_must_survive")
	DirAccess.make_dir_recursive_absolute(exe_side)
	_ml._remove_tree(exe_side, false)
	_assert(DirAccess.dir_exists_absolute(exe_side), "a folder outside user:// is refused")
	DirAccess.remove_absolute(exe_side)
	_write_file("user://t22_canary.txt", "x")
	_ml._remove_tree("user://", false)
	_assert(FileAccess.file_exists("user://t22_canary.txt"), "user:// itself is refused")
	H.remove_user_file("user://t22_canary.txt")
	_write_file("user://t22_keep/sub/f.txt", "x")
	_ml._remove_tree("user://t22_keep", true)
	_assert(DirAccess.dir_exists_absolute(ProjectSettings.globalize_path("user://t22_keep"))
			and not DirAccess.dir_exists_absolute(ProjectSettings.globalize_path("user://t22_keep/sub")),
			"keep_root empties the folder, keeps it")
	_ml._remove_tree("user://t22_keep", false)

# Cleanup reports a failure before the caller can restart into stale state.
func _t23_unmodded_cleanup() -> void:
	if not _assert(_ml.has_method("_clear_unmodded_boot_state"), "the loader has _clear_unmodded_boot_state"):
		return
	var state := "user://t23_state"
	var cfg_path := "user://t23_override.cfg"
	var original := "[autoload_prepend]\nOldMod=\"*res://old.gd\"\n[rendering]\nrenderer/rendering_method=\"gl_compatibility\"\n"
	_write_file(state + "/keep", "keep")
	_write_file(cfg_path, original)
	var error := str(_ml._clear_unmodded_boot_state(state, cfg_path))
	_assert(error.contains("Cannot remove") and error.contains("t23_state"), "a failed state delete names its path")
	check_eq(FileAccess.get_file_as_string(cfg_path), original, "override.cfg after a failed state delete")
	DirAccess.remove_absolute(state + "/keep")
	DirAccess.remove_absolute(state)
	_write_file(state, "old state")
	error = str(_ml._clear_unmodded_boot_state(state, "user://t23_missing_dir/override.cfg"))
	_assert(error.contains("override.cfg") and error.contains("Cannot write"), "a failed override cleanup blocks too")
	error = str(_ml._clear_unmodded_boot_state(state, cfg_path))
	_assert(error.is_empty() and not FileAccess.file_exists(state), "a retry after the fix succeeds")
	var cleaned := ConfigFile.new()
	_assert(cleaned.load(cfg_path) == OK and not cleaned.has_section_key("autoload_prepend", "OldMod"),
			"cleanup removes old mod autoloads")
	check_eq(str(cleaned.get_value("rendering", "renderer/rendering_method", "")), "gl_compatibility",
			"the unrelated rendering setting")
	DirAccess.remove_absolute(cfg_path)

# Registry targets compile eagerly because mods write their injected fields;
# AISpawner.gd stays deferred: its preloads are the AI scenes baking AI.gd.
func _t24_aispawner_deferred() -> void:
	var scenes := PackedStringArray(["res://AI/Bandit/AI_Bandit.tscn"])
	_assert(bool(_ml._defers_scene_preloads("Door.gd", scenes)), "a script with a scene preload defers")
	_assert(not bool(_ml._defers_scene_preloads("Door.gd", PackedStringArray())), "no scene preload, no deferral")
	_assert(bool(_ml._defers_scene_preloads("AISpawner.gd", scenes)), "AISpawner.gd defers despite being a target")
	for rt in _ml.REGISTRY_TARGETS:
		if str(rt) != "AISpawner.gd":
			_assert(not bool(_ml._defers_scene_preloads(str(rt), scenes)), "registry target %s compiles eagerly" % str(rt))
	var src := "extends Node3D\nvar bandit = preload(\"res://AI/Bandit/AI_Bandit.tscn\")\nfunc f():\n\tvar x = preload(\"res://AI/Guard/AI_Guard.tscn\")\n"
	var found: PackedStringArray = _ml._collect_module_scope_scene_preloads(src)
	_assert(found.size() == 1 and found[0] == "res://AI/Bandit/AI_Bandit.tscn",
			"only the module-scope preload is collected (got %s)" % str(found))

# Loading a remap target at mount time caches the scene's scripts before the
# hook pack mounts, so their deferred rewrites never lazy-compile.
func _t25_scene_remap_mount() -> void:
	var zip_abs := H.write_zip("user://t25_remap.zip", {
		"T25Mod/Thing.gd": "extends Node\n",
		"T25Mod/Room.tscn": "[gd_scene load_steps=2 format=3]\n\n[ext_resource type=\"Script\" path=\"res://T25Mod/Thing.gd\" id=\"1\"]\n\n[node name=\"ModRoom\" type=\"Node\"]\nscript = ExtResource(\"1\")\n",
		"T25Vanilla/Room.tscn.remap": "[remap]\n\npath=\"res://T25Mod/Room.tscn\"\n",
	}, _report)
	_assert(FileAccess.file_exists(zip_abs), "wrote the fixture zip")
	_assert(bool(_ml._try_mount_pack(zip_abs)), "the fixture archive mounts")
	_assert(not ResourceLoader.has_cached("res://T25Mod/Thing.gd"), "mounting compiled no referenced script")
	_assert(ResourceLoader.exists("res://T25Vanilla/Room.tscn"), "the remapped path exists")
	var room := load("res://T25Vanilla/Room.tscn") as PackedScene
	if _assert(room != null, "the remapped path loads"):
		var node := room.instantiate()
		check_eq(str(node.name), "ModRoom", "the scene the remapped path serves")
		node.free()
	DirAccess.remove_absolute(zip_abs)

# A mod's code runs from its own archive as shipped.
func _t26_pack_has_no_mod_scripts() -> void:
	_ml.set("_archive_file_sets", {"t26_mod.zip": {"res://T26Mod/Main.gd": true}})
	var pack_rel := "user://t26_pack.zip"
	var packed: Array[String] = []
	var none: Array[String] = []
	check_eq(int(_ml._hook_pack_write_zip(pack_rel, none, {}, {}, {}, packed)), 0, "hooks in a pack with nothing to wrap")
	var zr := ZIPReader.new()
	_assert(zr.open(ProjectSettings.globalize_path(pack_rel)) == OK, "the pack opens")
	var entries := zr.get_files()
	zr.close()
	check_eq(entries, PackedStringArray(["__modloader_canary__.txt"]), "the pack's entries")
	(_ml.get("_archive_file_sets") as Dictionary).clear()
	DirAccess.remove_absolute(ProjectSettings.globalize_path(pack_rel))

# Only Pass 1 may probe (its process exits right after); later generations
# repeat its verdicts or they would pack the rewrite it found broken.
func _t27_probe_verdicts_persist() -> void:
	var ai := "res://Scripts/AI.gd"
	var spawner := "res://Scripts/AISpawner.gd"
	var state_abs := ProjectSettings.globalize_path(_state_path)
	DirAccess.remove_absolute(state_abs)
	_ml.set("_hook_pack_demotions", {ai: "excluded"})
	_ml._hook_pack_begin_vetting(false)
	_assert(bool(_ml.get("_hook_pack_vetting")), "with no pass state the generation probes")
	_assert((_ml.get("_hook_pack_demotions") as Dictionary).is_empty(), "a probing generation starts with no verdicts")
	_ml.set("_hook_pack_demotions", {ai: "wrap_only", spawner: "excluded"})
	_ml._persist_hook_pack_state("user://modloader_hooks/framework_pack_27.zip", PackedStringArray())
	_ml.set("_hook_pack_demotions", {})
	_ml._hook_pack_begin_vetting(false)
	var got: Dictionary = _ml.get("_hook_pack_demotions")
	_assert(not bool(_ml.get("_hook_pack_vetting")), "the generation after a vetted one skips probing")
	_assert(str(got.get(ai, "")) == "wrap_only" and str(got.get(spawner, "")) == "excluded",
			"verdicts read back from pass state (got %s)" % str(got))

	# A registry only the injected code reads refuses instead of a false success.
	_assert(not bool(_ml._register_ai_type("t27_type", {"scene": PackedScene.new(), "zone": "Area05"})),
			"ai_types refuses with AISpawner.gd demoted")
	_assert(not bool(_ml._register_ai_loadout("t27_loadout", {})), "ai_loadouts refuses with AI.gd demoted")
	# shelters and maps hang on Compiler.gd's Spawn prelude; Loader.gd is a
	# healthy stand-in, handed over by a subclass (the loader is not in a tree).
	var place := "user://t27_place.tscn"
	var place_root := Node.new()
	var packed := PackedScene.new()
	packed.pack(place_root)
	place_root.free()
	ResourceSaver.save(packed, place)
	var ldr_script := GDScript.new()
	ldr_script.source_code = "extends Node\nvar shelters: Array = []\nvar _rtv_mod_shelters := {}\nvar _rtv_mod_scene_paths := {}\nvar _rtv_override_scene_paths := {}\n"
	ldr_script.reload()
	var ldr := Node.new()
	ldr.set_script(ldr_script)
	var sub_script := GDScript.new()
	sub_script.source_code = "extends \"%s\"\nvar t27_loader: Node\nfunc _loader_node() -> Node:\n\treturn t27_loader\n" % MODLOADER_PATH
	_assert(sub_script.reload() == OK, "the stand-in Loader subclass compiles")
	var sub: Object = sub_script.new()
	sub.set("t27_loader", ldr)
	_assert(bool(sub._register_shelter("t27_kept", {"path": place})), "a shelter registers with Compiler.gd whole")
	sub.set("_hook_pack_demotions", {"res://Scripts/Compiler.gd": "wrap_only"})
	_assert(not bool(sub._register_shelter("t27_place", {"path": place})), "shelters refuses with Compiler.gd demoted")
	_assert(not bool(sub._register_map("t27_area", {"path": place})), "maps refuses with Compiler.gd demoted")
	var scene_paths: Dictionary = sub.get("_registry_registered").get("scene_paths", {})
	for refused in ["t27_place", "t27_area"]:
		_assert(not scene_paths.has(refused) and not (ldr.get("_rtv_mod_scene_paths") as Dictionary).has(refused)
				and not (ldr.get("shelters") as Array).has(refused),
				"refused '%s' left nothing (scene_paths %s)" % [refused, str(scene_paths.keys())])
	_assert(bool(sub._remove_shelter("t27_kept")) and not (ldr.get("shelters") as Array).has("t27_kept"),
			"an earlier shelter is still removable")
	sub.free()
	ldr.free()
	DirAccess.remove_absolute(ProjectSettings.globalize_path(place))

	_ml._hook_status_write({"state": str(_ml.HOOK_STATE_DEMOTED), "attempted": 5, "ok": 5, "demoted": got.keys()})
	var problem: Dictionary = _ml._hook_status_problem()
	_assert(_is_error(problem, "AI.gd"), "a demotion is an error naming it (got %s)" % str(problem))

	# Nothing packed at all: the verdicts still reach the next generation.
	DirAccess.remove_absolute(state_abs)
	_ml.set("_hook_pack_demotions", {ai: "excluded"})
	var nothing: Array[String] = []
	_ml._hook_pack_mount_and_activate("user://modloader_hooks/framework_pack_27b.zip", nothing, 0, {}, true)
	_ml.set("_hook_pack_demotions", {})
	_ml._hook_pack_begin_vetting(false)
	_assert(not bool(_ml.get("_hook_pack_vetting"))
			and str((_ml.get("_hook_pack_demotions") as Dictionary).get(ai, "")) == "excluded",
			"with every rewrite out, verdicts persist")
	_assert(str(_ml._hook_status_problem().get("text", "")).contains("AI.gd"), "with every rewrite out, the launcher knows")
	_ml._hook_pack_begin_vetting(true)
	_assert(bool(_ml.get("_hook_pack_vetting")) and (_ml.get("_hook_pack_demotions") as Dictionary).is_empty(),
			"Pass 1 probes afresh")
	DirAccess.remove_absolute(state_abs)
	_ml._hook_status_write({"state": "ok", "attempted": 0})

# Godot loads a blank file as OK with no sections; read as a fresh install it
# would end with a near-empty file rolled over the backup.
func _t28_blank_cfg_recovers() -> void:
	var cfg_path := str(_ml.UI_CONFIG_PATH)
	var bak_path := cfg_path + ".bak"
	var good := _profiles_backup()
	var entries := _source_entries()
	var empty: Array[Dictionary] = []
	for blank in ["", "\n\n; cut short\n"]:
		begin("T28 empty file" if blank == "" else "T28 comment-only file")
		H.wipe_user()
		_assert(good.save(bak_path) == OK, "wrote the backup")
		_write_file(cfg_path, blank)
		_ml._persist_mod_sources_for_entries(entries)
		check_eq(FileAccess.get_file_as_string(cfg_path), blank, "the blank config after the persist")
		_ml.set("_ui_mod_entries", empty)
		_ml._load_ui_config()
		check_eq(str(_ml.get("_active_profile")), "Hardcore", "the recovered active profile")
		var profiles: Array = _ml._list_profiles()
		_assert(profiles.has("Default") and profiles.has("Hardcore"), "every profile is back (got %s)" % str(profiles))
		_assert(FileAccess.file_exists(cfg_path + ".corrupt"), "the blank file is kept as .corrupt")
	begin("T28")
	H.wipe_user()
	_assert(good.save(bak_path) == OK, "wrote the backup for the writer case")
	_write_file(cfg_path, "")
	_ml.set("_active_profile", "Hardcore")
	_ml._delete_active_profile()
	check_eq(FileAccess.get_file_as_string(cfg_path), "", "the blank config after a profile edit")
	var kept := ConfigFile.new()
	_assert(kept.load(bak_path) == OK and kept.has_section("profile.Hardcore.priority"), "the backup keeps every profile")
	H.wipe_user()
	_assert(good.save(bak_path) == OK, "wrote the backup again")
	_write_file(cfg_path, "")
	var partial := ConfigFile.new()
	partial.set_value("settings", "developer_mode", true)
	_ml._persist_ui_cfg(partial)
	var bak := ConfigFile.new()
	_assert(bak.load(bak_path) == OK and bak.has_section("profile.Hardcore.priority"),
			"saving over a blank config spares the backup")
	_assert(_ml._load_ui_cfg_for_write() != null, "writes proceed once the file has content")
	H.wipe_user()
	_write_file(cfg_path, "")
	_ml._persist_mod_sources_for_entries(entries)
	var fresh := ConfigFile.new()
	_assert(fresh.load(cfg_path) == OK and fresh.has_section("mod_sources"), "with no backup a blank config is fresh")
	H.wipe_user()

# A pack still named after the last hook mod is disabled would mount over the
# enabled mods every launch and shadow their own copies of its scripts.
func _t29_no_pack_forgets_pack() -> void:
	H.wipe_user()
	var seeded := ConfigFile.new()
	seeded.set_value("state", "mods_hash", "abc")
	seeded.set_value("state", "hook_pack_path", "user://modloader_hooks/framework_pack_9.zip")
	seeded.set_value("state", "hook_pack_wrapped_paths", PackedStringArray(["res://Scripts/Interface.gd"]))
	_assert(seeded.save(_state_path) == OK, "seeded pass state")
	_ml.set("_loaded_mod_ids", {})
	check_eq(str(_ml._generate_hook_pack(true)), "", "the pack built with no mod.txt mod")
	var after := ConfigFile.new()
	_assert(after.load(_state_path) == OK, "pass state is still readable")
	_assert(str(after.get_value("state", "hook_pack_path", "x")) == ""
			and (after.get_value("state", "hook_pack_wrapped_paths", PackedStringArray(["x"])) as PackedStringArray).is_empty(),
			"the old pack is no longer named (got '%s')" % str(after.get_value("state", "hook_pack_path", "")))
	check_eq(str(after.get_value("state", "mods_hash", "")), "abc", "the rest of pass state")
	H.wipe_user()
	_ml._generate_hook_pack(true)
	_assert(not FileAccess.file_exists(_state_path), "no pass state, no pack, none created")
	H.wipe_user()

# Godot hands an unknown argument to get_cmdline_args(), one after "--" to
# get_cmdline_user_args(); a Steam launch writes a one-shot file instead.
func _t30_skip_ui_flag() -> void:
	var none := PackedStringArray()
	check_eq(str(_ml.SKIP_UI_ARG), "--modloader-skip-ui", "the flag")
	for c in [[["--rendering-driver", "vulkan"], ["--modloader-restart"], false, "an ordinary command line"],
			[["--modloader-skip-ui"], [], true, "the flag before --"],
			[[], ["--modloader-restart", "--modloader-skip-ui"], true, "the flag after --"]]:
		check_eq(bool(_ml._launcher_skipped(PackedStringArray(c[0]), PackedStringArray(c[1]))), c[2], "%s skips" % c[3])
	var once := OS.get_executable_path().get_base_dir().path_join(str(_ml.SKIP_UI_ONCE_FILE))
	_assert(not FileAccess.file_exists(once), "no skip file beside the engine yet")
	check_eq(str(_ml._launcher_skip_reason()), "", "the reason with neither flag nor file")
	_assert(H.write_text(once, ""), "wrote the skip file")
	check_eq(str(_ml._launcher_skip_reason()), "modloader_skip_ui_once", "the reason with the skip file")
	_assert(not FileAccess.file_exists(once), "the skip file is consumed")
	check_eq(str(_ml._launcher_skip_reason()), "", "the reason on the launch after")
	H.write_text(once, "")
	_assert(bool(_ml._consume_skip_ui_once()) and not FileAccess.file_exists(once), "consuming the skip file deletes it")
	_assert(not bool(_ml._consume_skip_ui_once()), "no skip file, nothing to consume")
	var reason := _function_body("func _launcher_skip_reason(")
	var i_consume := _first_line(reason, "_consume_skip_ui_once()")
	_assert(i_consume >= 0 and i_consume < _first_line(reason, "_launcher_skipped("), "the file is consumed before the flag")
	var ready := _function_body("func _ready(")
	var i_off := _first_line(ready, "_is_modloader_disabled()")
	var i_used := _first_line(ready, "_consume_skip_ui_once()", i_off)
	var i_return := -1
	for i in range(maxi(i_off, 0), ready.size()):
		if ready[i].begins_with("\t\treturn"):
			i_return = i
			break
	_assert(i_off >= 0 and i_used >= 0 and i_used < i_return, "a disabled launch consumes it before idling")
	if FileAccess.file_exists(once):
		DirAccess.remove_absolute(once)

# override.cfg is read before static init, so last session's "!" autoloads
# run whatever it decides: an update must still mount their archives.
func _t31_update_keeps_mounts() -> void:
	var stale := ProjectSettings.globalize_path(str(_ml.HOOK_PACK_DIR)).path_join(str(_ml.HOOK_PACK_PREFIX) + "stale.zip")
	for c in [["loader version change", "0.0.0-harness", "a", "Version mismatch: saved=0.0.0-harness"],
			["game update", str(_ml.MODLOADER_VERSION), "b", "Game build changed -- dropping"]]:
		begin("T31 %s" % c[0])
		H.wipe_user()
		var zip := H.write_zip("user://t31_mod_%s.zip" % c[2], {"t31_marker_%s/hello.txt" % c[2]: c[2]}, _report)
		var cfg := ConfigFile.new()
		cfg.set_value("state", "modloader_version", c[1])
		cfg.set_value("state", "archive_paths", PackedStringArray([zip]))
		cfg.set_value("state", "mods_hash", FIXTURE_HASH)
		if c[2] == "a":
			_write_file(stale, "x")
		else:
			cfg.set_value("state", "exe_mtime", 1)
		_assert(cfg.save(_state_path) == OK, "seeded pass state")
		var mounted: Variant = _ml.call("_mount_previous_session")
		_assert(mounted is Dictionary and (mounted as Dictionary).has(zip), "the archives still mount (got %s)" % str(mounted))
		_assert(FileAccess.file_exists("res://t31_marker_%s/hello.txt" % c[2]), "the archive's files are reachable")
		_assert(not FileAccess.file_exists(_state_path), "pass state is discarded for a rebuild")
		if c[2] == "a":
			_assert(not FileAccess.file_exists(stale), "the stale hook pack is wiped")
		var fs_log := FileAccess.get_file_as_string("user://modloader_filescope.log")
		_assert(fs_log.contains(c[3]), "the log names the drop cause")
		_assert(fs_log.contains("hook pack skipped (stale)"), "the log says the pack was skipped")
	H.wipe_user()

# A mod that crashes an autoload never reaches _run_pass_2; without the
# marker from static init the next plain launch would loop unseen.
func _t32_restart_dirty_at_init() -> void:
	H.wipe_user()
	if not _assert(_ml.has_method("_static_mark_pass2_entered"), "the loader has _static_mark_pass2_entered"):
		return
	_ml.call("_static_mark_pass2_entered", PackedStringArray(["--other", "--modloader-restart"]))
	_assert(FileAccess.file_exists(_dirty_path), "a restart launch writes the dirty marker")
	H.wipe_user()
	_ml.call("_static_mark_pass2_entered", PackedStringArray(["--other"]))
	_assert(not FileAccess.file_exists(_dirty_path), "a plain launch writes no dirty marker")
	var body := _function_body("static func _mount_previous_session(")
	if body.is_empty():
		return
	var i_mark := _first_line(body, "_static_mark_pass2_entered(")
	var i_archives := _first_line(body, "_static_mount_archives(")
	var i_pack := _first_line(body, "_static_mount_hook_pack(")
	var i_dirty_check := _first_line(body, "PASS2_DIRTY_PATH")
	var i_state_load := -1
	for i in body.size():
		if body[i].contains("PASS_STATE_PATH") and body[i].contains("load("):
			i_state_load = i
			break
	_assert(i_mark >= 0 and i_archives > i_mark and i_pack > i_archives,
			"marker, archives, pack: lines %d, %d, %d" % [i_mark + 1, i_archives + 1, i_pack + 1])
	for direct in ["load_resource_pack(", "_try_mount_pack("]:
		var i_direct := _first_line(body, direct)
		_assert(i_direct < 0 or i_direct > i_mark, "%s (line %d) before the marker (line %d)" % [direct, i_direct + 1, i_mark + 1])
	_assert(_first_line(_function_body("static func _static_mount_archives("), "_try_mount_pack(") >= 0,
			"_static_mount_archives mounts through _try_mount_pack")
	_assert(_first_line(_function_body("static func _static_mount_hook_pack("), "load_resource_pack(") >= 0,
			"_static_mount_hook_pack calls load_resource_pack")
	# After the crash check reads it, or every restart reads as a crash.
	_assert(i_dirty_check >= 0 and i_mark > i_dirty_check,
			"marker line %d after crash check line %d" % [i_mark + 1, i_dirty_check + 1])
	_assert(i_state_load >= 0 and i_mark > i_state_load,
			"marker line %d after pass state read line %d" % [i_mark + 1, i_state_load + 1])
	H.wipe_user()

# reload_current_scene instantiates the main scene, hooked _init and mod
# scenes included: a crash there must still count.
func _t33_streak_after_reload() -> void:
	var body := _function_body("func _finish_boot(")
	if body.is_empty():
		return
	var i_reload := _first_line(body, "reload_current_scene(")
	var i_clear := _first_line(body, "_clear_restart_counter(")
	var i_heartbeat := _first_line(body, "_delete_heartbeat(")
	_assert(i_reload >= 0 and i_clear >= 0 and i_heartbeat >= 0,
			"reload, clear, heartbeat at lines %d, %d, %d" % [i_reload + 1, i_clear + 1, i_heartbeat + 1])
	_assert(i_clear > i_reload and i_heartbeat > i_reload,
			"clear %d, heartbeat %d after reload %d" % [i_clear + 1, i_heartbeat + 1, i_reload + 1])

# Godot read override.cfg before the wipe, so the extracted early autoloads
# must go too. An executable mtime of 0 is a stat failure, not an update.
func _t34_force_vanilla_early() -> void:
	H.wipe_user()
	var boot := str(_ml.EARLY_AUTOLOAD_DIR).path_join("SomeMod/Boot.gd")
	_write_file(boot, "extends Node\n")
	_ml._static_force_vanilla_state("T34", PackedStringArray())
	_assert(not FileAccess.file_exists(boot), "the wipe removes the early autoloads")
	var cfg := ConfigFile.new()
	cfg.set_value("state", "exe_mtime", 100)
	cfg.set_value("state", "pck_stamp", "200:3000")
	_assert(not bool(_ml._static_game_build_changed(cfg, 0, "200:3000")), "an mtime of 0 is no update")
	H.wipe_user()

# The streak count, and a tripped breaker's notice, reach the next launcher.
func _t35_crash_notice() -> void:
	H.wipe_user()
	if not _assert(_ml.has_method("_crash_notice_problem"), "the loader has _crash_notice_problem"):
		return
	_assert(_ml._crash_notice_problem(false).is_empty(), "no streak, no notice")
	_ml._static_write_crash_streak(2)
	var problem: Dictionary = _ml._crash_notice_problem(false)
	_assert(str(problem.get("text", "")).contains("last 2 launch"), "a streak of two names the count (got %s)" % str(problem))
	_assert(str(problem.get("text", "")).contains("loads mods in a single pass"), "the streak says mods still load")
	# The breaker trips after the launcher closed: that branch leaves the notice.
	var body := _function_body("func _run_pass_1(")
	var i_trip := _first_line(body, "_crash_breaker_tripped()")
	var i_notice := _first_line(body, "_write_crash_breaker_notice(", i_trip) if i_trip >= 0 else -1
	_assert(i_trip >= 0 and i_notice > i_trip, "breaker branch line %d writes notice line %d" % [i_trip + 1, i_notice + 1])
	_ml._static_write_crash_streak(0)
	_ml._write_crash_breaker_notice(2)
	problem = _ml._crash_notice_problem(true)
	_assert(str(problem.get("text", "")).contains("loaded mods in a single pass"),
			"the notice says mods still loaded (got %s)" % str(problem))
	_assert(not str(problem.get("text", "")).contains("without"), "the notice never says mods were off")
	_assert(_ml._crash_notice_problem(false).is_empty(), "the notice is consumed once shown")
	H.wipe_user()

# Windows cannot delete a mounted pack, so static init sweeps the older ones
# first; the wipe removes them all and the vanilla cache.
func _t36_hook_pack_sweeps() -> void:
	H.wipe_user()
	var pack_dir := str(_ml.HOOK_PACK_DIR)
	var prefix := str(_ml.HOOK_PACK_PREFIX)
	var keep := pack_dir.path_join(prefix + "_2.zip")
	var orphan := pack_dir.path_join(prefix + "_1.zip")
	var other := pack_dir.path_join("notes.txt")
	var vanilla := str(_ml.VANILLA_CACHE_DIR).path_join("Scripts/T36.gd")
	var legacy := pack_dir.path_join("FrameworkFoo.gd")
	for p in [keep, orphan, other, vanilla, legacy]:
		_write_file(p, "x")
	var log_lines := PackedStringArray()
	_ml._static_cleanup_orphan_hook_packs(keep, log_lines)
	_assert(FileAccess.file_exists(keep), "the sweep keeps the current pack")
	_assert(not FileAccess.file_exists(orphan), "the sweep deletes an older pack")
	_assert(FileAccess.file_exists(other), "the sweep leaves a non-pack file alone")
	_assert("\n".join(log_lines).contains("Cleaned 1 orphan hook pack"), "the sweep logs its count (got %s)" % str(log_lines))
	_assert(FileAccess.file_exists(legacy), "the orphan sweep leaves Framework*.gd")
	_ml._static_wipe_hook_cache()
	_assert(not FileAccess.file_exists(legacy), "the wipe deletes a loose Framework*.gd")
	_assert(not FileAccess.file_exists(keep), "the wipe deletes the current pack too")
	_assert(not FileAccess.file_exists(vanilla), "the wipe removes the vanilla cache")
	_assert(FileAccess.file_exists(other), "the wipe leaves a non-pack file alone")
	# The pack preflight sweeps Framework*.gd too, but keeps every pack zip.
	for p in [keep, legacy]:
		_write_file(p, "x")
	var mod_ids: Dictionary = _ml._loaded_mod_ids.duplicate()
	_ml._loaded_mod_ids.clear()
	check_eq(str(_ml._pack_preflight()), "", "preflight with no mod loaded")
	_ml._loaded_mod_ids.merge(mod_ids)
	_assert(not FileAccess.file_exists(legacy), "the preflight deletes a loose Framework*.gd")
	_assert(FileAccess.file_exists(keep), "the preflight keeps the pack zip")
	H.remove_user_file(str(_ml.HOOK_STATUS_PATH))
	H.wipe_user()

# A Godot 4.7 .pck fails to mount; the warning names the exporter and the .zip way out.
func _t42_pck_v4_warning() -> void:
	var dir := ProjectSettings.globalize_path("user://t42")
	DirAccess.make_dir_recursive_absolute(dir)
	for c in [[4, 7, true], [3, 6, false]]:
		var path := dir.path_join("v%d.pck" % c[0])
		var f := FileAccess.open(path, FileAccess.WRITE)
		for v in [0x43504447, c[0], 4, c[1], 0, 0, 0, 0]:
			f.store_32(v)
		f.close()
		var why := str(_ml._pck_v4_warning(path))
		_assert((why.contains("Godot 4.7") and why.contains(".zip")) == c[2], "v%d pck warning (got %s)" % [c[0], why])
	_assert(not bool(_ml._try_mount_pack(dir.path_join("v4.pck"))), "a v4 pck does not mount")
	var body := _function_body("static func _try_mount_pack(")
	_assert(_first_line(body, "_pck_v4_warning(") >= 0, "a failed mount checks for v4")
	_ml._remove_tree("user://t42", false)

func _t37_dynamic_override_targets() -> void:
	var analysis: Dictionary = _ml.get("_mod_script_analysis")
	analysis.clear()
	analysis["A"] = {"uses_dynamic_override": true, "extends_paths": ["res://Scripts/Controller.gd"]}
	analysis["B"] = {"uses_dynamic_override": false, "extends_paths": ["res://Scripts/Camera.gd"]}
	analysis["C"] = {"uses_dynamic_override": true, "extends_paths": []}
	check_eq(_ml._dynamic_override_targets(), {"A": ["res://Scripts/Controller.gd"]}, "take_over_path mods with a target")
	analysis.clear()

# A rewrite that failed to compile still loads with its source; only a
# renamed vanilla method in the method list proves a rewrite.
func _t38_rewrite_detection() -> void:
	var plain := GDScript.new()
	plain.source_code = "extends Node\nfunc Jump():\n\tpass\n"
	_assert(plain.reload() == OK, "the plain fixture compiles")
	var rewritten := GDScript.new()
	rewritten.source_code = "extends Node\nfunc _rtv_vanilla_Jump():\n\tpass\nfunc Jump():\n\t_rtv_vanilla_Jump()\n"
	_assert(rewritten.reload() == OK, "the rewritten fixture compiles")
	_assert(not bool(_ml._static_script_has_rewrite(plain)), "no _rtv_vanilla_ method, no rewrite")
	_assert(bool(_ml._static_script_has_rewrite(rewritten)), "a _rtv_vanilla_ method is a rewrite")
	for c in [[[{"name": "Jump"}, {"name": "_rtv_vanilla_Jump"}], true, "a renamed method"],
			[[{"name": "Jump"}, {"name": "rtv_vanilla_Jump"}], false, "a near-miss prefix"],
			[[], false, "an empty method list"]]:
		check_eq(bool(_ml._static_method_list_has_rewrite(c[0])), c[1], "%s reads as a rewrite" % c[2])
	var node := Node.new()
	node.set_script(rewritten)
	_assert(bool(_ml._static_method_list_has_rewrite(node.get_method_list())), "a live rewritten node reads rewritten")
	node.free()

# One _hook_pack_write_zip run reaching every branch of its per-script loop;
# the plain-text scripts are read through the VFS (no game PCK here).
func _t39_pack_records_scripts() -> void:
	H.wipe_user()
	for n in T39_SOURCES:
		_write_file(T39_DIR + n, T39_SOURCES[n])
	H.reset_pck_state(_ml)
	_ml.set("_game_pck_path_override", "")
	_ml.set("_hook_pack_vetting", false)
	_ml.set("_hook_pack_demotions", {T39_DIR + "T39Excluded.gd": "excluded", T39_DIR + "Compiler.gd": "wrap_only"})
	_ml.set("_any_mod_declared_registry", true)
	_ml.set("_developer_mode", true)
	var deferred: Dictionary = _ml.get("_scripts_with_scene_preloads")
	deferred.clear()
	var zero: Dictionary = _ml.get("_pck_zero_byte_paths")
	zero.clear()
	zero[T39_DIR + "T39Empty.gd"] = true
	var overrides: Dictionary = _ml.get("_override_registry")
	overrides[T39_DIR + "T39Hooked.gd"] = [{"mod_name": "T39 Replacer"}]
	var lines: Array = _ml.get("_report_lines")
	lines.clear()

	var order := ["Mine.gd", "ItemData.gd", "T39Empty.gd", "T39Unneeded.gd", "T39NoSource.gd", "T39Hooked.gd",
			"T39Rpc.gd", "T39Typo.gd", "T39Excluded.gd", "T39Deferred.gd", "Database.gd", "Compiler.gd"]
	var masks := {
		"Mine.gd": ["explode"], "ItemData.gd": ["get"], "T39Empty.gd": ["x"], "T39NoSource.gd": ["x"],
		"T39Hooked.gd": ["jump", "sync", "rest", "missingone"], "T39Rpc.gd": ["sync"], "T39Typo.gd": ["jumpp"],
		"T39Excluded.gd": ["jump"], "T39Deferred.gd": ["open"], "Database.gd": [], "Compiler.gd": [],
	}
	var paths: Array[String] = []
	var needed := {}
	var mask := {}
	var ledger := {}
	for n in order:
		var p: String = T39_DIR + n
		paths.append(p)
		if masks.has(n):
			needed[p] = true
			var m := {}
			for k in masks[n]:
				m[k] = true
			mask[p] = m
			ledger[p] = _ledger_row("[hooks]/.hook()", masks[n])
	ledger[T39_DIR + "Database.gd"] = _ledger_row("[hooks]+[registry]", [])
	ledger[T39_DIR + "Database.gd"]["declared_methods"] = ["_ready", "Gone"]
	ledger[T39_DIR + "Compiler.gd"] = _ledger_row("[registry]", [])

	var pack_rel := "user://t39_pack.zip"
	var packed: Array[String] = []
	var hooks: int = int(_ml._hook_pack_write_zip(pack_rel, paths, needed, mask, ledger, packed))
	var text := "\n".join(lines)
	check_eq(hooks, 16, "hook points of four wrapped methods")
	check_eq(PackedStringArray(packed), PackedStringArray([T39_DIR + "T39Hooked.gd", T39_DIR + "T39Deferred.gd",
			T39_DIR + "Database.gd", T39_DIR + "Compiler.gd"]), "the packed scripts in order")
	var want_lost := {
		"Mine.gd": "on the runtime-sensitive skip list",
		"ItemData.gd": "a save-data/resource-data class",
		"T39Empty.gd": "zero-byte file",
		"T39NoSource.gd": "detokenizer produced no source",
		"T39Rpc.gd": "declared method(s) cannot be wrapped: sync (the method is an @rpc, which cannot be wrapped)",
		"T39Typo.gd": "declared method(s) [\"jumpp\"] not found in the vanilla script",
		"T39Excluded.gd": "does not compile against this game build; left unmodified",
	}
	for n in want_lost:
		var rec: Dictionary = ledger[T39_DIR + n]
		_assert(str(rec["status"]) == "lost" and str(rec["detail"]).contains(want_lost[n]),
				"%s is lost with its reason (got %s: %s)" % [n, rec["status"], rec["detail"]])
		check_eq(rec["missing"], n == "T39Typo.gd", "%s counts as missing" % n)
	for c in [["declares hooks on Mine.gd, but that script is excluded from rewriting (runtime-sensitive skip list)",
			"a hook on a runtime-sensitive script warns"],
			["declares hooks on ItemData.gd, but data/save resource classes are excluded from rewriting",
			"a hook on a data class warns"]]:
		_assert(text.contains(c[0]), c[1])
	_assert(text.contains("Skipped 1 zero-byte PCK entry(ies)") and text.contains("Surface-skipped 1 vanilla script(s)"),
			"zero-byte and surface skips counted once each")

	var hooked: Dictionary = ledger[T39_DIR + "T39Hooked.gd"]
	_assert(str(hooked["status"]) == "wrapped" and int(hooked.get("wrapped_count", 0)) == 1,
			"a partial mask wraps what matched (got %s)" % str(hooked))
	check_eq(hooked["missing_methods"], ["sync (the method is an @rpc, which cannot be wrapped)",
			"rest (the method takes a rest parameter (...), which a wrapper cannot forward)", "missingone"],
			"the unmatched rest of the mask")
	for c in [["Hook on T39Hooked.gd::missingone will NEVER fire: no such method in vanilla.", "a misspelled method"],
			["Hook on T39Hooked.gd::Sync will NEVER fire: the method is an @rpc, which cannot be wrapped.",
			"an unwrappable method"]]:
		check_eq(text.count(c[0]), 1, "warnings for %s" % c[1])
	_assert(text.contains("res://Scripts/T39Hooked.gd is rewritten for hooks and also replaced by T39 Replacer"),
			"displacing another mod's replacement warns")
	_assert(deferred.has(T39_DIR + "T39Deferred.gd") and deferred.size() == 1,
			"only the scene-preload script defers (got %s)" % str(deferred.keys()))
	check_eq(str(ledger[T39_DIR + "T39Deferred.gd"]["status"]), "wrapped", "a deferred script's status")

	var db: Dictionary = ledger[T39_DIR + "Database.gd"]
	var db_missing := str(db["missing_methods"])
	_assert(str(db["status"]) == "wrapped" and db_missing.contains("Gone") and not db_missing.contains("_ready"),
			"a widened target's names checked by hand (got %s)" % db_missing)
	_assert(text.contains("Hook on Database.gd::Gone will NEVER fire: no such method in vanilla."),
			"a missing name on a widened target warns")
	_assert((db["missing_methods"] as Array).has("registry transform (marker 'var _rtv_vanilla_scenes' absent -- registry features on this script will not work)"),
			"a no-op registry transform is reported (got %s)" % db_missing)
	var compiler: Dictionary = ledger[T39_DIR + "Compiler.gd"]
	_assert(str(compiler["status"]) == "wrapped" and str(compiler["missing_methods"]).contains("registry code (does not compile"),
			"a wrap-only target lacks its registry code (got %s)" % str(compiler))
	_assert(not str(compiler["missing_methods"]).contains("registry transform"), "a wrap-only target has no marker blame")

	var zr := ZIPReader.new()
	_assert(zr.open(ProjectSettings.globalize_path(pack_rel)) == OK, "the pack opens")
	var entries := zr.get_files()
	_assert(entries.size() == 13 and entries.has("__modloader_canary__.txt"),
			"three entries per script plus canary (got %s)" % str(entries))
	for e in ["Scripts/T39Hooked.gd", "Scripts/T39Hooked.gd.remap", "Scripts/T39Hooked.gdc"]:
		_assert(entries.has(e), "the pack carries %s" % e)
	if entries.has("Scripts/T39Hooked.gd"):
		var gd := zr.read_file("Scripts/T39Hooked.gd").get_string_from_utf8()
		_assert(gd.contains("func _rtv_vanilla_Jump(a):") and not gd.contains("func _rtv_vanilla_Sync("),
				"the packed source renames only matched methods")
	if entries.has("Scripts/T39Hooked.gd.remap"):
		check_eq(zr.read_file("Scripts/T39Hooked.gd.remap").get_string_from_utf8(),
				"[remap]\npath=\"res://Scripts/T39Hooked.gd\"\n", "the remap")
	if entries.has("Scripts/T39Hooked.gdc"):
		_assert(zr.read_file("Scripts/T39Hooked.gdc").is_empty(), "the shadowing .gdc is empty")
	zr.close()

	DirAccess.remove_absolute(ProjectSettings.globalize_path(pack_rel))
	for n in T39_SOURCES:
		DirAccess.remove_absolute(ProjectSettings.globalize_path(T39_DIR + n))
	overrides.clear()
	zero.clear()
	deferred.clear()
	lines.clear()
	_ml.set("_hook_pack_demotions", {})
	_ml.set("_any_mod_declared_registry", false)
	_ml.set("_developer_mode", false)
	H.wipe_user()

# At 60 s a deferred script compiled without its rewrite is a critical (VFS
# precedence failed); one nothing loaded yet is normal.
func _t40_deferred_watchdog() -> void:
	var lines: Array = _ml.get("_report_lines")
	_ml.set("_developer_mode", true)
	var keep := [
		_cached_script("res://T40/Live.gd", "extends Node\nfunc _rtv_vanilla_Open():\n\tpass\n"),
		_cached_script("res://T40/Lacks.gd", "extends Node\nfunc Open():\n\tpass\n"),
	]
	for c in [[["Live.gd", "Never.gd"], "DEFER-VERIFY (60s): 1/2 deferred rewrite(s) live; 1 not yet loaded by game code (normal until their scenes are used): Never.gd",
			"an unloaded script is not loaded yet"],
			[["Live.gd", "Lacks.gd", "Never.gd"], "[Critical] [STABILITY] DEFER-VERIFY (60s): 1 deferred script(s) lazy-compiled WITHOUT the rewrite -- VFS did not serve the hook pack for: Lacks.gd.",
			"a script without its rewrite is critical"],
			[["Live.gd"], "DEFER-VERIFY (60s): all 1 deferred rewrite(s) lazy-compiled with hooks live",
			"all deferred rewrites live is said"]]:
		lines.clear()
		var paths := PackedStringArray()
		for n in c[0]:
			paths.append("res://T40/" + n)
		_ml._verify_deferred_scripts(paths)
		_assert("\n".join(lines).contains(c[1]), "%s (got %s)" % [c[2], "\n".join(lines)])
	lines.clear()
	keep.clear()
	_ml.set("_developer_mode", false)

# Every eager script must carry its renamed method; none doing so, a miss on
# a canary A script or a demotion is an error, a lost target a warning.
func _t41_compile_proof() -> void:
	var lines: Array = _ml.get("_report_lines")
	var deferred: Dictionary = _ml.get("_scripts_with_scene_preloads")
	deferred.clear()
	deferred["res://T41/Deferred.gd"] = true
	var keep := [
		_cached_script("res://T41/Rewritten.gd", "extends Node\nfunc _rtv_vanilla_Jump():\n\tpass\n"),
		_cached_script("res://T41/Controller.gd", "extends Node\nfunc Jump():\n\tpass\n"),
	]
	var eager: Array[String] = ["res://T41/Rewritten.gd", "res://T41/Controller.gd", "res://T41/Deferred.gd"]
	var proof: Dictionary = _ml._compile_proof(eager)
	_assert(int(proof["ok"]) == 1 and PackedStringArray(proof["fail"]) == PackedStringArray(["res://T41/Controller.gd"]),
			"one rewrite, one plain fail, deferred skipped (got %s)" % str(proof))
	deferred.clear()
	keep.clear()

	var demotions: Dictionary = _ml.get("_hook_pack_demotions")
	var lost: Array = _ml.get("_hook_pack_lost_targets")
	demotions.clear()
	lost.clear()
	var cases := [
		[0, ["res://T41/A.gd"], 1, 0, "all_failed", "ALL 1 rewrites failed to take effect", "none of the loader's 1 script rewrites took effect"],
		[1, ["res://T41/Controller.gd"], 2, 1, "critical_failed", "Hook rewrites missing on critical scripts: res://T41/Controller.gd.", "hooks did not work on Controller.gd"],
		[2, ["res://T41/Other.gd"], 3, 1, "ok", "COMPILE-PROOF summary: 2/3 rewrites active (1 pinned-fallback), 1 deferred to lazy-compile", ""],
		[0, [], 0, 2, "ok", "COMPILE-PROOF summary: 0/0 rewrites active, 2 deferred to lazy-compile", ""],
	]
	for i in cases.size():
		var c: Array = cases[i]
		begin("T41 case %d" % (i + 1))
		lines.clear()
		var verdict: Dictionary = _ml._canary_a_verdict(int(c[0]), PackedStringArray(c[1]), int(c[2]), int(c[3]))
		check_eq(str(verdict["state"]), c[4], "canary A's state")
		_assert("\n".join(lines).contains(c[5]), "canary A logs '%s' (got %s)" % [c[5], str(lines)])
		_ml._hook_status_write(_ml._activation_status(verdict, int(c[2])))
		var problem: Dictionary = _ml._hook_status_problem()
		if c[6] == "":
			_assert(problem.is_empty(), "a healthy activation shows nothing (got %s)" % str(problem))
		else:
			_assert(_is_error(problem, c[6]), "the launcher says '%s' (got %s)" % [c[6], str(problem)])
	begin("T41")
	var healthy: Dictionary = _ml._canary_a_verdict(2, PackedStringArray(), 2, 0)
	demotions["res://Scripts/AI.gd"] = "wrap_only"
	_ml._hook_status_write(_ml._activation_status(healthy, 2))
	var problem: Dictionary = _ml._hook_status_problem()
	_assert(_is_error(problem, "AI.gd"), "hooks working, a demotion is the notice (got %s)" % str(problem))
	var all_failed: Dictionary = _ml._canary_a_verdict(0, PackedStringArray(["res://T41/A.gd"]), 1, 0)
	_ml._hook_status_write(_ml._activation_status(all_failed, 1))
	_assert(str(_ml._hook_status_problem().get("text", "")).contains("none of the loader's"),
			"a total failure outranks a demotion")
	demotions.clear()
	lost.append("Foo.gd :: jump (declared by Some Mod via [hooks]) -- no such method")
	_ml._hook_status_write(_ml._activation_status(healthy, 2))
	problem = _ml._hook_status_problem()
	_assert(str(problem.get("severity", "")) == "warning" and str(problem.get("text", "")).contains("Foo.gd :: jump"),
			"a lost target is a warning naming it (got %s)" % str(problem))
	lost.clear()
	lines.clear()
	_ml._hook_status_write({"state": "ok", "attempted": 0})
	H.remove_user_file(str(_ml.HOOK_STATUS_PATH))

# Only a target missing from the game blames a game update; a skip names its
# cause, and a partial wrap names the methods left out.
func _t43_lost_target_causes() -> void:
	var gone := _ledger_row("[hooks]/.hook()", ["jump"])
	_ml._ledger_lose(gone, "no vanilla script at this path", true)
	var reconcile := {"res://Scripts/T43Gone.gd": gone}
	for c in [["T43Skip.gd", "on the runtime-sensitive skip list"], ["T43Empty.gd", "zero-byte file"],
			["T43Probe.gd", "does not compile against this game build"], ["T43Zip.gd", "zip write failed"]]:
		var rec := _ledger_row("[hooks]/.hook()", ["jump"])
		_ml._ledger_lose(rec, c[1])
		reconcile["res://Scripts/" + c[0]] = rec
	var part := _ledger_row("[hooks]/.hook()", ["jump", "sync"])
	part["status"] = "wrapped"
	part["wrapped_count"] = 1
	part["missing_methods"] = ["sync (an @rpc)"]
	reconcile["res://Scripts/T43Part.gd"] = part
	_ml._log_hook_reconciliation(reconcile)
	var healthy: Dictionary = _ml._canary_a_verdict(1, PackedStringArray(), 1, 0)
	_ml._hook_status_write(_ml._activation_status(healthy, 1))
	var rec: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(str(_ml.HOOK_STATUS_PATH)))
	check_eq(rec["lost"].size(), 1, "missing targets in lost")
	_assert(str(rec["lost"][0]).begins_with("T43Gone.gd"), "lost holds the missing script")
	check_eq(rec["skipped"].size(), 4, "skipped targets in skipped")
	for i in 4:
		var c: String = ["skip list", "zero-byte", "does not compile", "zip write"][i]
		_assert(rec["skipped"].any(func(l): return str(l).contains(c)), "skipped keeps reason '%s'" % c)
	check_eq(rec["partial"], ["T43Part.gd (declared by a mod (declared at runtime via add_hook)) did not wrap: sync (an @rpc)"],
			"partial names the unwrapped methods")
	var problem: Dictionary = _ml._hook_status_problem()
	check_eq(str(problem.get("severity", "")), "warning", "the banner severity")
	var lines: PackedStringArray = str(problem.get("text", "")).split("\n")
	check_eq(lines.size(), 3, "one banner line per cause")
	_assert(lines[0].contains("1 hook target(s) a mod asked for were not found") and lines[0].contains("T43Gone.gd")
			and not lines[0].contains("T43Skip.gd"), "only missing targets are not found")
	_assert(lines[1].contains("the loader skipped 4 hook target(s)") and lines[1].contains("skip list")
			and not lines[1].contains("game update"), "skips name their cause")
	_assert(lines[2].contains("did not wrap: sync") and not lines[2].contains("those hooks did nothing"),
			"partial names the methods")
	_ml._log_hook_reconciliation({})
	H.remove_user_file(str(_ml.HOOK_STATUS_PATH))

# The legacy count wipes pass state at MAX crashes, not one later.
func _t44_trip_at_max() -> void:
	for c in [[_max, false], [_max - 1, true]]:
		H.wipe_user()
		var cfg := ConfigFile.new()
		cfg.set_value("state", "restart_count", c[0])
		cfg.save(_state_path)
		_ml._write_heartbeat()
		_ml._check_crash_recovery()
		check_eq(FileAccess.file_exists(_state_path), c[1], "pass state present at count %d" % c[0])
		_assert(not FileAccess.file_exists(_heartbeat_path), "recovery deletes the heartbeat")
	H.wipe_user()

func _t45_pack_path_sane() -> void:
	var dir := str(_ml.HOOK_PACK_DIR)
	var prefix := str(_ml.HOOK_PACK_PREFIX)
	for c in [[dir + "/" + prefix + "_12.zip", true], [dir + "/" + prefix + "_12.ZIP", true],
			[dir + "/sub/" + prefix + "_12.zip", false], [dir + "/../" + prefix + "_12.zip", false],
			[dir + "/other_12.zip", false], [dir + "/" + prefix + "_12.txt", false],
			["user://elsewhere/" + prefix + "_12.zip", false]]:
		check_eq(bool(_ml._pack_path_sane(c[0])), c[1], "sane pack path %s" % c[0])

# A deleted folder mod's cache zip outlives it; either path form must notice.
func _t46_deleted_folder_mod() -> void:
	H.wipe_user()
	var tmp := str(_ml.TMP_DIR)
	var dev := tmp.path_join("t46_no_such_folder_dev.zip")
	var plain := tmp.path_join("t46_plain.zip")
	_write_file(dev, "x")
	_write_file(plain, "x")
	for path in [dev, ProjectSettings.globalize_path(dev)]:
		_assert(bool(_ml._any_archive_missing(PackedStringArray([path]), PackedStringArray())),
				"deleted folder mod missing: %s" % path)
	_assert(not bool(_ml._any_archive_missing(PackedStringArray([plain]), PackedStringArray())),
			"a present archive is not missing")
	H.wipe_user()

func _t47_stale_cache_sweep() -> void:
	H.wipe_user()
	var mods := ProjectSettings.globalize_path("user://t47_mods")
	DirAccess.make_dir_recursive_absolute(mods.path_join("kept"))
	var saved_mods_dir: String = _ml.get("_mods_dir")
	_ml.set("_mods_dir", mods)
	var tmp := str(_ml.TMP_DIR)
	for f in ["gone_dev.zip", "gone_dev.zip.src", "kept_dev.zip", "orphan.zip"]:
		_write_file(tmp.path_join(f), "x")
	_ml._clean_stale_cache()
	_ml.set("_mods_dir", saved_mods_dir)
	for c in [["gone_dev.zip", false], ["gone_dev.zip.src", false], ["kept_dev.zip", true], ["orphan.zip", false]]:
		check_eq(FileAccess.file_exists(tmp.path_join(c[0])), c[1], "%s kept by the sweep" % c[0])
	H.wipe_user()

# Only Pass 1 probes a deferred script; a later generation ships it unprobed.
func _t48_deferred_probe() -> void:
	var source := "extends Node
func Open():
	pass
"
	var parsed: Dictionary = _ml._rtv_parse_script("T48.gd", source)
	for c in [[false, true, 0], [true, true, 1], [false, false, 1]]:
		_ml.set("_hook_pack_vetting", true)
		_ml.set("_hook_pack_pre_restart", c[0])
		_ml.set("_probe_count", 0)
		var got: Dictionary = _ml._hook_pack_vet_rewrite("res://Scripts/T48.gd", source, parsed, {"open": true}, c[1])
		check_eq(int(_ml.get("_probe_count")), c[2], "probes, pre_restart %s deferred %s" % [c[0], c[1]])
		check_eq(str(got["mode"]), "full", "a compiling rewrite stays full")
	_ml.set("_hook_pack_vetting", false)
	_ml.set("_hook_pack_pre_restart", false)
	_ml.set("_probe_count", 0)
	(_ml.get("_hook_pack_demotions") as Dictionary).clear()

func _t49_banner_more() -> void:
	for c in [[3, false], [4, true]]:
		var lost := []
		for i in c[0]:
			lost.append("T49_%d.gd" % i)
		_ml._hook_status_write({"state": "ok", "lost": lost})
		var text := str(_ml._hook_status_problem().get("text", ""))
		check_eq(text.contains("(and 1 more)"), c[1], "%d lost says and 1 more" % c[0])
	H.remove_user_file(str(_ml.HOOK_STATUS_PATH))

# The Mods button's Menu.gd wrap must not narrow a mod's wildcard.
func _t50_menu_hook_seed() -> void:
	var menu := "res://Scripts/Menu.gd"
	var hooked: Dictionary = _ml.get("_hooked_methods")
	var saved := hooked.duplicate(true)
	for c in [[null, {"_ready": true}], [{}, {}], [{"open": true}, {"open": true, "_ready": true}]]:
		hooked.erase(menu)
		if c[0] != null:
			hooked[menu] = (c[0] as Dictionary).duplicate()
		_ml._seed_core_hooks()
		check_eq(hooked.get(menu), c[1], "Menu.gd mask after seeding %s" % str(c[0]))
	hooked.clear()
	hooked.merge(saved)

# At the breaker's count the launch about to start already skips the restart.
func _t51_streak_banner_launch() -> void:
	for c in [[_max - 1, "if the next one fails too"], [_max, "so this launch skips the restart"],
			[_max + 1, "so this launch skips the restart"]]:
		H.wipe_user()
		_ml._static_write_crash_streak(c[0])
		var text := str(_ml._crash_notice_problem(false).get("text", ""))
		_assert(text.contains(c[1]), "streak %d says '%s'" % [c[0], c[1]])
	H.wipe_user()

# A missing registry marker is a partial entry; the hooks still fire.
func _t52_partial_registry_banner() -> void:
	for entry in ["Loader.gd (declared by a mod) did not wrap: registry transform (marker 'x' absent -- registry features on this script will not work)",
			"T52.gd (declared by a mod) did not wrap: sync (an @rpc)"]:
		_ml._hook_status_write({"state": "ok", "partial": [entry]})
		var text := str(_ml._hook_status_problem().get("text", ""))
		_assert(text.contains(entry), "the banner names the entry")
		_assert(not text.contains("hooks on the rest did nothing"), "no claim that hooks did nothing")
	H.remove_user_file(str(_ml.HOOK_STATUS_PATH))

# One crashed launch in production order: boot (static-init wipe, then
# _check_crash_recovery), Pass 1 arms the restart (heartbeat, then pass
# state), Pass 2 writes its dirty marker, and a mod crashes it.
func _crashed_launch() -> void:
	_next_launch_boot()
	_ml._write_heartbeat()
	_count_attempt()
	if not bool(_ml._static_write_pass2_dirty()):
		_fail("harness could not write the pass-2 dirty marker at " + _dirty_path)

func _next_launch_boot() -> void:
	if FileAccess.file_exists(_dirty_path):
		_wipe()
	_ml._check_crash_recovery()

# The counting half of arming a restart, without the heartbeat (T2).
func _count_attempt() -> void:
	_ml._write_pass_state(PackedStringArray(["user://harness_fixture_mod.zip"]), FIXTURE_HASH)

# The wipe static init fires on a crashed Pass 2.
func _wipe() -> void:
	_ml._static_force_vanilla_state("pass 2 crashed mid-run", PackedStringArray())

func _is_error(problem: Dictionary, needle: String) -> bool:
	return str(problem.get("severity", "")) == "error" and str(problem.get("text", "")).contains(needle)

func _write_file(path: String, text: String) -> void:
	if not H.write_text(path, text):
		_fail("harness could not write " + path)

# A link at `link` to `target`; on Windows a junction when a symlink needs a
# privilege the account lacks.
func _make_link(target: String, link: String) -> bool:
	DirAccess.make_dir_recursive_absolute(link.get_base_dir())
	if DirAccess.open(link.get_base_dir()).create_link(target, link) == OK:
		return true
	if OS.get_name() != "Windows":
		return false
	return OS.execute("cmd", ["/c", "mklink", "/J", link.replace("/", "\\"), target.replace("/", "\\")]) == 0

func _profiles_backup() -> ConfigFile:
	var good := ConfigFile.new()
	good.set_value("settings", "active_profile", "Hardcore")
	good.set_value("profile.Default.enabled", "a@1.0", true)
	good.set_value("profile.Hardcore.enabled", "a@1.0", false)
	good.set_value("profile.Hardcore.priority", "a@1.0", 40)
	return good

func _source_entries() -> Array[Dictionary]:
	var mod_txt := ConfigFile.new()
	mod_txt.parse("[mod]\nname=\"A\"\nid=\"a\"\nversion=\"1.0\"\n\n[updates]\nsource=\"vostokmods:a\"\n")
	var entries: Array[Dictionary] = [{"profile_key": "a@1.0", "cfg": mod_txt}]
	return entries

func _ledger_row(declared: String, methods: Array) -> Dictionary:
	return {"declared": declared, "methods": methods, "status": "pending", "detail": "", "missing_methods": []}

# A script compiled from source and cached at path, as a game-loaded script sits.
func _cached_script(path: String, source: String) -> GDScript:
	var s := GDScript.new()
	s.source_code = source
	s.reload()
	s.take_over_path(path)
	return s

func _source() -> PackedStringArray:
	if _built.is_empty():
		_built = FileAccess.get_file_as_string(MODLOADER_PATH).split("\n")
	return _built

# The lines after the one definition starting with header, up to the next
# top-level func; [] and a failure unless exactly one exists.
func _function_body(header: String) -> PackedStringArray:
	var lines := _source()
	var starts := []
	for i in lines.size():
		if lines[i].begins_with(header):
			starts.append(i)
	var body := PackedStringArray()
	if not check_eq(starts.size(), 1, "definitions of '%s' in the built loader" % header):
		return body
	for i in range(starts[0] + 1, lines.size()):
		if lines[i].begins_with("func ") or lines[i].begins_with("static func "):
			break
		body.append(lines[i])
	return body

func _first_line(body: PackedStringArray, needle: String, from := 0) -> int:
	for i in range(maxi(from, 0), body.size()):
		if body[i].contains(needle):
			return i
	return -1
