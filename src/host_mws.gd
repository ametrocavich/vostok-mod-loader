## ----- host_mws.gd -----
## ModWorkshop adapter: reference implementation of the host seam. Talks to
## api.modworkshop.net through the shared transport in host_http.gd and
## normalizes its payloads into host_types.gd records.
##
## Endpoints are documented at github.com/ModWorkshop/site
## (backend/routes/api.php). Rate budget: 90 req/min/IP unauthenticated,
## x-ratelimit-remaining on every response. Every request needs a real
## User-Agent: an empty or default one gets a bodyless 403. The envelope
## shape (data vs bare object) varies by endpoint, so unwrapping is done per
## operation below.

const MODWORKSHOP_VERSIONS_URL := "https://api.modworkshop.net/mods/versions"
const MODWORKSHOP_PAGE_URL_TEMPLATE := "https://modworkshop.net/mod/%s"
const MODWORKSHOP_BATCH_SIZE := 100

# ModWorkshop API (host_mws.gd): an empty/default User-Agent gets a 403; game 864 = RTV.
const MWS_API_BASE := "https://api.modworkshop.net"
const MWS_STORAGE_BASE := "https://storage.modworkshop.net"
const MWS_RTV_GAME_ID := 864
const MWS_PAGE_LIMIT := 50
# The API caps search queries at 150 chars and answers longer ones with a 422.
const MWS_QUERY_MAX_LEN := 150

# Cache TTLs: listings go stale fast, detail and history rarely, categories
# barely. The file endpoints get a short TTL so a stale download_url does
# not outlive a CDN rotation.
const _MWS_TTL_LIST_MS := 5 * 60 * 1000
const _MWS_TTL_DETAIL_MS := 30 * 60 * 1000
const _MWS_TTL_CATEGORIES_MS := 60 * 60 * 1000
const _MWS_TTL_PRIMARY_MS := 60 * 1000

func _mwsp_caps() -> Dictionary:
	var caps := host_empty_caps()
	caps["browse"] = true
	caps["search"] = true
	caps["categories"] = true
	caps["file_history"] = true
	caps["resolve_file"] = true
	caps["version_pin"] = true
	caps["page_url"] = true
	caps["batch_versions"] = true
	caps["total_count"] = true
	# The API ignores `sort` when `query` is non-empty; Browse re-sorts
	# search results client-side.
	caps["sort_ignored_with_query"] = true
	caps["metrics"] = PackedStringArray(["downloads", "likes", "views"])
	return caps


func _mwsp_scalars() -> Dictionary:
	var s := host_empty_scalars()
	# Menu order. "Featured" is not a sort; it is the curated landing below.
	# row_field names the ModSummary field each sort orders by; the Browse
	# tab re-sorts search results client-side because this API ignores
	# `sort` when `query` is set, and the mapping belongs with the key names.
	s["sorts"] = [
		{"key": "bumped_at", "label": "Recently updated", "row_field": "updated_at"},
		{"key": "downloads", "label": "Most downloaded", "row_field": "downloads"},
		{"key": "likes", "label": "Most liked", "row_field": "likes"},
		{"key": "views", "label": "Most viewed", "row_field": "views"},
		{"key": "published_at", "label": "Newest", "row_field": "published_at"},
	]
	# The popular-and-latest route is dead upstream, so the landing is two
	# ordinary list queries.
	s["landing_sections"] = [
		{"key": "popular", "title": "Popular this week", "sort_key": "weekly_score", "limit": 10},
		{"key": "latest", "title": "Latest", "sort_key": "bumped_at", "limit": 10},
	]
	s["query_max_len"] = MWS_QUERY_MAX_LEN
	s["page_size"] = MWS_PAGE_LIMIT
	s["version_batch_size"] = MODWORKSHOP_BATCH_SIZE
	return s


func _mwsp_mod_page_url(id: String) -> String:
	if id.is_empty():
		return ""
	return MODWORKSHOP_PAGE_URL_TEMPLATE % id


## Laravel dialect: 429 + Retry-After in seconds, X-RateLimit-Remaining on
## every response.
func _mwsp_note_rate_headers(status: int, headers: PackedStringArray) -> void:
	# Seconds only. to_int() on the HTTP-date form would string its digits
	# together into a huge number, so that form reads as absent.
	var retry_after := _hnet_header_value(headers, "Retry-After").strip_edges()
	var wait_s := retry_after.to_int() if retry_after.is_valid_int() else 0
	if status == 429:
		# An absent Retry-After gives wait_s == 0; pass 0 through so
		# host_arm_cooldown applies its 60s default. Clamping 0 up to 1 would
		# arm a 1s cooldown the transport waits out and retries into.
		host_arm_cooldown(HOST_MODWORKSHOP, clampi(wait_s, 1, 900) * 1000 if wait_s > 0 else 0)
		return
	var remaining := _hnet_header_value(headers, "X-RateLimit-Remaining")
	# A 2xx with 0 remaining was the last request this window allows; success
	# responses do not say when the window resets, so assume a full minute.
	if remaining.is_valid_int() and remaining.to_int() <= 0:
		host_arm_cooldown(HOST_MODWORKSHOP, 0)


## Pull the "data" array out of a list response; an `as Array` cast would
## crash on data:null or a non-array (an error page served with a 2xx).
func _mws_data_rows(resp: Variant) -> Array:
	if not (resp is Dictionary):
		return []
	var d: Variant = (resp as Dictionary).get("data", [])
	return d if d is Array else []


func _mwsp_games_url(tail: String) -> String:
	return MWS_API_BASE + "/games/" + str(MWS_RTV_GAME_ID) + tail


# ----- normalizers -----

## Full URL for an Image record ({file, has_thumb}); the smaller /thumbs/
## variant when wanted and available. The URL convention's one home.
func mws_image_url(image_record: Dictionary, want_thumb: bool = false) -> String:
	var fn: String = _host_str(image_record.get("file"))
	if fn.is_empty():
		return ""
	var has_thumb: bool = bool(image_record.get("has_thumb", false))
	if want_thumb and has_thumb:
		return MWS_STORAGE_BASE + "/mods/images/thumbs/" + fn
	return MWS_STORAGE_BASE + "/mods/images/" + fn


## MWS Image record ({file, has_thumb}) -> ImageRef. `file` is an opaque
## storage filename that never changes for a given image, so it doubles as
## the disk cache key.
func _mwsp_image(v: Variant) -> Dictionary:
	if not (v is Dictionary):
		return host_image("", "", "")
	var rec: Dictionary = v
	var fn := _host_str(rec.get("file"))
	if fn.is_empty():
		return host_image("", "", "")
	return host_image(mws_image_url(rec, false), mws_image_url(rec, true), fn)


func _mwsp_summary(v: Variant) -> Dictionary:
	var s := host_empty_summary()
	if not (v is Dictionary):
		return s
	var row: Dictionary = v
	var id := _host_id_str(row.get("id", ""))
	if id.is_empty():
		return s
	s["ref"] = host_ref(HOST_MODWORKSHOP, id)
	s["name"] = _host_str(row.get("name"))
	if s["name"] == "":
		s["name"] = id
	var user: Variant = row.get("user")
	if user is Dictionary:
		s["author_name"] = _host_str((user as Dictionary).get("name"))
	var category: Variant = row.get("category")
	if category is Dictionary:
		s["category_name"] = _host_str((category as Dictionary).get("name"))
	s["version"] = _host_str(row.get("version")).strip_edges()
	s["downloads"] = _host_count(row.get("downloads"))
	s["likes"] = _host_count(row.get("likes"))
	s["views"] = _host_count(row.get("views"))
	s["updated_at"] = _host_str(row.get("bumped_at"))
	s["published_at"] = _host_str(row.get("published_at"))
	s["short_description"] = _host_str(row.get("short_desc"))
	s["thumbnail"] = _mwsp_image(row.get("thumbnail"))
	s["default_file_id"] = _host_id_str(row.get("download_id", ""))
	return s


func _mwsp_file(v: Variant) -> Dictionary:
	var f := host_empty_file()
	if not (v is Dictionary):
		return f
	var rec: Dictionary = v
	f["id"] = _host_id_str(rec.get("id", ""))
	f["version"] = _host_str(rec.get("version")).strip_edges()
	# _host_str, not str: a null download_url must read as "" so
	# _mwsp_file_result returns HOST_ERR_NO_FILE.
	f["download_url"] = _host_str(rec.get("download_url"))
	f["size"] = _host_count(rec.get("size"))
	f["created_at"] = _host_str(rec.get("created_at"))
	f["filename_hint"] = _mwsp_filename_hint(f["download_url"])
	return f


## Storage links carry the real filename in a ?filename= parameter.
func _mwsp_filename_hint(download_url: String) -> String:
	var q := download_url.find("?filename=")
	if q < 0:
		return ""
	return download_url.substr(q + 10).uri_decode().get_file()


# ----- operations -----

## The query string of a listing request. `limit` in the seam's query is the
## row count the caller wants; it is clamped to the host's cap, and absent
## means a full page.
func _mwsp_list_params(q: Dictionary, page: int) -> PackedStringArray:
	var params := PackedStringArray()
	var query := str(q.get("query", ""))
	if query != "":
		# Clamp rather than 422; an over-limit query would read as a
		# connection error.
		params.append("query=" + query.substr(0, MWS_QUERY_MAX_LEN).uri_encode())
	var sort_key := str(q.get("sort_key", ""))
	params.append("sort=" + (sort_key if sort_key != "" else "bumped_at"))
	var limit := int(q.get("limit", 0))
	params.append("limit=" + str(clampi(limit, 1, MWS_PAGE_LIMIT) if limit > 0 else MWS_PAGE_LIMIT))
	params.append("page=" + str(page))
	var category_id := str(q.get("category_ref", "")).to_int()
	if category_id > 0:
		params.append("category_id=" + str(category_id))
	return params


## Search / sort / filter the RTV catalog -> {data: [rows], meta}. The
## search parameter is `query` (max 150; `search`, `q` and `name` are
## silently ignored). limit caps at 50; larger values 422. Sort enum:
## bumped_at (default), published_at, likes, downloads, views, score,
## weekly_score, daily_score, random, best_match, name.
func _mwsp_list_mods(q: Dictionary) -> Dictionary:
	# MWS pages by number; the seam speaks cursors, so convert here.
	var page := maxi(1, str(q.get("cursor", "")).to_int())
	var params := _mwsp_list_params(q, page)
	var res := await _hnet_get_json(HOST_MODWORKSHOP, _mwsp_games_url("/mods?" + "&".join(params)), _MWS_TTL_LIST_MS)
	if not res["ok"]:
		return res
	var raw: Variant = res["data"]
	if not (raw is Dictionary):
		return host_err(HOST_ERR_BAD_RESPONSE, 0, "ModWorkshop sent an unexpected response")

	var rows := []
	for row in _mws_data_rows(raw):
		var summary := _mwsp_summary(row)
		# A row without a resolvable id cannot be opened or downloaded; drop it.
		if host_ref_valid(summary["ref"]):
			rows.append(summary)

	var meta_v: Variant = (raw as Dictionary).get("meta")
	var meta: Dictionary = meta_v if meta_v is Dictionary else {}
	var last_page := _host_count(meta.get("last_page"))
	var has_more := last_page > page
	var next_cursor := str(page + 1) if has_more else ""
	return host_ok(host_page(rows, has_more, next_cursor, _host_count(meta.get("total"))))


## /mods/{id} returns the mod object directly (name, user, desc/short_desc,
## thumbnail and banner).
func _mwsp_get_mod(ref: Dictionary) -> Dictionary:
	var res := await _hnet_get_json(HOST_MODWORKSHOP, MWS_API_BASE + "/mods/" + str(ref["id"]).uri_encode(), _MWS_TTL_DETAIL_MS)
	if not res["ok"]:
		return res
	var raw: Variant = res["data"]
	if not (raw is Dictionary):
		return host_err(HOST_ERR_BAD_RESPONSE, 0, "ModWorkshop sent an unexpected response")
	# /mods/{id} returns the object directly, but callers also feed listing
	# rows through here; unwrap a {data} envelope when present.
	var row: Dictionary = raw
	var inner: Variant = row.get("data")
	if inner is Dictionary:
		row = inner

	var detail := host_empty_detail()
	detail.merge(_mwsp_summary(row), true)
	detail["banner"] = _mwsp_image(row.get("banner"))
	detail["description"] = _markdown_to_bbcode(str(row.get("desc", row.get("short_desc", ""))))
	return host_ok(detail)


## Full file history -> {data: [File], meta}; each File carries version,
## size, created_at and its own download_url.
func _mwsp_list_files(ref: Dictionary) -> Dictionary:
	var res := await _hnet_get_json(HOST_MODWORKSHOP, MWS_API_BASE + "/mods/" + str(ref["id"]).uri_encode() + "/files", _MWS_TTL_DETAIL_MS)
	if not res["ok"]:
		return res
	var raw: Variant = res["data"]
	var files := []
	for row in _mws_data_rows(raw):
		var f := _mwsp_file(row)
		if str(f["download_url"]) != "":
			files.append(f)
	return host_ok(files)


## /files/primary is the author-pinned default (display_order = 0).
## /files/latest sorts by the API's own key (semver desc, excludes
## prereleases) and can return an older file than primary, so it is only
## the fallback when no primary is designated. /files/{version} is the
## record for an exact version; a missing one is reported as such, never
## substituted, since a pinned modpack apply depends on it.
func _mwsp_resolve_file(ref: Dictionary, version: String) -> Dictionary:
	var base := MWS_API_BASE + "/mods/" + str(ref["id"]).uri_encode() + "/files"

	if version != "":
		var pinned := await _hnet_get_json(HOST_MODWORKSHOP, base + "/" + version.uri_encode(), _MWS_TTL_PRIMARY_MS)
		if not pinned["ok"]:
			if str(pinned["code"]) == HOST_ERR_NOT_FOUND:
				# Absent upstream: the author deleted the upload or never made it.
				return host_err(HOST_ERR_VERSION_NOT_FOUND, 404,
						"version %s is not available" % version)
			return pinned
		return _mwsp_file_result(pinned["data"])

	var primary := await _hnet_get_json(HOST_MODWORKSHOP, base + "/primary", _MWS_TTL_PRIMARY_MS)
	if primary["ok"] and primary["data"] is Dictionary:
		return _mwsp_file_result(primary["data"])
	if not primary["ok"] and str(primary["code"]) != HOST_ERR_NOT_FOUND:
		return primary
	var latest := await _hnet_get_json(HOST_MODWORKSHOP, base + "/latest", _MWS_TTL_PRIMARY_MS)
	if latest["ok"] and latest["data"] is Dictionary:
		return _mwsp_file_result(latest["data"])
	if not latest["ok"] and str(latest["code"]) != HOST_ERR_NOT_FOUND:
		return latest
	return host_err(HOST_ERR_NO_FILE, 404, "that mod has no downloadable file")


func _mwsp_file_result(raw: Variant) -> Dictionary:
	var f := _mwsp_file(raw)
	if str(f["download_url"]) == "":
		return host_err(HOST_ERR_NO_FILE, 0, "that mod has no downloadable file")
	return host_ok(f)


## Category list -> {data: [Category], meta}. Tree-shaped via parent_id;
## top-level nodes have parent_id == null.
func _mwsp_list_categories() -> Dictionary:
	var res := await _hnet_get_json(HOST_MODWORKSHOP, _mwsp_games_url("/categories"), _MWS_TTL_CATEGORIES_MS)
	if not res["ok"]:
		return res
	var raw: Variant = res["data"]
	var out := []
	for row in _mws_data_rows(raw):
		if not (row is Dictionary):
			continue
		var rec: Dictionary = row
		var id := _host_id_str(rec.get("id", ""))
		if id.is_empty():
			continue
		# parent_id is null for top-level nodes; "" is the seam's sentinel.
		var parent: Variant = rec.get("parent_id")
		var parent_id := "" if parent == null else _host_id_str(parent)
		out.append(host_category(id, _host_str(rec.get("name")), parent_id))
	return host_ok(out)


## The versions endpoint answers up to MODWORKSHOP_BATCH_SIZE ids per call
## as {"<id>": "<version>"}. Ids go as repeated ?mod_ids[]= query params; a
## JSON GET body is ignored and answered with 422. Chunks stream through
## on_progress so a rate limit part-way through still leaves the answers
## already collected.
func _mwsp_latest_versions(ids: PackedStringArray, on_progress: Callable) -> Dictionary:
	var versions := {}
	var done := 0
	var last_err := {}
	for start in range(0, ids.size(), MODWORKSHOP_BATCH_SIZE):
		var chunk := ids.slice(start, mini(start + MODWORKSHOP_BATCH_SIZE, ids.size()))
		var parts := PackedStringArray()
		for id in chunk:
			parts.append("mod_ids[]=" + str(id).uri_encode())
		var res := await _hnet_get_json(HOST_MODWORKSHOP, MODWORKSHOP_VERSIONS_URL + "?" + "&".join(parts))
		done += chunk.size()
		if not res["ok"]:
			last_err = res
			# Neither a rate limit nor a dead connection clears inside this
			# loop; stop rather than spend the rest of the list on certain
			# failures. Nothing resolved reports the failure, not an empty
			# success the update check would report as "everything is up to date".
			var code := str(res["code"])
			if code == HOST_ERR_RATE_LIMITED or code == HOST_ERR_OFFLINE:
				return res if versions.is_empty() else host_ok(versions)
			continue
		if not (res["data"] is Dictionary):
			last_err = host_err(HOST_ERR_BAD_RESPONSE, 0, "versions response was not an object")
			continue
		var partial := {}
		for id_v in (res["data"] as Dictionary):
			var version := _host_str((res["data"] as Dictionary)[id_v])
			var key := host_ref_key(host_ref(HOST_MODWORKSHOP, _host_id_str(id_v)))
			if version == "" or key == "":
				continue
			versions[key] = version
			partial[key] = version
		if on_progress.is_valid():
			on_progress.call({"done": done, "total": ids.size(), "partial": partial})
	if versions.is_empty() and not last_err.is_empty():
		return last_err
	return host_ok(versions)
