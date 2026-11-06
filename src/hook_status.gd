## Last session's hook outcome, written after the launcher closed and read by
## the next launcher's banner.

const HOOK_STATUS_PATH := "user://modloader_hook_status.json"

const HOOK_STATE_OK := "ok"
const HOOK_STATE_UNSUPPORTED_GDSC := "unsupported_gdsc"
const HOOK_STATE_DETOK_FAILED := "detok_failed"
const HOOK_STATE_ALL_FAILED := "all_failed"
const HOOK_STATE_CRITICAL_FAILED := "critical_failed"
const HOOK_STATE_PACK_FAILED := "pack_failed"
const HOOK_STATE_DEMOTED := "demoted"

# The loader version and game build are stamped so a record from another
# loader or game build is ignored.
func _hook_status_write(fields: Dictionary) -> void:
	var rec := fields.duplicate()
	rec["loader_version"] = MODLOADER_VERSION
	rec["exe_mtime"] = FileAccess.get_modified_time(OS.get_executable_path())
	rec["pck_stamp"] = _game_pck_stamp()
	# For a person reading the file; the loader never reads it back.
	rec["written_at"] = int(Time.get_unix_time_from_system())
	var f := FileAccess.open(HOOK_STATUS_PATH, FileAccess.WRITE)
	if f != null:
		f.store_string(JSON.stringify(rec))
		f.close()

# {"severity", "text"} for the launcher banner, or {} when nothing is wrong.
# A game update alone says nothing: only a recorded failure speaks.
func _hook_status_problem() -> Dictionary:
	if not FileAccess.file_exists(HOOK_STATUS_PATH):
		return {}
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(HOOK_STATUS_PATH))
	if not (parsed is Dictionary):
		return {}
	var rec: Dictionary = parsed
	if str(rec.get("loader_version", "")) != MODLOADER_VERSION:
		return {}
	var mtime_v: Variant = rec.get("exe_mtime", 0)
	var mtime := int(mtime_v) if (mtime_v is int or mtime_v is float) else 0
	if mtime != FileAccess.get_modified_time(OS.get_executable_path()):
		return {}
	var rec_pck_stamp := str(rec.get("pck_stamp", ""))
	var pck_stamp := _game_pck_stamp()
	if rec_pck_stamp != "" and pck_stamp != "" and rec_pck_stamp != pck_stamp:
		return {}
	var state := str(rec.get("state", ""))
	var text := ""
	match state:
		HOOK_STATE_UNSUPPORTED_GDSC:
			text = "This version of Road to Vostok stores its scripts in a format (v%d) this mod loader does not understand. Mods still load, but hooks and the registry do nothing until the loader is updated." % int(rec.get("gdsc_version", 0))
		HOOK_STATE_DETOK_FAILED:
			text = "The loader could not read this version of Road to Vostok's scripts correctly. Mods still load, but hooks and the registry do nothing until the loader is updated."
		HOOK_STATE_ALL_FAILED:
			text = "Last time the game ran, none of the loader's %d script rewrites took effect, so hook-based mods did nothing. This usually follows a game update; check for a loader update." % int(rec.get("attempted", 0))
		HOOK_STATE_CRITICAL_FAILED:
			text = "Last time the game ran, hooks did not work on %s. Mods that change those scripts did nothing. This usually follows a game update; check for a loader update." % ", ".join(_status_names(rec, "critical_failures"))
		HOOK_STATE_DEMOTED:
			text = "The loader's changes to %s do not fit this version of Road to Vostok, so it left them out. The game runs normally, but mods that hook or register against those scripts do nothing. This usually follows a game update; check for a loader update." % ", ".join(_status_names(rec, "demoted"))
		HOOK_STATE_PACK_FAILED:
			text = "Last time the game ran, the loader could not build or mount its hook pack, so hook-based mods did nothing. Check the free space on your disk; if it keeps happening, check for a loader update."
	if text != "":
		return {"severity": "error", "text": text}
	if state != HOOK_STATE_OK:
		return {}
	# A target missing from the game, one the loader skipped, and a script with methods
	# left out each get their own line; the mod's other hooks fire.
	var parts: Array = []
	for c in [["lost", "Last time the game ran, %d hook target(s) a mod asked for were not found in the game's scripts, so those hooks did nothing: %s%s. This usually follows a game update; check for an update of that mod."],
			["skipped", "Last time the game ran, the loader skipped %d hook target(s) a mod asked for, so those hooks did nothing: %s%s."],
			["partial", "Last time the game ran, %d hooked script(s) wrapped only part of what a mod asked for; what is listed did not take effect: %s%s."]]:
		var lines_v: Variant = rec.get(c[0], [])
		var lines: Array = lines_v if lines_v is Array else []
		if lines.is_empty():
			continue
		var shown: Array = lines.slice(0, 3).map(func(l): return str(l))
		var more := " (and %d more)" % (lines.size() - 3) if lines.size() > 3 else ""
		parts.append(c[1] % [lines.size(), "; ".join(shown), more])
	if parts.is_empty():
		return {}
	return {"severity": "warning", "text": "\n".join(parts)}

# The file names in rec[key], [] when the hand-editable record lacks the list.
func _status_names(rec: Dictionary, key: String) -> Array:
	var names: Variant = rec.get(key, [])
	return names.map(func(n): return str(n).get_file()) if names is Array else []
