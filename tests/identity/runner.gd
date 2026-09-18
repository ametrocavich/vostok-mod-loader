## runner.gd -- mod-identity harness. NOT part of the shipped loader.
## Executed by check_identity.sh inside a THROWAWAY Godot project assembled
## under the system temp dir; never run it against this repo or against the
## Road to Vostok install.
##
## WHY THIS EXISTS: a mod whose mod.txt declares no id= is identified by its
## filename. Re-packaging it under a different extension or version suffix
## used to produce a second, separate identity, which meant two copies of the
## same mod both mounted and load order decided which body of code actually
## ran. The reported symptom was "I edited my mod and it keeps running the old
## code, but renaming it back fixes it".
##
## The fix is a normalized filename stem, which is a heuristic: too greedy and
## it merges two genuinely different mods, too strict and the original bug
## comes back. Both directions are asserted below.
extends SceneTree

const MODLOADER_PATH := "res://modloader_neutered.gd"

# file name -> expected normalized stem
const STEM_CASES: Array = [
	# The reported case: same mod, different container extension.
	["CoolMod.zip", "coolmod"],
	["CoolMod.vmz", "coolmod"],
	["CoolMod.pck", "coolmod"],
	# Version suffixes an author bumps between releases.
	["CoolMod_v1.0.zip", "coolmod"],
	["CoolMod_v1.1.zip", "coolmod"],
	["CoolMod-1.2.3.zip", "coolmod"],
	["CoolMod v2.vmz", "coolmod"],
	["CoolModv2.zip", "coolmod"],
	["CoolMod.1.0.zip", "coolmod"],
	# Case folding.
	["COOLMOD.ZIP", "coolmod"],
	# A digit with no separator reads as part of the name. Collapsing it would
	# merge two different mods, so it must survive.
	["CoolMod2.zip", "coolmod2"],
	["Mod4Fun.zip", "mod4fun"],
	# Nothing left over after stripping: keep the stem rather than return "".
	["1.2.zip", "1.2"],
	["v2.zip", "v2"],
	# Names that carry no version token at all.
	["A Mod With Spaces.zip", "a mod with spaces"],
	["under_score.zip", "under_score"],
	# A trailing integer after a SPACE stays part of the name: "Ammo Pack 1" and
	# "Ammo Pack 2" are different mods. An explicit v, or a dotted version, still
	# strips. These pin the STEM, not just the collapse -- a same-stem assertion
	# alone cannot tell "ammo pack" from "ammo pack 1", since both spellings
	# collapse the pair either way.
	["Ammo Pack 1.zip", "ammo pack 1"],
	["Ammo Pack 2.zip", "ammo pack 2"],
	["Ammo Pack v2.zip", "ammo pack"],
	["Ammo Pack 1.2.zip", "ammo pack"],
	["Ammo Pack 10.zip", "ammo pack 10"],
]

var _failures: PackedStringArray = []
var _assertions := 0

func _init() -> void:
	print("[identity] harness start")

func _process(_delta: float) -> bool:
	_run()
	return true

func _run() -> void:
	var ml_script := load(MODLOADER_PATH) as GDScript
	if ml_script == null:
		_fail("could not load " + MODLOADER_PATH)
		_finish()
		return
	var ml: Object = ml_script.new()
	var mounted: Variant = ml.get("_filescope_mounted")
	if typeof(mounted) != TYPE_DICTIONARY or not (mounted as Dictionary).is_empty():
		_fail("modloader boot static-init was NOT neutralized -- refusing to run")
		_finish()
		return
	# The stem normalizer reads regexes _ready compiles once per launch.
	ml._compile_regex()

	_t1_stem_table(ml)
	_t2_extension_change_collapses(ml)
	_t3_version_bump_collapses_and_newest_wins(ml)
	_t4_distinct_mods_stay_distinct(ml)
	_t5_declared_id_still_wins(ml)
	_t6_pck_never_collapses(ml)
	_t7_mod_txt_read_record(ml)
	_t8_priority_does_not_leak_between_profiles(ml)
	_t9_repackaged_mod_drops_its_old_key(ml)
	_t10_missing_profile_falls_back_to_a_user_profile(ml)
	_t11_profile_bookkeeping_is_not_a_mod_change(ml)

	_finish()

# --- Tests -------------------------------------------------------------------

func _t1_stem_table(ml: Object) -> void:
	for case in STEM_CASES:
		var got: String = str(ml._normalized_mod_stem(str(case[0])))
		_assert(got == str(case[1]),
				"T1: stem(%s) = '%s', expected '%s'" % [case[0], got, case[1]])

# The exact bug: CoolMod.vmz replaced by CoolMod.zip must be ONE mod.
func _t2_extension_change_collapses(ml: Object) -> void:
	var out: Array = ml._dedupe_by_mod_id(_entries([
		{"file": "CoolMod.vmz", "ver": ""},
		{"file": "CoolMod.zip", "ver": ""},
	]))
	_assert(out.size() == 1, "T2: .vmz + .zip of one mod must collapse to 1 entry, got %d" % out.size())
	if out.size() == 1:
		var hidden: Array = (out[0] as Dictionary).get("duplicates_hidden", [])
		_assert(hidden.size() == 1, "T2: the losing copy must be recorded as hidden, got %d" % hidden.size())

func _t3_version_bump_collapses_and_newest_wins(ml: Object) -> void:
	var out: Array = ml._dedupe_by_mod_id(_entries([
		{"file": "CoolMod_v1.0.zip", "ver": "1.0"},
		{"file": "CoolMod_v1.1.zip", "ver": "1.1"},
	]))
	_assert(out.size() == 1, "T3: two versions must collapse to 1 entry, got %d" % out.size())
	if out.size() == 1:
		_assert(str((out[0] as Dictionary)["file_name"]) == "CoolMod_v1.1.zip",
				"T3: the higher version must win, got %s" % (out[0] as Dictionary)["file_name"])

# The guard against over-merging. These are different mods and must both live.
func _t4_distinct_mods_stay_distinct(ml: Object) -> void:
	var out: Array = ml._dedupe_by_mod_id(_entries([
		{"file": "CoolMod.zip", "ver": ""},
		{"file": "CoolMod2.zip", "ver": ""},
		{"file": "OtherMod.zip", "ver": ""},
	]))
	_assert(out.size() == 3, "T4: three distinct mods must stay three entries, got %d" % out.size())

	# A trailing number after a SPACE reads as part of the name, not a version.
	# "Ammo Pack 1" and "Ammo Pack 2" are two different mods; collapsing them
	# DELETES one from the list, and which one survives is decided by mtime, so
	# it can flip between sessions. An underscore or hyphen is a packaging
	# convention and still means a version; a space is prose.
	var named: Array = ml._dedupe_by_mod_id(_entries([
		{"file": "Ammo Pack 1.zip", "ver": ""},
		{"file": "Ammo Pack 2.zip", "ver": ""},
	]))
	_assert(named.size() == 2,
			"T4: 'Ammo Pack 1' and 'Ammo Pack 2' are distinct mods, got %d entries" % named.size())
	# ... while an explicit version marker after a space still collapses.
	var versioned: Array = ml._dedupe_by_mod_id(_entries([
		{"file": "Ammo Pack v1.zip", "ver": ""},
		{"file": "Ammo Pack v2.zip", "ver": ""},
	]))
	_assert(versioned.size() == 1,
			"T4: 'Ammo Pack v1/v2' is one mod at two versions, got %d entries" % versioned.size())
	var dotted: Array = ml._dedupe_by_mod_id(_entries([
		{"file": "Ammo Pack 1.2.zip", "ver": ""},
		{"file": "Ammo Pack 1.3.zip", "ver": ""},
	]))
	_assert(dotted.size() == 1,
			"T4: 'Ammo Pack 1.2/1.3' is one mod at two versions, got %d entries" % dotted.size())

# A declared id still takes precedence over any filename resemblance.
func _t5_declared_id_still_wins(ml: Object) -> void:
	var a := _entry("Totally.zip", "")
	var b := _entry("Different.zip", "")
	a["mod_id"] = "shared.id"
	b["mod_id"] = "shared.id"
	a["profile_key"] = "shared.id@1.0"
	b["profile_key"] = "shared.id@1.1"
	a["version"] = "1.0"
	b["version"] = "1.1"
	var out: Array = ml._dedupe_by_mod_id([a, b] as Array[Dictionary])
	_assert(out.size() == 1, "T5: same declared id must collapse regardless of filename, got %d" % out.size())

# .pck carries no mod.txt, so a name resemblance is too weak to act on.
func _t6_pck_never_collapses(ml: Object) -> void:
	var a := _entry("Same.pck", "")
	var b := _entry("Same.zip", "")
	a["ext"] = "pck"
	var out: Array = ml._dedupe_by_mod_id([a, b] as Array[Dictionary])
	_assert(out.size() == 2, "T6: a .pck must never be collapsed into another entry, got %d" % out.size())

# read_mod_config returns everything the scanner needs from one archive's
# mod.txt as one record, {cfg, status, error, files}, so nothing from one read
# can leak into the next mod's warnings. The fixture zips are written into the
# throwaway project's user://.
func _t7_mod_txt_read_record(ml: Object) -> void:
	var ok_zip := _write_zip("user://identity_ok.zip",
			{"mod.txt": "[mod]\nname=\"Ok\"\nid=\"ok\"\n", "Ok/Main.gd": "extends Node\n"})
	var nested_zip := _write_zip("user://identity_nested.zip", {"Sub/mod.txt": "[mod]\nname=\"Nested\"\n"})
	var broken_zip := _write_zip("user://identity_broken.zip", {"mod.txt": "[mod\nname=\n"})
	var bare_zip := _write_zip("user://identity_bare.zip", {"Plain/thing.txt": "x"})
	var want_keys := ["cfg", "error", "files", "status"]

	var r: Variant = ml.read_mod_config(ok_zip)
	_assert(r is Dictionary, "T7: read_mod_config returns a record, not a bare ConfigFile")
	if not (r is Dictionary):
		return
	var keys: Array = (r as Dictionary).keys()
	keys.sort()
	_assert(keys == want_keys, "T7: the record has exactly cfg/error/files/status (got %s)" % str(keys))
	_assert(str(r["status"]) == "ok" and r["cfg"] is ConfigFile and str((r["cfg"] as ConfigFile).get_value("mod", "id", "")) == "ok",
			"T7: a root mod.txt reads as ok with its ConfigFile (got status %s)" % str(r["status"]))
	var files: Dictionary = r["files"]
	_assert(files.has("res://mod.txt") and files.has("res://Ok/Main.gd"),
			"T7: the archive's entries are captured as res:// paths (got %s)" % str(files.keys()))

	var nested: Dictionary = ml.read_mod_config(nested_zip)
	_assert(str(nested["status"]) == "nested:Sub/mod.txt" and nested["cfg"] == null,
			"T7: a mod.txt below the root reads as nested:<path> (got %s)" % str(nested["status"]))

	var broken: Dictionary = ml.read_mod_config(broken_zip)
	_assert(str(broken["status"]) == "parse_error" and broken["cfg"] == null and str(broken["error"]) != "",
			"T7: unparseable mod.txt reads as parse_error with a diagnostic (got %s / '%s')" % [str(broken["status"]), str(broken["error"])])

	var bare: Dictionary = ml.read_mod_config(bare_zip)
	_assert(str(bare["status"]) == "none" and bare["cfg"] == null and str(bare["error"]) == "",
			"T7: no mod.txt reads as none with no diagnostic left over (got %s / '%s')" % [str(bare["status"]), str(bare["error"])])

	var missing: Dictionary = ml.read_mod_config(ProjectSettings.globalize_path("user://identity_missing.zip"))
	_assert(str(missing["status"]) == "none" and missing["cfg"] == null,
			"T7: a missing archive reads as none")

	var folder := ProjectSettings.globalize_path("user://identity_folder")
	DirAccess.make_dir_recursive_absolute(folder)
	var f := FileAccess.open(folder.path_join("mod.txt"), FileAccess.WRITE)
	if f != null:
		f.store_string("[mod]\nname=\"Folder\"\nid=\"folder\"\n")
		f.close()
	var fr: Dictionary = ml.read_mod_config_folder(folder)
	_assert(str(fr["status"]) == "ok" and fr["cfg"] is ConfigFile and (fr["files"] as Dictionary).is_empty(),
			"T7: a folder mod reads as ok with no captured file list (got %s)" % str(fr["status"]))

	for p in [ok_zip, nested_zip, broken_zip, bare_zip]:
		DirAccess.remove_absolute(p)
	DirAccess.remove_absolute(folder.path_join("mod.txt"))
	DirAccess.remove_absolute(folder)

# --- Fixture helpers ---------------------------------------------------------

# Write a zip of {entry_name: text} and return its absolute path.
func _write_zip(user_path: String, entries: Dictionary) -> String:
	var abs_path := ProjectSettings.globalize_path(user_path)
	var zp := ZIPPacker.new()
	if zp.open(abs_path, ZIPPacker.APPEND_CREATE) != OK:
		_fail("harness could not create " + abs_path)
		return abs_path
	for name in entries.keys():
		zp.start_file(str(name))
		zp.write_file(str(entries[name]).to_utf8_buffer())
		zp.close_file()
	zp.close()
	return abs_path

# Profile state follows the mod, not the profile that was applied before. A
# profile that stores no priority for a mod applies the mod's own default
# (mod.txt or the filename prefix), never the value the previous profile left
# in memory, which the next save would otherwise write into the new profile.
func _t8_priority_does_not_leak_between_profiles(ml: Object) -> void:
	var mod_txt := ConfigFile.new()
	_assert(mod_txt.parse("[mod]\nname=\"Leaky\"\nid=\"leaky\"\nversion=\"1.0\"\npriority=7\n") == OK,
			"T8: fixture mod.txt parses")
	var read := {"cfg": mod_txt, "status": "ok", "error": "", "files": {}}
	var entry: Dictionary = ml._entry_from_config(read, "Leaky.zip", "/nonexistent/Leaky.zip", "zip")
	_assert(int(entry.get("priority_default", -1)) == 7,
			"T8: the entry records its mod.txt priority as priority_default (got %s)" % str(entry.get("priority_default")))
	var entries: Array[Dictionary] = [entry]
	ml.set("_ui_mod_entries", entries)
	var cfg := ConfigFile.new()
	cfg.set_value("profile.A.enabled", "leaky@1.0", true)
	cfg.set_value("profile.A.priority", "leaky@1.0", 50)
	cfg.set_value("profile.B.enabled", "other@1.0", true)
	ml._apply_profile_to_entries(cfg, "A")
	_assert(int(entry["priority"]) == 50, "T8: profile A's stored priority applies (got %d)" % int(entry["priority"]))
	ml._apply_profile_to_entries(cfg, "B")
	_assert(int(entry["priority"]) == 7,
			"T8: profile B stores none, so the mod's own default applies, not A's 50 (got %d)" % int(entry["priority"]))
	_assert(not bool(entry["enabled"]), "T8: a mod profile B never listed is off there")
	var empty: Array[Dictionary] = []
	ml.set("_ui_mod_entries", empty)

# A mod with no id= is keyed by its filename, and a re-package carries its
# state over by normalized stem. The old "zip:" key is then stale: it must not
# be kept on save (two stored keys with one stem stop the next carry-over) and
# must not show up as a missing mod.
func _t9_repackaged_mod_drops_its_old_key(ml: Object) -> void:
	var cfg_path := str(ml.UI_CONFIG_PATH)
	for p in [cfg_path, cfg_path + ".bak"]:
		if FileAccess.file_exists(p):
			DirAccess.remove_absolute(ProjectSettings.globalize_path(p))
	var seed := ConfigFile.new()
	seed.set_value("settings", "active_profile", "Default")
	seed.set_value("profile.Default.enabled", "zip:CoolMod_v1.0.zip", false)
	seed.set_value("profile.Default.priority", "zip:CoolMod_v1.0.zip", 12)
	seed.set_value("profile.Default.enabled", "zip:Gone.zip", true)
	_assert(seed.save(cfg_path) == OK, "T9: seeded mod_config.cfg in the throwaway user://")
	var live := _entry("CoolMod_v1.1.zip", "")
	var entries: Array[Dictionary] = [live]
	ml.set("_ui_mod_entries", entries)
	ml.set("_active_profile", "Default")
	ml._apply_profile_to_entries(seed, "Default")
	_assert(not bool(live["enabled"]) and int(live["priority"]) == 12,
			"T9: the re-packaged mod picks up the state stored under its old filename")
	var missing: Array = ml._missing_mods_in_active_profile()
	_assert(not missing.has("zip:CoolMod_v1.0.zip"),
			"T9: the old filename's key is not reported as a missing mod (got %s)" % str(missing))
	_assert(missing.has("zip:Gone.zip"), "T9: a mod that really is gone is still reported")
	ml._save_ui_config()
	var saved := ConfigFile.new()
	_assert(saved.load(cfg_path) == OK, "T9: the saved config loads")
	_assert(saved.has_section_key("profile.Default.enabled", "zip:CoolMod_v1.1.zip")
			and not saved.has_section_key("profile.Default.enabled", "zip:CoolMod_v1.0.zip")
			and not saved.has_section_key("profile.Default.priority", "zip:CoolMod_v1.0.zip"),
			"T9: the save writes the live key and drops the stale one")
	_assert(saved.has_section_key("profile.Default.enabled", "zip:Gone.zip"),
			"T9: a stored key with no live counterpart is kept")
	var empty: Array[Dictionary] = []
	ml.set("_ui_mod_entries", empty)
	for p in [cfg_path, cfg_path + ".bak"]:
		if FileAccess.file_exists(p):
			DirAccess.remove_absolute(ProjectSettings.globalize_path(p))

# The stored active profile can be gone (deleted by hand, a restored backup).
# With a pack active the fallback is that pack's slot, which keeps the pack
# and its MCM settings consistent; otherwise it is a profile the player made,
# never a slot a modpack manages.
func _t10_missing_profile_falls_back_to_a_user_profile(ml: Object) -> void:
	var cfg_path := str(ml.UI_CONFIG_PATH)
	for p in [cfg_path, cfg_path + ".bak"]:
		if FileAccess.file_exists(p):
			DirAccess.remove_absolute(ProjectSettings.globalize_path(p))
	var seed := ConfigFile.new()
	seed.set_value("settings", "active_profile", "Gone")
	seed.set_value("settings", "active_modpack", "Pack")
	seed.set_value("profile._before_modpack_Pack.enabled", "a@1.0", true)
	seed.set_value("profile.modpack__Pack.enabled", "a@1.0", true)
	seed.set_value("profile.zed.enabled", "a@1.0", true)
	_assert(seed.save(cfg_path) == OK, "T10: seeded mod_config.cfg")
	var none: Array[Dictionary] = []
	ml.set("_ui_mod_entries", none)
	ml._load_ui_config()
	_assert(str(ml.get("_active_profile")) == "modpack__Pack",
			"T10: with a pack active, a missing stored profile falls back to the pack's slot (got '%s')" % str(ml.get("_active_profile")))
	var after := ConfigFile.new()
	after.load(cfg_path)
	_assert(str(after.get_value("settings", "active_modpack", "")) == "Pack", "T10: and the pack stays active")
	seed.set_value("settings", "active_modpack", "")
	seed.erase_section("profile.modpack__Pack.enabled")
	_assert(seed.save(cfg_path) == OK, "T10: seeded mod_config.cfg with no pack active")
	ml._load_ui_config()
	_assert(str(ml.get("_active_profile")) == "zed",
			"T10: with no pack active it falls back to the player's own profile (got '%s')" % str(ml.get("_active_profile")))
	for p in [cfg_path, cfg_path + ".bak"]:
		if FileAccess.file_exists(p):
			DirAccess.remove_absolute(ProjectSettings.globalize_path(p))

# Renaming or creating a profile changes no mod state, so a launcher opened
# in-game must not restart over it. A new profile starts from the default
# view settings, which is what its stored state says after the next launch.
func _t11_profile_bookkeeping_is_not_a_mod_change(ml: Object) -> void:
	var cfg_path := str(ml.UI_CONFIG_PATH)
	for p in [cfg_path, cfg_path + ".bak"]:
		if FileAccess.file_exists(p):
			DirAccess.remove_absolute(ProjectSettings.globalize_path(p))
	var seed := ConfigFile.new()
	seed.set_value("settings", "active_profile", "Default")
	seed.set_value("profile.Default.enabled", "a@1.0", true)
	_assert(seed.save(cfg_path) == OK, "T11: seeded mod_config.cfg")
	var none: Array[Dictionary] = []
	ml.set("_ui_mod_entries", none)
	ml.set("_active_profile", "Default")
	ml.set("_boot_complete", true)
	ml.set("_dirty_since_boot", false)
	ml._rename_profile("Renamed")
	_assert(not bool(ml.get("_dirty_since_boot")), "T11: a rename does not ask for a restart")
	_assert(str(ml.get("_active_profile")) == "Renamed", "T11: the rename took effect")
	ml.set("_mods_hide_disabled", true)
	ml._create_profile("Fresh")
	_assert(not bool(ml.get("_dirty_since_boot")), "T11: creating a profile does not ask for a restart")
	_assert(not bool(ml.get("_mods_hide_disabled")), "T11: a new profile starts with Hide disabled off, as its stored state says")
	ml.set("_boot_complete", false)
	ml.set("_active_profile", "Default")
	for p in [cfg_path, cfg_path + ".bak"]:
		if FileAccess.file_exists(p):
			DirAccess.remove_absolute(ProjectSettings.globalize_path(p))
	for d in ["user://.profile_snapshots"]:
		if DirAccess.dir_exists_absolute(ProjectSettings.globalize_path(d)):
			ml._remove_tree(d, false)

func _entry(file_name: String, version: String) -> Dictionary:
	return {
		"file_name": file_name,
		"full_path": "/nonexistent/" + file_name,
		"ext": file_name.get_extension().to_lower(),
		"mod_name": file_name.get_basename(),
		"mod_id": file_name,
		"version": version,
		"profile_key": "zip:" + file_name,
		"enabled": true,
		"priority": 0,
	}

func _entries(specs: Array) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for s in specs:
		out.append(_entry(str((s as Dictionary)["file"]), str((s as Dictionary)["ver"])))
	return out

# --- Reporting ---------------------------------------------------------------

func _assert(cond: bool, msg: String) -> void:
	_assertions += 1
	if not cond:
		_failures.append(msg)

func _fail(msg: String) -> void:
	_failures.append(msg)

func _finish() -> void:
	if _failures.is_empty():
		print("[identity] PASS: %d assertion(s) across T1..T11" % _assertions)
		quit(0)
		return
	for m in _failures:
		printerr("[identity] FAIL: " + m)
	printerr("[identity] FAILED: %d of %d assertion(s)" % [_failures.size(), _assertions])
	quit(1)
