## Mod-identity harness, run by check_identity.sh: filename stems, duplicates, profile state.
## Does not prove the scan of a real mods folder (check_mods.sh does).
extends "res://runner_base.gd"

const STEM_CASES := [
	["CoolMod.zip", "coolmod"],
	["CoolMod.vmz", "coolmod"],
	["CoolMod.pck", "coolmod"],
	["CoolMod_v1.0.zip", "coolmod"],
	["100-CoolMod.vmz", "coolmod"],
	["CoolMod_v1.1.zip", "coolmod"],
	["CoolMod-1.2.3.zip", "coolmod"],
	["CoolMod v2.vmz", "coolmod"],
	["CoolModv2.zip", "coolmod"],
	["CoolMod.1.0.zip", "coolmod"],
	["COOLMOD.ZIP", "coolmod"],
	["CoolMod2.zip", "coolmod2"],
	["Mod4Fun.zip", "mod4fun"],
	# A bare number after "_" is a part number: both archives load.
	["WeaponPack_1.zip", "weaponpack_1"],
	["WeaponPack_2.zip", "weaponpack_2"],
	["WeaponPack_v1.zip", "weaponpack"],
	["1.2.zip", "1.2"],
	["v2.zip", "v2"],
	["A Mod With Spaces.zip", "a mod with spaces"],
	["under_score.zip", "under_score"],
	# A number after a space is part of the name; "v" or a dotted version strips.
	["Ammo Pack 1.zip", "ammo pack 1"],
	["Ammo Pack 2.zip", "ammo pack 2"],
	["Ammo Pack v2.zip", "ammo pack"],
	["Ammo Pack 1.2.zip", "ammo pack"],
	["Ammo Pack 10.zip", "ammo pack 10"],
]

func _init() -> void:
	super("identity", "T1..T14")

func _tests(ml: Object) -> void:
	ml._compile_regex()
	for t in [_t1_stem_table, _t2_extension_change, _t3_version_bump, _t4_distinct_mods, _t5_declared_id_wins,
			_t6_pck_never_collapses, _t7_mod_txt_record, _t8_priority_per_profile, _t9_repackaged_mod_key,
			_t10_missing_profile, _t11_profile_bookkeeping, _t12_active_profile_label, _t13_newer_archive_beats_folder,
			_t14_skip_lines_name_the_fix]:
		begin(str(t.get_method()).get_slice("_", 1).to_upper())
		t.call(ml)

func _t1_stem_table(ml: Object) -> void:
	for c in STEM_CASES:
		check_eq(str(ml._normalized_mod_stem(c[0])), c[1], "stem(%s)" % c[0])

func _t2_extension_change(ml: Object) -> void:
	var out: Array = ml._dedupe_by_mod_id(_entries(["CoolMod.vmz", "CoolMod.zip"]))
	if check_eq(out.size(), 1, ".vmz and .zip of one mod"):
		check_eq((out[0].get("duplicates_hidden", []) as Array).size(), 1, "losing copies hidden")

func _t3_version_bump(ml: Object) -> void:
	var pair: Array[Dictionary] = [_entry("CoolMod_v1.0.zip", "1.0"), _entry("CoolMod_v1.1.zip", "1.1")]
	var out: Array = ml._dedupe_by_mod_id(pair)
	if check_eq(out.size(), 1, "two versions of one mod"):
		check_eq(str(out[0]["file_name"]), "CoolMod_v1.1.zip", "the higher version wins")

func _t4_distinct_mods(ml: Object) -> void:
	for c in [[["CoolMod.zip", "CoolMod2.zip", "OtherMod.zip"], 3], [["Ammo Pack 1.zip", "Ammo Pack 2.zip"], 2],
			[["Ammo Pack v1.zip", "Ammo Pack v2.zip"], 1], [["Ammo Pack 1.2.zip", "Ammo Pack 1.3.zip"], 1]]:
		check_eq((ml._dedupe_by_mod_id(_entries(c[0])) as Array).size(), c[1], "entries left of %s" % str(c[0]))

func _t5_declared_id_wins(ml: Object) -> void:
	var pair: Array[Dictionary] = [
		_entry("Totally.zip", "1.0", {"mod_id": "shared.id", "profile_key": "shared.id@1.0"}),
		_entry("Different.zip", "1.1", {"mod_id": "shared.id", "profile_key": "shared.id@1.1"}),
	]
	check_eq((ml._dedupe_by_mod_id(pair) as Array).size(), 1, "one declared id, two filenames")

func _t6_pck_never_collapses(ml: Object) -> void:
	check_eq((ml._dedupe_by_mod_id(_entries(["Same.pck", "Same.zip"])) as Array).size(), 2, "a .pck beside its .zip")

func _t7_mod_txt_record(ml: Object) -> void:
	var ok_zip := H.write_zip("user://identity_ok.zip",
			{"mod.txt": "[mod]\nname=\"Ok\"\nid=\"ok\"\n", "Ok/Main.gd": "extends Node\n"}, _report)
	var nested_zip := H.write_zip("user://identity_nested.zip", {"Sub/mod.txt": "[mod]\nname=\"Nested\"\n"}, _report)
	var broken_zip := H.write_zip("user://identity_broken.zip", {"mod.txt": "[mod\nname=\n"}, _report)
	var bare_zip := H.write_zip("user://identity_bare.zip", {"Plain/thing.txt": "x"}, _report)

	var r: Variant = ml.read_mod_config(ok_zip)
	if not _assert(r is Dictionary, "a record, not a bare ConfigFile"):
		return
	var keys: Array = r.keys()
	keys.sort()
	check_eq(keys, ["cfg", "error", "files", "status"], "record keys")
	_assert(str(r["status"]) == "ok" and r["cfg"] is ConfigFile and str(r["cfg"].get_value("mod", "id", "")) == "ok",
			"root mod.txt reads as ok (got %s)" % r["status"])
	var files: Dictionary = r["files"]
	_assert(files.has("res://mod.txt") and files.has("res://Ok/Main.gd"), "entries as res:// paths (got %s)" % str(files.keys()))

	# error: "set" must be non-empty, "empty" must be empty, "any" is not checked.
	var missing := ProjectSettings.globalize_path("user://identity_missing.zip")
	for c in [["nested", nested_zip, "nested:Sub/mod.txt", "any"], ["unparseable", broken_zip, "parse_error", "set"],
			["no mod.txt", bare_zip, "none", "empty"], ["missing archive", missing, "none", "any"]]:
		var rec: Dictionary = ml.read_mod_config(c[1])
		var err := str(rec["error"])
		var err_ok: bool = c[3] == "any" or (err != "") == (c[3] == "set")
		_assert(str(rec["status"]) == c[2] and rec["cfg"] == null and err_ok,
				"%s reads as %s (got %s / '%s')" % [c[0], c[2], rec["status"], err])

	var folder := ProjectSettings.globalize_path("user://identity_folder")
	H.write_text(folder.path_join("mod.txt"), "[mod]\nname=\"Folder\"\nid=\"folder\"\n")
	var fr: Dictionary = ml.read_mod_config_folder(folder)
	_assert(str(fr["status"]) == "ok" and fr["cfg"] is ConfigFile and (fr["files"] as Dictionary).is_empty(),
			"folder mod is ok, no file list (got %s)" % fr["status"])

	for p in [ok_zip, nested_zip, broken_zip, bare_zip, folder.path_join("mod.txt"), folder]:
		DirAccess.remove_absolute(p)

# A profile with no stored priority applies the mod's own default, never
# the previous profile's value, which the next save would write into it.
func _t8_priority_per_profile(ml: Object) -> void:
	var mod_txt := ConfigFile.new()
	_assert(mod_txt.parse("[mod]\nname=\"Leaky\"\nid=\"leaky\"\nversion=\"1.0\"\npriority=7\n") == OK,
			"fixture mod.txt parses")
	var read := {"cfg": mod_txt, "status": "ok", "error": "", "files": {}}
	var entry: Dictionary = ml._entry_from_config(read, "Leaky.zip", "/nonexistent/Leaky.zip", "zip")
	check_eq(int(entry["priority_default"]), 7, "priority_default from mod.txt")
	var entries: Array[Dictionary] = [entry]
	ml.set("_ui_mod_entries", entries)
	var cfg := ConfigFile.new()
	cfg.set_value("profile.A.enabled", "leaky@1.0", true)
	cfg.set_value("profile.A.priority", "leaky@1.0", 50)
	cfg.set_value("profile.B.enabled", "other@1.0", true)
	ml._apply_profile_to_entries(cfg, "A")
	check_eq(int(entry["priority"]), 50, "profile A's stored priority")
	ml._apply_profile_to_entries(cfg, "B")
	check_eq(int(entry["priority"]), 7, "profile B falls back to the default")
	_assert(not bool(entry["enabled"]), "a mod B never listed is off")
	var empty: Array[Dictionary] = []
	ml.set("_ui_mod_entries", empty)

# A re-packaged mod with no id= carries its state over by stem; the old
# "zip:" key is then stale, neither saved nor reported missing.
func _t9_repackaged_mod_key(ml: Object) -> void:
	var cfg_path := _drop_config(ml)
	var seed := ConfigFile.new()
	seed.set_value("settings", "active_profile", "Default")
	seed.set_value("profile.Default.enabled", "zip:CoolMod_v1.0.zip", false)
	seed.set_value("profile.Default.priority", "zip:CoolMod_v1.0.zip", 12)
	seed.set_value("profile.Default.enabled", "zip:Gone.zip", true)
	_assert(seed.save(cfg_path) == OK, "seeded mod_config.cfg")
	var live := _entry("CoolMod_v1.1.zip")
	var entries: Array[Dictionary] = [live]
	ml.set("_ui_mod_entries", entries)
	ml.set("_active_profile", "Default")
	ml._apply_profile_to_entries(seed, "Default")
	_assert(not bool(live["enabled"]) and int(live["priority"]) == 12, "state carries over from the old filename")
	var missing: Array = ml._missing_mods_in_active_profile()
	_assert(not missing.has("zip:CoolMod_v1.0.zip"), "old key not reported missing (got %s)" % str(missing))
	_assert(missing.has("zip:Gone.zip"), "a really gone mod is reported")
	ml._save_ui_config()
	var saved := ConfigFile.new()
	_assert(saved.load(cfg_path) == OK, "the saved config loads")
	_assert(saved.has_section_key("profile.Default.enabled", "zip:CoolMod_v1.1.zip")
			and not saved.has_section_key("profile.Default.enabled", "zip:CoolMod_v1.0.zip")
			and not saved.has_section_key("profile.Default.priority", "zip:CoolMod_v1.0.zip"),
			"save writes the live key, drops the stale")
	_assert(saved.has_section_key("profile.Default.enabled", "zip:Gone.zip"), "a key with no live entry is kept")
	var empty: Array[Dictionary] = []
	ml.set("_ui_mod_entries", empty)
	_drop_config(ml)

# With a pack active, a missing stored profile falls back to the pack's slot;
# otherwise to a profile the player made, never a pack slot.
func _t10_missing_profile(ml: Object) -> void:
	var cfg_path := _drop_config(ml)
	var seed := ConfigFile.new()
	seed.set_value("settings", "active_profile", "Gone")
	seed.set_value("settings", "active_modpack", "Pack")
	seed.set_value("profile._before_modpack_Pack.enabled", "a@1.0", true)
	seed.set_value("profile.modpack__Pack.enabled", "a@1.0", true)
	seed.set_value("profile.zed.enabled", "a@1.0", true)
	_assert(seed.save(cfg_path) == OK, "seeded mod_config.cfg")
	var none: Array[Dictionary] = []
	ml.set("_ui_mod_entries", none)
	ml._load_ui_config()
	check_eq(str(ml.get("_active_profile")), "modpack__Pack", "fallback with a pack active")
	var after := ConfigFile.new()
	after.load(cfg_path)
	check_eq(str(after.get_value("settings", "active_modpack", "")), "Pack", "the pack stays active")
	seed.set_value("settings", "active_modpack", "")
	seed.erase_section("profile.modpack__Pack.enabled")
	_assert(seed.save(cfg_path) == OK, "seeded mod_config.cfg without a pack")
	ml._load_ui_config()
	check_eq(str(ml.get("_active_profile")), "zed", "fallback with no pack active")
	_drop_config(ml)

# A rename or a copy of the current selection changes nothing that loads; a
# new profile with another selection does, and starts from default view settings.
func _t11_profile_bookkeeping(ml: Object) -> void:
	var cfg_path := _drop_config(ml)
	var seed := ConfigFile.new()
	seed.set_value("settings", "active_profile", "Default")
	seed.set_value("profile.Default.enabled", "a@1.0", true)
	_assert(seed.save(cfg_path) == OK, "seeded mod_config.cfg")
	var installed: Array[Dictionary] = [_entry("a.zip", "1.0")]
	ml.set("_ui_mod_entries", installed)
	ml.set("_active_profile", "Default")
	ml.set("_boot_complete", true)
	var booted := str(ml._loaded_set_signature())
	ml.set("_booted_set_signature", booted)
	ml._rename_profile("Renamed")
	_assert(not bool(ml._post_boot_restart_needed()), "a rename asks for no restart")
	check_eq(str(ml.get("_active_profile")), "Renamed", "the rename took effect")
	ml.set("_mods_hide_disabled", true)
	ml._create_profile("Fresh")
	check_eq(str(ml._loaded_set_signature()), booted, "a copy leaves what loads")
	_assert(bool(ml._mcm_switch_pending()), "a post-boot create records the MCM swap")
	_assert(not bool(ml.get("_mods_hide_disabled")), "a new profile starts with Hide off")
	# The New dialog's Empty state, as _show_new_profile_dialog applies it.
	for entry in ml.get("_ui_mod_entries"):
		entry["enabled"] = false
	ml._create_profile("Blank")
	_assert(str(ml._loaded_set_signature()) != booted, "another selection changes what loads")
	_assert(bool(ml._post_boot_restart_needed()), "another selection asks for a restart")
	var none: Array[Dictionary] = []
	ml.set("_ui_mod_entries", none)
	ml.set("_booted_set_signature", "")
	ml.set("_boot_complete", false)
	ml.set("_active_profile", "Default")
	_drop_config(ml)
	if DirAccess.dir_exists_absolute(ProjectSettings.globalize_path("user://.profile_snapshots")):
		ml._remove_tree("user://.profile_snapshots", false)

func _t12_active_profile_label(ml: Object) -> void:
	if not _assert(ml.has_method("_active_profile_label"), "the loader has _active_profile_label"):
		return
	ml.set("_active_profile", "Default")
	check_eq(str(ml._active_profile_label()), "Default", "a user profile's label")
	ml.set("_active_profile", str(ml.MODPACK_PROFILE_PREFIX) + "Night Ops")
	check_eq(str(ml._active_profile_label()), "[Modpack: Night Ops]", "a pack slot's label")
	ml.set("_active_profile", "Default")

# Developer Mode: a same-version archive newer than its dev folder wins, as on 3.4.2.
func _t13_newer_archive_beats_folder(ml: Object) -> void:
	var zip_path := ProjectSettings.globalize_path("user://identity_t13/MyMod.zip")
	_assert(H.write_text(zip_path, "x"), "fixture archive written")
	var keys := {"mod_id": "mymod", "profile_key": "mymod@1.0"}
	var folder := _entry("MyMod", "1.0", keys.merged({"ext": "folder"}))
	var archive := _entry("MyMod.zip", "1.0", keys.merged({"full_path": zip_path}))
	var was_dev := bool(ml.get("_developer_mode"))
	ml.set("_developer_mode", true)
	var pair: Array[Dictionary] = [folder, archive]
	var out: Array = ml._dedupe_by_mod_id(pair)
	if check_eq(out.size(), 1, "one copy of mymod"):
		check_eq(str(out[0]["file_name"]), "MyMod.zip", "the newer archive wins")
	ml.set("_developer_mode", was_dev)
	DirAccess.remove_absolute(zip_path)
	DirAccess.remove_absolute(zip_path.get_base_dir())

# A skipped archive's log line names where mod.txt sits, or how to ship it as a mod.
func _t14_skip_lines_name_the_fix(ml: Object) -> void:
	var dir := "user://identity_t14"
	var previous := str(ml.get("_mods_dir"))
	ml.set("_mods_dir", ProjectSettings.globalize_path(dir))
	DirAccess.make_dir_recursive_absolute(dir)
	H.write_zip(dir + "/T14Pack.zip", {"profile.json": "{\"metroprofile\": 1, \"name\": \"T14\"}"}, _report)
	H.write_zip(dir + "/T14Nested.zip", {"T14Sub/mod.txt": "[mod]\nname=\"T14\"\nid=\"t14\"\n"}, _report)
	var report: Array = ml.get("_report_lines")
	report.clear()
	var entries: Array[Dictionary] = ml.collect_mod_metadata()
	var note: Array = report.filter(func(l): return str(l).contains("Treating T14Pack.zip as a modpack"))
	_assert(note.size() == 1 and str(note[0]).contains("remove that file to ship it as a mod"),
			"the modpack note names the fix")
	var nested: Array = entries.filter(func(e): return e["file_name"] == "T14Nested.zip")
	if check_eq(nested.size(), 1, "the nested archive is listed"):
		ml._process_mod_candidate(nested[0], 0)
		_assert(report.any(func(l): return str(l).contains("Invalid mod -- mod.txt is at T14Sub/mod.txt")),
				"the log names the subfolder")
	report.clear()
	ml._remove_tree(dir, false)
	ml.set("_mods_dir", previous)

# Removes mod_config.cfg and its .bak; returns the config path.
func _drop_config(ml: Object) -> String:
	var cfg_path := str(ml.UI_CONFIG_PATH)
	H.remove_user_file(cfg_path)
	H.remove_user_file(cfg_path + ".bak")
	return cfg_path

func _entry(file: String, version := "", overrides := {}) -> Dictionary:
	var o := {"file_name": file, "full_path": "/nonexistent/" + file, "ext": file.get_extension().to_lower(),
			"mod_name": file.get_basename()}
	o.merge(overrides, true)
	return H.mod_entry("zip:" + file, file, version, o)

func _entries(files: Array) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for f in files:
		out.append(_entry(f))
	return out
