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

func _init() -> void:
	print("[host] harness start")

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
	_t8_vm_pure_surface(ml)
	_t9_caps_match_wiring(ml)

	_finish()

# --- Fixtures ----------------------------------------------------------------

# A ModWorkshop listing row shaped exactly like a GET /games/864/mods `data`
# row: the field names are the ones host_mws.gd's normalizers read and
# mws_api.gd's endpoint notes document (id, name, user.name, category.name,
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
 "updatedAt": "2026-08-07T06:05:11.420Z", "latestGameVersion": null}
"""

# The same row with the nullable fields actually null. thumbnailUrl is null
# whenever a mod has no screenshot, which is the common case for a new upload.
const VM_ROW_NULLS_JSON := """
{"id": "m_5", "slug": "nulls", "name": "Nulls", "summary": null,
 "author": "Ovrrde", "categories": [], "thumbnailUrl": null,
 "downloadsCount": 0, "followersCount": 0, "viewsCount": 0,
 "createdAt": null, "updatedAt": null, "latestGameVersion": null}
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
	var r3: Variant = ml.host_ref_from_key("nexus:collection/riverwood:v2")
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
	var allowed := ["downloads", "followers", "views", "newest", "updated"]
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
	# refuse an id that cannot be one of its own (Nexus ids are integers,
	# VostokMods ids are slugs). Probe each with an id IT would accept, or the
	# check measures the fixture rather than the wiring.
	var sample := {
		ml.HOST_MODWORKSHOP: "12345",
		ml.HOST_VOSTOKMODS: "example-slug",
		ml.HOST_NEXUS: "51",
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
	if _failures.is_empty():
		print("[host] PASS: %d assertion(s) across T1..T9" % _assertions)
		quit(0)
		return
	for m in _failures:
		printerr("[host] FAIL: " + m)
	printerr("[host] FAILED: %d of %d assertion(s)" % [_failures.size(), _assertions])
	quit(1)
