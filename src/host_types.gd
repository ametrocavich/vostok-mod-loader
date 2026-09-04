## ----- host_types.gd -----
## Provider-neutral vocabulary for talking to a mod host.
##
## Every field in every record is always present with its declared type;
## missing data is a sentinel, never an absent key, so consumers write
## rec["name"] without shape-checking. Sentinels: String -> "", counters ->
## -1 ("host does not report this metric", distinct from a real 0),
## Array/Dictionary -> empty.
##
## host_ref_key's "provider:id" grammar is the same one mod.txt's [updates]
## source= key uses; one parser serves both so they cannot drift.

const HOST_MODWORKSHOP := "modworkshop"
const HOST_NEXUS := "nexus"
const HOST_VOSTOKMODS := "vostokmods"

## Providers the on-disk parser accepts. Anything else is rejected at parse
## time so a typo fails loudly instead of resolving to the wrong host.
const HOST_PROVIDERS_KNOWN: Array[String] = ["modworkshop", "nexus", "vostokmods"]

# Failure codes. Each exists because some caller branches on it.
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

# NO_FILE stays separate from NOT_FOUND: mod_discovery.gd distinguishes
# "no such mod" from "nothing to download" in its user-facing copy.


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


## Stable string key for a ref: "modworkshop:12345". "" when either half is
## missing, which is the single "no source" test.
func host_ref_key(ref: Dictionary) -> String:
	if not host_ref_valid(ref):
		return ""
	return str(ref["provider"]) + ":" + str(ref["id"])


## Inverse of host_ref_key, and the parser for mod.txt's `source=` value.
## Splits on the first colon only: ids are opaque and may contain colons.
## Returns {} for anything not <known-provider>:<non-empty-id>; a bare value
## is never assumed to be a ModWorkshop id, since guessing the host is how a
## mod downloads a stranger's upload.
func host_ref_from_key(key: String) -> Dictionary:
	var sep := key.find(":")
	if sep <= 0:
		return {}
	# Lowercase the provider half so a hand-authored "ModWorkshop:12" resolves;
	# the known set is lowercase with no case collisions. The id half stays
	# case-sensitive and opaque.
	var provider := key.substr(0, sep).strip_edges().to_lower()
	if not HOST_PROVIDERS_KNOWN.has(provider):
		return {}
	var id := key.substr(sep + 1).strip_edges()
	if id.is_empty():
		return {}
	return host_ref(provider, id)


## str() that maps null to "" instead of the literal "<null>". Every
## normalizer string field flows through here, so a host's null download_url
## or name fails the empty-field checks instead of reaching a URL.
func _host_str(v: Variant) -> String:
	return "" if v == null else str(v)


func _host_id_str(v: Variant) -> String:
	# Godot parses every JSON number as a float, so plain str() would turn id
	# 12345 into "12345.0" (a broken URL segment and a key that never matches
	# mod.txt). Every id crossing the seam goes through here; null reads as "".
	if v == null:
		return ""
	if v is float:
		return str(int(v))
	if v is int:
		return str(v)
	return str(v).strip_edges()


# ----- records -----

## Read a metric off a host payload; absent must read as -1, never 0.
func _host_count(v: Variant) -> int:
	if v is int:
		return v
	if v is float:
		return int(v)
	return -1


## An image the UI may display. thumb_url is "" when the host serves one
## size. cache_key is an opaque immutable-per-image token used as the disk
## cache filename; "" means no immutability promise, so never cached to disk.
func host_image(url: String, thumb_url: String, cache_key: String) -> Dictionary:
	return {"url": url, "thumb_url": thumb_url, "cache_key": cache_key}


## A listing row; adapters start from this and overwrite what they can
## supply, so every adapter inherits a new field's sentinel.
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


## A summary plus the two fields only the detail modal needs. `description`
## is always BBCode: adapters own the conversion from what their host speaks.
func host_empty_detail() -> Dictionary:
	var d := host_empty_summary()
	d["banner"] = host_image("", "", "")
	d["description"] = ""
	return d


## One downloadable artifact. download_url is required non-empty: an adapter
## that cannot produce one returns HOST_ERR_NO_FILE instead. filename_hint
## carries whatever the host knows about the eventual filename, so the
## install tail reads one field instead of re-parsing URLs per host. headers
## is per-file so a signed-CDN host can attach a token to one download.
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


## parent_id "" means top-level; flat hosts leave it "" on every entry.
func host_category(id: String, name: String, parent_id: String) -> Dictionary:
	return {"id": id, "name": name, "parent_id": parent_id}


## One page of listing rows. Paging is has_more + next_cursor only; a
## page-numbered host stringifies its number into the cursor. total is -1
## when the host does not report one.
func host_page(rows: Array, has_more: bool, next_cursor: String, total: int) -> Dictionary:
	return {
		"rows": rows,
		"has_more": has_more,
		"next_cursor": next_cursor,
		"total": total,
	}


## What a provider can do. Static and network-free, safe during widget
## construction; the UI hides controls for capabilities that are off.
func host_empty_caps() -> Dictionary:
	return {
		"browse": false,
		"search": false,
		"categories": false,
		"file_history": false,
		# Whether host_resolve_file can produce a FileRecord. This is the one
		# cap the Download button keys on; file_history is separate (a host
		# can serve a current file without exposing history, and vice versa).
		"resolve_file": false,
		# Whether a listing row already says if the mod has a file to serve
		# (default_file_id "" then means "nothing to download"). A host that
		# leaves this false decides at download time, so the UI offers
		# Download on every row.
		"lists_downloadable": false,
		"version_pin": false,
		"page_url": false,
		"batch_versions": false,
		"total_count": false,
		"sort_ignored_with_query": false,
		"metrics": PackedStringArray(),
	}


## Non-boolean provider policy, kept out of host_caps so capability tests
## stay boolean. Empty sorts/landing_sections is a supported state: the
## Browse tab renders no sort control and no landing sections.
func host_empty_scalars() -> Dictionary:
	return {
		"sorts": [],
		"landing_sections": [],
		"query_max_len": 150,
		"page_size": 50,
		"version_batch_size": 1,
	}
