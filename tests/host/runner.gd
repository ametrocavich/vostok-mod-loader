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

# A VostokMods ModCard row, shaped from the site's own listing route rather
# than inferred from one observed response. followersCount is present ON
# PURPOSE: the adapter deliberately does NOT map it onto likes, and T2 pins
# that. `group` on a category is the discriminator between a real category and
# a tag, which the row mixes together.
const VM_ROW_JSON := """
{"id": "m_4", "slug": "example", "name": "Example", "summary": "An example mod.",
 "author": "Ovrrde", "authorId": "ovrrde",
 "categories": [{"slug": "tag-1", "name": "Tag One", "group": "tags"},
                {"slug": "category-1", "name": "Category 1", "group": "categories"}],
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
 "author": "Ovrrde", "categories": [], "thumbnailUrl": null,
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
	_assert(row is Dictionary, "T2: VostokMods fixture JSON parses")
	var s: Variant = ml._vmp_summary(row)
	_assert_same_keys(ml, s, "T2")
	var key := str(ml.host_ref_key(s["ref"]))
	# IDENTITY IS THE SLUG, not the numeric id. Every VostokMods route --
	# detail, download, public page -- is slug-keyed and the numeric id
	# addresses nothing, so a ref built from the id would 404 everywhere.
	_assert(key == "vostokmods:example",
			"T2: ref identity is the SLUG (got %s)" % key)
	_assert(str(s["name"]) == "Example", "T2: name (got %s)" % str(s["name"]))
	_assert(str(s["author_name"]) == "Ovrrde",
			"T2: author is a bare display string (got %s)" % str(s["author_name"]))
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
			"T2n: empty categories -> '' (got %s)" % str(n["category_name"]))
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
			"T3: VostokMods row with null id -> invalid ref, empty key")
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
# modworkshop= line, so a mod downloaded from VostokMods must keep the identity
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

# T8: the pure half of the VostokMods adapter. The seam has no live consumer
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
	var nofile: Variant = ml._vmp_file_result(JSON.parse_string('{"id": "v_12", "downloadUrl": null}'))
	_assert(not nofile["ok"] and str(nofile["code"]) == ml.HOST_ERR_NO_FILE,
			"T8: a record with no url resolves to NO_FILE, never a bad ok")

	# group is the discriminator between a real category and a tag.
	var cats: Variant = JSON.parse_string("""
	[{"slug": "t", "name": "Tag", "group": "tags"},
	 {"slug": "c", "name": "Cat", "group": "categories"}]
	""")
	_assert(str(ml._vmp_primary_category(cats)) == "Cat",
			"T8: group=categories wins over an earlier tag")
	_assert(str(ml._vmp_primary_category(JSON.parse_string("[]"))) == "",
			"T8: no categories -> ''")

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
	# VostokMods ids are slugs). Probe each with an id IT would accept, or the
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
const VM_MANIFEST_JSON := """\n{"format": 2, "slug": "hardcore-survival", "name": "Hardcore Survival",\n "summary": "Short description", "author": "Ovrrde",\n "url": "https://vostokmods.net/modpack/hardcore-survival",\n "coverUrl": null, "updatedAt": "2026-09-11T16:07:32.051Z",\n "hash": "0123abcd",\n "mcmConfig": {\n   "doinkoink-mcm/config.ini": "[General]\n\nvolume={\\\"value\\\": 3}\n",\n   "export.ini": "[some-mod]\n\nImportModData={\\\"friendlyName\\\": \\\"Some Mod\\\"}\nspeed={\\\"value\\\": 7, \\\"import_data\\\": {\\\"section\\\": \\\"Movement\\\"}}\n",\n   "../evil.ini": "[x]\n\nImportModData={}\n"\n },\n "mods": [\n   {"loadOrder": 1, "slug": "mod-configuration-menu", "name": "MCM", "author": "metro",\n    "available": true, "reason": null, "version": "2.9.2", "fileName": "mcm.vmz",\n    "fileSize": 4404019, "sha256": "AB12ab12ab12ab12ab12ab12ab12ab12ab12ab12ab12ab12ab12ab12ab12ab12",\n    "downloadUrl": "https://vostokmods.net/api/mods/mod-configuration-menu/versions/2.9.2/download",\n    "pageUrl": "https://vostokmods.net/mod/mod-configuration-menu"},\n   {"loadOrder": 2, "slug": "still-scanning", "name": "Scanning", "author": "x",\n    "available": false, "reason": "scanning", "version": null, "fileName": null,\n    "fileSize": null, "sha256": null, "downloadUrl": null, "pageUrl": null},\n   {"loadOrder": 3, "slug": "gone", "name": "Gone", "author": "x",\n    "available": false, "reason": "removed", "version": null, "fileName": null,\n    "fileSize": null, "sha256": null, "downloadUrl": null, "pageUrl": null}\n ]}\n"""

const VM_PACK_ROW_JSON := """
{"id": "01a09139", "slug": "test", "name": "Test", "summary": "", "author": "Admin Prime",
 "authorId": "admin", "authorAvatarUrl": null, "createdAt": "2026-09-11T16:07:32.051Z",
 "updatedAt": "2026-09-11T16:30:14.194Z", "modCount": 14, "coverUrl": null,
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
	_assert(str(s["cover_url"]) == "", "T10: null coverUrl reads as empty, not '<null>'")

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
	_assert(not src.has("modworkshop_id"), "T10: no ModWorkshop mirror on a VostokMods record")
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
# VostokMods and its mod.txt says nothing, so only [mod_sources] knows its host.
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
	ml.unload_modpack(null)
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
	_assert(bool(ml._modpack_ref_downloadable(ml.host_ref("vostokmods", "x"))), "T14: a VostokMods ref is downloadable")
	_assert(bool(ml._modpack_ref_downloadable(ml.host_ref("modworkshop", "1"))), "T14: a ModWorkshop ref is downloadable")
	_assert(not bool(ml._modpack_ref_downloadable({})), "T14: an empty ref is not downloadable")
	_assert(not bool(ml._modpack_ref_downloadable({"provider": "steam", "id": "1"})), "T14: an unknown host is not downloadable")

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
		print("[host] PASS: %d assertion(s) across T1..T26" % _assertions)
		quit(0)
		return
	for m in _failures:
		printerr("[host] FAIL: " + m)
	printerr("[host] FAILED: %d of %d assertion(s)" % [_failures.size(), _assertions])
	quit(1)
