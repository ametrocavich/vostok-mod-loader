## Mod discovery, identity, load order, dependencies and updates on a user:// mods folder (check_mods.sh).
## Not proven here: the network (T78 stubs the transfer), mounting across a restart, hook dispatch.
extends "res://runner_base.gd"

const MODS_DIR := "user://t78_mods"
const FIXTURE_DIR := "user://t78_fix"

## The loader with its manifest transport served from `served` by URL; every URL and detail TTL asked is kept.
class ManifestStub extends "res://stub_loader.gd":
	var served := {}
	var asked: Array = []
	var ttls: Array = []

	func _hnet_get_json(provider: String, url: String, ttl_ms: int = 0,
			allow_rate_wait: bool = true, allow_transport_retry: bool = true) -> Dictionary:
		asked.append(url)
		if not served.has(url):
			return host_err(HOST_ERR_NOT_FOUND, 404, "no fixture for " + url)
		return host_ok(served[url])

	func _vmp_detail(id: String, ttl_ms: int = _VM_TTL_DETAIL_MS) -> Dictionary:
		ttls.append(ttl_ms)
		return super(id, ttl_ms)

func _init() -> void:
	super("mods", "T13..T101")
	# T101 waits on a loopback HTTP transfer.
	max_frames = 600

func _tests(ml: Object) -> void:
	# Mod scans and id matching read the regexes _ready compiles.
	ml._compile_regex()
	for name in ["_updates_check_message", "_download_failure_text", "_same_file_name"]:
		_assert(ml.has_method(name), "the loader has " + name)
	for t in [
		["T13", _t13_update_check_rules], ["T15", _t15_warnings_and_author_notes],
		["T22", _t22_update_check_message], ["T23", _t23_download_failure_text],
		["T26", _t26_same_file_name], ["T27", _t27_download_file_names],
		["T28", _t28_dependency_lists_and_load_order], ["T37", _t37_update_guards],
		["T42", _t42_update_finds_its_version_already_installed],
		["T43", _t43_install_checks_the_page_against_installed_mods],
		["T44", _t44_delete_drops_every_version_of_the_mod], ["T45", _t45_scan_and_load_pipeline],
		["T47", _t47_delete_spares_a_hidden_older_copy], ["T48", _t48_profile_keys_match_ids_without_case],
		["T49", _t49_update_check_trusts_the_served_version], ["T52", _t52_update_rename_moves_a_filename_key],
		["T57", _t57_hook_scan_reads_single_quotes], ["T58", _t58_hidden_duplicate_keys_survive_a_save],
		["T63", _t63_windows_invalid_file_names_are_refused], ["T64", _t64_live_entry_falls_back_to_the_same_id],
		["T67", _t67_stale_cache_sweep], ["T68", _t68_browse_collision_with_the_same_mod_counts_as_installed],
		["T75", _t75_optional_dependency_cycles_are_not_cycles], ["T76", _t76_idless_mods_are_named_by_their_stem],
		["T77", _t77_required_dependency_status], ["T78", _t78_downloads_land_end_to_end],
		["T79", _t79_update_check_probes_site_packs], ["T80", _t80_prefixed_idless_copy_collapses],
		["T81", _t81_dev_folders_stay_hidden_keys], ["T82", _t82_nameless_mods_sort_by_file_name],
		["T83", _t83_percent_in_a_server_file_name], ["T84", _t84_update_check_asks_fresh],
		["T93", _t93_an_id_with_an_at_keeps_its_state], ["T94", _t94_a_required_cycle_releases_no_optional_edge],
		["T95", _t95_a_changed_dev_folder_is_rezipped], ["T96", _t96_priority_is_clamped_for_every_kind],
		["T97", _t97_tied_overrides_apply_in_load_order], ["T98", _t98_claims_are_kept_per_archive],
		["T99", _t99_a_pck_sharing_a_loaded_id_mounts], ["T100", _t100_a_hashless_pack_counts_as_changed],
		["T101", _t101_download_checks_the_listed_checksum],
	]:
		begin(t[0])
		await t[1].call(ml)
	begin("")

## A mod.txt; an empty name or id leaves its line out.
func _mod_txt(id: String, version: String, name := "") -> String:
	var text := "[mod]\n"
	if name != "":
		text += "name=\"%s\"\n" % name
	if id != "":
		text += "id=\"%s\"\n" % id
	return text + "version=\"%s\"\n" % version

## A zip at user_path holding only mod_txt; returns its absolute path.
func _zip(user_path: String, mod_txt: String) -> String:
	return H.write_zip(user_path, {"mod.txt": mod_txt}, _report)

## A ConfigFile of [section, key, value] rows saved as mod_config.cfg.
func _seed(ml: Object, rows: Array) -> ConfigFile:
	var cfg := ConfigFile.new()
	for r in rows:
		cfg.set_value(r[0], r[1], r[2])
	_save(ml, cfg, "seeded mod_config.cfg")
	return cfg

func _save(ml: Object, cfg: ConfigFile, what: String) -> void:
	_assert(cfg.save(str(ml.UI_CONFIG_PATH)) == OK, what)

func _read(ml: Object) -> ConfigFile:
	var cfg := ConfigFile.new()
	cfg.load(str(ml.UI_CONFIG_PATH))
	return cfg

func _install(ml: Object, entries: Array) -> Array[Dictionary]:
	var typed: Array[Dictionary] = []
	typed.assign(entries)
	ml.set("_ui_mod_entries", typed)
	return typed

func _source_cfg(source: String) -> ConfigFile:
	var cfg := ConfigFile.new()
	cfg.set_value("updates", "source", source)
	return cfg

## Points the loader at dir and returns the mods dir it had.
func _use_mods_dir(ml: Object, dir: String, absolute := false) -> String:
	var previous := str(ml.get("_mods_dir"))
	DirAccess.make_dir_recursive_absolute(dir)
	ml.set("_mods_dir", ProjectSettings.globalize_path(dir) if absolute else dir)
	return previous

func _drop_mods_dir(ml: Object, dir: String, previous: String) -> void:
	ml._remove_tree(dir, false)
	ml.set("_mods_dir", previous)

func _has_line(lines: Variant, needle: String) -> bool:
	for l in lines:
		if str(l).contains(needle):
			return true
	return false

func _disposition(file_name: String) -> PackedStringArray:
	return PackedStringArray(["Content-Disposition: attachment; filename=\"%s\"" % file_name])

func _update_entry(profile_key: String, ext: String, mod_txt: String) -> Dictionary:
	return H.mod_entry(profile_key, profile_key.get_slice("@", 0), profile_key.get_slice("@", 1), {"ext": ext,
			"cfg": H.cfg_from_text(mod_txt, _report) if mod_txt != "" else null,
			"full_path": "/mods/" + profile_key, "mod_name": profile_key})

func _dep_entry(mod_id: String, enabled: bool, required: Array, provides: Array = []) -> Dictionary:
	return H.mod_entry(mod_id + "@1.0", mod_id, "1.0", {"mod_name": mod_id[0].to_upper() + mod_id.substr(1),
			"enabled": enabled, "required_dependencies": required, "provides": provides})

## The row warnings and author notes the loader builds for one read mod.txt.
func _entry_from(ml: Object, cfg: ConfigFile, status: String, error: String, files: Dictionary, ext := "vmz") -> Dictionary:
	var read := {"cfg": cfg, "status": status, "error": error, "files": files}
	var entry: Dictionary = ml._entry_from_config(read, "Mod." + ext, "/mods/Mod." + ext, ext)
	return {"warnings": ml._build_entry_warnings(entry, files), "notes": ml._build_entry_author_notes(entry, files)}

# The update check asks only about sourced, versioned archives from a host that
# serves files; a missing answer is an error, an older install an update.
func _t13_update_check_rules(ml: Object) -> void:
	var entries: Array[Dictionary] = [
		_update_entry("a@1.0", "vmz", '[mod]\nversion="1.0"\n\n[updates]\nsource="vostokmods:a"\n'),
		_update_entry("b@1.0", "folder", '[mod]\nversion="1.0"\n\n[updates]\nsource="vostokmods:b"\n'),
		_update_entry("c@", "vmz", '[updates]\nsource="vostokmods:c"\n'),
		_update_entry("d@1.0", "vmz", '[mod]\nversion="1.0"\n'),
		_update_entry("e@1.0", "pck", ""),
		_update_entry("f@2.0", "zip", '[mod]\nversion="2.0"\n\n[updates]\nsource="modworkshop:5"\n'),
		_update_entry("g@1.0", "vmz", '[mod]\nversion="1.0"\n\n[updates]\nsource="vostokmods:g"\n'),
	]
	var candidates: Dictionary = ml._updates_check_candidates(entries, {})
	check_eq(int(candidates["no_version"]), 1, "sourced mods with no version")
	var keys: Array = []
	for p: Dictionary in candidates["pending"]:
		keys.append(str(p["profile_key"]))
	check_eq(keys, ["a@1.0", "f@2.0", "g@1.0"], "mods checked")
	ml._mod_updates_state["f@2.0"] = {"latest_version": "9.9", "current_version": "2.0"}
	var summary: Dictionary = ml._updates_check_apply(candidates["pending"], {"vostokmods:a": "1.1", "modworkshop:5": "2.0"})
	check_eq(summary, {"checked": 3, "with_updates": 1, "errors": 1}, "check summary")
	var state: Dictionary = ml._mod_updates_state
	_assert(state.has("a@1.0") and str(state["a@1.0"]["latest_version"]) == "1.1" and str(state["a@1.0"]["current_version"]) == "1.0",
			"an older install records the update: %s" % str(state.get("a@1.0")))
	_assert(not state.has("f@2.0"), "an up-to-date mod clears its stale entry")
	_assert(not state.has("g@1.0"), "a mod the site skipped records nothing")
	state.clear()

# Row warnings say the mod will not work; author notes say its mod.txt could
# be better. Each message lands in its own list only.
func _t15_warnings_and_author_notes(ml: Object) -> void:
	var nested := _entry_from(ml, null, "nested:Sub/mod.txt", "", {})
	_assert(_has_line(nested["warnings"], "subfolder") and nested["notes"].is_empty(), "a nested mod.txt is a warning: %s" % str(nested))
	var broken := _entry_from(ml, null, "parse_error", "line 3 [mod]: nam", {})
	_assert(_has_line(broken["warnings"], "parse error at line 3") and broken["notes"].is_empty(),
			"a parse error warns with its line: %s" % str(broken))
	var files := {"res://mod.txt": true, "res://X/main.gd": true}
	var no_id := _entry_from(ml, H.cfg_from_text('[mod]\nname="X"\n\n[autoload]\nMain="res://X/Main.gd"\n', _report), "ok", "", files)
	_assert(_has_line(no_id["warnings"], "did you mean res://X/main.gd"), "a wrong autoload path names the near miss: %s" % str(no_id))
	_assert(_has_line(no_id["notes"], "No id= in mod.txt") and not _has_line(no_id["warnings"], "No id="),
			"a missing id= is an author note: %s" % str(no_id))
	var bad_source := _entry_from(ml, H.cfg_from_text('[mod]\nid="bs"\nversion="1.0"\n\n[updates]\nsource="12345"\n', _report),
			"ok", "", {"res://mod.txt": true})
	_assert(_has_line(bad_source["notes"], "unrecognized [updates] source") and bad_source["warnings"].is_empty(),
			"an unrecognized source= is a note only: %s" % str(bad_source))
	var baked := _entry_from(ml, H.cfg_from_text('[mod]\nid="bk"\nversion=1.10\n\n[updates]\nsource="vostokmods:bk"\n', _report),
			"ok", "", {"res://mod.txt": true, "res://BK/A.gd": true, "res://BK/A.gd.remap": true})
	_assert(_has_line(baked["notes"], "unquoted") and _has_line(baked["notes"], "pre-compiled script") and baked["warnings"].is_empty(),
			"unquoted version and stale bake are notes: %s" % str(baked))
	var rescued := _entry_from(ml, H.cfg_from_text('[mod]\nid="rs"\nversion="1.0"\n\n[updates]\nsource="12345"\nmodworkshop=777\n', _report),
			"ok", "", {"res://mod.txt": true})
	_assert(_has_line(rescued["notes"], "unrecognized [updates] source") and _has_line(rescued["notes"], "modworkshop=")
			and not _has_line(rescued["notes"], "will not update"), "a bad source= names the line used: %s" % str(rescued["notes"]))
	var dev_folder := _entry_from(ml, null, "parse_error", "line 3 [mod]: nam", {}, "folder")
	_assert(_has_line(dev_folder["warnings"], "parse error at line 3"), "a broken dev folder warns too: %s" % str(dev_folder))
	_assert(_entry_from(ml, null, "none", "", {}, "folder")["warnings"].is_empty(), "a bare dev folder gets no re-download warning")
	var pck := _entry_from(ml, null, "pck", "", {}, "pck")
	_assert(pck["warnings"].is_empty() and pck["notes"].is_empty(), "a .pck gets neither list")

func _t22_update_check_message(ml: Object) -> void:
	var cooldowns: Dictionary = ml.get("_host_cooldown_until_ms")
	var failing := {"checked": 3, "with_updates": 0, "errors": 3, "no_version": 0, "providers": ["modworkshop"]}
	# [label, summary, cooldown running, phrases it holds, phrases it must not hold]
	for c in [
		["no mod names a site", {"checked": 0, "with_updates": 0, "errors": 0, "no_version": 0}, false,
				["say where they came from"], []],
		["versionless mods are skipped", {"checked": 0, "with_updates": 0, "errors": 0, "no_version": 2}, false,
				["version"], ["say where they came from"]],
		["every check failed", failing, false, ["connection"], []],
		["every check failed in a cooldown", failing, true, ["rate limit"], ["connection"]],
		["up to date", {"checked": 4, "with_updates": 0, "errors": 1, "no_version": 1, "providers": ["modworkshop"]}, false,
				["Checked 3 mod(s)", "1 could not be checked", "1 skipped"], []],
	]:
		cooldowns.clear()
		if c[2]:
			ml.host_arm_cooldown("modworkshop", 30000)
		var text := str(ml._updates_check_message(c[1]))
		var ok := true
		for s in c[3]:
			ok = ok and text.contains(s)
		for s in c[4]:
			ok = ok and not text.contains(s)
		_assert(ok, "%s: '%s'" % [c[0], text])
	cooldowns.clear()
	check_eq(str(ml._updates_check_message({"checked": 4, "with_updates": 2, "errors": 0, "no_version": 0, "providers": ["modworkshop"]})),
			"2 update(s) available.", "message with two updates")
	var entries: Array[Dictionary] = [H.mod_entry("q@", "q", "", {"cfg":
			H.cfg_from_text("[mod]\nname=\"Q\"\nid=\"q\"\n[updates]\nsource=\"vostokmods:q\"\n", _report)})]
	var candidates: Dictionary = ml._updates_check_candidates(entries, {})
	_assert(candidates["pending"].is_empty() and int(candidates["no_version"]) == 1,
			"a sourced mod with no version is skipped: %s" % str(candidates))

func _t23_download_failure_text(ml: Object) -> void:
	(ml.get("_host_cooldown_until_ms") as Dictionary).clear()
	var too_big := str(ml._download_failure_text("modworkshop", HTTPRequest.RESULT_BODY_SIZE_LIMIT_EXCEEDED, 200))
	_assert(too_big.contains("%d MB" % (int(ml.DOWNLOAD_MAX_BYTES) >> 20)) and not too_big.contains("network"),
			"an oversized file is no network problem: '%s'" % too_big)
	for c in [[HTTPRequest.RESULT_CANT_CONNECT, 0, "network"], [HTTPRequest.RESULT_SUCCESS, 404, "HTTP 404"]]:
		var text := str(ml._download_failure_text("modworkshop", c[0], c[1]))
		_assert(text.contains(c[2]), "the failure text says %s: '%s'" % [c[2], text])

# Where the file system ignores case, a name differing only in case is the
# installed file, not a collision.
func _t26_same_file_name(ml: Object) -> void:
	for c in [["CoolMod.zip", "CoolMod.zip", true], ["CoolMod.zip", "OtherMod.zip", false],
			["CoolMod.zip", "coolmod.zip", OS.get_name() in ["Windows", "macOS"]]]:
		check_eq(bool(ml._same_file_name(c[0], c[1])), c[2], "%s is the file %s" % [c[0], c[1]])

# A download's file name comes from the server: only a bare .vmz/.zip/.pck
# name may be joined onto the mods folder.
func _t27_download_file_names(ml: Object) -> void:
	for bad in ["", "../evil.zip", "..\\evil.zip", "sub/evil.zip", "C:evil.zip", ".hidden.zip", "evil.zip:stream", "readme.txt", "mod.exe"]:
		_assert(not ml._is_safe_mod_filename(bad), "'%s' is not a safe mod file name" % bad)
	for good in ["CoolMod.vmz", "Cool Mod v1.2.zip", "pack.PCK"]:
		_assert(ml._is_safe_mod_filename(good), "'%s' is a safe mod file name" % good)
	var cd := func(value: String) -> String:
		return str(ml._filename_from_content_disposition(PackedStringArray(["Content-Type: application/zip", "Content-Disposition: " + value])))
	for c in [['attachment; filename="CoolMod.vmz"', "CoolMod.vmz"], ["attachment; filename=CoolMod.zip; size=3", "CoolMod.zip"],
			['attachment; filename="Cool%20Mod.zip"', "Cool Mod.zip"], ['attachment; filename="../../evil.zip"', ""],
			['attachment; filename="..%2F..%2Fevil.zip"', ""], ['attachment; filename="notes.txt"', ""]]:
		check_eq(cd.call(c[0]), c[1], "file name from " + c[0])
	_assert(cd.call("attachment; filename=\"fallback.zip\"; filename*=UTF-8''Na%C3%AFve.zip") != "fallback.zip", "filename* wins over filename")
	check_eq(str(ml._filename_from_content_disposition(PackedStringArray(["X-Other: 1"]))), "", "file name with no header")
	var none := PackedStringArray()
	for c in [["CoolMod_v1.0.vmz", none, "1.1", "CoolMod_v1.1.vmz"], ["CoolMod.vmz", none, "v2.0", "CoolMod_v2.0.vmz"],
			["CoolMod.vmz", none, "", "CoolMod.vmz"], ["CoolMod.vmz", none, "../../1.0", "CoolMod.vmz"],
			["CoolMod.vmz", _disposition("Renamed.zip"), "9", "Renamed.zip"]]:
		check_eq(str(ml._derive_updated_filename(c[0], c[1], c[2])), c[3], "update name of %s at '%s'" % [c[0], c[2]])

func _t28_dependency_lists_and_load_order(ml: Object) -> void:
	# A non-string item or value is kept as its text.
	for c in [
		['[dependencies]\nrequired=["a", "b"]\n', ["a", "b"]],
		['[dependencies]\nrequired="a, b , c"\n', ["a", "b", "c"]],
		['[dependencies]\nrequired="[a, \'b\']"\n', ["a", "b"]],
		['[dependencies]\nrequired=["A", "a", " ", ""]\n', ["A"]],
		['[mod]\nid="x"\n', []],
		['[dependencies]\nrequired=[1, "a"]\n', ["1", "a"]],
		['[dependencies]\nrequired=5\n', ["5"]],
		['[dependencies]\nrequired=PackedStringArray("p", "q")\n', ["p", "q"]],
	]:
		var cfg := ConfigFile.new()
		_assert(cfg.parse(c[0]) == OK, "fixture parses: %s" % H.oneline(c[0]))
		check_eq(ml._parse_dependency_list(cfg, "required"), Array(c[1]), "required list of " + H.oneline(c[0]))
	_assert(ml._parse_dependency_list(null, "required").is_empty(), "a null ConfigFile has no dependencies")
	# provides= takes the same shapes, drops non-strings and never lists the mod's own id.
	for c in [
		['[mod]\nprovides=["old_a", "Old_B", "OLD_A"]\n', ["old_a", "Old_B"]],
		['[mod]\nprovides=PackedStringArray("x", "y")\n', ["x", "y"]],
		['[mod]\nprovides="a, b"\n', ["a", "b"]],
		['[mod]\nprovides="[a, \'b\']"\n', ["a", "b"]],
		['[mod]\nprovides=[1, "kept"]\n', ["kept"]],
		['[mod]\nprovides=5\n', []],
		['[mod]\nprovides={"a": 1}\n', []],
		['[mod]\nprovides=["New", "old", " new "]\n', ["old"]],
		['[mod]\nid="new"\n', []],
	]:
		check_eq(ml._parse_provides_list(H.cfg_from_text(c[0], _report), "new", "New.zip"), Array(c[1]), "provides of " + H.oneline(c[0]))
	var low := {"priority": 0, "mod_name": "Zeta", "file_name": "a.zip"}
	var alpha := {"priority": 0, "mod_name": "alpha", "file_name": "z.zip"}
	for c in [[low, {"priority": 5, "mod_name": "Alpha", "file_name": "b.zip"}, "a lower priority loads first"],
			[alpha, low, "equal priorities order by caseless name"],
			[{"priority": 0, "mod_name": "Alpha", "file_name": "a.zip"}, alpha, "equal names order by file name"]]:
		_assert(ml._compare_load_order(c[0], c[1]), c[2])

# Update refuses what would go wrong after a full download: a .zip mounted at
# startup is locked until exit, and another mod's file would delete this one.
func _t37_update_guards(ml: Object) -> void:
	var mounted_path := ProjectSettings.globalize_path("user://t37_mounted.zip")
	var mounted: Dictionary = ml.get("_filescope_mounted")
	mounted[mounted_path] = true
	var r: Dictionary = await ml.replace_mod_from_ref(mounted_path, ml.host_ref("vostokmods", "t37"))
	_assert(not r["ok"] and r.get("local", false) and str(r["error"]).contains("relaunch"),
			"a mounted .zip says disable and relaunch: %s" % str(r))
	mounted.erase(mounted_path)
	var old_zip := _zip("user://t37_old.zip", _mod_txt("mod_a", "1.0", "A"))
	for c in [[_mod_txt("mod_b", "2.3", "B"), true, "another id is refused"],
			[_mod_txt("MOD_A", "1.1", "A"), false, "the same id in another case updates"],
			[_mod_txt("", "1.1", "A"), false, "no id to compare updates"]]:
		var err := str(ml._update_names_another_mod(old_zip, H.cfg_from_text(c[0], _report), "modworkshop"))
		_assert(err.contains("different mod") if c[1] else err == "", "%s: '%s'" % [c[2], err])
	H.remove_user_file("user://t37_old.zip")

# With no host file name an update is "<stem>_v<version>"; when an earlier
# update already put that file there, it is the update and the older copy goes.
func _t42_update_finds_its_version_already_installed(ml: Object) -> void:
	H.pack_cleanup(ml)
	var dir := "user://t42_mods"
	var previous := _use_mods_dir(ml, dir)
	var ref: Dictionary = ml.host_ref("vostokmods", "coolmod")
	var v10 := _mod_txt("coolmod", "1.0", "Cool")
	var v11 := _mod_txt("coolmod", "1.1", "Cool")
	var updated := _zip(dir + "/coolmod_v1.1.vmz", v11)
	var older := _zip(dir + "/coolmod.vmz", v10)
	var dl := _zip(dir + "/coolmod.vmz.download", v11)
	var r: Dictionary = ml._adopt_update(older, dl, PackedStringArray(), ref, "1.1")
	_assert(r["ok"] and str(r["new_file_name"]) == "coolmod_v1.1.vmz", "an update already there succeeds: %s" % str(r))
	_assert(not FileAccess.file_exists(older) and not FileAccess.file_exists(dl) and FileAccess.file_exists(updated),
			"the older copy and the download go")
	var kept: Dictionary = ml._get_persisted_mod_sources().get("coolmod@1.1", {})
	_assert(str(kept.get("provider", "")) == "vostokmods" and str(kept.get("id", "")) == "coolmod" and str(kept.get("version", "")) == "1.1",
			"the survivor records the page at its version: %s" % str(kept))

	H.remove_user_file(dir + "/coolmod_v1.1.vmz")
	var other := _zip(dir + "/coolmod_v1.1.vmz", _mod_txt("othermod", "1.1", "Other"))
	older = _zip(dir + "/coolmod.vmz", v10)
	dl = _zip(dir + "/coolmod.vmz.download", v11)
	r = ml._adopt_update(older, dl, PackedStringArray(), ref, "1.1")
	_assert(not r["ok"] and str(r["error"]).contains("different file"), "another mod under the name stops it: %s" % str(r))
	_assert(FileAccess.file_exists(older) and FileAccess.file_exists(other) and not FileAccess.file_exists(dl),
			"both archives stay, the download goes")

	H.remove_user_file(dir + "/coolmod_v1.1.vmz")
	_zip(dir + "/coolmod_v1.1.vmz", v10)
	dl = _zip(dir + "/coolmod.vmz.download", v11)
	r = ml._adopt_update(older, dl, PackedStringArray(), ref, "1.1")
	_assert(not r["ok"] and FileAccess.file_exists(older), "an older copy under the name stops it: %s" % str(r))

	H.remove_user_file(dir + "/coolmod_v1.1.vmz")
	dl = _zip(dir + "/coolmod.vmz.download", v11)
	r = ml._adopt_update(older, dl, PackedStringArray(), ref, "1.1")
	_assert(r["ok"] and FileAccess.file_exists(dir + "/coolmod_v1.1.vmz") and not FileAccess.file_exists(older),
			"with the name free the update swaps: %s" % str(r))

	var no_id := _mod_txt("", "1.1", "Cool")
	_zip(dir + "/noid.vmz", no_id)
	_assert(not ml._update_already_installed_at(ProjectSettings.globalize_path(dir + "/noid.vmz"), H.cfg_from_text(no_id, _report)),
			"an id-less file is not the update")
	for f in ["coolmod_v1.1.vmz", "coolmod.vmz", "noid.vmz"]:
		H.remove_user_file(dir + "/" + f)
	ml.set("_mods_dir", previous)
	H.pack_cleanup(ml)

# A page the player installed a mod from may not deliver another installed
# mod; an id nothing installed carries is a rename and installs.
func _t43_install_checks_the_page_against_installed_mods(ml: Object) -> void:
	H.pack_cleanup(ml)
	var tacmed_uuid := "01a0f8b5-8059-726a-a1ad-ac10591a7794"
	var installed := _install(ml, [
		H.mod_entry("Likhos-TacMed@1.4.155", "Likhos-TacMed", "1.4.155", {"cfg": _source_cfg("vostokmods:" + tacmed_uuid)}),
		H.mod_entry("likhos-eventuality@1.3.64", "likhos-eventuality", "1.3.64",
				{"cfg": _source_cfg("vostokmods:01a0f8d6-b246-7b70-a494-ad7eed7102c8")}),
	])
	var aliases: Dictionary = ml.get("_host_ref_aliases")
	aliases.clear()
	(ml.get("_mods_meta_by_key") as Dictionary).clear()
	var by_slug: Dictionary = ml.host_ref("vostokmods", "likhos-tacmed")
	_assert(ml._mod_ids_installed_from(by_slug).is_empty(), "unpaired, the slug finds nothing installed")
	ml._vmp_note_ids({"id": tacmed_uuid, "slug": "likhos-tacmed"})
	var ids: PackedStringArray = ml._mod_ids_installed_from(by_slug)
	check_eq(ids, PackedStringArray(["likhos-tacmed"]), "paired, ids installed from the slug")
	check_eq(ml._mod_ids_installed_from(ml.host_ref("vostokmods", tacmed_uuid)), ids, "ids installed from the UUID")
	var refusal := func(path: String, from_ids: PackedStringArray) -> String:
		return str(ml._install_names_another_mod(path, from_ids, "vostokmods"))
	var wrong := _zip("user://t43_wrong.vmz", _mod_txt("likhos-eventuality", "1.3.64", "Eventuality"))
	var err: String = refusal.call(wrong, ids)
	_assert(err.contains("different mod") and err.contains("likhos-eventuality") and not err.begins_with("Already have"),
			"another mod's file is refused, not as installed: %s" % err)
	check_eq(refusal.call(_zip("user://t43_right.vmz", _mod_txt("likhos-tacmed", "1.4.156", "TacMed")), ids), "",
			"refusal of the page's own mod")
	check_eq(refusal.call(_zip("user://t43_renamed.vmz", _mod_txt("Likhos-TacMed-2", "2.0.0", "TacMed")), ids), "",
			"refusal of a renamed id")
	var hidden_copy := H.mod_entry("likhos-other@1.0", "Likhos-Other", "1.0")
	installed.append(hidden_copy)
	_assert(refusal.call(_zip("user://t43_other.vmz", _mod_txt("likhos-other", "1.1", "Other")), ids).contains("different mod"),
			"another installed mod's id is refused, caseless")
	installed.erase(hidden_copy)
	check_eq(refusal.call(_zip("user://t43_noid.vmz", _mod_txt("", "1.4.156", "TacMed")), ids), "", "refusal of a file with no id")
	check_eq(refusal.call(wrong, PackedStringArray()), "", "refusal from a page nothing came from")
	aliases.clear()
	for f in ["wrong", "right", "noid", "renamed", "other"]:
		H.remove_user_file("user://t43_%s.vmz" % f)
	H.pack_cleanup(ml)

# A profile not active since the version changed still keys the mod by the old
# version; a delete drops those keys too, but not a lookalike id or a live one.
func _t44_delete_drops_every_version_of_the_mod(ml: Object) -> void:
	H.pack_cleanup(ml)
	DirAccess.make_dir_recursive_absolute("user://t44_mods")
	var gone_path := _zip("user://t44_mods/foo_v2.0.zip", _mod_txt("foo", "2.0"))
	var foo := H.mod_entry("foo@2.0", "foo", "2.0", {"full_path": gone_path, "file_name": "foo_v2.0.zip"})
	var rows := [["settings", "active_profile", "Default"]]
	for prof: String in ["Default", "Other"]:
		var en := "profile." + prof + ".enabled"
		rows += [[en, "foo@2.0", true], [en, "foo@1.0", true], [en, "foobar@1.0", true], [en, "bar@1.0", true],
				["profile." + prof + ".priority", "foo@1.0", 5], ["profile." + prof + ".dep_ignore", "foo@1.0", true]]
	var seed := _seed(ml, rows)
	_install(ml, [foo, H.mod_entry("bar@1.0", "bar", "1.0")])
	_assert(ml._delete_mod_file_and_cleanup(foo), "the delete succeeds")
	_assert(not FileAccess.file_exists(gone_path), "the archive is gone")
	var cfg := _read(ml)
	for prof: String in ["Default", "Other"]:
		var en := "profile." + prof + ".enabled"
		_assert(not cfg.has_section_key(en, "foo@2.0") and not cfg.has_section_key(en, "foo@1.0")
				and not cfg.has_section_key("profile." + prof + ".priority", "foo@1.0")
				and not cfg.has_section_key("profile." + prof + ".dep_ignore", "foo@1.0"), "%s forgets foo under both versions" % prof)
		_assert(cfg.has_section_key(en, "foobar@1.0") and cfg.has_section_key(en, "bar@1.0"), "%s keeps the other mods" % prof)
	# foo 1.0 is also installed as its own archive, so its key stays.
	_zip("user://t44_mods/foo_v2.0.zip", _mod_txt("foo", "2.0"))
	seed.set_value("profile.Default.enabled", "foo@2.0", true)
	seed.set_value("profile.Default.enabled", "foo@1.0", false)
	_save(ml, seed, "reseeded mod_config.cfg")
	_install(ml, [foo, H.mod_entry("foo@1.0", "foo", "1.0")])
	_assert(ml._delete_mod_file_and_cleanup(foo), "the second delete succeeds")
	cfg = _read(ml)
	_assert(not cfg.has_section_key("profile.Default.enabled", "foo@2.0") and cfg.has_section_key("profile.Default.enabled", "foo@1.0"),
			"the version still installed keeps its key")
	H.pack_cleanup(ml)

# The scan-to-load pipeline on real archives: a mod.txt that does not parse is
# listed and mounted but loads nothing; an autoload nothing provides is dropped.
func _t45_scan_and_load_pipeline(ml: Object) -> void:
	H.pack_cleanup(ml)
	var dir := "user://t45_mods"
	var previous := _use_mods_dir(ml, dir, true)
	H.write_zip(dir + "/t45_auto.zip", {
		"mod.txt": "[mod]\nname=\"T45 Auto\"\nid=\"t45auto\"\nversion=\"1.0\"\n\n[autoload]\nT45Auto=\"res://T45Auto/auto.gd\"\nT45Nowhere=\"res://T45Auto/missing.gd\"\n",
		"T45Auto/auto.gd": "extends Node\nvar ready_ran := false\nfunc _ready() -> void:\n\tready_ran = true\n",
	}, _report)
	H.write_zip(dir + "/t45_broken.zip", {"mod.txt": "[mod\nid=\"t45broken\"\n", "T45Broken/x.gd": "extends Node\n"}, _report)
	H.write_zip(dir + "/t45_over.zip", {
		"mod.txt": "[mod]\nname=\"T45 Over\"\nid=\"t45over\"\nversion=\"1.0\"\n\n[script_overrides]\n\"res://Scripts/T45Vanilla.gd\"=\"res://T45Over/over.gd\"\n",
		"T45Over/over.gd": "extends Node\nfunc who() -> String:\n\treturn \"override\"\n",
		"Scripts/T45Vanilla.gd": "extends Node\nfunc who() -> String:\n\treturn \"vanilla\"\n",
	}, _report)

	var entries: Array[Dictionary] = ml.collect_mod_metadata()
	check_eq(str(ml.get("_mods_dir")), ProjectSettings.globalize_path(dir), "mods dir after the scan")
	var by_file: Dictionary = {}
	for e in entries:
		by_file[str(e["file_name"])] = e
	_assert(entries.size() == 3 and by_file.has("t45_auto.zip") and by_file.has("t45_broken.zip") and by_file.has("t45_over.zip"),
			"the scan lists the three archives: %s" % str(by_file.keys()))
	var auto_e: Dictionary = by_file["t45_auto.zip"]
	var broken_e: Dictionary = by_file["t45_broken.zip"]
	_assert(str(auto_e["mod_txt_status"]) == "ok" and str(auto_e["profile_key"]) == "t45auto@1.0"
			and str(auto_e["mod_name"]) == "T45 Auto" and auto_e["enabled"], "a good mod.txt names, keys and enables it")
	_assert(str(broken_e["mod_txt_status"]) == "parse_error" and broken_e["cfg"] == null
			and str(broken_e["profile_key"]) == "zip:t45_broken.zip" and not broken_e["warnings"].is_empty(),
			"a bad mod.txt is listed by file name: %s" % str(broken_e.get("warnings")))

	ml.set("_ui_mod_entries", entries)
	ml.load_all_mods("T45")
	var report: Array = ml.get("_report_lines")
	var loaded: Dictionary = ml.get("_loaded_mod_ids")
	_assert(loaded.has("t45auto") and loaded.has("t45over") and not loaded.has("t45broken") and not loaded.has("t45_broken.zip"),
			"the valid mods load, the broken one not: %s" % str(loaded.keys()))
	_assert(_has_line(report, "Invalid mod -- mod.txt parse error at"), "the broken mod.txt is reported with where")
	_assert(FileAccess.file_exists("res://T45Broken/x.gd") and FileAccess.file_exists("res://T45Auto/auto.gd"),
			"every archive is mounted, broken or not")
	var pending: Array = ml.get("_pending_autoloads")
	_assert(pending.size() == 1 and str(pending[0]["name"]) == "T45Auto" and str(pending[0]["path"]) == "res://T45Auto/auto.gd",
			"only the carried autoload is queued: %s" % str(pending))
	_assert(_has_line(report, "Autoload path not found: res://T45Auto/missing.gd"), "the dropped autoload is named")
	var overrides: Array = ml.get("_pending_script_overrides")
	_assert(overrides.size() == 1 and str(overrides[0]["vanilla_path"]) == "res://Scripts/T45Vanilla.gd"
			and str(overrides[0]["mod_script_path"]) == "res://T45Over/over.gd", "the script override is queued: %s" % str(overrides))

	# The boot applies the overrides and instantiates the autoloads after this.
	ml._apply_script_overrides()
	var taken := load("res://Scripts/T45Vanilla.gd") as GDScript
	_assert(taken != null and str(taken.new().call("who")) == "override", "the vanilla path serves the override")
	ml.set("_has_loaded", true)
	root.add_child(ml)
	for p in pending:
		ml._instantiate_autoload(str(p["mod_name"]), str(p["name"]), str(p["path"]))
	_assert(root.has_node("T45Auto") and root.get_node("T45Auto").get("ready_ran"), "the autoload is under root and ran _ready")
	if root.has_node("T45Auto"):
		root.get_node("T45Auto").free()
	for f in ["t45_auto.zip", "t45_broken.zip", "t45_over.zip"]:
		H.remove_user_file(dir + "/" + f)
	ml.set("_mods_dir", previous)
	H.pack_cleanup(ml)

# The scan shows the newer of two archives of one id; deleting it keeps the
# keys the hidden copy answers to, since that copy becomes the live mod.
func _t47_delete_spares_a_hidden_older_copy(ml: Object) -> void:
	H.pack_cleanup(ml)
	var dir := "user://t47_mods"
	_use_mods_dir(ml, dir, true)
	_zip(dir + "/foo_v1.zip", _mod_txt("foo", "1.0"))
	_zip(dir + "/foo_v2.zip", _mod_txt("foo", "2.0"))
	var entries: Array[Dictionary] = ml.collect_mod_metadata()
	_assert(entries.size() == 1 and str(entries[0]["profile_key"]) == "foo@2.0", "the scan shows only the newer copy (%d)" % entries.size())
	check_eq(entries[0].get("duplicates_hidden", []).size(), 1, "hidden older copies")
	# A dev-mode folder of the same mod, hidden while dev mode is off, is installed too.
	_seed(ml, [["settings", "active_profile", "Default"], ["profile.Default.enabled", "foo@2.0", true],
			["profile.B.enabled", "foo@1.0", true], ["profile.B.priority", "foo@1.0", 4], ["profile.B.enabled", "bar@1.0", true],
			["profile.B.enabled", "foo@0.5", true], ["profile.B.priority", "foo@0.5", 2]])
	ml.set("_ui_mod_entries", entries)
	var hidden_keys: Dictionary = ml.get("_hidden_folder_profile_keys")
	hidden_keys["foo@0.5"] = true
	_assert(ml._delete_mod_file_and_cleanup(entries[0]), "the delete succeeds")
	hidden_keys.erase("foo@0.5")
	var cfg := _read(ml)
	_assert(not cfg.has_section_key("profile.Default.enabled", "foo@2.0"), "the deleted version's key is gone")
	_assert(cfg.has_section_key("profile.B.enabled", "foo@1.0") and cfg.has_section_key("profile.B.priority", "foo@1.0"),
			"the hidden older copy keeps its keys")
	_assert(cfg.has_section_key("profile.B.enabled", "foo@0.5") and cfg.has_section_key("profile.B.priority", "foo@0.5"),
			"a hidden dev folder keeps its keys")
	ml.set("_mods_dir", "")
	H.pack_cleanup(ml)

# Ids compare without case everywhere, so a recased id= keeps its stored keys.
func _t48_profile_keys_match_ids_without_case(ml: Object) -> void:
	H.pack_cleanup(ml)
	var cfg := ConfigFile.new()
	cfg.set_value("profile.B.enabled", "CoolMod@1.0", false)
	cfg.set_value("profile.B.priority", "CoolMod@1.0", 9)
	var entry := H.mod_entry("coolmod@2.0", "coolmod", "2.0")
	check_eq(str(ml._resolve_stored_key(cfg, "B", entry)), "CoolMod@1.0", "stored key of a recased id")
	_assert(ml._stored_key_migrated("CoolMod@1.0", {"coolmod": true}, {}), "the old key migrates to the recased id")
	_assert(not ml._stored_key_migrated("CoolMod@1.0", {"coolmodx": true}, {}), "a longer id does not claim the key")
	DirAccess.make_dir_recursive_absolute("user://t48_mods")
	entry["full_path"] = _zip("user://t48_mods/coolmod.zip", _mod_txt("coolmod", "2.0"))
	cfg.set_value("settings", "active_profile", "Default")
	cfg.set_value("profile.Default.enabled", "coolmod@2.0", true)
	_save(ml, cfg, "seeded mod_config.cfg")
	_install(ml, [entry])
	_assert(ml._delete_mod_file_and_cleanup(entry), "the delete succeeds")
	cfg = _read(ml)
	_assert(not cfg.has_section_key("profile.B.enabled", "CoolMod@1.0") and not cfg.has_section_key("profile.B.priority", "CoolMod@1.0"),
			"the delete drops the other casing's key")
	H.pack_cleanup(ml)

# A file the site labels above its mod.txt version is installed at the served
# version the download recorded, and the scan keeps that record.
func _t49_update_check_trusts_the_served_version(ml: Object) -> void:
	H.pack_cleanup(ml)
	var entries: Array[Dictionary] = [_update_entry("vd@0.9.0", "vmz", "[mod]\nid=\"vd\"\nversion=\"0.9.0\"\n[updates]\nsource=\"vostokmods:vd\"\n")]
	var served := {"provider": "vostokmods", "id": "vd", "version": "1.0.0"}
	var pending: Array = ml._updates_check_candidates(entries, {"vd@0.9.0": served})["pending"]
	_assert(pending.size() == 1 and str(pending[0]["version"]) == "1.0.0", "the candidate carries the served version: %s" % str(pending))
	check_eq(ml._updates_check_apply(pending, {"vostokmods:vd": "1.0.0"})["with_updates"], 0, "updates at the recorded version")
	check_eq(ml._updates_check_apply(pending, {"vostokmods:vd": "1.1.0"})["with_updates"], 1, "updates at a newer site version")
	ml._mod_updates_state.erase("vd@0.9.0")
	# Another host's record, or one behind mod.txt, leaves mod.txt in charge.
	var other_host := {"provider": "modworkshop", "id": "123", "version": "1.0.0"}
	var stale := {"provider": "vostokmods", "id": "vd", "version": "0.8.0"}
	for rec in [other_host, stale]:
		pending = ml._updates_check_candidates(entries, {"vd@0.9.0": rec})["pending"]
		_assert(pending.size() == 1 and str(pending[0]["version"]) == "0.9.0", "mod.txt's version beats %s" % str(rec))
	# The scan keeps a served version, brings a stale one up to mod.txt, and an
	# explicit source= replaces another host's record.
	var seed := ConfigFile.new()
	for c in [[served, "1.0.0"], [stale, "0.9.0"], [other_host, "0.9.0"]]:
		seed.set_value("mod_sources", "vd@0.9.0", ml._serialize_mod_source_rec(c[0]))
		_save(ml, seed, "seeded mod_config.cfg")
		ml._persist_mod_sources_for_entries(entries)
		var rec: Dictionary = ml._get_persisted_mod_sources().get("vd@0.9.0", {})
		_assert(str(rec.get("provider", "")) == "vostokmods" and str(rec.get("version", "")) == c[1],
				"the scan stores vostokmods %s: %s" % [c[1], str(rec)])
	H.pack_cleanup(ml)

# A mod with no id= is keyed by file name, so an update the site renamed
# moves that key itself.
func _t52_update_rename_moves_a_filename_key(ml: Object) -> void:
	H.pack_cleanup(ml)
	var dir := "user://t52_mods"
	var previous := _use_mods_dir(ml, dir, true)
	var old_path := _zip(dir + "/cool_mod.zip", _mod_txt("", "1.0", "Cool"))
	var temp_path := _zip(dir + "/cool_mod.zip.download", _mod_txt("", "1.2", "Cool"))
	_seed(ml, [["settings", "active_profile", "Default"], ["profile.Default.enabled", "zip:cool_mod.zip", false],
			["profile.B.enabled", "zip:cool_mod.zip", true], ["profile.B.priority", "zip:cool_mod.zip", 7],
			["profile.B.dep_ignore", "zip:cool_mod.zip", true],
			["mod_sources", "zip:cool_mod.zip", ml._serialize_mod_source_rec({"provider": "vostokmods", "id": "cool", "version": "1.0"})]])
	var r: Dictionary = ml._adopt_update(old_path, temp_path, _disposition("CoolMod-1.2.zip"), ml.host_ref("vostokmods", "cool"), "1.2")
	_assert(r["ok"] and str(r["new_file_name"]) == "CoolMod-1.2.zip", "the update takes the server's name: %s" % str(r))
	var key := "zip:CoolMod-1.2.zip"
	var cfg := _read(ml)
	_assert(cfg.get_value("profile.B.enabled", key, null) == true and int(cfg.get_value("profile.B.priority", key, 0)) == 7
			and cfg.get_value("profile.B.dep_ignore", key, null) == true, "profile B's state follows the rename")
	_assert(cfg.get_value("profile.Default.enabled", key, null) == false, "the Default profile's state follows too")
	_assert(not cfg.has_section_key("profile.B.enabled", "zip:cool_mod.zip") and not cfg.has_section_key("mod_sources", "zip:cool_mod.zip"),
			"nothing is left under the old name")
	var rec: Dictionary = ml._get_persisted_mod_sources().get(key, {})
	_assert(str(rec.get("id", "")) == "cool" and str(rec.get("version", "")) == "1.2", "the source record moves to the new key: %s" % str(rec))
	# RFC 5987 allows a language tag between the quotes.
	check_eq(str(ml._filename_from_content_disposition(PackedStringArray(["Content-Disposition: attachment; filename*=UTF-8'en'Na%C3%AFve-1.0.zip"]))),
			"Na\u00efve-1.0.zip", "file name from a tagged filename*")
	_drop_mods_dir(ml, dir, previous)
	H.pack_cleanup(ml)

# The source scan enrolls what a mod's literal .hook() calls name, in either quote.
func _t57_hook_scan_reads_single_quotes(ml: Object) -> void:
	var analysis := {"take_over_literal_paths": [], "extends_paths": [], "uses_dynamic_override": false,
			"calls_bloader_api": false, "hook_calls": []}
	ml._compile_regex()
	ml._scan_gd_source("func _ready():\n\t_lib.hook('controller-jump-pre', _cb)\n\t_lib.hook(\"ai-death-post\", _cb2)\n", analysis)
	var seen := PackedStringArray()
	for c: Dictionary in analysis["hook_calls"]:
		seen.append(str(c["prefix"]) + "-" + str(c["method"]))
	for hook in ["controller-jump", "ai-death"]:
		_assert(seen.has(hook), "%s is scanned: %s" % [hook, str(seen)])

# foo.zip (1.0) hides behind foo_v2.zip (2.0); a save keeps 1.0's own keys.
func _t58_hidden_duplicate_keys_survive_a_save(ml: Object) -> void:
	H.pack_cleanup(ml)
	var dir := "user://t58_mods"
	_use_mods_dir(ml, dir, true)
	_zip(dir + "/foo_v1.zip", _mod_txt("foo", "1.0"))
	_zip(dir + "/foo_v2.zip", _mod_txt("foo", "2.0"))
	var installed: Array[Dictionary] = ml.collect_mod_metadata()
	_assert(installed.size() == 1 and installed[0].get("duplicates_hidden", []).size() == 1, "one copy shown, one hidden behind it")
	ml.set("_ui_mod_entries", installed)
	ml.set("_active_profile", "Default")
	_seed(ml, [["settings", "active_profile", "Default"], ["profile.Default.enabled", "foo@2.0", true],
			["profile.Default.enabled", "foo@1.0", false], ["profile.Default.priority", "foo@1.0", 5]])
	ml._save_ui_config()
	var cfg := _read(ml)
	_assert(cfg.has_section_key("profile.Default.enabled", "foo@1.0") and cfg.has_section_key("profile.Default.priority", "foo@1.0"),
			"the hidden copy's keys survive the save")
	_assert(cfg.has_section_key("profile.Default.enabled", "foo@2.0"), "the shown copy's key is written")
	_drop_mods_dir(ml, dir, "")
	H.pack_cleanup(ml)

# Windows cannot create these names, so the rename after a download would fail.
func _t63_windows_invalid_file_names_are_refused(ml: Object) -> void:
	for bad in ["What's New?.zip", "Mod*Pack.vmz", "Cool|Mod.zip", "a<b>.zip", "quote\".zip", "name.zip ", "aux.zip", "CON.vmz", "com1.zip"]:
		_assert(not ml._is_safe_mod_filename(bad), "'%s' is refused" % bad)
	for good in ["What's New.zip", "Cool Mod v1.2.zip", "console.zip", "auxiliary-pack.vmz"]:
		_assert(ml._is_safe_mod_filename(good), "'%s' is accepted" % good)

# A row key captured before a dialog resolves by id once the key changed.
func _t64_live_entry_falls_back_to_the_same_id(ml: Object) -> void:
	H.pack_cleanup(ml)
	var x2 := H.mod_entry("x@2.0", "x", "2.0")
	_install(ml, [x2])
	check_eq(str(ml._live_entry_for_profile_key("x@1.0", H.mod_entry("x@1.0", "x", "1.0")).get("profile_key", "")), "x@2.0",
			"live key for a stale x@1.0")
	check_eq(str(ml._live_full_path("x@1.0", "fallback")), str(x2["full_path"]), "live path for x@1.0")
	var other := H.mod_entry("y@1.0", "y", "1.0")
	_assert(ml._live_entry_for_profile_key("y@1.0", other) == other, "another id keeps the captured entry")
	H.pack_cleanup(ml)

# A download cut off by Launch leaves a .download; a cached zip whose stem ends
# in _dev is not a folder cache.
func _t67_stale_cache_sweep(ml: Object) -> void:
	var dir := "user://t67_mods"
	var previous := _use_mods_dir(ml, dir)
	var cache_dir := ProjectSettings.globalize_path(str(ml.TMP_DIR))
	DirAccess.make_dir_recursive_absolute(cache_dir)
	for p in [dir + "/half.download", dir + "/THING_DEV.VMZ", cache_dir.path_join("Thing_dev.zip"), cache_dir.path_join("Gone.zip")]:
		H.write_text(p, "x")
	ml._clean_stale_cache()
	_assert(not FileAccess.file_exists(dir + "/half.download"), "a leftover .download is swept")
	_assert(FileAccess.file_exists(cache_dir.path_join("Thing_dev.zip")), "a _dev stem's cache is kept, caseless")
	_assert(not FileAccess.file_exists(cache_dir.path_join("Gone.zip")), "a removed archive's cache is swept")
	_drop_mods_dir(ml, dir, previous)

# A hand-dropped copy under the download's name is the install when it is the
# same id at the downloaded version or newer.
func _t68_browse_collision_with_the_same_mod_counts_as_installed(ml: Object) -> void:
	var installed := _zip("user://t68_installed.zip", _mod_txt("foo", "1.2"))
	var temp_same := _zip("user://t68_same.download", _mod_txt("foo", "1.2"))
	var r: Dictionary = ml._install_collision(installed, temp_same, "t68_installed.zip")
	_assert(r["ok"] and str(r["file_name"]) == "t68_installed.zip", "the same mod and version is installed: %s" % str(r))
	_assert(not FileAccess.file_exists(temp_same), "the temp file is removed")
	r = ml._install_collision(installed, _zip("user://t68_other.download", _mod_txt("bar", "1.0")), "t68_installed.zip")
	_assert(not r["ok"] and str(r["error"]).begins_with("Already have a file named")
			and str(r.get("code", "")) == str(ml.DOWNLOAD_ALREADY_INSTALLED), "another mod is refused by code and text")
	for c in [["newer", "1.3", false], ["older", "1.1", true]]:
		r = ml._install_collision(installed, _zip("user://t68_%s.download" % c[0], _mod_txt("foo", c[1])), "t68_installed.zip")
		check_eq(r["ok"], c[2], "an %s download counts as installed" % c[0])
	for f in ["installed.zip", "same.download", "other.download", "newer.download", "older.download"]:
		H.remove_user_file("user://t68_" + f)

func _t75_optional_dependency_cycles_are_not_cycles(ml: Object) -> void:
	var a := H.mod_entry("a@1.0", "a", "1.0")
	var b := H.mod_entry("b@1.0", "b", "1.0")
	var order := func(a_req: Array, a_opt: Array, b_req: Array, b_opt: Array) -> Dictionary:
		a["required_dependencies"] = a_req
		a["optional_dependencies"] = a_opt
		b["required_dependencies"] = b_req
		b["optional_dependencies"] = b_opt
		return ml._apply_dependency_ordering([a, b])
	var soft: Dictionary = order.call([], ["b"], [], ["a"])
	_assert(soft["cycle_keys"].is_empty(), "mutual optional dependencies are no cycle: %s" % str(soft["cycle_keys"]))
	check_eq(soft["ordered"].size(), 2, "mods ordered")
	check_eq(order.call(["b"], [], ["a"], [])["cycle_keys"].size(), 2, "cycle keys of mutual required dependencies")
	# A required edge closed by an optional one: the optional edge gives way.
	var mixed: Dictionary = order.call(["b"], [], [], ["a"])
	_assert(mixed["cycle_keys"].is_empty(), "an optional edge closing a cycle is none")
	var ids := PackedStringArray()
	for e: Dictionary in mixed["ordered"]:
		ids.append(str(e["mod_id"]))
	check_eq(ids, PackedStringArray(["b", "a"]), "load order along the required edge")
	# An id in both lists is a required edge.
	check_eq(order.call(["b"], ["b"], ["a"], [])["cycle_keys"].size(), 2, "cycle keys with an id in both lists")

# A dependency on "CoolMod" must find CoolMod.zip; a folder with no mod.txt
# is still a hidden folder, as on 3.4.2 (T81).
func _t76_idless_mods_are_named_by_their_stem(ml: Object) -> void:
	H.pack_cleanup(ml)
	var dir := "user://t76_mods"
	DirAccess.make_dir_recursive_absolute(dir + "/MCM")
	var previous := _use_mods_dir(ml, dir, true)
	_zip(dir + "/CoolMod.zip", _mod_txt("", "1.0", "Cool"))
	var was_dev := bool(ml.get("_developer_mode"))
	ml.set("_developer_mode", false)
	var cool := {}
	for e: Dictionary in ml.collect_mod_metadata():
		if str(e["file_name"]) == "CoolMod.zip":
			cool = e
	_assert(not cool.is_empty(), "the archive is listed")
	check_eq(str(cool.get("mod_id", "")), "CoolMod", "an id-less mod's id")
	check_eq(str(cool.get("profile_key", "")), "zip:CoolMod.zip", "an id-less mod's profile key")
	_assert(ml.get("_hidden_folder_profile_keys").has("zip:MCM"), "a folder without mod.txt is a hidden key")
	ml.set("_developer_mode", was_dev)
	_drop_mods_dir(ml, dir, previous)
	H.pack_cleanup(ml)

# The load filter and the row status resolve a dependency the same way: the
# loader's own ids count, a real id beats a provides= alias, an alias stands in
# for a disabled mod, a blocked dependency blocks its dependents, and "Load
# anyway" loads the mod while its row keeps the reasons.
func _t77_required_dependency_status(ml: Object) -> void:
	H.pack_cleanup(ml)
	var hidden_ids: Dictionary = ml.get("_hidden_folder_ids")
	hidden_ids.clear()
	hidden_ids["devmod"] = true
	var by_id := {}
	for e: Dictionary in _install(ml, [
		_dep_entry("missing", true, ["zz"]),
		_dep_entry("wants_off", true, ["off"]),
		_dep_entry("off", false, []),
		_dep_entry("chain", true, ["broken"]),
		_dep_entry("broken", true, ["zz"], ["old_broken"]),
		_dep_entry("via_alias", true, ["old_broken"]),
		_dep_entry("wants_alias", true, ["old_name"]),
		_dep_entry("renamed", true, [], ["old_name"]),
		_dep_entry("wants_real", true, ["realx"]),
		_dep_entry("realx", true, ["zz"]),
		_dep_entry("aliasx", true, [], ["realx"]),
		_dep_entry("wants_standin", true, ["offreal"]),
		_dep_entry("offreal", false, []),
		_dep_entry("standin", true, [], ["offreal"]),
		_dep_entry("wants_dev", true, ["devmod"]),
		_dep_entry("selfish", true, ["Selfish", "metro_mod_loader"]),
		_dep_entry("anyway", true, ["zz"]),
		_dep_entry("cyc_a", true, ["cyc_b"]),
		_dep_entry("cyc_b", true, ["cyc_a"]),
	]):
		by_id[str(e["mod_id"])] = e
	by_id["anyway"]["dependency_ignored"] = true

	var loading := PackedStringArray()
	for e: Dictionary in ml._refresh_dependency_status()["loadable"]:
		loading.append(str(e["mod_id"]))
	for id in ["wants_alias", "renamed", "aliasx", "wants_standin", "standin", "selfish", "anyway", "cyc_a", "cyc_b"]:
		_assert(loading.has(id), "%s loads: %s" % [id, str(loading)])
	for id in ["missing", "wants_off", "chain", "broken", "via_alias", "wants_real", "realx", "wants_dev", "off", "offreal"]:
		_assert(not loading.has(id), "%s does not load: %s" % [id, str(loading)])

	# [mod, the fields its one blocker carries, why]
	for c in [
		["missing", {"status": "not_installed", "id": "zz", "fixable": false, "display": "zz"}, "nothing provides it"],
		["wants_off", {"status": "disabled", "fixable": true, "display": "Off (off)"}, "installed but disabled"],
		["chain", {"status": "not_loaded", "fixable": false}, "its dependency is itself blocked"],
		["broken", {"status": "not_installed"}, "the blocked dependency's own cause"],
		["via_alias", {"status": "not_loaded"}, "an alias of a blocked provider"],
		["wants_real", {"status": "not_loaded", "display": "Realx (realx)"}, "a real id beats an alias"],
		["wants_dev", {"status": "hidden_folder"}, "only a hidden dev folder"],
	]:
		var info: Array = by_id[c[0]]["dependency_blockers_info"]
		var got: Dictionary = info[0] if info.size() == 1 else {"count": info.size()}
		var fields := {}
		for k in c[1]:
			fields[k] = got.get(k)
		check_eq(fields, c[1], "%s, %s" % [c[0], c[2]])
	for id in ["wants_alias", "wants_standin", "selfish", "cyc_a"]:
		_assert(by_id[id]["dependency_blockers"].is_empty() and by_id[id]["dependency_blockers_info"].is_empty(),
				"%s has nothing blocking it" % id)
	_assert(_has_line(by_id["selfish"]["dependency_warnings"], "lists itself"), "a self-dependency warns, never blocks")
	_assert(by_id["anyway"]["dependency_blockers"].is_empty() and by_id["anyway"]["dependency_blockers_info"].size() == 1,
			"Load anyway clears blockers, keeps the reason")
	for id in ["cyc_a", "cyc_b"]:
		_assert(_has_line(by_id[id]["dependency_warnings"], "dependency cycle"), "%s is warned about its cycle" % id)
	_assert(by_id["off"]["dependency_warnings"].is_empty() and by_id["off"]["dependency_blockers_info"].is_empty(),
			"a disabled mod gets no dependency status")

	# The load step logs each skip in the row's words.
	var report: Array = ml.get("_report_lines")
	report.clear()
	ml._loadable_enabled_entries(true)
	for line in ["Skipping Wants_off (wants_off) -- required dependency off is installed but disabled",
			"Skipping Chain (chain) -- required dependency broken is blocked by its own missing dependency",
			"Skipping Wants_dev (wants_dev) -- required dependency devmod is a dev folder hidden while Developer Mode is off",
			"Skipping Missing (missing) -- required dependency zz is not installed"]:
		_assert(_has_line(report, line), "skip line: " + line)

	# The row's fix button turns on every installed dependency down the chain.
	var top := _dep_entry("top", true, ["mid", "metro_mod_loader", "absent"])
	var mid := _dep_entry("mid", false, ["leaf"])
	var leaf := _dep_entry("leaf", false, [])
	_install(ml, [top, mid, leaf])
	ml._enable_required_deps(top)
	_assert(mid["enabled"] and leaf["enabled"], "enabling dependencies follows the chain")
	hidden_ids.clear()
	H.pack_cleanup(ml)

func _version_at(dl: Object, path: String) -> String:
	if not FileAccess.file_exists(path):
		return "<missing>"
	return str(dl._cfg_mod_version(dl.read_mod_config(path)["cfg"]))

func _leftovers(mods_abs: String) -> PackedStringArray:
	var out := PackedStringArray()
	for f in DirAccess.get_files_at(mods_abs):
		if f.ends_with(".download") or f.ends_with(".bak"):
			out.append(f)
	return out

## Drops mod_config.cfg and its .bak: with only the .bak left a save records nothing.
func _forget_sources(dl: Object) -> void:
	H.remove_user_file(str(dl.UI_CONFIG_PATH))
	H.remove_user_file(str(dl.UI_CONFIG_PATH) + ".bak")

func _source_of(dl: Object, file_name: String) -> Dictionary:
	var mods_abs := ProjectSettings.globalize_path(MODS_DIR)
	var key := str(dl._archive_profile_key(file_name, mods_abs.path_join(file_name)))
	return dl._get_persisted_mod_sources().get(key, {})

## A Vostok Mods detail serving one downloadable version.
func _one_version(slug: String, id: String, version: String) -> Dictionary:
	return {"slug": slug, "versions": [{"id": id, "version": version, "downloadable": true,
			"downloadUrl": "/api/%s/%s" % [slug, version]}]}

# The two download entry points with only the network leaves stubbed: the
# file on disk, the refusals, the profile keys and the source record are real.
func _t78_downloads_land_end_to_end(_ml: Object) -> void:
	var dl: Object = load("res://stub_loader.gd").new()
	dl._compile_regex()
	H.pack_cleanup(dl)
	for d in [MODS_DIR, FIXTURE_DIR]:
		if DirAccess.dir_exists_absolute(ProjectSettings.globalize_path(d)):
			dl._remove_tree(d, false)
		DirAccess.make_dir_recursive_absolute(d)
	var mods_abs := ProjectSettings.globalize_path(MODS_DIR)
	dl.set("_mods_dir", mods_abs)
	var clean := func() -> bool:
		return _leftovers(mods_abs).is_empty()
	var cool10 := _zip(FIXTURE_DIR + "/cool10.zip", _mod_txt("t78cool", "1.0", "T78"))
	var other10 := _zip(FIXTURE_DIR + "/other10.zip", _mod_txt("t78other", "1.0", "T78"))
	var plain := H.write_zip(FIXTURE_DIR + "/plain.zip", {"data/thing.txt": "x"}, _report)
	var not_zip := ProjectSettings.globalize_path(FIXTURE_DIR + "/not_zip.bin")
	H.write_text(not_zip, "<html>not an archive</html>")
	var details: Dictionary = dl.stub_details
	details["t78-cool"] = {"slug": "t78-cool", "versions": [
		{"id": "v2", "version": "1.1", "downloadable": false},
		{"id": "v1", "version": "1.0", "downloadable": true, "downloadUrl": "/api/t78-cool/1.0", "fileName": "T78Cool.zip"},
	]}
	var requests: Array = dl.stub_requests
	var cool_ref: Dictionary = dl.host_ref("vostokmods", "t78-cool")

	# A fresh install: the host's file name, the source record, our User-Agent.
	dl.stub_archive = cool10
	var r: Dictionary = await dl.download_mod_from_ref(cool_ref, "", false, "abc123")
	_assert(r["ok"] and str(r["file_name"]) == "T78Cool.zip" and str(r["error"]) == "", "a fresh install takes the host's name: %s" % str(r))
	_assert(_version_at(dl, mods_abs.path_join("T78Cool.zip")) == "1.0" and clean.call(),
			"the archive is in mods/, no temp left: %s" % str(_leftovers(mods_abs)))
	var rec := _source_of(dl, "T78Cool.zip")
	_assert(str(rec.get("provider", "")) == "vostokmods" and str(rec.get("id", "")) == "t78-cool" and str(rec.get("version", "")) == "1.0",
			"the install records the page: %s" % str(rec))
	var req: Dictionary = requests.back()
	_assert(str(req["url"]) == str(dl.VM_SITE_BASE) + "/api/t78-cool/1.0" and str(req["sha256"]) == "abc123"
			and str(req["temp_path"]) == mods_abs.path_join("vostokmods_t78-cool.download"),
			"the transfer gets url, checksum and temp name: %s" % str(req))
	var sent: PackedStringArray = req["headers"]
	_assert(sent.size() == 1 and sent[0].begins_with("User-Agent: vostok-mod-loader/"), "a download sends only our User-Agent: %s" % str(sent))

	# Browse refuses another mod under a taken name, with the code modpacks count.
	dl.stub_archive = other10
	r = await dl.download_mod_from_ref(cool_ref)
	_assert(not r["ok"] and str(r["error"]) == "Already have a file named T78Cool.zip" and str(r["file_name"]) == "",
			"Browse refuses another mod under the name: %s" % str(r))
	check_eq(str(r.get("code", "")), str(dl.DOWNLOAD_ALREADY_INSTALLED), "refusal code")
	_assert(_version_at(dl, mods_abs.path_join("T78Cool.zip")) == "1.0" and clean.call(), "the installed archive stays, the temp goes")

	# The same mod already there is the install: nothing replaced, source recorded.
	_forget_sources(dl)
	dl.stub_archive = cool10
	r = await dl.download_mod_from_ref(cool_ref)
	_assert(r["ok"] and str(r["file_name"]) == "T78Cool.zip", "the same mod under the name is installed: %s" % str(r))
	check_eq(str(_source_of(dl, "T78Cool.zip").get("id", "")), "t78-cool", "recorded source id")

	# A modpack apply suffixes the version instead, once.
	dl.stub_archive = other10
	r = await dl.download_mod_from_ref(cool_ref, "", true)
	_assert(r["ok"] and str(r["file_name"]) == "T78Cool-v1.0.zip", "a modpack collision takes a version suffix: %s" % str(r))
	_assert(_version_at(dl, mods_abs.path_join("T78Cool.zip")) == "1.0" and FileAccess.file_exists(mods_abs.path_join("T78Cool-v1.0.zip")),
			"both files are in mods/")
	r = await dl.download_mod_from_ref(cool_ref, "", true)
	_assert(not r["ok"] and str(r["error"]) == "Already have a file named T78Cool-v1.0.zip (and the renamed variant)"
			and str(r.get("code", "")) == str(dl.DOWNLOAD_ALREADY_INSTALLED) and clean.call(), "both names taken is already there: %s" % str(r))

	# A pinned version not yet scanned, or gone, never reaches the transfer.
	var before := requests.size()
	r = await dl.download_mod_from_ref(cool_ref, "1.1")
	_assert(not r["ok"] and str(r["error"]).contains("malware scan") and str(r.get("code", "")) == str(dl.HOST_ERR_NOT_SCANNED),
			"an unscanned pin says so, with its code: %s" % str(r))
	r = await dl.download_mod_from_ref(cool_ref, "9.9")
	_assert(not r["ok"] and str(r.get("code", "")) == str(dl.HOST_ERR_VERSION_NOT_FOUND), "a missing pin carries its code: %s" % str(r))
	check_eq(requests.size(), before, "requests after a failed resolve")
	r = await dl.download_mod_from_ref({})
	_assert(not r["ok"] and str(r["error"]) == "This mod has no download source recorded.", "no source, no download: %s" % str(r))

	dl.stub_archive = ""
	r = await dl.download_mod_from_ref(cool_ref)
	_assert(not r["ok"] and str(r["error"]) == "stub transfer failed" and clean.call(), "a failed transfer is the error: %s" % str(r))

	# A plain resource pack (no mod.txt) installs; a broken container does not.
	dl.stub_archive = plain
	dl.stub_headers = _disposition("T78Plain.zip")
	r = await dl.download_mod_from_ref(cool_ref)
	_assert(r["ok"] and str(r["file_name"]) == "T78Plain.zip" and FileAccess.file_exists(mods_abs.path_join("T78Plain.zip")),
			"an archive with no mod.txt installs: %s" % str(r))
	_assert(str(dl._archive_profile_key("T78Plain.zip", mods_abs.path_join("T78Plain.zip"))).begins_with("zip:")
			and str(_source_of(dl, "T78Plain.zip").get("id", "")) == "t78-cool", "its source is under its file-name key")
	dl.stub_archive = not_zip
	for c in [["T78Bad.zip", "Downloaded file is not a valid archive"], ["T78Bad.pck", "Downloaded file is not a valid .pck"]]:
		dl.stub_headers = _disposition(c[0])
		r = await dl.download_mod_from_ref(cool_ref)
		_assert(not r["ok"] and str(r["error"]) == c[1] and not FileAccess.file_exists(mods_abs.path_join(c[0])) and clean.call(),
				"a broken %s is refused: %s" % [c[0], str(r)])

	# A name the file system will not give up (a folder) fails the final move.
	DirAccess.make_dir_recursive_absolute(mods_abs.path_join("T78Dir.zip"))
	H.write_zip(MODS_DIR + "/T78Dir.zip/inner.zip", {"x.txt": "x"}, _report)
	dl.stub_archive = cool10
	dl.stub_headers = _disposition("T78Dir.zip")
	r = await dl.download_mod_from_ref(cool_ref)
	_assert(not r["ok"] and str(r["error"]).begins_with("Could not move the downloaded file into the mods folder") and clean.call(),
			"a failed final move is reported: %s" % str(r))
	dl.stub_headers = PackedStringArray()

	# The page's own installed mod guards what the page may deliver.
	_forget_sources(dl)
	_install(dl, [H.mod_entry("t78cool@1.0", "t78cool", "1.0", {"cfg": _source_cfg("vostokmods:t78-cool")}),
			H.mod_entry("t78other@1.0", "t78other", "1.0")])
	dl.stub_archive = other10
	r = await dl.download_mod_from_ref(cool_ref)
	_assert(not r["ok"] and str(r["error"]).contains("different mod") and clean.call() and not str(r["error"]).begins_with("Already have"),
			"the page serving another mod is refused: %s" % str(r))
	_assert(str(r.get("code", "")) != str(dl.DOWNLOAD_ALREADY_INSTALLED), "the refusal has no already-installed code")
	_install(dl, [])

	# replace_mod_from_ref
	details["t78-upd"] = _one_version("t78-upd", "u2", "1.1")
	var upd_ref: Dictionary = dl.host_ref("vostokmods", "t78-upd")
	var target := _zip(MODS_DIR + "/t78upd.vmz", _mod_txt("t78upd", "1.0", "T78"))
	H.write_text(target + ".bak", "left by an interrupted update")
	dl.stub_archive = _zip(FIXTURE_DIR + "/upd11.zip", _mod_txt("t78upd", "1.1", "T78"))
	requests.clear()
	r = await dl.replace_mod_from_ref(target, upd_ref)
	_assert(r["ok"] and str(r["new_file_name"]) == "t78upd_v1.1.vmz", "an update takes the version-bumped name: %s" % str(r))
	_assert(not FileAccess.file_exists(target) and _version_at(dl, mods_abs.path_join("t78upd_v1.1.vmz")) == "1.1" and clean.call(),
			"the old archive, stale .bak and temp go: %s" % str(_leftovers(mods_abs)))
	rec = _source_of(dl, "t78upd_v1.1.vmz")
	_assert(str(rec.get("id", "")) == "t78-upd" and str(rec.get("version", "")) == "1.1", "the update records its served source: %s" % str(rec))
	req = requests.back()
	_assert(str(req["temp_path"]) == target + ".download" and (req["headers"] as PackedStringArray).size() == 1,
			"the update downloads beside its target: %s" % str(req))

	# An id-less mod's profile state follows the renamed archive.
	details["t78-plain"] = _one_version("t78-plain", "p2", "2.0")
	var plain_old := _zip(MODS_DIR + "/t78plain.zip", _mod_txt("", "1.0", "T78"))
	dl.stub_archive = _zip(FIXTURE_DIR + "/plain20.zip", _mod_txt("", "2.0", "T78"))
	_seed(dl, [["settings", "active_profile", "Default"], ["profile.Default.enabled", "zip:t78plain.zip", false],
			["profile.B.enabled", "zip:t78plain.zip", true]])
	r = await dl.replace_mod_from_ref(plain_old, dl.host_ref("vostokmods", "t78-plain"))
	var cfg := _read(dl)
	_assert(r["ok"] and str(r["new_file_name"]) == "t78plain_v2.0.zip" and cfg.get_value("profile.B.enabled", "zip:t78plain_v2.0.zip", null) == true
			and cfg.get_value("profile.Default.enabled", "zip:t78plain_v2.0.zip", null) == false
			and not cfg.has_section_key("profile.B.enabled", "zip:t78plain.zip"), "the file-name key moves with the update: %s" % str(r))
	check_eq(str(_source_of(dl, "t78plain_v2.0.zip").get("version", "")), "2.0", "source version under the new key")

	# A failed final move puts the .bak back: the original stays installed.
	details["t78-lock"] = _one_version("t78-lock", "l2", "1.1")
	var lock_target := _zip(MODS_DIR + "/t78lock.vmz", _mod_txt("t78lock", "1.0", "T78"))
	DirAccess.make_dir_recursive_absolute(mods_abs.path_join("t78lock_v1.1.vmz"))
	H.write_zip(MODS_DIR + "/t78lock_v1.1.vmz/inner.zip", {"x.txt": "x"}, _report)
	dl.stub_archive = _zip(FIXTURE_DIR + "/lock11.zip", _mod_txt("t78lock", "1.1", "T78"))
	r = await dl.replace_mod_from_ref(lock_target, dl.host_ref("vostokmods", "t78-lock"))
	_assert(not r["ok"] and r["local"] and str(r["new_file_name"]) == "t78lock.vmz"
			and str(r["error"]) == "Could not finalize the update (file may be locked) -- the old version was kept",
			"a failed final move keeps the old version: %s" % str(r))
	_assert(_version_at(dl, lock_target) == "1.0" and clean.call(), "the .bak is restored and the temp goes: %s" % str(_leftovers(mods_abs)))

	# Only the same mod replaces an installed one.
	var updated := mods_abs.path_join("t78upd_v1.1.vmz")
	dl.stub_archive = other10
	r = await dl.replace_mod_from_ref(updated, upd_ref)
	_assert(not r["ok"] and r["local"] and str(r["error"]).contains("different mod") and _version_at(dl, updated) == "1.1" and clean.call(),
			"an update that is another mod is refused: %s" % str(r))
	dl.stub_archive = plain
	r = await dl.replace_mod_from_ref(updated, upd_ref)
	_assert(not r["ok"] and r["local"] and str(r["error"]) == "Downloaded file is not a valid mod archive (no readable mod.txt)"
			and _version_at(dl, updated) == "1.1" and clean.call(), "an update with no mod.txt is refused: %s" % str(r))
	dl.stub_archive = ""
	r = await dl.replace_mod_from_ref(updated, upd_ref)
	_assert(not r["ok"] and not r["local"] and str(r["error"]) == "stub transfer failed" and str(r["new_file_name"]) == "t78upd_v1.1.vmz",
			"a failed transfer leaves the update undone: %s" % str(r))
	r = await dl.replace_mod_from_ref(updated, {})
	_assert(not r["ok"] and str(r["error"]) == "This mod has no download source recorded.", "an update with no source does nothing: %s" % str(r))

	# The version is already installed under the update's name: the older copy goes.
	var dup_old := _zip(MODS_DIR + "/t78dup.vmz", _mod_txt("t78dup", "1.0", "T78"))
	_zip(MODS_DIR + "/t78dup_v1.1.vmz", _mod_txt("t78dup", "1.1", "T78"))
	details["t78-dup"] = _one_version("t78-dup", "d2", "1.1")
	dl.stub_archive = _zip(FIXTURE_DIR + "/dup11.zip", _mod_txt("t78dup", "1.1", "T78"))
	r = await dl.replace_mod_from_ref(dup_old, dl.host_ref("vostokmods", "t78-dup"))
	_assert(r["ok"] and str(r["new_file_name"]) == "t78dup_v1.1.vmz" and not FileAccess.file_exists(dup_old) and clean.call(),
			"an update already there removes the older copy: %s" % str(r))
	check_eq(str(_source_of(dl, "t78dup_v1.1.vmz").get("id", "")), "t78-dup", "the survivor's recorded source id")

	for d in [MODS_DIR, FIXTURE_DIR]:
		dl._remove_tree(d, false)
	H.pack_cleanup(dl)
	dl.free()

# Check for updates asks the site for each pack's manifest; a moved hash is a
# changed pack, and an active one must be unloaded before its Refresh.
func _t79_update_check_probes_site_packs(_ml: Object) -> void:
	var stub := ManifestStub.new()
	stub._compile_regex()
	H.pack_cleanup(stub)
	stub._remove_tree("user://t79_mods", false)
	stub.set("_mods_dir", "user://t79_mods")
	DirAccess.make_dir_recursive_absolute("user://t79_mods")
	var urls := {}
	for c in [["same", "h1"], ["moved", "h2"], ["gone", ""]]:
		var slug := "t79-" + str(c[0])
		var manifest := {"format": 2, "slug": slug, "name": str(c[0]).capitalize() + " Pack", "hash": "h1", "mods": []}
		_assert(stub._hosted_import_manifest(manifest)["ok"], slug + " imported")
		urls[c[0]] = str(stub._vmp_modpack_manifest_url(slug))
		if c[1] != "":
			var served := manifest.duplicate()
			served["hash"] = c[1]
			stub.served[urls[c[0]]] = served
	H.write_zip("user://t79_mods/local.zip", {"profile.json": JSON.stringify({"metroprofile": 1, "name": "Local", "enabled": {}})}, _report)
	var keys := ["active_pack_changed", "checked", "errors", "no_version", "packs_changed", "packs_checked", "packs_failed",
			"providers", "with_updates"]
	var busy_flag := "_mod_updates_check_in_progress"
	stub.set(busy_flag, true)
	var busy: Dictionary = await stub._run_updates_check_for_mods()
	stub.set(busy_flag, false)
	var got := busy.keys()
	got.sort()
	_assert(got == keys and stub.asked.is_empty(), "a busy check keeps its keys, asks nothing")
	var nothing := "No installed mods say where they came from, so there is nothing to check."
	var changed := " 1 pack(s) changed; Refresh them on the Modpacks tab."
	for c in [["inactive", "", ""], ["active", "Moved Pack", " Unload Moved Pack before you refresh it."]]:
		_seed(stub, [["settings", "active_profile", "Default"], ["settings", "active_modpack", stub._sanitize_profile_name(c[1])]])
		stub.asked.clear()
		var summary: Dictionary = await stub._run_updates_check_for_mods()
		got = summary.keys()
		got.sort()
		check_eq(got, keys, c[0] + " summary keys")
		_assert(int(summary["checked"]) == 0 and int(summary["packs_checked"]) == 2 and int(summary["packs_changed"]) == 1
				and int(summary["packs_failed"]) == 1, "%s: two packs answered, one moved: %s" % [c[0], str(summary)])
		var asked := stub.asked.duplicate()
		asked.sort()
		var want := urls.values()
		want.sort()
		check_eq(asked, want, c[0] + " manifests asked, once each")
		check_eq(str(stub._updates_check_message(summary)), nothing + changed + c[2], c[0] + " message")
	check_eq(str(stub._updates_check_message({"checked": 4, "with_updates": 2, "errors": 0, "no_version": 0,
			"providers": [], "packs_checked": 1, "packs_changed": 0, "active_pack_changed": ""})),
			"2 update(s) available.", "no pack sentence without a change")
	var failed := {"checked": 0, "with_updates": 0, "errors": 0, "no_version": 0, "providers": [],
			"packs_checked": 0, "packs_changed": 0, "packs_failed": 2, "active_pack_changed": ""}
	check_eq(str(stub._updates_check_message(failed)), nothing + " Could not check 2 pack(s) on Vostok Mods.",
			"every pack probe failed")
	failed["packs_checked"] = 1
	check_eq(str(stub._updates_check_message(failed)), nothing, "a partial pack probe stays quiet")
	var blank: Dictionary = (stub.served[urls["same"]] as Dictionary).duplicate()
	blank["hash"] = ""
	stub.served[urls["same"]] = blank
	_seed(stub, [["settings", "active_profile", "Default"], ["settings", "active_modpack", ""]])
	check_eq(int((await stub._run_updates_check_for_mods())["packs_changed"]), 2, "a served pack with no hash changed")
	stub._remove_tree("user://t79_mods", false)
	H.pack_cleanup(stub)
	stub.free()

# Two id-less copies of one mod, one behind a "100-" prefix, are one row.
func _t80_prefixed_idless_copy_collapses(ml: Object) -> void:
	H.pack_cleanup(ml)
	var dir := "user://t80_mods"
	var previous := _use_mods_dir(ml, dir, true)
	_zip(dir + "/FooBar.zip", _mod_txt("", "1.0", "Foo Bar"))
	_zip(dir + "/100-FooBar.vmz", _mod_txt("", "1.0", "Foo Bar"))
	var rows: Array[Dictionary] = ml.collect_mod_metadata()
	if check_eq(rows.size(), 1, "one row for both copies"):
		check_eq(str(rows[0]["mod_id"]), "FooBar", "the kept copy's id")
		check_eq((rows[0].get("duplicates_hidden", []) as Array).size(), 1, "the other copy is hidden")
	_drop_mods_dir(ml, dir, previous)
	H.pack_cleanup(ml)

# Developer Mode off: a dev folder with no or a broken mod.txt keeps its
# profile key, so the profile does not list it as missing.
func _t81_dev_folders_stay_hidden_keys(ml: Object) -> void:
	H.pack_cleanup(ml)
	var dir := "user://t81_mods"
	DirAccess.make_dir_recursive_absolute(dir + "/ScratchMod/Scripts")
	var previous := _use_mods_dir(ml, dir, true)
	H.write_text(ProjectSettings.globalize_path(dir + "/Broken/mod.txt"), "[mod\nname=\n")
	var was_dev := bool(ml.get("_developer_mode"))
	ml.set("_developer_mode", false)
	ml.set("_ui_mod_entries", ml.collect_mod_metadata())
	for key in ["zip:ScratchMod", "zip:Broken"]:
		_assert(ml.get("_hidden_folder_profile_keys").has(key), key + " is a hidden key")
	ml.set("_active_profile", "Default")
	_seed(ml, [["settings", "active_profile", "Default"], ["profile.Default.enabled", "zip:ScratchMod", true],
			["profile.Default.enabled", "zip:Broken", true]])
	check_eq(ml._missing_mods_in_active_profile(), [], "no hidden folder is missing")
	ml.set("_developer_mode", was_dev)
	_drop_mods_dir(ml, dir, previous)
	H.pack_cleanup(ml)

# Same-priority mods with no name= sort by file name with its extension, as on
# 3.4.2; a dev folder keeps the dots in its name.
func _t82_nameless_mods_sort_by_file_name(ml: Object) -> void:
	var nameless := {"cfg": H.cfg_from_text('[mod]\nversion="1"\n', _report), "status": "ok", "error": ""}
	var named := {"cfg": H.cfg_from_text('[mod]\nname="Foo"\n', _report), "status": "ok", "error": ""}
	var none := {"cfg": null, "status": "none", "error": ""}
	var foo: Dictionary = ml._entry_from_config(nameless, "Foo.zip", "/nonexistent/Foo.zip", "zip")
	var addon: Dictionary = ml._entry_from_config(nameless, "Foo-Addon.zip", "/nonexistent/Foo-Addon.zip", "zip")
	var bare: Dictionary = ml._entry_from_config(none, "Foo-Addon.zip", "/nonexistent/Foo-Addon.zip", "zip")
	var foo_named: Dictionary = ml._entry_from_config(named, "Foo.zip", "/nonexistent/Foo.zip", "zip")
	var addon_named: Dictionary = ml._entry_from_config(named, "Foo-Addon.zip", "/nonexistent/Foo-Addon.zip", "zip")
	for c in [[addon, foo, "Foo-Addon.zip loads before Foo.zip"], [bare, foo, "so does one with no mod.txt"],
			[addon_named, foo_named, "equal names order by file name"]]:
		_assert(ml._compare_load_order(c[0], c[1]) and not ml._compare_load_order(c[1], c[0]), c[2])
	check_eq(str(foo["mod_name"]), "Foo", "the row still shows the stem")
	var folder: Dictionary = ml._entry_from_config(none, "com.me.mod", "/nonexistent/com.me.mod", "folder")
	check_eq(str(folder["mod_id"]), "com.me.mod", "a dotted folder's id")

# A literal "%" is a name Windows can create; it installs under that name.
func _t83_percent_in_a_server_file_name(ml: Object) -> void:
	for good in ["Better Loot 50%.zip", "100%.vmz"]:
		_assert(ml._is_safe_mod_filename(good), "'%s' is accepted" % good)
	check_eq(str(ml._derive_updated_filename("Loot.zip", _disposition("Loot 100%.zip"), "2.0")), "Loot 100%.zip",
			"an update takes the served name")
	check_eq(str(ml._filename_from_content_disposition(PackedStringArray(
			["Content-Disposition: attachment; filename*=UTF-8''Better%20Loot%2050%25.zip"]))),
			"Better Loot 50%.zip", "a decoded % is kept")

# Check for updates asks Vostok Mods with the fresh TTL, not the detail cache.
func _t84_update_check_asks_fresh(_ml: Object) -> void:
	var stub := ManifestStub.new()
	stub._compile_regex()
	await stub.fetch_latest_versions([stub.host_ref("vostokmods", "t84")])
	check_eq(stub.ttls, [int(stub._VM_TTL_FRESH_MS)], "one detail request, fresh TTL")
	_assert(int(stub._VM_TTL_FRESH_MS) < int(stub._VM_TTL_DETAIL_MS), "fresher than the detail cache")
	stub.free()

# Keys are id + "@" + version, so an id that holds "@" still owns its old keys.
func _t93_an_id_with_an_at_keeps_its_state(ml: Object) -> void:
	H.pack_cleanup(ml)
	var cfg := ConfigFile.new()
	for row in [[".enabled", true], [".priority", 5], [".dep_ignore", true]]:
		cfg.set_value("profile.Mine" + row[0], "Author@CoolMod@1.0", row[1])
	var entry := H.mod_entry("author@coolmod@1.1", "author@coolmod", "1.1", {"enabled": false})
	check_eq(str(ml._resolve_stored_key(cfg, "Mine", entry)), "Author@CoolMod@1.0", "stored key of an id with @")
	_install(ml, [entry])
	ml._apply_profile_to_entries(cfg, "Mine")
	_assert(entry["enabled"] and entry["dependency_ignored"], "enabled and Load anyway carry over")
	check_eq(entry["priority"], 5, "priority after the version bump")
	check_eq(entry.get("profile_version_mismatch", {}).get("stored", ""), "1.0", "stored version")
	_assert(ml._stored_key_migrated("Author@CoolMod@1.0", {"author@coolmod": true}, {}), "the old key migrates")
	_assert(not ml._stored_key_migrated("author@coolmod@1.0", {"author@cool": true}, {}), "a shorter id does not claim it")
	for c in [["Author@CoolMod@1.0", "author@coolmod", "1.0"], ["plain@2.0", "plain", "2.0"], ["zip:a.zip", "", ""]]:
		check_eq([ml._profile_key_id(c[0]), ml._version_from_profile_key(c[0])], [c[1], c[2]], "key split: " + c[0])
	H.pack_cleanup(ml)

# A required cycle stalls the walk; an optional edge off it is not released.
func _t94_a_required_cycle_releases_no_optional_edge(ml: Object) -> void:
	var a := H.mod_entry("a@1.0", "a", "1.0", {"required_dependencies": ["b"]})
	var b := H.mod_entry("b@1.0", "b", "1.0", {"required_dependencies": ["a"]})
	var c := H.mod_entry("c@1.0", "c", "1.0", {"optional_dependencies": ["a"]})
	var r: Dictionary = ml._apply_dependency_ordering([a, b, c])
	var ids := PackedStringArray()
	for e: Dictionary in r["ordered"]:
		ids.append(str(e["mod_id"]))
	check_eq(ids, PackedStringArray(["a", "b", "c"]), "load order beside a required cycle")
	check_eq(r["adjusted"], false, "order adjusted")
	check_eq(r["cycle_keys"].size(), 2, "cycle keys")

func _zip_files(path: String) -> PackedStringArray:
	var zr := ZIPReader.new()
	if zr.open(path) != OK:
		return PackedStringArray()
	var files := zr.get_files()
	zr.close()
	return files

# A dev folder already mounted at file scope is re-zipped only once it changed.
func _t95_a_changed_dev_folder_is_rezipped(ml: Object) -> void:
	var dir := "user://t95_mods"
	var previous := _use_mods_dir(ml, dir, true)
	var folder := ProjectSettings.globalize_path(dir + "/T95Dev")
	H.write_text(folder + "/mod.txt", _mod_txt("t95dev", "1.0"))
	var dev_zip := str(ml.zip_folder_to_temp(folder))
	var mounted: Dictionary = ml.get("_filescope_mounted")
	mounted[dev_zip] = true
	H.write_zip(dev_zip, {"t95_sentinel.txt": "x"}, _report)
	var c := {"file_name": "T95Dev", "full_path": folder, "ext": "folder"}
	check_eq(str(ml._mount_candidate(c)), dev_zip, "mount path of an unchanged folder")
	_assert(_zip_files(dev_zip).has("t95_sentinel.txt"), "an unchanged folder is not re-zipped")
	H.write_text(folder + "/Scripts/T95New.gd", "extends Node\n")
	check_eq(str(ml._mount_candidate(c)), dev_zip, "mount path of a changed folder")
	var files := _zip_files(dev_zip)
	_assert(files.has("Scripts/T95New.gd") and not files.has("t95_sentinel.txt"), "a changed folder is re-zipped: %s" % str(files))
	mounted.erase(dev_zip)
	_drop_mods_dir(ml, dir, previous)

func _t96_priority_is_clamped_for_every_kind(ml: Object) -> void:
	for ext in ["zip", "folder"]:
		for c in [["5000", 999], ["-5000", -999]]:
			var read := {"cfg": H.cfg_from_text("[mod]\npriority=%s\n" % c[0], _report), "status": "ok", "error": ""}
			var e: Dictionary = ml._entry_from_config(read, "Mod", "/nonexistent/Mod", ext)
			check_eq([e["priority"], e["priority_default"]], [c[1], c[1]], "%s priority %s" % [ext, c[0]])

# Equal priorities apply in the order the mods loaded, so the later one wins.
func _t97_tied_overrides_apply_in_load_order(ml: Object) -> void:
	var vanilla := "res://Scripts/T97Vanilla.gd"
	var pending: Array[Dictionary] = []
	for c in [["b", 0, 1], ["a", 0, 0], ["low", -1, 2]]:
		var path := "user://t97/%s.gd" % c[0]
		H.write_text(path, "extends Node\nfunc who() -> String:\n\treturn \"%s\"\n" % c[0])
		pending.append({"vanilla_path": vanilla, "mod_script_path": path, "mod_name": c[0], "priority": c[1], "seq": c[2]})
	ml.set("_pending_script_overrides", pending)
	ml._apply_script_overrides()
	var taken := load(vanilla) as GDScript
	check_eq(str(taken.new().call("who")) if taken != null else "", "b", "tied override serving the path")
	var none: Array[Dictionary] = []
	ml.set("_pending_script_overrides", none)

func _t98_claims_are_kept_per_archive(ml: Object) -> void:
	var path := "res://T98/x.gd"
	var registry: Dictionary = ml.get("_override_registry")
	for archive in ["a.zip", "b.zip", "a.zip"]:
		ml._register_claim(path, "Same", archive, 0)
	check_eq(registry[path].size(), 2, "claims of one name in two archives")
	registry.erase(path)

# Foo.vmz and Foo.pck may share a stem: the .pck still mounts.
func _t99_a_pck_sharing_a_loaded_id_mounts(ml: Object) -> void:
	var src := ProjectSettings.globalize_path("user://t99/marker.txt")
	H.write_text(src, "t99")
	var pck := ProjectSettings.globalize_path("user://t99/foo.pck")
	var packer := PCKPacker.new()
	_assert(packer.pck_start(pck) == OK and packer.add_file("res://T99Pck/marker.txt", src) == OK and packer.flush() == OK,
			"the fixture .pck is written")
	var loaded: Dictionary = ml.get("_loaded_mod_ids")
	loaded["foo"] = {"mod_id": "foo"}
	var report: Array = ml.get("_report_lines")
	report.clear()
	ml._process_mod_candidate({"file_name": "foo.pck", "mod_name": "foo", "mod_id": "foo", "ext": "pck", "full_path": pck}, 1)
	_assert(FileAccess.file_exists("res://T99Pck/marker.txt") and not _has_line(report, "Duplicate mod id"),
			"the .pck mounts, no duplicate: %s" % str(report))
	ml._process_mod_candidate({"file_name": "foo.zip", "mod_name": "foo", "mod_id": "foo", "ext": "zip", "full_path": pck}, 2)
	_assert(_has_line(report, "Duplicate mod id 'foo'"), "a second archive of the id is skipped")
	loaded.erase("foo")

# With no hash on either side a pack cannot be compared, so it changed.
func _t100_a_hashless_pack_counts_as_changed(_ml: Object) -> void:
	var stub := ManifestStub.new()
	stub._compile_regex()
	H.pack_cleanup(stub)
	var dir := "user://t100_mods"
	stub._remove_tree(dir, false)
	stub.set("_mods_dir", dir)
	DirAccess.make_dir_recursive_absolute(dir)
	var manifest := {"format": 2, "slug": "t100-bare", "name": "Bare Pack", "hash": "", "mods": []}
	_assert(stub._hosted_import_manifest(manifest)["ok"], "the hashless pack imported")
	stub.served[str(stub._vmp_modpack_manifest_url("t100-bare"))] = manifest.duplicate()
	_seed(stub, [["settings", "active_profile", "Default"], ["settings", "active_modpack", stub._sanitize_profile_name("Bare Pack")]])
	var s: Dictionary = await stub._run_updates_check_for_mods()
	check_eq([s["packs_checked"], s["packs_changed"], s["active_pack_changed"]], [1, 1, "Bare Pack"], "a pack hashless on both sides")
	stub._remove_tree(dir, false)
	H.pack_cleanup(stub)
	stub.free()

## Answers `count` HTTP requests on server with body, then stops it.
func _serve(server: TCPServer, body: PackedByteArray, count: int) -> void:
	for i in count:
		var frames := 0
		while not server.is_connection_available() and frames < 300:
			frames += 1
			await process_frame
		if not server.is_connection_available():
			break
		var peer := server.take_connection()
		var request := ""
		while not request.contains("\r\n\r\n") and frames < 300:
			peer.poll()
			var n := peer.get_available_bytes()
			if n > 0:
				request += peer.get_utf8_string(n)
			else:
				frames += 1
				await process_frame
		var head := "HTTP/1.1 200 OK\r\nContent-Length: %d\r\nConnection: close\r\n\r\n" % body.size()
		peer.put_data(head.to_utf8_buffer() + body)
		for f in 5:
			await process_frame
		peer.disconnect_from_host()
	server.stop()

# A modpack member must match its listed SHA-256 in either case; none listed passes.
func _t101_download_checks_the_listed_checksum(ml: Object) -> void:
	if not ml.is_inside_tree():
		root.add_child(ml)
	var body := "t101 archive bytes".to_utf8_buffer()
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	ctx.update(body)
	var sha := ctx.finish().hex_encode()
	var server := TCPServer.new()
	if not _assert(server.listen(0, "127.0.0.1") == OK, "a loopback server listens"):
		return
	var url := "http://127.0.0.1:%d/t101.zip" % server.get_local_port()
	var temp := ProjectSettings.globalize_path("user://t101.download")
	var cases := [[sha, true], [sha.to_upper(), true], ["", true], ["0".repeat(64), false]]
	_serve(server, body, cases.size())
	for c in cases:
		var r: Dictionary = await ml._http_download_to_temp("vostokmods", url, PackedStringArray(), temp, c[0])
		_assert(bool(r["ok"]) == c[1] and (c[1] or str(r["error"]).contains("checksum")),
				"sha %s gives ok=%s: %s" % [str(c[0]).left(8), c[1], str(r)])
	H.remove_user_file("user://t101.download")
