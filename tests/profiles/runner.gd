## Profiles, modpacks and launcher state against a user:// mods folder (check_profiles.sh).
## Not proven here: network downloads (T78 stubs them), what the hosts serve, the launcher UI.
extends "res://runner_base.gd"

const SNAP := "user://.profile_snapshots/"
const LIVE_MCM := "user://MCM/some-mod/config.ini"
const LIVE_M := "user://MCM/m/config.ini"

# A format-2 manifest like the site's reference doc: one mod available, one
# scanning, one removed; mcmConfig holds a raw per-mod file and an MCM export.
const VM_MANIFEST_JSON := """\n{"format": 2, "slug": "hardcore-survival", "name": "Hardcore Survival",\n "summary": "Short description", "ownerDisplayName": "Ovrrde",\n "url": "https://vostokmods.net/modpack/hardcore-survival",\n "thumbnailUrl": null, "updatedAt": "2026-09-11T16:07:32.051Z",\n "hash": "0123abcd",\n "mcmConfig": {\n   "doinkoink-mcm/config.ini": "[General]\n\nvolume={\\\"value\\\": 3}\n",\n   "export.ini": "[some-mod]\n\nImportModData={\\\"friendlyName\\\": \\\"Some Mod\\\"}\nspeed={\\\"value\\\": 7, \\\"import_data\\\": {\\\"section\\\": \\\"Movement\\\"}}\n",\n   "../evil.ini": "[x]\n\nImportModData={}\n"\n },\n "mods": [\n   {"loadOrder": 1, "slug": "mod-configuration-menu", "name": "MCM", "ownerDisplayName": "metro",\n    "available": true, "reason": null, "version": "2.9.2", "fileName": "mcm.vmz",\n    "fileSize": 4404019, "sha256": "AB12ab12ab12ab12ab12ab12ab12ab12ab12ab12ab12ab12ab12ab12ab12ab12",\n    "downloadUrl": "https://vostokmods.net/api/mods/mod-configuration-menu/versions/2.9.2/download",\n    "pageUrl": "https://vostokmods.net/mod/mod-configuration-menu"},\n   {"loadOrder": 2, "slug": "still-scanning", "name": "Scanning", "ownerDisplayName": "x",\n    "available": false, "reason": "scanning", "version": null, "fileName": null,\n    "fileSize": null, "sha256": null, "downloadUrl": null, "pageUrl": null},\n   {"loadOrder": 3, "slug": "gone", "name": "Gone", "ownerDisplayName": "x",\n    "available": false, "reason": "removed", "version": null, "fileName": null,\n    "fileSize": null, "sha256": null, "downloadUrl": null, "pageUrl": null}\n ]}\n"""

const VM_PACK_ROW_JSON := """
{"id": "01a09139", "slug": "test", "name": "Test", "summary": "", "ownerDisplayName": "Admin Prime",
 "ownerUsername": "admin", "ownerAvatarUrl": null, "createdAt": "2026-09-11T16:07:32.051Z",
 "updatedAt": "2026-09-11T16:30:14.194Z", "modCount": 14, "thumbnailUrl": null,
 "manifestUrl": "https://vostokmods.net/api/modpacks/test/manifest",
 "url": "https://vostokmods.net/modpack/test"}
"""

## The loader with its manifest transport served from `served` by URL; every URL asked is kept.
class ManifestStub extends "res://stub_loader.gd":
	var served := {}
	var asked: Array = []
	var apply_starts := false

	func _hnet_get_json(provider: String, url: String, ttl_ms: int = 0,
			allow_rate_wait: bool = true, allow_transport_retry: bool = true) -> Dictionary:
		asked.append(url)
		if apply_starts:
			_modpack_apply_in_progress = true
		if not served.has(url):
			return host_err(HOST_ERR_NOT_FOUND, 404, "no fixture for " + url)
		return host_ok(served[url])

## The loader with mod_config.cfg turned into a directory after `block_after` runs, so saves fail.
class CfgBlockStub extends "res://stub_loader.gd":
	var block_after := ""

	func _ui_cfg_load(cfg: ConfigFile) -> int:
		var err := super(cfg)
		if block_after == "load":
			_block_cfg()
		return err

	func _restore_mcm_from(profile_name: String) -> bool:
		var ok := super(profile_name)
		if block_after == "restore":
			_block_cfg()
		return ok

	func _block_cfg() -> void:
		block_after = ""
		DirAccess.rename_absolute(UI_CONFIG_PATH, UI_CONFIG_PATH + ".held")
		DirAccess.make_dir_absolute(UI_CONFIG_PATH)

	func unblock_cfg() -> void:
		DirAccess.remove_absolute(UI_CONFIG_PATH)
		DirAccess.rename_absolute(UI_CONFIG_PATH + ".held", UI_CONFIG_PATH)

func _init() -> void:
	super("profiles", "T10..T101")

func _tests(ml: Object) -> void:
	# Mod scans and id matching read the regexes _ready compiles.
	ml._compile_regex()
	for name in ["_vmp_modpack_page", "_modpack_apply_outcome", "_modpack_reconcile_active",
			"_modpack_forget_slot", "_modpack_download_counts", "_modpack_pin_conflict", "force_unload_modpack"]:
		_assert(ml.has_method(name), "the loader has " + name)
	for t in [
		["T10", _t10_hosted_modpacks], ["T14", _t14_modpack_source_installed],
		["T12", _t12_apply_failure_shape], ["T16", _t16_unload_leaves_no_pack_mcm_behind],
		["T17", _t17_pack_keys_follow_the_installed_mods], ["T18", _t18_refreshed_pack_rebuilds_its_slot],
		["T19", _t19_apply_preview_is_read_only], ["T24", _t24_pack_format_version],
		["T29", _t29_pack_version_pins], ["T30", _t30_reimport_hosted_pack],
		["T31", _t31_hosted_pack_names_and_errors], ["T35", _t35_pack_slug_finds_the_mod_txt_uuid],
		["T38", _t38_leaving_a_profile_without_mcm_records_none],
		["T39", _t39_pairing_asks_little_and_covers_unavailable_mods],
		["T40", _t40_pinned_file_matches_by_checksum], ["T41", _t41_one_installed_test_and_cheap_pairing],
		["T46", _t46_profile_outlives_its_last_key], ["T50", _t50_pack_matches_an_unsourced_copy],
		["T51", _t51_reload_heals_the_active_pack], ["T53", _t53_stranded_slot_lands_on_the_backup_profile],
		["T54", _t54_remove_with_a_pack_active_keeps_the_slot_key], ["T56", _t56_hosted_import_regains_checksums],
		["T59", _t59_legacy_pack_key_matches_an_installed_version],
		["T61", _t61_new_profile_flushes_the_priority_debounce], ["T62", _t62_profile_names_have_no_trailing_space],
		["T65", _t65_reopened_launcher_restarts_only_when_the_loaded_set_changed],
		["T66", _t66_post_boot_profile_switch_defers_the_mcm_swap], ["T69", _t69_escaped_dialogs_are_freed],
		["T70", _t70_hosted_packs_with_one_name_keep_their_own_slots],
		["T71", _t71_reopen_rescans_and_restarts_on_the_loaded_set],
		["T72", _t72_post_boot_unload_keeps_the_pack_mcm],
		["T73", _t73_post_boot_profile_edits_follow_the_pending_swap],
		["T74", _t74_post_boot_apply_backs_up_the_right_mcm],
		["T77", _t77_rename_moves_the_slot_and_missing_rows_go], ["T78", _t78_pack_downloads_through_a_stub],
		["T79", _t79_pending_swap_in_the_backup_completes],
		["T80", _t80_write_without_the_live_file_keeps_the_backup],
		["T81", _t81_pack_mcm_limits], ["T82", _t82_hosted_record_keeps_the_cover],
		["T83", _t83_no_pack_fetch_during_an_apply], ["T84", _t84_pack_restore_caps_mcm],
		["T85", _t85_force_unload_keeps_the_pack_as_a_profile],
		["T86", _t86_342_slot_with_an_edge_space_migrates],
		["T87", _t87_unchanged_pack_skips_the_mcm_caps],
		["T88", _t88_unload_without_a_backup_slot_keeps_the_mcm],
		["T89", _t89_capture_from_a_slotless_profile_takes_the_live_mcm],
		["T90", _t90_in_place_update_needs_a_restart], ["T91", _t91_row_counts_hash_no_file],
		["T92", _t92_pack_scan_opens_each_zip_once],
		["T93", _t93_unlisted_active_lands_on_the_first_profile],
		["T94", _t94_id_prefix_takes_no_other_mods_keys],
		["T95", _t95_profile_names_keep_every_digit],
		["T96", _t96_resnapshot_drops_deleted_mcm_files],
		["T97", _t97_mcm_copy_skips_dot_entries],
		["T98", _t98_hashless_pack_reimports_its_changes],
		["T99", _t99_slotless_active_pack_refuses_a_replace],
		["T100", _t100_newest_same_named_pack_wins],
		["T101", _t101_failed_cfg_save_stops_the_mcm_switch],
	]:
		begin(t[0])
		await t[1].call(ml)
	begin("")

## A ConfigFile of [section, key, value] rows saved as mod_config.cfg + suffix.
func _seed(ml: Object, rows: Array, suffix := "") -> ConfigFile:
	var cfg := ConfigFile.new()
	for r in rows:
		cfg.set_value(r[0], r[1], r[2])
	_assert(cfg.save(str(ml.UI_CONFIG_PATH) + suffix) == OK, "seeded mod_config.cfg" + suffix)
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

## The installed entry whose field equals value, or {}.
func _find(ml: Object, field: String, value: String) -> Dictionary:
	for e: Dictionary in ml.get("_ui_mod_entries"):
		if str(e.get(field, "")) == value:
			return e
	return {}

## An [updates] source=, with a [mod] version= when one is given.
func _source_cfg(source: String, version := "") -> ConfigFile:
	var cfg := ConfigFile.new()
	if version != "":
		cfg.set_value("mod", "version", version)
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

func _slot(entry: Dictionary, suffix := ".enabled") -> String:
	return "profile.modpack__" + str(entry["sanitized_name"]) + suffix

## [mcm_pending_from, mcm_pending_to] as saved.
func _pending(ml: Object) -> Array:
	var cfg := _read(ml)
	return [str(cfg.get_value("settings", "mcm_pending_from", "")), str(cfg.get_value("settings", "mcm_pending_to", ""))]

## Two installed mods on Default, a@1.0 and foo@2.0; only [mod_sources] says
## foo came from Vostok Mods.
func _pack_setup(ml: Object) -> void:
	H.pack_cleanup(ml)
	_install(ml, [H.mod_entry("a@1.0", "a", "1.0"), H.mod_entry("foo@2.0", "foo", "2.0")])
	ml.set("_active_profile", "Default")
	_seed(ml, [["settings", "active_profile", "Default"], ["profile.Default.enabled", "a@1.0", true],
			["mod_sources", "foo@2.0", ml._serialize_mod_source_rec({"provider": "vostokmods", "id": "foo", "version": "2.0"})]])

func _pack_write(ml: Object, profile: Dictionary, mcm_value: String) -> Dictionary:
	H.remove_user_file(H.PACK_ZIP)
	# The scan remembers a zip by mtime and size; a rewrite in the same second keeps both.
	(ml.get("_modpack_zip_memo") as Dictionary).clear()
	var entry: Dictionary = ml._build_modpack_entry(H.write_zip(H.PACK_ZIP, {"profile.json": JSON.stringify(profile),
			"MCM/some-mod/config.ini": "[a]\nv=" + mcm_value + "\n"}, _report))
	var packs: Array[Dictionary] = [entry]
	ml.set("_modpack_entries", packs)
	return entry

## Profile A is active with its MCM live, B has its own snapshot, boot is done.
func _ab_profiles(ml: Object) -> void:
	H.pack_cleanup(ml)
	H.write_text(LIVE_M, "A")
	H.write_text(SNAP + "B/MCM/m/config.ini", "B")
	_install(ml, [H.mod_entry("a@1.0", "a", "1.0")])
	ml.set("_active_profile", "A")
	_seed(ml, [["settings", "active_profile", "A"], ["profile.A.enabled", "a@1.0", true],
			["profile.B.enabled", "a@1.0", false]])
	ml.set("_boot_complete", true)

func _t10_hosted_modpacks(ml: Object) -> void:
	var want := "https://vostokmods.net/api/modpacks/hardcore-survival/manifest"
	for text in [want, "http://vostokmods.net/modpack/hardcore-survival", "vostokmods.net/modpack/hardcore-survival?utm=1",
			"https://www.vostokmods.net/modpack/Hardcore-Survival/", "hardcore-survival"]:
		check_eq(str(ml._vmp_modpack_manifest_url(text)), want, "manifest URL of '%s'" % text)
	for text in ["https://evil.example/api/modpacks/x/manifest", "https://vostokmods.net.evil.example/modpack/x",
			"https://vostokmods.net@evil.example/modpack/x", "https://vostokmods.net/mod/some-mod", "has space", ""]:
		check_eq(str(ml._vmp_modpack_manifest_url(text)), "", "manifest URL of '%s'" % text)

	var s: Dictionary = ml._vmp_modpack_summary(JSON.parse_string(VM_PACK_ROW_JSON))
	_assert(str(s["slug"]) == "test" and str(s["name"]) == "Test", "pack summary slug and name")
	check_eq(int(s["mod_count"]), 14, "pack summary mod_count")
	_assert(str(s["manifest_url"]).ends_with("/api/modpacks/test/manifest"), "pack summary manifest_url")
	check_eq(str(s["page_url"]), "https://vostokmods.net/modpack/test", "pack summary page_url")

	# A body without `entries` is a changed shape, not an empty page of packs.
	var page: Dictionary = ml._vmp_modpack_page(JSON.parse_string('{"entries": [' + VM_PACK_ROW_JSON
			+ ', {"id": "x", "name": "No slug"}], "total": 2, "page": 1, "pageCount": 1}'))
	_assert(page["ok"], "a listing under entries is read")
	var rows: Array = page["data"]["rows"]
	_assert(rows.size() == 1 and str(rows[0]["slug"]) == "test", "rows from entries, slugless dropped (got %d)" % rows.size())
	_assert(int(page["data"]["total"]) == 2 and not page["data"]["has_more"], "listing total and paging")
	var more: Dictionary = ml._vmp_modpack_page(JSON.parse_string('{"entries": [], "total": 45, "page": 2, "pageCount": 3}'))
	_assert(more["ok"] and more["data"]["has_more"] and str(more["data"]["next_cursor"]) == "3", "an empty page still pages on")
	for bad in ['{"modpacks": [{"slug": "a"}], "total": 1}', '{"page": 1}', '[]']:
		_assert(not ml._vmp_modpack_page(JSON.parse_string(bad))["ok"], "a body without entries is an error: " + bad)

	var manifest: Variant = JSON.parse_string(VM_MANIFEST_JSON)
	_assert(manifest is Dictionary, "manifest fixture parses")
	check_eq(str(ml._vmp_validate_manifest(manifest)), "", "format-2 manifest validation error")
	var newer: Dictionary = (manifest as Dictionary).duplicate()
	newer["format"] = 3
	_assert(str(ml._vmp_validate_manifest(newer)) != "", "a newer format is refused")
	_assert(str(ml._vmp_validate_manifest({"format": 2, "slug": "x"})) != "", "a manifest with no mods is refused")

	var conv: Dictionary = ml._hosted_manifest_to_profile(manifest)
	var profile: Dictionary = conv["profile"]
	check_eq(int(profile["metroprofile"]), 1, "metroprofile version")
	_assert(str(profile["name"]) == "Hardcore Survival" and str(profile["author"]) == "Ovrrde", "name and author carried over")
	var enabled: Dictionary = profile["enabled"]
	_assert(enabled.size() == 3 and enabled.has("vostokmods:mod-configuration-menu") and enabled.has("vostokmods:gone"),
			"every listed mod enabled by slug: %s" % str(enabled.keys()))
	var priority: Dictionary = profile["priority"]
	_assert(int(priority["vostokmods:mod-configuration-menu"]) == 1 and int(priority["vostokmods:gone"]) == 3,
			"priority follows loadOrder")
	var sources: Dictionary = profile["sources"]
	check_eq(sources.keys(), ["vostokmods:mod-configuration-menu"], "mods with a source record")
	var src: Dictionary = sources["vostokmods:mod-configuration-menu"]
	_assert(str(src["provider"]) == "vostokmods" and str(src["id"]) == "mod-configuration-menu"
			and str(src["version"]) == "2.9.2", "source record pins the manifest version")
	var rec: Dictionary = ml._normalize_source_record(src)
	_assert(str(rec["provider"]) == "vostokmods" and str(rec["version"]) == "2.9.2", "source record survives the normalizer")
	_assert(not src.has("modworkshop_id"), "no ModWorkshop mirror on the record")
	var unavailable: Dictionary = profile["unavailable"]
	_assert(str(unavailable.get("vostokmods:still-scanning")) == "scanning" and str(unavailable.get("vostokmods:gone")) == "removed",
			"unavailable mods keep the site's reason")
	check_eq(str(profile["checksums"].get("vostokmods:mod-configuration-menu")),
			"ab12ab12ab12ab12ab12ab12ab12ab12ab12ab12ab12ab12ab12ab12ab12ab12", "sha256 kept lowercased")
	var hosted: Dictionary = profile["hosted"]
	_assert(str(hosted["slug"]) == "hardcore-survival" and str(hosted["hash"]) == "0123abcd" and int(hosted["format"]) == 2,
			"hosted record: slug, hash and format")
	_assert(str(ml._hosted_unavailable_copy("scanning")).contains("scanned"), "scanning reason has its own copy")

	# The raw file passes through, the export merges into its mod's config.ini.
	var mcm: Dictionary = conv["mcm"]
	_assert(str(mcm.get("doinkoink-mcm/config.ini", "")).contains("volume"), "raw per-mod MCM file kept verbatim")
	_assert(mcm.has("some-mod/config.ini"), "export merged into some-mod: %s" % str(mcm.keys()))
	var merged := ConfigFile.new()
	_assert(merged.parse(str(mcm["some-mod/config.ini"])) == OK, "merged config parses")
	var v: Variant = merged.get_value("Movement", "speed", null)
	_assert(v is Dictionary and int(v.get("value", 0)) == 7 and not v.has("import_data"),
			"merged value lands in its section, unmarked")
	for k in mcm.keys():
		_assert(not str(k).contains(".."), "no MCM key with ..: " + str(k))
	_assert(not mcm.has("x/config.ini"), "an export under an unsafe key is dropped")
	_assert(not conv["warnings"].is_empty(), "the unsafe MCM key warns")

	# Only profile.json and the MCM/ tree of a pack zip reach user://.
	var pack_zip := H.write_zip("user://host_pack.zip", {
		"profile.json": JSON.stringify({"metroprofile": 1, "name": "Strangers", "enabled": {"x@1": true}}),
		"mod_config.cfg": "[settings]\nactive_profile=\"Evil\"\n",
		"foo.txt": "x",
		"evil.pck": "GDPC",
		"MCM/some-mod/config.ini": "[a]\nv=1\n",
		"MCM/../escape.ini": "[a]\n",
	}, _report)
	var before := H.snapshot_user()
	var validation: Dictionary = ml._validate_modpack({"file_path": pack_zip})
	_assert(validation["ok"], "stray files still validate: %s" % validation.get("error"))
	_assert(H.snapshot_user() == before, "validation writes nothing under user://")
	var cfg_path := str(ml.UI_CONFIG_PATH)
	H.remove_user_file(cfg_path)
	H.remove_user_file(cfg_path + ".bak")
	var mat: Dictionary = ml._materialize_modpack_profile({"file_path": pack_zip}, "modpack__strangers")
	_assert(mat["ok"], "the pack materializes: %s" % mat.get("error"))
	_assert(FileAccess.file_exists(SNAP + "modpack__strangers/MCM/some-mod/config.ini"), "the MCM tree lands in the slot")
	var cfg_rel := cfg_path.trim_prefix("user://")
	var leaked: Array = []
	for p: String in H.snapshot_user():
		if not before.has(p) and not (p in [cfg_rel, cfg_rel + ".bak", ".profile_snapshots/"]) \
				and not p.begins_with(".profile_snapshots/modpack__strangers/"):
			leaked.append(p)
	check_eq(leaked, [], "other files written under user://")
	_assert(not FileAccess.file_exists("user://escape.ini") and not FileAccess.file_exists(SNAP + "escape.ini"),
			"an MCM entry with .. is dropped")
	var written := ConfigFile.new()
	_assert(written.load(cfg_path) == OK and str(written.get_value("settings", "active_profile", "")) != "Evil",
			"the pack's mod_config.cfg never replaces ours")
	ml._remove_tree("user://.profile_snapshots", false)
	for p in [cfg_path, cfg_path + ".bak", "user://host_pack.zip"]:
		H.remove_user_file(p)

	check_eq(str(ml._hosted_pack_file_path("../Weird Slug!")).get_file(), "vostokmods-weirdslug.zip", "pack file name")
	check_eq(str(ml._hosted_pack_file_path("!!!")), "", "path for a slug with nothing safe")

# Every apply result has the same keys, so the dialogs read the counts
# unchecked. Both failures return before any download, without suspending.
func _t12_apply_failure_shape(ml: Object) -> void:
	var r: Dictionary = await ml._apply_modpack_inner({}, null, Callable())
	ml.set("_modpack_apply_in_progress", true)
	var busy: Dictionary = await ml.apply_modpack({}, null, Callable())
	ml.set("_modpack_apply_in_progress", false)
	for c in [["validation failure", r], ["apply in progress", busy]]:
		var keys: Array = c[1].keys()
		keys.sort()
		check_eq(keys, ["downloaded", "error", "failed_downloads", "failures", "ok"], c[0] + " result keys")
	_assert(not r["ok"] and str(r["error"]) != "", "a validation failure is ok=false with a message")
	_assert(r["downloaded"] == 0 and r["failed_downloads"] == 0 and r["failures"] is Array and r["failures"].is_empty(),
			"a validation failure downloads nothing: %s" % str(r))
	_assert(not busy["ok"] and str(busy["error"]).contains("in progress"), "the busy refusal says so: %s" % busy["error"])
	# A failed apply is a failure even with failed downloads in its counts.
	var failed: Dictionary = ml._modpack_apply_failure("cannot read settings", 2, 1, [{"profile_key": "a@1"}])
	for c in [[failed, "failed"], [{"ok": true, "failed_downloads": 1}, "partial"],
			[{"ok": true, "failed_downloads": 0}, "applied"],
			[{"ok": false, "cancelled": true, "failed_downloads": 1}, "cancelled"]]:
		check_eq(str(ml._modpack_apply_outcome(c[0])), c[1], "outcome of %s" % str(c[0]))

# A pack record counts as installed by host ref, at the pinned version when
# it pins one, without a v prefix; a legacy modworkshop_id resolves the same.
func _t14_modpack_source_installed(ml: Object) -> void:
	var installed := {"vostokmods:rtvcoop": ["5.0.0", "v5.1.0"], "modworkshop:777": ["1.0"]}
	for c in [
		["unpinned, installed", {"provider": "vostokmods", "id": "rtvcoop"}, true],
		["pinned to an installed version", {"provider": "vostokmods", "id": "rtvcoop", "version": "5.0.0"}, true],
		["pinned with a v prefix", {"provider": "vostokmods", "id": "rtvcoop", "version": "v5.0.0"}, true],
		["pinned to the v-prefixed copy", {"provider": "vostokmods", "id": "rtvcoop", "version": "5.1.0"}, true],
		["pinned to a version not on disk", {"provider": "vostokmods", "id": "rtvcoop", "version": "5.2.0"}, false],
		["not installed at all", {"provider": "vostokmods", "id": "other"}, false],
		["legacy modworkshop_id record", {"modworkshop_id": 777}, true],
		["legacy record pinned elsewhere", {"modworkshop_id": 777, "version": "2.0"}, false],
		["unknown provider", {"provider": "steam", "id": "1"}, false],
		["not a record", "rtvcoop", false],
	]:
		check_eq(bool(ml._modpack_source_installed(c[1], installed)), c[2], c[0])
	for c in [["Vostok Mods", ml.host_ref("vostokmods", "x"), true], ["ModWorkshop", ml.host_ref("modworkshop", "1"), true],
			["empty", {}, false], ["unknown host", {"provider": "steam", "id": "1"}, false]]:
		check_eq(bool(ml._modpack_ref_downloadable(c[1])), c[2], c[0] + " ref downloadable")

func _t16_unload_leaves_no_pack_mcm_behind(ml: Object) -> void:
	_pack_setup(ml)
	var round_trip := {"metroprofile": 1, "name": "Round Trip", "enabled": {"a@1.0": true}}
	var r: Dictionary = await ml.apply_modpack(_pack_write(ml, round_trip, "1"), null, Callable())
	_assert(r["ok"], "the pack applies: %s" % r.get("error"))
	_assert(FileAccess.file_exists(LIVE_MCM), "the pack's MCM is live while active")
	var u: Dictionary = ml.unload_modpack(null)
	_assert(u["ok"], "the pack unloads: %s" % u.get("error"))
	check_eq(str(ml.get("_active_profile")), "Default", "profile after unload")
	_assert(not FileAccess.file_exists(LIVE_MCM), "unload leaves no pack MCM behind")
	_assert(not FileAccess.file_exists(SNAP + "Default/MCM/some-mod/config.ini"), "pack MCM not seeded into the player's slot")
	_assert(not DirAccess.dir_exists_absolute(ProjectSettings.globalize_path(SNAP + "_before_modpack_Round Trip")),
			"the consumed backup slot is removed")

	# A player who had MCM settings gets exactly those back.
	_pack_setup(ml)
	H.write_text("user://MCM/mine/config.ini", "[m]\nv=own\n")
	r = await ml.apply_modpack(_pack_write(ml, round_trip, "1"), null, Callable())
	_assert(r["ok"] and not FileAccess.file_exists("user://MCM/mine/config.ini"), "an active pack's MCM replaces the player's")
	var retained := SNAP + "_before_modpack_Round Trip/overrides/Preferences.tres"
	H.write_text(retained, "player preferences")
	ml.unload_modpack(null)
	_assert(FileAccess.file_exists(retained), "unload keeps files beside the MCM snapshot")
	_assert(FileAccess.get_file_as_string("user://MCM/mine/config.ini").contains("v=own")
			and not FileAccess.file_exists(LIVE_MCM), "unload restores the player's own MCM only")
	H.pack_cleanup(ml)

# A pack keys a mod it has not seen installed by host ("vostokmods:foo"); every
# path a mod can land by rewrites that key to the mod's own.
func _t17_pack_keys_follow_the_installed_mods(ml: Object) -> void:
	_pack_setup(ml)
	var entry := _pack_write(ml, {"metroprofile": 1, "name": "Round Trip", "enabled": {"a@1.0": true, "vostokmods:foo": true},
			"sources": {"vostokmods:foo": {"provider": "vostokmods", "id": "foo"}}}, "1")
	var en := _slot(entry)
	# An earlier apply left the slot keyed by the pack; foo was installed since.
	var kept := _read(ml)
	kept.set_value(en, "a@1.0", true)
	kept.set_value(en, "vostokmods:foo", true)
	kept.set_value(_slot(entry, ".priority"), "a@1.0", 77)
	kept.save(str(ml.UI_CONFIG_PATH))
	var r: Dictionary = await ml.apply_modpack(entry, null, Callable())
	_assert(r["ok"], "applies over its kept slot: %s" % r.get("error"))
	var cfg := _read(ml)
	check_eq(cfg.get_value(_slot(entry, ".priority"), "a@1.0", 0), 77, "kept slot priority")
	_assert(cfg.has_section_key(en, "foo@2.0") and not cfg.has_section_key(en, "vostokmods:foo"), "the kept slot's keys are reconciled")
	# A download lands outside the apply loop while the pack is active.
	cfg.erase_section_key(en, "foo@2.0")
	cfg.set_value(en, "vostokmods:foo", true)
	cfg.save(str(ml.UI_CONFIG_PATH))
	check_eq(ml._modpack_reconcile_active(), 1, "stub keys reconciled")
	cfg = _read(ml)
	_assert(cfg.has_section_key(en, "foo@2.0") and not cfg.has_section_key(en, "vostokmods:foo"), "the stub key moved to the install")
	ml.unload_modpack(null)
	check_eq(ml._modpack_reconcile_active(), 0, "keys reconciled with no pack active")
	H.pack_cleanup(ml)

# Unload keeps the slot, so a second apply reads it; a slot dropped after a
# Refresh rewrote the zip is rebuilt from the new zip.
func _t18_refreshed_pack_rebuilds_its_slot(ml: Object) -> void:
	_pack_setup(ml)
	var entry := _pack_write(ml, {"metroprofile": 1, "name": "Round Trip", "enabled": {"a@1.0": true}, "priority": {"a@1.0": 5}}, "1")
	var name := str(entry["sanitized_name"])
	var en := _slot(entry)
	var pri := _slot(entry, ".priority")
	var rebuilt := func() -> bool:
		var c := _read(ml)
		return c.get_value(pri, "a@1.0", 0) == 9 and c.has_section_key(en, "foo@2.0")
	var r: Dictionary = await ml.apply_modpack(entry, null, Callable())
	_assert(r["ok"], "the pack applies: %s" % r.get("error"))
	_assert(not ml._modpack_forget_slot(name), "the active pack's slot is never dropped")
	ml.unload_modpack(null)
	var cfg := _read(ml)
	cfg.set_value(pri, "a@1.0", 6)
	cfg.save(str(ml.UI_CONFIG_PATH))
	r = await ml.apply_modpack(entry, null, Callable())
	_assert(r["ok"] and _read(ml).get_value(pri, "a@1.0", 0) == 6, "a second apply reads the kept slot")
	ml.unload_modpack(null)
	# A zip replaced under the same name is another pack.
	entry = _pack_write(ml, {"metroprofile": 1, "name": "Round Trip", "enabled": {"a@1.0": true, "foo@2.0": true},
			"priority": {"a@1.0": 9}}, "2")
	r = await ml.apply_modpack(entry, null, Callable())
	_assert(r["ok"] and rebuilt.call(), "a changed zip rebuilds the slot")
	ml.unload_modpack(null)
	_assert(ml._modpack_forget_slot(name), "a kept slot can be dropped")
	cfg = _read(ml)
	_assert(not cfg.has_section(en) and not cfg.has_section(pri), "dropping a slot erases its sections")
	_assert(not DirAccess.dir_exists_absolute(ProjectSettings.globalize_path(SNAP + "modpack__" + name)),
			"dropping a slot removes its MCM snapshot")
	_assert(cfg.has_section("profile.Default.enabled"), "the player's own profile is untouched")
	r = await ml.apply_modpack(entry, null, Callable())
	_assert(r["ok"] and rebuilt.call(), "the rebuilt slot has the new list")
	_assert(FileAccess.get_file_as_string(LIVE_MCM).contains("v=2"), "the rebuilt slot has the new MCM")
	ml.unload_modpack(null)
	H.pack_cleanup(ml)

# The Apply preview writes nothing and counts only what can be downloaded.
func _t19_apply_preview_is_read_only(ml: Object) -> void:
	_pack_setup(ml)
	var cfg_path := str(ml.UI_CONFIG_PATH)
	var entry := _pack_write(ml, {"metroprofile": 1, "name": "Preview",
			"enabled": {"a@1.0": true, "vostokmods:new-mod": true, "vostokmods:scanning": true, "nosource@1.0": true},
			"sources": {"vostokmods:new-mod": {"provider": "vostokmods", "id": "new-mod", "version": "1.0"}},
			"unavailable": {"vostokmods:scanning": "scanning"}}, "1")
	H.remove_user_file(cfg_path + ".bak")
	var before := FileAccess.get_file_as_string(cfg_path)
	var missing: Array = ml._get_missing_mods_for_modpack(entry)
	check_eq(missing.size(), 3, "listed mods not installed")
	_assert(FileAccess.get_file_as_string(cfg_path) == before and not FileAccess.file_exists(cfg_path + ".bak"),
			"previewing an apply writes nothing")
	check_eq(ml._modpack_download_counts(missing), {"download": 1, "blocked": 2}, "download counts")
	check_eq(ml._modpack_download_counts([]), {"download": 0, "blocked": 0}, "download counts of nothing")
	H.pack_cleanup(ml)

func _t24_pack_format_version(ml: Object) -> void:
	H.pack_cleanup(ml)
	var res: Dictionary = ml._validate_modpack(_pack_write(ml, {"metroprofile": 2, "name": "Newer", "enabled": {}}, "1"))
	_assert(not res["ok"] and str(res["error"]).contains("newer version of the mod loader"),
			"a newer format asks for an update: %s" % res["error"])
	res = ml._validate_modpack(_pack_write(ml, {"name": "Unmarked", "enabled": {}}, "1"))
	_assert(not res["ok"] and not str(res["error"]).contains("newer version"),
			"no format version blames no old loader: %s" % res["error"])
	_assert(ml._validate_modpack(_pack_write(ml, {"metroprofile": 1, "name": "Current", "enabled": {}}, "1"))["ok"],
			"format version 1 validates")
	H.pack_cleanup(ml)

# A pin never enables another installed version; an older pin fails before
# the newest-copy selector can hide its download.
func _t29_pack_version_pins(ml: Object) -> void:
	_pack_setup(ml)
	var pin := {"provider": "vostokmods", "id": "foo", "version": "1.0"}
	var pack := {"metroprofile": 1, "name": "Pinned", "enabled": {"vostokmods:foo": true},
			"priority": {"vostokmods:foo": 8}, "dep_ignore": {"vostokmods:foo": true}, "sources": {"vostokmods:foo": pin}}
	for version in ["1.0", "3.0", "v2.0", ""]:
		pin["version"] = version
		_assert(ml._materialize_modpack_profile(_pack_write(ml, pack, "1"), "modpack__Pinned")["ok"], "pinned fixture materializes")
		var cfg := _read(ml)
		var resolves: bool = version in ["v2.0", ""]
		for suffix in [".enabled", ".priority", ".dep_ignore"]:
			var sec: String = "profile.modpack__Pinned" + suffix
			_assert(cfg.has_section_key(sec, "foo@2.0") == resolves, "%s pin '%s' resolves only to itself" % [suffix, version])
			_assert(cfg.has_section_key(sec, "vostokmods:foo") != resolves, "%s keeps an unresolved pin as missing" % suffix)
	_pack_setup(ml)
	pin["version"] = "1.0"
	var entry := _pack_write(ml, pack, "1")
	var before := FileAccess.get_file_as_bytes(str(ml.UI_CONFIG_PATH))
	var r: Dictionary = await ml.apply_modpack(entry, null, Callable())
	_assert(not r["ok"] and str(r["error"]).contains("newer installed version"), "an older pin is refused as a conflict")
	_assert(r["downloaded"] == 0 and r["failed_downloads"] == 0, "the conflict is refused before downloading")
	_assert(before == FileAccess.get_file_as_bytes(str(ml.UI_CONFIG_PATH)), "the conflict changes no profile state")
	# A pack from the site pinned what it had when fetched: refresh it.
	var hosted: Dictionary = pack.duplicate(true)
	hosted["hosted"] = {"provider": "vostokmods", "slug": "round-trip"}
	_assert(str(ml._modpack_pin_conflict(_pack_write(ml, hosted, "1"))).contains("Refresh the pack"), "a site pack says to refresh")
	pin["version"] = "3.0"
	_assert(str(ml._modpack_pin_conflict(_pack_write(ml, pack, "1"))).is_empty(), "a newer pinned version still downloads")
	H.pack_cleanup(ml)

# Paste, Get and Refresh share the import: a changed zip does not reuse an
# earlier slot, and an active pack is not replaced.
func _t30_reimport_hosted_pack(ml: Object) -> void:
	_pack_setup(ml)
	var previous := _use_mods_dir(ml, "user://t30_mods")
	var manifest := {"format": 2, "name": "Hosted Again", "slug": "hosted-again", "hash": "one",
			"mods": [{"slug": "foo", "name": "Foo Mod", "version": "2.0", "available": true, "loadOrder": 5}],
			"mcmConfig": {"some-mod/config.ini": "[a]\nv=1\n"}}
	var imported: Dictionary = ml._hosted_import_manifest(manifest)
	_assert(imported["ok"], "the first import succeeds")
	check_eq((ml.get("_pack_mod_names") as Dictionary).get("vostokmods:foo"), "Foo Mod", "the import keeps mod names")
	var applied: Dictionary = await ml.apply_modpack(ml._build_modpack_entry(str(imported["file_path"])), null, Callable())
	_assert(applied["ok"], "the hosted pack applies without downloads")
	var before := FileAccess.get_file_as_bytes(str(imported["file_path"]))
	_assert(ml._hosted_import_manifest(manifest)["ok"], "an unchanged import keeps the active pack")
	manifest["hash"] = "two"
	manifest["mods"][0]["loadOrder"] = 9
	manifest["mcmConfig"]["some-mod/config.ini"] = "[a]\nv=2\n"
	var refused: Dictionary = ml._hosted_import_manifest(manifest)
	check_eq([refused["ok"], refused["error"]], [false, "Unload \"Hosted Again\" before replacing its modpack file."],
			"a changed active pack needs an unload")
	_assert(before == FileAccess.get_file_as_bytes(str(imported["file_path"])), "the refusal leaves the active zip intact")
	ml.unload_modpack(null)
	var refreshed: Dictionary = ml._hosted_import_manifest(manifest)
	_assert(refreshed["ok"], "a changed inactive pack imports")
	var entry: Dictionary = ml._build_modpack_entry(str(refreshed["file_path"]))
	applied = await ml.apply_modpack(entry, null, Callable())
	_assert(applied["ok"] and _read(ml).get_value(_slot(entry, ".priority"), "foo@2.0", 0) == 9,
			"the reimport applies the new priority")
	_assert(FileAccess.get_file_as_string(LIVE_MCM).contains("v=2"), "the reimport applies the new MCM")
	ml.unload_modpack(null)
	_drop_mods_dir(ml, "user://t30_mods", previous)
	H.pack_cleanup(ml)

# A name with no cased letters sanitizes to "": the import falls back to the
# slug. A refused manifest keeps the validator's reason.
func _t31_hosted_pack_names_and_errors(ml: Object) -> void:
	_pack_setup(ml)
	var previous := _use_mods_dir(ml, "user://t31_mods")
	var uncased := char(0x751F) + char(0x5B58) + " " + char(0x5305)
	check_eq(str(ml._sanitize_profile_name(uncased)).strip_edges(), "", "fixture name sanitized")
	var imported: Dictionary = ml._hosted_import_manifest({"format": 2, "name": uncased, "slug": "survival-cn", "hash": "one",
			"mods": [{"slug": "foo", "version": "2.0", "available": true, "loadOrder": 1}]})
	_assert(imported["ok"] and str(imported["name"]) == "survival-cn", "an unusable name imports as the slug: %s" % imported.get("name"))
	var entry: Dictionary = ml._build_modpack_entry(str(imported["file_path"]))
	check_eq(str(entry["sanitized_name"]), "survival-cn", "imported pack slot name")
	var applied: Dictionary = await ml.apply_modpack(entry, null, Callable())
	_assert(applied["ok"], "the imported pack applies: %s" % applied.get("error"))
	ml.unload_modpack(null)
	var too_new: Dictionary = ml.host_err(ml.HOST_ERR_BAD_RESPONSE, 0, str(ml._vmp_validate_manifest({"format": 99, "mods": []})))
	_assert(str(ml._hosted_fetch_error_copy(too_new)).contains("update the mod loader"), "a too-new manifest asks for an update")
	for c in [["offline", ml.host_err(ml.HOST_ERR_OFFLINE, 0, "")], ["bare bad response", ml.host_err(ml.HOST_ERR_BAD_RESPONSE, 0, "")]]:
		check_eq(str(ml._hosted_fetch_error_copy(c[1])), str(ml.host_error_message(ml.HOST_VOSTOKMODS, c[1])), c[0] + " copy")
	_drop_mods_dir(ml, "user://t31_mods", previous)
	H.pack_cleanup(ml)

# A pack names a mod by slug; the site writes the UUID into the mod.txt of the
# file it serves. Once a host response pairs the two, the slug finds the mod.
func _t35_pack_slug_finds_the_mod_txt_uuid(ml: Object) -> void:
	H.pack_cleanup(ml)
	var uuid := "01a0a18a-3e89-7977-a03a-c3b839ea00cf"
	var foo := H.mod_entry("foo@2.0", "foo", "2.0", {"enabled": false, "cfg": _source_cfg("vostokmods:" + uuid, "2.0")})
	_install(ml, [H.mod_entry("a@1.0", "a", "1.0"), foo])
	ml.set("_active_profile", "Default")
	_seed(ml, [["settings", "active_profile", "Default"], ["profile.Default.enabled", "a@1.0", true],
			["mod_sources", "foo@2.0", ml._serialize_mod_source_rec({"provider": "vostokmods", "id": uuid, "version": "2.0"})]])
	var entry := _pack_write(ml, {"metroprofile": 1, "name": "Round Trip", "enabled": {"a@1.0": true, "vostokmods:foo": true},
			"sources": {"vostokmods:foo": {"provider": "vostokmods", "id": "foo", "version": "2.0"}}}, "1")
	var aliases: Dictionary = ml.get("_host_ref_aliases")
	aliases.clear()
	(ml.get("_mods_meta_by_key") as Dictionary).clear()
	var ask: Array = ml._modpack_unpaired_host_refs(entry)
	_assert(ask.size() == 1 and str(ml.host_ref_key(ask[0])) == "vostokmods:" + uuid, "unpaired, the UUID is asked about: %s" % str(ask))
	check_eq(ml._get_missing_mods_for_modpack(entry).size(), 1, "missing mods while unpaired")
	ml._vmp_note_ids({"id": uuid, "slug": "foo"})
	_assert("vostokmods:" + uuid in ml.host_ref_aliases("vostokmods:foo")
			and "vostokmods:foo" in ml.host_ref_aliases("vostokmods:" + uuid), "an id and a slug pair both ways")
	_assert(ml._modpack_unpaired_host_refs(entry).is_empty(), "paired, the apply asks nothing")
	_assert(ml._get_missing_mods_for_modpack(entry).is_empty(), "paired, the slug finds the installed mod")
	_assert(ml._browse_install_map().has("vostokmods:foo"), "paired, a Browse row finds the mod")
	var r: Dictionary = await ml.apply_modpack(entry, null, Callable())
	_assert(r["ok"] and r["downloaded"] == 0 and r["failed_downloads"] == 0, "applies without downloading: %s" % str(r))
	var en := _slot(entry)
	var cfg := _read(ml)
	_assert(cfg.has_section_key(en, "foo@2.0") and not cfg.has_section_key(en, "vostokmods:foo"), "the slot is keyed by the install")
	_assert(_find(ml, "profile_key", "foo@2.0").get("enabled", false), "the pack's mod is enabled")
	ml.unload_modpack(null)
	aliases.clear()
	H.pack_cleanup(ml)

# A profile left with no user://MCM gets an empty slot; without it, coming back
# seeds the profile from whichever MCM settings are live.
func _t38_leaving_a_profile_without_mcm_records_none(ml: Object) -> void:
	H.pack_cleanup(ml)
	_assert(not DirAccess.dir_exists_absolute(ProjectSettings.globalize_path("user://MCM")), "no live MCM folder")
	ml._snapshot_mcm_to("T38Light")
	_assert(ml._has_mcm_snapshot("T38Light"), "the profile has a snapshot slot")
	H.write_text("user://MCM/heavy-mod/config.ini", "[a]\nv=heavy\n")
	_assert(ml._restore_mcm_from("T38Light") and not FileAccess.file_exists("user://MCM/heavy-mod/config.ini"),
			"coming back restores no MCM settings")
	H.pack_cleanup(ml)

# The pairing asks only about installs an unmatched pack mod could name; an
# unavailable pack mod has no source and its key still finds an installed copy.
func _t39_pairing_asks_little_and_covers_unavailable_mods(ml: Object) -> void:
	H.pack_cleanup(ml)
	var uuid := "019ff1f0-00ac-76a9-a23f-7151e4531131"
	var foo := H.mod_entry("foo@2.0", "foo", "2.0", {"cfg": _source_cfg("vostokmods:" + uuid, "2.0")})
	_install(ml, [foo, H.mod_entry("bar@1.0", "bar", "1.0")])
	ml.set("_active_profile", "Default")
	_seed(ml, [["settings", "active_profile", "Default"],
			["mod_sources", "bar@1.0", ml._serialize_mod_source_rec({"provider": "vostokmods", "id": "bar", "version": "1.0"})]])
	var aliases: Dictionary = ml.get("_host_ref_aliases")
	aliases.clear()
	(ml.get("_mods_meta_by_key") as Dictionary).clear()
	var entry := _pack_write(ml, {"metroprofile": 1, "name": "Round Trip", "enabled": {"vostokmods:bar": true, "vostokmods:qux": true},
			"sources": {"vostokmods:bar": {"provider": "vostokmods", "id": "bar"},
					"vostokmods:qux": {"provider": "vostokmods", "id": "qux"}}}, "1")
	var ask: Array = ml._modpack_unpaired_host_refs(entry)
	_assert(ask.size() == 1 and str(ml.host_ref_key(ask[0])) == "vostokmods:" + uuid,
			"only the UUID install is asked about: %s" % str(ask))
	entry = _pack_write(ml, {"metroprofile": 1, "name": "Round Trip", "enabled": {"vostokmods:foo": true},
			"unavailable": {"vostokmods:foo": "scanning"}}, "1")
	var missing: Array = ml._get_missing_mods_for_modpack(entry)
	check_eq(missing.size(), 1, "unpaired unavailable mods missing")
	var item: Dictionary = missing[0] if missing.size() == 1 else {}
	var src: Dictionary = item.get("source", {})
	_assert(item.get("unreachable", false) and item.get("ref", {}).is_empty() and str(src.get("provider", "")) == "vostokmods"
			and str(src.get("id", "")) == "foo" and str(src.get("version", "")) == "",
			"the unavailable item names its key's mod: %s" % str(item))
	ml._vmp_note_ids({"id": uuid, "slug": "foo"})
	_assert(ml._get_missing_mods_for_modpack(entry).is_empty(), "paired, the unavailable key finds the copy")
	foo["enabled"] = false
	var r: Dictionary = await ml.apply_modpack(entry, null, Callable())
	_assert(r["ok"] and _read(ml).has_section_key(_slot(entry), "foo@2.0") and foo["enabled"],
			"the apply keys and enables the copy: %s" % str(r))
	ml.unload_modpack(null)
	aliases.clear()
	H.pack_cleanup(ml)

# A site label can differ from the file's own mod.txt version; the pack's
# checksum is for the exact pinned file, so those bytes are that version.
func _t40_pinned_file_matches_by_checksum(ml: Object) -> void:
	H.pack_cleanup(ml)
	var uuid := "01a108b6-2a9e-75bb-b9ac-43623230bebb"
	var mod_txt := "[mod]\nname=\"Vehicle Doors\"\nid=\"vehicle-doors\"\nversion=\"0.9.0\"\n\n[updates]\nsource=\"vostokmods:" + uuid + "\"\n"
	var vd_path := H.write_zip("user://t40_VehicleDoors.vmz", {"mod.txt": mod_txt}, _report)
	var vd_sha := FileAccess.get_sha256(vd_path)
	var vd := H.mod_entry("vehicle-doors@0.9.0", "vehicle-doors", "0.9.0",
			{"full_path": vd_path, "enabled": false, "cfg": H.cfg_from_text(mod_txt, _report)})
	var installed := _install(ml, [vd])
	ml.set("_active_profile", "Default")
	_seed(ml, [["settings", "active_profile", "Default"]])
	var aliases: Dictionary = ml.get("_host_ref_aliases")
	aliases.clear()
	ml._vmp_note_ids({"id": uuid, "slug": "vehicle-doors"})
	var key := "vostokmods:vehicle-doors"
	var pack := {"metroprofile": 1, "name": "Round Trip", "enabled": {key: true},
			"sources": {key: {"provider": "vostokmods", "id": "vehicle-doors", "version": "1.0.0"}},
			"checksums": {key: "0".repeat(64)}}
	check_eq(ml._get_missing_mods_for_modpack(_pack_write(ml, pack, "1")).size(), 1, "missing with other bytes under the label")
	pack["checksums"][key] = vd_sha
	var entry := _pack_write(ml, pack, "1")
	_assert(ml._get_missing_mods_for_modpack(entry).is_empty(), "the pinned file is installed by checksum")
	var r: Dictionary = await ml.apply_modpack(entry, null, Callable())
	_assert(r["ok"] and r["downloaded"] == 0 and r["failed_downloads"] == 0, "applies without downloading: %s" % str(r))
	var en := _slot(entry)
	var cfg := _read(ml)
	_assert(cfg.has_section_key(en, "vehicle-doors@0.9.0") and not cfg.has_section_key(en, key) and vd["enabled"],
			"the slot keys and enables the install")
	# A slot left keyed by the pack heals at boot.
	cfg.erase_section_key(en, "vehicle-doors@0.9.0")
	cfg.set_value(en, key, true)
	cfg.save(str(ml.UI_CONFIG_PATH))
	check_eq(ml._modpack_reconcile_active(), 1, "stale keys reconciled")
	ml.unload_modpack(null)
	# A mod.txt claiming more than the label is still the pinned file.
	ml.set("_ui_mod_entries", installed)
	vd["version"] = "1.1.0"
	_assert(str(ml._modpack_pin_conflict(entry)).is_empty(), "the pinned file is never a newer copy")
	pack["checksums"][key] = "0".repeat(64)
	_assert(not str(ml._modpack_pin_conflict(_pack_write(ml, pack, "1"))).is_empty(), "another newer file still blocks the pin")
	aliases.clear()
	H.remove_user_file("user://t40_VehicleDoors.vmz")
	H.pack_cleanup(ml)

# The details dialog and the apply ask one question per pack mod; a pinned file
# is hashed only when it would block, and an answered install is not asked again.
func _t41_one_installed_test_and_cheap_pairing(ml: Object) -> void:
	H.pack_cleanup(ml)
	var foo := H.mod_entry("Foo@1.0", "Foo", "1.0")
	var bar := H.mod_entry("bar@2.0", "bar", "2.0", {"cfg": _source_cfg("vostokmods:bar", "2.0")})
	_install(ml, [foo, bar])
	ml.set("_active_profile", "Default")
	_seed(ml, [["settings", "active_profile", "Default"]])
	var aliases: Dictionary = ml.get("_host_ref_aliases")
	aliases.clear()
	var sources := {"vostokmods:qux": {"provider": "vostokmods", "id": "qux"}}
	var index: Dictionary = ml._modpack_installed_index()
	for c in [["foo@1.0", true, "id@version in another case"], ["vostokmods:bar", true, "a sourceless hosted key"],
			["vostokmods:qux", false, "a mod not installed"]]:
		check_eq(bool(ml._modpack_key_installed(c[0], sources, {}, index)), c[1], c[2] + " installed")
	var missing: Array = ml._get_missing_mods_for_modpack(_pack_write(ml, {"metroprofile": 1, "name": "Round Trip",
			"enabled": {"foo@1.0": true, "vostokmods:bar": true, "vostokmods:qux": true}, "sources": sources}, "1"))
	_assert(missing.size() == 1 and str(missing[0]["profile_key"]) == "vostokmods:qux",
			"the apply finds the same one missing: %s" % str(missing))
	var sha_cache: Dictionary = ml.get("_modpack_sha256_cache")
	sha_cache.clear()
	var bar_path := H.write_zip("user://t41_bar.vmz", {"mod.txt": "[mod]\nid=\"bar\"\n"}, _report)
	bar["full_path"] = bar_path
	var pin_pack := {"metroprofile": 1, "name": "Round Trip", "enabled": {"vostokmods:bar": true},
			"sources": {"vostokmods:bar": {"provider": "vostokmods", "id": "bar", "version": "2.0"}},
			"checksums": {"vostokmods:bar": "0".repeat(64)}}
	_assert(str(ml._modpack_pin_conflict(_pack_write(ml, pin_pack, "1"))).is_empty() and sha_cache.is_empty(),
			"a copy at the pin is not hashed")
	bar["version"] = "2.1"
	_assert(not str(ml._modpack_pin_conflict(_pack_write(ml, pin_pack, "1"))).is_empty() and sha_cache.has(bar_path),
			"a newer copy is hashed and blocks")
	bar["version"] = "2.0"
	# A UUID-only install that the pack's slug may name.
	var uuid := "01a108b6-2a9e-75bb-b9ac-43623230be41"
	_install(ml, [foo, bar, H.mod_entry("baz@1.0", "baz", "1.0", {"cfg": _source_cfg("vostokmods:" + uuid)})])
	var asked: Dictionary = ml.get("_modpack_host_ids_asked")
	asked.clear()
	var entry := _pack_write(ml, {"metroprofile": 1, "name": "Round Trip", "enabled": {"vostokmods:baz-slug": true},
			"sources": {"vostokmods:baz-slug": {"provider": "vostokmods", "id": "baz-slug"}}}, "1")
	check_eq(ml._modpack_unpaired_host_refs(entry).size(), 1, "unpaired refs for a UUID-only install")
	# Out of the tree every request fails as offline.
	await ml._modpack_learn_host_ids(entry, false)
	_assert(asked.is_empty() and ml._modpack_unpaired_host_refs(entry).size() == 1, "an ask that never arrived repeats")
	# In the tree a cached detail answers; _has_loaded keeps _ready from booting.
	ml.set("_has_loaded", true)
	root.add_child(ml)
	ml._hnet_cache_put(str(ml.VM_API_BASE) + "/mods/" + uuid.uri_encode(), {"id": uuid, "name": "Baz"}, 60000)
	await ml._modpack_learn_host_ids(entry, false)
	root.remove_child(ml)
	_assert(asked.has("vostokmods:" + uuid) and ml._modpack_unpaired_host_refs(entry).is_empty(),
			"an answered install is not asked again: %s" % str(asked))
	asked.clear()
	(ml.get("_host_cache") as Dictionary).clear()
	aliases.clear()
	H.remove_user_file("user://t41_bar.vmz")
	H.pack_cleanup(ml)

# ConfigFile drops a section once its last key goes, so a profile is listed
# by a marker that outlives its mod keys.
func _t46_profile_outlives_its_last_key(ml: Object) -> void:
	H.pack_cleanup(ml)
	DirAccess.make_dir_recursive_absolute("user://t46_mods")
	var foo := H.mod_entry("foo@1.0", "foo", "1.0", {"full_path": H.write_zip("user://t46_mods/foo.zip",
			{"mod.txt": "[mod]\nid=\"foo\"\nversion=\"1.0\"\n"}, _report)})
	_seed(ml, [["settings", "active_profile", "Test"], ["profile.Default.enabled", "foo@1.0", true],
			["profile.Test.enabled", "foo@1.0", true], ["profile.Test.priority", "foo@1.0", 3]])
	_install(ml, [foo])
	ml.set("_active_profile", "Test")
	_assert(ml._delete_mod_file_and_cleanup(foo), "the delete succeeds")
	var profiles: Array = ml._list_profiles()
	_assert(profiles.has("Test") and profiles.has("Default"), "both profiles outlive their only mod: %s" % str(profiles))
	_install(ml, [])
	ml._load_ui_config()
	check_eq(str(ml.get("_active_profile")), "Test", "active profile after losing its mod")
	ml._create_profile("Empty")
	_assert(ml._list_profiles().has("Empty"), "a profile made with nothing installed is listed")
	# A settings-only pack keeps its slot, so it stays the active pack.
	var r: Dictionary = ml._materialize_modpack_profile(_pack_write(ml, {"metroprofile": 1, "name": "Settings Only", "enabled": {}}, "1"),
			"modpack__Settings Only")
	_assert(r["ok"], "the settings-only pack materializes: %s" % r.get("error"))
	_assert(ml._list_profiles().has("modpack__Settings Only"), "a pack with no mods keeps a slot")
	H.pack_cleanup(ml)

# A hand-dropped copy records no host; a hosted pack keys by slug, which is the
# mod's id, so a copy with that id counts at the pin or by checksum.
func _t50_pack_matches_an_unsourced_copy(ml: Object) -> void:
	H.pack_cleanup(ml)
	var mod_txt := "[mod]\nname=\"Vehicle Doors\"\nid=\"vehicle-doors\"\nversion=\"0.9.0\"\n"
	var vd_path := H.write_zip("user://t50_VehicleDoors.vmz", {"mod.txt": mod_txt}, _report)
	var vd_sha := FileAccess.get_sha256(vd_path)
	var vd := H.mod_entry("vehicle-doors@0.9.0", "vehicle-doors", "0.9.0", {"full_path": vd_path, "cfg": H.cfg_from_text(mod_txt, _report)})
	_install(ml, [vd])
	ml.set("_active_profile", "Default")
	var seed := _seed(ml, [["settings", "active_profile", "Default"]])
	var key := "vostokmods:vehicle-doors"
	var pin := {"provider": "vostokmods", "id": "vehicle-doors", "version": "1.0.0"}
	var pack := {"metroprofile": 1, "name": "Unsourced", "enabled": {key: true}, "sources": {key: pin}, "checksums": {key: vd_sha}}
	var missing := func() -> int:
		return ml._get_missing_mods_for_modpack(_pack_write(ml, pack, "1")).size()
	check_eq(missing.call(), 0, "missing with the pinned file's checksum")
	pack["checksums"][key] = "0".repeat(64)
	check_eq(missing.call(), 1, "missing with another file's checksum")
	pack.erase("checksums")
	pack["sources"] = {key: {"provider": "vostokmods", "id": "vehicle-doors"}}
	check_eq(missing.call(), 0, "missing unpinned with the same id")
	vd["mod_id"] = "doors-of-vehicles"
	check_eq(missing.call(), 1, "missing with a different id")
	vd["mod_id"] = "vehicle-doors"
	vd["version"] = "3.0.0"
	pack["sources"] = {key: {"provider": "vostokmods", "id": "vehicle-doors", "version": "2.0.0"}}
	pack["checksums"] = {key: "0".repeat(64)}
	_assert(not str(ml._modpack_pin_conflict(_pack_write(ml, pack, "1"))).is_empty(), "a newer unsourced copy blocks the pin")
	pack["checksums"][key] = vd_sha
	_assert(str(ml._modpack_pin_conflict(_pack_write(ml, pack, "1"))).is_empty(), "the pinned file never blocks its pin")
	vd["version"] = "0.9.0"
	seed.set_value("profile.modpack__Unsourced.enabled", key, true)
	_save(ml, seed, "seeded the slot")
	var moved: int = ml._modpack_reconcile_profile_keys("modpack__Unsourced", {key: pin}, {key: vd_sha})
	_assert(moved == 1 and _read(ml).has_section_key("profile.modpack__Unsourced.enabled", "vehicle-doors@0.9.0"),
			"the slot is rekeyed onto the copy (moved %d)" % moved)
	# A download that recorded the served version matches that pin unhashed.
	vd["cfg"] = H.cfg_from_text(mod_txt + "\n[updates]\nsource=\"vostokmods:vehicle-doors\"\n", _report)
	seed.set_value("mod_sources", "vehicle-doors@0.9.0", ml._serialize_mod_source_rec(pin))
	_save(ml, seed, "seeded the served version")
	pack.erase("checksums")
	pack["sources"] = {key: pin}
	check_eq(missing.call(), 0, "missing at the served version")
	H.remove_user_file("user://t50_VehicleDoors.vmz")
	H.pack_cleanup(ml)

# The rescan behind every install, update and delete reconciles the active pack.
func _t51_reload_heals_the_active_pack(ml: Object) -> void:
	_pack_setup(ml)
	var previous := _use_mods_dir(ml, "user://t51_mods", true)
	var entry := _pack_write(ml, {"metroprofile": 1, "name": "Heals", "enabled": {"vostokmods:bar": true},
			"sources": {"vostokmods:bar": {"provider": "vostokmods", "id": "bar"}},
			"unavailable": {"vostokmods:bar": "scanning"}}, "1")
	var r: Dictionary = await ml.apply_modpack(entry, null, Callable())
	_assert(r["ok"], "applies with its mod unavailable: %s" % r.get("error"))
	var en := _slot(entry)
	_assert(_read(ml).has_section_key(en, "vostokmods:bar"), "the slot keeps the pack key meanwhile")
	# The mod arrives from Browse and the Mods tab rescans.
	H.write_zip("user://t51_mods/bar.zip", {"mod.txt": "[mod]\nid=\"bar\"\nversion=\"1.0\"\n[updates]\nsource=\"vostokmods:bar\"\n"}, _report)
	ml._reload_entries_for_active_profile()
	var cfg := _read(ml)
	_assert(cfg.has_section_key(en, "bar@1.0") and not cfg.has_section_key(en, "vostokmods:bar"), "the rescan rekeys the slot")
	_assert(_find(ml, "profile_key", "bar@1.0").get("enabled", false), "the pack mod is enabled")
	ml.unload_modpack(null)
	_drop_mods_dir(ml, "user://t51_mods", previous)
	H.pack_cleanup(ml)

# A crash mid-unload leaves the pack slot active with no pack. Recovery lands
# on the profile the pack replaced, or the first user profile with its own MCM.
func _t53_stranded_slot_lands_on_the_backup_profile(ml: Object) -> void:
	H.pack_cleanup(ml)
	_install(ml, [H.mod_entry("a@1.0", "a", "1.0")])
	var seed := _seed(ml, [["settings", "active_profile", "modpack__X"], ["settings", "active_modpack", ""],
			["settings", "modpack_backup_profile", "Main"], ["settings", "modpack_backup_valid", true],
			["profile.Alpha.enabled", "a@1.0", true], ["profile.Main.enabled", "a@1.0", false],
			["profile.modpack__X.enabled", "a@1.0", true]])
	# Main's own snapshot is older than the pre-pack MCM.
	for c in [["_before_modpack_X", "v=pre"], ["Alpha", "v=alpha"], ["Main", "v=main-old"]]:
		ml._write_mcm_snapshot_from_data(c[0], {"some-mod/config.ini": str(c[1]).to_utf8_buffer()})
	H.write_text(LIVE_MCM, "v=pack")
	ml._load_ui_config()
	check_eq(str(ml.get("_active_profile")), "Main", "recovered profile")
	check_eq(FileAccess.get_file_as_string(LIVE_MCM), "v=pre", "live MCM on that profile")
	var cfg := _read(ml)
	check_eq(str(cfg.get_value("settings", "modpack_backup_profile", "x")), "", "backup profile name")
	_assert(not cfg.get_value("settings", "modpack_backup_valid", true), "modpack_backup_valid is cleared")
	seed.set_value("settings", "active_profile", "modpack__X")
	seed.set_value("settings", "modpack_backup_profile", "Gone")
	_save(ml, seed, "reseeded mod_config.cfg")
	ml._write_mcm_snapshot_from_data("_before_modpack_X", {"some-mod/config.ini": "v=pre".to_utf8_buffer()})
	ml._load_ui_config()
	check_eq(str(ml.get("_active_profile")), "Alpha", "profile with the replaced one gone")
	check_eq(FileAccess.get_file_as_string(LIVE_MCM), "v=alpha", "live MCM on Alpha")
	H.pack_cleanup(ml)

# The pack still declares a removed mod; only the player's profiles forget it.
func _t54_remove_with_a_pack_active_keeps_the_slot_key(ml: Object) -> void:
	H.pack_cleanup(ml)
	DirAccess.make_dir_recursive_absolute("user://t54_mods")
	var foo := H.mod_entry("foo@1.0", "foo", "1.0", {"full_path": H.write_zip("user://t54_mods/foo.zip",
			{"mod.txt": "[mod]\nid=\"foo\"\nversion=\"1.0\"\n"}, _report)})
	_seed(ml, [["settings", "active_profile", "modpack__X"], ["settings", "active_modpack", "X"],
			["profile.modpack__X.enabled", "foo@1.0", true], ["profile._before_modpack_X.enabled", "foo@1.0", true],
			["profile.Default.enabled", "foo@1.0", true]])
	_install(ml, [foo])
	ml.set("_active_profile", "modpack__X")
	_assert(ml._delete_mod_file_and_cleanup(foo), "the delete succeeds")
	var cfg := _read(ml)
	_assert(cfg.has_section_key("profile.modpack__X.enabled", "foo@1.0"), "the pack's slot keeps the mod's key")
	_assert(not cfg.has_section_key("profile.Default.enabled", "foo@1.0"), "the player's own profile forgets the mod")
	_assert(not cfg.has_section("profile._before_modpack_X.settings"), "the backup slot gets no marker")
	_assert(not cfg.has_section_key("profile._before_modpack_X.enabled", "foo@1.0"), "the backup slot forgets the mod too")
	ml.set("_active_profile", "Default")
	H.pack_cleanup(ml)

# A pack lacking checksums the manifest offers is rewritten under an unchanged
# hash, even while it is the active pack.
func _t56_hosted_import_regains_checksums(ml: Object) -> void:
	_pack_setup(ml)
	var previous := _use_mods_dir(ml, "user://t56_mods")
	var manifest := {"format": 2, "name": "Old Converter", "slug": "old-converter", "hash": "same",
			"mods": [{"slug": "foo", "version": "2.0", "available": true, "loadOrder": 1, "sha256": "a".repeat(64)}]}
	var imported: Dictionary = ml._hosted_import_manifest(manifest)
	_assert(imported["ok"] and imported["changed"], "the first import writes the pack")
	var path := str(imported["file_path"])
	var same: Dictionary = ml._hosted_import_manifest(manifest)
	_assert(same["ok"] and not same["changed"], "the same manifest is unchanged")
	var active: Dictionary = ml._build_modpack_entry(path)
	var applied: Dictionary = await ml.apply_modpack(active, null, Callable())
	_assert(applied["ok"], "the pack applies: %s" % applied.get("error"))
	var reader := ZIPReader.new()
	_assert(reader.open(path) == OK, "the pack zip opens")
	var pd: Dictionary = JSON.parse_string(reader.read_file("profile.json").get_string_from_utf8())
	reader.close()
	pd.erase("checksums")
	H.remove_user_file(path)
	H.write_zip(path, {"profile.json": JSON.stringify(pd)}, _report)
	_assert(ml._modpack_checksums(ml._build_modpack_entry(path)).is_empty(), "the stripped pack has no checksums")
	var regained: Dictionary = ml._hosted_import_manifest(manifest)
	_assert(regained["ok"] and not regained["changed"], "missing checksums rewrite an unchanged pack: %s" % str(regained))
	_assert(not ml._modpack_checksums(ml._build_modpack_entry(path)).is_empty(), "the rewritten pack has checksums")
	check_eq(str(ml.get_active_modpack()), str(active["sanitized_name"]), "active pack after the rewrite")
	_assert(_read(ml).has_section(_slot(active)), "the kept slot survives the rewrite")
	ml.unload_modpack(null)
	H.remove_user_file(path)
	_drop_mods_dir(ml, "user://t56_mods", previous)
	H.pack_cleanup(ml)

func _t59_legacy_pack_key_matches_an_installed_version(ml: Object) -> void:
	_pack_setup(ml)
	var missing: Array = ml._get_missing_mods_for_modpack(_pack_write(ml, {"metroprofile": 1, "name": "Legacy",
			"enabled": {"foo@1.0": true}}, "1"))
	_assert(missing.is_empty(), "an older version's key is not missing: %s" % str(missing))
	check_eq(ml._get_missing_mods_for_modpack(_pack_write(ml, {"metroprofile": 1, "name": "Legacy2",
			"enabled": {"bar@1.0": true}}, "1")).size(), 1, "missing for a mod never installed")
	H.pack_cleanup(ml)

func _t61_new_profile_flushes_the_priority_debounce(ml: Object) -> void:
	H.pack_cleanup(ml)
	_install(ml, [H.mod_entry("a@1.0", "a", "1.0", {"priority": 7})])
	ml.set("_active_profile", "Default")
	_seed(ml, [["settings", "active_profile", "Default"], ["profile.Default.enabled", "a@1.0", true]])
	ml.set("_priority_save_pending", true)
	ml._create_profile("Copy")
	check_eq(_read(ml).get_value("profile.Default.priority", "a@1.0", 0), 7, "pending priority saved under its profile")
	_assert(not ml.get("_priority_save_pending"), "the debounce is flushed")
	ml.set("_priority_save_pending", true)
	ml._delete_active_profile()
	_assert(not ml.get("_priority_save_pending"), "a delete drops the pending edit")
	check_eq(str(ml.get("_active_profile")), "Default", "profile after the delete")
	ml.set("_active_profile", "Default")
	H.pack_cleanup(ml)

func _t62_profile_names_have_no_trailing_space(ml: Object) -> void:
	for c in [["Best Mods Ever !", "Best Mods Ever"], ["  Solo  ", "Solo"]]:
		check_eq(str(ml._sanitize_profile_name(c[0])), c[1], "sanitized '%s'" % c[0])

func _t65_reopened_launcher_restarts_only_when_the_loaded_set_changed(ml: Object) -> void:
	H.pack_cleanup(ml)
	var a := H.mod_entry("a@1.0", "a", "1.0")
	var b := H.mod_entry("b@1.0", "b", "1.0", {"enabled": false})
	_install(ml, [a, b])
	ml.set("_active_profile", "Default")
	var seed := _seed(ml, [["settings", "active_profile", "Default"]])
	ml.set("_boot_complete", true)
	ml.set("_booted_set_signature", str(ml._loaded_set_signature()))
	# Only what loads decides, not a saved edit by itself.
	ml._save_ui_config()
	for c in [["an unchanged session", [], false], ["enabling a mod", [[b, "enabled", true]], true],
			["a priority change", [[b, "enabled", false], [a, "priority", 3]], true],
			["reverted edits", [[a, "priority", 0]], false], ["a rescan enabling a mod", [[b, "enabled", true]], true],
			["the booted set again", [[b, "enabled", false]], false]]:
		for edit in c[1]:
			edit[0][edit[1]] = edit[2]
		check_eq(bool(ml._post_boot_restart_needed()), c[2], c[0] + " needs a restart")
	seed.set_value("settings", "mcm_pending_to", "B")
	_save(ml, seed, "reseeded with a pending MCM swap")
	_assert(ml._post_boot_restart_needed(), "a pending profile switch needs the restart")
	seed.erase_section_key("settings", "mcm_pending_to")
	_save(ml, seed, "reseeded without it")
	_assert(not ml._post_boot_restart_needed(), "without the swap no restart")
	ml.set("_boot_complete", false)
	H.pack_cleanup(ml)

# Mods write their MCM files while the game runs (some on exit), so a
# post-boot switch swaps user://MCM at the next launch, not under them.
func _t66_post_boot_profile_switch_defers_the_mcm_swap(ml: Object) -> void:
	_ab_profiles(ml)
	ml._switch_profile("B")
	check_eq(FileAccess.get_file_as_string(LIVE_M), "A", "live MCM while the game runs")
	check_eq(str(_read(ml).get_value("settings", "active_profile", "")), "B", "saved active profile")
	_assert(ml._mcm_switch_pending(), "the swap is recorded as pending")
	ml._switch_profile("A")
	_assert(not ml._mcm_switch_pending(), "switching back cancels the pending swap")
	ml._switch_profile("B")
	_assert(ml._mcm_switch_pending(), "switching away again records it")
	ml.set("_boot_complete", false)
	ml._complete_pending_mcm_switch()
	check_eq(FileAccess.get_file_as_string(LIVE_M), "B", "live MCM after the restart")
	check_eq(FileAccess.get_file_as_string(SNAP + "A/MCM/m/config.ini"), "A", "the outgoing profile's snapshot")
	_assert(not ml._mcm_switch_pending(), "the pending record is cleared")
	# Before boot (the Pass 1 launcher) the swap is immediate.
	ml._switch_profile("A")
	check_eq(FileAccess.get_file_as_string(LIVE_M), "A", "live MCM after a pre-boot switch")
	_assert(not ml._mcm_switch_pending(), "a pre-boot switch records nothing")
	ml.set("_active_profile", "Default")
	H.pack_cleanup(ml)

func _t69_escaped_dialogs_are_freed(ml: Object) -> void:
	var d := AcceptDialog.new()
	ml._wire_accept_dismiss(d)
	d.canceled.emit()
	_assert(d.is_queued_for_deletion(), "a dialog closed with ESC is freed")

# Hosted pack files are per slug, so two packs called "Hardcore" keep their
# own slots and a Refresh of one leaves the other's alone.
func _t70_hosted_packs_with_one_name_keep_their_own_slots(ml: Object) -> void:
	_pack_setup(ml)
	var previous := _use_mods_dir(ml, "user://t70_mods")
	var path_a := str(ml._hosted_pack_file_path("hardcore-a"))
	for slug in ["hardcore-a", "hardcore-b"]:
		H.write_zip(str(ml._hosted_pack_file_path(slug)), {"profile.json": JSON.stringify({"metroprofile": 1, "name": "Hardcore",
				"enabled": {"a@1.0": true}, "hosted": {"slug": slug, "hash": "h" + slug.right(1)}})}, _report)
	var packs: Array = ml.collect_modpack_metadata()
	check_eq(packs.size(), 2, "packs listed")
	var names := {}
	var slot_a := ""
	for p: Dictionary in packs:
		names[str(p["sanitized_name"])] = true
		_assert(p.get("duplicates_hidden", []).is_empty(), "neither pack hides the other")
		if str(p["file_path"]) == path_a:
			slot_a = str(p["sanitized_name"])
	check_eq(names.size(), 2, "distinct slot names")
	_assert(names.has("Hardcore"), "one keeps the plain name: %s" % str(names.keys()))
	var seed := _read(ml)
	seed.set_value("profile.modpack__" + slot_a + ".enabled", "a@1.0", true)
	_save(ml, seed, "seeded A's kept slot")
	var imported: Dictionary = ml._hosted_import_manifest({"format": 2, "name": "Hardcore", "slug": "hardcore-b", "hash": "hb2",
			"mods": [{"slug": "a", "version": "1.0", "available": true, "loadOrder": 1}]})
	_assert(imported["ok"] and imported["changed"], "B's changed manifest imports: %s" % str(imported))
	_assert(_read(ml).has_section("profile.modpack__" + slot_a + ".enabled"), "A's kept slot survives B's refresh")
	_drop_mods_dir(ml, "user://t70_mods", previous)
	H.pack_cleanup(ml)

# The reopened launcher rescans; the rescan saves nothing, and closing
# restarts when what loads now differs from what boot loaded.
func _t71_reopen_rescans_and_restarts_on_the_loaded_set(ml: Object) -> void:
	H.pack_cleanup(ml)
	var previous := _use_mods_dir(ml, "user://t71_mods")
	H.write_zip("user://t71_mods/q.zip", {"mod.txt": "[mod]\nid=\"q\"\nversion=\"1.0\"\n"}, _report)
	_seed(ml, [["settings", "active_profile", "Default"]])
	ml.set("_active_profile", "Default")
	ml.set("_boot_complete", true)
	_install(ml, [])
	ml.set("_booted_set_signature", str(ml._loaded_set_signature()))
	var cfg_before := FileAccess.get_file_as_string(str(ml.UI_CONFIG_PATH))
	ml._reload_entries_for_active_profile()
	_assert(not _find(ml, "mod_id", "q").is_empty(), "the rescan lists the dropped-in archive")
	_assert(FileAccess.get_file_as_string(str(ml.UI_CONFIG_PATH)) == cfg_before, "the rescan alone saves nothing")
	_assert(ml._post_boot_restart_needed(), "the new archive loads, so closing restarts")
	ml.set("_boot_complete", false)
	_drop_mods_dir(ml, "user://t71_mods", previous)
	H.pack_cleanup(ml)

# After boot an unload leaves user://MCM alone: restoring the backup now would
# put the player's settings under the pack's mods. The restart swaps.
func _t72_post_boot_unload_keeps_the_pack_mcm(ml: Object) -> void:
	_pack_setup(ml)
	var entry := _pack_write(ml, {"metroprofile": 1, "name": "Late", "enabled": {"a@1.0": true}}, "pack")
	H.write_text(LIVE_MCM, "[a]\nv=mine\n")
	var r: Dictionary = await ml.apply_modpack(entry, null, Callable())
	_assert(r["ok"], "the pack applies before boot: %s" % r.get("error"))
	check_eq(FileAccess.get_file_as_string(LIVE_MCM), "[a]\nv=pack\n", "live MCM after a pre-boot apply")
	# The game runs with the pack; the player edits a pack setting in game.
	H.write_text(LIVE_MCM, "[a]\nv=pack-edited\n")
	ml.set("_boot_complete", true)
	ml.unload_modpack(null)
	check_eq(FileAccess.get_file_as_string(LIVE_MCM), "[a]\nv=pack-edited\n", "live MCM after a post-boot unload")
	check_eq(str(ml.get_active_modpack()), "", "active pack after unload")
	_assert(ml._mcm_switch_pending(), "the swap waits for the restart")
	ml.set("_boot_complete", false)
	ml._complete_pending_mcm_switch()
	check_eq(FileAccess.get_file_as_string(LIVE_MCM), "[a]\nv=mine\n", "live MCM after the restart")
	check_eq(FileAccess.get_file_as_string(SNAP + "modpack__Late/MCM/some-mod/config.ini"), "[a]\nv=pack-edited\n",
			"the pack slot's MCM")
	H.pack_cleanup(ml)

func _t73_post_boot_profile_edits_follow_the_pending_swap(ml: Object) -> void:
	_ab_profiles(ml)
	ml._switch_profile("B")
	# B's MCM is not live yet, so a profile made from B copies B's snapshot.
	ml._create_profile("N")
	check_eq(FileAccess.get_file_as_string(SNAP + "N/MCM/m/config.ini"), "B", "N's MCM, copied from B")
	check_eq(FileAccess.get_file_as_string(SNAP + "B/MCM/m/config.ini"), "B", "B's snapshot")
	check_eq(FileAccess.get_file_as_string(LIVE_M), "A", "live MCM")
	check_eq(_pending(ml), ["A", "N"], "pending swap from, to")
	ml._rename_profile("N2")
	check_eq(_pending(ml)[1], "N2", "pending target after the rename")
	check_eq(FileAccess.get_file_as_string(SNAP + "N2/MCM/m/config.ini"), "B", "snapshot after the rename")
	# The delete lands on A, whose MCM is live: nothing is left to swap.
	ml._delete_active_profile()
	check_eq(str(ml.get("_active_profile")), "A", "profile after the delete")
	_assert(not ml._mcm_switch_pending(), "landing on the live owner cancels the swap")
	check_eq(FileAccess.get_file_as_string(LIVE_M), "A", "live MCM after the delete")
	# Deleting the live owner leaves nothing to snapshot at the restart.
	ml._switch_profile("B")
	_assert(ml._mcm_switch_pending(), "A -> B is pending again")
	ml.set("_active_profile", "A")
	ml._delete_active_profile()
	var pending := _pending(ml)
	check_eq(pending[0], "", "pending source after deleting it")
	check_eq(pending[1], str(ml.get("_active_profile")), "pending target after the delete")
	ml.set("_boot_complete", false)
	ml.set("_active_profile", "Default")
	H.pack_cleanup(ml)

# After a post-boot switch to B the live MCM is still Default's, so an apply
# backs up B's snapshot.
func _t74_post_boot_apply_backs_up_the_right_mcm(ml: Object) -> void:
	_pack_setup(ml)
	H.write_text(LIVE_MCM, "[a]\nv=A\n")
	H.write_text(SNAP + "B/MCM/some-mod/config.ini", "[a]\nv=B\n")
	var seed := _read(ml)
	seed.set_value("profile.B.enabled", "a@1.0", true)
	_save(ml, seed, "seeded profile B")
	ml.set("_boot_complete", true)
	ml._switch_profile("B")
	var r: Dictionary = await ml.apply_modpack(_pack_write(ml, {"metroprofile": 1, "name": "Over", "enabled": {"a@1.0": true}}, "pack"),
			null, Callable())
	_assert(r["ok"], "the pack applies after boot: %s" % r.get("error"))
	check_eq(FileAccess.get_file_as_string(LIVE_MCM), "[a]\nv=A\n", "live MCM after a post-boot apply")
	check_eq(FileAccess.get_file_as_string(SNAP + "_before_modpack_Over/MCM/some-mod/config.ini"), "[a]\nv=B\n",
			"backup of the replaced profile")
	check_eq(_pending(ml), ["Default", "modpack__Over"], "pending swap from, to")
	ml.set("_boot_complete", false)
	ml._complete_pending_mcm_switch()
	check_eq(FileAccess.get_file_as_string(LIVE_MCM), "[a]\nv=pack\n", "live MCM after the restart")
	check_eq(FileAccess.get_file_as_string(SNAP + "Default/MCM/some-mod/config.ini"), "[a]\nv=A\n", "the live owner's slot")
	ml.unload_modpack(null)
	H.pack_cleanup(ml)

# Rename carries the MCM snapshot; Remove and Remove all strip missing keys
# from the active profile's three sections only.
func _t77_rename_moves_the_slot_and_missing_rows_go(ml: Object) -> void:
	H.pack_cleanup(ml)
	_install(ml, [H.mod_entry("a@1.0", "a", "1.0")])
	ml.set("_active_profile", "Old")
	var rows := [["settings", "active_profile", "Old"], ["profile.Old.enabled", "a@1.0", true]]
	for k in ["gone@1.0", "lost@2.0", "zip:Away.zip"]:
		rows += [["profile.Old.enabled", k, true], ["profile.Old.priority", k, 2], ["profile.Old.dep_ignore", k, true]]
	_seed(ml, rows + [["profile.Other.enabled", "gone@1.0", true]])
	ml._write_mcm_snapshot_from_data("Old", {"m/config.ini": "v=old".to_utf8_buffer()})
	ml._rename_profile("New")
	check_eq(FileAccess.get_file_as_string(SNAP + "New/MCM/m/config.ini"), "v=old", "snapshot under the new name")
	_assert(not DirAccess.dir_exists_absolute(ProjectSettings.globalize_path(SNAP + "Old")), "no snapshot slot under the old name")
	check_eq(ml._missing_mods_in_active_profile(), ["gone@1.0", "lost@2.0", "zip:Away.zip"], "missing keys after the rename")
	ml._remove_missing_entries_from_profile(["gone@1.0"])
	var cfg := _read(ml)
	for suffix in [".enabled", ".priority", ".dep_ignore"]:
		_assert(not cfg.has_section_key("profile.New" + suffix, "gone@1.0"), "Remove strips the key from " + suffix)
		_assert(cfg.has_section_key("profile.New" + suffix, "lost@2.0"), "Remove leaves other missing keys in " + suffix)
	ml._remove_missing_entries_from_profile(ml._missing_mods_in_active_profile())
	cfg = _read(ml)
	for suffix in [".enabled", ".priority", ".dep_ignore"]:
		_assert(not cfg.has_section_key("profile.New" + suffix, "lost@2.0")
				and not cfg.has_section_key("profile.New" + suffix, "zip:Away.zip"), "Remove all strips every missing key: " + suffix)
	_assert(ml._missing_mods_in_active_profile().is_empty(), "no missing row is left")
	_assert(cfg.get_value("profile.New.enabled", "a@1.0", false), "the installed mod's key stays")
	_assert(cfg.has_section_key("profile.Other.enabled", "gone@1.0"), "other profiles keep their keys")
	ml.set("_active_profile", "Default")
	H.pack_cleanup(ml)

## A pack whose every mod is missing and named by its Vostok Mods slug.
func _stub_pack(stub: Object, name: String, slugs: Array, extra_enabled: Array = []) -> Dictionary:
	var enabled := {}
	var sources := {}
	for slug in slugs:
		enabled["vostokmods:" + str(slug)] = true
		sources["vostokmods:" + str(slug)] = {"provider": "vostokmods", "id": str(slug)}
	for key in extra_enabled:
		enabled[str(key)] = true
	return _pack_write(stub, {"metroprofile": 1, "name": name, "enabled": enabled, "sources": sources}, "1")

func _stub_reset(stub: Object, mods_abs: String) -> void:
	H.pack_cleanup(stub)
	stub._remove_tree(mods_abs, false)
	DirAccess.make_dir_recursive_absolute(mods_abs)
	stub.set("_active_profile", "Default")
	stub.set("_modpack_apply_cancelled", false)
	stub.calls.clear()
	_seed(stub, [["settings", "active_profile", "Default"]])

func _stub_keys(rows: Array) -> Array:
	var keys := []
	for row: Dictionary in rows:
		keys.append(str(row["profile_key"]))
	keys.sort()
	return keys

func _failure_rows(stub: Object, slugs: Array) -> Array:
	var rows: Array = []
	for slug in slugs:
		rows.append(stub._modpack_failure_row("vostokmods:" + slug, "earlier", {"provider": "vostokmods", "id": slug}, "", ""))
	return rows

func _t78_pack_downloads_through_a_stub(_ml: Object) -> void:
	var stub: Object = load("res://stub_loader.gd").new()
	stub._compile_regex()
	var fixtures := ProjectSettings.globalize_path("user://t78_fixtures")
	var mods_abs := ProjectSettings.globalize_path("user://t78_mods")
	DirAccess.make_dir_recursive_absolute(fixtures)
	for id in ["ok-a", "ok-d", "cancel-g", "ok-h", "cancel-i", "cancel-j", "ok-k"]:
		H.write_zip("user://t78_fixtures/" + id + ".zip",
				{"mod.txt": "[mod]\nid=\"%s\"\nversion=\"1.0\"\n[updates]\nsource=\"vostokmods:%s\"\n" % [id, id]}, _report)
	stub.fixture_dir = fixtures
	stub.set("_mods_dir", mods_abs)
	var events: Array = []
	var progress := func(info: Dictionary) -> void:
		events.append(str(info.get("action", "")))

	# One apply meets a download, a failure, a mod on disk under both names and
	# a mod the pack names no source for.
	_stub_reset(stub, mods_abs)
	var r: Dictionary = await stub.apply_modpack(_stub_pack(stub, "Stubbed", ["ok-a", "fail-b", "have-c"], ["nosrc@1.0"]), null, progress)
	_assert(r["ok"], "applies with some downloads failed: %s" % r.get("error"))
	check_eq(stub.calls, ["fail-b", "have-c", "ok-a"], "downloads, once each in key order")
	check_eq(r["downloaded"], 2, "downloaded: a download and an 'Already have'")
	check_eq(r["failed_downloads"], 2, "failed: a download and a sourceless mod")
	check_eq(_stub_keys(r["failures"]), ["nosrc@1.0", "vostokmods:fail-b"], "failure row keys")
	for row: Dictionary in r["failures"]:
		_assert(row.has("ref") and row.has("version") and row.has("sha256") and str(row.get("error", "")) != "",
				"a failure row carries what retry reads: %s" % str(row))
		if row["profile_key"] == "vostokmods:fail-b":
			check_eq(str(row["error"]), "Download failed (HTTP 500)", "fail-b row error")
	check_eq(events, ["skipped", "downloading", "downloading", "downloading", "applying"], "progress actions")
	check_eq(str(stub._modpack_apply_outcome(r)), "partial", "apply outcome")
	_assert(FileAccess.file_exists(mods_abs.path_join("ok-a.zip")), "the downloaded archive is in mods/")
	var cfg := _read(stub)
	_assert(cfg.has_section_key("profile.modpack__Stubbed.enabled", "ok-a@1.0")
			and not cfg.has_section_key("profile.modpack__Stubbed.enabled", "vostokmods:ok-a"), "the slot keys the download by its install")
	check_eq(str(stub.get_active_modpack()), "Stubbed", "active pack")
	stub.unload_modpack(null)

	# Retry, unlike the apply, keeps an 'Already have' in its failures; its
	# rescan takes the new mod in.
	stub.calls.clear()
	events.clear()
	var rows := _failure_rows(stub, ["ok-d", "fail-e", "have-f"])
	rows.append(stub._modpack_failure_row("nosrc@1.0", "no source", {}, "", ""))
	var rr: Dictionary = await stub.retry_failed_downloads(rows, progress)
	check_eq(stub.calls, ["ok-d", "fail-e", "have-f"], "retry downloads, once each")
	_assert(rr["downloaded"] == 1 and not rr["cancelled"], "retry counts its one download: %s" % str(rr))
	check_eq(_stub_keys(rr["failures"]), ["nosrc@1.0", "vostokmods:fail-e", "vostokmods:have-f"], "rows still failing")
	check_eq(events, ["retrying", "retrying", "retrying"], "retry progress actions")
	_assert(not _find(stub, "mod_id", "ok-d").is_empty(), "retry rescans, so the mod is listed")
	stub.set("_modpack_apply_in_progress", true)
	stub.calls.clear()
	var busy: Dictionary = await stub.retry_failed_downloads(rows, progress)
	stub.set("_modpack_apply_in_progress", false)
	_assert(stub.calls.is_empty() and busy["downloaded"] == 0 and busy["failures"].size() == rows.size(),
			"a retry during an apply hands rows back")

	# Cancel mid-apply: nothing after it is fetched and no profile state changes.
	_stub_reset(stub, mods_abs)
	r = await stub.apply_modpack(_stub_pack(stub, "Cancelled", ["cancel-g", "ok-h"]), null, Callable())
	_assert(r["cancelled"] and not r["ok"], "a cancel mid-apply returns cancelled: %s" % str(r))
	_assert(str(r["error"]).contains("1 of 2"), "the cancel says how far it got: %s" % r["error"])
	_assert(r["downloaded"] == 1 and r["failed_downloads"] == 0, "the cancel carries the counts so far")
	check_eq(stub.calls, ["cancel-g"], "downloads up to the cancel")
	_assert(not _find(stub, "mod_id", "cancel-g").is_empty(), "the download before the cancel is taken in")
	cfg = _read(stub)
	_assert(str(cfg.get_value("settings", "active_modpack", "")) == "" and str(stub.get("_active_profile")) == "Default"
			and not cfg.has_section("profile._before_modpack_Cancelled.enabled"), "a cancelled apply changes no profile state")
	check_eq(str(stub._modpack_apply_outcome(r)), "cancelled", "apply outcome")

	# A cancel during the last download is caught after the loop.
	_stub_reset(stub, mods_abs)
	r = await stub.apply_modpack(_stub_pack(stub, "Last", ["cancel-i"]), null, Callable())
	_assert(r["cancelled"] and str(r["error"]).contains("after downloading 1 mod(s)"), "a last-download cancel stops first: %s" % str(r))
	check_eq(str(_read(stub).get_value("settings", "active_modpack", "")), "", "active pack after the cancel")

	# A cancel during a retry leaves the rows after it failed; the next Retry
	# starts afresh.
	_stub_reset(stub, mods_abs)
	rr = await stub.retry_failed_downloads(_failure_rows(stub, ["cancel-j", "ok-k"]), Callable())
	_assert(rr["cancelled"] and rr["downloaded"] == 1, "a cancelled retry keeps its download: %s" % str(rr))
	_assert(_stub_keys(rr["failures"]) == ["vostokmods:ok-k"] and stub.calls == ["cancel-j"],
			"rows after the cancel stay failed: %s" % str(_stub_keys(rr["failures"])))
	stub.calls.clear()
	rr = await stub.retry_failed_downloads(rr["failures"], Callable())
	_assert(stub.calls == ["ok-k"] and rr["downloaded"] == 1 and not rr["cancelled"], "a retry clears the last cancel: %s" % str(rr))

	stub.set("_modpack_apply_cancelled", false)
	H.pack_cleanup(stub)
	stub._remove_tree(mods_abs, false)
	stub._remove_tree(fixtures, false)
	stub.free()

# The live file is unreadable and its .bak records a post-boot switch A -> B:
# the recovery swaps before any mod runs and keeps no pending record.
func _t79_pending_swap_in_the_backup_completes(ml: Object) -> void:
	H.pack_cleanup(ml)
	H.write_text(LIVE_M, "A")
	H.write_text(SNAP + "B/MCM/m/config.ini", "B")
	var cfg_path := str(ml.UI_CONFIG_PATH)
	_seed(ml, [["settings", "active_profile", "B"], ["settings", "mcm_pending_from", "A"], ["settings", "mcm_pending_to", "B"],
			["settings", "active_modpack", "Gone"], ["profile.A.enabled", "a@1.0", true], ["profile.B.enabled", "a@1.0", false]], ".bak")
	H.write_text(cfg_path, "[settings\nnot a config file")
	_install(ml, [H.mod_entry("a@1.0", "a", "1.0")])
	ml.set("_boot_complete", false)
	ml._load_ui_config()
	check_eq(str(ml.get("_active_profile")), "B", "recovered active profile")
	check_eq(FileAccess.get_file_as_string(LIVE_M), "B", "live MCM after the recovery")
	check_eq(FileAccess.get_file_as_string(SNAP + "A/MCM/m/config.ini"), "A", "A's snapshot")
	_assert(FileAccess.file_exists(cfg_path + ".corrupt"), "the unreadable file is kept as .corrupt")
	var after := ConfigFile.new()
	_assert(after.load(cfg_path) == OK, "the recovered config is readable")
	check_eq(str(after.get_value("settings", "active_modpack", "x")), "", "active_modpack after the same load")
	_assert(not after.has_section_key("settings", "mcm_pending_from") and not after.has_section_key("settings", "mcm_pending_to"),
			"the rewrite keeps no pending record")
	H.remove_user_file(cfg_path + ".corrupt")
	ml.set("_active_profile", "Default")
	H.pack_cleanup(ml)

# With only the .bak left, a single-key write continues from its contents.
func _t80_write_without_the_live_file_keeps_the_backup(ml: Object) -> void:
	H.pack_cleanup(ml)
	var cfg_path := str(ml.UI_CONFIG_PATH)
	_seed(ml, [["settings", "active_profile", "A"], ["profile.A.enabled", "a@1.0", true], ["profile.B.enabled", "a@1.0", false]], ".bak")
	_assert(not FileAccess.file_exists(cfg_path), "the live file is missing")
	ml._set_ui_cfg_value("settings", "t80_key", 7)
	var after := ConfigFile.new()
	_assert(after.load(cfg_path) == OK, "the write recreates the live file")
	_assert(after.has_section("profile.A.enabled") and after.has_section("profile.B.enabled"),
			"both backup profiles are kept: %s" % str(after.get_sections()))
	check_eq(str(after.get_value("settings", "active_profile", "")), "A", "active profile from the backup")
	check_eq(after.get_value("settings", "t80_key", 0), 7, "the new value")
	ml._set_ui_cfg_value("settings", "t80_key", 8)
	var rolled := ConfigFile.new()
	_assert(rolled.load(cfg_path + ".bak") == OK and rolled.has_section("profile.A.enabled")
			and rolled.has_section("profile.B.enabled"), "the next .bak still holds both profiles")
	H.pack_cleanup(ml)

## A site manifest for slug with an mcmConfig and extra top-level keys.
func _site_manifest(slug: String, mcm: Dictionary = {}, extra: Dictionary = {}) -> Dictionary:
	var m := {"format": 2, "slug": slug, "name": slug.capitalize(), "hash": "h1",
			"mods": [{"slug": "foo", "version": "2.0", "available": true, "loadOrder": 1}], "mcmConfig": mcm}
	m.merge(extra, true)
	return m

func _t81_pack_mcm_limits(ml: Object) -> void:
	_pack_setup(ml)
	ml._remove_tree("user://t81_mods", false)
	var previous := _use_mods_dir(ml, "user://t81_mods")
	var many := {}
	for i in 33:
		many["m%d/config.ini" % i] = "[a]\nv=1\n"
	var export := "[x]\nImportModData={}\n"
	for i in 33:
		export += "[mod%d]\nv={\"value\": 1, \"import_data\": {\"section\": \"S\"}}\n" % i
	var full := {}
	for i in 31:
		full["m%d/config.json" % i] = "{}"
	full["big/config.cfg"] = "x".repeat(65536)
	for c in [
		["33 files", many, "more than 32 mod settings files"],
		["an export of 33 mods", {"export.ini": export}, "more than 32 mod settings files"],
		["a file over 64 KiB", {"m/config.ini": "x".repeat(65537)}, "m/config.ini is over 64 KiB"],
	]:
		var r: Dictionary = ml._hosted_import_manifest(_site_manifest("t81-limit", c[1]))
		_assert(not r["ok"] and str(r["error"]).contains(c[2]) and str(r["error"]).ends_with("so it was not imported."),
				"%s fails the import: %s" % [c[0], r["error"]])
		_assert(not FileAccess.file_exists(str(ml._hosted_pack_file_path("t81-limit"))), c[0] + ": no pack written")
	var r: Dictionary = ml._hosted_import_manifest(_site_manifest("t81-full", full))
	_assert(r["ok"], "32 files, one at 64 KiB, import: %s" % r["error"])
	var odd := {"../evil.ini": "[x]\n", "/root.ini": "[x]\n", "m/notes.txt": "x", "m/": "x", "": "x",
			"c:/config.ini": "[x]\n", "ok/config.ini": "[x]\n"}
	r = ml._hosted_import_manifest(_site_manifest("t81-odd", odd))
	var warnings: PackedStringArray = r.get("warnings", PackedStringArray())
	_assert(r["ok"] and warnings.size() == 6, "odd keys skip with a warning: %s" % str(warnings))
	for w in warnings:
		_assert(not w.contains("  "), "a warning names its key: " + w)
	var zip := ZIPReader.new()
	_assert(zip.open(str(r["file_path"])) == OK, "the odd pack is written")
	check_eq(Array(zip.get_files()).filter(func(f: String) -> bool: return f.begins_with("MCM/")), ["MCM/ok/config.ini"],
			"only the safe file is packed")
	zip.close()
	_drop_mods_dir(ml, "user://t81_mods", previous)
	H.pack_cleanup(ml)

func _t82_hosted_record_keeps_the_cover(ml: Object) -> void:
	_pack_setup(ml)
	ml._remove_tree("user://t82_mods", false)
	var previous := _use_mods_dir(ml, "user://t82_mods")
	var cover := "https://vostokmods.net/thumbs/t82.png"
	var url := str(ml._vmp_modpack_manifest_url("t82-cover"))
	for c in [["t82-cover", {"thumbnailUrl": cover, "manifest_url": url}, cover], ["t82-bare", {"thumbnailUrl": null}, ""]]:
		var r: Dictionary = ml._hosted_import_manifest(_site_manifest(c[0], {}, c[1]))
		_assert(r["ok"], "%s imports: %s" % [c[0], r["error"]])
		var hosted: Dictionary = ml._build_modpack_entry(str(r["file_path"]))["hosted"]
		var keys: Array = hosted.keys()
		keys.sort()
		check_eq(keys, ["format", "hash", "manifest_url", "provider", "slug", "thumbnail_url", "url"], c[0] + " hosted keys")
		_assert(str(hosted["thumbnail_url"]) == c[2] and str(hosted["slug"]) == c[0] and str(hosted["hash"]) == "h1"
				and int(hosted["format"]) == 2, "%s hosted record: %s" % [c[0], str(hosted)])
	var listed := {}
	for e: Dictionary in ml.collect_modpack_metadata():
		listed[str(e["hosted"]["slug"])] = str(e["thumbnail_url"])
	check_eq(listed, {"t82-cover": cover, "t82-bare": ""}, "covers on the listed packs")
	var old: Dictionary = ml._build_modpack_entry(H.write_zip("user://t82_mods/old.zip", {"profile.json": JSON.stringify(
			{"metroprofile": 1, "name": "Old", "enabled": {}, "hosted": {"provider": "vostokmods", "slug": "old"}})}, _report))
	check_eq(str(old["thumbnail_url"]), "", "an older pack's cover")
	var plain: Dictionary = ml._hosted_import_manifest(_site_manifest("t82-http", {}, {"thumbnailUrl": "http://x/c.png"}))
	check_eq(str(ml._build_modpack_entry(str(plain["file_path"]))["thumbnail_url"]), "", "an http cover is not kept")
	var caps: Dictionary = ml._hosted_import_manifest(_site_manifest("t82-caps", {}, {"thumbnailUrl": "HTTPS://x/c.png"}))
	check_eq(str(ml._build_modpack_entry(str(caps["file_path"]))["thumbnail_url"]), "HTTPS://x/c.png",
			"an upper-case https cover is kept")
	var edited := {"metroprofile": 1, "name": "Kept Name", "enabled": {"vostokmods:foo": false}, "priority": {"vostokmods:foo": 7},
			"hosted": {"provider": "vostokmods", "slug": "t82-old", "hash": "h1"}}
	var old_path := H.write_zip(str(ml._hosted_pack_file_path("t82-old")), {"profile.json": JSON.stringify(edited),
			"MCM/m/config.ini": "[a]\nv=9\n"}, _report)
	for pass_name in ["backfill", "again"]:
		var back: Dictionary = ml._hosted_import_manifest(_site_manifest("t82-old", {}, {"thumbnailUrl": cover}))
		_assert(back["ok"] and not back["changed"], "%s: same hash is unchanged: %s" % [pass_name, str(back)])
		var e: Dictionary = ml._build_modpack_entry(old_path)
		check_eq([e["thumbnail_url"], e["raw_name"], e["enabled_count"], e["total_count"]], [cover, "Kept Name", 0, 1],
				pass_name + ": cover added, setup kept")
		var pd: Dictionary = ml._modpack_read_profile(old_path)
		check_eq(int(pd["priority"]["vostokmods:foo"]), 7, pass_name + ": priority kept")
		var zr := ZIPReader.new()
		_assert(zr.open(old_path) == OK and zr.read_file("MCM/m/config.ini").get_string_from_utf8() == "[a]\nv=9\n",
				pass_name + ": MCM file kept")
		zr.close()
	_drop_mods_dir(ml, "user://t82_mods", previous)
	H.pack_cleanup(ml)

func _t83_no_pack_fetch_during_an_apply(_ml: Object) -> void:
	var stub := ManifestStub.new()
	stub._compile_regex()
	_pack_setup(stub)
	stub._remove_tree("user://t83_mods", false)
	var previous := _use_mods_dir(stub, "user://t83_mods")
	var url := str(stub._vmp_modpack_manifest_url("t83-pack"))
	stub.served[url] = _site_manifest("t83-pack")
	var entry := {"raw_name": "T83 Pack", "hosted": {"provider": "vostokmods", "slug": "t83-pack", "manifest_url": url}}
	stub.set("_modpack_apply_in_progress", true)
	var busy: Dictionary = await stub._hosted_pack_from_link("t83-pack")
	_assert(not busy["ok"] and str(busy["error"]) == "Wait for the current apply to finish.", "Get waits: %s" % str(busy))
	busy = await stub._hosted_refresh_pack(entry)
	_assert(not busy["ok"] and not busy["changed"] and str(busy["error"]) == "Wait for the current apply to finish.",
			"Refresh waits: %s" % str(busy))
	check_eq(stub.asked, [], "requests during an apply")
	stub.set("_modpack_apply_in_progress", false)
	var got: Dictionary = await stub._hosted_pack_from_link("t83-pack")
	_assert(got["ok"] and got["changed"], "after the apply Get imports: %s" % got["error"])
	var again: Dictionary = await stub._hosted_refresh_pack(entry)
	_assert(again["ok"] and not again["changed"], "after the apply Refresh runs: %s" % again["error"])
	check_eq(stub.asked, [url, url], "one request per fetch")
	var late := str(stub._vmp_modpack_manifest_url("t83-late"))
	stub.served[late] = _site_manifest("t83-late")
	var moved := _site_manifest("t83-pack", {}, {"hash": "h2"})
	stub.served[url] = moved
	stub.apply_starts = true
	stub.asked.clear()
	busy = await stub._hosted_pack_from_link("t83-late")
	_assert(not busy["ok"] and str(busy["error"]) == "Wait for the current apply to finish.", "Get stops mid-fetch")
	_assert(not FileAccess.file_exists(str(stub._hosted_pack_file_path("t83-late"))), "Get wrote nothing")
	stub.set("_modpack_apply_in_progress", false)
	busy = await stub._hosted_refresh_pack(entry)
	_assert(not busy["ok"] and not busy["changed"] and str(busy["error"]) == "Wait for the current apply to finish.",
			"Refresh stops mid-fetch")
	check_eq(stub.asked, [late, url], "both fetched before stopping")
	check_eq(str(stub._build_modpack_entry(str(stub._hosted_pack_file_path("t83-pack")))["hosted"]["hash"]), "h1",
			"Refresh left the zip alone")
	stub.apply_starts = false
	stub.set("_modpack_apply_in_progress", false)
	_drop_mods_dir(stub, "user://t83_mods", previous)
	H.pack_cleanup(stub)
	stub.free()

# The restore takes the importer's caps and refuses ":"; it skips, so the pack still applies.
func _t84_pack_restore_caps_mcm(ml: Object) -> void:
	var data := {"c:/config.ini": "x".to_utf8_buffer(), "big/config.ini": "x".repeat(65537).to_utf8_buffer(),
			"edge/config.ini": "x".repeat(65536).to_utf8_buffer()}
	for i in 32:
		data["m%d/config.ini" % i] = "[a]".to_utf8_buffer()
	var out: Dictionary = ml._mcm_restore_files(data)
	check_eq(out.size(), 32, "32 files restored")
	_assert(out.has("edge/config.ini") and not out.has("c:/config.ini") and not out.has("big/config.ini"),
			"64 KiB kept, ':' and over-size skipped")
	_assert(not out.has("m31/config.ini"), "the 33rd file is skipped")
	check_eq(ml._mcm_restore_files({"a/config.ini": "[a]".to_utf8_buffer()}).keys(), ["a/config.ini"], "a small pack is whole")

# With the backup gone Unload refuses; the force keeps the pack's mods as a
# profile of the pack's name and leaves user://MCM and mods/ alone.
func _t85_force_unload_keeps_the_pack_as_a_profile(ml: Object) -> void:
	_pack_setup(ml)
	var previous := _use_mods_dir(ml, "user://t85_mods")
	H.write_text("user://t85_mods/keep.txt", "mine")
	var seed := _read(ml)
	seed.set_value("profile.kept.enabled", "a@1.0", false)
	_save(ml, seed, "seeded a profile named kept")
	var entry := _pack_write(ml, {"metroprofile": 1, "name": "Kept",
			"enabled": {"a@1.0": true, "foo@2.0": false}, "priority": {"a@1.0": 4}}, "pack")
	var r: Dictionary = await ml.apply_modpack(entry, null, Callable())
	_assert(r["ok"], "the pack applies: %s" % r.get("error"))
	var cfg := _read(ml)
	cfg.erase_section_key("settings", "modpack_backup_valid")
	ml._erase_profile_sections(cfg, "_before_modpack_Kept")
	cfg.set_value("profile._before_modpack_Kept.dep_ignore", "a@1.0", true)
	_save(ml, cfg, "dropped the backup")

	var missing := "The backup for this pack is missing, so your previous profile cannot be restored."
	check_eq(ml.unload_modpack(null), {"ok": false, "needs_force": true, "error": missing, "profile": "Kept 2"},
			"the refusal")
	check_eq(ml.get_active_modpack(), "Kept", "the refusal changes nothing")
	check_eq(ml.force_unload_modpack(null), {"ok": true, "error": "", "profile": "Kept 2"}, "the force result")
	cfg = _read(ml)
	check_eq([str(ml.get("_active_profile")), cfg.get_value("settings", "active_profile")], ["Kept 2", "Kept 2"],
			"active profile, live and saved")
	check_eq([cfg.get_value("profile.Kept 2.enabled", "a@1.0"), cfg.get_value("profile.Kept 2.enabled", "foo@2.0"),
			cfg.get_value("profile.Kept 2.priority", "a@1.0")], [true, false, 4], "the pack's enabled and priority")
	check_eq(ml.get_active_modpack(), "", "active pack after the force")
	check_eq(Array(cfg.get_section_keys("settings")).filter(func(k: String): return k.begins_with("modpack_")), [],
			"no modpack_ settings keys")
	check_eq(Array(cfg.get_sections()).filter(func(s: String): return s.contains("modpack_")), [],
			"no pack or backup sections")
	check_eq(FileAccess.get_file_as_string(SNAP + "Kept 2/MCM/some-mod/config.ini"), "[a]\nv=pack\n", "the new MCM slot")
	check_eq(FileAccess.get_file_as_string(LIVE_MCM), "[a]\nv=pack\n", "live MCM untouched")
	check_eq(Array(DirAccess.get_files_at("user://t85_mods")), ["keep.txt"], "mods folder untouched")
	check_eq(FileAccess.get_file_as_string("user://t85_mods/keep.txt"), "mine", "mod file untouched")
	check_eq(ml.force_unload_modpack(null), {"ok": false, "error": "No modpack is active"}, "a second force")

	r = await ml.apply_modpack(entry, null, Callable())
	_assert(r["ok"], "the pack applies again: %s" % r.get("error"))
	var refused: Dictionary = ml.force_unload_modpack(null)
	_assert(not refused["ok"] and str(refused["error"]).contains("Unload"), "a backed-up pack refuses force")
	check_eq(ml.get_active_modpack(), "Kept", "the refused force changes nothing")
	_assert(ml.unload_modpack(null)["ok"], "Unload still works")
	check_eq(str(ml.get("_active_profile")), "Kept 2", "profile after the unload")
	_drop_mods_dir(ml, "user://t85_mods", previous)
	H.pack_cleanup(ml)

# 3.4.2 kept the space "!" left behind; one load moves the slots so the row is Active again.
func _t86_342_slot_with_an_edge_space_migrates(ml: Object) -> void:
	_pack_setup(ml)
	ml.set("_boot_complete", false)
	var entry := _pack_write(ml, {"metroprofile": 1, "name": "Best Mods Ever !",
			"enabled": {"a@1.0": true, "foo@2.0": true}}, "pack")
	check_eq(str(entry["sanitized_name"]), "Best Mods Ever", "the slot name today")
	var old := "Best Mods Ever "
	_seed(ml, [["settings", "active_profile", "modpack__" + old], ["settings", "active_modpack", old],
			["settings", "modpack_backup_profile", "Default"], ["settings", "modpack_backup_valid", true],
			["profile.Default.enabled", "a@1.0", true], ["profile._before_modpack_" + old + ".enabled", "a@1.0", true],
			["profile.modpack__" + old + ".enabled", "a@1.0", true], ["profile.modpack__" + old + ".enabled", "foo@2.0", true],
			["profile.modpack__" + old + ".settings", "listed", true]])
	H.write_text(LIVE_MCM, "pack")
	H.write_text(SNAP + "_before_modpack_" + old + "/MCM/some-mod/config.ini", "mine")
	ml._load_ui_config()
	var cfg := _read(ml)
	check_eq([ml.get_active_modpack(), str(ml.get("_active_profile")), cfg.get_value("settings", "active_profile")],
			["Best Mods Ever", "modpack__Best Mods Ever", "modpack__Best Mods Ever"], "active pack and slot")
	check_eq(Array(cfg.get_sections()).filter(func(sec: String): return sec.contains(old + ".")), [], "3.4.2 sections left")
	check_eq([cfg.get_value("profile.modpack__Best Mods Ever.enabled", "foo@2.0", false),
			cfg.get_value("profile._before_modpack_Best Mods Ever.enabled", "a@1.0", false)], [true, true], "slots moved")
	_assert(ml._modpack_active_state(entry, ml.get_active_modpack())["is_active"], "the row shows Active")
	var bytes := FileAccess.get_file_as_bytes(str(ml.UI_CONFIG_PATH))
	ml._load_ui_config()
	_assert(FileAccess.get_file_as_bytes(str(ml.UI_CONFIG_PATH)) == bytes, "a second load writes nothing")
	var u: Dictionary = ml.unload_modpack(null)
	_assert(u["ok"], "Unload works: %s" % u.get("error"))
	check_eq([str(ml.get("_active_profile")), ml.get_active_modpack()], ["Default", ""], "after the unload")
	check_eq(FileAccess.get_file_as_string(LIVE_MCM), "mine", "the backup MCM is restored")
	H.pack_cleanup(ml)

# Get or Refresh of a pack already on disk at the site's hash answers unchanged,
# over the MCM caps too; a changed hash over the caps is still refused.
func _t87_unchanged_pack_skips_the_mcm_caps(_ml: Object) -> void:
	var stub := ManifestStub.new()
	stub._compile_regex()
	_pack_setup(stub)
	stub._remove_tree("user://t87_mods", false)
	var previous := _use_mods_dir(stub, "user://t87_mods")
	var many := {}
	for i in 33:
		many["m%d/config.ini" % i] = "[a]
v=1
"
	var manifest := _site_manifest("t87-pack", many)
	var conv: Dictionary = stub._hosted_manifest_to_profile(manifest)
	var path := str(stub._hosted_pack_file_path("t87-pack"))
	_assert(stub._hosted_write_pack_zip(conv["profile"], conv["mcm"], path)["ok"], "a 3.4.2 import is on disk")
	var bytes := FileAccess.get_file_as_bytes(path)
	var got: Dictionary = stub._hosted_import_manifest(manifest)
	check_eq([got["ok"], got.get("changed"), got["error"]], [true, false, ""], "Get of the same pack")
	var url := str(stub._vmp_modpack_manifest_url("t87-pack"))
	stub.served[url] = manifest
	var again: Dictionary = await stub._hosted_refresh_pack(stub._build_modpack_entry(path))
	check_eq([again["ok"], again["changed"], again["error"]], [true, false, ""], "Refresh of the same pack")
	var moved: Dictionary = stub._hosted_import_manifest(_site_manifest("t87-pack", many, {"hash": "h2"}))
	_assert(not moved["ok"] and str(moved["error"]).contains("more than 32"), "a changed pack over the caps fails")
	_assert(FileAccess.get_file_as_bytes(path) == bytes, "the pack on disk is untouched")
	_drop_mods_dir(stub, "user://t87_mods", previous)
	H.pack_cleanup(stub)
	stub.free()

# With the backup slot gone, a post-boot unload leaves the profile's own slot alone.
func _t88_unload_without_a_backup_slot_keeps_the_mcm(ml: Object) -> void:
	_pack_setup(ml)
	var entry := _pack_write(ml, {"metroprofile": 1, "name": "Late", "enabled": {"a@1.0": true}}, "pack")
	H.write_text(LIVE_MCM, "[a]\nv=mine\n")
	var r: Dictionary = await ml.apply_modpack(entry, null, Callable())
	_assert(r["ok"], "the pack applies before boot: %s" % r.get("error"))
	ml._remove_tree(SNAP + "_before_modpack_Late", false)
	ml.set("_boot_complete", true)
	ml.unload_modpack(null)
	check_eq(FileAccess.get_file_as_string(SNAP + "Default/MCM/some-mod/config.ini"), "[a]\nv=mine\n", "Default's own slot")
	ml.set("_boot_complete", false)
	ml._complete_pending_mcm_switch()
	check_eq(FileAccess.get_file_as_string(LIVE_MCM), "[a]\nv=mine\n", "live MCM after the restart")
	H.pack_cleanup(ml)

# A profile with no slot takes the live MCM at the restart, so a copy of it does too.
func _t89_capture_from_a_slotless_profile_takes_the_live_mcm(ml: Object) -> void:
	for apply in [false, true]:
		_pack_setup(ml)
		H.write_text(LIVE_MCM, "[a]\nv=A\n")
		var seed := _read(ml)
		seed.set_value("profile.C.enabled", "a@1.0", true)
		_save(ml, seed, "seeded profile C")
		ml.set("_boot_complete", true)
		ml._switch_profile("C")
		var slot := "N"
		if apply:
			var r: Dictionary = await ml.apply_modpack(_pack_write(ml, {"metroprofile": 1, "name": "Over",
					"enabled": {"a@1.0": true}}, "pack"), null, Callable())
			_assert(r["ok"], "the pack applies after boot: %s" % r.get("error"))
			slot = "_before_modpack_Over"
		else:
			ml._create_profile("N")
		check_eq(FileAccess.get_file_as_string(SNAP + slot + "/MCM/some-mod/config.ini"), "[a]\nv=A\n", slot + "'s MCM")
		ml.set("_boot_complete", false)
		ml._complete_pending_mcm_switch()
		if apply:
			ml.unload_modpack(null)
		check_eq(FileAccess.get_file_as_string(LIVE_MCM), "[a]\nv=A\n", "live MCM at the end")
		ml.set("_active_profile", "Default")
		H.pack_cleanup(ml)

# An update that replaces a file under its own name changes what loads.
func _t90_in_place_update_needs_a_restart(ml: Object) -> void:
	H.pack_cleanup(ml)
	var previous := _use_mods_dir(ml, "user://t90_mods")
	var mod_txt := "[mod]\nid=\"q\"\nversion=\"1.0\"\n"
	var path := H.write_zip("user://t90_mods/q.zip", {"mod.txt": mod_txt}, _report)
	_seed(ml, [["settings", "active_profile", "Default"]])
	ml.set("_active_profile", "Default")
	ml.set("_boot_complete", true)
	_install(ml, [])
	ml._reload_entries_for_active_profile()
	ml.set("_booted_set_signature", str(ml._loaded_set_signature()))
	_assert(not ml._post_boot_restart_needed(), "an untouched file needs no restart")
	# Modified times count whole seconds.
	OS.delay_msec(1100)
	H.write_zip(path, {"mod.txt": mod_txt, "new.gd": "extends Node\n"}, _report)
	ml._reload_entries_for_active_profile()
	_assert(ml._post_boot_restart_needed(), "a file replaced in place needs the restart")
	ml.set("_boot_complete", false)
	_drop_mods_dir(ml, "user://t90_mods", previous)
	H.pack_cleanup(ml)

# Row counts hash no file; the Apply preview still checks the pinned bytes.
func _t91_row_counts_hash_no_file(ml: Object) -> void:
	H.pack_cleanup(ml)
	var path := H.write_zip("user://t91_bar.vmz", {"mod.txt": "[mod]\nid=\"bar\"\n"}, _report)
	_install(ml, [H.mod_entry("bar@2.1", "bar", "2.1", {"cfg": _source_cfg("vostokmods:bar", "2.1"), "full_path": path})])
	ml.set("_active_profile", "Default")
	_seed(ml, [["settings", "active_profile", "Default"]])
	var sources := {"vostokmods:bar": {"provider": "vostokmods", "id": "bar", "version": "2.0"}}
	var checksums := {"vostokmods:bar": "0".repeat(64)}
	var sha_cache: Dictionary = ml.get("_modpack_sha256_cache")
	sha_cache.clear()
	_assert(ml._modpack_key_installed("vostokmods:bar", sources, checksums, ml._modpack_installed_index()),
			"a copy at another version counts")
	_assert(sha_cache.is_empty(), "the row count hashes no file")
	_assert(not ml._modpack_key_installed("vostokmods:bar", sources, checksums, ml._modpack_installed_index(true)),
			"the preview finds other bytes")
	_assert(sha_cache.has(path), "the preview hashed the copy")
	H.remove_user_file(path)
	H.pack_cleanup(ml)

# A rescan of unchanged files opens no zip; a changed file is read again.
func _t92_pack_scan_opens_each_zip_once(ml: Object) -> void:
	H.pack_cleanup(ml)
	var previous := _use_mods_dir(ml, "user://t92_mods")
	var memo: Dictionary = ml.get("_modpack_zip_memo")
	memo.clear()
	var pack := func(name: String) -> void:
		H.write_zip("user://t92_mods/p.zip", {"profile.json": JSON.stringify({"metroprofile": 1, "name": name,
				"enabled": {}})}, _report)
	pack.call("Once")
	H.write_zip("user://t92_mods/m.zip", {"mod.txt": "[mod]\nid=\"m\"\n"}, _report)
	check_eq(str(ml.collect_modpack_metadata()[0]["raw_name"]), "Once", "pack name on the first scan")
	check_eq(memo.size(), 2, "zips remembered")
	for v: Dictionary in memo.values():
		if v["profile"] is Dictionary:
			v["profile"]["name"] = "Memo"
	check_eq(str(ml.collect_modpack_metadata()[0]["raw_name"]), "Memo", "pack name from an unchanged zip")
	pack.call("Read Again")
	check_eq(str(ml.collect_modpack_metadata()[0]["raw_name"]), "Read Again", "pack name from a changed zip")
	var size := FileAccess.get_size("user://t92_mods/p.zip")
	# Modified times count whole seconds.
	OS.delay_msec(1100)
	pack.call("Read Agian")
	check_eq(FileAccess.get_size("user://t92_mods/p.zip"), size, "same-size rewrite")
	check_eq(str(ml.collect_modpack_metadata()[0]["raw_name"]), "Read Agian", "pack name from a newer zip")
	_drop_mods_dir(ml, "user://t92_mods", previous)
	H.pack_cleanup(ml)

func _t93_unlisted_active_lands_on_the_first_profile(ml: Object) -> void:
	H.pack_cleanup(ml)
	_seed(ml, [["settings", "active_profile", "Ghost"], ["profile.Zed.enabled", "a@1.0", true],
			["profile.Alpha.enabled", "a@1.0", true]])
	ml._load_ui_config()
	check_eq(str(ml.get("_active_profile")), "Alpha", "profile after an unlisted active")
	ml.set("_active_profile", "Default")
	H.pack_cleanup(ml)

# foo must not adopt foobar@1.0's rows after a version change.
func _t94_id_prefix_takes_no_other_mods_keys(ml: Object) -> void:
	for c in [["foo@1.0", true], ["FOO@1.0", true], ["foobar@1.0", false], ["foo", false]]:
		check_eq(ml._key_names_id(c[0], "foo"), c[1], "%s names foo" % c[0])
	H.pack_cleanup(ml)
	var foo := H.mod_entry("foo@2.0", "foo", "2.0")
	_install(ml, [foo])
	var cfg := ConfigFile.new()
	cfg.set_value("profile.Test.enabled", "foobar@1.0", true)
	cfg.set_value("profile.Test.priority", "foobar@1.0", 9)
	ml._apply_profile_to_entries(cfg, "Test")
	check_eq([foo["enabled"], foo["priority"], foo.has("profile_version_mismatch")], [false, 0, false],
			"foo keeps its defaults")
	H.pack_cleanup(ml)

func _t95_profile_names_keep_every_digit(ml: Object) -> void:
	for c in [["Run 0123456789", "Run 0123456789"], ["A9", "A9"], ["a/b:c.d", "abcd"]]:
		check_eq(str(ml._sanitize_profile_name(c[0])), c[1], "sanitized '%s'" % c[0])

func _t96_resnapshot_drops_deleted_mcm_files(ml: Object) -> void:
	H.pack_cleanup(ml)
	H.write_text(LIVE_MCM, "a")
	H.write_text(LIVE_M, "b")
	ml._snapshot_mcm_to("T96")
	DirAccess.remove_absolute(LIVE_M)
	ml._snapshot_mcm_to("T96")
	var slot := str(ml._mcm_snapshot_dir("T96"))
	_assert(FileAccess.file_exists(slot.path_join("some-mod/config.ini")), "the kept file is in the slot")
	_assert(not FileAccess.file_exists(slot.path_join("m/config.ini")), "the deleted file left the slot")
	_assert(ml._restore_mcm_from("T96") and not FileAccess.file_exists(LIVE_M), "restore brings no deleted file")
	H.pack_cleanup(ml)

func _t97_mcm_copy_skips_dot_entries(ml: Object) -> void:
	for d in ["user://t97_src", "user://t97_dst"]:
		ml._remove_tree(d, false)
	H.write_text("user://t97_src/keep.cfg", "k")
	H.write_text("user://t97_src/.hidden", "h")
	H.write_text("user://t97_src/.hiddendir/x.cfg", "x")
	ml._copy_dir_recursive("user://t97_src", "user://t97_dst")
	check_eq([FileAccess.file_exists("user://t97_dst/keep.cfg"), FileAccess.file_exists("user://t97_dst/.hidden"),
			DirAccess.dir_exists_absolute("user://t97_dst/.hiddendir")], [true, false, false], "copied keep, hidden, hiddendir")
	for d in ["user://t97_src", "user://t97_dst"]:
		ml._remove_tree(d, false)

func _t98_hashless_pack_reimports_its_changes(ml: Object) -> void:
	_pack_setup(ml)
	ml._remove_tree("user://t98_mods", false)
	var previous := _use_mods_dir(ml, "user://t98_mods")
	for v in ["2.0", "2.1"]:
		var m := _site_manifest("t98-pack", {}, {"hash": null})
		m["mods"][0]["version"] = v
		var r: Dictionary = ml._hosted_import_manifest(m)
		_assert(r["ok"] and r["changed"], "hashless %s import changes: %s" % [v, str(r)])
		var pd: Variant = ml._modpack_read_profile(str(ml._hosted_pack_file_path("t98-pack")))
		_assert(pd != null and JSON.stringify(pd).contains(v), "the pack holds foo " + v)
	_drop_mods_dir(ml, "user://t98_mods", previous)
	H.pack_cleanup(ml)

# No zip on disk yet, but the active pack has the incoming name.
func _t99_slotless_active_pack_refuses_a_replace(ml: Object) -> void:
	_pack_setup(ml)
	ml._remove_tree("user://t99_mods", false)
	var previous := _use_mods_dir(ml, "user://t99_mods")
	var cfg := _read(ml)
	cfg.set_value("settings", "active_modpack", "T99 Pack")
	_save(ml, cfg, "seeded the active pack")
	var r: Dictionary = ml._hosted_import_manifest(_site_manifest("t99-pack", {}, {"name": "T99 Pack"}))
	_assert(not r["ok"] and str(r["error"]).begins_with("Unload"), "import refused: %s" % str(r))
	_assert(not FileAccess.file_exists(str(ml._hosted_pack_file_path("t99-pack"))), "no pack written")
	_drop_mods_dir(ml, "user://t99_mods", previous)
	H.pack_cleanup(ml)

func _t100_newest_same_named_pack_wins(ml: Object) -> void:
	H.pack_cleanup(ml)
	ml._remove_tree("user://t100_mods", false)
	var previous := _use_mods_dir(ml, "user://t100_mods")
	(ml.get("_modpack_zip_memo") as Dictionary).clear()
	var profile := JSON.stringify({"metroprofile": 1, "name": "Same", "enabled": {}})
	H.write_zip("user://t100_mods/b_old.zip", {"profile.json": profile}, _report)
	# Modified times count whole seconds.
	OS.delay_msec(1100)
	H.write_zip("user://t100_mods/a_new.zip", {"profile.json": profile}, _report)
	var packs: Array = ml.collect_modpack_metadata()
	_assert(packs.size() == 1 and str(packs[0]["file_name"]) == "a_new.zip", "the newer zip is listed")
	check_eq(str(packs[0].get("duplicates_hidden", [{}])[0].get("file_name", "")), "b_old.zip", "the older zip is hidden")
	_drop_mods_dir(ml, "user://t100_mods", previous)
	H.pack_cleanup(ml)

# A failed cfg save stops the switch with its markers on disk, so the retry loses no MCM.
func _t101_failed_cfg_save_stops_the_mcm_switch(_ml: Object) -> void:
	# [save that fails, live MCM after it, markers left on disk]
	for c in [["load", "A", ["A", "B"]], ["restore", "B", ["", "B"]]]:
		var stub := CfgBlockStub.new()
		H.pack_cleanup(stub)
		H.write_text(LIVE_M, "A")
		H.write_text(SNAP + "B/MCM/m/config.ini", "B")
		_seed(stub, [["settings", "active_profile", "B"], ["settings", "mcm_pending_from", "A"],
				["settings", "mcm_pending_to", "B"]])
		stub.block_after = c[0]
		stub._complete_pending_mcm_switch()
		stub.unblock_cfg()
		_assert(not stub.get("_mcm_switch_completed"), "%s: not completed" % c[0])
		check_eq(FileAccess.get_file_as_string(LIVE_M), c[1], "%s: live MCM after the failure" % c[0])
		var cfg := _read(stub)
		check_eq([str(cfg.get_value("settings", "mcm_pending_from", "")), str(cfg.get_value("settings", "mcm_pending_to", ""))],
				c[2], "%s: markers on disk" % c[0])
		stub._complete_pending_mcm_switch()
		_assert(stub.get("_mcm_switch_completed"), "%s: the retry completes" % c[0])
		check_eq(FileAccess.get_file_as_string(LIVE_M), "B", "%s: live MCM after the retry" % c[0])
		check_eq(FileAccess.get_file_as_string(SNAP + "A/MCM/m/config.ini"), "A", "%s: A's slot after the retry" % c[0])
		_assert(not stub._mcm_switch_pending(), "%s: the retry clears the markers" % c[0])
		H.pack_cleanup(stub)
		stub.free()
