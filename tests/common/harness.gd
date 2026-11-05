## Static helpers for the headless runners (const H := preload("res://harness.gd")).
## Report: new(tag, scope), begin(id), check(), check_eq(), check_num(), fail(), finish(tree).
extends RefCounted

const PACK_ZIP := "user://host_round_trip.zip"

## One runner's tally. begin(id) prefixes later failures with "id: ", so a
## message never repeats the test id.
class Report:
	var prefix: String
	var scope: String
	var id := ""
	var assertions := 0
	var failures: PackedStringArray = []

	func _init(p_prefix: String, p_scope: String) -> void:
		prefix = p_prefix
		scope = p_scope

	func begin(p_id: String) -> void:
		id = p_id

	func check(cond: bool, msg: String) -> bool:
		assertions += 1
		if not cond:
			fail(msg)
		return cond

	## Equal values of one type (an int never equals a float); a miss reads
	## "what (got X, want Y)" on one line.
	func check_eq(got: Variant, want: Variant, what: String) -> bool:
		return _check_same(typeof(got) == typeof(want) and got == want, got, want, what)

	## Equal numbers, int or float alike.
	func check_num(got: Variant, want: Variant, what: String) -> bool:
		var numbers := [TYPE_INT, TYPE_FLOAT]
		var same: bool = typeof(got) in numbers and typeof(want) in numbers and got == want
		return _check_same(same, got, want, what)

	func _check_same(same: bool, got: Variant, want: Variant, what: String) -> bool:
		var msg := "%s (got %s, want %s)" % [what, var_to_str(got), var_to_str(want)]
		return check(same, msg.replace("\n", "\\n").replace("\t", "\\t"))

	func fail(msg: String) -> void:
		failures.append(msg if id == "" else id + ": " + msg)

	func ok() -> bool:
		return failures.is_empty()

	## Prints the PASS line, or every FAIL line and the FAILED total, and quits
	## the runner's tree with 0 or 1. A run with no assertions fails.
	func finish(tree: SceneTree) -> void:
		if assertions == 0:
			fail("no assertions ran")
		if failures.is_empty():
			print("[%s] PASS: %d assertion(s) across %s" % [prefix, assertions, scope])
			tree.quit(0)
			return
		for m in failures:
			printerr("[%s] FAIL: %s" % [prefix, m])
		printerr("[%s] FAILED: %d of %d assertion(s)" % [prefix, failures.size(), assertions])
		tree.quit(1)

## A zip at user_path holding each entries key as a file with that value's
## text. Returns the absolute path; a failure to create it is a report failure.
static func write_zip(user_path: String, entries: Dictionary, report: Report) -> String:
	var abs_path := ProjectSettings.globalize_path(user_path)
	var zp := ZIPPacker.new()
	if zp.open(abs_path, ZIPPacker.APPEND_CREATE) != OK:
		report.fail("harness could not create " + abs_path)
		return abs_path
	for name in entries.keys():
		zp.start_file(str(name))
		zp.write_file(str(entries[name]).to_utf8_buffer())
		zp.close_file()
	zp.close()
	return abs_path

## s on one log line: newlines and tabs spelled out.
static func oneline(s: String) -> String:
	return s.replace("\n", "\\n").replace("\t", "\\t")

## Writes text to path, creating its directory. False when it cannot open it.
static func write_text(path: String, text: String) -> bool:
	return write_bytes(path, text.to_utf8_buffer())

## Writes buf to path, creating its directory. False when it cannot open it.
static func write_bytes(path: String, buf: PackedByteArray) -> bool:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(path.get_base_dir()))
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return false
	f.store_buffer(buf)
	f.close()
	return true

static func remove_user_file(path: String) -> void:
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(path))

## A ConfigFile parsed from fixture text; a parse failure is a report failure.
static func cfg_from_text(text: String, report: Report) -> ConfigFile:
	var cfg := ConfigFile.new()
	if cfg.parse(text) != OK:
		report.fail("fixture mod.txt failed to parse: " + oneline(text))
	return cfg

## v as `width` little-endian bytes (GDSC and PCK header fields).
static func uint_le(v: int, width := 4) -> PackedByteArray:
	var out := PackedByteArray()
	for i in width:
		out.append((v >> (8 * i)) & 0xFF)
	return out

## An installed-mod row carrying every key _entry_from_config writes; keys in
## overrides replace the defaults.
static func mod_entry(profile_key: String, mod_id: String, version: String, overrides := {}) -> Dictionary:
	var e := {
		"file_name": mod_id + ".zip", "full_path": "/nonexistent/" + mod_id + ".zip", "ext": "zip",
		"mod_name": mod_id, "mod_id": mod_id, "version": version, "profile_key": profile_key,
		"enabled": true, "priority": 0, "priority_default": 0, "cfg": null,
		"required_dependencies": [], "optional_dependencies": [], "provides": [],
		"dependency_warnings": [], "dependency_blockers": [], "dependency_blockers_info": [],
		"dependency_ignored": false, "mod_txt_status": "", "mod_txt_error": "", "has_registry": false,
	}
	e.merge(overrides, true)
	return e

## Removes mod_config.cfg and its .bak, zip, user://MCM and the profile
## snapshots, and empties the loader's mod and pack lists.
static func pack_cleanup(ml: Object, zip := PACK_ZIP) -> void:
	var cfg_path := str(ml.UI_CONFIG_PATH)
	for p in [cfg_path, cfg_path + ".bak", zip]:
		remove_user_file(p)
	for d in ["user://MCM", "user://.profile_snapshots"]:
		if DirAccess.dir_exists_absolute(ProjectSettings.globalize_path(d)):
			ml._remove_tree(d, false)
	var none: Array[Dictionary] = []
	ml.set("_ui_mod_entries", none)
	ml.set("_modpack_entries", none)

## Forgets the indexed game PCK, so the next read looks for it again.
static func reset_pck_state(ml: Object) -> void:
	ml.set("_game_pck_index", {})
	ml.set("_game_pck_path", "")
	ml.set("_game_pck_indexed", false)
	ml.set("_vanilla_cache_checked", false)

## Calls visit(rel, abs, is_dir) for every entry under abs_dir, children before
## their directory. The top-level logs/ is skipped: the engine holds it open.
static func walk_dir(abs_dir: String, visit: Callable, rel := "") -> void:
	for e in DirAccess.get_directories_at(abs_dir):
		var child: String = e if rel == "" else rel + "/" + e
		if child != "logs":
			walk_dir(abs_dir.path_join(e), visit, child)
			visit.call(child, abs_dir.path_join(e), true)
	for e in DirAccess.get_files_at(abs_dir):
		visit.call(e if rel == "" else rel + "/" + e, abs_dir.path_join(e), false)

## Empties user:// except logs/.
static func wipe_user() -> void:
	var remove := func(_rel: String, path: String, _is_dir: bool) -> void:
		DirAccess.remove_absolute(path)
	walk_dir(ProjectSettings.globalize_path("user://"), remove)

## user:// as {"dir/": "<dir>", "file": "size:base64"}, keys relative to user://.
static func snapshot_user() -> Dictionary:
	var out := {}
	var record := func(rel: String, path: String, is_dir: bool) -> void:
		if is_dir:
			out[rel + "/"] = "<dir>"
		else:
			var bytes := FileAccess.get_file_as_bytes(path)
			out[rel] = "%d:%s" % [bytes.size(), Marshalls.raw_to_base64(bytes)]
	walk_dir(ProjectSettings.globalize_path("user://"), record)
	return out
