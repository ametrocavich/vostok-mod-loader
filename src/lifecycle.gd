## ----- lifecycle.gd -----
## Top-level orchestration: _ready is the entrypoint, dispatches to
## _run_pass_1 (first launch, show UI) or _run_pass_2 (post-restart).
## _finish_* helpers wrap up either path by instantiating queued autoloads
## and emitting frameworks_ready.

func _ready() -> void:
	if _has_loaded:
		return
	_has_loaded = true
	# Honor disabled sentinel. Static init already cleaned persistent state,
	# so we just sit idle for this session. User removes the file to re-enable.
	if _is_modloader_disabled():
		print("[ModLoader] disabled via sentinel file -- sitting idle")
		return
	await get_tree().process_frame
	_compile_regex()
	# Hook _load_all_mods completion to mount our test pack AFTER mod re-mounts.
	# (Test pack mounted before _run_pass_2 gets overwritten when load_all_mods
	# re-mounts ImmersiveXP.vmz with replace_files=true.)
	var is_pass_2 := "--modloader-restart" in OS.get_cmdline_user_args()
	if _load_test_pack_flag() and not is_pass_2:
		_test_pack_precedence()
		_log_info("[TEST-REMAP] test complete (Pass 1, before restart)")
	if is_pass_2:
		await _run_pass_2()
	else:
		await _run_pass_1()
	# Deferred verify: by now all autoloads have run. Check what IXP took over.
	if _load_test_pack_flag():
		await get_tree().create_timer(1.0).timeout
		_test_post_autoload_verify()

# Shared restart helper. Used by Pass 1's two-pass bootstrap, Reset to Vanilla,
# and the post-boot main-menu reopen flow. `clean_pass1` strips
# --modloader-restart so the next run is a clean Pass 1 rather than a Pass 2
# expecting stale state.
func _modloader_restart(clean_pass1: bool) -> void:
	var args: Array = []
	if clean_pass1:
		for a in OS.get_cmdline_args():
			if a != "--modloader-restart":
				args.append(a)
	else:
		args = Array(OS.get_cmdline_args())
	# Godot's arg parser consumes --rendering-driver / --rendering-method
	# (main.cpp:1272,1280) and does NOT push them back to main_args, so
	# OS.get_cmdline_args() returns the stripped list. Without re-injecting,
	# the relaunch loses the Steam launch option and Godot falls back to the
	# default driver (D3D12 on Windows). Visible on fresh-install first
	# launch; subsequent launches short-circuit on the mod-state hash and
	# never restart.
	_preserve_engine_driver_args(args)
	if not clean_pass1:
		args.append_array(["--", "--modloader-restart"])
	OS.set_restart_on_exit(true, args)
	get_tree().quit()

func _preserve_engine_driver_args(args: Array) -> void:
	# Scoped to the two flags RTV's Steam launch-option presets actually set
	# ([DirectX] / [Vulkan] / [Compatibility] pick --rendering-driver and/or
	# --rendering-method). If the user didn't pass a flag, querying returns
	# Godot's default (no-op); if they did, we preserve their choice.
	if not args.has("--rendering-driver"):
		var driver := RenderingServer.get_current_rendering_driver_name()
		if not driver.is_empty():
			args.append("--rendering-driver")
			args.append(driver)
	if not args.has("--rendering-method"):
		var method := RenderingServer.get_current_rendering_method()
		if not method.is_empty():
			args.append("--rendering-method")
			args.append(method)

# Public entry point for the main-menu "Mods" button. Re-shows the launcher UI
# post-boot; if any mutation sets _dirty_since_boot, quits + restarts into a
# clean Pass 1. Noop when the UI is already open.
func reopen_mod_ui() -> void:
	if _ui_window != null:
		return
	_dirty_since_boot = false
	await show_mod_ui()
	if _dirty_since_boot:
		_log_info("[ModLoader] Post-boot mod changes detected -- restarting")
		_modloader_restart(true)

func _run_pass_1() -> void:
	_log_info("Metro Mod Loader v" + MODLOADER_VERSION)
	_check_crash_recovery()
	_check_safe_mode()
	_compile_regex()
	_build_class_name_lookup()
	# Populate _all_game_script_paths NOW so the .hook() prefix resolver in
	# _merge_hook_calls_into_wrap_mask (run from load_all_mods below) can
	# fall back to filename-stem matches for vanilla scripts without
	# class_name (Flashlight, NVG, Interface, ...). Previously this only
	# ran inside _generate_hook_pack, so source-scanned hooks on
	# class_name-less scripts were silently dropped.
	_enumerate_game_scripts()
	_load_developer_mode_setting()
	_ui_mod_entries = collect_mod_metadata()
	_clean_stale_cache()
	_load_ui_config()
	await show_mod_ui()
	_save_ui_config()

	load_all_mods()
	_apply_script_overrides()  # apply [script_overrides] before hook generation

	var sections := _build_autoload_sections()
	var archive_paths := _collect_enabled_archive_paths()

	var new_hash := _compute_state_hash(archive_paths, sections.prepend)
	var old_hash := ""
	var state_cfg := ConfigFile.new()
	if state_cfg.load(PASS_STATE_PATH) == OK:
		old_hash = state_cfg.get_value("state", "mods_hash", "")

	if new_hash == old_hash and not new_hash.is_empty():
		_log_info("Mod state unchanged -- skipping restart")
		await _finish_with_existing_mounts()
		return

	# Note: do NOT generate framework wrappers here. If we restart, the work is
	# wasted. Pass 2 will generate after archives are mounted + class lookup
	# rebuilt. Single-pass paths (_finish_single_pass, _finish_with_existing_mounts)
	# generate before activating hooks.

	if archive_paths.size() > 0:
		_log_info("Preparing two-pass restart -- %d archive(s)" % archive_paths.size())
		if sections.prepend.size() > 0:
			_log_info("  %d early autoload(s) in [autoload_prepend]" % sections.prepend.size())
		# Generate hook pack NOW, before restart, so next session's static-init
		# mount has a fresh pack for the current mod set. Without this, when
		# the pack is missing (first-ever session, after Reset, after mod-set
		# change) Godot pins class_name scripts (Camera, WeaponRig, Door, etc.)
		# as PCK-bytecode during [autoload_prepend] boot and Pass 2's fallback
		# (CACHE_MODE_IGNORE + take_over_path) can't recover them. Verified
		# 2026-04-17: 40/126 rewrites silently die after Reset otherwise.
		# defer_activation=true: write the zip + persist pass_state, but skip
		# mount + reload()/take_over_path. Pass 1's GDScriptCache is already
		# polluted by the PCK's pre-compiled class_name scripts, so activation
		# here would fire a misleading "hooks WILL NOT fire" STABILITY alarm
		# seconds before Pass 2's fresh engine gets 126/126 inline-live.
		_register_rtv_modlib_meta()
		_generate_hook_pack(true)
		_write_heartbeat()
		var err := _write_override_cfg(sections.prepend)
		if err != OK:
			_log_critical("Failed to write override.cfg (error %d) -- single-pass fallback" % err)
			await _finish_single_pass()
			return
		if _write_pass_state(archive_paths, new_hash) != OK:
			await _finish_single_pass()
			return
		_modloader_restart(false)
		return

	# No archives enabled. Clean up stale two-pass state if present.
	if FileAccess.file_exists(PASS_STATE_PATH):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(PASS_STATE_PATH))
		_restore_clean_override_cfg()
	if DirAccess.dir_exists_absolute(ProjectSettings.globalize_path(HOOK_PACK_DIR)):
		_static_wipe_hook_cache()
		_log_info("[Hooks] Cleaned up unused hook artifacts")
	await _finish_single_pass()

func _finish_with_existing_mounts() -> void:
	# Register meta + generate the framework pack BEFORE mod autoloads run so
	# Engine.get_meta("RTVModLib") is live by the time they call .hook().
	# Script overrides were already applied in _run_pass_1() before the hash
	# check; no need to re-apply from pass state.
	_boot_complete = true
	_register_rtv_modlib_meta()
	_generate_hook_pack()
	for entry in _pending_autoloads:
		if get_tree().root.has_node(entry["name"]):
			_log_info("  Autoload '%s' already in tree -- skipped" % entry["name"])
			continue
		_instantiate_autoload(entry["mod_name"], entry["name"], entry["path"])
	if _developer_mode:
		_log_override_timing_warnings()
		_print_conflict_summary()
		_write_conflict_report()
	_emit_frameworks_ready()
	_delete_heartbeat()
	if not _filescope_mounted.is_empty() or not _archive_file_sets.is_empty() or _pending_autoloads.size() > 0:
		var err := get_tree().reload_current_scene()
		if err != OK:
			_log_critical("reload_current_scene() failed with error " + str(err))
			return

func _finish_single_pass() -> void:
	_boot_complete = true
	_register_rtv_modlib_meta()
	_generate_hook_pack()
	for entry in _pending_autoloads:
		_instantiate_autoload(entry["mod_name"], entry["name"], entry["path"])
	if _developer_mode:
		_log_override_timing_warnings()
		_print_conflict_summary()
		_write_conflict_report()
	_emit_frameworks_ready()
	_delete_heartbeat()
	if not _archive_file_sets.is_empty() or _pending_autoloads.size() > 0:
		var err := get_tree().reload_current_scene()
		if err != OK:
			_log_critical("reload_current_scene() failed with error " + str(err))
			return

# Pass 2: Post-restart -- archives already mounted at file-scope


func _run_pass_2() -> void:
	_boot_complete = true
	_log_info("Pass 2 -- %d archive(s) mounted at file-scope" % _filescope_mounted.size())
	# Write dirty marker first thing. If Pass 2 crashes before cleanup below,
	# next launch's static init detects the marker and force-wipes state.
	var _dirty_f := FileAccess.open(PASS2_DIRTY_PATH, FileAccess.WRITE)
	if _dirty_f:
		_dirty_f.store_string(str(Time.get_unix_time_from_system()))
		_dirty_f.close()
	# Restore script overrides from pass state and apply before hooks.
	var _pass_cfg := ConfigFile.new()
	if _pass_cfg.load(PASS_STATE_PATH) == OK:
		var saved_overrides: Array = _pass_cfg.get_value("state", "script_overrides", [])
		for entry in saved_overrides:
			if entry is Dictionary and entry.has("vanilla_path") and entry.has("mod_script_path"):
				_pending_script_overrides.append(entry)
			else:
				_log_warning("[Overrides] Malformed entry in pass state -- skipped")
	_apply_script_overrides()
	_clear_restart_counter()
	_compile_regex()
	_build_class_name_lookup()
	# See _run_pass_1: enumerate before load_all_mods so filename-stem
	# fallback in _merge_hook_calls_into_wrap_mask is populated.
	_enumerate_game_scripts()
	_load_developer_mode_setting()
	_ui_mod_entries = collect_mod_metadata()
	_load_ui_config()

	load_all_mods("Pass 2")
	_register_rtv_modlib_meta()
	_generate_hook_pack()
	# After load_all_mods re-mounts mod archives (wiping our IXP/Controller
	# override), remount the already-generated test pack to re-apply.
	# NOTE: Godot dedupes load_resource_pack by path, so mounting the same
	# filename twice is a no-op. Copy to a different filename each time.
	if _load_test_pack_flag():
		var src_abs := ProjectSettings.globalize_path("user://test_pack_precedence.zip")
		var reapply_abs := ProjectSettings.globalize_path("user://test_pack_reapply_" \
				+ str(Time.get_ticks_msec()) + ".zip")
		if FileAccess.file_exists(src_abs):
			var src := FileAccess.open(src_abs, FileAccess.READ)
			var dst := FileAccess.open(reapply_abs, FileAccess.WRITE)
			if src and dst:
				dst.store_buffer(src.get_buffer(src.get_length()))
				src.close()
				dst.close()
				if ProjectSettings.load_resource_pack(reapply_abs, true):
					_log_info("[TEST-REMAP] Pass 2: re-applied test pack via copy " + reapply_abs.get_file())
					# Verify VFS state post-reapply
					if FileAccess.file_exists("res://ImmersiveXP/Controller.gd"):
						var chk := FileAccess.get_file_as_bytes("res://ImmersiveXP/Controller.gd")
						var has_marker := "TEST-HOOK-IXP" in chk.get_string_from_utf8()
						_log_info("[TEST-REMAP] Pass 2 post-reapply: IXP/Controller.gd = " \
								+ str(chk.size()) + " bytes, has marker: " + str(has_marker))
				else:
					_log_warning("[TEST-REMAP] Pass 2: load_resource_pack on copy failed")
			else:
				_log_warning("[TEST-REMAP] Pass 2: failed to copy test pack")
	for entry in _pending_autoloads:
		if get_tree().root.has_node(entry["name"]):
			_log_info("  Autoload '%s' already in tree -- skipped" % entry["name"])
			continue
		_instantiate_autoload(entry["mod_name"], entry["name"], entry["path"])

	if _developer_mode:
		_log_override_timing_warnings()
		_print_conflict_summary()
		_write_conflict_report()
	_emit_frameworks_ready()
	_delete_heartbeat()
	# Pass 2 reached cleanup -- clear the dirty marker so next launch knows we
	# finished without crashing. If reload_current_scene below fails we still
	# want the marker gone; the state we wrote IS consistent at this point.
	if FileAccess.file_exists(PASS2_DIRTY_PATH):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(PASS2_DIRTY_PATH))
	if not _filescope_mounted.is_empty() or not _archive_file_sets.is_empty() or _pending_autoloads.size() > 0:
		var err := get_tree().reload_current_scene()
		if err != OK:
			_log_critical("reload_current_scene() failed with error " + str(err))
			return

