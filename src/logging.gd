## ----- logging.gd -----
## Thin logging helpers used by every domain. Each helper both emits via
## Godot's print/push_* and appends to _report_lines for the conflict report.
##
## SINK CONTRACT -- what lands where:
##   _log_info(msg)      print        + _report_lines
##   _log_warning(msg)   push_warning + _report_lines
##   _log_critical(msg)  push_error   + _report_lines
##   _log_debug(msg)     print        + _report_lines, but only when
##                       _developer_mode is true; otherwise a full no-op.
##   push_warning(...)   direct calls (most of the registry layer today)
##                       reach the Godot console/debugger only. They
##                       never appear in the conflict report. scene_nodes.gd
##                       mixes both sinks; the registry layer has no single
##                       convention yet.
##   _write_filescope_log  static-init only (fs_archive.gd/boot.gd):
##                       prints + writes user://modloader_filescope.log.
##                       Use for code that runs before instance state
##                       exists.
##
## The conflict report (CONFLICT_REPORT_PATH) is written by
## _write_conflict_report only when _developer_mode is on, at the end of
## each finish path. Two implicit rules follow:
##   - load_all_mods() CLEARS _report_lines at its start, so anything
##     logged earlier in a pass never reaches the report file.
##   - registry verbs called from gameplay-time hooks run after the report
##     was written, so lines appended then are never flushed. _report_append
##     caps the buffer for that reason: a mod calling a logging registry verb
##     every frame would otherwise grow it for the whole session.
## Convention for new code: boot/discovery/loading-path events an
## operator should see in the report -> _log_*. Author-facing complaints
## from mod-called API verbs at runtime -> push_warning.

# Upper bound on the in-memory report buffer. Boot fills a few hundred lines;
# the cap only engages when something logs continuously after the report has
# already been written, which is always a runaway caller.
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
