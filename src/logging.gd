## The four loggers print or push and feed _report_lines, the developer-mode
## conflict report; _log_debug is a no-op outside developer mode.

# Boot fills a few hundred lines; hitting the cap means a runaway caller.
const REPORT_LINES_MAX := 5000

func _report_append(line: String) -> void:
	if _report_lines.size() < REPORT_LINES_MAX:
		_report_lines.append(line)
	elif _report_lines.size() == REPORT_LINES_MAX:
		_report_lines.append("[ModLoader][Warning] Report buffer hit %d lines; further lines are dropped. Something is logging on a per-frame path." % REPORT_LINES_MAX)

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
