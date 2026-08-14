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

# The VostokMods /api/mods row quoted verbatim in host_vostokmods.gd's header
# (the single confirmed response), with the elided thumbnail filename filled
# in. followersCount is present ON PURPOSE: the adapter deliberately does NOT
# map it onto likes, and T2 pins that.
const VM_ROW_JSON := """
{"id": 4, "slug": "example", "name": "Example", "author": "Ovrrde",
 "categories": [{"slug": "category-1", "name": "Category 1"}],
 "thumbnailUrl": "https://files.vostokmods.net/mods/4/screenshots/example.png",
 "downloadsCount": 1, "followersCount": 1,
 "updatedAt": "2026-08-07T06:05:11.420Z"}
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
	_assert(key == "vostokmods:4",
			"T2: JSON float id normalizes to ref vostokmods:4 (got %s)" % key)
	_assert(str(s["name"]) == "Example", "T2: name (got %s)" % str(s["name"]))
	_assert(str(s["author_name"]) == "Ovrrde",
			"T2: author is a bare display string (got %s)" % str(s["author_name"]))
	_assert(s["downloads"] is int and int(s["downloads"]) == 1,
			"T2: downloads is int 1 (got %s)" % str(s["downloads"]))
	# The deliberate NON-mapping: a follow is a subscription, not an
	# endorsement, so followersCount must NOT surface as likes.
	_assert(s["likes"] is int and int(s["likes"]) == -1,
			"T2: followersCount must NOT map onto likes (got %s)" % str(s["likes"]))
	_assert(s["views"] is int and int(s["views"]) == -1,
			"T2: views stays -1 'not reported' (got %s)" % str(s["views"]))
	_assert(str(s["version"]) == "",
			"T2: version sentinel '' -- the listing has no version field")
	_assert(str(s["published_at"]) == "",
			"T2: published_at sentinel '' -- not in the listing")
	_assert(str(s["updated_at"]) == "2026-08-07T06:05:11.420Z",
			"T2: updated_at maps from updatedAt (got %s)" % str(s["updated_at"]))
	_assert(str(s["category_name"]) == "Category 1",
			"T2: first categories[] entry shown (got %s)" % str(s["category_name"]))
	var thumb: Variant = s["thumbnail"]
	_assert(str(thumb["url"]) == "https://files.vostokmods.net/mods/4/screenshots/example.png",
			"T2: thumbnailUrl passes through absolute (got %s)" % str(thumb["url"]))
	_assert(str(thumb["thumb_url"]) == "",
			"T2: no separate thumb size -> thumb_url ''")
	_assert(str(thumb["cache_key"]) == "",
			"T2: no immutability promise -> cache_key '' (never disk-cached)")
	_assert(str(s["short_description"]) == "",
			"T2: short_description sentinel ''")

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
	var r2: Variant = ml.host_ref_from_key("vostokmods:4")
	_assert(str(r2.get("provider", "")) == "vostokmods" and str(r2.get("id", "")) == "4",
			"T5: vostokmods:4 parses (got %s)" % str(r2))
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
				'[mod]\nversion="1.2"\n\n[updates]\nsource="vostokmods:4"\n',
				"vostokmods", "4", "1.2"],
		["dual-written: source= wins",
				'[updates]\nsource="vostokmods:4"\nmodworkshop=777\n',
				"vostokmods", "4", ""],
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
		print("[host] PASS: %d assertion(s) across T1..T7" % _assertions)
		quit(0)
		return
	for m in _failures:
		printerr("[host] FAIL: " + m)
	printerr("[host] FAILED: %d of %d assertion(s)" % [_failures.size(), _assertions])
	quit(1)
