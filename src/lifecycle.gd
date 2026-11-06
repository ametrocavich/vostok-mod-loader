## Entry point: _ready runs Pass 1 (the launcher, then a restart) or Pass 2 (the restarted process).

func _ready() -> void:
	if _has_loaded:
		return
	_has_loaded = true
	if _is_modloader_disabled():
		if _static_remove_file(_static_exe_dir().path_join(DISABLED_ONCE_FILE)):
			_log_info("One-shot vanilla launch -- sentinel cleared, next launch is normal")
		else:
			_log_info("Disabled via sentinel file -- sitting idle")
		_consume_skip_ui_once()
		return
	# Before the first await: early autoloads run while this _ready is suspended and need the meta.
	_register_rtv_modlib_meta()
	await get_tree().process_frame
	_compile_regex()
	if RESTART_ARG in OS.get_cmdline_user_args():
		await _run_pass_2()
	else:
		await _run_pass_1()

# Godot passes an unknown argument through to get_cmdline_args(), so check both sides of "--".
func _launcher_skipped(args: PackedStringArray, user_args: PackedStringArray) -> bool:
	return SKIP_UI_ARG in args or SKIP_UI_ARG in user_args

# Consumed even when the flag is set too, so a later Steam launch shows the launcher.
func _launcher_skip_reason() -> String:
	var once_used := _consume_skip_ui_once()
	if _launcher_skipped(OS.get_cmdline_args(), OS.get_cmdline_user_args()):
		return SKIP_UI_ARG
	return SKIP_UI_ONCE_FILE if once_used else ""

# A disabled launch consumes it too: the file asks to skip the next launch only.
func _consume_skip_ui_once() -> bool:
	var once := _static_exe_dir().path_join(SKIP_UI_ONCE_FILE)
	if not FileAccess.file_exists(once):
		return false
	if DirAccess.remove_absolute(once) != OK:
		_log_warning("[Launcher] Could not delete %s -- every launch skips the launcher until it is removed" % once)
	return true

func _restart_into_pass_1() -> void:
	_restart_with(false)

func _restart_with(add_sentinel: bool) -> void:
	var args: Array = []
	for a in OS.get_cmdline_args():
		if add_sentinel or a != RESTART_ARG:
			args.append(a)
	# Godot's arg parser consumes RTV's two Steam-preset flags, so get_cmdline_args() lacks them.
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
	var user_args: Array = []
	for ua in OS.get_cmdline_user_args():
		if ua != RESTART_ARG:
			user_args.append(ua)
	if add_sentinel:
		user_args.append(RESTART_ARG)
	if user_args.size() > 0:
		args.append("--")
		args.append_array(user_args)
	OS.set_restart_on_exit(true, args)
	get_tree().quit()

func reopen_mod_ui() -> void:
	if _ui_window != null:
		return
	_reload_entries_for_active_profile()
	await show_mod_ui()
	if _priority_save_pending:
		_priority_save_pending = false
		_save_ui_config()
	if _post_boot_restart_needed():
		_log_info("[Launcher] Post-boot mod changes detected -- restarting")
		_restart_into_pass_1()

# Before load_all_mods: the .hook() resolver matches class_name-less scripts by stem.
func _scan_game_and_mods() -> void:
	_build_class_name_lookup()
	_enumerate_game_scripts()
	_load_developer_mode_setting()
	_ui_mod_entries = collect_mod_metadata()

func _run_pass_1() -> void:
	_log_info("Metro Mod Loader v" + MODLOADER_VERSION)
	_check_crash_recovery()
	_check_safe_mode()
	_scan_game_and_mods()
	_clean_stale_cache()
	_remove_retired_state()
	_load_ui_config()
	_modpack_reconcile_active()
	var skip_reason := _launcher_skip_reason()
	if skip_reason != "":
		_log_info("[Launcher] Skipped (%s): loading profile \"%s\" as if Launch was clicked" \
				% [skip_reason, _active_profile])
	else:
		await show_mod_ui()
	_save_ui_config()

	# Pass 2 applies overrides before load_all_mods and the hook pack reads them after: clear here.
	_applied_script_overrides.clear()
	load_all_mods()
	_apply_script_overrides()

	var sections := _build_autoload_sections()
	var archive_paths := _collect_enabled_archive_paths()

	var new_hash := _compute_state_hash(archive_paths, sections.prepend)
	var old_hash := ""
	var state_cfg := ConfigFile.new()
	if state_cfg.load(PASS_STATE_PATH) == OK:
		old_hash = _state_str(state_cfg, "mods_hash", "")

	if new_hash == old_hash and not new_hash.is_empty() and not _mcm_switch_completed:
		_log_info("Mod state unchanged -- skipping restart")
		_finish_boot(_mods_mounted_or_queued())
		return
	if _mcm_switch_completed:
		_log_info("Profile switch completed at this launch -- restarting so every mod reads the new MCM")

	if archive_paths.size() > 0 and _crash_breaker_tripped():
		_log_critical("Restart loop detected (%d consecutive crashed restarts) -- staying single-pass this launch." \
				% _static_read_crash_streak())
		# The launcher has already closed; the next one shows this.
		_write_crash_breaker_notice(_static_read_crash_streak())
		_static_write_crash_streak(0)
		_reset_to_unmodded_state()
		await _finish_single_pass()
		return

	if archive_paths.size() > 0:
		if _pass1_arm_restart(sections, archive_paths, new_hash):
			_restart_with(true)
		else:
			await _finish_single_pass()
		return
	await _pass1_finish_unmodded()

# A failed cleanup must not restart into old mounts, so a declined retry quits.
func _pass1_finish_unmodded() -> void:
	var cleanup_error := _clear_unmodded_boot_state()
	while not cleanup_error.is_empty():
		_log_critical("Could not launch without mods: " + cleanup_error)
		var dialog := ConfirmationDialog.new()
		dialog.title = "Could not launch without mods"
		dialog.dialog_text = cleanup_error + "\n\nRetry after resolving the problem, or quit this launch."
		dialog.ok_button_text = "Retry"
		dialog.cancel_button_text = "Quit"
		dialog.min_size = Vector2i(520, 160)
		_attach_ui_dialog(dialog)
		if not await _await_dialog_choice(dialog):
			get_tree().quit()
			return
		cleanup_error = _clear_unmodded_boot_state()
	if DirAccess.dir_exists_absolute(ProjectSettings.globalize_path(HOOK_PACK_DIR)):
		_static_wipe_hook_cache()
		_log_info("[Hooks] Cleaned up unused hook artifacts")
	# Static init mounted the previous set and its early autoloads ran; only a new process is clean.
	if not _filescope_mounted.is_empty():
		_log_info("Nothing to load, but the previous mod set is mounted in this process -- restarting without it")
		_restart_with(true)
		return
	await _finish_single_pass()

func _pass1_arm_restart(sections: Dictionary, archive_paths: PackedStringArray, new_hash: String) -> bool:
	_log_info("Preparing two-pass restart -- %d archive(s)" % archive_paths.size())
	if sections.prepend.size() > 0:
		_log_info("  %d early autoload(s) in [autoload_prepend]" % sections.prepend.size())
	# Deferred: Pass 1's GDScriptCache is already polluted, so activating would raise a false alarm.
	_generate_hook_pack(true)
	_write_heartbeat()
	if _write_override_cfg(sections.prepend) != OK:
		_log_critical("Failed to write override.cfg (%s) -- single-pass fallback" % _static_cfg_write_error)
		return false
	return _write_pass_state(archive_paths, new_hash) == OK

func _mods_mounted_or_queued() -> bool:
	return not _filescope_mounted.is_empty() or not _archive_file_sets.is_empty() \
			or _pending_autoloads.size() > 0

# Not _filescope_mounted: on a single-pass finish those are the previous session's mounts.
func _finish_single_pass() -> void:
	_finish_boot(not _archive_file_sets.is_empty() or _pending_autoloads.size() > 0)

# Heartbeat and streak clear after the scene reload, the last place a mod can crash the pass.
func _finish_boot(reload_scene: bool) -> bool:
	_boot_complete = true
	_booted_set_signature = _loaded_set_signature()
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
	_emit_frameworks_ready()
	# After frameworks_ready, so the report holds the override check too.
	if _developer_mode:
		_write_conflict_report()
	var reloaded := true
	if reload_scene:
		var err := get_tree().reload_current_scene()
		if err != OK:
			_log_critical("reload_current_scene() failed with error " + str(err))
			reloaded = false
	# A reload error is not a crash: the breaker must not count it.
	_delete_heartbeat()
	_clear_restart_counter()
	return reloaded

func _run_pass_2() -> void:
	_boot_complete = true
	_log_info("Pass 2 -- %d archive(s) mounted at file-scope" % _filescope_mounted.size())
	# A crash before the end makes the next static init force-wipe.
	_static_write_pass2_dirty()
	var pass_cfg := ConfigFile.new()
	if pass_cfg.load(PASS_STATE_PATH) == OK:
		var so_v: Variant = pass_cfg.get_value("state", "script_overrides", [])
		var saved_overrides: Array = so_v if so_v is Array else []
		for entry in saved_overrides:
			if entry is Dictionary and entry.has_all(["vanilla_path", "mod_script_path", "mod_name", "priority"]):
				_pending_script_overrides.append(entry)
			else:
				_log_warning("[Overrides] Malformed entry in pass state -- skipped")
	_apply_script_overrides()
	_scan_game_and_mods()
	_load_ui_config()

	load_all_mods("Pass 2")
	# The streak clears inside the finish and the dirty marker after it, behind the crash window.
	var reloaded := _finish_boot(_mods_mounted_or_queued())
	_static_remove_file(PASS2_DIRTY_PATH)
	if not reloaded:
		return
	# Windows hands foreground away when Pass 1 dies; ask for focus once the window is mapped.
	await get_tree().process_frame
	await get_tree().process_frame
	var win := get_window()
	if win != null:
		win.grab_focus()
		win.request_attention()
