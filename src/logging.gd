## ----- logging.gd -----
## Logging helpers. Each _log_* both emits via print/push_* and appends to
## _report_lines for the conflict report; _log_debug only in developer mode.
## Direct push_warning calls (most of the registry layer) reach the console
## only, never the report. _write_filescope_log is static-init only: prints +
## writes user://modloader_filescope.log.
##
## The conflict report is written only in developer mode, at the end of each
## finish path. load_all_mods() clears _report_lines at its start, and lines
## appended after the report is written are never flushed -- _report_append
## caps the buffer for that reason. Convention: boot/discovery/loading events
## -> _log_*; author-facing complaints from mod-called verbs -> push_warning.

# Report buffer cap; boot fills a few hundred lines, so hitting it means a
# runaway caller.
const REPORT_LINES_MAX := 5000

func _report_append(line: String) -> void:
	if _report_lines.size() >= REPORT_LINES_MAX:
		if _report_lines.size() == REPORT_LINES_MAX:
			_report_lines.append("[ModLoader][Warning] Report buffer hit %d lines; further lines are dropped. Something is logging on a per-frame path." % REPORT_LINES_MAX)
		return
	_report_lines.append(line)

func _log_info(msg: String) -> void:
	var line := "[ModLoader][Info] " + msg
	print(line)
	_report_append(line)

func _log_warning(msg: String) -> void:
	var line := "[ModLoader][Warning] " + msg
	push_warning(line)
	_report_append(line)

func _log_critical(msg: String) -> void:
	var line := "[ModLoader][Critical] " + msg
	push_error(line)
	_report_append(line)

func _log_debug(msg: String) -> void:
	if not _developer_mode:
		return
	var line := "[ModLoader][Debug] " + msg
	print(line)
	_report_append(line)
