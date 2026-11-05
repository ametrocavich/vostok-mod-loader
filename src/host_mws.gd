# ModWorkshop adapter. Routes: github.com/ModWorkshop/site backend/routes/api.php. The envelope
# (data vs bare object) varies by endpoint, so each operation unwraps its own.

const MWS_DOMAIN := "modworkshop.net"
const MWS_SITE_BASE := "https://" + MWS_DOMAIN
const MWS_API_BASE := "https://api." + MWS_DOMAIN
const MWS_STORAGE_BASE := "https://storage." + MWS_DOMAIN
const MWS_RTV_GAME_ID := 864  # Road to Vostok
const MWS_PAGE_LIMIT := 50  # a larger limit gets a 422
const MWS_QUERY_MAX_LEN := 150  # a longer query gets a 422
const MWS_BATCH_SIZE := 100

const _MWS_TTL_LIST_MS := 5 * 60 * 1000
const _MWS_TTL_DETAIL_MS := 30 * 60 * 1000
const _MWS_TTL_CATEGORIES_MS := 60 * 60 * 1000
# Short, so a stale download_url does not outlive a CDN rotation.
const _MWS_TTL_PRIMARY_MS := 60 * 1000

func _mwsp_caps() -> Dictionary:
	var caps := host_empty_caps()
	caps["browse"] = true
	caps["search"] = true
	caps["categories"] = true
	caps["file_history"] = true
	caps["resolve_file"] = true
	caps["total_count"] = true
	# The API ignores `sort` when `query` is set; Browse re-sorts search results itself.
	caps["sort_ignored_with_query"] = true
	caps["metrics"] = PackedStringArray(["downloads", "likes", "views"])
	return caps


func _mwsp_scalars() -> Dictionary:
	var s := host_empty_scalars()
	# row_field is the ModSummary field Browse re-sorts search results by.
	s["sorts"] = [
		{"key": "bumped_at", "label": "Recently updated", "row_field": "updated_at"},
		{"key": "downloads", "label": "Most downloaded", "row_field": "downloads"},
		{"key": "likes", "label": "Most liked", "row_field": "likes"},
		{"key": "views", "label": "Most viewed", "row_field": "views"},
		{"key": "published_at", "label": "Newest", "row_field": "published_at"},
	]
	# The popular-and-latest route is dead upstream, so the landing is two list queries.
	s["landing_sections"] = [
		{"title": "Popular this week", "sort_key": "weekly_score", "limit": 10},
		{"title": "Latest", "sort_key": "bumped_at", "limit": 10},
	]
	s["query_max_len"] = MWS_QUERY_MAX_LEN
	return s


func _mwsp_mod_page_url(id: String) -> String:
	if id.is_empty():
		return ""
	return MWS_SITE_BASE + "/mod/" + id


## Laravel dialect: 429 with Retry-After in seconds, X-RateLimit-Remaining on every response.
func _mwsp_note_rate_headers(status: int, headers: PackedStringArray) -> void:
	# to_int() on the HTTP-date form would run its digits together, so that form reads as absent.
	var retry_after := _header_value(headers, "Retry-After").strip_edges()
	var wait_s := retry_after.to_int() if retry_after.is_valid_int() else 0
	if status == 429:
		# 0 lets host_arm_cooldown apply its default; a 1s floor would arm a cooldown the
		# transport waits out and retries straight into.
		host_arm_cooldown(HOST_MODWORKSHOP, clampi(wait_s, 1, 900) * 1000 if wait_s > 0 else 0)
		return
	# A 2xx does not say when the window resets, so 0 remaining assumes a full minute.
	var remaining := _header_value(headers, "X-RateLimit-Remaining")
	if remaining.is_valid_int() and remaining.to_int() <= 0:
		host_arm_cooldown(HOST_MODWORKSHOP, 0)


## `as Array` would crash on data:null or on an error page served with a 2xx.
func _mwsp_data_rows(resp: Variant) -> Array:
	if not (resp is Dictionary):
		return []
	var d: Variant = (resp as Dictionary).get("data", [])
	return d if d is Array else []


func _mwsp_games_url(tail: String) -> String:
	return MWS_API_BASE + "/games/" + str(MWS_RTV_GAME_ID) + tail


func _mwsp_mod_url(ref: Dictionary) -> String:
	return MWS_API_BASE + "/mods/" + str(ref["id"]).uri_encode()


## An Image record's `file` never changes for that image, so it doubles as the cache key.
func _mwsp_image(v: Variant) -> Dictionary:
	var fn := _host_str((v as Dictionary).get("file")) if v is Dictionary else ""
	if fn.is_empty():
		return host_image("", "")
	return host_image(MWS_STORAGE_BASE + "/mods/images/" + fn, fn)


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
	var url := _host_str(rec.get("download_url"))
	f["id"] = _host_id_str(rec.get("id", ""))
	f["version"] = _host_str(rec.get("version")).strip_edges()
	f["download_url"] = url
	f["size"] = _host_count(rec.get("size"))
	f["created_at"] = _host_str(rec.get("created_at"))
	# Storage links carry the real file name in a ?filename= parameter.
	var q := url.find("?filename=")
	if q >= 0:
		f["filename_hint"] = url.substr(q + "?filename=".length()).uri_decode().get_file()
	return f


## `limit` is the row count the caller wants, clamped to the host's cap; absent is a full page.
func _mwsp_list_params(q: Dictionary, page: int) -> Dictionary:
	var params := {}
	var query := str(q.get("query", ""))
	if query != "":
		params["query"] = query.substr(0, MWS_QUERY_MAX_LEN)
	var sort_key := str(q.get("sort_key", ""))
	params["sort"] = sort_key if sort_key != "" else "bumped_at"
	var limit := int(q.get("limit", 0))
	params["limit"] = clampi(limit, 1, MWS_PAGE_LIMIT) if limit > 0 else MWS_PAGE_LIMIT
	params["page"] = page
	var category_id := str(q.get("category_ref", "")).to_int()
	if category_id > 0:
		params["category_id"] = category_id
	return params


func _mwsp_list_mods(q: Dictionary) -> Dictionary:
	var page := maxi(1, str(q.get("cursor", "")).to_int())
	var url := _mwsp_games_url("/mods" + _hnet_query(_mwsp_list_params(q, page)))
	var res := await _hnet_get_json(HOST_MODWORKSHOP, url, _MWS_TTL_LIST_MS)
	if not res["ok"]:
		return res
	var raw: Variant = res["data"]
	if not (raw is Dictionary):
		return _host_bad_response(HOST_MODWORKSHOP)

	var rows := []
	for row in _mwsp_data_rows(raw):
		var summary := _mwsp_summary(row)
		if host_ref_valid(summary["ref"]):
			rows.append(summary)

	var meta_v: Variant = (raw as Dictionary).get("meta")
	var meta: Dictionary = meta_v if meta_v is Dictionary else {}
	var has_more := _host_count(meta.get("last_page")) > page
	return host_ok(host_page(rows, has_more, str(page + 1) if has_more else "", _host_count(meta.get("total"))))


func _mwsp_get_mod(ref: Dictionary) -> Dictionary:
	var res := await _hnet_get_json(HOST_MODWORKSHOP, _mwsp_mod_url(ref), _MWS_TTL_DETAIL_MS)
	if not res["ok"]:
		return res
	if not (res["data"] is Dictionary):
		return _host_bad_response(HOST_MODWORKSHOP)
	var row: Dictionary = res["data"]
	var detail := host_empty_detail()
	detail.merge(_mwsp_summary(row), true)
	detail["banner"] = _mwsp_image(row.get("banner"))
	var desc := _host_str(row.get("desc"))
	if desc.is_empty():
		desc = _host_str(row.get("short_desc"))
	detail["description"] = _markdown_to_bbcode(desc)
	return host_ok(detail)


func _mwsp_list_files(ref: Dictionary) -> Dictionary:
	var res := await _hnet_get_json(HOST_MODWORKSHOP, _mwsp_mod_url(ref) + "/files", _MWS_TTL_DETAIL_MS)
	if not res["ok"]:
		return res
	var files := []
	for row in _mwsp_data_rows(res["data"]):
		var f := _mwsp_file(row)
		if str(f["download_url"]) != "":
			files.append(f)
	return host_ok(files)


## /files/primary is the author's pick; /files/latest (semver, no prereleases) can be older,
## so it is only the fallback. A pinned version is never substituted.
func _mwsp_resolve_file(ref: Dictionary, version: String) -> Dictionary:
	var base := _mwsp_mod_url(ref) + "/files"
	if version != "":
		var pinned := await _hnet_get_json(HOST_MODWORKSHOP, base + "/" + version.uri_encode(), _MWS_TTL_PRIMARY_MS)
		if not pinned["ok"]:
			if str(pinned["code"]) == HOST_ERR_NOT_FOUND:
				return host_err(HOST_ERR_VERSION_NOT_FOUND, 404, "version %s is not available" % version)
			return pinned
		return _host_file_result(_mwsp_file(pinned["data"]))

	for tail in ["/primary", "/latest"]:
		var res := await _hnet_get_json(HOST_MODWORKSHOP, base + tail, _MWS_TTL_PRIMARY_MS)
		if res["ok"] and res["data"] is Dictionary:
			return _host_file_result(_mwsp_file(res["data"]))
		if not res["ok"] and str(res["code"]) != HOST_ERR_NOT_FOUND:
			return res
	return _host_no_file(404)


func _mwsp_list_categories() -> Dictionary:
	var res := await _hnet_get_json(HOST_MODWORKSHOP, _mwsp_games_url("/categories"), _MWS_TTL_CATEGORIES_MS)
	if not res["ok"]:
		return res
	var out := []
	for row in _mwsp_data_rows(res["data"]):
		if not (row is Dictionary):
			continue
		var rec: Dictionary = row
		var id := _host_id_str(rec.get("id", ""))
		if id.is_empty():
			continue
		var parent: Variant = rec.get("parent_id")
		var parent_id := "" if parent == null else _host_id_str(parent)
		out.append(host_category(id, _host_str(rec.get("name")), parent_id))
	return host_ok(out)


## Up to MWS_BATCH_SIZE ids per call as repeated ?mod_ids[]= params, answered as
## {"<id>": "<version>"}; a JSON GET body is answered with a 422.
func _mwsp_latest_versions(ids: PackedStringArray) -> Dictionary:
	var versions := {}
	var last_err := {}
	for start in range(0, ids.size(), MWS_BATCH_SIZE):
		var chunk := ids.slice(start, mini(start + MWS_BATCH_SIZE, ids.size()))
		var parts := PackedStringArray()
		for id in chunk:
			parts.append("mod_ids[]=" + str(id).uri_encode())
		var res := await _hnet_get_json(HOST_MODWORKSHOP, MWS_API_BASE + "/mods/versions?" + "&".join(parts))
		if not res["ok"]:
			last_err = res
			if _host_batch_should_stop(str(res["code"])):
				return res if versions.is_empty() else host_ok(versions)
			continue
		if not (res["data"] is Dictionary):
			last_err = host_err(HOST_ERR_BAD_RESPONSE, 0, "versions response was not an object")
			continue
		for id_v in (res["data"] as Dictionary):
			var version := _host_str((res["data"] as Dictionary)[id_v])
			var key := host_ref_key(host_ref(HOST_MODWORKSHOP, _host_id_str(id_v)))
			if version == "" or key == "":
				continue
			versions[key] = version
	# Nothing resolved reports the failure, not an "everything is up to date" success.
	if versions.is_empty() and not last_err.is_empty():
		return last_err
	return host_ok(versions)
