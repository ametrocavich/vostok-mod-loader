## ----- logging.gd -----
## _log_info/_log_warning/_log_critical/_log_debug print (or push_*) and append
## to _report_lines for the developer-mode conflict report; _log_debug is a
## no-op outside developer mode. Registry verbs called by mods use push_warning
## directly, which reaches the console but never the report. load_all_mods
## clears _report_lines; _report_append caps it so a per-frame logger cannot
## grow it forever.

# Boot fills a few hundred lines; hitting the cap means a runaway caller.
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
