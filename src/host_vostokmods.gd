## ----- host_vostokmods.gd -----
## VostokMods adapter (vostokmods.net). Endpoint contracts are in
## .research/VOSTOKMODS_API.md.
##
## A mod's identity here is its slug, not its numeric id: every route is
## slug-keyed and the id addresses nothing, so a ref is
## host_ref("vostokmods", "<slug>") and mod.txt declares
## source="vostokmods:my-mod-slug". A rename can change the slug; accepted,
## since the id cannot address any endpoint.
##
## The host scans uploads and refuses to serve versions whose scan is not
## clean (`downloadable` false); this adapter treats those as having no file.

const VM_API_BASE := "https://vostokmods.net/api"
const VM_SITE_BASE := "https://vostokmods.net"

# Like the ModWorkshop TTLs: listings go stale fast, detail rarely, categories almost never.
const _VM_TTL_LIST_MS := 5 * 60 * 1000
const _VM_TTL_DETAIL_MS := 30 * 60 * 1000
const _VM_TTL_CATEGORIES_MS := 60 * 60 * 1000

# The listing schema caps `q` at 100 characters and defaults `limit` to 24.
const _VM_QUERY_MAX_LEN := 100
const _VM_PAGE_SIZE := 24


func _vmp_caps() -> Dictionary:
	var caps := host_empty_caps()
	caps["browse"] = true
	caps["search"] = true
	caps["categories"] = true
	caps["file_history"] = true
	caps["version_pin"] = true
	caps["page_url"] = true
	caps["total_count"] = true
	# `sort` and `q` apply independently; search needs no client-side re-sort.
	caps["metrics"] = PackedStringArray(["downloads", "views"])
	return caps


func _vmp_scalars() -> Dictionary:
	var s := host_empty_scalars()
	# Keys are the API's sort enum verbatim. newestFile is the site's own
	# default: it orders by the latest clean file, where `updated` bumps a mod
	# to the top on any edit at all.
	s["sorts"] = [
		{"key": "newestFile", "label": "Newest release"},
		{"key": "updated", "label": "Recently updated"},
		{"key": "downloads", "label": "Most downloaded"},
		{"key": "views", "label": "Most viewed"},
		{"key": "followers", "label": "Most followed"},
		{"key": "newest", "label": "Newest mod"},
	]
	s["landing_sections"] = [
		{"key": "popular", "title": "Popular", "sort_key": "downloads", "limit": 10},
		{"key": "latest", "title": "New releases", "sort_key": "newestFile", "limit": 10},
	]
	s["query_max_len"] = _VM_QUERY_MAX_LEN
	s["page_size"] = _VM_PAGE_SIZE
	# Versions only arrive with the mod detail: one request per update check.
	s["version_batch_size"] = 1
	return s


func _vmp_mod_page_url(slug: String) -> String:
	if slug.is_empty():
		return ""
	# Singular /mod/, not /mods/ -- the listing route is plural, the page is not.
	return VM_SITE_BASE + "/mod/" + slug.uri_encode()


## The host announces no rate-limit dialect (no Retry-After, no
## X-RateLimit-*); the shared transport's default cooldown on 429 is all
## there is.
func _vmp_note_rate_headers(_status: int, _headers: PackedStringArray) -> void:
	pass


# ----- normalizers -----

## Listing row or detail object -> ModSummary (both share these field names).
## followersCount is not mapped onto `likes`: a follow is a subscription,
## not an endorsement.
func _vmp_summary(v: Variant) -> Dictionary:
	var s := host_empty_summary()
	if not (v is Dictionary):
		return s
	var row: Dictionary = v
	var slug := _host_str(row.get("slug")).strip_edges()
	if slug.is_empty():
		return s
	s["ref"] = host_ref(HOST_VOSTOKMODS, slug)
	s["name"] = _host_str(row.get("name"))
	if s["name"] == "":
		s["name"] = slug
	# `author` is the owner's display name; authorId is their username.
	s["author_name"] = _host_str(row.get("author"))
	s["short_description"] = _host_str(row.get("summary"))
	s["downloads"] = _host_count(row.get("downloadsCount"))
	s["views"] = _host_count(row.get("viewsCount"))
	s["updated_at"] = _host_str(row.get("updatedAt"))
	s["published_at"] = _host_str(row.get("createdAt"))
	s["category_name"] = _vmp_primary_category(row.get("categories"))
	# thumbnailUrl is null when a mod has no screenshot. No separate thumb
	# size is served, and the empty cache_key keeps the image out of the disk
	# cache: the host promises nothing about the URL staying the same bytes.
	s["thumbnail"] = host_image(_host_str(row.get("thumbnailUrl")), "", "")
	# Listing cards carry the newest clean version, so a mod with nothing to
	# download is knowable before the detail fetch. default_file_id stays ""
	# when there is no downloadable file, and the Browse tab reads that as
	# "no Download button".
	var latest: Variant = row.get("latestVersion")
	if _vmp_downloadable(latest):
		s["default_file_id"] = _host_str((latest as Dictionary).get("id"))
	return s


## The categories array mixes real categories and tags; `group` is the
## discriminator. Prefer a category-ish group, else the first entry of any.
func _vmp_primary_category(v: Variant) -> String:
	if not (v is Array):
		return ""
	var first_any := ""
	for c in (v as Array):
		if not (c is Dictionary):
			continue
		var rec: Dictionary = c
		var name := _host_str(rec.get("name"))
		if name.is_empty():
			continue
		if first_any.is_empty():
			first_any = name
		if _host_str(rec.get("group")).to_lower().begins_with("categor"):
			return name
	return first_any


## One entry of a detail payload's versions[] -> FileRecord. downloadUrl is
## site-root-relative and 302-redirects to storage; HTTPRequest follows it.
func _vmp_file(v: Variant) -> Dictionary:
	var f := host_empty_file()
	if not (v is Dictionary):
		return f
	var rec: Dictionary = v
	f["id"] = _host_str(rec.get("id"))
	f["version"] = _host_str(rec.get("version")).strip_edges()
	var rel := _host_str(rec.get("downloadUrl"))
	if not rel.is_empty():
		f["download_url"] = rel if rel.begins_with("http") else VM_SITE_BASE + rel
	f["size"] = _host_count(rec.get("fileSize"))
	f["created_at"] = _host_str(rec.get("createdAt"))
	f["filename_hint"] = _host_str(rec.get("fileName")).get_file()
	return f


## Whether the host will actually serve this version (see header).
func _vmp_downloadable(v: Variant) -> bool:
	return v is Dictionary and _json_truthy((v as Dictionary).get("downloadable"))


# ----- operations -----

func _vmp_list_mods(q: Dictionary) -> Dictionary:
	var params := {"page": maxi(1, str(q.get("cursor", "")).to_int())}
	var query := str(q.get("query", ""))
	if query != "":
		# Clamp rather than let the schema reject it: an over-long query
		# would surface as a connection error.
		params["q"] = query.substr(0, _VM_QUERY_MAX_LEN)
	var sort_key := str(q.get("sort_key", ""))
	if sort_key != "":
		params["sort"] = sort_key
	var category := str(q.get("category_ref", ""))
	if category != "":
		# The filter takes comma-separated category slugs.
		params["categories"] = category
	var limit := int(q.get("limit", 0))
	if limit > 0:
		params["limit"] = limit

	var res := await _hnet_get_json(HOST_VOSTOKMODS, VM_API_BASE + "/mods" + _hnet_query(params), _VM_TTL_LIST_MS)
	if not res["ok"]:
		return res
	var body: Variant = res["data"]
	if not (body is Dictionary):
		return host_err(HOST_ERR_BAD_RESPONSE, 0, "VostokMods sent an unexpected response")

	var rows := []
	var raw_rows: Variant = (body as Dictionary).get("mods")
	if raw_rows is Array:
		for row in (raw_rows as Array):
			var summary := _vmp_summary(row)
			# A row with no slug cannot be opened or downloaded; drop it.
			if host_ref_valid(summary["ref"]):
				rows.append(summary)

	var page := _host_count((body as Dictionary).get("page"))
	var page_count := _host_count((body as Dictionary).get("pageCount"))
	var has_more := page > 0 and page_count > page
	return host_ok(host_page(rows, has_more, str(page + 1) if has_more else "",
			_host_count((body as Dictionary).get("total"))))


## Shared fetch: versions arrive only with the mod detail, so detail, file
## history and resolve all go through here and share one cache entry.
func _vmp_detail(slug: String) -> Dictionary:
	if slug.is_empty():
		return host_err(HOST_ERR_NOT_FOUND, 0, "no mod slug")
	var url := VM_API_BASE + "/mods/" + slug.uri_encode()
	var res := await _hnet_get_json(HOST_VOSTOKMODS, url, _VM_TTL_DETAIL_MS)
	if not res["ok"]:
		return res
	if not (res["data"] is Dictionary):
		return host_err(HOST_ERR_BAD_RESPONSE, 0, "VostokMods sent an unexpected response")
	return res


func _vmp_get_mod(ref: Dictionary) -> Dictionary:
	var res := await _vmp_detail(str(ref["id"]))
	if not res["ok"]:
		return res
	var row: Dictionary = res["data"]

	var detail := host_empty_detail()
	detail.merge(_vmp_summary(row), true)
	# Screenshots are ordered by the author; the first doubles as the banner.
	var shots: Variant = row.get("screenshots")
	if shots is Array and not (shots as Array).is_empty():
		var first: Variant = (shots as Array)[0]
		if first is Dictionary:
			detail["banner"] = host_image(_host_str((first as Dictionary).get("url")), "", "")
	# `description` is markdown; the seam's contract is BBCode.
	detail["description"] = _markdown_to_bbcode(_host_str(row.get("description")))
	var versions: Variant = row.get("versions")
	if versions is Array:
		for v in (versions as Array):
			if _vmp_downloadable(v):
				detail["version"] = _host_str((v as Dictionary).get("version")).strip_edges()
				detail["default_file_id"] = _host_str((v as Dictionary).get("id"))
				break
	return host_ok(detail)


func _vmp_list_files(ref: Dictionary) -> Dictionary:
	var res := await _vmp_detail(str(ref["id"]))
	if not res["ok"]:
		return res
	var files := []
	var versions: Variant = (res["data"] as Dictionary).get("versions")
	if versions is Array:
		for v in (versions as Array):
			if not _vmp_downloadable(v):
				continue
			var f := _vmp_file(v)
			if str(f["download_url"]) != "":
				files.append(f)
	return host_ok(files)


func _vmp_resolve_file(ref: Dictionary, version: String) -> Dictionary:
	var res := await _vmp_detail(str(ref["id"]))
	if not res["ok"]:
		return res
	var versions: Variant = (res["data"] as Dictionary).get("versions")
	if not (versions is Array):
		return host_err(HOST_ERR_NO_FILE, 0, "that mod has no downloadable file")

	if version != "":
		for v in (versions as Array):
			if not (v is Dictionary):
				continue
			if _host_str((v as Dictionary).get("version")).strip_edges() != version:
				continue
			# The version exists but the host refuses to serve it -- a
			# different answer from not having it.
			if not _vmp_downloadable(v):
				return host_err(HOST_ERR_NO_FILE, 0,
						"version %s has not passed the host's malware scan" % version)
			return _vmp_file_result(v)
		return host_err(HOST_ERR_VERSION_NOT_FOUND, 404,
				"version %s is not available" % version)

	# versions[] is newest-first, so the first downloadable entry is current.
	for v in (versions as Array):
		if _vmp_downloadable(v):
			return _vmp_file_result(v)
	return host_err(HOST_ERR_NO_FILE, 0, "that mod has no downloadable file")


func _vmp_file_result(v: Variant) -> Dictionary:
	var f := _vmp_file(v)
	if str(f["download_url"]) == "":
		return host_err(HOST_ERR_NO_FILE, 0, "that mod has no downloadable file")
	return host_ok(f)


## Categories are a flat list ordered by group; the group is carried as the
## parent so the filter can render two levels.
func _vmp_list_categories() -> Dictionary:
	var res := await _hnet_get_json(HOST_VOSTOKMODS, VM_API_BASE + "/categories", _VM_TTL_CATEGORIES_MS)
	if not res["ok"]:
		return res
	var rows: Variant = res["data"]
	if not (rows is Array):
		return host_err(HOST_ERR_BAD_RESPONSE, 0, "VostokMods sent an unexpected response")
	var out := []
	for r in (rows as Array):
		if not (r is Dictionary):
			continue
		var rec: Dictionary = r
		# The filter matches on slug, so the slug is the id the seam carries.
		var slug := _host_str(rec.get("slug")).strip_edges()
		if slug.is_empty():
			continue
		out.append(host_category(slug, _host_str(rec.get("name")), _host_str(rec.get("group"))))
	return host_ok(out)


## One detail request per mod: no batch endpoint. Results stream so a
## failure part-way still leaves the answers already collected.
func _vmp_latest_versions(ids: PackedStringArray, on_progress: Callable) -> Dictionary:
	var versions := {}
	var done := 0
	var failures := 0
	for slug in ids:
		var ref := host_ref(HOST_VOSTOKMODS, slug)
		var res := await _vmp_resolve_file(ref, "")
		done += 1
		if not res["ok"]:
			failures += 1
			# Rate limit / offline will not clear mid-loop; stop.
			var code := str(res["code"])
			if code == HOST_ERR_RATE_LIMITED or code == HOST_ERR_OFFLINE:
				if versions.is_empty():
					return res
				return host_ok(versions)
			continue
		var version := str((res["data"] as Dictionary)["version"])
		if version == "":
			continue
		var key := host_ref_key(ref)
		versions[key] = version
		if on_progress.is_valid():
			on_progress.call({"done": done, "total": ids.size(), "partial": {key: version}})
	# Learning nothing must not render as "everything is up to date".
	if versions.is_empty() and failures > 0:
		return host_err(HOST_ERR_BAD_RESPONSE, 0,
				"could not read a version for any of the %d mods checked" % failures)
	return host_ok(versions)
