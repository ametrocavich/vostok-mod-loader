## runner.gd -- host-seam + on-disk source-format harness. NOT part of the
## shipped loader. Executed by check_host.sh inside a THROWAWAY Godot project
## assembled under the system temp dir; never run it against this repo or
## against the Road to Vostok install.
##
## WHY THIS EXISTS: the host-provider seam (host_types.gd + one adapter per
## host) and the provider-qualified source format shipped with zero coverage,
## and every guarantee below is a contract some caller already leans on:
##   - normalizers emit EVERY field with its declared type, missing data as
##     sentinels ("" / -1), never absent keys -- the rule that lets the UI
##     stop shape-checking remote JSON at every read site;
##   - the "provider:id" grammar REJECTS rather than guesses: a bare number
##     defaulted to ModWorkshop downloads a stranger's upload;
##   - source records of every era converge to one stable serialization in a
##     single pass, so mod_config.cfg is not rewritten on every scan;
##   - the legacy modworkshop_id mirror is emitted IFF provider ==
##     modworkshop. profile.json is mailed between users, and a mirrored id
##     on a non-ModWorkshop record makes a pre-source loader download
##     whatever mod owns that number on ModWorkshop.
##
## WHAT THIS PROVES, AND WHAT IT DOES NOT:
##   PROVES  -- the pure translation layer: host payload -> summary record,
##              era record -> canonical record -> serialized cache value,
##              the result envelope, and the provider:id grammar.
##   DOES NOT PROVE -- anything about live HTTP: no request is made, so
##              endpoint URLs, rate-limit dialects and the shapes REAL hosts
##              send today are out of scope. The fixture rows are the ones
##              captured in the adapters' own documentation, so a host that
##              has since changed its payload is invisible here.
##
## No network, no RTV corpus, so it runs on any machine and can NEVER skip.
extends SceneTree

const MODLOADER_PATH := "res://modloader_neutered.gd"

var _failures: PackedStringArray = []
var _assertions := 0
# Set by _finish. _run awaits coroutines that must complete without
# suspending; if one suspends, the main loop would end with exit code 0 and
# no verdict, so the guard below turns that into a failure.
var _done := false

func _init() -> void:
	print("[host] harness start")

func _process(_delta: float) -> bool:
	_run()
	if not _done:
		printerr("[host] FAIL: the run suspended on an await and never reached _finish")
		quit(1)
	return true

func _run() -> void:
	var ml_script := load(MODLOADER_PATH) as GDScript
	if ml_script == null:
		_fail("could not load " + MODLOADER_PATH)
		_finish()
		return
	var ml: Object = ml_script.new()
	# Same guard the codegen/detok harnesses use: prove the boot static-init
	# really was neutralized before we touch anything on this instance.
	var mounted: Variant = ml.get("_filescope_mounted")
	if typeof(mounted) != TYPE_DICTIONARY or not (mounted as Dictionary).is_empty():
		_fail("modloader boot static-init was NOT neutralized -- refusing to run")
		_finish()
		return

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
	_t10_hosted_modpacks(ml)
	_t13_update_check_rules(ml)
	_t14_modpack_source_installed(ml)
	_t15_warnings_and_author_notes(ml)
	await _t12_apply_failure_shape(ml)
	await _t16_unload_leaves_no_pack_mcm_behind(ml)
	await _t17_pack_keys_follow_the_installed_mods(ml)
	await _t18_refreshed_pack_rebuilds_its_slot(ml)
	_t19_apply_preview_is_read_only(ml)
	_t20_rate_limit_headers(ml)
	_t21_mws_list_params(ml)
	_t22_update_check_message(ml)
	_t23_download_failure_text(ml)
	_t24_pack_format_version(ml)
	_t25_version_ordering(ml)
	_t26_same_file_name(ml)
	_t27_download_file_names(ml)
	_t28_dependency_lists_and_load_order(ml)
	await _t29_pack_version_pins(ml)
	await _t30_reimport_hosted_pack(ml)
	await _t31_hosted_pack_names_and_errors(ml)
	_t32_browse_hides_the_loaders_own_listing(ml)
	_t33_install_map_keys_both_ids(ml)
	_t34_animated_webp_shows_its_first_frame(ml)
	await _t35_pack_slug_finds_the_mod_txt_uuid(ml)
	_t36_binary_scan_reads_past_the_first_nul(ml)
	await _t37_update_guards(ml)
	_t38_leaving_a_profile_without_mcm_records_none(ml)
	await _t39_pairing_asks_little_and_covers_unavailable_mods(ml)
	await _t40_pinned_file_matches_by_checksum(ml)
	await _t41_one_installed_test_and_cheap_pairing(ml)

	_finish()

# --- Fixtures ----------------------------------------------------------------

# A ModWorkshop listing row shaped exactly like a GET /games/864/mods `data`
# row: the field names are the ones host_mws.gd's normalizers read and
# host_mws.gd's endpoint notes document (id, name, user.name, category.name,
# version, downloads/likes/views, bumped_at, published_at, short_desc,
# thumbnail{file,has_thumb}). Parsed from JSON text, not written as a GDScript
# literal, so every number arrives as a FLOAT -- exactly as production
# payloads do, which is the whole reason _host_id_str exists.
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

# A Vostok Mods ModCard row, shaped from the site's own listing route rather
# than inferred from one observed response. followersCount is present ON
# PURPOSE: the adapter deliberately does NOT map it onto likes, and T2 pins
# that. `group` on a category is the discriminator between a real category and
# a tag, which the row mixes together.
const VM_ROW_JSON := """
{"id": "m_4", "slug": "example", "name": "Example", "summary": "An example mod.",
 "ownerDisplayName": "Ovrrde", "ownerUsername": "ovrrde",
 "taxonomies": [{"slug": "tag-1", "name": "Tag One", "group": {"slug": "tags", "name": "Tags"}},
                {"slug": "category-1", "name": "Category 1", "group": {"slug": "categories", "name": "Categories"}}],
 "thumbnailUrl": "https://files.vostokmods.net/mods/4/screenshots/example.png",
 "downloadsCount": 1, "followersCount": 7, "viewsCount": 42,
 "createdAt": "2026-08-01T00:00:00.000Z",
 "updatedAt": "2026-08-07T06:05:11.420Z", "latestGameVersion": null,
 "latestVersion": {"id": "v_1", "scanStatus": "clean", "downloadable": true,
                   "createdAt": "2026-08-07T06:05:11.420Z"}}
"""

# The same row with the nullable fields actually null. thumbnailUrl is null
# whenever a mod has no screenshot, which is the common case for a new upload.
const VM_ROW_NULLS_JSON := """
{"id": "m_5", "slug": "nulls", "name": "Nulls", "summary": null,
 "ownerDisplayName": "Ovrrde", "taxonomies": [], "thumbnailUrl": null,
 "downloadsCount": 0, "followersCount": 0, "viewsCount": 0,
 "createdAt": null, "updatedAt": null, "latestGameVersion": null,
 "latestVersion": null}
"""

# --- Tests -------------------------------------------------------------------

func _t1_mws_summary(ml: Object) -> void:
	var row: Variant = JSON.parse_string(MWS_ROW_JSON)
	_assert(row is Dictionary, "T1: MWS fixture JSON parses")
	var s: Variant = ml._mwsp_summary(row)
	_assert_same_keys(ml, s, "T1")
	var key := str(ml.host_ref_key(s["ref"]))
	_assert(key == "modworkshop:12345",
			"T1: JSON float id normalizes to ref modworkshop:12345 (got %s)" % key)
	_assert(str(s["name"]) == "Example Mod", "T1: name (got %s)" % str(s["name"]))
	_assert(str(s["author_name"]) == "AuthorGuy",
			"T1: author_name from user.name (got %s)" % str(s["author_name"]))
	_assert(str(s["category_name"]) == "Weapons",
			"T1: category_name from category.name (got %s)" % str(s["category_name"]))
	_assert(str(s["version"]) == "1.2.0",
			"T1: version is strip_edges'd (got '%s')" % str(s["version"]))
	_assert(s["downloads"] is int and int(s["downloads"]) == 321,
			"T1: downloads is int 321 (got %s)" % str(s["downloads"]))
	_assert(s["likes"] is int and int(s["likes"]) == 12,
			"T1: likes is int 12 (got %s)" % str(s["likes"]))
	_assert(s["views"] is int and int(s["views"]) == 4567,
			"T1: views is int 4567 (got %s)" % str(s["views"]))
	_assert(str(s["updated_at"]) == "2026-08-01T10:20:30.000000Z",
			"T1: updated_at maps from bumped_at (got %s)" % str(s["updated_at"]))
	_assert(str(s["published_at"]) == "2026-07-01T00:00:00.000000Z",
			"T1: published_at (got %s)" % str(s["published_at"]))
	_assert(str(s["short_description"]) == "A short blurb",
			"T1: short_description maps from short_desc")
	# URL convention pin: opaque storage filename doubles as the cache key.
	var thumb: Variant = s["thumbnail"]
	_assert(str(thumb["url"]) == "https://storage.modworkshop.net/mods/images/abc123.png",
			"T1: thumbnail url convention (got %s)" % str(thumb["url"]))
	_assert(str(thumb["thumb_url"]) == "https://storage.modworkshop.net/mods/images/thumbs/abc123.png",
			"T1: thumbnail thumbs/ variant when has_thumb (got %s)" % str(thumb["thumb_url"]))
	_assert(str(thumb["cache_key"]) == "abc123.png",
			"T1: storage filename doubles as cache_key (got %s)" % str(thumb["cache_key"]))
	_assert(str(s["default_file_id"]) == "",
			"T1: default_file_id sentinel stays '' on a listing row")
	# A row with an id but no name falls back to the id, never to "".
	var unnamed: Variant = ml._mwsp_summary({"id": 12345.0})
	_assert(str(unnamed["name"]) == "12345",
			"T1: empty name falls back to the id (got %s)" % str(unnamed["name"]))

func _t2_vm_summary(ml: Object) -> void:
	var row: Variant = JSON.parse_string(VM_ROW_JSON)
	_assert(row is Dictionary, "T2: Vostok Mods fixture JSON parses")
	var s: Variant = ml._vmp_summary(row)
	_assert_same_keys(ml, s, "T2")
	var key := str(ml.host_ref_key(s["ref"]))
	# IDENTITY IS THE SLUG, not the numeric id. Every Vostok Mods route --
	# detail, download, public page -- is slug-keyed and the numeric id
	# addresses nothing, so a ref built from the id would 404 everywhere.
	_assert(key == "vostokmods:example",
			"T2: ref identity is the SLUG (got %s)" % key)
	_assert(str(s["name"]) == "Example", "T2: name (got %s)" % str(s["name"]))
	_assert(str(s["author_name"]) == "Ovrrde",
			"T2: author_name is ownerDisplayName (got %s)" % str(s["author_name"]))
	_assert(str(s["short_description"]) == "An example mod.",
			"T2: summary maps to short_description (got %s)" % str(s["short_description"]))
	_assert(s["downloads"] is int and int(s["downloads"]) == 1,
			"T2: downloads is int 1 (got %s)" % str(s["downloads"]))
	# The deliberate NON-mapping: a follow is a subscription, not an
	# endorsement, so followersCount must NOT surface as likes.
	_assert(s["likes"] is int and int(s["likes"]) == -1,
			"T2: followersCount must NOT map onto likes (got %s)" % str(s["likes"]))
	_assert(s["views"] is int and int(s["views"]) == 42,
			"T2: views maps from viewsCount (got %s)" % str(s["views"]))
	_assert(str(s["version"]) == "",
			"T2: version sentinel '' -- the listing carries no version")
	_assert(str(s["published_at"]) == "2026-08-01T00:00:00.000Z",
			"T2: published_at maps from createdAt (got %s)" % str(s["published_at"]))
	_assert(str(s["updated_at"]) == "2026-08-07T06:05:11.420Z",
			"T2: updated_at maps from updatedAt (got %s)" % str(s["updated_at"]))
	# The row mixes categories and tags; `group` is the discriminator, so the
	# category must win even though the tag is listed first.
	_assert(str(s["category_name"]) == "Category 1",
			"T2: group=categories wins over an earlier tag (got %s)" % str(s["category_name"]))
	_assert(str(s["default_file_id"]) == "v_1",
			"T2: a clean latestVersion on the card sets default_file_id (got %s)" % str(s["default_file_id"]))
	var thumb: Variant = s["thumbnail"]
	_assert(str(thumb["url"]) == "https://files.vostokmods.net/mods/4/screenshots/example.png",
			"T2: thumbnailUrl passes through absolute (got %s)" % str(thumb["url"]))
	_assert(str(thumb["thumb_url"]) == "",
			"T2: no separate thumb size -> thumb_url ''")
	_assert(str(thumb["cache_key"]) == "",
			"T2: no immutability promise -> cache_key '' (never disk-cached)")

	# The nullable-field row. thumbnailUrl is null for any mod with no
	# screenshot, and str(null) is the literal "<null>" -- non-empty, so it
	# would be treated as a real URL and fetched.
	var nrow: Variant = JSON.parse_string(VM_ROW_NULLS_JSON)
	_assert(nrow is Dictionary, "T2n: nullable fixture JSON parses")
	var n: Variant = ml._vmp_summary(nrow)
	_assert_same_keys(ml, n, "T2n")
	_assert(str(ml.host_ref_key(n["ref"])) == "vostokmods:nulls",
			"T2n: slug identity still resolves with every other field null")
	var nthumb: Variant = n["thumbnail"]
	_assert(str(nthumb["url"]) == "",
			"T2n: null thumbnailUrl -> '' never '<null>' (got %s)" % str(nthumb["url"]))
	_assert(str(n["short_description"]) == "",
			"T2n: null summary -> '' (got %s)" % str(n["short_description"]))
	_assert(str(n["updated_at"]) == "",
			"T2n: null updatedAt -> '' (got %s)" % str(n["updated_at"]))
	_assert(str(n["category_name"]) == "",
			"T2n: empty taxonomies -> '' (got %s)" % str(n["category_name"]))
	_assert(str(n["default_file_id"]) == "",
			"T2n: null latestVersion -> no default_file_id (got %s)" % str(n["default_file_id"]))

# A null id means "this host has no id for this row". str(null) is the literal
# "<null>", which is non-empty and would sail through host_ref_valid, so this
# pins that a null id yields "" all the way through both normalizers.
func _t3_null_and_float_ids(ml: Object) -> void:
	_assert(str(ml._host_id_str(null)) == "",
			"T3: _host_id_str(null) is '' -- NOT the literal '<null>'")
	_assert(str(ml._host_id_str(12345.0)) == "12345",
			"T3: _host_id_str renders a JSON float id without the .0")
	_assert(str(ml._host_id_str(" 77 ")) == "77",
			"T3: _host_id_str strips string ids")
	var mws: Variant = ml._mwsp_summary(JSON.parse_string('{"id": null, "name": "X"}'))
	_assert(str(ml.host_ref_key(mws["ref"])) == "",
			"T3: MWS row with null id -> invalid ref, empty key")
	_assert(str(mws["name"]) == "",
			"T3: MWS row with null id stays the empty summary (name '')")
	var vm: Variant = ml._vmp_summary(JSON.parse_string('{"id": null, "name": "X"}'))
	_assert(str(ml.host_ref_key(vm["ref"])) == "",
			"T3: Vostok Mods row with null id -> invalid ref, empty key")
	_assert(not ml.host_ref_valid(ml.host_ref("modworkshop", "")),
			"T3: a ref with an empty id is invalid")
	# ModWorkshop sends JSON null for a field a mod never filled in.
	var sparse: Variant = ml._mwsp_summary(JSON.parse_string(
			'{"id": 7, "name": null, "version": null, "short_desc": null, "bumped_at": null, "published_at": null, "user": {"name": null}, "category": {"name": null}}'))
	for key in ["version", "short_description", "updated_at", "published_at", "author_name", "category_name"]:
		_assert(str(sparse[key]) == "", "T3: a null MWS %s reads as '' (got '%s')" % [key, str(sparse[key])])
	_assert(not str(sparse["name"]).contains("null"), "T3: a null MWS name does not read as '<null>' (got '%s')" % str(sparse["name"]))
	var sparse_file: Variant = ml._mwsp_file(JSON.parse_string('{"id": 9, "version": null, "created_at": null, "file": null}'))
	for key in ["version", "created_at"]:
		_assert(str(sparse_file[key]) == "", "T3: a null MWS file %s reads as '' (got '%s')" % [key, str(sparse_file[key])])

func _t4_result_envelope(ml: Object) -> void:
	var want_keys := ["code", "data", "http", "message", "ok", "retry_after_s"]
	var okd: Variant = ml.host_ok([1, 2])
	var ok_keys: Array = (okd as Dictionary).keys()
	ok_keys.sort()
	_assert(ok_keys == want_keys,
			"T4: host_ok key set (got %s)" % str(ok_keys))
	_assert(bool(okd["ok"]) == true, "T4: host_ok ok=true")
	_assert(okd["data"] == [1, 2], "T4: host_ok carries data unchanged")
	_assert(str(okd["code"]) == "" and int(okd["http"]) == 0
			and str(okd["message"]) == "" and int(okd["retry_after_s"]) == 0,
			"T4: host_ok failure fields are all zeroed")
	var errd: Variant = ml.host_err("rate_limited", 429, "slow down", 30)
	var err_keys: Array = (errd as Dictionary).keys()
	err_keys.sort()
	_assert(err_keys == want_keys,
			"T4: host_err key set matches host_ok (got %s)" % str(err_keys))
	_assert(bool(errd["ok"]) == false, "T4: host_err ok=false")
	_assert(errd["data"] == null, "T4: host_err data=null")
	_assert(str(errd["code"]) == "rate_limited" and int(errd["http"]) == 429
			and str(errd["message"]) == "slow down" and int(errd["retry_after_s"]) == 30,
			"T4: host_err carries code/http/message/retry_after_s")
	var errd2: Variant = ml.host_err("offline", 0, "no net")
	_assert(int(errd2["retry_after_s"]) == 0,
			"T4: host_err retry_after_s defaults to 0")

# The one grammar serving both the wire key and mod.txt's source= value.
# Split on the FIRST colon only; reject rather than guess.
func _t5_ref_grammar(ml: Object) -> void:
	var r: Variant = ml.host_ref_from_key("modworkshop:12345")
	_assert(str(r.get("provider", "")) == "modworkshop" and str(r.get("id", "")) == "12345",
			"T5: modworkshop:12345 parses (got %s)" % str(r))
	_assert(str(ml.host_ref_key(r)) == "modworkshop:12345",
			"T5: host_ref_key is the inverse of host_ref_from_key")
	var r2: Variant = ml.host_ref_from_key("vostokmods:example")
	_assert(str(r2.get("provider", "")) == "vostokmods" and str(r2.get("id", "")) == "example",
			"T5: vostokmods:example parses (got %s)" % str(r2))
	# Ids are opaque and may themselves contain colons: split on the FIRST.
	var r3: Variant = ml.host_ref_from_key("vostokmods:collection/riverwood:v2")
	_assert(str(r3.get("id", "")) == "collection/riverwood:v2",
			"T5: id keeps everything after the first colon (got %s)" % str(r3.get("id", "")))
	for bad in ["12345", "steam:123", "modworkshop:", "modworkshop:   ", ":123", ""]:
		var rej: Variant = ml.host_ref_from_key(bad)
		_assert(rej is Dictionary and (rej as Dictionary).is_empty(),
				"T5: '%s' must be rejected as {}, never guessed (got %s)" % [bad, str(rej)])

# ROUND TRIP for every on-disk era of the [mod_sources]/profile.json record:
# era record -> _normalize_source_record (read) -> _serialize_mod_source_rec
# (write) -> parse -> normalize -> serialize again. The two serializations
# must be identical -- convergence in ONE pass, so mod_config.cfg is not
# rewritten on every scan -- and the payload must obey THE MIRROR RULE:
# modworkshop_id present IFF provider == modworkshop.
func _t6_source_round_trip(ml: Object) -> void:
	var eras := [
		# [label, input record, want provider, want id, want mirror, want version]
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
		var label: String = era[0]
		var n1: Variant = ml._normalize_source_record(era[1])
		# Canonical shape: exactly provider/id/version, always present.
		var nk: Array = (n1 as Dictionary).keys()
		nk.sort()
		_assert(nk == ["id", "provider", "version"],
				"T6 %s: canonical record has exactly provider/id/version (got %s)" % [label, str(nk)])
		_assert(str(n1["provider"]) == str(era[2]),
				"T6 %s: provider (want '%s', got '%s')" % [label, str(era[2]), str(n1["provider"])])
		_assert(str(n1["id"]) == str(era[3]),
				"T6 %s: id (want '%s', got '%s')" % [label, str(era[3]), str(n1["id"])])
		_assert(str(n1["version"]) == str(era[5]),
				"T6 %s: version (want '%s', got '%s')" % [label, str(era[5]), str(n1["version"])])
		# THE MIRROR RULE. "new with stale mirror" is the load-bearing case:
		# provider is ABSOLUTE, so the stale 999 must vanish, not re-emit.
		var payload: Variant = ml._mod_source_payload(n1)
		var want_mirror: bool = era[4]
		_assert(bool((payload as Dictionary).has("modworkshop_id")) == want_mirror,
				"T6 %s: modworkshop_id mirror present IFF provider == modworkshop (payload: %s)"
						% [label, JSON.stringify(payload)])
		if want_mirror:
			_assert(int(payload["modworkshop_id"]) == str(n1["id"]).to_int(),
					"T6 %s: mirror value equals the id (payload: %s)" % [label, JSON.stringify(payload)])
		# CONVERGENCE IN ONE PASS.
		var s1 := str(ml._serialize_mod_source_rec(n1))
		var n2: Variant = ml._normalize_source_record(JSON.parse_string(s1))
		var s2 := str(ml._serialize_mod_source_rec(n2))
		_assert(s1 == s2,
				"T6 %s: serialization must converge in one pass ('%s' -> '%s')" % [label, s1, s2])

# The mod.txt [updates] surface: source= wins, the legacy modworkshop= key is
# read forever, and neither key is ever guessed into an id.
func _t7_modtxt_reader(ml: Object) -> void:
	var cases := [
		# [label, mod.txt text, want provider, want id, want version]
		["source= alone",
				'[mod]\nversion="1.2"\n\n[updates]\nsource="vostokmods:example"\n',
				"vostokmods", "example", "1.2"],
		["dual-written: source= wins",
				'[updates]\nsource="vostokmods:example"\nmodworkshop=777\n',
				"vostokmods", "example", ""],
		["legacy modworkshop= int",
				'[updates]\nmodworkshop=777\n',
				"modworkshop", "777", ""],
		["legacy junk id rejected",
				'[updates]\nmodworkshop="12abc"\n',
				"", "", ""],
		["malformed source= falls back to legacy",
				'[updates]\nsource="steam:4"\nmodworkshop=777\n',
				"modworkshop", "777", ""],
		["legacy zero-padded normalizes",
				'[updates]\nmodworkshop="0123"\n',
				"modworkshop", "123", ""],
		["bare unqualified source= rejected, never defaulted",
				'[updates]\nsource="12345"\n',
				"", "", ""],
	]
	for c in cases:
		var label: String = c[0]
		var cfg := ConfigFile.new()
		if cfg.parse(c[1]) != OK:
			_fail("T7 %s: fixture mod.txt failed to parse: %s" % [label, _oneline(c[1])])
			continue
		var rec: Variant = ml._mod_source_from_cfg(cfg)
		_assert(str(rec["provider"]) == str(c[2]),
				"T7 %s: provider (want '%s', got '%s')" % [label, str(c[2]), str(rec["provider"])])
		_assert(str(rec["id"]) == str(c[3]),
				"T7 %s: id (want '%s', got '%s')" % [label, str(c[3]), str(rec["id"])])
		_assert(str(rec["version"]) == str(c[4]),
				"T7 %s: version (want '%s', got '%s')" % [label, str(c[4]), str(rec["version"])])
	var nullrec: Variant = ml._mod_source_from_cfg(null)
	_assert(str(nullrec["provider"]) == "" and str(nullrec["id"]) == "",
			"T7: a null ConfigFile reads as no-source, not a crash")
	# ConfigFile drops a section with no keys. [registry] is kept because it is
	# a presence signal; a header the loader does not know is kept so the
	# unrecognized-section notice can name it; a known section stays absent.
	var bare: Dictionary = ml._parse_mod_txt('[mod]\nid="b"\n\n[Registry]\n\n[hooks]\n\n[registry]\n')
	var bare_cfg: ConfigFile = bare["cfg"]
	_assert(bare_cfg != null and bare_cfg.has_section("registry"), "T7: a bare [registry] header survives the parse")
	_assert(bare_cfg != null and bare_cfg.has_section("Registry"), "T7: a bare header the loader does not know survives too, so it can be reported")
	_assert(bare_cfg != null and not bare_cfg.has_section("hooks"), "T7: a bare known section gets no placeholder key")
	# The parse diagnostic names the broken line, not an earlier value that
	# legitimately spans several lines.
	var spanning: Dictionary = ml._parse_mod_txt('[mod]\nname="X"\ntags=[\n"a",\n"b"\n]\nid=not quoted\n')
	_assert(spanning["cfg"] == null and str(spanning["error"]).begins_with("line 7 [mod]"),
			"T7: the diagnostic skips a multi-line value and names line 7 (got '%s')" % str(spanning["error"]))
	var first_line: Dictionary = ml._parse_mod_txt('[mod]\nname=X Y\nid="x"\n')
	_assert(str(first_line["error"]).begins_with("line 2 [mod]"), "T7: a broken single line is still named (got '%s')" % str(first_line["error"]))

# Ranking a mod.txt declaration against the [mod_sources] record the launcher
# stored for the same mod. Files served by vostokmods.net carry only a legacy
# modworkshop= line, so a mod downloaded from Vostok Mods must keep the identity
# the download recorded; otherwise Browse shows it as not installed, the update
# check asks the wrong host and a hosted pack re-downloads it on every apply.
# An explicit source= is the author's word and wins over everything.
func _t11_source_precedence(ml: Object) -> void:
	var legacy := _cfg_from_text('[mod]
version="1.2"

[updates]
modworkshop=777
')
	var explicit := _cfg_from_text('[updates]
source="vostokmods:example"
')
	var silent := _cfg_from_text('[mod]
version="1.2"
')
	var stored_vm := {"provider": "vostokmods", "id": "rtvcoop", "version": "5.0.0"}
	var stored_mws := {"provider": "modworkshop", "id": "777", "version": "1.2"}
	var stored_other_mws := {"provider": "modworkshop", "id": "999"}
	var cases := [
		# [label, mod.txt, stored record or null, want provider:id, want version]
		["explicit source= beats a stored other-provider record", explicit, stored_other_mws, "vostokmods:example", ""],
		["legacy plus a stored vostokmods record yields vostokmods", legacy, stored_vm, "vostokmods:rtvcoop", "5.0.0"],
		["legacy alone yields modworkshop", legacy, null, "modworkshop:777", "1.2"],
		["legacy plus a stored record of the same provider is unchanged", legacy, stored_mws, "modworkshop:777", "1.2"],
		["nothing declared falls back to the stored record", silent, stored_vm, "vostokmods:rtvcoop", "5.0.0"],
		["nothing declared and nothing stored is no source", silent, null, "", ""],
	]
	for c in cases:
		var label: String = c[0]
		var entry := {"profile_key": "k", "cfg": c[1]}
		var persisted := {}
		if c[2] != null:
			persisted["k"] = ml._normalize_source_record(c[2])
		var rec: Dictionary = ml._entry_source_record(entry, persisted)
		var keys: Array = rec.keys()
		keys.sort()
		_assert(keys == ["id", "provider", "version"],
				"T11 %s: resolved record has exactly provider/id/version (got %s)" % [label, str(keys)])
		var got := ""
		if str(rec["provider"]) != "":
			got = str(rec["provider"]) + ":" + str(rec["id"])
		_assert(got == str(c[3]),
				"T11 %s: want '%s', got '%s'" % [label, str(c[3]), got])
		_assert(str(rec["version"]) == str(c[4]),
				"T11 %s: version (want '%s', got '%s')" % [label, str(c[4]), str(rec["version"])])

	# The scan-time persist applies the same ranking to what it writes: a
	# legacy line never displaces a record another host's download wrote, an
	# explicit source= replaces whatever is stored, and a second scan with
	# nothing new writes nothing.
	var cfg_path := str(ml.UI_CONFIG_PATH)
	var bak_path := cfg_path + ".bak"
	_remove_user_file(cfg_path)
	_remove_user_file(bak_path)
	var seed := ConfigFile.new()
	seed.set_value("mod_sources", "vm@1", ml._serialize_mod_source_rec(ml._normalize_source_record(stored_vm)))
	seed.set_value("mod_sources", "same@1", ml._serialize_mod_source_rec(ml._normalize_source_record(stored_mws)))
	seed.set_value("mod_sources", "other@1", ml._serialize_mod_source_rec(ml._normalize_source_record(stored_other_mws)))
	_assert(seed.save(cfg_path) == OK, "T11: seeded mod_config.cfg in the throwaway user://")
	var entries: Array[Dictionary] = [
		{"profile_key": "vm@1", "cfg": legacy},
		{"profile_key": "same@1", "cfg": legacy},
		{"profile_key": "other@1", "cfg": explicit},
		{"profile_key": "new@1", "cfg": legacy},
	]
	ml._persist_mod_sources_for_entries(entries)
	var after: Dictionary = ml._get_persisted_mod_sources()
	_assert(_stored_key(after, "vm@1") == "vostokmods:rtvcoop",
			"T11 persist: a legacy line leaves a stored vostokmods record alone (got %s)" % _stored_key(after, "vm@1"))
	_assert(_stored_key(after, "same@1") == "modworkshop:777",
			"T11 persist: a legacy line keeps a stored record of the same provider (got %s)" % _stored_key(after, "same@1"))
	_assert(_stored_key(after, "other@1") == "vostokmods:example",
			"T11 persist: an explicit source= replaces a stored other-provider record (got %s)" % _stored_key(after, "other@1"))
	_assert(_stored_key(after, "new@1") == "modworkshop:777",
			"T11 persist: a legacy line is recorded when nothing is stored (got %s)" % _stored_key(after, "new@1"))
	_remove_user_file(bak_path)
	ml._persist_mod_sources_for_entries(entries)
	_assert(not FileAccess.file_exists(bak_path),
			"T11 persist: a second scan with nothing new must not rewrite mod_config.cfg")
	_remove_user_file(cfg_path)
	_remove_user_file(bak_path)

func _cfg_from_text(text: String) -> ConfigFile:
	var cfg := ConfigFile.new()
	if cfg.parse(text) != OK:
		_fail("fixture mod.txt failed to parse: " + _oneline(text))
	return cfg

func _stored_key(persisted: Dictionary, profile_key: String) -> String:
	if not persisted.has(profile_key):
		return "(absent)"
	var rec: Dictionary = persisted[profile_key]
	return str(rec["provider"]) + ":" + str(rec["id"])

func _remove_user_file(path: String) -> void:
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(path))

# --- Shared assertions -------------------------------------------------------

# The "every field always present" rule: a normalizer's output must carry
# exactly the key set host_empty_summary declares, no more, no fewer.

# T8: the pure half of the Vostok Mods adapter. The seam has no live consumer
# yet, so nothing has ever executed these; the async operations need a network
# and stay out of reach here, but everything below is a pure function and has
# no excuse for being untested.
func _t8_vm_pure_surface(ml: Object) -> void:
	# Page URL. /mod/ is SINGULAR -- the plural path 404s, which is the whole
	# reason this capability was once believed unsupported.
	var url: String = str(ml._vmp_mod_page_url("example"))
	_assert(url == "https://vostokmods.net/mod/example",
			"T8: mod page url is /mod/{slug} (got %s)" % url)
	_assert(str(ml._vmp_mod_page_url("")) == "",
			"T8: empty slug yields '' so the UI hides the button")

	# A version entry from a detail payload.
	var vrow: Variant = JSON.parse_string("""
	{"id": "v_9", "version": "1.4.0", "fileName": "coolmod-1.4.0.zip",
	 "fileSize": 20480, "createdAt": "2026-08-10T00:00:00.000Z",
	 "downloadUrl": "/api/mods/example/versions/1.4.0/download",
	 "downloadable": true, "scanStatus": "clean"}
	""")
	_assert(vrow is Dictionary, "T8: version fixture parses")
	var f: Variant = ml._vmp_file(vrow)
	_assert(str(f["download_url"]) == "https://vostokmods.net/api/mods/example/versions/1.4.0/download",
			"T8: relative downloadUrl is absolutized (got %s)" % str(f["download_url"]))
	_assert(str(f["version"]) == "1.4.0", "T8: version (got %s)" % str(f["version"]))
	_assert(str(f["filename_hint"]) == "coolmod-1.4.0.zip",
			"T8: filename_hint from fileName (got %s)" % str(f["filename_hint"]))
	_assert(f["size"] is int and int(f["size"]) == 20480,
			"T8: size from fileSize (got %s)" % str(f["size"]))
	_assert(ml._vmp_downloadable(vrow), "T8: a clean version is downloadable")

	# A version the host refuses to serve. It must not become a file record:
	# download_url would 404, and the user would see a failed download instead
	# of the real reason.
	var dirty: Variant = JSON.parse_string("""
	{"id": "v_10", "version": "1.5.0", "fileName": "bad.zip", "fileSize": 1,
	 "downloadUrl": "/api/mods/example/versions/1.5.0/download",
	 "downloadable": false, "scanStatus": "flagged"}
	""")
	_assert(not ml._vmp_downloadable(dirty),
			"T8: a non-clean version is NOT downloadable")
	_assert(not ml._vmp_downloadable(JSON.parse_string('{"version": "x"}')),
			"T8: a version with no downloadable flag is not downloadable")
	_assert(not ml._vmp_downloadable(null), "T8: null is not downloadable")

	# A null downloadUrl must read as absent, not as the literal "<null>",
	# which is non-empty and would be requested as a real URL.
	var nullurl: Variant = ml._vmp_file(JSON.parse_string('{"id": "v_11", "downloadUrl": null}'))
	_assert(str(nullurl["download_url"]) == "",
			"T8: null downloadUrl -> '' never '<null>' (got %s)" % str(nullurl["download_url"]))

	# The listing body: rows under `entries`, an empty page included. A body
	# without the key is not a listing (the key moved once and Browse showed
	# nothing for a day), so it must read as an error upstream, never as empty.
	var listing: Variant = JSON.parse_string("""
	{"entries": [{"id": "019ff204-4d5c-7a17-92b7-f9a6a5a4dc88", "slug": "loot-modifier", "name": "Loot Modifier"},
	             {"id": "019ff1f0-00ac-76a9-a23f-7151e4531131", "slug": "rtvcoop", "name": "RTVCoop"}],
	 "page": 1, "pageCount": 1, "total": 2}
	""")
	_assert(ml._vmp_rows(listing) is Array and (ml._vmp_rows(listing) as Array).size() == 2,
			"T8: listing rows are read from `entries`")
	_assert(ml._vmp_rows(JSON.parse_string('{"entries": [], "total": 0}')) is Array,
			"T8: an empty listing is still a listing")
	_assert(ml._vmp_rows(JSON.parse_string('{"mods": [{"slug": "a"}]}')) == null and ml._vmp_rows(JSON.parse_string('{"page": 1}')) == null and ml._vmp_rows(null) == null,
			"T8: a body without `entries` is not a listing")
	# The page link takes the slug or the UUID; the site resolves either.
	var uuid := "019ff1f0-00ac-76a9-a23f-7151e4531131"
	_assert(str(ml._vmp_mod_page_url(uuid)) == "https://vostokmods.net/mod/" + uuid,
			"T8: a UUID page url passes the UUID through")
	var nofile: Variant = ml._vmp_file_result(JSON.parse_string('{"id": "v_12", "downloadUrl": null}'))
	_assert(not nofile["ok"] and str(nofile["code"]) == ml.HOST_ERR_NO_FILE,
			"T8: a record with no url resolves to NO_FILE, never a bad ok")

	# The group object's slug is the discriminator between a category and a tag.
	var cats: Variant = JSON.parse_string("""
	[{"slug": "t", "name": "Tag", "group": {"slug": "tags", "name": "Tags"}},
	 {"slug": "c", "name": "Cat", "group": {"slug": "categories", "name": "Categories"}}]
	""")
	_assert(str(ml._vmp_primary_category(cats)) == "Cat",
			"T8: group categories wins over an earlier tag")
	_assert(str(ml._vmp_primary_category(JSON.parse_string("[]"))) == "",
			"T8: no taxonomies -> ''")
	_assert(str(ml._vmp_group_slug(JSON.parse_string('{"slug": "categories"}'))) == "categories" and str(ml._vmp_group_slug("categories")) == "",
			"T8: a group is an object; a bare string is not a group")

	# Scalars must agree with the API's own schema, or a request is rejected
	# for a reason the user reads as a connection failure.
	var sc: Variant = ml._vmp_scalars()
	_assert(int(sc["query_max_len"]) == 100, "T8: q is capped at 100 by the schema")
	_assert(int(sc["page_size"]) == 24, "T8: default limit is 24")
	var allowed := ["downloads", "followers", "views", "newest", "updated", "newestFile"]
	_assert((sc["sorts"] as Array).size() > 0, "T8: sorts is non-empty")
	for opt in (sc["sorts"] as Array):
		_assert(allowed.has(str((opt as Dictionary)["key"])),
				"T8: sort key '%s' is not in the API enum" % str((opt as Dictionary)["key"]))
	for sec in (sc["landing_sections"] as Array):
		_assert(allowed.has(str((sec as Dictionary)["sort_key"])),
				"T8: landing sort_key '%s' is not in the API enum" % str((sec as Dictionary)["sort_key"]))


# T9: a capability is a PROMISE the UI acts on -- it hides controls for what is
# off and offers them for what is on. A cap that disagrees with its wiring puts
# a button on screen that can only fail, which is the exact failure the whole
# capability model exists to prevent. Nothing checked the two against each
# other until now.
func _t9_caps_match_wiring(ml: Object) -> void:
	# Each host has its own id grammar, and a page-URL builder is right to
	# refuse an id that cannot be one of its own (ModWorkshop ids are integers,
	# Vostok Mods ids are slugs). Probe each with an id IT would accept, or the
	# check measures the fixture rather than the wiring.
	var sample := {
		ml.HOST_MODWORKSHOP: "12345",
		ml.HOST_VOSTOKMODS: "example-slug",
	}
	for provider in ml.host_providers():
		var caps: Variant = ml.host_caps(provider)
		_assert(sample.has(provider),
				"T9: no sample id for provider '%s' -- add one when adding a host" % provider)
		var page := str(ml.host_mod_page_url(ml.host_ref(provider, str(sample.get(provider, "1")))))
		if bool(caps["page_url"]):
			_assert(page != "",
					"T9: %s claims page_url but builds no URL" % provider)
		else:
			_assert(page == "",
					"T9: %s denies page_url but built '%s'" % [provider, page])
		# A browsable host must offer something to sort by or an explicitly
		# empty list; a non-browsable one must not advertise sorts.
		var sorts: Array = ml.host_sorts(provider)
		if not bool(caps["browse"]):
			_assert(sorts.is_empty(),
					"T9: %s cannot browse but advertises %d sort(s)" % [provider, sorts.size()])
		_assert(str(ml.host_display_name(provider)) != "",
				"T9: %s has no display name" % provider)
	# Every provider has an arm in every dispatcher. The arms go to the network
	# and cannot be called here, so they are read off the source: a provider
	# missing from one match falls to the HOST_ERR_UNWIRED default at runtime.
	var source := FileAccess.get_file_as_string(MODLOADER_PATH)
	for provider in ml.host_providers():
		var const_name := ""
		for candidate in ["HOST_MODWORKSHOP", "HOST_VOSTOKMODS"]:
			if str(ml.get(candidate)) == str(provider):
				const_name = candidate
		if const_name == "":
			# A provider added later: find the constant that holds its id.
			var decl := RegEx.create_from_string("(?m)^const (HOST_[A-Z_]+) := \"%s\"" % str(provider)).search(source)
			const_name = decl.get_string(1) if decl != null else ""
		_assert(const_name != "", "T9: no HOST_ constant holds the provider id '%s'" % provider)
		for op in ["host_list_mods", "host_get_mod", "host_list_files", "host_resolve_file",
				"host_list_categories", "host_latest_versions", "host_note_rate_headers", "host_caps"]:
			var start := source.find("\nfunc %s(" % op)
			_assert(start >= 0, "T9: dispatcher %s exists" % op)
			var end := source.find("\nfunc ", start + 1)
			var body := source.substr(start, (end if end > start else source.length()) - start)
			_assert(body.contains("\t\t%s:" % const_name), "T9: %s has a match arm for %s" % [op, const_name])

# A format-2 manifest shaped like the site's own reference doc: one
# available mod with a checksum, one unavailable (scanning), one removed;
# mcmConfig carries both shapes at once (a raw per-mod file and an MCM
# export whose ImportModData must merge into another mod's config.ini).
const VM_MANIFEST_JSON := """\n{"format": 2, "slug": "hardcore-survival", "name": "Hardcore Survival",\n "summary": "Short description", "ownerDisplayName": "Ovrrde",\n "url": "https://vostokmods.net/modpack/hardcore-survival",\n "thumbnailUrl": null, "updatedAt": "2026-09-11T16:07:32.051Z",\n "hash": "0123abcd",\n "mcmConfig": {\n   "doinkoink-mcm/config.ini": "[General]\n\nvolume={\\\"value\\\": 3}\n",\n   "export.ini": "[some-mod]\n\nImportModData={\\\"friendlyName\\\": \\\"Some Mod\\\"}\nspeed={\\\"value\\\": 7, \\\"import_data\\\": {\\\"section\\\": \\\"Movement\\\"}}\n",\n   "../evil.ini": "[x]\n\nImportModData={}\n"\n },\n "mods": [\n   {"loadOrder": 1, "slug": "mod-configuration-menu", "name": "MCM", "ownerDisplayName": "metro",\n    "available": true, "reason": null, "version": "2.9.2", "fileName": "mcm.vmz",\n    "fileSize": 4404019, "sha256": "AB12ab12ab12ab12ab12ab12ab12ab12ab12ab12ab12ab12ab12ab12ab12ab12",\n    "downloadUrl": "https://vostokmods.net/api/mods/mod-configuration-menu/versions/2.9.2/download",\n    "pageUrl": "https://vostokmods.net/mod/mod-configuration-menu"},\n   {"loadOrder": 2, "slug": "still-scanning", "name": "Scanning", "ownerDisplayName": "x",\n    "available": false, "reason": "scanning", "version": null, "fileName": null,\n    "fileSize": null, "sha256": null, "downloadUrl": null, "pageUrl": null},\n   {"loadOrder": 3, "slug": "gone", "name": "Gone", "ownerDisplayName": "x",\n    "available": false, "reason": "removed", "version": null, "fileName": null,\n    "fileSize": null, "sha256": null, "downloadUrl": null, "pageUrl": null}\n ]}\n"""

const VM_PACK_ROW_JSON := """
{"id": "01a09139", "slug": "test", "name": "Test", "summary": "", "ownerDisplayName": "Admin Prime",
 "ownerUsername": "admin", "ownerAvatarUrl": null, "createdAt": "2026-09-11T16:07:32.051Z",
 "updatedAt": "2026-09-11T16:30:14.194Z", "modCount": 14, "thumbnailUrl": null,
 "manifestUrl": "https://vostokmods.net/api/modpacks/test/manifest",
 "url": "https://vostokmods.net/modpack/test"}
"""

func _t10_hosted_modpacks(ml: Object) -> void:
	# Link normalization: every accepted spelling lands on the manifest URL,
	# and nothing off vostokmods.net is ever fetched.
	var want := "https://vostokmods.net/api/modpacks/hardcore-survival/manifest"
	for text in [
		"https://vostokmods.net/api/modpacks/hardcore-survival/manifest",
		"http://vostokmods.net/modpack/hardcore-survival",
		"vostokmods.net/modpack/hardcore-survival?utm=1",
		"https://www.vostokmods.net/modpack/Hardcore-Survival/",
		"hardcore-survival",
	]:
		_assert(str(ml._vmp_modpack_manifest_url(text)) == want,
				"T10: link '%s' -> manifest URL (got '%s')" % [text, str(ml._vmp_modpack_manifest_url(text))])
	for text in [
		"https://evil.example/api/modpacks/x/manifest",
		"https://vostokmods.net.evil.example/modpack/x",
		"https://vostokmods.net@evil.example/modpack/x",
		"https://vostokmods.net/mod/some-mod",
		"has space",
		"",
	]:
		_assert(str(ml._vmp_modpack_manifest_url(text)) == "",
				"T10: link '%s' must be refused (got '%s')" % [text, str(ml._vmp_modpack_manifest_url(text))])

	# Listing row normalizer.
	var row: Variant = JSON.parse_string(VM_PACK_ROW_JSON)
	var s: Dictionary = ml._vmp_modpack_summary(row)
	_assert(str(s["slug"]) == "test" and str(s["name"]) == "Test", "T10: pack summary slug/name")
	_assert(int(s["mod_count"]) == 14, "T10: pack summary mod_count reads a JSON float as int")
	_assert(str(s["manifest_url"]).ends_with("/api/modpacks/test/manifest"), "T10: pack summary manifest_url")
	_assert(str(s["page_url"]) == "https://vostokmods.net/modpack/test", "T10: pack summary page_url")
	_assert(str(s["cover_url"]) == "", "T10: null thumbnailUrl reads as empty, not '<null>'")

	# The pack listing carries its rows under `entries`, like the mod listing.
	# A body without the key is a changed shape and must be an error: read as
	# an empty page it tells the player nobody has published a pack.
	_assert(ml.has_method("_vmp_modpack_page"), "T10: the loader has _vmp_modpack_page")
	var pack_listing: Variant = JSON.parse_string(
			'{"entries": [' + VM_PACK_ROW_JSON + ', {"id": "x", "name": "No slug"}], "total": 2, "page": 1, "pageCount": 1}')
	var pack_page: Dictionary = ml._vmp_modpack_page(pack_listing)
	_assert(bool(pack_page["ok"]), "T10: a pack listing under `entries` is read")
	if bool(pack_page["ok"]):
		var pack_rows: Array = pack_page["data"]["rows"]
		_assert(pack_rows.size() == 1 and str(pack_rows[0]["slug"]) == "test",
				"T10: pack rows come from `entries`, a row with no slug dropped (got %d)" % pack_rows.size())
		_assert(int(pack_page["data"]["total"]) == 2 and not bool(pack_page["data"]["has_more"]),
				"T10: pack listing total and paging")
	var pack_more: Dictionary = ml._vmp_modpack_page(JSON.parse_string('{"entries": [], "total": 45, "page": 2, "pageCount": 3}'))
	_assert(bool(pack_more["ok"]) and bool(pack_more["data"]["has_more"]) and str(pack_more["data"]["next_cursor"]) == "3",
			"T10: an empty pack page is still a listing, and pages on")
	for bad in ['{"modpacks": [{"slug": "a"}], "total": 1}', '{"page": 1}', '[]']:
		_assert(not bool(ml._vmp_modpack_page(JSON.parse_string(bad))["ok"]),
				"T10: a pack body without `entries` is an error, not an empty listing (%s)" % bad)

	# Manifest validation.
	var manifest: Variant = JSON.parse_string(VM_MANIFEST_JSON)
	_assert(manifest is Dictionary, "T10: manifest fixture parses")
	_assert(str(ml._vmp_validate_manifest(manifest)) == "", "T10: a format-2 manifest validates")
	var newer: Dictionary = (manifest as Dictionary).duplicate()
	newer["format"] = 3
	_assert(str(ml._vmp_validate_manifest(newer)) != "", "T10: a newer format is refused")
	_assert(str(ml._vmp_validate_manifest({"format": 2, "slug": "x"})) != "", "T10: a manifest with no mods is refused")

	# Manifest -> profile.json conversion.
	var conv: Dictionary = ml._hosted_manifest_to_profile(manifest)
	var profile: Dictionary = conv["profile"]
	_assert(int(profile["metroprofile"]) == 1, "T10: hosted pack is a metroprofile v1 payload")
	_assert(str(profile["name"]) == "Hardcore Survival" and str(profile["author"]) == "Ovrrde",
			"T10: name and author carried over")
	var enabled: Dictionary = profile["enabled"]
	_assert(enabled.size() == 3 and enabled.has("vostokmods:mod-configuration-menu") and enabled.has("vostokmods:gone"),
			"T10: every listed mod is enabled under a slug key (got %s)" % str(enabled.keys()))
	var priority: Dictionary = profile["priority"]
	_assert(int(priority["vostokmods:mod-configuration-menu"]) == 1 and int(priority["vostokmods:gone"]) == 3,
			"T10: priority follows loadOrder")
	var sources: Dictionary = profile.get("sources", {})
	_assert(sources.size() == 1 and sources.has("vostokmods:mod-configuration-menu"),
			"T10: only available mods get a source record (got %s)" % str(sources.keys()))
	var src: Dictionary = sources["vostokmods:mod-configuration-menu"]
	_assert(str(src["provider"]) == "vostokmods" and str(src["id"]) == "mod-configuration-menu" and str(src["version"]) == "2.9.2",
			"T10: source record pins the manifest version")
	var rec: Dictionary = ml._normalize_source_record(src)
	_assert(str(rec["provider"]) == "vostokmods" and str(rec["version"]) == "2.9.2",
			"T10: the source record round-trips through the normalizer")
	_assert(not src.has("modworkshop_id"), "T10: no ModWorkshop mirror on a Vostok Mods record")
	var unavailable: Dictionary = profile.get("unavailable", {})
	_assert(str(unavailable.get("vostokmods:still-scanning", "")) == "scanning" and str(unavailable.get("vostokmods:gone", "")) == "removed",
			"T10: unavailable mods keep the site's reason")
	var checksums: Dictionary = profile.get("checksums", {})
	_assert(str(checksums.get("vostokmods:mod-configuration-menu", "")) == "ab12ab12ab12ab12ab12ab12ab12ab12ab12ab12ab12ab12ab12ab12ab12ab12",
			"T10: sha256 is kept, lowercased")
	var hosted: Dictionary = profile["hosted"]
	_assert(str(hosted["slug"]) == "hardcore-survival" and str(hosted["hash"]) == "0123abcd" and int(hosted["format"]) == 2,
			"T10: hosted record carries slug, hash and format")
	_assert(str(ml._hosted_unavailable_copy("scanning")).contains("scanned"), "T10: scanning reason has its own copy")

	# MCM: the raw file passes through, the export merges into the other
	# mod's config.ini, and the traversal key is dropped.
	var mcm: Dictionary = conv["mcm"]
	_assert(mcm.has("doinkoink-mcm/config.ini") and str(mcm["doinkoink-mcm/config.ini"]).contains("volume"),
			"T10: raw per-mod MCM file kept verbatim")
	_assert(mcm.has("some-mod/config.ini"), "T10: MCM export merged into some-mod/config.ini (got %s)" % str(mcm.keys()))
	if mcm.has("some-mod/config.ini"):
		var cf := ConfigFile.new()
		_assert(cf.parse(str(mcm["some-mod/config.ini"])) == OK, "T10: merged config parses")
		var v: Variant = cf.get_value("Movement", "speed", null)
		_assert(v is Dictionary and int((v as Dictionary).get("value", 0)) == 7 and not (v as Dictionary).has("import_data"),
				"T10: merged value lands in its import_data.section without the import_data marker")
	for k in mcm.keys():
		_assert(not str(k).contains(".."), "T10: MCM key with .. must not survive (%s)" % str(k))
	_assert(not mcm.has("x/config.ini"), "T10: an export under an unsafe key is not merged")
	var warnings: PackedStringArray = conv["warnings"]
	_assert(warnings.size() >= 1, "T10: the unsafe MCM key produced a warning")

	# A pack zip is a mod list plus an MCM tree and nothing else: files beside
	# profile.json do not stop validation and never reach user://, and only
	# the MCM/ tree lands in the pack's own snapshot slot.
	var pack_zip := _write_zip("user://host_pack.zip", {
		"profile.json": JSON.stringify({"metroprofile": 1, "name": "Strangers", "enabled": {"x@1": true}}),
		"mod_config.cfg": "[settings]\nactive_profile=\"Evil\"\n",
		"foo.txt": "x",
		"evil.pck": "GDPC",
		"MCM/some-mod/config.ini": "[a]\nv=1\n",
		"MCM/../escape.ini": "[a]\n",
	})
	var before := _user_listing()
	var validation: Dictionary = ml._validate_modpack({"file_path": pack_zip})
	_assert(bool(validation.get("ok", false)), "T10: a pack with stray files beside profile.json validates (got %s)" % str(validation.get("error", "")))
	_assert(_user_listing() == before, "T10: validation writes nothing under user://")
	var cfg_path := str(ml.UI_CONFIG_PATH)
	_remove_user_file(cfg_path)
	_remove_user_file(cfg_path + ".bak")
	var mat: Dictionary = ml._materialize_modpack_profile({"file_path": pack_zip}, "modpack__strangers")
	_assert(bool(mat.get("ok", false)), "T10: the pack materializes (got %s)" % str(mat.get("error", "")))
	var after := _user_listing()
	var slot := "user://.profile_snapshots/modpack__strangers/MCM"
	_assert(FileAccess.file_exists(slot + "/some-mod/config.ini"), "T10: the MCM tree lands in the pack's snapshot slot")
	var leaked: Array = []
	for p in after:
		if before.has(p):
			continue
		var path_s := str(p)
		if path_s == cfg_path or path_s == cfg_path + ".bak" or path_s == "user://.profile_snapshots/" \
				or path_s.begins_with("user://.profile_snapshots/modpack__strangers/"):
			continue
		leaked.append(path_s)
	_assert(leaked.is_empty(), "T10: nothing else was written under user:// (got %s)" % str(leaked))
	_assert(not FileAccess.file_exists("user://escape.ini") and not FileAccess.file_exists("user://.profile_snapshots/escape.ini"),
			"T10: an MCM entry with .. in its path is dropped")
	var written := ConfigFile.new()
	_assert(written.load(cfg_path) == OK and str(written.get_value("settings", "active_profile", "")) != "Evil",
			"T10: the pack's mod_config.cfg never replaces the launcher's")
	ml._remove_tree("user://.profile_snapshots", false)
	_remove_user_file(cfg_path)
	_remove_user_file(cfg_path + ".bak")
	_remove_user_file("user://host_pack.zip")

	# Pack file path never escapes mods/.
	var path := str(ml._hosted_pack_file_path("../Weird Slug!"))
	_assert(path.get_file() == "vostokmods-weirdslug.zip",
			"T10: pack file name is reduced to [a-z0-9-] (got %s)" % path.get_file())
	_assert(str(ml._hosted_pack_file_path("!!!")) == "", "T10: a slug with nothing safe in it yields no path")


# Every return from the modpack apply flow carries the same keys, so the
# dialogs can read the download counts without shape-checking. Both early
# failures here return before any download starts, so the coroutine
# completes without suspending.
func _t12_apply_failure_shape(ml: Object) -> void:
	var want_keys := ["downloaded", "error", "failed_downloads", "failures", "ok"]
	var r: Dictionary = await ml._apply_modpack_inner({}, null, Callable())
	var keys: Array = r.keys()
	keys.sort()
	_assert(keys == want_keys,
			"T12: a validation failure returns the apply shape (got %s)" % str(keys))
	_assert(not bool(r.get("ok", true)) and str(r.get("error", "")) != "",
			"T12: a validation failure is ok=false with a message")
	_assert(int(r.get("downloaded", -1)) == 0 and int(r.get("failed_downloads", -1)) == 0
			and (r.get("failures", null) is Array) and (r.get("failures", [1]) as Array).is_empty(),
			"T12: a validation failure reports zero downloads (got %s)" % str(r))
	ml.set("_modpack_apply_in_progress", true)
	var busy: Dictionary = await ml.apply_modpack({}, null, Callable())
	ml.set("_modpack_apply_in_progress", false)
	var busy_keys: Array = busy.keys()
	busy_keys.sort()
	_assert(busy_keys == want_keys,
			"T12: the apply-in-progress refusal returns the apply shape (got %s)" % str(busy_keys))
	_assert(not bool(busy.get("ok", true)) and str(busy.get("error", "")).contains("in progress"),
			"T12: the apply-in-progress refusal says so (got %s)" % str(busy.get("error", "")))
	# Which dialog a result gets. A failed apply is a failure even when it
	# carries failed downloads: the counts describe what ran before it failed.
	_assert(ml.has_method("_modpack_apply_outcome"), "T12: the loader has _modpack_apply_outcome")
	if not ml.has_method("_modpack_apply_outcome"):
		return
	var failed_after_downloads: Dictionary = ml._modpack_apply_failure("cannot read settings", 2, 1, [{"profile_key": "a@1"}])
	_assert(str(ml._modpack_apply_outcome(failed_after_downloads)) == "failed",
			"T12: a failed apply with a failed download is 'failed', not 'partial'")
	_assert(str(ml._modpack_apply_outcome({"ok": true, "failed_downloads": 1})) == "partial",
			"T12: an applied pack with a failed download is 'partial'")
	_assert(str(ml._modpack_apply_outcome({"ok": true, "failed_downloads": 0})) == "applied",
			"T12: an applied pack with no failed download is 'applied'")
	_assert(str(ml._modpack_apply_outcome({"ok": false, "cancelled": true, "failed_downloads": 1})) == "cancelled",
			"T12: a cancelled apply is 'cancelled' whatever else it carries")

# --- Pack apply and unload, with nothing to download --------------------------

# An applied pack lives in its own profile slot, and the slot is kept on
# unload so the player's edits survive. These tests run the real apply and
# unload against a pack whose mods are all installed, so no request is made.
const PACK_ZIP := "user://host_round_trip.zip"

func _pack_cleanup(ml: Object) -> void:
	var cfg_path := str(ml.UI_CONFIG_PATH)
	for p in [cfg_path, cfg_path + ".bak", PACK_ZIP]:
		_remove_user_file(p)
	for d in ["user://MCM", "user://.profile_snapshots"]:
		if DirAccess.dir_exists_absolute(ProjectSettings.globalize_path(d)):
			ml._remove_tree(d, false)
	var none: Array[Dictionary] = []
	ml.set("_ui_mod_entries", none)
	ml.set("_modpack_entries", none)

# Two installed mods on the Default profile, a@1.0 and foo@2.0. foo came from
# Vostok Mods and its mod.txt says nothing, so only [mod_sources] knows its host.
func _pack_setup(ml: Object) -> void:
	_pack_cleanup(ml)
	var installed: Array[Dictionary] = [_installed_entry("a@1.0", "a", "1.0"), _installed_entry("foo@2.0", "foo", "2.0")]
	ml.set("_ui_mod_entries", installed)
	ml.set("_active_profile", "Default")
	var seed := ConfigFile.new()
	seed.set_value("settings", "active_profile", "Default")
	seed.set_value("profile.Default.enabled", "a@1.0", true)
	seed.set_value("mod_sources", "foo@2.0",
			ml._serialize_mod_source_rec({"provider": "vostokmods", "id": "foo", "version": "2.0"}))
	_assert(seed.save(str(ml.UI_CONFIG_PATH)) == OK, "pack fixture: seeded mod_config.cfg")

func _pack_write(ml: Object, profile: Dictionary, mcm_value: String) -> Dictionary:
	_remove_user_file(PACK_ZIP)
	var zip_path := _write_zip(PACK_ZIP, {
		"profile.json": JSON.stringify(profile),
		"MCM/some-mod/config.ini": "[a]\nv=" + mcm_value + "\n",
	})
	var entry: Dictionary = ml._build_modpack_entry(zip_path)
	var packs: Array[Dictionary] = [entry]
	ml.set("_modpack_entries", packs)
	return entry

func _installed_entry(profile_key: String, mod_id: String, version: String) -> Dictionary:
	return {
		"file_name": mod_id + ".zip", "full_path": "/nonexistent/" + mod_id + ".zip", "ext": "zip",
		"mod_name": mod_id, "mod_id": mod_id, "version": version, "profile_key": profile_key,
		"enabled": true, "priority": 0, "priority_default": 0, "cfg": null,
	}

# Applying a pack replaces the player's MCM settings and unload puts them
# back. A player who had no MCM folder before the apply has none after the
# unload, and the pack's settings are not seeded into their own profile slot.
func _t16_unload_leaves_no_pack_mcm_behind(ml: Object) -> void:
	_pack_setup(ml)
	var entry := _pack_write(ml, {"metroprofile": 1, "name": "Round Trip", "enabled": {"a@1.0": true}}, "1")
	var r: Dictionary = await ml.apply_modpack(entry, null, Callable())
	_assert(bool(r.get("ok", false)), "T16: the pack applies (got %s)" % str(r.get("error", "")))
	_assert(FileAccess.file_exists("user://MCM/some-mod/config.ini"), "T16: the pack's MCM is live while it is active")
	var u: Dictionary = ml.unload_modpack(null)
	_assert(bool(u.get("ok", false)), "T16: the pack unloads (got %s)" % str(u.get("error", "")))
	_assert(str(ml.get("_active_profile")) == "Default", "T16: unload returns to the profile the player was on")
	_assert(not FileAccess.file_exists("user://MCM/some-mod/config.ini"),
			"T16: unload leaves no pack MCM behind when the player had none before")
	_assert(not FileAccess.file_exists("user://.profile_snapshots/Default/MCM/some-mod/config.ini"),
			"T16: the pack's MCM is not seeded into the player's own profile slot")
	_assert(not DirAccess.dir_exists_absolute(ProjectSettings.globalize_path("user://.profile_snapshots/_before_modpack_Round Trip")),
			"T16: the consumed backup slot is removed")

	# A player who did have MCM settings gets exactly those back.
	_pack_setup(ml)
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("user://MCM/mine"))
	var mine := FileAccess.open("user://MCM/mine/config.ini", FileAccess.WRITE)
	mine.store_string("[m]\nv=own\n")
	mine.close()
	entry = _pack_write(ml, {"metroprofile": 1, "name": "Round Trip", "enabled": {"a@1.0": true}}, "1")
	r = await ml.apply_modpack(entry, null, Callable())
	_assert(bool(r.get("ok", false)) and not FileAccess.file_exists("user://MCM/mine/config.ini"),
			"T16: while the pack is active its MCM replaces the player's")
	var retained := "user://.profile_snapshots/_before_modpack_Round Trip/overrides/Preferences.tres"
	DirAccess.make_dir_recursive_absolute(retained.get_base_dir())
	var original := FileAccess.open(retained, FileAccess.WRITE)
	original.store_string("player preferences")
	original.close()
	ml.unload_modpack(null)
	_assert(FileAccess.file_exists(retained), "T16: unload preserves files outside the consumed MCM snapshot")
	_assert(FileAccess.get_file_as_string("user://MCM/mine/config.ini").contains("v=own")
			and not FileAccess.file_exists("user://MCM/some-mod/config.ini"),
			"T16: unload restores the player's own MCM and nothing of the pack's")
	_pack_cleanup(ml)

# A pack keys a mod it has never seen installed by its host ("vostokmods:foo").
# Once the mod is installed the slot's key is rewritten to the mod's own key.
# That has to happen on every path a mod can land: an apply over a slot kept
# from an earlier apply, and a download outside the apply loop (a missing-mod
# row's Download, Retry).
func _t17_pack_keys_follow_the_installed_mods(ml: Object) -> void:
	_assert(ml.has_method("_modpack_reconcile_active"), "T17: the loader has _modpack_reconcile_active")
	if not ml.has_method("_modpack_reconcile_active"):
		return
	_pack_setup(ml)
	var cfg_path := str(ml.UI_CONFIG_PATH)
	var pack := {"metroprofile": 1, "name": "Round Trip",
			"enabled": {"a@1.0": true, "vostokmods:foo": true},
			"sources": {"vostokmods:foo": {"provider": "vostokmods", "id": "foo"}}}
	var entry := _pack_write(ml, pack, "1")
	var slot := "modpack__" + str(entry.get("sanitized_name", ""))
	# An earlier apply failed to download foo and left the slot keyed by the
	# pack. The player unloaded, installed foo another way, and applies again.
	var kept := ConfigFile.new()
	kept.load(cfg_path)
	kept.set_value("profile." + slot + ".enabled", "a@1.0", true)
	kept.set_value("profile." + slot + ".enabled", "vostokmods:foo", true)
	kept.set_value("profile." + slot + ".priority", "a@1.0", 77)
	kept.save(cfg_path)
	var r: Dictionary = await ml.apply_modpack(entry, null, Callable())
	_assert(bool(r.get("ok", false)), "T17: the pack applies over its kept slot (got %s)" % str(r.get("error", "")))
	var after_apply := ConfigFile.new()
	after_apply.load(cfg_path)
	_assert(int(after_apply.get_value("profile." + slot + ".priority", "a@1.0", 0)) == 77,
			"T17: applying over a kept slot keeps the player's edit")
	_assert(after_apply.has_section_key("profile." + slot + ".enabled", "foo@2.0")
			and not after_apply.has_section_key("profile." + slot + ".enabled", "vostokmods:foo"),
			"T17: applying over a kept slot reconciles its keys with the mods installed since")

	# While the pack is active a download lands outside the apply loop.
	var stub := ConfigFile.new()
	stub.load(cfg_path)
	stub.erase_section_key("profile." + slot + ".enabled", "foo@2.0")
	stub.set_value("profile." + slot + ".enabled", "vostokmods:foo", true)
	stub.save(cfg_path)
	_assert(int(ml._modpack_reconcile_active()) == 1, "T17: the active pack's stub key is reconciled")
	var resolved := ConfigFile.new()
	resolved.load(cfg_path)
	_assert(resolved.has_section_key("profile." + slot + ".enabled", "foo@2.0")
			and not resolved.has_section_key("profile." + slot + ".enabled", "vostokmods:foo"),
			"T17: the stub key moved to the key the mod is installed under")
	ml.unload_modpack(null)
	_assert(int(ml._modpack_reconcile_active()) == 0, "T17: with no pack active there is nothing to reconcile")
	_pack_cleanup(ml)

# The slot is kept on unload, so a plain second apply reads the slot and not
# the zip. When Refresh rewrote the zip from the site the slot is dropped, and
# the next apply is built from the new zip: mod list, priorities and MCM.
func _t18_refreshed_pack_rebuilds_its_slot(ml: Object) -> void:
	_assert(ml.has_method("_modpack_forget_slot"), "T18: the loader has _modpack_forget_slot")
	if not ml.has_method("_modpack_forget_slot"):
		return
	_pack_setup(ml)
	var cfg_path := str(ml.UI_CONFIG_PATH)
	var entry := _pack_write(ml, {"metroprofile": 1, "name": "Round Trip", "enabled": {"a@1.0": true}, "priority": {"a@1.0": 5}}, "1")
	var sanitized := str(entry.get("sanitized_name", ""))
	var slot := "modpack__" + sanitized
	var r: Dictionary = await ml.apply_modpack(entry, null, Callable())
	_assert(bool(r.get("ok", false)), "T18: the pack applies (got %s)" % str(r.get("error", "")))
	_assert(not bool(ml._modpack_forget_slot(sanitized)), "T18: the active pack's slot is never dropped")
	ml.unload_modpack(null)

	var v2 := {"metroprofile": 1, "name": "Round Trip", "enabled": {"a@1.0": true, "foo@2.0": true}, "priority": {"a@1.0": 9}}
	entry = _pack_write(ml, v2, "2")
	r = await ml.apply_modpack(entry, null, Callable())
	var kept := ConfigFile.new()
	kept.load(cfg_path)
	_assert(bool(r.get("ok", false)) and int(kept.get_value("profile." + slot + ".priority", "a@1.0", 0)) == 5,
			"T18: a second apply reads the kept slot, not the zip")
	ml.unload_modpack(null)

	_assert(bool(ml._modpack_forget_slot(sanitized)), "T18: a kept slot can be dropped")
	var dropped := ConfigFile.new()
	dropped.load(cfg_path)
	_assert(not dropped.has_section("profile." + slot + ".enabled") and not dropped.has_section("profile." + slot + ".priority"),
			"T18: dropping a slot erases its sections")
	_assert(not DirAccess.dir_exists_absolute(ProjectSettings.globalize_path("user://.profile_snapshots/" + slot)),
			"T18: dropping a slot removes its MCM snapshot")
	_assert(dropped.has_section("profile.Default.enabled"), "T18: the player's own profile is untouched")
	r = await ml.apply_modpack(entry, null, Callable())
	var rebuilt := ConfigFile.new()
	rebuilt.load(cfg_path)
	_assert(bool(r.get("ok", false)) and int(rebuilt.get_value("profile." + slot + ".priority", "a@1.0", 0)) == 9
			and rebuilt.has_section_key("profile." + slot + ".enabled", "foo@2.0"),
			"T18: the rebuilt slot carries the new zip's mod list and priorities")
	_assert(FileAccess.get_file_as_string("user://MCM/some-mod/config.ini").contains("v=2"),
			"T18: the rebuilt slot carries the new zip's MCM")
	ml.unload_modpack(null)
	_pack_cleanup(ml)

# The Apply confirmation previews what an apply would download. The preview
# writes nothing, and it counts only what can be downloaded: a mod the site
# cannot serve, or one the pack names no source for, is listed after the
# apply for a manual install, not downloaded.
func _t19_apply_preview_is_read_only(ml: Object) -> void:
	_assert(ml.has_method("_modpack_download_counts"), "T19: the loader has _modpack_download_counts")
	if not ml.has_method("_modpack_download_counts"):
		return
	_pack_setup(ml)
	var cfg_path := str(ml.UI_CONFIG_PATH)
	var pack := {"metroprofile": 1, "name": "Preview",
			"enabled": {"a@1.0": true, "vostokmods:new-mod": true, "vostokmods:scanning": true, "nosource@1.0": true},
			"sources": {"vostokmods:new-mod": {"provider": "vostokmods", "id": "new-mod", "version": "1.0"}},
			"unavailable": {"vostokmods:scanning": "scanning"}}
	var entry := _pack_write(ml, pack, "1")
	_remove_user_file(cfg_path + ".bak")
	var before := FileAccess.get_file_as_string(cfg_path)
	var missing: Array = ml._get_missing_mods_for_modpack(entry)
	_assert(missing.size() == 3, "T19: three of the four listed mods are not installed (got %d)" % missing.size())
	_assert(FileAccess.get_file_as_string(cfg_path) == before and not FileAccess.file_exists(cfg_path + ".bak"),
			"T19: previewing an apply writes nothing to mod_config.cfg")
	var counts: Dictionary = ml._modpack_download_counts(missing)
	_assert(int(counts.get("download", -1)) == 1 and int(counts.get("blocked", -1)) == 2,
			"T19: one mod downloads, two are listed for a manual install (got %s)" % str(counts))
	var nothing: Dictionary = ml._modpack_download_counts([])
	_assert(int(nothing.get("download", -1)) == 0 and int(nothing.get("blocked", -1)) == 0,
			"T19: nothing missing counts as nothing")
	_pack_cleanup(ml)

# --- T20: what a response says about the rate limit ----------------------------

# The cooldown is per provider and armed from a response's status and headers.
# Every caller goes through host_note_rate_headers, the download path included.
func _t20_rate_limit_headers(ml: Object) -> void:
	var cooldowns: Dictionary = ml.get("_host_cooldown_until_ms")
	cooldowns.clear()
	ml.host_note_rate_headers("modworkshop", 200, PackedStringArray(["X-RateLimit-Remaining: 12"]))
	_assert(int(ml.host_rate_cooldown_seconds("modworkshop")) == 0, "T20: a 2xx with budget left arms nothing")
	ml.host_note_rate_headers("modworkshop", 429, PackedStringArray(["Retry-After: 30"]))
	var secs := int(ml.host_rate_cooldown_seconds("modworkshop"))
	_assert(secs >= 29 and secs <= 30, "T20: Retry-After in seconds is honored (got %d)" % secs)
	cooldowns.clear()
	ml.host_note_rate_headers("modworkshop", 429, PackedStringArray(["Retry-After: Wed, 21 Oct 2026 07:28:00 GMT"]))
	secs = int(ml.host_rate_cooldown_seconds("modworkshop"))
	_assert(secs >= 59 and secs <= 60, "T20: an HTTP-date Retry-After falls back to the default window (got %d)" % secs)
	cooldowns.clear()
	ml.host_note_rate_headers("vostokmods", 429, PackedStringArray())
	secs = int(ml.host_rate_cooldown_seconds("vostokmods"))
	_assert(secs >= 59 and secs <= 60, "T20: a 429 from a host with no rate dialect arms the default window (got %d)" % secs)
	_assert(int(ml.host_rate_cooldown_seconds("modworkshop")) == 0, "T20: and leaves the other host alone")
	cooldowns.clear()

# --- T21: the ModWorkshop listing request ---------------------------------------

func _t21_mws_list_params(ml: Object) -> void:
	_assert(ml.has_method("_mwsp_list_params"), "T21: the loader has _mwsp_list_params")
	if not ml.has_method("_mwsp_list_params"):
		return
	var plain := "&".join(ml._mwsp_list_params({}, 1) as PackedStringArray)
	_assert(plain == "sort=bumped_at&limit=50&page=1", "T21: an empty query asks for the default sort and a full page (got '%s')" % plain)
	var landing := "&".join(ml._mwsp_list_params({"sort_key": "weekly_score", "limit": 10}, 1) as PackedStringArray)
	_assert(landing == "sort=weekly_score&limit=10&page=1", "T21: a landing section's limit reaches the request (got '%s')" % landing)
	var greedy := "&".join(ml._mwsp_list_params({"limit": 500}, 3) as PackedStringArray)
	_assert(greedy == "sort=bumped_at&limit=50&page=3", "T21: a limit above the host's cap is clamped to it (got '%s')" % greedy)
	var search := "&".join(ml._mwsp_list_params({"query": "night vision", "category_ref": "12"}, 1) as PackedStringArray)
	_assert(search == "query=night%20vision&sort=bumped_at&limit=50&page=1&category_id=12", "T21: query and category are carried (got '%s')" % search)

# --- T22: what the update check tells the player --------------------------------

func _t22_update_check_message(ml: Object) -> void:
	_assert(ml.has_method("_updates_check_message"), "T22: the loader has _updates_check_message")
	if not ml.has_method("_updates_check_message"):
		return
	var cooldowns: Dictionary = ml.get("_host_cooldown_until_ms")
	cooldowns.clear()
	var none := str(ml._updates_check_message({"checked": 0, "with_updates": 0, "errors": 0, "no_version": 0}, []))
	_assert(none.contains("say where they came from"), "T22: nothing to check because no mod names a site (got '%s')" % none)
	var unversioned := str(ml._updates_check_message({"checked": 0, "with_updates": 0, "errors": 0, "no_version": 2}, []))
	_assert(unversioned.contains("version") and not unversioned.contains("say where they came from"),
			"T22: mods skipped for having no version are not blamed on a missing site (got '%s')" % unversioned)
	var offline := str(ml._updates_check_message({"checked": 3, "with_updates": 0, "errors": 3, "no_version": 0}, ["modworkshop"]))
	_assert(offline.contains("connection"), "T22: every check failing with no cooldown running points at the connection (got '%s')" % offline)
	ml.host_arm_cooldown("modworkshop", 30000)
	var limited := str(ml._updates_check_message({"checked": 3, "with_updates": 0, "errors": 3, "no_version": 0}, ["modworkshop"]))
	_assert(limited.contains("rate limit") and not limited.contains("connection"),
			"T22: every check failing while the site's cooldown runs says rate limit (got '%s')" % limited)
	cooldowns.clear()
	var fine := str(ml._updates_check_message({"checked": 4, "with_updates": 0, "errors": 1, "no_version": 1}, ["modworkshop"]))
	_assert(fine.contains("Checked 3 mod(s)") and fine.contains("1 could not be checked") and fine.contains("1 skipped"),
			"T22: the up-to-date message counts failures and versionless mods (got '%s')" % fine)
	var some := str(ml._updates_check_message({"checked": 4, "with_updates": 2, "errors": 0, "no_version": 0}, ["modworkshop"]))
	_assert(some == "2 update(s) available.", "T22: updates are counted (got '%s')" % some)
	var skipped := {}
	var entries: Array[Dictionary] = [_installed_entry("q@", "q", "")]
	var cfg := ConfigFile.new()
	cfg.parse("[mod]\nname=\"Q\"\nid=\"q\"\n[updates]\nsource=\"vostokmods:q\"\n")
	entries[0]["cfg"] = cfg
	var pending: Array = ml._updates_check_candidates(entries, {}, skipped)
	_assert(pending.is_empty() and int(skipped.get("no_version", 0)) == 1,
			"T22: a mod with a site and no version is counted as skipped (got %s, %s)" % [str(pending), str(skipped)])

# --- T23: why a download failed --------------------------------------------------

func _t23_download_failure_text(ml: Object) -> void:
	_assert(ml.has_method("_download_failure_text"), "T23: the loader has _download_failure_text")
	if not ml.has_method("_download_failure_text"):
		return
	(ml.get("_host_cooldown_until_ms") as Dictionary).clear()
	var too_big := str(ml._download_failure_text("modworkshop", HTTPRequest.RESULT_BODY_SIZE_LIMIT_EXCEEDED, 200))
	_assert(too_big.contains("256 MB") and not too_big.contains("network"),
			"T23: a file over the size cap is named as such, not as a network problem (got '%s')" % too_big)
	var dropped := str(ml._download_failure_text("modworkshop", HTTPRequest.RESULT_CANT_CONNECT, 0))
	_assert(dropped.contains("network"), "T23: a transport failure points at the network (got '%s')" % dropped)
	var refused := str(ml._download_failure_text("modworkshop", HTTPRequest.RESULT_SUCCESS, 404))
	_assert(refused.contains("HTTP 404"), "T23: an HTTP failure carries its status (got '%s')" % refused)

# --- T24: a pack file's format version ---------------------------------------------

func _t24_pack_format_version(ml: Object) -> void:
	_pack_cleanup(ml)
	var newer := _pack_write(ml, {"metroprofile": 2, "name": "Newer", "enabled": {}}, "1")
	var res: Dictionary = ml._validate_modpack(newer)
	_assert(not bool(res["ok"]) and str(res["error"]).contains("newer version of the mod loader"),
			"T24: a pack with a higher format version asks for a loader update (got '%s')" % str(res["error"]))
	var unmarked := _pack_write(ml, {"name": "Unmarked", "enabled": {}}, "1")
	res = ml._validate_modpack(unmarked)
	_assert(not bool(res["ok"]) and not str(res["error"]).contains("newer version"),
			"T24: a pack with no format version is not blamed on an old loader (got '%s')" % str(res["error"]))
	var current := _pack_write(ml, {"metroprofile": 1, "name": "Current", "enabled": {}}, "1")
	_assert(bool((ml._validate_modpack(current) as Dictionary)["ok"]), "T24: format version 1 validates")
	_pack_cleanup(ml)

# --- T25: version ordering ---------------------------------------------------------

# compare_versions decides whether the update check offers a file and which of
# two copies of one mod loads. A prerelease ranks below its own release.
func _t25_version_ordering(ml: Object) -> void:
	var cases := [
		["1.0.0", "1.0.0", 0], ["1.2", "1.10", -1], ["v2.0", "1.9.9", 1], ["1.0", "1.0.0", 0],
		["1.0.0-beta.1", "1.0.0", -1], ["1.0.0", "1.0.0-rc.2", 1],
		["1.0.0-beta.2", "1.0.0-beta.10", -1], ["1.0.0-alpha", "1.0.0-beta", -1],
		["1.0.1-beta.1", "1.0.0", 1], ["1.0.0+build.5", "1.0.0", 0],
		["", "1.0", -1], ["1.0", "", 1], ["", "", 0],
	]
	for c in cases:
		var got := int(ml.compare_versions(str(c[0]), str(c[1])))
		_assert(got == int(c[2]), "T25: compare_versions('%s', '%s') is %d (got %d)" % [c[0], c[1], c[2], got])
	# The update check offers the stable release to a mod installed at its beta.
	var pending := [{"profile_key": "m@1.0.0-beta.1", "ref": ml.host_ref("vostokmods", "m"), "version": "1.0.0-beta.1", "full_path": "", "mod_name": "M"}]
	var summary: Dictionary = ml._updates_check_apply(pending, {"vostokmods:m": "1.0.0"})
	_assert(int(summary["with_updates"]) == 1, "T25: a stable release is an update for its own prerelease (got %s)" % str(summary))
	(ml.get("_mod_updates_state") as Dictionary).erase("m@1.0.0-beta.1")

# --- T26: is a derived file name the installed archive itself ---------------------

# An update can rename the archive. On a file system that ignores case, a new
# name that differs only in case is the installed file, not a collision.
func _t26_same_file_name(ml: Object) -> void:
	_assert(ml.has_method("_same_file_name"), "T26: the loader has _same_file_name")
	if not ml.has_method("_same_file_name"):
		return
	_assert(bool(ml._same_file_name("CoolMod.zip", "CoolMod.zip")), "T26: equal names are the same file")
	_assert(not bool(ml._same_file_name("CoolMod.zip", "OtherMod.zip")), "T26: different names are not")
	var ignores_case := OS.get_name() in ["Windows", "macOS"]
	_assert(bool(ml._same_file_name("CoolMod.zip", "coolmod.zip")) == ignores_case,
			"T26: a case-only difference is the same file exactly where the file system ignores case")

# --- T27: where a download is allowed to land ---------------------------------------

# The file name of a download comes from the server. Everything it can say is
# untrusted: only a bare .vmz/.zip/.pck name may be joined onto the mods folder.
func _t27_download_file_names(ml: Object) -> void:
	for bad in ["", "../evil.zip", "..\\evil.zip", "sub/evil.zip", "C:evil.zip", ".hidden.zip", "evil.zip:stream", "readme.txt", "mod.exe"]:
		_assert(not bool(ml._is_safe_mod_filename(bad)), "T27: '%s' is not a safe mod file name" % bad)
	for good in ["CoolMod.vmz", "Cool Mod v1.2.zip", "pack.PCK"]:
		_assert(bool(ml._is_safe_mod_filename(good)), "T27: '%s' is a safe mod file name" % good)
	var cd := func(value: String) -> String:
		return str(ml._filename_from_content_disposition(PackedStringArray(["Content-Type: application/zip", "Content-Disposition: " + value])))
	_assert(cd.call('attachment; filename="CoolMod.vmz"') == "CoolMod.vmz", "T27: a quoted filename is read")
	_assert(cd.call("attachment; filename=CoolMod.zip; size=3") == "CoolMod.zip", "T27: an unquoted filename is read")
	_assert(cd.call("attachment; filename=\"Cool%20Mod.zip\"") == "Cool Mod.zip", "T27: a percent-encoded filename is decoded")
	_assert(cd.call("attachment; filename=\"fallback.zip\"; filename*=UTF-8''Na%C3%AFve.zip") != "fallback.zip", "T27: filename* wins over filename")
	_assert(cd.call('attachment; filename="../../evil.zip"') == "", "T27: a traversing filename is refused, not trimmed")
	_assert(cd.call('attachment; filename="..%2F..%2Fevil.zip"') == "", "T27: an encoded traversal is refused after decoding")
	_assert(cd.call('attachment; filename="notes.txt"') == "", "T27: a name that is not a mod archive is refused")
	_assert(str(ml._filename_from_content_disposition(PackedStringArray(["X-Other: 1"]))) == "", "T27: no header, no name")
	var none := PackedStringArray()
	_assert(str(ml._derive_updated_filename("CoolMod_v1.0.vmz", none, "1.1")) == "CoolMod_v1.1.vmz", "T27: an update swaps the version suffix")
	_assert(str(ml._derive_updated_filename("CoolMod.vmz", none, "v2.0")) == "CoolMod_v2.0.vmz", "T27: an update adds a version suffix")
	_assert(str(ml._derive_updated_filename("CoolMod.vmz", none, "")) == "CoolMod.vmz", "T27: no version keeps the name")
	_assert(str(ml._derive_updated_filename("CoolMod.vmz", none, "../../1.0")) == "CoolMod.vmz", "T27: a version that is not a file name keeps the old name")
	_assert(str(ml._derive_updated_filename("CoolMod.vmz", PackedStringArray(['Content-Disposition: attachment; filename="Renamed.zip"']), "9")) == "Renamed.zip",
			"T27: a safe server name wins over the derived one")

# --- T28: mod.txt dependency lists and the load-order tie-break --------------------

# Paste, Get and Refresh share the import boundary. A changed zip must not
# reuse the slot from an earlier apply, and an active pack cannot be replaced.
func _t30_reimport_hosted_pack(ml: Object) -> void:
	_pack_setup(ml)
	var previous_dir := str(ml.get("_mods_dir"))
	var mods_dir := "user://t30_mods"
	DirAccess.make_dir_recursive_absolute(mods_dir)
	ml.set("_mods_dir", mods_dir)
	var manifest := {"format": 2, "name": "Hosted Again", "slug": "hosted-again", "hash": "one",
			"mods": [{"slug": "foo", "version": "2.0", "available": true, "loadOrder": 5}],
			"mcmConfig": {"some-mod/config.ini": "[a]\nv=1\n"}}
	var imported: Dictionary = ml._hosted_import_manifest(manifest)
	_assert(bool(imported["ok"]), "T30: initial import succeeds")
	var entry: Dictionary = ml._build_modpack_entry(str(imported["file_path"]))
	var applied: Dictionary = await ml.apply_modpack(entry, null, Callable())
	_assert(bool(applied["ok"]), "T30: initial hosted pack applies without downloads")
	var before := FileAccess.get_file_as_bytes(str(imported["file_path"]))
	var same: Dictionary = ml._hosted_import_manifest(manifest)
	_assert(bool(same["ok"]), "T30: an unchanged import keeps the active pack")
	manifest["hash"] = "two"
	manifest["mods"][0]["loadOrder"] = 9
	manifest["mcmConfig"]["some-mod/config.ini"] = "[a]\nv=2\n"
	var refused: Dictionary = ml._hosted_import_manifest(manifest)
	_assert(not bool(refused["ok"]) and str(refused["error"]).contains("Unload"),
			"T30: a changed active pack must be unloaded before reimport")
	_assert(before == FileAccess.get_file_as_bytes(str(imported["file_path"])),
			"T30: refusing reimport leaves the active zip intact")
	ml.unload_modpack(null)
	var refreshed: Dictionary = ml._hosted_import_manifest(manifest)
	_assert(bool(refreshed["ok"]), "T30: changed inactive pack imports")
	entry = ml._build_modpack_entry(str(refreshed["file_path"]))
	applied = await ml.apply_modpack(entry, null, Callable())
	var cfg := ConfigFile.new()
	cfg.load(str(ml.UI_CONFIG_PATH))
	var sec := "profile.modpack__" + str(entry["sanitized_name"]) + ".priority"
	_assert(bool(applied["ok"]) and int(cfg.get_value(sec, "foo@2.0", 0)) == 9,
			"T30: reimport applies the new priority instead of the kept slot")
	_assert(FileAccess.get_file_as_string("user://MCM/some-mod/config.ini").contains("v=2"),
			"T30: reimport applies the new MCM settings")
	ml.unload_modpack(null)
	ml._remove_tree(mods_dir, false)
	ml.set("_mods_dir", previous_dir)
	_pack_cleanup(ml)

# A pack name with no cased letters sanitizes to "", which has no slot: the
# import falls back to the slug. A manifest the loader refuses keeps the
# validator's reason instead of the generic bad-response copy.
# The loader is listed on both sites so players can find it, but it is not a
# mod: Download in Browse would put the loader's own zip into mods/, where it
# shows as a broken mod and gets mounted over res://modloader.gd.
func _t32_browse_hides_the_loaders_own_listing(ml: Object) -> void:
	var own: Dictionary = ml.HOST_OWN_LISTINGS
	_assert(str(own.get(ml.HOST_VOSTOKMODS, "")) == "metro-mod-loader" and str(own.get(ml.HOST_MODWORKSHOP, "")) == "55623",
			"T32: the two known listings are named (got %s)" % str(own))
	for provider: String in own:
		var rows := []
		for id in ["some-mod", str(own[provider]), "another-mod"]:
			var row: Dictionary = ml.host_empty_summary()
			row["ref"] = ml.host_ref(provider, id)
			row["name"] = id
			rows.append(row)
		var page: Dictionary = ml.host_page(rows, true, "2", 3)
		var shown: Dictionary = ml._host_hide_own_listing(provider, ml.host_ok(page))
		var names := PackedStringArray()
		for r in ((shown["data"] as Dictionary)["rows"] as Array):
			names.append(str((r as Dictionary)["name"]))
		_assert(names == PackedStringArray(["some-mod", "another-mod"]),
				"T32: %s still lists the loader, or lost a real mod (got %s)" % [provider, str(names)])
		_assert(bool((shown["data"] as Dictionary)["has_more"]) and str((shown["data"] as Dictionary)["next_cursor"]) == "2",
				"T32: paging survives the filter on %s" % provider)
	# Another host's id that happens to match is a different mod.
	var other: Dictionary = ml.host_empty_summary()
	other["ref"] = ml.host_ref(ml.HOST_MODWORKSHOP, "metro-mod-loader")
	var kept: Dictionary = ml._host_hide_own_listing(ml.HOST_MODWORKSHOP, ml.host_ok(ml.host_page([other], false, "", 1)))
	_assert(((kept["data"] as Dictionary)["rows"] as Array).size() == 1, "T32: the id is matched per host")
	# A failed result passes through untouched.
	var failed: Dictionary = ml.host_err(ml.HOST_ERR_BAD_RESPONSE, 0, "x")
	_assert(ml._host_hide_own_listing(ml.HOST_VOSTOKMODS, failed) == failed, "T32: an error result is returned as it came")
	# The offline landing is read back from disk, and a file written by a build
	# that did not filter yet can hold the loader's row.
	var snapshots: Dictionary = ml.get("_browse_landing_snapshots")
	for provider: String in own:
		var saved_rows := []
		for id in ["some-mod", str(own[provider])]:
			var row: Dictionary = ml.host_empty_summary()
			row["ref"] = ml.host_ref(provider, id)
			row["name"] = id
			saved_rows.append(row)
		var snap_path := str(ml._browse_landing_snapshot_path(provider))
		DirAccess.make_dir_recursive_absolute(snap_path.get_base_dir())
		var f := FileAccess.open(snap_path, FileAccess.WRITE)
		f.store_string(JSON.stringify({"sections": [{"title": "Popular", "rows": saved_rows}], "saved_at_unix": 1700000000}))
		f.close()
		snapshots.erase(provider)
		var snap: Dictionary = ml._browse_landing_snapshot(provider)
		var saved_names := PackedStringArray()
		for sec in (snap.get("sections", []) as Array):
			for r in ((sec as Dictionary)["rows"] as Array):
				saved_names.append(str((r as Dictionary)["name"]))
		_assert(saved_names == PackedStringArray(["some-mod"]),
				"T32: the saved %s landing still lists the loader, or lost a real mod (got %s)" % [provider, str(saved_names)])
		_assert(int(snap.get("saved_at_unix", 0)) == 1700000000, "T32: the saved %s landing keeps its timestamp" % provider)
		snapshots.erase(provider)
		DirAccess.remove_absolute(snap_path)

func _t31_hosted_pack_names_and_errors(ml: Object) -> void:
	_pack_setup(ml)
	var previous_dir := str(ml.get("_mods_dir"))
	var mods_dir := "user://t31_mods"
	DirAccess.make_dir_recursive_absolute(mods_dir)
	ml.set("_mods_dir", mods_dir)
	var uncased := char(0x751F) + char(0x5B58) + " " + char(0x5305)
	_assert(str(ml._sanitize_profile_name(uncased)).strip_edges() == "", "T31: fixture name has no cased letters")
	var manifest := {"format": 2, "name": uncased, "slug": "survival-cn", "hash": "one",
			"mods": [{"slug": "foo", "version": "2.0", "available": true, "loadOrder": 1}]}
	var imported: Dictionary = ml._hosted_import_manifest(manifest)
	_assert(bool(imported["ok"]) and str(imported["name"]) == "survival-cn",
			"T31: a name with no usable characters imports under the slug (got '%s')" % str(imported.get("name", "")))
	if bool(imported["ok"]):
		var entry: Dictionary = ml._build_modpack_entry(str(imported["file_path"]))
		_assert(str(entry.get("sanitized_name", "")) == "survival-cn", "T31: the imported pack has a slot name")
		var applied: Dictionary = await ml.apply_modpack(entry, null, Callable())
		_assert(bool(applied["ok"]), "T31: the imported pack applies (%s)" % str(applied.get("error", "")))
		ml.unload_modpack(null)
	var too_new: Dictionary = ml.host_err(ml.HOST_ERR_BAD_RESPONSE, 0, str(ml._vmp_validate_manifest({"format": 99, "mods": []})))
	_assert(str(ml._hosted_fetch_error_copy(too_new)).contains("update the mod loader"),
			"T31: a too-new manifest tells the player to update the loader")
	var offline: Dictionary = ml.host_err(ml.HOST_ERR_OFFLINE, 0, "")
	_assert(str(ml._hosted_fetch_error_copy(offline)) == str(ml.host_error_message(ml.HOST_VOSTOKMODS, offline)),
			"T31: other failures keep the shared host copy")
	var bare: Dictionary = ml.host_err(ml.HOST_ERR_BAD_RESPONSE, 0, "")
	_assert(str(ml._hosted_fetch_error_copy(bare)) == str(ml.host_error_message(ml.HOST_VOSTOKMODS, bare)),
			"T31: a bad response with no reason keeps the shared host copy")
	ml._remove_tree(mods_dir, false)
	ml.set("_mods_dir", previous_dir)
	_pack_cleanup(ml)

# A source pin must not enable another installed version, including after a
# failed download. Older pins must fail before the newest-copy selector can
# hide their download.
func _t29_pack_version_pins(ml: Object) -> void:
	_pack_setup(ml)
	var pack := {"metroprofile": 1, "name": "Pinned", "enabled": {"vostokmods:foo": true},
			"priority": {"vostokmods:foo": 8}, "dep_ignore": {"vostokmods:foo": true},
			"sources": {"vostokmods:foo": {"provider": "vostokmods", "id": "foo", "version": "1.0"}}}
	for version in ["1.0", "3.0", "v2.0", ""]:
		pack["sources"]["vostokmods:foo"]["version"] = version
		var entry := _pack_write(ml, pack, "1")
		var result: Dictionary = ml._materialize_modpack_profile(entry, "modpack__Pinned")
		_assert(bool(result["ok"]), "T29: pinned fixture materializes")
		var cfg := ConfigFile.new()
		cfg.load(str(ml.UI_CONFIG_PATH))
		for suffix in [".enabled", ".priority", ".dep_ignore"]:
			var sec: String = "profile.modpack__Pinned" + suffix
			var match_pin: bool = version in ["v2.0", ""]
			_assert(cfg.has_section_key(sec, "foo@2.0") == match_pin,
					"T29: %s pin '%s' resolves only to its version" % [suffix, version])
			_assert(cfg.has_section_key(sec, "vostokmods:foo") != match_pin,
					"T29: %s keeps an unresolved pin as a missing row" % suffix)
	_pack_setup(ml)
	pack["sources"]["vostokmods:foo"]["version"] = "1.0"
	var entry := _pack_write(ml, pack, "1")
	_assert(ml.has_method("_modpack_pin_conflict"), "T29: apply has a version-conflict preflight")
	if ml.has_method("_modpack_pin_conflict"):
		var before := FileAccess.get_file_as_bytes(str(ml.UI_CONFIG_PATH))
		var result: Dictionary = await ml.apply_modpack(entry, null, Callable())
		_assert(not bool(result["ok"]) and str(result["error"]).contains("newer installed version"),
				"T29: an older pin is refused with an actionable conflict")
		_assert(int(result["downloaded"]) == 0 and int(result["failed_downloads"]) == 0,
				"T29: conflict is refused before downloading")
		_assert(before == FileAccess.get_file_as_bytes(str(ml.UI_CONFIG_PATH)),
				"T29: conflict does not change the profile or backup state")
		# A pack from the site pins the versions it had when fetched; a mod
		# updated since is fixed by refreshing the pack.
		var hosted_pack: Dictionary = pack.duplicate(true)
		hosted_pack["hosted"] = {"provider": "vostokmods", "slug": "round-trip"}
		_assert(str(ml._modpack_pin_conflict(_pack_write(ml, hosted_pack, "1"))).contains("Refresh the pack"),
				"T29: a pack from the site says to refresh it when a pinned mod was updated since")
		pack["sources"]["vostokmods:foo"]["version"] = "3.0"
		_assert(str(ml._modpack_pin_conflict(_pack_write(ml, pack, "1"))).is_empty(),
				"T29: a newer requested version can still be downloaded")
	_pack_cleanup(ml)

func _t28_dependency_lists_and_load_order(ml: Object) -> void:
	var cases := [
		['[dependencies]\nrequired=["a", "b"]\n', ["a", "b"]],
		['[dependencies]\nrequired="a, b , c"\n', ["a", "b", "c"]],
		['[dependencies]\nrequired="[a, \'b\']"\n', ["a", "b"]],
		['[dependencies]\nrequired=["A", "a", " ", ""]\n', ["A"]],
		['[mod]\nid="x"\n', []],
	]
	for c in cases:
		var cfg := ConfigFile.new()
		_assert(cfg.parse(str(c[0])) == OK, "T28: fixture parses: %s" % _oneline(str(c[0])))
		var got: Array = ml._parse_dependency_list(cfg, "required")
		_assert(got == Array(c[1]), "T28: required list of %s is %s (got %s)" % [_oneline(str(c[0])), str(c[1]), str(got)])
	_assert((ml._parse_dependency_list(null, "required") as Array).is_empty(), "T28: a null ConfigFile has no dependencies")
	var low := {"priority": 0, "mod_name": "Zeta", "file_name": "a.zip"}
	var high := {"priority": 5, "mod_name": "Alpha", "file_name": "b.zip"}
	_assert(bool(ml._compare_load_order(low, high)), "T28: a lower priority loads first whatever the names")
	var alpha := {"priority": 0, "mod_name": "alpha", "file_name": "z.zip"}
	_assert(bool(ml._compare_load_order(alpha, low)), "T28: equal priorities order by mod name, ignoring case")
	var twin := {"priority": 0, "mod_name": "Alpha", "file_name": "a.zip"}
	_assert(bool(ml._compare_load_order(twin, alpha)), "T28: equal names order by file name")

# The update check in two pure halves: which installed mods are asked about,
# and what the site's answers mean. A dev folder, a mod with no version, no
# source, no readable mod.txt or a host that cannot serve files is skipped;
# a missing answer is an error, an equal or newer installed version is up to
# date and clears a stale entry, an older one records an update.
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
	var pending: Array = ml._updates_check_candidates(entries, {})
	var keys: Array = []
	for p in pending:
		keys.append(str((p as Dictionary)["profile_key"]))
	_assert(keys == ["a@1.0", "f@2.0", "g@1.0"],
			"T13: only sourced, versioned, archive mods are checked (got %s)" % str(keys))
	ml._mod_updates_state["f@2.0"] = {"latest_version": "9.9", "current_version": "2.0"}
	var summary: Dictionary = ml._updates_check_apply(pending, {"vostokmods:a": "1.1", "modworkshop:5": "2.0"})
	_assert(int(summary["checked"]) == 3 and int(summary["with_updates"]) == 1 and int(summary["errors"]) == 1,
			"T13: counts are checked=3, with_updates=1, errors=1 (got %s)" % str(summary))
	var state: Dictionary = ml._mod_updates_state
	_assert(state.has("a@1.0") and str((state["a@1.0"] as Dictionary)["latest_version"]) == "1.1"
			and str((state["a@1.0"] as Dictionary)["current_version"]) == "1.0",
			"T13: an older installed version records the update (got %s)" % str(state.get("a@1.0")))
	_assert(not state.has("f@2.0"), "T13: an up-to-date mod clears its stale update entry")
	_assert(not state.has("g@1.0"), "T13: a mod the site did not answer for records nothing")
	state.clear()

func _update_entry(profile_key: String, ext: String, mod_txt: String) -> Dictionary:
	var cfg: ConfigFile = null
	if mod_txt != "":
		cfg = _cfg_from_text(mod_txt)
	return {"profile_key": profile_key, "ext": ext, "cfg": cfg,
			"full_path": "/mods/" + profile_key, "mod_name": profile_key}

# A pack's source record counts as installed when a mod with that host ref
# is on disk, at the pinned version when the record pins one. Versions
# compare without a v prefix, and a legacy modworkshop_id record resolves
# like a provider-qualified one. A record is downloadable only from a host
# this build can fetch files from.
func _t14_modpack_source_installed(ml: Object) -> void:
	var installed := {"vostokmods:rtvcoop": ["5.0.0", "v5.1.0"], "modworkshop:777": ["1.0"]}
	var cases := [
		# [label, record, want]
		["unpinned, installed", {"provider": "vostokmods", "id": "rtvcoop"}, true],
		["pinned to an installed version", {"provider": "vostokmods", "id": "rtvcoop", "version": "5.0.0"}, true],
		["pinned with a v prefix", {"provider": "vostokmods", "id": "rtvcoop", "version": "v5.0.0"}, true],
		["pinned to the v-prefixed installed copy", {"provider": "vostokmods", "id": "rtvcoop", "version": "5.1.0"}, true],
		["pinned to a version not on disk", {"provider": "vostokmods", "id": "rtvcoop", "version": "5.2.0"}, false],
		["not installed at all", {"provider": "vostokmods", "id": "other"}, false],
		["legacy modworkshop_id record", {"modworkshop_id": 777}, true],
		["legacy modworkshop_id pinned elsewhere", {"modworkshop_id": 777, "version": "2.0"}, false],
		["unknown provider", {"provider": "steam", "id": "1"}, false],
		["not a record", "rtvcoop", false],
	]
	for c in cases:
		var got := bool(ml._modpack_source_installed(c[1], installed))
		_assert(got == bool(c[2]), "T14 %s: want %s, got %s" % [str(c[0]), str(c[2]), str(got)])
	_assert(bool(ml._modpack_ref_downloadable(ml.host_ref("vostokmods", "x"))), "T14: a Vostok Mods ref is downloadable")
	_assert(bool(ml._modpack_ref_downloadable(ml.host_ref("modworkshop", "1"))), "T14: a ModWorkshop ref is downloadable")
	_assert(not bool(ml._modpack_ref_downloadable({})), "T14: an empty ref is not downloadable")
	_assert(not bool(ml._modpack_ref_downloadable({"provider": "steam", "id": "1"})), "T14: an unknown host is not downloadable")

# An installed mod whose mod.txt carries the UUID Vostok Mods writes since
# 2026-09-30 is keyed by that UUID, while Browse rows carry the slug. The
# Mods-tab memo holds the detail the UUID resolved to, so the install map
# must answer under both ids or Browse offers Download for an installed mod.
func _t33_install_map_keys_both_ids(ml: Object) -> void:
	_pack_cleanup(ml)
	var uuid := "019ff1f0-00ac-76a9-a23f-7151e4531131"
	var entry := _installed_entry("rtvcoop@5.0.0", "rtvcoop", "5.0.0")
	var cfg := ConfigFile.new()
	cfg.set_value("mod", "version", "5.0.0")
	cfg.set_value("updates", "source", "vostokmods:" + uuid)
	entry["cfg"] = cfg
	var installed: Array[Dictionary] = [entry]
	ml.set("_ui_mod_entries", installed)
	var memo: Dictionary = ml.get("_mods_meta_by_key")
	memo.clear()
	var map: Dictionary = ml._browse_install_map()
	_assert(map.has("vostokmods:" + uuid) and not map.has("vostokmods:rtvcoop"),
			"T33: before any detail answer only the UUID key exists (got %s)" % str(map.keys()))
	var detail: Dictionary = ml.host_empty_detail()
	detail["ref"] = ml.host_ref("vostokmods", "rtvcoop")
	memo["vostokmods:" + uuid] = detail
	map = ml._browse_install_map()
	_assert(map.has("vostokmods:" + uuid) and map.has("vostokmods:rtvcoop") and map["vostokmods:rtvcoop"] == entry,
			"T33: once the detail answered with the slug, both keys find the entry (got %s)" % str(map.keys()))
	memo.clear()
	_pack_cleanup(ml)

# Godot's WebP loader refuses a file with the animation flag, and both hosts
# serve animated covers, so the decoder rewraps the first frame as a still
# WebP. The fixtures wrap Godot's own still encodings, one per kind of frame:
# lossy, lossy with an ALPH chunk, lossless, and a frame smaller than the
# canvas. The second frame is always blue, so a blue result means the wrong
# frame was decoded.
func _t34_animated_webp_shows_its_first_frame(ml: Object) -> void:
	var red := Image.create_empty(48, 32, false, Image.FORMAT_RGB8)
	red.fill(Color(1, 0, 0))
	var blue := Image.create_empty(48, 32, false, Image.FORMAT_RGB8)
	blue.fill(Color(0, 0, 1))
	var blue_frame := {"chunks": _webp_frame_chunks(blue.save_webp_to_buffer(true, 0.9)),
			"offset": Vector2i.ZERO, "size": Vector2i(48, 32)}
	var full := Vector2i(48, 32)

	var still: Image = ml._decode_image_buffer(red.save_webp_to_buffer(true, 0.9))
	_assert(still != null and still.get_size() == full, "T34: a still lossy WebP still decodes")

	var lossy := _animated_webp(full, [{"chunks": _webp_frame_chunks(red.save_webp_to_buffer(true, 0.9)),
			"offset": Vector2i.ZERO, "size": full}, blue_frame])
	var img: Image = ml._decode_image_buffer(lossy)
	_assert(img != null and img.get_size() == full and _near(img.get_pixel(24, 16), Color(1, 0, 0)),
			"T34: an animated lossy WebP decodes to its red first frame (got %s)" % _describe(img, Vector2i(24, 16)))

	var half := Image.create_empty(48, 32, false, Image.FORMAT_RGBA8)
	half.fill_rect(Rect2i(0, 0, 24, 32), Color(0, 1, 0, 1))
	var alpha_still := half.save_webp_to_buffer(true, 0.9)
	_assert(alpha_still.slice(12, 16).get_string_from_ascii() == "VP8X" and ml._decode_image_buffer(alpha_still) != null,
			"T34: a still WebP with alpha is not mistaken for an animated one")
	var with_alpha := _animated_webp(full, [{"chunks": _webp_frame_chunks(alpha_still),
			"offset": Vector2i.ZERO, "size": full}, blue_frame])
	img = ml._decode_image_buffer(with_alpha)
	_assert(img != null and _near(img.get_pixel(8, 16), Color(0, 1, 0)) and img.get_pixel(40, 16).a < 0.1,
			"T34: a lossy first frame keeps its ALPH transparency (got %s / %s)"
					% [_describe(img, Vector2i(8, 16)), _describe(img, Vector2i(40, 16))])

	var lossless := _animated_webp(full, [{"chunks": _webp_frame_chunks(red.save_webp_to_buffer(false)),
			"offset": Vector2i.ZERO, "size": full}, blue_frame])
	img = ml._decode_image_buffer(lossless)
	_assert(img != null and img.get_pixel(24, 16).is_equal_approx(Color(1, 0, 0)),
			"T34: an animated lossless WebP decodes to its red first frame (got %s)" % _describe(img, Vector2i(24, 16)))

	var small := Image.create_empty(32, 32, false, Image.FORMAT_RGB8)
	small.fill(Color(1, 0, 0))
	var inset := _animated_webp(Vector2i(64, 64), [{"chunks": _webp_frame_chunks(small.save_webp_to_buffer(false)),
			"offset": Vector2i(16, 16), "size": Vector2i(32, 32)}, blue_frame])
	img = ml._decode_image_buffer(inset)
	_assert(img != null and img.get_size() == Vector2i(64, 64) and img.get_pixel(4, 4).a == 0.0
			and img.get_pixel(32, 32).is_equal_approx(Color(1, 0, 0)),
			"T34: a first frame smaller than the canvas sits at its offset on a clear canvas (got %s / %s)"
					% [_describe(img, Vector2i(4, 4)), _describe(img, Vector2i(32, 32))])

	_assert(ml._decode_image_buffer(lossy.slice(0, 60)) == null,
			"T34: an animated WebP cut off inside its first frame decodes to null")

# Vostok Mods names a mod by slug or UUID. A hosted pack keys its mods by
# slug, and the site writes the UUID into the mod.txt of every file it
# serves, so the installed mod resolves to the UUID. Unpaired, the pack's
# mod reads as missing and the apply would leave it disabled. Once a host
# response has paired the ids, the slug finds the mod: nothing is missing,
# the slot is keyed by the installed mod, and the mod is enabled.
func _t35_pack_slug_finds_the_mod_txt_uuid(ml: Object) -> void:
	_pack_cleanup(ml)
	var uuid := "01a0a18a-3e89-7977-a03a-c3b839ea00cf"
	var foo := _installed_entry("foo@2.0", "foo", "2.0")
	foo["enabled"] = false
	var foo_cfg := ConfigFile.new()
	foo_cfg.set_value("mod", "version", "2.0")
	foo_cfg.set_value("updates", "source", "vostokmods:" + uuid)
	foo["cfg"] = foo_cfg
	var installed: Array[Dictionary] = [_installed_entry("a@1.0", "a", "1.0"), foo]
	ml.set("_ui_mod_entries", installed)
	ml.set("_active_profile", "Default")
	var seed := ConfigFile.new()
	seed.set_value("settings", "active_profile", "Default")
	seed.set_value("profile.Default.enabled", "a@1.0", true)
	seed.set_value("mod_sources", "foo@2.0",
			ml._serialize_mod_source_rec({"provider": "vostokmods", "id": uuid, "version": "2.0"}))
	_assert(seed.save(str(ml.UI_CONFIG_PATH)) == OK, "T35: seeded mod_config.cfg")
	var entry := _pack_write(ml, {"metroprofile": 1, "name": "Round Trip",
			"enabled": {"a@1.0": true, "vostokmods:foo": true},
			"sources": {"vostokmods:foo": {"provider": "vostokmods", "id": "foo", "version": "2.0"}}}, "1")
	var aliases: Dictionary = ml.get("_host_ref_aliases")
	aliases.clear()
	(ml.get("_mods_meta_by_key") as Dictionary).clear()

	var ask: Array = ml._modpack_unpaired_host_refs(entry)
	_assert(ask.size() == 1 and str(ml.host_ref_key(ask[0])) == "vostokmods:" + uuid,
			"T35: unpaired, the apply asks the host about the installed mod's UUID (got %s)" % str(ask))
	_assert((ml._get_missing_mods_for_modpack(entry) as Array).size() == 1,
			"T35: unpaired, the pack's slug reads as missing")

	ml._vmp_note_ids({"id": uuid, "slug": "foo"})
	_assert("vostokmods:" + uuid in ml.host_ref_aliases("vostokmods:foo")
			and "vostokmods:foo" in ml.host_ref_aliases("vostokmods:" + uuid),
			"T35: a row with an id and a slug pairs them both ways")
	_assert((ml._modpack_unpaired_host_refs(entry) as Array).is_empty(), "T35: paired, the apply asks nothing")
	_assert((ml._get_missing_mods_for_modpack(entry) as Array).is_empty(),
			"T35: paired, the pack's slug finds the installed mod")
	_assert(ml._browse_install_map().has("vostokmods:foo"), "T35: paired, a Browse row keyed by slug finds the mod")

	var r: Dictionary = await ml.apply_modpack(entry, null, Callable())
	_assert(bool(r.get("ok", false)) and int(r.get("downloaded", -1)) == 0 and int(r.get("failed_downloads", -1)) == 0,
			"T35: the pack applies without trying to download anything (got %s)" % str(r))
	var after := ConfigFile.new()
	after.load(str(ml.UI_CONFIG_PATH))
	var en_sec := "profile.modpack__" + str(entry.get("sanitized_name", "")) + ".enabled"
	_assert(after.has_section_key(en_sec, "foo@2.0") and not after.has_section_key(en_sec, "vostokmods:foo"),
			"T35: the pack's slot is keyed by the installed mod")
	var live_foo: Dictionary = {}
	for e in (ml.get("_ui_mod_entries") as Array):
		if str((e as Dictionary).get("profile_key", "")) == "foo@2.0":
			live_foo = e
	_assert(bool(live_foo.get("enabled", false)), "T35: the pack's mod is enabled after the apply")
	ml.unload_modpack(null)
	aliases.clear()
	_pack_cleanup(ml)

# A binary resource starts "RSRC" and a zero word, and Godot's string
# decoders stop at the first NUL, so the scanner's binary rules used to see
# four characters. The fixture is a real binary scene saved by the engine,
# carrying a payload in a string property the way a built-in script carries
# its source; a clean scene must still scan clean.
func _t36_binary_scan_reads_past_the_first_nul(ml: Object) -> void:
	var path := "user://scan_payload.scn"
	var bad := _scene_bytes(path, "func _ready():\n\tOS.execute(\"cmd.exe\", [\"/c\", \"calc\"])\n\tvar e = Expression.new()\n")
	_assert(bad.slice(0, 4).get_string_from_ascii() == "RSRC" and bad.find(0) == 4,
			"T36: the fixture is a binary resource with a NUL right after its magic")
	ml._security_compile_rules()
	var findings: Array = []
	ml._security_scan_binary("scan_payload.scn", bad, findings)
	var rules := PackedStringArray()
	for f in findings:
		rules.append(str((f as Dictionary).get("rule", "")))
	_assert(rules.has("os_execute") and rules.has("expression_eval"),
			"T36: a payload in a binary scene is found (got %s)" % str(rules))
	_assert(int(ml.compute_risk_level(findings)) == int(ml.RISK_RED), "T36: and it is rated red")
	var clean_findings: Array = []
	ml._security_scan_binary("scan_clean.scn", _scene_bytes(path, "A note about how the cabin door opens."), clean_findings)
	_assert(clean_findings.is_empty(), "T36: a clean binary scene has no findings (got %s)" % str(clean_findings))
	# Every binary rule fires on a sample call inside a binary scene: one
	# sample per rule, all in one scene.
	var binary_ids := PackedStringArray()
	for rule in (ml._SECURITY_RULES as Array):
		if bool((rule as Dictionary).get("binary", false)):
			binary_ids.append(str(rule["id"]))
	var every := "OS.execute(\"x\", [])\nOS.create_process(\"x\", [])\nOS.create_instance([])\nOS.kill(1)\n" \
			+ "OS.crash(\"x\")\nOS.set_use_file_access_save_and_swap(false)\nExpression.new()\n" \
			+ "s.set_source_code(src)\nbytes_to_var_with_objects(b)\nMarshalls.base64_to_variant(s, true)\n"
	var all_findings: Array = []
	ml._security_scan_binary("scan_every.scn", _scene_bytes(path, every), all_findings)
	var found := PackedStringArray()
	for f in all_findings:
		found.append(str((f as Dictionary).get("rule", "")))
	for rule_id in binary_ids:
		_assert(found.has(rule_id), "T36: binary rule %s fires on its sample inside a binary scene (found %s)" % [rule_id, str(found)])
	_remove_user_file(path)

# Update replaces the installed archive, so it refuses what would go wrong
# after a full download: a .zip the game mounted at startup is locked until
# it exits, and a file whose mod.txt names another mod would delete this
# one. Both answer before any network request and say the cause is local.
func _t37_update_guards(ml: Object) -> void:
	var mounted_path := ProjectSettings.globalize_path("user://t37_mounted.zip")
	var mounted: Dictionary = ml.get("_filescope_mounted")
	mounted[mounted_path] = true
	var r: Dictionary = await ml.replace_mod_from_ref(mounted_path, ml.host_ref("vostokmods", "t37"))
	_assert(not bool(r["ok"]) and bool(r.get("local", false)) and str(r["error"]).contains("relaunch"),
			"T37: updating a mounted .zip says to disable and relaunch (got %s)" % str(r))
	mounted.erase(mounted_path)

	var old_zip := _write_zip("user://t37_old.zip", {"mod.txt": "[mod]\nname=\"A\"\nid=\"mod_a\"\nversion=\"1.0\"\n"})
	var other := ConfigFile.new()
	other.parse("[mod]\nname=\"B\"\nid=\"mod_b\"\nversion=\"2.3\"\n")
	_assert(str(ml._update_names_another_mod(old_zip, other, "modworkshop")).contains("different mod"),
			"T37: a download whose mod.txt names another id is refused")
	var same := ConfigFile.new()
	same.parse("[mod]\nname=\"A\"\nid=\"MOD_A\"\nversion=\"1.1\"\n")
	_assert(str(ml._update_names_another_mod(old_zip, same, "modworkshop")) == "",
			"T37: the same id in another case is the same mod")
	var no_id := ConfigFile.new()
	no_id.parse("[mod]\nname=\"A\"\nversion=\"1.1\"\n")
	_assert(str(ml._update_names_another_mod(old_zip, no_id, "modworkshop")) == "",
			"T37: with no id to compare the update goes ahead")
	_remove_user_file("user://t37_old.zip")

# A profile left while user://MCM does not exist still gets a snapshot slot,
# an empty one. Without it, coming back finds no snapshot and seeds the
# profile from whichever profile's MCM settings are live.
func _t38_leaving_a_profile_without_mcm_records_none(ml: Object) -> void:
	_pack_cleanup(ml)
	_assert(not DirAccess.dir_exists_absolute(ProjectSettings.globalize_path("user://MCM")), "T38: no live MCM folder")
	ml._snapshot_mcm_to("T38Light")
	_assert(bool(ml._has_mcm_snapshot("T38Light")), "T38: the profile has a snapshot slot")
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("user://MCM/heavy-mod"))
	var f := FileAccess.open("user://MCM/heavy-mod/config.ini", FileAccess.WRITE)
	f.store_string("[a]\nv=heavy\n")
	f.close()
	_assert(bool(ml._restore_mcm_from("T38Light")) and not FileAccess.file_exists("user://MCM/heavy-mod/config.ini"),
			"T38: coming back restores no MCM settings, not another profile's")
	_pack_cleanup(ml)

# The pairing before an apply asks the site only about installs that could
# be what an unmatched pack mod names: a pack names mods by slug, so a mod
# installed under its slug (a Browse download before the site wrote UUIDs)
# is never asked about. A mod the site marks unavailable has no source in
# the pack, and its key still finds an installed copy.
func _t39_pairing_asks_little_and_covers_unavailable_mods(ml: Object) -> void:
	_pack_cleanup(ml)
	var uuid := "019ff1f0-00ac-76a9-a23f-7151e4531131"
	var foo := _installed_entry("foo@2.0", "foo", "2.0")
	var foo_cfg := ConfigFile.new()
	foo_cfg.set_value("mod", "version", "2.0")
	foo_cfg.set_value("updates", "source", "vostokmods:" + uuid)
	foo["cfg"] = foo_cfg
	var bar := _installed_entry("bar@1.0", "bar", "1.0")
	var installed: Array[Dictionary] = [foo, bar]
	ml.set("_ui_mod_entries", installed)
	ml.set("_active_profile", "Default")
	var seed := ConfigFile.new()
	seed.set_value("settings", "active_profile", "Default")
	seed.set_value("mod_sources", "bar@1.0", ml._serialize_mod_source_rec({"provider": "vostokmods", "id": "bar", "version": "1.0"}))
	_assert(seed.save(str(ml.UI_CONFIG_PATH)) == OK, "T39: seeded mod_config.cfg")
	var aliases: Dictionary = ml.get("_host_ref_aliases")
	aliases.clear()
	(ml.get("_mods_meta_by_key") as Dictionary).clear()

	var entry := _pack_write(ml, {"metroprofile": 1, "name": "Round Trip",
			"enabled": {"vostokmods:bar": true, "vostokmods:qux": true},
			"sources": {"vostokmods:bar": {"provider": "vostokmods", "id": "bar"},
					"vostokmods:qux": {"provider": "vostokmods", "id": "qux"}}}, "1")
	var ask: Array = ml._modpack_unpaired_host_refs(entry)
	_assert(ask.size() == 1 and str(ml.host_ref_key(ask[0])) == "vostokmods:" + uuid,
			"T39: only the install known by UUID is asked about, not the one known by slug (got %s)" % str(ask))

	entry = _pack_write(ml, {"metroprofile": 1, "name": "Round Trip",
			"enabled": {"vostokmods:foo": true},
			"unavailable": {"vostokmods:foo": "scanning"}}, "1")
	_assert((ml._get_missing_mods_for_modpack(entry) as Array).size() == 1,
			"T39: unpaired, an unavailable pack mod reads as missing")
	ml._vmp_note_ids({"id": uuid, "slug": "foo"})
	_assert((ml._get_missing_mods_for_modpack(entry) as Array).is_empty(),
			"T39: paired, the pack key of an unavailable mod finds the installed copy")
	foo["enabled"] = false
	var r: Dictionary = await ml.apply_modpack(entry, null, Callable())
	var after := ConfigFile.new()
	after.load(str(ml.UI_CONFIG_PATH))
	var en_sec := "profile.modpack__" + str(entry.get("sanitized_name", "")) + ".enabled"
	_assert(bool(r.get("ok", false)) and after.has_section_key(en_sec, "foo@2.0") and bool(foo.get("enabled", false)),
			"T39: the apply keys the unavailable mod by its installed copy and enables it (got %s)" % str(r))
	ml.unload_modpack(null)
	aliases.clear()
	_pack_cleanup(ml)

# A site's version label can differ from the version in the file's own
# mod.txt: Vehicle Doors is 1.0.0 on Vostok Mods and says 0.9.0 inside. The
# pack pins the label, so the installed copy never matched, the apply left
# the mod as a missing row, and its Download fetched the same 142 MB file a
# second time. The pack's checksum is for the exact pinned file, so an
# installed archive with those bytes is that version.
func _t40_pinned_file_matches_by_checksum(ml: Object) -> void:
	_pack_cleanup(ml)
	var uuid := "01a108b6-2a9e-75bb-b9ac-43623230bebb"
	var mod_txt := "[mod]\nname=\"Vehicle Doors\"\nid=\"vehicle-doors\"\nversion=\"0.9.0\"\n\n[updates]\nsource=\"vostokmods:" + uuid + "\"\n"
	var vd_path := _write_zip("user://t40_VehicleDoors.vmz", {"mod.txt": mod_txt})
	var vd_sha := FileAccess.get_sha256(vd_path)
	var vd := _installed_entry("vehicle-doors@0.9.0", "vehicle-doors", "0.9.0")
	vd["full_path"] = vd_path
	vd["enabled"] = false
	var vd_cfg := ConfigFile.new()
	vd_cfg.parse(mod_txt)
	vd["cfg"] = vd_cfg
	var installed: Array[Dictionary] = [vd]
	ml.set("_ui_mod_entries", installed)
	ml.set("_active_profile", "Default")
	var seed := ConfigFile.new()
	seed.set_value("settings", "active_profile", "Default")
	_assert(seed.save(str(ml.UI_CONFIG_PATH)) == OK, "T40: seeded mod_config.cfg")
	var aliases: Dictionary = ml.get("_host_ref_aliases")
	aliases.clear()
	ml._vmp_note_ids({"id": uuid, "slug": "vehicle-doors"})
	var pin := {"provider": "vostokmods", "id": "vehicle-doors", "version": "1.0.0"}
	var pack := {"metroprofile": 1, "name": "Round Trip", "enabled": {"vostokmods:vehicle-doors": true},
			"sources": {"vostokmods:vehicle-doors": pin}, "checksums": {"vostokmods:vehicle-doors": "0".repeat(64)}}

	var entry := _pack_write(ml, pack, "1")
	_assert((ml._get_missing_mods_for_modpack(entry) as Array).size() == 1,
			"T40: other bytes under the pinned label still read as missing")
	pack["checksums"]["vostokmods:vehicle-doors"] = vd_sha
	entry = _pack_write(ml, pack, "1")
	_assert((ml._get_missing_mods_for_modpack(entry) as Array).is_empty(),
			"T40: the pinned file is installed although its mod.txt says another version")

	var r: Dictionary = await ml.apply_modpack(entry, null, Callable())
	var after := ConfigFile.new()
	after.load(str(ml.UI_CONFIG_PATH))
	var en_sec := "profile.modpack__" + str(entry.get("sanitized_name", "")) + ".enabled"
	_assert(bool(r.get("ok", false)) and int(r.get("downloaded", -1)) == 0 and int(r.get("failed_downloads", -1)) == 0,
			"T40: the pack applies without downloading anything (got %s)" % str(r))
	_assert(after.has_section_key(en_sec, "vehicle-doors@0.9.0") and not after.has_section_key(en_sec, "vostokmods:vehicle-doors")
			and bool(vd.get("enabled", false)),
			"T40: the slot is keyed by the installed mod and the mod is enabled")

	# A slot left keyed by the pack (what 3.4.1 wrote) heals at boot.
	var stale := ConfigFile.new()
	stale.load(str(ml.UI_CONFIG_PATH))
	stale.erase_section_key(en_sec, "vehicle-doors@0.9.0")
	stale.set_value(en_sec, "vostokmods:vehicle-doors", true)
	stale.save(str(ml.UI_CONFIG_PATH))
	_assert(int(ml._modpack_reconcile_active()) == 1, "T40: the active pack's stale key is reconciled")
	ml.unload_modpack(null)

	# A mod.txt that claims a newer version than the label is the same file,
	# not a newer copy that would block the pin.
	ml.set("_ui_mod_entries", installed)
	vd["version"] = "1.1.0"
	_assert(str(ml._modpack_pin_conflict(entry)).is_empty(),
			"T40: the pinned file is not a newer copy whatever its mod.txt says")
	pack["checksums"]["vostokmods:vehicle-doors"] = "0".repeat(64)
	_assert(not str(ml._modpack_pin_conflict(_pack_write(ml, pack, "1"))).is_empty(),
			"T40: another file with a newer version still blocks the pin")
	aliases.clear()
	_remove_user_file("user://t40_VehicleDoors.vmz")
	_pack_cleanup(ml)

# The pack's details dialog and the apply ask one question of each pack mod
# (_modpack_key_installed). The dialog skipped the id@version match in
# another case and the key of a hosted mod the site could not serve, so it
# showed mods missing that the apply then found installed. Then two costs
# the apply avoids: a pinned file is hashed only when its version would
# block the pin, and an installed mod the site has answered for is not
# asked about again this session, while an ask that never reached the site is.
func _t41_one_installed_test_and_cheap_pairing(ml: Object) -> void:
	_pack_cleanup(ml)
	var foo := _installed_entry("Foo@1.0", "Foo", "1.0")
	var bar := _installed_entry("bar@2.0", "bar", "2.0")
	var bar_cfg := ConfigFile.new()
	bar_cfg.set_value("mod", "version", "2.0")
	bar_cfg.set_value("updates", "source", "vostokmods:bar")
	bar["cfg"] = bar_cfg
	var installed: Array[Dictionary] = [foo, bar]
	ml.set("_ui_mod_entries", installed)
	ml.set("_active_profile", "Default")
	var seed := ConfigFile.new()
	seed.set_value("settings", "active_profile", "Default")
	_assert(seed.save(str(ml.UI_CONFIG_PATH)) == OK, "T41: seeded mod_config.cfg")
	var aliases: Dictionary = ml.get("_host_ref_aliases")
	aliases.clear()

	var sources := {"vostokmods:qux": {"provider": "vostokmods", "id": "qux"}}
	var index: Dictionary = ml._modpack_installed_index()
	_assert(bool(ml._modpack_key_installed("foo@1.0", sources, {}, index)),
			"T41: the same id@version in another case is installed")
	_assert(bool(ml._modpack_key_installed("vostokmods:bar", sources, {}, index)),
			"T41: a hosted key with no source finds the mod it names")
	_assert(not bool(ml._modpack_key_installed("vostokmods:qux", sources, {}, index)),
			"T41: a mod that is not installed reads as missing")
	var entry := _pack_write(ml, {"metroprofile": 1, "name": "Round Trip",
			"enabled": {"foo@1.0": true, "vostokmods:bar": true, "vostokmods:qux": true}, "sources": sources}, "1")
	var missing: Array = ml._get_missing_mods_for_modpack(entry)
	_assert(missing.size() == 1 and str((missing[0] as Dictionary)["profile_key"]) == "vostokmods:qux",
			"T41: the apply finds the same one mod missing (got %s)" % str(missing))

	# Only an installed copy newer than the pin is hashed.
	var sha_cache: Dictionary = ml.get("_modpack_sha256_cache")
	sha_cache.clear()
	var bar_path := _write_zip("user://t41_bar.vmz", {"mod.txt": "[mod]\nid=\"bar\"\n"})
	bar["full_path"] = bar_path
	var pin_pack := {"metroprofile": 1, "name": "Round Trip", "enabled": {"vostokmods:bar": true},
			"sources": {"vostokmods:bar": {"provider": "vostokmods", "id": "bar", "version": "2.0"}},
			"checksums": {"vostokmods:bar": "0".repeat(64)}}
	_assert(str(ml._modpack_pin_conflict(_pack_write(ml, pin_pack, "1"))).is_empty() and sha_cache.is_empty(),
			"T41: an installed copy at the pinned version is not hashed")
	bar["version"] = "2.1"
	_assert(not str(ml._modpack_pin_conflict(_pack_write(ml, pin_pack, "1"))).is_empty() and sha_cache.has(bar_path),
			"T41: a newer installed copy is hashed, and blocks the pin when it is other bytes")
	bar["version"] = "2.0"

	# A UUID-only install that the pack's slug may name.
	var uuid := "01a108b6-2a9e-75bb-b9ac-43623230be41"
	var baz := _installed_entry("baz@1.0", "baz", "1.0")
	var baz_cfg := ConfigFile.new()
	baz_cfg.set_value("updates", "source", "vostokmods:" + uuid)
	baz["cfg"] = baz_cfg
	var with_baz: Array[Dictionary] = [foo, bar, baz]
	ml.set("_ui_mod_entries", with_baz)
	var asked: Dictionary = ml.get("_modpack_host_ids_asked")
	asked.clear()
	entry = _pack_write(ml, {"metroprofile": 1, "name": "Round Trip", "enabled": {"vostokmods:baz-slug": true},
			"sources": {"vostokmods:baz-slug": {"provider": "vostokmods", "id": "baz-slug"}}}, "1")
	_assert((ml._modpack_unpaired_host_refs(entry) as Array).size() == 1, "T41: the UUID-only install is asked about")
	# Out of the tree every request fails as offline.
	await ml._modpack_learn_host_ids(entry, false)
	_assert(asked.is_empty() and (ml._modpack_unpaired_host_refs(entry) as Array).size() == 1,
			"T41: an ask that never reached the site is asked again")
	# In the tree, a cached detail answers without the network. _has_loaded
	# keeps _ready from booting the loader.
	ml.set("_has_loaded", true)
	root.add_child(ml)
	ml._hnet_cache_put(str(ml.VM_API_BASE) + "/mods/" + uuid.uri_encode(), {"id": uuid, "name": "Baz"}, 60000)
	await ml._modpack_learn_host_ids(entry, false)
	root.remove_child(ml)
	_assert(asked.has("vostokmods:" + uuid) and (ml._modpack_unpaired_host_refs(entry) as Array).is_empty(),
			"T41: an install the site answered for is not asked about again (asked %s)" % str(asked))
	asked.clear()
	(ml.get("_host_cache") as Dictionary).clear()
	aliases.clear()
	_remove_user_file("user://t41_bar.vmz")
	_pack_cleanup(ml)

func _scene_bytes(path: String, payload: String) -> PackedByteArray:
	var node := Node.new()
	node.name = "Root"
	node.set_meta("payload", payload)
	var scene := PackedScene.new()
	scene.pack(node)
	node.free()
	if ResourceSaver.save(scene, path) != OK:
		_fail("harness could not save " + path)
	return FileAccess.get_file_as_bytes(path)

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
		var tag := still.slice(pos, pos + 4).get_string_from_ascii()
		if tag == "ALPH" or tag == "VP8 " or tag == "VP8L":
			out.append_array(still.slice(pos, next))
		pos = next
	return out

# An animated WebP: VP8X with the animation and alpha flags, ANIM, then one
# ANMF per frame ({chunks, offset, size}).
func _animated_webp(canvas: Vector2i, frames: Array) -> PackedByteArray:
	var body := "WEBP".to_ascii_buffer()
	body.append_array(_riff_chunk("VP8X", PackedByteArray([0x12, 0, 0, 0]) + _u24(canvas.x - 1) + _u24(canvas.y - 1)))
	body.append_array(_riff_chunk("ANIM", PackedByteArray([0, 0, 0, 0, 0, 0])))
	for f in frames:
		var off: Vector2i = f["offset"]
		var sz: Vector2i = f["size"]
		var payload := _u24(off.x >> 1) + _u24(off.y >> 1) + _u24(sz.x - 1) + _u24(sz.y - 1) + _u24(100) + PackedByteArray([0])
		payload.append_array(f["chunks"])
		body.append_array(_riff_chunk("ANMF", payload))
	var out := "RIFF".to_ascii_buffer()
	out.append_array(_u32(body.size()))
	out.append_array(body)
	return out

func _riff_chunk(tag: String, payload: PackedByteArray) -> PackedByteArray:
	var out := tag.to_ascii_buffer()
	out.append_array(_u32(payload.size()))
	out.append_array(payload)
	if payload.size() % 2 == 1:
		out.append(0)
	return out

func _u24(v: int) -> PackedByteArray:
	return PackedByteArray([v & 0xFF, (v >> 8) & 0xFF, (v >> 16) & 0xFF])

func _u32(v: int) -> PackedByteArray:
	var out := PackedByteArray()
	out.resize(4)
	out.encode_u32(0, v)
	return out

# Row warnings are for the player: the mod will not work. Author notes are
# for the mod's author: it works, but its mod.txt could be better. Each
# message must land in its own list and never in the other.
func _t15_warnings_and_author_notes(ml: Object) -> void:
	var nested := _entry_from(ml, null, "nested:Sub/mod.txt", "", {})
	_assert(_has_line(nested["warnings"], "subfolder") and (nested["notes"] as Array).is_empty(),
			"T15: a nested mod.txt is a warning, not a note (got %s / %s)" % [str(nested["warnings"]), str(nested["notes"])])
	var broken := _entry_from(ml, null, "parse_error", "line 3 [mod]: nam", {})
	_assert(_has_line(broken["warnings"], "parse error at line 3") and (broken["notes"] as Array).is_empty(),
			"T15: a parse error is a warning naming the line (got %s)" % str(broken["warnings"]))
	var files := {"res://mod.txt": true, "res://X/main.gd": true}
	var no_id := _entry_from(ml, _cfg_from_text('[mod]\nname="X"\n\n[autoload]\nMain="res://X/Main.gd"\n'), "ok", "", files)
	_assert(_has_line(no_id["warnings"], "did you mean res://X/main.gd"),
			"T15: an autoload path that points nowhere is a warning with the near miss (got %s)" % str(no_id["warnings"]))
	_assert(_has_line(no_id["notes"], "No id= in mod.txt") and not _has_line(no_id["warnings"], "No id="),
			"T15: a missing id= is an author note, not a warning (got %s / %s)" % [str(no_id["warnings"]), str(no_id["notes"])])
	var bad_source := _entry_from(ml, _cfg_from_text('[mod]\nid="bs"\nversion="1.0"\n\n[updates]\nsource="12345"\n'), "ok", "", {"res://mod.txt": true})
	_assert(_has_line(bad_source["notes"], "unrecognized [updates] source") and (bad_source["warnings"] as Array).is_empty(),
			"T15: an unrecognized source= is an author note only (got %s / %s)" % [str(bad_source["warnings"]), str(bad_source["notes"])])
	var baked := _entry_from(ml, _cfg_from_text('[mod]\nid="bk"\nversion=1.10\n\n[updates]\nsource="vostokmods:bk"\n'), "ok", "",
			{"res://mod.txt": true, "res://BK/A.gd": true, "res://BK/A.gd.remap": true})
	_assert(_has_line(baked["notes"], "unquoted") and _has_line(baked["notes"], "pre-compiled script") and (baked["warnings"] as Array).is_empty(),
			"T15: an unquoted version and a stale bake are author notes only (got %s / %s)" % [str(baked["warnings"]), str(baked["notes"])])
	var rescued := _entry_from(ml, _cfg_from_text('[mod]\nid="rs"\nversion="1.0"\n\n[updates]\nsource="12345"\nmodworkshop=777\n'), "ok", "", {"res://mod.txt": true})
	_assert(_has_line(rescued["notes"], "unrecognized [updates] source") and _has_line(rescued["notes"], "modworkshop=")
			and not _has_line(rescued["notes"], "will not update"),
			"T15: a bad source= beside a valid modworkshop= says which line is used, not that the mod cannot update (got %s)" % str(rescued["notes"]))
	var dev_folder := _entry_from(ml, null, "parse_error", "line 3 [mod]: nam", {}, "folder")
	_assert(_has_line(dev_folder["warnings"], "parse error at line 3"),
			"T15: a developer folder with a broken mod.txt gets the parse warning too (got %s)" % str(dev_folder["warnings"]))
	var bare_folder := _entry_from(ml, null, "none", "", {}, "folder")
	_assert((bare_folder["warnings"] as Array).is_empty(), "T15: a developer folder with no mod.txt is not told to re-download")
	var pck := _entry_from(ml, null, "pck", "", {}, "pck")
	_assert((pck["warnings"] as Array).is_empty() and (pck["notes"] as Array).is_empty(),
			"T15: a .pck gets neither list")

func _entry_from(ml: Object, cfg: ConfigFile, status: String, error: String, files: Dictionary, ext: String = "vmz") -> Dictionary:
	var read := {"cfg": cfg, "status": status, "error": error, "files": files}
	var entry: Dictionary = ml._entry_from_config(read, "Mod." + ext, "/mods/Mod." + ext, ext)
	return {
		"warnings": ml._build_entry_warnings(entry, files),
		"notes": ml._build_entry_author_notes(entry, files),
	}

func _has_line(lines: Variant, needle: String) -> bool:
	for l in (lines as Array):
		if str(l).contains(needle):
			return true
	return false

# Every path under user:// except Godot's own logs/, as user:// paths.
func _user_listing() -> Dictionary:
	var out: Dictionary = {}
	_list_dir(ProjectSettings.globalize_path("user://"), "user://", out)
	return out

func _list_dir(abs_dir: String, prefix: String, out: Dictionary) -> void:
	var d := DirAccess.open(abs_dir)
	if d == null:
		return
	d.list_dir_begin()
	while true:
		var e := d.get_next()
		if e == "":
			break
		if e == "." or e == ".." or (prefix == "user://" and e == "logs"):
			continue
		var child := prefix.path_join(e) if prefix != "user://" else "user://" + e
		if d.current_is_dir():
			out[child + "/"] = true
			_list_dir(abs_dir.path_join(e), child, out)
		else:
			out[child] = true
	d.list_dir_end()

# Write a zip of {entry_name: text} into user:// and return its absolute path.
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

func _assert_same_keys(ml: Object, s: Variant, label: String) -> void:
	var want: Array = (ml.host_empty_summary() as Dictionary).keys()
	want.sort()
	var got: Array = (s as Dictionary).keys()
	got.sort()
	_assert(got == want,
			"%s: summary key set must match host_empty_summary (want %s, got %s)"
					% [label, str(want), str(got)])

# --- Reporting ---------------------------------------------------------------

func _oneline(s: String) -> String:
	return s.replace("\n", "\\n").replace("\t", "\\t")

func _assert(cond: bool, msg: String) -> void:
	_assertions += 1
	if not cond:
		_failures.append(msg)

func _fail(msg: String) -> void:
	_failures.append(msg)

func _finish() -> void:
	_done = true
	if _failures.is_empty():
		print("[host] PASS: %d assertion(s) across T1..T41" % _assertions)
		quit(0)
		return
	for m in _failures:
		printerr("[host] FAIL: " + m)
	printerr("[host] FAILED: %d of %d assertion(s)" % [_failures.size(), _assertions])
	quit(1)
