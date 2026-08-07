## ----- host_types.gd -----
## Provider-neutral vocabulary for talking to a mod host.
##
## One rule governs every record here: every field is always present with its
## declared type. Missing data is a sentinel, never an absent key. Consumers
## write rec["name"], never rec.get("name", "") and never `is Dictionary`.
## That rule is the whole point -- it is what lets the UI stop shape-checking
## remote JSON at every read site.
##
## Sentinels:
##   String    -> ""
##   counters  -> -1, meaning "this host does not report this metric".
##                Distinct from 0, which is a real count of zero, so a host
##                that has no concept of likes renders no chip rather than
##                "0 likes".
##   Array/Dictionary -> empty
##
## The "provider:id" grammar in host_ref_key is the same grammar mod.txt's
## [updates] source= key uses. One parser serves the wire format and the disk
## format so the two cannot drift apart.

const HOST_MODWORKSHOP := "modworkshop"
const HOST_VOSTOKMODS := "vostokmods"

## Every provider the loader will parse from disk or dispatch to. An id whose
## provider is not on this list is rejected at parse time rather than guessed
## at, so a typo fails loudly instead of resolving to the wrong host.
const HOST_PROVIDERS_KNOWN: Array[String] = ["modworkshop", "vostokmods"]

# Failure codes. Each one exists because some caller branches on it
# differently; a code nobody distinguishes belongs merged into another.
const HOST_ERR_OFFLINE := "offline"                       # no HTTP response at all
const HOST_ERR_RATE_LIMITED := "rate_limited"             # budget spent, retry_after_s is set
const HOST_ERR_AUTH := "auth"                             # credentials needed or rejected; never retried
const HOST_ERR_NOT_FOUND := "not_found"                   # no such mod
const HOST_ERR_NO_FILE := "no_file"                       # mod exists, has no downloadable artifact
const HOST_ERR_VERSION_NOT_FOUND := "version_not_found"   # pinned version is gone
const HOST_ERR_SERVER := "server"                         # 5xx, retriable
const HOST_ERR_CLIENT := "client"                         # 4xx we have no better name for
const HOST_ERR_TOO_LARGE := "too_large"                   # body cap tripped
const HOST_ERR_BAD_RESPONSE := "bad_response"             # unparseable, or a captive portal's HTML
const HOST_ERR_UNSUPPORTED := "unsupported"               # provider declares this capability off
const HOST_ERR_UNWIRED := "unwired"                       # capability on but no dispatch arm: our bug

# NO_FILE is deliberately not folded into NOT_FOUND. mod_discovery.gd
# distinguishes "that mod id does not exist" from "that mod has nothing to
# download" in its user-facing copy today, and merging them would be a
# visible regression.


# ----- result envelope -----

func host_ok(data: Variant) -> Dictionary:
	return {
		"ok": true,
		"data": data,
		"code": "",
		"http": 0,
		"message": "",
		"retry_after_s": 0,
	}


func host_err(code: String, http: int, message: String, retry_after_s: int = 0) -> Dictionary:
	return {
		"ok": false,
		"data": null,
		"code": code,
		"http": http,
		"message": message,
		"retry_after_s": retry_after_s,
	}


# ----- mod references -----

func host_ref(provider: String, id: String) -> Dictionary:
	return {"provider": provider, "id": id}


func host_ref_valid(ref: Dictionary) -> bool:
	return str(ref.get("provider", "")) != "" and str(ref.get("id", "")) != ""


## Stable string key for a ref: "modworkshop:12345". Empty when either half is
## missing, which is the single "no source" test that replaces the old
## `mws_id <= 0` checks.
func host_ref_key(ref: Dictionary) -> String:
	if not host_ref_valid(ref):
		return ""
	return str(ref["provider"]) + ":" + str(ref["id"])


## Inverse of host_ref_key, and the parser for mod.txt's `source=` value.
## Splits on the FIRST colon only: ids are opaque and may themselves contain
## colons or slashes. Returns {} for anything that is not exactly
## <known-provider>:<non-empty-id>. A bare value with no colon is rejected
## rather than assumed to be a ModWorkshop id -- silently guessing the host
## is how a mod ends up downloading a stranger's upload.
func host_ref_from_key(key: String) -> Dictionary:
	var sep := key.find(":")
	if sep <= 0:
		return {}
	var provider := key.substr(0, sep)
	if not HOST_PROVIDERS_KNOWN.has(provider):
		return {}
	var id := key.substr(sep + 1).strip_edges()
	if id.is_empty():
		return {}
	return host_ref(provider, id)


## Coerce whatever a host called an id into the String the seam uses.
##
## Godot parses every JSON number as a float, so a mod id arrives as 12345.0
## and a plain str() yields "12345.0" -- at once a broken URL segment and a
## dictionary key that never matches the one read back from mod.txt. Every id
## crossing the seam goes through here.
func _host_id_str(v: Variant) -> String:
	if v is float:
		return str(int(v))
	if v is int:
		return str(v)
	return str(v).strip_edges()


# ----- records -----

## Read a metric off a host payload. JSON numbers arrive as floats, and an
## absent metric must read as -1 ("this host does not report it") rather than
## 0 ("nobody has downloaded it").
func _host_count(v: Variant) -> int:
	if v is int:
		return v
	if v is float:
		return int(v)
	return -1


## An image the UI may display. thumb_url is "" when the host serves only one
## size. cache_key is an opaque, immutable-per-image token used as the disk
## cache filename; "" means the host makes no immutability promise, so the
## image is fetched fresh and never written to disk.
func host_image(url: String, thumb_url: String, cache_key: String) -> Dictionary:
	return {"url": url, "thumb_url": thumb_url, "cache_key": cache_key}


## A listing row. Adapters start from this and overwrite what they can supply,
## so a new field lands in one place and every adapter inherits its sentinel.
func host_empty_summary() -> Dictionary:
	return {
		"ref": host_ref("", ""),
		"name": "",
		"author_name": "",
		"version": "",
		"downloads": -1,
		"likes": -1,
		"views": -1,
		"category_name": "",
		"updated_at": "",
		"published_at": "",
		"thumbnail": host_image("", "", ""),
		"short_description": "",
		"default_file_id": "",
	}


## A summary plus the two fields only the detail modal needs. `description` is
## always BBCode: adapters own the conversion from whatever their host speaks.
## There is deliberately no description_format enum -- a closed enum has no
## `html` member and the first host that ships HTML would force it open.
func host_empty_detail() -> Dictionary:
	var d := host_empty_summary()
	d["banner"] = host_image("", "", "")
	d["description"] = ""
	return d


## One downloadable artifact. download_url is required non-empty: an adapter
## that cannot produce one returns HOST_ERR_NO_FILE rather than a record with
## an empty url, so no caller has to test for that case.
##
## filename_hint carries whatever the host knows about the eventual filename
## (a Content-Disposition value, a ?filename= parameter, an asset name). The
## install tail reads one field instead of re-parsing URLs per host.
##
## headers is per-file rather than per-provider so a signed-CDN host can
## attach a token to one download without every provider gaining a global
## header hook.
func host_empty_file() -> Dictionary:
	return {
		"id": "",
		"version": "",
		"download_url": "",
		"size": -1,
		"created_at": "",
		"filename_hint": "",
		"headers": PackedStringArray(),
	}


## parent_id "" means top-level. Hosts with a flat category list leave it "" on
## every entry, which renders as a single level with no special casing.
func host_category(id: String, name: String, parent_id: String) -> Dictionary:
	return {"id": id, "name": name, "parent_id": parent_id}


## One page of listing rows. Paging is expressed only as has_more +
## next_cursor; a page-numbered host stringifies its number into the cursor.
## total is -1 when the host does not report one, which renders "N mods"
## instead of "N of M mods".
func host_page(rows: Array, has_more: bool, next_cursor: String, total: int) -> Dictionary:
	return {
		"rows": rows,
		"has_more": has_more,
		"next_cursor": next_cursor,
		"total": total,
	}


## What a provider can do. Static, no network, safe to call while building
## widgets -- the UI hides controls for capabilities that are off rather than
## letting the user press a button that can only fail.
func host_empty_caps() -> Dictionary:
	return {
		"browse": false,
		"search": false,
		"categories": false,
		"file_history": false,
		"version_pin": false,
		"page_url": false,
		"batch_versions": false,
		"total_count": false,
		"sort_ignored_with_query": false,
		"metrics": PackedStringArray(),
	}


## Non-boolean provider policy, kept out of host_caps so capability tests stay
## boolean. sorts and landing_sections being empty is a supported state: it
## means the Browse tab renders no sort control and no landing sections.
func host_empty_scalars() -> Dictionary:
	return {
		"sorts": [],
		"landing_sections": [],
		"query_max_len": 150,
		"page_size": 50,
		"version_batch_size": 1,
	}
