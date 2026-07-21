## ----- logging.gd -----
## Thin logging helpers used by every domain. Each helper both emits via
## Godot's print/push_* and appends to _report_lines for the conflict report.
##
## SINK CONTRACT -- what lands where:
##   _log_info(msg)      print        + _report_lines
##   _log_warning(msg)   push_warning + _report_lines
##   _log_critical(msg)  push_error   + _report_lines
##   _log_debug(msg)     print        + _report_lines, but ONLY when
##                       _developer_mode is true; otherwise a full no-op.
##   push_warning(...)   direct calls (most of the registry layer today)
##                       reach the Godot console/debugger only -- they
##                       NEVER appear in the conflict report. (scene_nodes.gd
##                       mixing both sinks is quality-plan item B8; a wider
##                       registry-layer convention is still an open call.)
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
##   - registry verbs called from gameplay-time hooks run after the
##     report was written; report lines appended then are never flushed
##     and only grow memory.
## Convention for new code: boot/discovery/loading-path events an
## operator should see in the report -> _log_*. Author-facing complaints
## from mod-called API verbs at runtime -> push_warning.

func _log_info(msg: String) -> void:
	var line := "[ModLoader][Info] " + msg
	print(line)
	_report_lines.append(line)

func _log_warning(msg: String) -> void:
	var line := "[ModLoader][Warning] " + msg
	push_warning(line)
	_report_lines.append(line)

func _log_critical(msg: String) -> void:
	var line := "[ModLoader][Critical] " + msg
	push_error(line)
	_report_lines.append(line)

func _log_debug(msg: String) -> void:
	if not _developer_mode:
		return
	var line := "[ModLoader][Debug] " + msg
	print(line)
	_report_lines.append(line)
