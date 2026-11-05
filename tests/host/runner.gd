## Host seam harness: normalizers, the provider:id grammar, source records, caps wiring and covers.
## It makes no request, so live endpoints and the payloads real hosts send today are not covered.
extends "res://runner_base.gd"

# Parsed from JSON text, so every number arrives as a float, as in production.
const MWS_ROW_JSON := """
{"id": 12345, "name": "Example Mod", "version": " 1.2.0 ",
 "user": {"id": 9, "name": "AuthorGuy"},
 "category": {"id": 3, "name": "Weapons"},
 "downloads": 321, "likes": 12, "views": 4567,
 "bumped_at": "2026-08-01T10:20:30.000000Z",
 "published_at": "2026-07-01T00:00:00.000000Z",
 "short_desc": "A short blurb",
 "thumbnail": {"file": "abc123.png", "has_thumb": true}}
"""

# followersCount must not become likes; updatedAt is later than the newest
# file because it moves on any page edit; a tag is listed before the category.
const VM_ROW_JSON := """
{"id": "m_4", "slug": "example", "name": "Example", "summary": "An example mod.",
 "ownerDisplayName": "Ovrrde", "ownerUsername": "ovrrde",
 "taxonomies": [{"slug": "tag-1", "name": "Tag One", "group": {"slug": "tags", "name": "Tags"}},
                {"slug": "category-1", "name": "Category 1", "group": {"slug": "categories", "name": "Categories"}}],
 "thumbnailUrl": "https://files.vostokmods.net/mods/4/screenshots/example.png",
 "downloadsCount": 1, "followersCount": 7, "viewsCount": 42,
 "createdAt": "2026-08-01T00:00:00.000Z",
 "updatedAt": "2026-08-20T13:32:22.294Z", "latestGameVersion": null,
 "latestVersion": {"id": "v_1", "scanStatus": "clean", "downloadable": true,
                   "createdAt": "2026-08-07T06:05:11.420Z"}}
"""

const VM_ROW_NULLS_JSON := """
{"id": "m_5", "slug": "nulls", "name": "Nulls", "summary": null,
 "ownerDisplayName": "Ovrrde", "taxonomies": [], "thumbnailUrl": null,
 "downloadsCount": 0, "followersCount": 0, "viewsCount": 0,
 "createdAt": null, "updatedAt": null, "latestGameVersion": null,
 "latestVersion": null}
"""

# A pack row and manifest as the site serves them on 2026-11-03.
const VM_PACK_LIVE_JSON := """
{"id": "01a0", "slug": "jonis-pack", "name": "Joni's Pack", "summary": "Everything.",
 "ownerId": "u1", "ownerUsername": "joni", "ownerDisplayName": "Joni", "ownerAvatarUrl": "https://x/a.png",
 "downloadsCount": 91, "viewsCount": 721, "followersCount": 3, "bookmarksCount": 1,
 "createdAt": "2026-10-01T00:00:00.000Z", "updatedAt": "2026-10-31T22:10:00.000Z", "modCount": 31,
 "type": "modpack", "url": "https://vostokmods.net/modpack/jonis-pack",
 "thumbnailUrl": "https://files.vostokmods.net/packs/1/cover.webp",
 "taxonomies": [{"slug": "multiplayer", "name": "Multiplayer", "group": {"slug": "tags"}},
                {"slug": "kitchen-sink", "name": "Kitchen Sink", "group": {"slug": "categories"}}],
 "latestGameVersion": null, "latestVersion": null,
 "manifestUrl": "https://vostokmods.net/api/modpacks/jonis-pack/manifest"}
"""

# GET /api/modpacks/{slug} as served on 2026-11-03: the row's keys plus markdown and HTML
# descriptions, screenshots, the manifest's mod list and viewer flags.
const VM_PACK_DETAIL_JSON := """
{"type": "modpack", "id": "01a0", "slug": "jonis-pack", "name": "Joni's Pack", "summary": "Everything.",
 "description": "![cover](https://files.vostokmods.net/packs/1/cover.webp)\\n\\nEvery **mod** I run.",
 "descriptionHtml": "<p>Every <strong>mod</strong> I run.</p>",
 "descriptionMdc": {"data": {"title": "", "description": ""}, "body": {"type": "root", "children": []},
                    "toc": {"title": "", "searchDepth": 2, "depth": 2, "links": []}},
 "ownerId": "u1", "ownerUsername": "joni", "ownerDisplayName": "Joni", "ownerAvatarUrl": "https://x/a.png",
 "status": "published", "moderationNote": "", "suspensionSource": null, "commentsEnabled": false,
 "license": "MIT", "aiDisclosure": true, "sourceUrl": "", "discordUrl": "", "donateUrl": "",
 "downloadsCount": 91, "viewsCount": 721, "followersCount": 4, "bookmarksCount": 3,
 "createdAt": "2026-10-01T00:00:00.000Z", "updatedAt": "2026-10-31T22:10:00.000Z",
 "url": "https://vostokmods.net/modpack/jonis-pack", "thumbnailUrl": "https://files.vostokmods.net/packs/1/cover.webp",
 "taxonomies": [{"id": "t1", "slug": "kitchen-sink", "name": "Kitchen Sink", "groupId": "g1", "icon": "i", "sortOrder": 16,
                 "group": {"id": "g1", "slug": "categories", "name": "Categories", "icon": "i", "sortOrder": 0},
                 "contentTypes": ["modpack"], "articleTypes": []}],
 "screenshots": [{"id": "s1", "url": "https://files.vostokmods.net/packs/1/shot.webp", "hidden": true, "isThumbnail": false},
                 {"id": "s2", "url": "https://files.vostokmods.net/packs/1/cover.webp", "hidden": false, "isThumbnail": true}],
 "versions": [], "viewer": {"canManage": false, "followed": false, "bookmarked": false},
 "manifestUrl": "https://vostokmods.net/api/modpacks/jonis-pack/manifest", "modCount": 31, "mcmFiles": {},
 "mods": [{"id": "m1", "slug": "hk-g28", "name": "HK G28", "ownerDisplayName": "y",
           "thumbnailUrl": "https://files.vostokmods.net/mods/1/t.webp", "loadOrder": 1, "version": "1.2.0", "available": true}]}
"""

const VM_MANIFEST_LIVE_JSON := """
{"format": 2, "slug": "jonis-pack", "name": "Joni's Pack", "summary": "Everything.",
 "ownerDisplayName": "Joni", "url": "https://vostokmods.net/modpack/jonis-pack", "thumbnailUrl": "https://x/c.png",
 "updatedAt": "2026-10-31T22:10:00.000Z", "hash": "ab", "mcmConfig": null,
 "mods": [
  {"loadOrder": 2, "slug": "gone", "name": "Gone", "ownerDisplayName": "x", "available": false,
   "reason": "removed", "version": null, "fileName": null, "fileSize": null, "sha256": null,
   "downloadUrl": null, "pageUrl": "https://vostokmods.net/mod/gone"},
  {"loadOrder": 1, "slug": "hk-g28", "name": "HK G28", "ownerDisplayName": "y", "available": true,
   "reason": null, "version": "1.2.0", "fileName": "hk.vmz", "fileSize": 10, "sha256": null,
   "downloadUrl": "https://vostokmods.net/api/mods/hk-g28/versions/1.2.0/download",
   "pageUrl": "https://vostokmods.net/mod/hk-g28"},
  {"loadOrder": 3, "slug": "nameless", "available": true, "version": " 2.0 ",
   "pageUrl": "https://evil.example/mod/nameless"}
 ]}
"""

# A loader whose GET answers from `replies` by URL and records [url, ttl_ms] per request.
const STUB_NET_SRC := """extends "res://modloader_neutered.gd"
var replies := {}
var asked: Array = []
var shown: Array = []
func _show_modloader_update_dialog(latest: String) -> void:
	shown.append(latest)
func _get_ui_cfg_value(section: String, key: String, default: Variant) -> Variant:
	return default
func _hnet_get_json(provider: String, url: String, ttl_ms: int = 0,
		allow_rate_wait: bool = true, allow_transport_retry: bool = true) -> Dictionary:
	asked.append([url, ttl_ms])
	return replies[url] if replies.has(url) else host_err(HOST_ERR_NOT_FOUND, 404, "no fixture")
"""

func _init() -> void:
	super("host", "T1..T48")

func _tests(ml: Object) -> void:
	# The detail normalizer's markdown pass reads regexes _ready compiles.
	ml._compile_regex()
	_t1_mws_summary(ml)
	_t2_vm_summary(ml)
	_t3_null_and_float_ids(ml)
	_t4_result_envelope(ml)
	_t5_ref_grammar(ml)
	_t6_source_round_trip(ml)
	_t7_modtxt_reader(ml)
	_t11_source_precedence(ml)
	_t8_vm_pure_surface(ml)
	_t9_caps_match_wiring(ml)
	_t20_rate_limit_headers(ml)
	_t21_mws_list_params(ml)
	_t25_version_ordering(ml)
	_t32_browse_hides_own_listing(ml)
	_t33_install_map_keys_both_ids(ml)
	_t34_animated_webp_first_frame(ml)
	_t35_status_error_mapping(ml)
	_t36_resolve_failure_copy(ml)
	_t37_vm_rate_headers(ml)
	_t39_vm_download_host_guard(ml)
	_t40_vm_banner(ml)
	_t41_vm_pack_summary(ml)
	_t45_vm_site_url_predicate(ml)
	_t48_pack_sha_pins(ml)
	var net := _stub_net()
	await _t38_vm_categories_for_mods(net)
	await _t42_vm_pack_listing(net)
	await _t43_vm_pack_detail(net)
	await _t44_vm_manifest_slug_guard(net)
	await _t46_mws_primary_file_first(net)
	await _t47_loader_update_prompt(net)
	net.free()

# Each key of want against rec; "a.b" reads a nested key, and an int stays an int.
func _fields(rec: Dictionary, want: Dictionary) -> void:
	for path: String in want:
		var got: Variant = rec
		for k in path.split("."):
			got = got[k]
		if want[path] is int:
			_assert(got is int and got == want[path], "%s is int %d (got %s)" % [path, want[path], var_to_str(got)])
		else:
			check_eq(got, want[path], path)

func _same_keys(ml: Object, s: Dictionary) -> void:
	var want: Array = (ml.host_empty_summary() as Dictionary).keys()
	want.sort()
	var got: Array = s.keys()
	got.sort()
	check_eq(got, want, "summary keys match host_empty_summary")

func _t1_mws_summary(ml: Object) -> void:
	begin("T1")
	var row: Variant = JSON.parse_string(MWS_ROW_JSON)
	_assert(row is Dictionary, "fixture JSON parses")
	var s: Dictionary = ml._mwsp_summary(row)
	_same_keys(ml, s)
	check_eq(ml.host_ref_key(s["ref"]), "modworkshop:12345", "float id ref key")
	_fields(s, {
		"name": "Example Mod", "author_name": "AuthorGuy", "category_name": "Weapons", "version": "1.2.0",
		"downloads": 321, "likes": 12, "views": 4567,
		"updated_at": "2026-08-01T10:20:30.000000Z", "published_at": "2026-07-01T00:00:00.000000Z",
		"short_description": "A short blurb",
		"thumbnail.url": "https://storage.modworkshop.net/mods/images/abc123.png",
		"thumbnail.cache_key": "abc123.png", "default_file_id": "",
	})
	check_eq((ml._mwsp_summary({"id": 12345.0}) as Dictionary)["name"], "12345", "a nameless row is named by id")

func _t2_vm_summary(ml: Object) -> void:
	begin("T2")
	var row: Variant = JSON.parse_string(VM_ROW_JSON)
	_assert(row is Dictionary, "fixture JSON parses")
	var s: Dictionary = ml._vmp_summary(row)
	_same_keys(ml, s)
	# Every Vostok Mods route is slug-keyed; the numeric id addresses nothing.
	check_eq(ml.host_ref_key(s["ref"]), "vostokmods:example", "ref identity is the slug")
	_fields(s, {
		"name": "Example", "author_name": "Ovrrde", "short_description": "An example mod.",
		"downloads": 1, "likes": -1, "views": 42, "version": "",
		"published_at": "2026-08-01T00:00:00.000Z", "updated_at": "2026-08-07T06:05:11.420Z",
	})
	var unserved: Dictionary = ml._vmp_summary(JSON.parse_string("""
	{"slug": "unserved", "updatedAt": "2026-08-20T13:32:22.294Z",
	 "latestVersion": {"id": "v_2", "scanStatus": "pending", "downloadable": false,
	                   "createdAt": "2026-08-19T00:00:00.000Z"}}
	"""))
	check_eq(unserved["updated_at"], "", "no clean file, no updated_at")
	_fields(s, {
		"category_name": "Category 1", "default_file_id": "v_1",
		"thumbnail.url": "https://files.vostokmods.net/mods/4/screenshots/example.png",
		"thumbnail.cache_key": "",
	})

	# str(null) is "<null>", which is non-empty and would be fetched as a URL.
	begin("T2n")
	var nrow: Variant = JSON.parse_string(VM_ROW_NULLS_JSON)
	_assert(nrow is Dictionary, "nullable fixture JSON parses")
	var n: Dictionary = ml._vmp_summary(nrow)
	_same_keys(ml, n)
	check_eq(ml.host_ref_key(n["ref"]), "vostokmods:nulls", "slug identity with null fields")
	_fields(n, {"thumbnail.url": "", "short_description": "", "updated_at": "", "category_name": "",
		"default_file_id": ""})

func _t3_null_and_float_ids(ml: Object) -> void:
	begin("T3")
	for c in [[null, ""], [12345.0, "12345"], [" 77 ", "77"]]:
		check_eq(ml._host_id_str(c[0]), c[1], "_host_id_str(%s)" % var_to_str(c[0]))
	var mws: Dictionary = ml._mwsp_summary(JSON.parse_string('{"id": null, "name": "X"}'))
	check_eq(ml.host_ref_key(mws["ref"]), "", "MWS null id ref key")
	check_eq(mws["name"], "", "MWS null id stays empty")
	var vm: Dictionary = ml._vmp_summary(JSON.parse_string('{"id": null, "name": "X"}'))
	check_eq(ml.host_ref_key(vm["ref"]), "", "Vostok Mods null id ref key")
	_assert(not ml.host_ref_valid(ml.host_ref("modworkshop", "")), "a ref with no id is invalid")
	var sparse: Dictionary = ml._mwsp_summary(JSON.parse_string(
			'{"id": 7, "name": null, "version": null, "short_desc": null, "bumped_at": null, "published_at": null, "user": {"name": null}, "category": {"name": null}}'))
	for key in ["version", "short_description", "updated_at", "published_at", "author_name", "category_name"]:
		check_eq(sparse[key], "", "null MWS " + key)
	_assert(not str(sparse["name"]).contains("null"), "null MWS name is not <null>")
	var sparse_file: Dictionary = ml._mwsp_file(JSON.parse_string('{"id": 9, "version": null, "created_at": null, "file": null}'))
	for key in ["version", "created_at"]:
		check_eq(sparse_file[key], "", "null MWS file " + key)

func _t4_result_envelope(ml: Object) -> void:
	begin("T4")
	var want_keys := ["code", "data", "http", "message", "ok"]
	for c in [["host_ok", ml.host_ok([1, 2]), true, [1, 2], ["", 0, ""]],
			["host_err", ml.host_err("rate_limited", 429, "slow down"), false, null, ["rate_limited", 429, "slow down"]]]:
		var env: Dictionary = c[1]
		var keys := env.keys()
		keys.sort()
		check_eq(keys, want_keys, c[0] + " keys")
		check_eq(env["ok"], c[2], c[0] + " ok")
		check_eq(env["data"], c[3], c[0] + " data")
		check_eq([env["code"], env["http"], env["message"]], c[4], c[0] + " code, http and message")

func _t5_ref_grammar(ml: Object) -> void:
	begin("T5")
	check_eq(ml.host_ref_from_key("modworkshop:12345"), {"provider": "modworkshop", "id": "12345"}, "modworkshop key")
	check_eq(ml.host_ref_key(ml.host_ref_from_key("modworkshop:12345")), "modworkshop:12345", "key round trip")
	check_eq(ml.host_ref_from_key("vostokmods:example"), {"provider": "vostokmods", "id": "example"}, "vostokmods key")
	check_eq(ml.host_ref_from_key("vostokmods:collection/riverwood:v2")["id"], "collection/riverwood:v2",
			"id keeps later colons")
	for bad in ["12345", "steam:123", "modworkshop:", "modworkshop:   ", ":123", ""]:
		check_eq(ml.host_ref_from_key(bad), {}, "'%s' is rejected" % bad)

# Every on-disk era of a source record converges to one serialization in one
# pass, and the payload mirrors modworkshop_id only when the provider is modworkshop.
func _t6_source_round_trip(ml: Object) -> void:
	var eras := [
		# [label, record, provider, id, mirror, version]
		["legacy int", {"modworkshop_id": 12345}, "modworkshop", "12345", true, ""],
		["legacy float", JSON.parse_string('{"modworkshop_id": 12345}'), "modworkshop", "12345", true, ""],
		["legacy quoted string", {"modworkshop_id": "12345"}, "modworkshop", "12345", true, ""],
		["legacy null", {"modworkshop_id": null}, "", "", false, ""],
		["new provider-qualified", {"provider": "vostokmods", "id": "4", "version": "1.0.3"}, "vostokmods", "4", false, "1.0.3"],
		["new modworkshop", {"provider": "modworkshop", "id": "777"}, "modworkshop", "777", true, ""],
		["new with stale mirror", {"provider": "vostokmods", "id": "4", "modworkshop_id": 999}, "vostokmods", "4", false, ""],
		["unknown provider", {"provider": "steam", "id": "1"}, "", "", false, ""],
	]
	for era in eras:
		begin("T6 " + era[0])
		var n1: Dictionary = ml._normalize_source_record(era[1])
		var nk := n1.keys()
		nk.sort()
		check_eq(nk, ["id", "provider", "version"], "canonical keys")
		check_eq(n1["provider"], era[2], "provider")
		check_eq(n1["id"], era[3], "id")
		check_eq(n1["version"], era[5], "version")
		var payload: Dictionary = ml._mod_source_payload(n1)
		check_eq(payload.has("modworkshop_id"), era[4], "mirror present only for modworkshop")
		if era[4]:
			check_eq(int(payload["modworkshop_id"]), str(n1["id"]).to_int(), "mirror value equals the id")
		var s1 := str(ml._serialize_mod_source_rec(n1))
		var s2 := str(ml._serialize_mod_source_rec(ml._normalize_source_record(JSON.parse_string(s1))))
		check_eq(s2, s1, "serialization converges in one pass")

func _t7_modtxt_reader(ml: Object) -> void:
	var cases := [
		# [label, mod.txt, provider, id, version]
		["source= alone", '[mod]\nversion="1.2"\n\n[updates]\nsource="vostokmods:example"\n', "vostokmods", "example", "1.2"],
		["dual-written: source= wins", '[updates]\nsource="vostokmods:example"\nmodworkshop=777\n', "vostokmods", "example", ""],
		["legacy modworkshop= int", '[updates]\nmodworkshop=777\n', "modworkshop", "777", ""],
		["legacy junk id rejected", '[updates]\nmodworkshop="12abc"\n', "", "", ""],
		["malformed source= falls back", '[updates]\nsource="steam:4"\nmodworkshop=777\n', "modworkshop", "777", ""],
		["legacy zero-padded normalizes", '[updates]\nmodworkshop="0123"\n', "modworkshop", "123", ""],
		["bare source= rejected", '[updates]\nsource="12345"\n', "", "", ""],
	]
	for c in cases:
		begin("T7 " + c[0])
		var rec: Dictionary = ml._mod_source_from_cfg(H.cfg_from_text(c[1], _report))
		for i in 3:
			check_eq(rec[["provider", "id", "version"][i]], c[2 + i], ["provider", "id", "version"][i])
	begin("T7")
	var nullrec: Dictionary = ml._mod_source_from_cfg(null)
	check_eq([nullrec["provider"], nullrec["id"]], ["", ""], "a null ConfigFile is no source")
	# ConfigFile drops a section with no keys; [registry] is a presence signal and
	# an unknown header is kept so the notice can name it.
	var bare: ConfigFile = ml._parse_mod_txt('[mod]\nid="b"\n\n[Registry]\n\n[hooks]\n\n[registry]\n')["cfg"]
	_assert(bare != null and bare.has_section("registry"), "a bare [registry] survives")
	_assert(bare != null and bare.has_section("Registry"), "a bare unknown header survives")
	_assert(bare != null and not bare.has_section("hooks"), "a bare known section stays absent")
	var spanning: Dictionary = ml._parse_mod_txt('[mod]\nname="X"\ntags=[\n"a",\n"b"\n]\nid=not quoted\n')
	_assert(spanning["cfg"] == null and str(spanning["error"]).begins_with("line 7 [mod]"),
			"error skips a multi-line value (got %s)" % str(spanning["error"]))
	var first_line: Dictionary = ml._parse_mod_txt('[mod]\nname=X Y\nid="x"\n')
	_assert(str(first_line["error"]).begins_with("line 2 [mod]"), "error names line 2 (got %s)" % str(first_line["error"]))

# A mod.txt declaration against the stored [mod_sources] record. Files served by
# vostokmods.net carry only a legacy modworkshop= line, so the download's record
# wins over it; an explicit source= wins over everything.
func _t11_source_precedence(ml: Object) -> void:
	var legacy := H.cfg_from_text('[mod]\nversion="1.2"\n\n[updates]\nmodworkshop=777\n', _report)
	var explicit := H.cfg_from_text('[updates]\nsource="vostokmods:example"\n', _report)
	var silent := H.cfg_from_text('[mod]\nversion="1.2"\n', _report)
	var stored_vm := {"provider": "vostokmods", "id": "rtvcoop", "version": "5.0.0"}
	var stored_mws := {"provider": "modworkshop", "id": "777", "version": "1.2"}
	var stored_other_mws := {"provider": "modworkshop", "id": "999"}
	var cases := [
		# [label, mod.txt, stored record or null, provider:id, version]
		["explicit beats stored other provider", explicit, stored_other_mws, "vostokmods:example", ""],
		["legacy plus stored vostokmods", legacy, stored_vm, "vostokmods:rtvcoop", "5.0.0"],
		["legacy alone", legacy, null, "modworkshop:777", "1.2"],
		["legacy plus stored same provider", legacy, stored_mws, "modworkshop:777", "1.2"],
		["nothing declared, stored record", silent, stored_vm, "vostokmods:rtvcoop", "5.0.0"],
		["nothing declared, nothing stored", silent, null, "", ""],
	]
	for c in cases:
		begin("T11 " + c[0])
		var persisted := {}
		if c[2] != null:
			persisted["k"] = ml._normalize_source_record(c[2])
		var rec: Dictionary = ml._entry_source_record({"profile_key": "k", "cfg": c[1]}, persisted)
		var keys := rec.keys()
		keys.sort()
		check_eq(keys, ["id", "provider", "version"], "resolved keys")
		check_eq("" if rec["provider"] == "" else "%s:%s" % [rec["provider"], rec["id"]], c[3], "provider:id")
		check_eq(rec["version"], c[4], "version")

	begin("T11 persist")
	var cfg_path := str(ml.UI_CONFIG_PATH)
	var bak_path := cfg_path + ".bak"
	H.remove_user_file(cfg_path)
	H.remove_user_file(bak_path)
	var seed := ConfigFile.new()
	for c in [["vm@1", stored_vm], ["same@1", stored_mws], ["other@1", stored_other_mws]]:
		seed.set_value("mod_sources", c[0], ml._serialize_mod_source_rec(ml._normalize_source_record(c[1])))
	_assert(seed.save(cfg_path) == OK, "seeded mod_config.cfg")
	var entries: Array[Dictionary] = [
		{"profile_key": "vm@1", "cfg": legacy},
		{"profile_key": "same@1", "cfg": legacy},
		{"profile_key": "other@1", "cfg": explicit},
		{"profile_key": "new@1", "cfg": legacy},
	]
	ml._persist_mod_sources_for_entries(entries)
	var after: Dictionary = ml._get_persisted_mod_sources()
	for c in [["vm@1", "vostokmods:rtvcoop"], ["same@1", "modworkshop:777"], ["other@1", "vostokmods:example"],
			["new@1", "modworkshop:777"]]:
		var rec: Dictionary = after.get(c[0], {"provider": "(absent)", "id": ""})
		check_eq("%s:%s" % [rec["provider"], rec["id"]], c[1], "stored source of " + c[0])
	H.remove_user_file(bak_path)
	ml._persist_mod_sources_for_entries(entries)
	_assert(not FileAccess.file_exists(bak_path), "a second scan rewrites nothing")
	H.remove_user_file(cfg_path)
	H.remove_user_file(bak_path)

# The pure half of the Vostok Mods adapter; its async operations need a network.
func _t8_vm_pure_surface(ml: Object) -> void:
	begin("T8")
	# /mod/ is singular; the plural path 404s.
	check_eq(ml._vmp_mod_page_url("example"), "https://vostokmods.net/mod/example", "mod page url")
	check_eq(ml._vmp_mod_page_url(""), "", "an empty slug has no page")

	var vrow: Variant = JSON.parse_string("""
	{"id": "v_9", "version": "1.4.0", "fileName": "coolmod-1.4.0.zip",
	 "fileSize": 20480, "createdAt": "2026-08-10T00:00:00.000Z",
	 "downloadUrl": "/api/mods/example/versions/1.4.0/download",
	 "downloadable": true, "scanStatus": "clean"}
	""")
	_assert(vrow is Dictionary, "version fixture parses")
	_fields(ml._vmp_file(vrow), {
		"download_url": "https://vostokmods.net/api/mods/example/versions/1.4.0/download",
		"version": "1.4.0", "filename_hint": "coolmod-1.4.0.zip", "size": 20480,
	})
	_assert(ml._vmp_downloadable(vrow), "a clean version is downloadable")

	# A version the host refuses to serve is not a file: its download would 404.
	var dirty: Variant = JSON.parse_string("""
	{"id": "v_10", "version": "1.5.0", "fileName": "bad.zip", "fileSize": 1,
	 "downloadUrl": "/api/mods/example/versions/1.5.0/download",
	 "downloadable": false, "scanStatus": "flagged"}
	""")
	_assert(not ml._vmp_downloadable(dirty), "a flagged version is not downloadable")
	_assert(not ml._vmp_downloadable(JSON.parse_string('{"version": "x"}')), "no downloadable flag, not downloadable")
	_assert(not ml._vmp_downloadable(null), "null is not downloadable")
	check_eq((ml._vmp_file(JSON.parse_string('{"id": "v_11", "downloadUrl": null}')) as Dictionary)["download_url"], "",
			"a null downloadUrl is empty")

	# A body without `entries` is an error upstream, never an empty listing.
	var listing: Variant = JSON.parse_string("""
	{"entries": [{"id": "019ff204-4d5c-7a17-92b7-f9a6a5a4dc88", "slug": "loot-modifier", "name": "Loot Modifier"},
	             {"id": "019ff1f0-00ac-76a9-a23f-7151e4531131", "slug": "rtvcoop", "name": "RTVCoop"}],
	 "page": 1, "pageCount": 1, "total": 2}
	""")
	_assert(ml._vmp_rows(listing) is Array and (ml._vmp_rows(listing) as Array).size() == 2, "rows come from entries")
	_assert(ml._vmp_rows(JSON.parse_string('{"entries": [], "total": 0}')) is Array, "an empty listing is a listing")
	_assert(ml._vmp_rows(JSON.parse_string('{"mods": [{"slug": "a"}]}')) == null and ml._vmp_rows(JSON.parse_string('{"page": 1}')) == null and ml._vmp_rows(null) == null,
			"a body without entries is not a listing")
	var uuid := "019ff1f0-00ac-76a9-a23f-7151e4531131"
	check_eq(ml._vmp_mod_page_url(uuid), "https://vostokmods.net/mod/" + uuid, "a UUID page url")
	var nofile: Dictionary = ml._host_file_result(ml._vmp_file(JSON.parse_string('{"id": "v_12", "downloadUrl": null}')))
	_assert(not nofile["ok"] and str(nofile["code"]) == ml.HOST_ERR_NO_FILE, "no url resolves to NO_FILE")

	# The detail's date and version are the newest served file's, never a page
	# edit's (updatedAt) or an unscanned upload's.
	var drow: Variant = JSON.parse_string("""
	{"id": "m_4", "slug": "example", "name": "Example",
	 "updatedAt": "2026-10-06T13:32:22.294Z",
	 "versions": [{"id": "v_14", "version": "2.4.0", "scanStatus": "pending", "downloadable": false,
	               "createdAt": "2026-10-01T00:00:00.000Z"},
	              {"id": "v_13", "version": "2.3.2", "scanStatus": "clean", "downloadable": true,
	               "createdAt": "2026-09-25T08:55:42.705Z"}]}
	""")
	var det: Dictionary = ml._vmp_detail_record(drow)
	check_eq(det["updated_at"], "2026-09-25T08:55:42.705Z", "detail updated_at")
	check_eq([det["version"], det["default_file_id"]], ["2.3.2", "v_13"], "detail version and file")
	var det_none: Dictionary = ml._vmp_detail_record(JSON.parse_string(
			'{"slug": "example", "updatedAt": "2026-10-06T13:32:22.294Z", "versions": []}'))
	check_eq(det_none["updated_at"], "", "no served file, no updated_at")

	var cats: Variant = JSON.parse_string("""
	[{"slug": "t", "name": "Tag", "group": {"slug": "tags", "name": "Tags"}},
	 {"slug": "c", "name": "Cat", "group": {"slug": "categories", "name": "Categories"}}]
	""")
	check_eq(ml._vmp_primary_category(cats), "Cat", "the category wins over a tag")
	check_eq(ml._vmp_primary_category(JSON.parse_string("[]")), "", "no taxonomies, no category")
	_assert(str(ml._vmp_group_slug(JSON.parse_string('{"slug": "categories"}'))) == "categories" and str(ml._vmp_group_slug("categories")) == "",
			"a group is an object")

	# Scalars outside the API schema get a request rejected.
	var sc: Dictionary = ml._vmp_scalars()
	check_eq(sc["query_max_len"], 100, "query capped at 100")
	var allowed := ["downloads", "followers", "views", "newest", "updated", "newestFile"]
	_assert((sc["sorts"] as Array).size() > 0, "sorts is not empty")
	for opt: Dictionary in sc["sorts"]:
		_assert(allowed.has(str(opt["key"])), "sort key %s is in the API" % opt["key"])
	for sec: Dictionary in sc["landing_sections"]:
		_assert(allowed.has(str(sec["sort_key"])), "landing sort %s is in the API" % sec["sort_key"])
	# The API's `updated` sort bumps a mod on any page edit.
	var key_by_label := {}
	for opt: Dictionary in sc["sorts"]:
		key_by_label[str(opt["label"])] = str(opt["key"])
	check_eq(key_by_label.get("Recently updated", ""), "newestFile", "Recently updated sort")
	_assert(not key_by_label.values().has("updated"), "the page-edit sort is not offered")

# A capability is a promise the UI acts on, so it must agree with the wiring.
func _t9_caps_match_wiring(ml: Object) -> void:
	begin("T9")
	# A page-URL builder refuses an id of the wrong grammar, so each gets its own.
	var sample := {ml.HOST_MODWORKSHOP: "12345", ml.HOST_VOSTOKMODS: "example-slug"}
	for provider in ml.host_providers():
		_assert(sample.has(provider), "no sample id for " + provider)
		var page := str(ml.host_mod_page_url(ml.host_ref(provider, str(sample.get(provider, "1")))))
		_assert(page != "", "%s builds no page URL" % provider)
		var sorts: Array = ml.host_sorts(provider)
		if not ml.host_caps(provider)["browse"]:
			_assert(sorts.is_empty(), "%s cannot browse but has sorts" % provider)
		_assert(str(ml.host_display_name(provider)) != "", "%s has no display name" % provider)
	# The arms go to the network, so they are read off the source; a missing
	# one falls to the HOST_ERR_UNWIRED default at runtime.
	var source := FileAccess.get_file_as_string(MODLOADER_PATH)
	for provider in ml.host_providers():
		var decl := RegEx.create_from_string("(?m)^const (HOST_[A-Z_]+) := \"%s\"" % provider).search(source)
		var const_name := decl.get_string(1) if decl != null else ""
		_assert(const_name != "", "no HOST_ constant for " + provider)
		for op in ["host_list_mods", "host_get_mod", "host_list_files", "host_resolve_file",
				"host_list_categories", "host_latest_versions", "host_note_rate_headers", "host_caps"]:
			var start := source.find("\nfunc %s(" % op)
			_assert(start >= 0, "dispatcher %s exists" % op)
			var end := source.find("\nfunc ", start + 1)
			var body := source.substr(start, (end if end > start else source.length()) - start)
			_assert(body.contains("\t\t%s:" % const_name), "%s has an arm for %s" % [op, const_name])

func _t20_rate_limit_headers(ml: Object) -> void:
	begin("T20")
	var cooldowns: Dictionary = ml.get("_host_cooldown_until_ms")
	cooldowns.clear()
	ml.host_note_rate_headers("modworkshop", 200, PackedStringArray(["X-RateLimit-Remaining: 12"]))
	check_eq(ml.host_rate_cooldown_seconds("modworkshop"), 0, "a 2xx with budget arms nothing")
	ml.host_note_rate_headers("modworkshop", 429, PackedStringArray(["Retry-After: 30"]))
	var secs := int(ml.host_rate_cooldown_seconds("modworkshop"))
	_assert(secs >= 29 and secs <= 30, "Retry-After seconds honored (got %d)" % secs)
	cooldowns.clear()
	ml.host_note_rate_headers("modworkshop", 429, PackedStringArray(["Retry-After: Wed, 21 Oct 2026 07:28:00 GMT"]))
	secs = int(ml.host_rate_cooldown_seconds("modworkshop"))
	_assert(secs >= 59 and secs <= 60, "HTTP-date Retry-After uses the default (got %d)" % secs)
	cooldowns.clear()
	ml.host_note_rate_headers("vostokmods", 429, PackedStringArray())
	secs = int(ml.host_rate_cooldown_seconds("vostokmods"))
	_assert(secs >= 59 and secs <= 60, "a bare 429 arms the default (got %d)" % secs)
	check_eq(ml.host_rate_cooldown_seconds("modworkshop"), 0, "the other host stays clear")
	cooldowns.clear()

func _t21_mws_list_params(ml: Object) -> void:
	begin("T21")
	_assert(ml.has_method("_mwsp_list_params"), "the loader has _mwsp_list_params")
	for c in [
		[{}, 1, "?sort=bumped_at&limit=50&page=1", "empty query"],
		[{"sort_key": "weekly_score", "limit": 10}, 1, "?sort=weekly_score&limit=10&page=1", "landing section limit"],
		[{"limit": 500}, 3, "?sort=bumped_at&limit=50&page=3", "limit clamped to the cap"],
		[{"query": "night vision", "category_ref": "12"}, 1,
				"?query=night%20vision&sort=bumped_at&limit=50&page=1&category_id=12", "query and category"],
	]:
		check_eq(ml._hnet_query(ml._mwsp_list_params(c[0], c[1])), c[2], c[3])

func _t25_version_ordering(ml: Object) -> void:
	begin("T25")
	var cases := [
		["1.0.0", "1.0.0", 0], ["1.2", "1.10", -1], ["v2.0", "1.9.9", 1], ["1.0", "1.0.0", 0],
		["1.0.0-beta.1", "1.0.0", -1], ["1.0.0", "1.0.0-rc.2", 1],
		["1.0.0-beta.2", "1.0.0-beta.10", -1], ["1.0.0-alpha", "1.0.0-beta", -1],
		["1.0.1-beta.1", "1.0.0", 1], ["1.0.0+build.5", "1.0.0", 0],
		["", "1.0", -1], ["1.0", "", 1], ["", "", 0],
		# A letter stuck to the last number is a later build of that number.
		["1.0.0b", "1.0.0", 1], ["1.0.1", "1.0.1b", -1], ["1.0b", "1.0c", -1], ["1.0.0b", "1.0.0b", 0],
		["1.0.0b", "1.0.1", -1], ["2", "2.0", 0],
		# A prerelease word stuck to the number ranks below it, like "-rc1".
		["1.2rc1", "1.2", -1], ["1.2beta", "1.2", -1], ["1.2pre2", "1.2", -1], ["1.2dev", "1.2", -1],
		["1.2rc1", "1.2rc2", -1], ["1.2alpha", "1.2beta", -1], ["1.2rc1", "1.2b", -1],
		# The number after a tail's letters is a number, not text.
		["1.0.0b10", "1.0.0b9", 1], ["1.2rc10", "1.2rc9", 1], ["1.0.0b", "1.0.0b1", -1],
	]
	for c in cases:
		check_eq(ml.compare_versions(c[0], c[1]), c[2], "compare_versions(%s, %s)" % [c[0], c[1]])
	var pending := [{"profile_key": "m@1.0.0-beta.1", "ref": ml.host_ref("vostokmods", "m"), "version": "1.0.0-beta.1",
		"full_path": "", "mod_name": "M"}]
	var summary: Dictionary = ml._updates_check_apply(pending, {"vostokmods:m": "1.0.0"})
	check_eq(summary["with_updates"], 1, "a release updates its prerelease")
	(ml.get("_mod_updates_state") as Dictionary).erase("m@1.0.0-beta.1")

# The loader is listed on both sites, but Download in Browse would mount its
# zip over res://modloader.gd as a broken mod.
func _t32_browse_hides_own_listing(ml: Object) -> void:
	begin("T32")
	var own: Dictionary = ml.HOST_OWN_LISTINGS
	_assert(str(own.get(ml.HOST_VOSTOKMODS, "")) == "metro-mod-loader" and str(own.get(ml.HOST_MODWORKSHOP, "")) == "55623",
			"both listings are named (got %s)" % str(own))
	var rows_of := func(provider: String, ids: Array) -> Array:
		var rows := []
		for id in ids:
			var row: Dictionary = ml.host_empty_summary()
			row["ref"] = ml.host_ref(provider, id)
			row["name"] = id
			rows.append(row)
		return rows
	var names_of := func(rows: Array) -> PackedStringArray:
		var names := PackedStringArray()
		for r: Dictionary in rows:
			names.append(str(r["name"]))
		return names
	for provider: String in own:
		var page: Dictionary = ml.host_page(rows_of.call(provider, ["some-mod", own[provider], "another-mod"]), true, "2", 3)
		var shown: Dictionary = ml._host_hide_own_listing(provider, ml.host_ok(page))["data"]
		check_eq(names_of.call(shown["rows"]), PackedStringArray(["some-mod", "another-mod"]), provider + " rows")
		_assert(shown["has_more"] and str(shown["next_cursor"]) == "2", "paging survives on " + provider)
	var other: Array = rows_of.call(ml.HOST_MODWORKSHOP, ["metro-mod-loader"])
	var kept: Dictionary = ml._host_hide_own_listing(ml.HOST_MODWORKSHOP, ml.host_ok(ml.host_page(other, false, "", 1)))
	check_eq((kept["data"]["rows"] as Array).size(), 1, "the id is matched per host")
	var failed: Dictionary = ml.host_err(ml.HOST_ERR_BAD_RESPONSE, 0, "x")
	check_eq(ml._host_hide_own_listing(ml.HOST_VOSTOKMODS, failed), failed, "an error passes through")
	# An offline landing saved by a build that did not filter yet holds the row.
	var snapshots: Dictionary = ml.get("_browse_landing_snapshots")
	for provider: String in own:
		var snap_path := str(ml._browse_landing_snapshot_path(provider))
		var saved := {"sections": [{"title": "Popular", "rows": rows_of.call(provider, ["some-mod", own[provider]])}],
			"saved_at_unix": 1700000000}
		H.write_text(snap_path, JSON.stringify(saved))
		snapshots.erase(provider)
		var snap: Dictionary = ml._browse_landing_snapshot(provider)
		var saved_names := PackedStringArray()
		for sec: Dictionary in snap.get("sections", []):
			saved_names.append_array(names_of.call(sec["rows"]))
		check_eq(saved_names, PackedStringArray(["some-mod"]), "saved %s landing rows" % provider)
		check_eq(int(snap.get("saved_at_unix", 0)), 1700000000, "saved %s landing timestamp" % provider)
		snapshots.erase(provider)
		H.remove_user_file(snap_path)

# A mod.txt carries the Vostok Mods UUID while Browse rows carry the slug, so the
# install map answers under both once the detail resolved the UUID.
func _t33_install_map_keys_both_ids(ml: Object) -> void:
	begin("T33")
	H.pack_cleanup(ml)
	var uuid := "019ff1f0-00ac-76a9-a23f-7151e4531131"
	var cfg := ConfigFile.new()
	cfg.set_value("mod", "version", "5.0.0")
	cfg.set_value("updates", "source", "vostokmods:" + uuid)
	var entry := H.mod_entry("rtvcoop@5.0.0", "rtvcoop", "5.0.0", {"cfg": cfg})
	var installed: Array[Dictionary] = [entry]
	ml.set("_ui_mod_entries", installed)
	var memo: Dictionary = ml.get("_mods_meta_by_key")
	memo.clear()
	var map: Dictionary = ml._browse_install_map()
	_assert(map.has("vostokmods:" + uuid) and not map.has("vostokmods:rtvcoop"),
			"only the UUID key at first (got %s)" % str(map.keys()))
	var detail: Dictionary = ml.host_empty_detail()
	detail["ref"] = ml.host_ref("vostokmods", "rtvcoop")
	memo["vostokmods:" + uuid] = detail
	map = ml._browse_install_map()
	_assert(map.has("vostokmods:" + uuid) and map.has("vostokmods:rtvcoop") and map["vostokmods:rtvcoop"] == entry,
			"both keys after the detail (got %s)" % str(map.keys()))
	memo.clear()
	H.pack_cleanup(ml)

# Godot's WebP loader refuses an animated file, so the decoder rewraps the first
# frame as a still. The second frame is blue: blue means the wrong frame.
func _t34_animated_webp_first_frame(ml: Object) -> void:
	begin("T34")
	var full := Vector2i(48, 32)
	var red := Image.create_empty(48, 32, false, Image.FORMAT_RGB8)
	red.fill(Color(1, 0, 0))
	var blue := Image.create_empty(48, 32, false, Image.FORMAT_RGB8)
	blue.fill(Color(0, 0, 1))
	var blue_frame := {"chunks": _webp_frame_chunks(blue.save_webp_to_buffer(true, 0.9)), "offset": Vector2i.ZERO, "size": full}

	var still: Image = ml._decode_image_buffer(red.save_webp_to_buffer(true, 0.9))
	_assert(still != null and still.get_size() == full, "a still lossy WebP decodes")

	var lossy := _animated_webp(full, [{"chunks": _webp_frame_chunks(red.save_webp_to_buffer(true, 0.9)),
			"offset": Vector2i.ZERO, "size": full}, blue_frame])
	var img: Image = ml._decode_image_buffer(lossy)
	_assert(img != null and img.get_size() == full and _near(img.get_pixel(24, 16), Color(1, 0, 0)),
			"lossy first frame is red (got %s)" % _describe(img, Vector2i(24, 16)))

	var half := Image.create_empty(48, 32, false, Image.FORMAT_RGBA8)
	half.fill_rect(Rect2i(0, 0, 24, 32), Color(0, 1, 0, 1))
	var alpha_still := half.save_webp_to_buffer(true, 0.9)
	_assert(alpha_still.slice(12, 16).get_string_from_ascii() == "VP8X" and ml._decode_image_buffer(alpha_still) != null,
			"a still with alpha is not animated")
	img = ml._decode_image_buffer(_animated_webp(full, [{"chunks": _webp_frame_chunks(alpha_still),
			"offset": Vector2i.ZERO, "size": full}, blue_frame]))
	_assert(img != null and _near(img.get_pixel(8, 16), Color(0, 1, 0)) and img.get_pixel(40, 16).a < 0.1,
			"lossy frame keeps ALPH (got %s / %s)" % [_describe(img, Vector2i(8, 16)), _describe(img, Vector2i(40, 16))])

	img = ml._decode_image_buffer(_animated_webp(full, [{"chunks": _webp_frame_chunks(red.save_webp_to_buffer(false)),
			"offset": Vector2i.ZERO, "size": full}, blue_frame]))
	_assert(img != null and img.get_pixel(24, 16).is_equal_approx(Color(1, 0, 0)),
			"lossless first frame is red (got %s)" % _describe(img, Vector2i(24, 16)))

	var small := Image.create_empty(32, 32, false, Image.FORMAT_RGB8)
	small.fill(Color(1, 0, 0))
	img = ml._decode_image_buffer(_animated_webp(Vector2i(64, 64), [{"chunks": _webp_frame_chunks(small.save_webp_to_buffer(false)),
			"offset": Vector2i(16, 16), "size": Vector2i(32, 32)}, blue_frame]))
	_assert(img != null and img.get_size() == Vector2i(64, 64) and img.get_pixel(4, 4).a == 0.0
			and img.get_pixel(32, 32).is_equal_approx(Color(1, 0, 0)),
			"small frame sits at its offset (got %s / %s)" % [_describe(img, Vector2i(4, 4)), _describe(img, Vector2i(32, 32))])

	_assert(ml._decode_image_buffer(lossy.slice(0, 60)) == null, "a truncated animated WebP is null")

func _near(c: Color, want: Color) -> bool:
	return absf(c.r - want.r) < 0.1 and absf(c.g - want.g) < 0.1 and absf(c.b - want.b) < 0.1 and c.a > 0.9

func _describe(img: Image, at: Vector2i) -> String:
	if img == null:
		return "null"
	return "%s, %s at %s" % [str(img.get_size()), str(img.get_pixelv(at)), str(at)]

# The ALPH and bitstream chunks of a still WebP, padding included: what an
# ANMF frame carries after its 16-byte header.
func _webp_frame_chunks(still: PackedByteArray) -> PackedByteArray:
	var out := PackedByteArray()
	var pos := 12
	while pos + 8 <= still.size():
		var chunk_size := still.decode_u32(pos + 4)
		var next := pos + 8 + chunk_size + (chunk_size & 1)
		if still.slice(pos, pos + 4).get_string_from_ascii() in ["ALPH", "VP8 ", "VP8L"]:
			out.append_array(still.slice(pos, next))
		pos = next
	return out

# VP8X with the animation and alpha flags, ANIM, then one ANMF per {chunks, offset, size}.
func _animated_webp(canvas: Vector2i, frames: Array) -> PackedByteArray:
	var body := "WEBP".to_ascii_buffer()
	body.append_array(_riff_chunk("VP8X", PackedByteArray([0x12, 0, 0, 0]) + H.uint_le(canvas.x - 1, 3) + H.uint_le(canvas.y - 1, 3)))
	body.append_array(_riff_chunk("ANIM", PackedByteArray([0, 0, 0, 0, 0, 0])))
	for f in frames:
		var off: Vector2i = f["offset"]
		var sz: Vector2i = f["size"]
		var payload := PackedByteArray()
		for v in [off.x >> 1, off.y >> 1, sz.x - 1, sz.y - 1, 100]:
			payload.append_array(H.uint_le(v, 3))
		payload.append(0)
		payload.append_array(f["chunks"])
		body.append_array(_riff_chunk("ANMF", payload))
	return _riff_chunk("RIFF", body)

func _riff_chunk(tag: String, payload: PackedByteArray) -> PackedByteArray:
	var out := tag.to_ascii_buffer()
	out.append_array(H.uint_le(payload.size()))
	out.append_array(payload)
	if payload.size() % 2 == 1:
		out.append(0)
	return out

# Callers branch on the code; the transport itself needs a live request.
func _t35_status_error_mapping(ml: Object) -> void:
	begin("T35")
	_assert(ml.has_method("_hnet_status_error"), "the loader has _hnet_status_error")
	for c in [[401, "auth"], [403, "auth"], [404, "not_found"], [429, "rate_limited"], [500, "server"], [503, "server"],
			[400, "client"], [422, "client"], [302, "client"], [100, "client"]]:
		var err: Dictionary = ml._hnet_status_error(c[0])
		check_eq([err.get("ok", true), err.get("code", ""), err.get("http", 0)], [false, c[1], c[0]], "status %d" % c[0])
	check_eq((ml._hnet_status_error(422) as Dictionary).get("message", ""), "unexpected response 422", "an unnamed status is named")
	for ok_status in [200, 204, 299]:
		check_eq(ml._hnet_status_error(ok_status), {}, "%d is not a failure" % ok_status)

# A pinned version the host has not scanned yet is a wait, not a missing file.
func _t36_resolve_failure_copy(ml: Object) -> void:
	begin("T36")
	(ml.get("_host_cooldown_until_ms") as Dictionary).clear()
	var vm := str(ml.HOST_VOSTOKMODS)
	var scan_copy := "This version has not passed Vostok Mods's malware scan, so it cannot be downloaded yet."
	var unscanned: Dictionary = ml.host_err(ml.HOST_ERR_NOT_SCANNED, 0, "version 1.2 has not passed the host's malware scan")
	check_eq(ml._download_resolve_failure_copy(vm, unscanned, "1.2"), scan_copy, "an unscanned version says so")
	check_eq(ml._download_resolve_failure_copy(vm, ml.host_err(ml.HOST_ERR_NOT_SCANNED, 0, ""), "1.2"), scan_copy,
			"the code alone selects it")
	var nothing := str(ml._download_resolve_failure_copy(vm, ml._host_no_file(), ""))
	_assert(nothing.contains("no downloadable file") and not nothing.contains("scan"), "nothing to serve says so (got %s)" % nothing)
	check_eq(ml._download_resolve_failure_copy(vm, ml.host_err(ml.HOST_ERR_NO_FILE, 0, "not scanned"), ""), nothing,
			"no-file stays no-file")
	var got := str(ml.host_error_message(vm, unscanned))
	_assert(got.contains("malware scan") and got.contains("Vostok Mods"), "the shared copy names the scan (got %s)" % got)

func _stub_net() -> Object:
	var script := GDScript.new()
	script.source_code = STUB_NET_SRC
	script.reload()
	var net: Object = script.new()
	net._compile_regex()
	return net

func _serve(net: Object, url: String, body: Variant) -> void:
	(net.get("asked") as Array).clear()
	var replies: Dictionary = net.get("replies")
	replies.clear()
	replies[url] = net.host_ok(body)

# Live headers are lowercase ints and the window is about a second, so a
# spent budget waits inside the call instead of failing for a minute.
func _t37_vm_rate_headers(ml: Object) -> void:
	begin("T37")
	var cooldowns: Dictionary = ml.get("_host_cooldown_until_ms")
	var vm := str(ml.HOST_VOSTOKMODS)
	for c in [
		[200, ["ratelimit-limit: 90", "ratelimit-remaining: 89", "ratelimit-reset: 1"], 0, 0, "2xx with budget"],
		[200, ["ratelimit-remaining: 0", "ratelimit-reset: 1"], 1, 1, "2xx spent budget"],
		[429, ["ratelimit-remaining: 0", "ratelimit-reset: 3"], 2, 3, "429 with reset 3"],
		[429, ["ratelimit-reset: 0"], 1, 1, "429 with reset 0"],
		[429, [], 59, 60, "bare 429"],
		[429, ["ratelimit-reset: 120"], 119, 120, "429 with reset 120"],
		[429, ["ratelimit-reset: 1762200000"], 59, 60, "429 with an epoch reset"],
		[200, ["ratelimit-remaining: 0", "ratelimit-reset: 121"], 59, 60, "spent budget, reset 121"],
	]:
		cooldowns.clear()
		ml.host_note_rate_headers(vm, c[0], PackedStringArray(c[1]))
		var secs := int(ml.host_rate_cooldown_seconds(vm))
		_assert(secs >= c[2] and secs <= c[3], "%s arms %d-%ds (got %d)" % [c[4], c[2], c[3], secs])
	cooldowns.clear()
	ml.host_note_rate_headers(vm, 200, PackedStringArray(["ratelimit-remaining: 0", "ratelimit-reset: 1"]))
	_assert(int(ml._cooldown_ms(vm)) <= int(ml._HOST_RATE_WAIT_MAX_MS), "a spent budget is waited out")
	check_eq(ml.host_rate_cooldown_seconds("modworkshop"), 0, "ModWorkshop stays clear")
	cooldowns.clear()
	ml.host_note_rate_headers("modworkshop", 200, PackedStringArray(["ratelimit-remaining: 0", "ratelimit-reset: 1"]))
	check_eq(ml.host_rate_cooldown_seconds("modworkshop"), 0, "ModWorkshop ignores ratelimit-*")
	cooldowns.clear()

func _t38_vm_categories_for_mods(net: Object) -> void:
	begin("T38")
	var url := str(net.VM_API_BASE) + "/taxonomies"
	_serve(net, url, JSON.parse_string("""
	[{"slug": "weapons", "name": "Weapons", "group": {"slug": "categories"}, "contentTypes": ["mod"]},
	 {"slug": "kitchen-sink", "name": "Kitchen Sink", "group": {"slug": "categories"}, "contentTypes": ["modpack"]},
	 {"slug": "qol", "name": "QoL", "group": {"slug": "tags"}, "contentTypes": ["mod", "modpack"]},
	 {"slug": "no-types", "name": "No types", "group": {"slug": "tags"}},
	 {"slug": "", "name": "No slug", "group": {"slug": "tags"}, "contentTypes": ["mod"]}]
	"""))
	var res: Dictionary = await net._vmp_list_categories()
	_assert(res["ok"], "taxonomies list reads")
	var got := []
	for c: Dictionary in res.get("data", []):
		got.append([c["id"], c["name"], c["parent_id"]])
	check_eq(got, [["weapons", "Weapons", "categories"], ["qol", "QoL", "tags"], ["no-types", "No types", "tags"]],
			"mod taxonomies only, untyped rows kept")
	check_eq(net.get("asked"), [[url, int(net._VM_TTL_CATEGORIES_MS)]], "one cached request")

func _t39_vm_download_host_guard(ml: Object) -> void:
	begin("T39")
	var site := "https://vostokmods.net/api/mods/a/versions/1/download"
	for c in [
		["/api/mods/a/versions/1/download", site],
		["api/mods/a/versions/1/download", site],
		[site, site],
		["https://www.vostokmods.net/api/x", "https://www.vostokmods.net/api/x"],
		["HTTPS://VostokMods.net:443/api/x", ""],
		["https://evil.example/api/mods/a.zip", ""],
		["http://vostokmods.net.evil.example/a.zip", ""],
		["https://vostokmods.net@evil.example/a.zip", ""],
		["https://evil.example?vostokmods.net/a.zip", ""],
	]:
		var f: Dictionary = ml._vmp_file({"id": "v", "version": "1", "downloadUrl": c[0]})
		check_eq(f["download_url"], c[1], "download url of " + c[0])
	var foreign: Dictionary = ml._host_file_result(ml._vmp_file({"id": "v", "downloadUrl": "https://evil.example/a.zip"}))
	_assert(not foreign["ok"] and str(foreign["code"]) == ml.HOST_ERR_NO_FILE, "a foreign URL is no file")

# A hidden screenshot is not the banner; with none visible the cover is.
func _t40_vm_banner(ml: Object) -> void:
	begin("T40")
	var cover := "https://files.vostokmods.net/c.png"
	for c in [
		[[{"url": "https://x/hidden.png", "hidden": true}, {"url": "https://x/shown.png", "hidden": false,
				"isThumbnail": true}], cover, "https://x/shown.png", "first visible shot"],
		[[{"url": "https://x/a.png"}], cover, "https://x/a.png", "no hidden flag is visible"],
		[[{"url": "https://x/hidden.png", "hidden": true}], cover, cover, "all hidden, cover"],
		[[], cover, cover, "no shots, cover"],
		[null, null, "", "nothing, no banner"],
	]:
		var det: Dictionary = ml._vmp_detail_record({"slug": "m", "screenshots": c[0], "thumbnailUrl": c[1]})
		check_eq(det["banner"]["url"], c[2], c[3])

func _t41_vm_pack_summary(ml: Object) -> void:
	begin("T41")
	var s: Dictionary = ml._vmp_modpack_summary(JSON.parse_string(VM_PACK_LIVE_JSON))
	for k in (ml.host_empty_summary() as Dictionary).keys():
		_assert(s.has(k), "pack summary has " + k)
	check_eq(ml.host_ref_key(s["ref"]), "vostokmods:jonis-pack", "pack ref is the slug")
	_fields(s, {
		"kind": "modpack", "slug": "jonis-pack", "name": "Joni's Pack",
		"short_description": "Everything.", "author_name": "Joni", "mod_count": 31,
		"downloads": 91, "views": 721, "likes": -1, "category_name": "Kitchen Sink",
		"thumbnail.url": "https://files.vostokmods.net/packs/1/cover.webp",
		"thumbnail.cache_key": "url_" + "https://files.vostokmods.net/packs/1/cover.webp".sha256_text().left(32),
		"updated_at": "2026-10-31T22:10:00.000Z", "published_at": "2026-10-01T00:00:00.000Z",
		"manifest_url": "https://vostokmods.net/api/modpacks/jonis-pack/manifest",
		"page_url": "https://vostokmods.net/modpack/jonis-pack",
	})
	var n: Dictionary = ml._vmp_modpack_summary(JSON.parse_string(
			'{"slug": "bare", "thumbnailUrl": null, "downloadsCount": null, "taxonomies": null}'))
	_fields(n, {"thumbnail.url": "", "thumbnail.cache_key": "", "downloads": -1, "views": -1, "category_name": "",
		"name": "bare", "kind": "modpack"})
	for k in ["summary", "author", "thumbnail_url"]:
		_assert(not s.has(k), "no duplicate key " + k)
	for c in [["HTTPS://x/c.png", "HTTPS://x/c.png", "an upper-case https cover"], ["http://x/c.png", "", "an http cover"],
			["file:///c.png", "", "a file cover"]]:
		var row: Dictionary = ml._vmp_modpack_summary({"slug": "c", "thumbnailUrl": c[0]})
		check_eq(row["thumbnail"]["url"], c[1], c[2])
	_assert(not ml.host_ref_valid(ml._vmp_modpack_summary({"name": "x"})["ref"]), "a slugless pack has no ref")

func _t42_vm_pack_listing(net: Object) -> void:
	begin("T42")
	var keys := []
	for opt: Dictionary in net._VM_PACK_SORTS:
		keys.append(opt["key"])
	check_eq(keys, ["updated", "newest", "downloads", "views"], "pack sort keys")
	var base := str(net.VM_API_BASE) + "/modpacks"
	var url := base + "?page=2&limit=20&q=joni&sort=downloads"
	_serve(net, url, JSON.parse_string('{"entries": [' + VM_PACK_LIVE_JSON + '], "total": 21, "page": 2, "pageCount": 2}'))
	var res: Dictionary = await net._vmp_list_modpacks({"query": " joni ", "sort": "downloads", "cursor": "2"})
	check_eq(net.get("asked"), [[url, int(net._VM_TTL_LIST_MS)]], "listing request")
	_assert(res["ok"] and (res["data"]["rows"] as Array).size() == 1, "one row read")
	_assert(int(res["data"]["total"]) == 21 and not res["data"]["has_more"], "last page, total kept")
	_assert(str(res["data"]["rows"][0]["kind"]) == "modpack", "rows are pack summaries")
	_serve(net, base + "?page=1&limit=20", JSON.parse_string('{"entries": [], "total": 0, "page": 1, "pageCount": 0}'))
	await net._vmp_list_modpacks({"sort": "name"})
	check_eq(net.get("asked"), [[base + "?page=1&limit=20", int(net._VM_TTL_LIST_MS)]], "a dead sort is not sent")

func _t43_vm_pack_detail(net: Object) -> void:
	begin("T43")
	var url := str(net.VM_API_BASE) + "/modpacks/jonis-pack"
	var body: Dictionary = JSON.parse_string(VM_PACK_DETAIL_JSON)
	_serve(net, url, body)
	var res: Dictionary = await net._vmp_modpack_detail("jonis-pack")
	check_eq(net.get("asked"), [[url, int(net._VM_TTL_DETAIL_MS)]], "one detail request")
	_assert(res["ok"], "pack detail reads")
	var d: Dictionary = res.get("data", {})
	_fields(d, {"kind": "modpack", "slug": "jonis-pack", "mod_count": 31, "author_name": "Joni", "downloads": 91,
		"category_name": "Kitchen Sink", "banner.url": "https://files.vostokmods.net/packs/1/cover.webp",
		"thumbnail.url": "https://files.vostokmods.net/packs/1/cover.webp",
		"manifest_url": "https://vostokmods.net/api/modpacks/jonis-pack/manifest"})
	_assert(str(d["description"]).contains("[b]mod[/b]"), "description is BBCode")
	_assert(not d.has("mods"), "the mod list is the manifest's")
	body["screenshots"] = [{"id": "s3", "url": "https://x/s.png", "hidden": false, "isThumbnail": false}]
	_serve(net, url, body)
	check_eq((await net._vmp_modpack_detail("jonis-pack"))["data"]["banner"]["url"], "https://x/s.png",
			"first visible shot is the banner")
	body["screenshots"] = [{"id": "s4", "url": "http://x/s.png", "hidden": false}]
	_serve(net, url, body)
	check_eq((await net._vmp_modpack_detail("jonis-pack"))["data"]["banner"]["url"], "", "an http banner is dropped")
	body.erase("description")
	body.erase("screenshots")
	_serve(net, url, body)
	d = (await net._vmp_modpack_detail("jonis-pack"))["data"]
	check_eq([d["description"], d["banner"]["url"]], ["", "https://files.vostokmods.net/packs/1/cover.webp"],
			"no description, cover banner")
	for bad in [[], {"modpack": {"slug": "jonis-pack"}}]:
		_serve(net, url, bad)
		var r: Dictionary = await net._vmp_modpack_detail("jonis-pack")
		_assert(not r["ok"] and str(r["code"]) == net.HOST_ERR_BAD_RESPONSE, "unknown shape is an error")
	_serve(net, url, body)
	for slug in ["", "../x"]:
		_assert(not (await net._vmp_modpack_detail(slug))["ok"], "bad slug refused: " + slug)
	check_eq(net.get("asked"), [], "a bad slug sends nothing")

	var rows: Array = net._vmp_modpack_mods(JSON.parse_string(VM_MANIFEST_LIVE_JSON))
	var got := []
	for r: Dictionary in rows:
		got.append([r["slug"], r["name"], r["version"], r["available"], r["reason"], r["page_url"]])
	check_eq(got, [
		["hk-g28", "HK G28", "1.2.0", true, "", "https://vostokmods.net/mod/hk-g28"],
		["gone", "Gone", "", false, "removed", "https://vostokmods.net/mod/gone"],
		["nameless", "nameless", "2.0", true, "", "https://vostokmods.net/mod/nameless"],
	], "pack mods in loadOrder")
	check_eq(net._vmp_modpack_mods({"mods": "x"}), [], "no mod list, no rows")

# A manifest naming another pack would write or replace that pack's file.
func _t44_vm_manifest_slug_guard(net: Object) -> void:
	begin("T44")
	var url := str(net._vmp_manifest_url_for_slug("jonis-pack"))
	var m: Dictionary = JSON.parse_string(VM_MANIFEST_LIVE_JSON)
	_serve(net, url, m)
	var ok: Dictionary = await net._vmp_fetch_modpack_manifest(url)
	_assert(ok["ok"] and str(ok["data"]["manifest_url"]) == url, "the asked pack imports")
	check_eq(net.get("asked"), [[url, 0]], "manifest is never cached")
	m["slug"] = "other-pack"
	_serve(net, url, m)
	var bad: Dictionary = await net._vmp_fetch_modpack_manifest(url)
	_assert(not bad["ok"] and str(bad["code"]) == net.HOST_ERR_BAD_RESPONSE, "another pack's manifest fails")
	var why := str(bad.get("message", ""))
	_assert(why.contains("other-pack") and not why.contains(". "), "one sentence naming it: " + why)

# One predicate for fetches and the Open page button: https, the site's two hosts, no port or userinfo.
func _t45_vm_site_url_predicate(ml: Object) -> void:
	begin("T45")
	for c in [
		["https://vostokmods.net/modpack/x", true], ["https://www.vostokmods.net/mod/x", true],
		["HTTPS://VostokMods.net/api/x", true], ["https://vostokmods.net", true],
		["http://vostokmods.net/modpack/x", false], ["https://vostokmods.net:443/x", false],
		["https://vostokmods.net:8080/x", false], ["https://user@vostokmods.net/x", false],
		["https://vostokmods.net@evil.example/x", false], ["https://vostokmods.net.evil/x", false],
		["https://files.vostokmods.net/x", false], ["https://evil.example/x", false],
		["vostokmods.net/modpack/x", false], ["", false],
	]:
		check_eq(ml._vmp_is_site_url(c[0]), c[1], "site url: " + c[0])
		if str(c[0]).contains("://"):
			check_eq(ml._vmp_site_url(c[0]), c[0] if c[1] else "", "fetch url: " + c[0])

# The author's primary file wins over the semver-latest one.
func _t46_mws_primary_file_first(net: Object) -> void:
	begin("T46")
	var ref: Dictionary = net.host_ref(net.HOST_MODWORKSHOP, "55623")
	var base := str(net._mwsp_mod_url(ref)) + "/files"
	var replies: Dictionary = net.get("replies")
	for c in [
		[{"/primary": net.host_ok({"id": 2, "version": "2.0", "download_url": "https://x/2.zip"}),
			"/latest": net.host_ok({"id": 1, "version": "1.0", "download_url": "https://x/1.zip"})},
			true, "2.0", ["/primary"], "primary beats latest"],
		[{"/latest": net.host_ok({"id": 1, "version": "1.0", "download_url": "https://x/1.zip"})},
			true, "1.0", ["/primary", "/latest"], "no primary, latest"],
		[{"/primary": net.host_err(net.HOST_ERR_SERVER, 500, "down"),
			"/latest": net.host_ok({"id": 1, "version": "1.0", "download_url": "https://x/1.zip"})},
			false, "", ["/primary"], "a 500 stops the walk"],
	]:
		(net.get("asked") as Array).clear()
		replies.clear()
		for tail: String in c[0]:
			replies[base + tail] = c[0][tail]
		var res: Dictionary = await net._mwsp_resolve_file(ref, "")
		var urls := []
		for a: Array in net.get("asked"):
			urls.append(str(a[0]).trim_prefix(base))
		check_eq([res["ok"], str(res.get("data", {}).get("version", "")) if res["ok"] else "", urls],
				[c[1], c[2], c[3]], c[4])

# The installed version itself is never an update.
func _t47_loader_update_prompt(net: Object) -> void:
	begin("T47")
	var url := str(net.MODLOADER_RELEASES_API_URL) % str(net.MODLOADER_GITHUB_REPO)
	var mine := str(net.MODLOADER_VERSION)
	for c in [[mine, false], ["v" + mine, false], [mine + "-beta.1", false], ["0.0.1", false],
			["99.0.0", true], ["v99.0.0", true]]:
		(net.get("shown") as Array).clear()
		_serve(net, url, {"tag_name": c[0], "html_url": "https://github.com/x/y/releases/tag/1"})
		await net._check_modloader_update_async()
		check_eq((net.get("shown") as Array).size() == 1, c[1], "update prompt for " + c[0])

# Only a 64-hex sha256 is pinned, lower-cased.
func _t48_pack_sha_pins(ml: Object) -> void:
	begin("T48")
	var good := "AB".repeat(32)
	var mods := []
	for sha in ["abc", good + "0", good, "", null]:
		mods.append({"slug": "m%d" % mods.size(), "available": true, "version": "1", "sha256": sha})
	var conv: Dictionary = ml._hosted_manifest_to_profile({"slug": "p", "mods": mods})
	check_eq(conv["profile"].get("checksums", {}), {str(ml.HOSTED_KEY_PREFIX) + "m2": good.to_lower()}, "only the 64-char sha pinned")
