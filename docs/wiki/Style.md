# Style

The loader is one GDScript class assembled from `src/`. These rules decide
what a line has to earn to stay. Every example below is from this tree.

## Rules

1. A comment answers "why" with a fact the code cannot show: an engine quirk,
   an ordering a harness pins, a format another program reads. Everything
   else goes: banners, restated signatures, narrated reasoning, dates,
   versions, finding ids, sessions, previous shapes of the code. A file
   header is at most two lines. A doc comment is at most two lines.
2. A helper with one caller is inlined unless it is recursive, a Callable
   target, static-init reachable, or named by a test, a check script or a
   wiki page. Two helpers that do one thing become one.
3. A name says what the function does, in at most 30 characters. A file
   prefix (`_hosted_`, `_browse_`, `_mods_`, `_modpack_`, `_hook_pack_`,
   `_static_`) stays only where two files would otherwise collide, or where
   the function must be static. `static func` already says static.
4. A guard stays only when the failing case is reachable and a test shows
   it. A value this class produced is not re-checked for its type; a key
   this class always writes has no default.
5. One prefix per subsystem, one line per event, under 100 characters.
   A player-facing string is one sentence.
6. A test block loops over a table instead of repeating itself; an assertion
   message is at most eight words; a runner header is two lines.
7. Behavior is not a style choice. Order of side effects, early returns,
   default values, public signatures and every string a test or a player
   sees stay as they are. Generated-code names (`_rtv_*`, `_caller`,
   `_skip_super`, `_wrapper_active`, `_any_mod_hooked`, `_hooked_bases`,
   `_dispatch*`), `hooks_api.gd` public methods, `setup()`, the Registry
   verbs and result shapes, the Engine meta keys, the file formats and the
   lines a `--prove` mutation in a check script matches are frozen.
   Plain ASCII everywhere. "Vostok Mods" is two words in player copy.

## Examples

### A comment

```gdscript
# slop (profiles.gd)
	if err == ERR_FILE_NOT_FOUND and _ui_cfg_load_bak(cfg):
		# A live file deleted mid-session: write on top of the backup rather than
		# start empty, or the next save would roll a near-empty file over it.
		_log_warning("[Config] " + UI_CONFIG_PATH + " is missing; continuing from the .bak contents")

# human
	if err == ERR_FILE_NOT_FOUND and _ui_cfg_load_bak(cfg):
		_log_warning("[Config] " + UI_CONFIG_PATH + " is missing; continuing from the .bak contents")
```

The log line already says it. A comment that survives looks like this one
from `hook_pack.gd`, because nothing in the code shows the engine rule:

```gdscript
	# Godot prefers a sibling .gdc even after the remap; an empty one fails to
	# parse and falls back to the .gd.
```

### A helper to inline

```gdscript
# slop (mod_downloads.gd): four names for one idea
func _update_failure(target_path: String, msg: String, local := false) -> Dictionary:
func _install_failure(msg: String) -> Dictionary:
func _fail_download(temp_path: String, failure: Dictionary) -> Dictionary:
func _fail_update(target_path: String, temp_path: String, msg: String) -> Dictionary:
	return _fail_download(temp_path, _update_failure(target_path, msg, true))

# human: one function; callers that have a temp file pass it
func _fail(msg: String, target_path := "", temp_path := "", local := false) -> Dictionary:
```

### A name

```gdscript
# slop
static func _static_write_clean_override_cfg(cfg_path: String) -> bool:
func _unlock_crafting_category_button_if_needed(category: String) -> void:
func _hook_pack_write_entries(zp: ZIPPacker, script_path: String, rewritten: String) -> String:

# human
static func _reset_override_cfg(cfg_path: String) -> bool:
func _unlock_crafting_button(category: String) -> void:
func _write_pack_entries(zp: ZIPPacker, script_path: String, rewritten: String) -> String:
```

Rename only after `grep -rn <name> tests/ check*.sh docs/wiki/` is empty,
or when the batch owns every file that came up.

### A guard to drop

```gdscript
# slop (ui_modpacks.gd): r came from _hosted_refresh_pack in this class,
# which always writes "ok"
	var r: Dictionary = await _hosted_refresh_pack(entry)
	if not bool(r.get("ok", false)):

# human
	var r: Dictionary = await _hosted_refresh_pack(entry)
	if not r["ok"]:
```

`is_instance_valid` after an `await` stays only in UI code where the
launcher can close during the wait (T69 and the Get-button fix show the
case). A `typeof` or `is Dictionary` check on a value this class built goes.

### A log line

```gdscript
# slop (registry.gd)
	push_warning("[Registry] %s: '%s' is declared in the Registry const but %s neither handles nor refuses it -- unwired section (loader bug, see \"Adding a registry section\" in docs/wiki/Development.md), not a mod typo" % [verb, registry, verb])

# human
	push_warning("[Registry] %s: '%s' is declared but unwired (loader bug)" % [verb, registry])
```

Keep the prefix a test or `tests/ingame/lts/evaluate.py` greps for
(`[ModLoader][Critical]`, `[STABILITY]`, `=== Load Order`,
`does not compile against this game build`, `Repeating the last probe's
verdicts`).

### A test block

```gdscript
# slop (boot_state runner, T31): the same seven lines twice
	_assert(mounted is Dictionary and (mounted as Dictionary).has(zip_a),
			"T31: a loader version change still mounts the previous session's archives (got %s)" % str(mounted))
	_assert(FileAccess.file_exists("res://t31_marker_a/hello.txt"),
			"T31: the archive's files are reachable after a loader version change")
	...
	_assert(mounted is Dictionary and (mounted as Dictionary).has(zip_b),
			"T31: a game update still mounts the previous session's archives (got %s)" % str(mounted))

# human
	for c in [["version", "0.0.0-harness", 0], ["game update", MODLOADER_VERSION, 1]]:
		var zip := _seed_previous_session(c[1], c[2])
		var mounted: Dictionary = _ml.call("_mount_previous_session")
		_assert(mounted.has(zip), "T31 %s: archives mounted" % c[0])
		_assert(FileAccess.file_exists("res://t31/hello.txt"), "T31 %s: files reachable" % c[0])
		_assert(not FileAccess.file_exists(_pass_state_path), "T31 %s: pass state dropped" % c[0])
```

The assertion count does not fall. A runner header is the harness name and
what it does not prove, in two lines; the "WHY THIS EXISTS" essay goes.
