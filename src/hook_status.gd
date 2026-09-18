## ----- hook_status.gd -----
## What happened to the hook system last session, kept where the launcher
## can read it. Hook-pack generation and activation run after the launcher
## has closed, so a game update that breaks the rewriter would otherwise be
## visible only in the log: mods load, hook-based mods silently do nothing.
## Each generation writes one small record; the next launcher shows a
## banner when that record says hooks did not work.

const HOOK_STATUS_PATH := "user://modloader_hook_status.json"
# Written by static init when the game build changed (executable mtime or
# PCK stamp); cleared by the next healthy hook activation.
const GAME_UPDATED_MARKER_PATH := "user://modloader_game_updated"

# state values a record can carry
const HOOK_STATE_OK := "ok"
const HOOK_STATE_UNSUPPORTED_GDSC := "unsupported_gdsc"
const HOOK_STATE_DETOK_FAILED := "detok_failed"
const HOOK_STATE_ALL_FAILED := "all_failed"
const HOOK_STATE_CRITICAL_FAILED := "critical_failed"
const HOOK_STATE_PACK_FAILED := "pack_failed"


## Record the outcome of this session's hook work. `fields` carries at least
## "state"; the loader version and the game build (executable mtime, PCK
## stamp) are added so a record from another loader build or another game
## build is ignored.
func _hook_status_write(fields: Dictionary) -> void:
	var rec := fields.duplicate()
	rec["loader_version"] = MODLOADER_VERSION
	rec["exe_mtime"] = FileAccess.get_modified_time(OS.get_executable_path())
	rec["pck_stamp"] = _game_pck_stamp()
	rec["written_at"] = int(Time.get_unix_time_from_system())
	var f := FileAccess.open(HOOK_STATUS_PATH, FileAccess.WRITE)
	if f != null:
		f.store_string(JSON.stringify(rec))
		f.close()
	if str(rec.get("state", "")) == HOOK_STATE_OK and int(rec.get("attempted", 0)) > 0:
		# Hooks worked on this game build; the update notice has served.
		if FileAccess.file_exists(GAME_UPDATED_MARKER_PATH):
			DirAccess.remove_absolute(ProjectSettings.globalize_path(GAME_UPDATED_MARKER_PATH))


## The last record, or {} when there is none, it was written by a different
## loader build, or the game's executable or PCK has changed since.
func _hook_status_read() -> Dictionary:
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
	return rec


## Static-init side: the game executable changed. Written before any
## instance exists, so this is a static helper on a bare path.
static func _static_mark_game_updated() -> void:
	var f := FileAccess.open(GAME_UPDATED_MARKER_PATH, FileAccess.WRITE)
	if f != null:
		f.store_string(str(FileAccess.get_modified_time(OS.get_executable_path())))
		f.close()


## What the launcher should tell the player, or {} when nothing is wrong.
## {"severity": "error"|"notice", "text": String}. A failure record beats
## the game-updated notice: it is the more specific of the two.
func _hook_status_problem() -> Dictionary:
	var rec := _hook_status_read()
	var state := str(rec.get("state", ""))
	match state:
		HOOK_STATE_UNSUPPORTED_GDSC:
			return {"severity": "error", "text":
					"This version of Road to Vostok stores its scripts in a format (v%d) this mod loader does not understand. Mods still load, but hooks and the registry do nothing until the loader is updated." % int(rec.get("gdsc_version", 0))}
		HOOK_STATE_DETOK_FAILED:
			return {"severity": "error", "text":
					"The loader could not read this version of Road to Vostok's scripts correctly. Mods still load, but hooks and the registry do nothing until the loader is updated."}
		HOOK_STATE_ALL_FAILED:
			return {"severity": "error", "text":
					"Last time the game ran, none of the loader's %d script rewrites took effect, so hook-based mods did nothing. This usually follows a game update; check for a loader update." % int(rec.get("attempted", 0))}
		HOOK_STATE_CRITICAL_FAILED:
			var names: Array = rec.get("critical_failures", []) if rec.get("critical_failures") is Array else []
			var shown := PackedStringArray()
			for n in names:
				shown.append(str(n).get_file())
			return {"severity": "error", "text":
					"Last time the game ran, hooks did not work on %s. Mods that change those scripts did nothing. This usually follows a game update; check for a loader update." % ", ".join(shown)}
		HOOK_STATE_PACK_FAILED:
			return {"severity": "error", "text":
					"Last time the game ran, the loader could not build or mount its hook pack, so hook-based mods did nothing. Check the free space on your disk; if it keeps happening, check for a loader update."}
	if FileAccess.file_exists(GAME_UPDATED_MARKER_PATH):
		return {"severity": "notice", "text":
				"Road to Vostok was updated. The loader rebuilt its script cache for the new version. If hook-based mods stop working, check for a loader update."}
	return {}
