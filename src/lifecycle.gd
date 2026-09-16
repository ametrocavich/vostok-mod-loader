## ----- lifecycle.gd -----
## Top-level orchestration: _ready is the entrypoint, dispatches to
## _run_pass_1 (first launch, show UI) or _run_pass_2 (post-restart).
## _finish_* helpers wrap up either path by instantiating queued autoloads
## and emitting frameworks_ready.

func _ready() -> void:
	if _has_loaded:
		return
	_has_loaded = true
	# Disabled sentinel: static init already cleaned state; clear the one-shot variant.
	if _is_modloader_disabled():
		var exe_dir := OS.get_executable_path().get_base_dir()
		var once_path := exe_dir.path_join(DISABLED_ONCE_FILE)
		if FileAccess.file_exists(once_path):
			DirAccess.remove_absolute(once_path)
			print("[ModLoader] one-shot vanilla launch -- sentinel cleared, next launch is normal")
		else:
			print("[ModLoader] disabled via sentinel file -- sitting idle")
		return
	await get_tree().process_frame
	_compile_regex()
	# The test pack must mount after load_all_mods re-mounts archives.
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

# Shared restart helper. `clean_pass1` strips --modloader-restart for a clean Pass 1.
func _modloader_restart(clean_pass1: bool) -> void:
	var args: Array = []
	if clean_pass1:
		for a in OS.get_cmdline_args():
			if a != "--modloader-restart":
				args.append(a)
	else:
		args = Array(OS.get_cmdline_args())
	# Godot's arg parser consumes --rendering-driver / --rendering-method and
	# OS.get_cmdline_args() returns the stripped list; re-inject the Steam launch option.
	_preserve_engine_driver_args(args)
	# Args after "--" live in OS.get_cmdline_user_args(); forward them, re-adding the sentinel only for the bootstrap.
	var user_args: Array = []
	for ua in OS.get_cmdline_user_args():
		if ua != "--modloader-restart":
			user_args.append(ua)
	if not clean_pass1:
		user_args.append("--modloader-restart")
	if user_args.size() > 0:
		args.append("--")
		args.append_array(user_args)
	OS.set_restart_on_exit(true, args)
	get_tree().quit()

func _preserve_engine_driver_args(args: Array) -> void:
	# Only the two flags RTV's Steam presets set; a no-op when none was passed.
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

# Entry point for the main-menu "Mods" button. Re-shows the launcher; if any
# mutation set _dirty_since_boot, restarts into a clean Pass 1.
func reopen_mod_ui() -> void:
	if _ui_window != null:
		return
	_dirty_since_boot = false
	await show_mod_ui()
	# Flush a pending debounced priority save; it has not set _dirty_since_boot yet.
	if _priority_save_pending:
		_priority_save_pending = false
		_save_ui_config()
	if _dirty_since_boot:
		_log_info("[ModLoader] Post-boot mod changes detected -- restarting")
		_modloader_restart(true)

func _run_pass_1() -> void:
	_log_info("Metro Mod Loader v" + MODLOADER_VERSION)
	_check_crash_recovery()
	_check_safe_mode()
	_compile_regex()
	_build_class_name_lookup()
	# Enumerate before load_all_mods so the .hook() resolver can match class_name-less scripts by stem.
	_enumerate_game_scripts()
	_load_developer_mode_setting()
	_ui_mod_entries = collect_mod_metadata()
	_clean_stale_cache()
	_load_ui_config()
	await show_mod_ui()
	_save_ui_config()

	# Pass 2 applies the overrides before its load_all_mods call and the hook
	# pack reads the applied map after it, so the map is cleared here, not there.
	_applied_script_overrides.clear()
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

	# No wrapper generation here: a restart would waste it.

	if archive_paths.size() > 0 and _crash_breaker_tripped():
		# Restarting again would repeat the crash; single pass keeps the launcher reachable.
		_log_critical("Restart loop detected (%d consecutive crashed restarts) -- staying single-pass this launch. Disable recently added mods if the game is unstable." % _static_read_crash_streak())
		_static_write_crash_streak(0)
		_restore_clean_override_cfg()
		if FileAccess.file_exists(PASS_STATE_PATH):
			DirAccess.remove_absolute(ProjectSettings.globalize_path(PASS_STATE_PATH))
		await _finish_single_pass()
		return

	if archive_paths.size() > 0:
		_log_info("Preparing two-pass restart -- %d archive(s)" % archive_paths.size())
		if sections.prepend.size() > 0:
			_log_info("  %d early autoload(s) in [autoload_prepend]" % sections.prepend.size())
		# Generate the hook pack before the restart so next session's static-init
		# mount has a fresh pack. defer_activation=true: Pass 1's GDScriptCache is
		# already polluted, so activating here would fire a misleading alarm.
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
	else:
		# override.cfg can carry stale mod entries even without pass state; rewrite only when it differs.
		var cfg_path := OS.get_executable_path().get_base_dir().path_join("override.cfg")
		if FileAccess.file_exists(cfg_path):
			var cur := FileAccess.get_file_as_string(cfg_path)
			if cur != _clean_override_cfg_content(_read_preserved_cfg_sections(cfg_path)):
				_restore_clean_override_cfg()
	if DirAccess.dir_exists_absolute(ProjectSettings.globalize_path(HOOK_PACK_DIR)):
		_static_wipe_hook_cache()
		_log_info("[Hooks] Cleaned up unused hook artifacts")
	await _finish_single_pass()

func _finish_with_existing_mounts() -> void:
	# Register meta and generate the pack before mod autoloads call .hook().
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
	# A stale restart_count surviving hash-match sessions would trip the breaker early.
	_clear_restart_counter()
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
		# An autoload already loaded from override.cfg would be instantiated twice.
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
	# Session finished; a leftover restart_count is stale.
	_clear_restart_counter()
	if not _archive_file_sets.is_empty() or _pending_autoloads.size() > 0:
		var err := get_tree().reload_current_scene()
		if err != OK:
			_log_critical("reload_current_scene() failed with error " + str(err))
			return

# Pass 2: Post-restart -- archives already mounted at file-scope


func _run_pass_2() -> void:
	_boot_complete = true
	_log_info("Pass 2 -- %d archive(s) mounted at file-scope" % _filescope_mounted.size())
	# Dirty marker first: a crash before cleanup makes the next static init force-wipe.
	var _dirty_f := FileAccess.open(PASS2_DIRTY_PATH, FileAccess.WRITE)
	if _dirty_f:
		_dirty_f.store_string(str(Time.get_unix_time_from_system()))
		_dirty_f.close()
	# Restore script overrides from pass state and apply before hooks.
	var _pass_cfg := ConfigFile.new()
	if _pass_cfg.load(PASS_STATE_PATH) == OK:
		var so_v: Variant = _pass_cfg.get_value("state", "script_overrides", [])
		var saved_overrides: Array = so_v if so_v is Array else []
		for entry in saved_overrides:
			if entry is Dictionary and entry.has("vanilla_path") and entry.has("mod_script_path") and entry.has("mod_name") and entry.has("priority"):
				_pending_script_overrides.append(entry)
			else:
				_log_warning("[Overrides] Malformed entry in pass state -- skipped")
	_apply_script_overrides()
	_compile_regex()
	_build_class_name_lookup()
	# See _run_pass_1: enumerate before load_all_mods for the filename-stem fallback.
	_enumerate_game_scripts()
	_load_developer_mode_setting()
	_ui_mod_entries = collect_mod_metadata()
	_load_ui_config()

	load_all_mods("Pass 2")
	_register_rtv_modlib_meta()
	_generate_hook_pack()
	# Re-apply the test pack after the re-mounts; copy to a fresh filename (path dedupe).
	if _load_test_pack_flag():
		# Sweep prior sessions' reapply copies; nothing else deletes them.
		var user_dir_abs := ProjectSettings.globalize_path("user://")
		var user_dir := DirAccess.open(user_dir_abs)
		if user_dir != null:
			user_dir.list_dir_begin()
			while true:
				var stale_name := user_dir.get_next()
				if stale_name == "":
					break
				if stale_name.begins_with("test_pack_reapply_") and stale_name.ends_with(".zip"):
					DirAccess.remove_absolute(user_dir_abs.path_join(stale_name))
			user_dir.list_dir_end()
		var src_abs := ProjectSettings.globalize_path("user://test_pack_precedence.zip")
		var reapply_abs := ProjectSettings.globalize_path("user://test_pack_reapply_" \
				+ str(Time.get_ticks_msec()) + ".zip")
		if FileAccess.file_exists(src_abs):
			var src := FileAccess.open(src_abs, FileAccess.READ)
			var dst := FileAccess.open(reapply_abs, FileAccess.WRITE)
			if src and dst:
				# A short write (disk full) would otherwise mount a truncated zip.
				var write_ok := dst.store_buffer(src.get_buffer(src.get_length()))
				src.close()
				dst.close()
				if not write_ok:
					_log_warning("[TEST-REMAP] Pass 2: copy write failed")
					DirAccess.remove_absolute(reapply_abs)
				elif ProjectSettings.load_resource_pack(reapply_abs, true):
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
	# Clear the streak and drop the dirty marker at the end: clearing at entry
	# would precede the crash window and the breaker could never trip.
	_clear_restart_counter()
	if FileAccess.file_exists(PASS2_DIRTY_PATH):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(PASS2_DIRTY_PATH))
	if not _filescope_mounted.is_empty() or not _archive_file_sets.is_empty() or _pending_autoloads.size() > 0:
		var err := get_tree().reload_current_scene()
		if err != OK:
			_log_critical("reload_current_scene() failed with error " + str(err))
			return
	# Windows hands foreground away when the Pass-1 process dies; ask for focus
	# once the window is mapped, with request_attention as the fallback.
	await get_tree().process_frame
	await get_tree().process_frame
	var win := get_window()
	if win != null:
		win.grab_focus()
		win.request_attention()

