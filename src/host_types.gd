# Provider-neutral host records. Every field is always present with its type; missing data is a
# sentinel ("" for strings, -1 for a metric the host does not report, empty Array/Dictionary).

const HOST_MODWORKSHOP := "modworkshop"
const HOST_VOSTOKMODS := "vostokmods"

## Providers the on-disk source parser accepts; anything else fails at parse time.
const HOST_PROVIDERS_KNOWN: Array[String] = [HOST_MODWORKSHOP, HOST_VOSTOKMODS]

const HOST_ERR_OFFLINE := "offline"
const HOST_ERR_RATE_LIMITED := "rate_limited"
const HOST_ERR_AUTH := "auth"
const HOST_ERR_NOT_FOUND := "not_found"
# Separate from NOT_FOUND: the install copy tells "no such mod" from "nothing to download".
const HOST_ERR_NO_FILE := "no_file"
const HOST_ERR_NOT_SCANNED := "not_scanned"  # the host has not cleared a pinned version yet
const HOST_ERR_VERSION_NOT_FOUND := "version_not_found"
const HOST_ERR_SERVER := "server"
const HOST_ERR_CLIENT := "client"  # a 4xx with no better name
const HOST_ERR_TOO_LARGE := "too_large"
const HOST_ERR_BAD_RESPONSE := "bad_response"  # unparseable, or a captive portal's HTML
const HOST_ERR_UNWIRED := "unwired"  # a provider with no dispatch arm: a loader bug


func host_ok(data: Variant) -> Dictionary:
	return {
		"ok": true,
		"data": data,
		"code": "",
		"http": 0,
		"message": "",
	}


func host_err(code: String, http: int, message: String) -> Dictionary:
	return {
		"ok": false,
		"data": null,
		"code": code,
		"http": http,
		"message": message,
	}


func _host_bad_response(provider: String) -> Dictionary:
	return host_err(HOST_ERR_BAD_RESPONSE, 0, host_display_name(provider) + " sent an unexpected response")


func _host_no_file(http: int = 0) -> Dictionary:
	return host_err(HOST_ERR_NO_FILE, http, "that mod has no downloadable file")


## A FileRecord without a download_url is HOST_ERR_NO_FILE, never a record to fetch.
func _host_file_result(f: Dictionary) -> Dictionary:
	if str(f["download_url"]) == "":
		return _host_no_file()
	return host_ok(f)


## Neither a rate limit nor a dead connection clears inside a batch loop.
func _host_batch_should_stop(code: String) -> bool:
	return code == HOST_ERR_RATE_LIMITED or code == HOST_ERR_OFFLINE


func host_ref(provider: String, id: String) -> Dictionary:
	return {"provider": provider, "id": id}


func host_ref_valid(ref: Dictionary) -> bool:
	return str(ref.get("provider", "")) != "" and str(ref.get("id", "")) != ""


## "modworkshop:12345", or "" when either half is missing (the single "no source" test).
func host_ref_key(ref: Dictionary) -> String:
	if not host_ref_valid(ref):
		return ""
	return str(ref["provider"]) + ":" + str(ref["id"])


## Inverse of host_ref_key and the parser for mod.txt's source=. A bare id is refused:
## guessing the host is how a mod downloads a stranger's upload. Ids may contain colons.
func host_ref_from_key(key: String) -> Dictionary:
	var sep := key.find(":")
	if sep <= 0:
		return {}
	var provider := key.substr(0, sep).strip_edges().to_lower()
	if not HOST_PROVIDERS_KNOWN.has(provider):
		return {}
	var id := key.substr(sep + 1).strip_edges()
	if id.is_empty():
		return {}
	return host_ref(provider, id)


## str() that reads null as "" rather than "<null>", so a null URL fails the empty checks.
func _host_str(v: Variant) -> String:
	return "" if v == null else str(v)


func _host_id_str(v: Variant) -> String:
	# Godot parses every JSON number as a float: str() would turn id 12345 into
	# "12345.0", a broken URL segment and a key that never matches mod.txt.
	if v == null:
		return ""
	if v is float:
		return str(int(v))
	if v is int:
		return str(v)
	return str(v).strip_edges()


## A metric off a host payload; absent reads as -1, never 0.
func _host_count(v: Variant) -> int:
	if v is int:
		return v
	if v is float:
		return int(v)
	return -1


## cache_key is an immutable-per-image disk cache name; "" keeps the image off disk.
func host_image(url: String, cache_key: String) -> Dictionary:
	return {"url": url, "cache_key": cache_key}


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
		"thumbnail": host_image("", ""),
		"short_description": "",
		"default_file_id": "",
	}


## `description` is always BBCode; each adapter converts from what its host speaks.
func host_empty_detail() -> Dictionary:
	var d := host_empty_summary()
	d["banner"] = host_image("", "")
	d["description"] = ""
	return d


func host_empty_file() -> Dictionary:
	return {
		"id": "",
		"version": "",
		"download_url": "",
		"size": -1,
		"created_at": "",
		"filename_hint": "",
	}


## parent_id "" means top-level.
func host_category(id: String, name: String, parent_id: String) -> Dictionary:
	return {"id": id, "name": name, "parent_id": parent_id}


## A page-numbered host puts its next page number in next_cursor; total -1 is unreported.
func host_page(rows: Array, has_more: bool, next_cursor: String, total: int) -> Dictionary:
	return {
		"rows": rows,
		"has_more": has_more,
		"next_cursor": next_cursor,
		"total": total,
	}


func host_empty_caps() -> Dictionary:
	return {
		"browse": false,
		"search": false,
		"categories": false,
		"file_history": false,
		"resolve_file": false,  # the one cap the Download button keys on
		"lists_downloadable": false,  # rows say whether there is a file; else Download shows on every row
		"total_count": false,
		"sort_ignored_with_query": false,
		"metrics": PackedStringArray(),
	}


## Non-boolean provider policy. Empty sorts or landing_sections hide that Browse control.
func host_empty_scalars() -> Dictionary:
	return {
		"sorts": [],
		"landing_sections": [],
		"query_max_len": 150,
	}
