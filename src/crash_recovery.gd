## Crash detection across restarts: the crash streak and its breaker, the
## launcher notice, the heartbeat, safe mode and the pass-state restart counter.

# Consecutive crashed restart attempts, shared by the static writer and the instance readers.
static func _static_read_crash_streak() -> int:
	if not FileAccess.file_exists(CRASH_STREAK_PATH):
		return 0
	var f := FileAccess.open(CRASH_STREAK_PATH, FileAccess.READ)
	if f == null:
		return 0
	var text := f.get_as_text().strip_edges()
	f.close()
	# Hand-editable file: garbage reads as "no streak" rather than tripping the breaker.
	return maxi(0, text.to_int()) if text.is_valid_int() else 0

static func _static_write_crash_streak(value: int) -> void:
	if value <= 0:
		_static_remove_file(CRASH_STREAK_PATH)
		return
	_write_text(CRASH_STREAK_PATH, str(value))

# True when the last MAX_RESTART_COUNT two-pass attempts all died before finishing.
func _crash_breaker_tripped() -> bool:
	return _static_read_crash_streak() >= MAX_RESTART_COUNT

# The breaker trips after the launcher has closed; the count waits for the next one.
func _write_crash_breaker_notice(count: int) -> void:
	_write_text(CRASH_NOTICE_PATH, str(count))

# A breaker trip from the previous launch (shown once when consume is set),
# else a live streak, else {}.
func _crash_notice_problem(consume: bool) -> Dictionary:
	if FileAccess.file_exists(CRASH_NOTICE_PATH):
		var text := FileAccess.get_file_as_string(CRASH_NOTICE_PATH).strip_edges()
		var count := text.to_int() if text.is_valid_int() else MAX_RESTART_COUNT
		if consume:
			_static_remove_file(CRASH_NOTICE_PATH)
		return {"severity": "error", "text":
				"The game crashed %d time(s) in a row while starting with mods, so the last launch skipped the restart and loaded mods in a single pass; use Launch vanilla to check whether a mod is the cause." % count}
	var streak := _static_read_crash_streak()
	if streak > 0:
		return {"severity": "warning", "text":
				"The last %d launch(es) with mods did not reach the game; if the next one fails too, the loader skips the restart and loads mods in a single pass." % streak}
	return {}

func _write_heartbeat() -> void:
	_write_text(HEARTBEAT_PATH, "started:%d" % Time.get_unix_time_from_system())

func _delete_heartbeat() -> void:
	_static_remove_file(HEARTBEAT_PATH)

func _reset_to_unmodded_state() -> void:
	_restore_clean_override_cfg()
	_static_remove_file(PASS_STATE_PATH)

# restart_count dies with pass state in the crashed-Pass-2 wipe; the streak file
# survives it and drives _crash_breaker_tripped (Stability-Canaries.md).
func _check_crash_recovery() -> void:
	if not FileAccess.file_exists(HEARTBEAT_PATH):
		return
	_log_warning("Heartbeat detected -- previous launch may have crashed")
	var cfg := ConfigFile.new()
	if cfg.load(PASS_STATE_PATH) == OK:
		var count := _state_int(cfg, "restart_count", 0)
		if count >= MAX_RESTART_COUNT:
			_log_critical("Restart loop (%d crashes) -- resetting to clean state" % count)
			_reset_to_unmodded_state()
	_delete_heartbeat()

func _check_safe_mode() -> void:
	var safe_path := _static_exe_dir().path_join(SAFE_MODE_FILE)
	if not FileAccess.file_exists(safe_path):
		return
	_log_warning("Safe mode file detected -- resetting to clean state")
	_reset_to_unmodded_state()
	_delete_heartbeat()
	DirAccess.remove_absolute(safe_path)

func _clear_restart_counter() -> void:
	# Unconditional: a clean finish after the crash wipe has no pass state, and
	# the guarded path below would leave the streak set forever.
	_static_write_crash_streak(0)
	var cfg := ConfigFile.new()
	if cfg.load(PASS_STATE_PATH) == OK:
		if _state_int(cfg, "restart_count", 0) == 0:
			return
		cfg.set_value("state", "restart_count", 0)
		cfg.save(PASS_STATE_PATH)
