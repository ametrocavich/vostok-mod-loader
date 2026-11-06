# Vostok Mods adapter. Every route resolves a mod by slug or UUID: listings, packs and download
# URLs carry the slug, the mod.txt the site serves carries the UUID (_vmp_note_ids pairs them).

const VM_API_BASE := "https://vostokmods.net/api"
const VM_SITE_BASE := "https://vostokmods.net"

const _VM_TTL_LIST_MS := 5 * 60 * 1000
const _VM_TTL_DETAIL_MS := 30 * 60 * 1000
# Check for updates asks for fresh data; a minute still absorbs the Mods-tab refresh beside it.
const _VM_TTL_FRESH_MS := 60 * 1000
const _VM_TTL_CATEGORIES_MS := 60 * 60 * 1000

const _VM_QUERY_MAX_LEN := 100  # the listing schema's cap on `q`

# A manifest format above this needs loader work.
const VM_MODPACK_FORMAT := 2
const _VM_MODPACK_PAGE_SIZE := 20
const _VM_PACK_SORTS := [
	{"key": "updated", "label": "Recently updated"},
	{"key": "newest", "label": "Newest"},
	{"key": "downloads", "label": "Most downloaded"},
	{"key": "views", "label": "Most viewed"},
]

# The longest ratelimit-reset read as seconds; a larger one is likely an epoch
# timestamp, which would lock the site out, so the cooldown default applies.
const _VM_MAX_RESET_S := 120

# Shapes already logged as unknown, so each is reported once a session.
var _vmp_unknown_logged := {}


func _vmp_caps() -> Dictionary:
	var caps := host_empty_caps()
	caps["browse"] = true
	caps["search"] = true
	caps["categories"] = true
	caps["file_history"] = true
	caps["resolve_file"] = true
	caps["lists_downloadable"] = true  # cards carry latestVersion.downloadable
	caps["total_count"] = true
	caps["metrics"] = PackedStringArray(["downloads", "views"])
	return caps


func _vmp_scalars() -> Dictionary:
	var s := host_empty_scalars()
	# Keys are the API's sort enum. newestFile orders by the latest clean file, the date rows
	# show; `updated` is left out because any page edit bumps it.
	s["sorts"] = [
		{"key": "newestFile", "label": "Recently updated"},
		{"key": "downloads", "label": "Most downloaded"},
		{"key": "views", "label": "Most viewed"},
		{"key": "followers", "label": "Most followed"},
		{"key": "newest", "label": "Newest mod"},
	]
	s["landing_sections"] = [
		{"title": "Popular", "sort_key": "downloads", "limit": 10},
		{"title": "New releases", "sort_key": "newestFile", "limit": 10},
	]
	s["query_max_len"] = _VM_QUERY_MAX_LEN
	return s


func _vmp_mod_page_url(id: String) -> String:
	if id.is_empty():
		return ""
	# Singular /mod/: the listing route is plural, the page is not.
	return VM_SITE_BASE + "/mod/" + id.uri_encode()


## The Array under `key` (a listing's entries, a detail's versions), or null when absent.
func _vmp_rows(body: Variant, key := "entries") -> Variant:
	if not (body is Dictionary):
		return null
	var rows: Variant = (body as Dictionary).get(key)
	return rows if rows is Array else null


## Every response carries ratelimit-remaining and ratelimit-reset (seconds to the window's end).
func _vmp_note_rate_headers(status: int, headers: PackedStringArray) -> void:
	var remaining := _header_value(headers, "ratelimit-remaining")
	if status != 429 and not (remaining.is_valid_int() and remaining.to_int() <= 0):
		return
	# 0 lets host_arm_cooldown apply its default.
	var reset := _header_value(headers, "ratelimit-reset")
	var ms := 0
	if reset.is_valid_int() and reset.to_int() <= _VM_MAX_RESET_S:
		ms = maxi(reset.to_int(), 1) * 1000
	host_arm_cooldown(HOST_VOSTOKMODS, ms)


## Listing row or detail object; followersCount is a subscription, so it is not `likes`.
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
	s["author_name"] = _host_str(row.get("ownerDisplayName"))
	s["short_description"] = _host_str(row.get("summary"))
	s["downloads"] = _host_count(row.get("downloadsCount"))
	s["views"] = _host_count(row.get("viewsCount"))
	s["published_at"] = _host_str(row.get("createdAt"))
	s["category_name"] = _vmp_primary_category(row.get("taxonomies"))
	# No cache_key: the host promises nothing about the URL keeping the same bytes.
	s["thumbnail"] = host_image(_host_str(row.get("thumbnailUrl")), "")
	# updated_at is the newest clean file's date, as on the site; the row's updatedAt moves on
	# any page edit. A detail payload has no latestVersion: _vmp_detail_record dates it.
	var latest: Variant = row.get("latestVersion")
	if _vmp_downloadable(latest):
		s["default_file_id"] = _host_str((latest as Dictionary).get("id"))
		s["updated_at"] = _host_str((latest as Dictionary).get("createdAt"))
	return s


## Taxonomies mix categories and tags; prefer a category group, else the first named entry.
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
		if _vmp_group_slug(rec.get("group")).to_lower().begins_with("categor"):
			return name
	return first_any


func _vmp_group_slug(v: Variant) -> String:
	if not (v is Dictionary):
		return ""
	return _host_str((v as Dictionary).get("slug"))


## downloadUrl is site-root-relative and 302-redirects to storage; HTTPRequest follows it.
func _vmp_file(v: Variant) -> Dictionary:
	var f := host_empty_file()
	if not (v is Dictionary):
		return f
	var rec: Dictionary = v
	f["id"] = _host_str(rec.get("id"))
	f["version"] = _host_str(rec.get("version")).strip_edges()
	f["download_url"] = _vmp_site_url(_host_str(rec.get("downloadUrl")))
	f["size"] = _host_count(rec.get("fileSize"))
	f["created_at"] = _host_str(rec.get("createdAt"))
	f["filename_hint"] = _host_str(rec.get("fileName")).get_file()
	return f


## A path resolved on the site, an absolute URL only when _vmp_is_site_url passes, else "".
func _vmp_site_url(url: String) -> String:
	var u := url.strip_edges()
	if u.is_empty():
		return ""
	var lower := u.to_lower()
	if not (lower.begins_with("https://") or lower.begins_with("http://")):
		return VM_SITE_BASE + ("" if u.begins_with("/") else "/") + u
	if _vmp_is_site_url(u):
		return u
	_log_debug("[Host] Vostok Mods sent a URL off its site; ignored: " + u.left(40))
	return ""


## https on vostokmods.net or www., no port: fetches and the Open page button both ask this.
## Covers and banners load over https only; "" for anything else.
func _https_url(url: String) -> String:
	return url if url.to_lower().begins_with("https://") else ""


func _vmp_is_site_url(url: String) -> bool:
	return url.to_lower().begins_with("https://") and _vmp_is_site_host(url.substr(8))


## `rest` is a URL after its scheme. Userinfo ("vostokmods.net@other.host") is another host,
## and a port is another origin.
func _vmp_is_site_host(rest: String) -> bool:
	var slash := rest.find("/")
	var host := (rest if slash < 0 else rest.substr(0, slash)).to_lower()
	return host == "vostokmods.net" or host == "www.vostokmods.net"


## The host refuses to serve a version whose malware scan is not clean.
func _vmp_downloadable(v: Variant) -> bool:
	return v is Dictionary and _json_truthy((v as Dictionary).get("downloadable"))


func _vmp_list_mods(q: Dictionary) -> Dictionary:
	var params := {"page": maxi(1, str(q.get("cursor", "")).to_int())}
	var query := str(q.get("query", ""))
	if query != "":
		params["q"] = query.substr(0, _VM_QUERY_MAX_LEN)
	var sort_key := str(q.get("sort_key", ""))
	if sort_key != "":
		params["sort"] = sort_key
	var category := str(q.get("category_ref", ""))
	if category != "":
		params["taxonomies"] = category
	var limit := int(q.get("limit", 0))
	if limit > 0:
		params["limit"] = limit

	var res := await _hnet_get_json(HOST_VOSTOKMODS, VM_API_BASE + "/mods" + _hnet_query(params), _VM_TTL_LIST_MS)
	if not res["ok"]:
		return res
	var body: Variant = res["data"]
	if not (body is Dictionary):
		return _host_bad_response(HOST_VOSTOKMODS)
	# A missing rows key is a changed listing shape, not an empty page.
	var raw_rows: Variant = _vmp_rows(body)
	if raw_rows == null:
		return _host_bad_response(HOST_VOSTOKMODS)

	var rows := []
	for row in (raw_rows as Array):
		_vmp_note_ids(row)
		var summary := _vmp_summary(row)
		if host_ref_valid(summary["ref"]):
			rows.append(summary)
	return host_ok(_vmp_page(body as Dictionary, rows))


func _vmp_page(body: Dictionary, rows: Array) -> Dictionary:
	var page := _host_count(body.get("page"))
	var has_more := page > 0 and _host_count(body.get("pageCount")) > page
	return host_page(rows, has_more, str(page + 1) if has_more else "", _host_count(body.get("total")))


## Versions arrive only with the detail, so detail, file history and resolve share this
## fetch and its cache entry. `id` is the slug or the UUID.
func _vmp_detail(id: String, ttl_ms: int = _VM_TTL_DETAIL_MS) -> Dictionary:
	if id.is_empty():
		return host_err(HOST_ERR_NOT_FOUND, 0, "no mod id")
	var url := VM_API_BASE + "/mods/" + id.uri_encode()
	var res := await _hnet_get_json(HOST_VOSTOKMODS, url, ttl_ms)
	if not res["ok"]:
		return res
	if not (res["data"] is Dictionary):
		return _host_bad_response(HOST_VOSTOKMODS)
	_vmp_note_ids(res["data"])
	return res


# Compiled on first use.
var _vmp_uuid_re: RegEx = null

func _vmp_is_uuid(id: String) -> bool:
	if _vmp_uuid_re == null:
		_vmp_uuid_re = RegEx.new()
		_vmp_uuid_re.compile("^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$")
	return _vmp_uuid_re.search(id) != null


func _vmp_note_ids(row: Variant) -> void:
	if row is Dictionary:
		host_note_same_mod(HOST_VOSTOKMODS, _host_str((row as Dictionary).get("slug")).strip_edges(),
				_host_str((row as Dictionary).get("id")).strip_edges())


func _vmp_get_mod(ref: Dictionary) -> Dictionary:
	var res := await _vmp_detail(str(ref["id"]))
	if not res["ok"]:
		return res
	return host_ok(_vmp_detail_record(res["data"]))


func _vmp_detail_record(row: Dictionary) -> Dictionary:
	var detail := host_empty_detail()
	detail.merge(_vmp_summary(row), true)
	detail["banner"] = _vmp_banner(row)
	detail["description"] = _markdown_to_bbcode(_host_str(row.get("description")))
	var versions: Variant = _vmp_rows(row, "versions")
	if versions != null:
		for v in (versions as Array):
			if _vmp_downloadable(v):
				detail["version"] = _host_str((v as Dictionary).get("version")).strip_edges()
				detail["default_file_id"] = _host_str((v as Dictionary).get("id"))
				detail["updated_at"] = _host_str((v as Dictionary).get("createdAt"))
				break
	return detail


## The author orders the screenshots: the first one not hidden, else the cover.
func _vmp_banner(row: Dictionary) -> Dictionary:
	var shots: Variant = row.get("screenshots")
	if shots is Array:
		for shot in (shots as Array):
			if shot is Dictionary and not _json_truthy((shot as Dictionary).get("hidden")):
				return host_image(_host_str((shot as Dictionary).get("url")), "")
	return host_image(_host_str(row.get("thumbnailUrl")), "")


func _vmp_list_files(ref: Dictionary) -> Dictionary:
	var res := await _vmp_detail(str(ref["id"]))
	if not res["ok"]:
		return res
	var files := []
	var versions: Variant = _vmp_rows(res["data"], "versions")
	if versions != null:
		for v in (versions as Array):
			if not _vmp_downloadable(v):
				continue
			var f := _vmp_file(v)
			if str(f["download_url"]) != "":
				files.append(f)
	return host_ok(files)


func _vmp_resolve_file(ref: Dictionary, version: String, ttl_ms: int = _VM_TTL_DETAIL_MS) -> Dictionary:
	var res := await _vmp_detail(str(ref["id"]), ttl_ms)
	if not res["ok"]:
		return res
	var versions: Variant = _vmp_rows(res["data"], "versions")
	if versions == null:
		return _host_no_file()

	if version != "":
		for v in (versions as Array):
			if not (v is Dictionary):
				continue
			if _host_str((v as Dictionary).get("version")).strip_edges() != version:
				continue
			if not _vmp_downloadable(v):
				return host_err(HOST_ERR_NOT_SCANNED, 0,
						"version %s has not passed the host's malware scan" % version)
			return _host_file_result(_vmp_file(v))
		return host_err(HOST_ERR_VERSION_NOT_FOUND, 404, "version %s is not available" % version)

	# versions[] is newest first, so the first downloadable entry is current.
	for v in (versions as Array):
		if _vmp_downloadable(v):
			return _host_file_result(_vmp_file(v))
	return _host_no_file()


## A flat list ordered by group; the group's slug is the parent, so the filter has two levels.
func _vmp_list_categories() -> Dictionary:
	var res := await _hnet_get_json(HOST_VOSTOKMODS, VM_API_BASE + "/taxonomies", _VM_TTL_CATEGORIES_MS)
	if not res["ok"]:
		return res
	var rows: Variant = res["data"]
	if not (rows is Array):
		return _host_bad_response(HOST_VOSTOKMODS)
	var out := []
	for r in (rows as Array):
		if not (r is Dictionary):
			continue
		var rec: Dictionary = r
		# Pack-only taxonomies match no mod; a row without the field is kept.
		var types: Variant = rec.get("contentTypes")
		if types is Array and not (types as Array).has("mod"):
			continue
		# The filter matches on slug, so the slug is the id.
		var slug := _host_str(rec.get("slug")).strip_edges()
		if slug.is_empty():
			continue
		out.append(host_category(slug, _host_str(rec.get("name")), _vmp_group_slug(rec.get("group"))))
	return host_ok(out)


## One detail request per mod: there is no batch endpoint.
func _vmp_latest_versions(ids: PackedStringArray) -> Dictionary:
	var versions := {}
	var failures := 0
	for slug in ids:
		var ref := host_ref(HOST_VOSTOKMODS, slug)
		# The 30-minute detail cache would miss a file uploaded since the launcher opened.
		var res := await _vmp_resolve_file(ref, "", _VM_TTL_FRESH_MS)
		if not res["ok"]:
			failures += 1
			if _host_batch_should_stop(str(res["code"])):
				return res if versions.is_empty() else host_ok(versions)
			continue
		var version := str((res["data"] as Dictionary)["version"])
		if version == "":
			continue
		versions[host_ref_key(ref)] = version
	# Learning nothing must not read as "everything is up to date".
	if versions.is_empty() and failures > 0:
		return host_err(HOST_ERR_BAD_RESPONSE, 0,
				"could not read a version for any of the %d mods checked" % failures)
	return host_ok(versions)


# Modpacks: summaries, listing and manifest links. Packs are a Vostok Mods feature, so
# hosted_modpacks.gd calls these directly, not via the seam.

## The Browse summary keys plus the pack's own, so one row factory draws mods and packs.
## `kind` keeps a pack ref, which shares the mod key space, out of the install map.
func _vmp_modpack_summary(v: Variant) -> Dictionary:
	var s := host_empty_summary()
	s.merge({"kind": "modpack", "slug": "", "mod_count": -1, "manifest_url": "", "page_url": ""})
	if not (v is Dictionary):
		return s
	var row: Dictionary = v
	var slug := _host_str(row.get("slug")).strip_edges()
	s["slug"] = slug
	if slug != "":
		s["ref"] = host_ref(HOST_VOSTOKMODS, slug)
	s["name"] = _host_str(row.get("name"))
	if s["name"] == "":
		s["name"] = slug
	s["short_description"] = _host_str(row.get("summary"))
	s["author_name"] = _host_str(row.get("ownerDisplayName"))
	s["mod_count"] = _host_count(row.get("modCount"))
	s["downloads"] = _host_count(row.get("downloadsCount"))
	s["views"] = _host_count(row.get("viewsCount"))
	s["category_name"] = _vmp_primary_category(row.get("taxonomies"))
	var cover := _https_url(_host_str(row.get("thumbnailUrl")))
	s["thumbnail"] = host_image(cover, _url_thumb_key(cover))
	s["manifest_url"] = _host_str(row.get("manifestUrl"))
	if s["manifest_url"] == "" and slug != "":
		s["manifest_url"] = _vmp_manifest_url_for_slug(slug)
	s["page_url"] = _host_str(row.get("url"))
	if s["page_url"] == "" and slug != "":
		s["page_url"] = VM_SITE_BASE + "/modpack/" + slug.uri_encode()
	s["published_at"] = _host_str(row.get("createdAt"))
	s["updated_at"] = _host_str(row.get("updatedAt"))
	return s


## q keys: query, sort (a _VM_PACK_SORTS key), cursor (page number as text).
func _vmp_list_modpacks(q: Dictionary) -> Dictionary:
	var params := {"page": maxi(1, str(q.get("cursor", "")).to_int()), "limit": _VM_MODPACK_PAGE_SIZE}
	var query := str(q.get("query", "")).strip_edges()
	if query != "":
		params["q"] = query.substr(0, _VM_QUERY_MAX_LEN)
	var sort_key := str(q.get("sort", ""))
	for opt: Dictionary in _VM_PACK_SORTS:
		if opt["key"] == sort_key:
			params["sort"] = sort_key
	var res := await _hnet_get_json(HOST_VOSTOKMODS, VM_API_BASE + "/modpacks" + _hnet_query(params), _VM_TTL_LIST_MS)
	if not res["ok"]:
		return res
	return _vmp_modpack_page(res["data"])


## A body without `entries` is an error: as an empty page it would say nobody published a pack.
func _vmp_modpack_page(body: Variant) -> Dictionary:
	var raw_rows: Variant = _vmp_rows(body)
	if raw_rows == null:
		return _host_bad_response(HOST_VOSTOKMODS)
	var rows := []
	for row in (raw_rows as Array):
		var s := _vmp_modpack_summary(row)
		if str(s["slug"]) != "":
			rows.append(s)
	return host_ok(_vmp_page(body as Dictionary, rows))


## The pack page's record: the summary keys plus banner and description (BBCode). The mod
## list is the manifest's (_vmp_modpack_mods).
func _vmp_modpack_detail(slug: String) -> Dictionary:
	if slug.is_empty() or not _vmp_valid_slug(slug):
		return host_err(HOST_ERR_NOT_FOUND, 0, "no modpack slug")
	var res := await _hnet_get_json(HOST_VOSTOKMODS, VM_API_BASE + "/modpacks/" + slug.uri_encode(),
			_VM_TTL_DETAIL_MS)
	if not res["ok"]:
		return res
	var body: Variant = res["data"]
	if not (body is Dictionary and _host_str((body as Dictionary).get("slug")).strip_edges() != ""):
		_vmp_log_unknown("pack detail", body)
		return _host_bad_response(HOST_VOSTOKMODS)
	var row: Dictionary = body
	var detail := _vmp_modpack_summary(row)
	detail["banner"] = host_image(_https_url(str(_vmp_banner(row)["url"])), "")
	var desc: Variant = row.get("description")
	if desc != null and not (desc is String):
		_vmp_log_unknown("pack description", desc)
	detail["description"] = _markdown_to_bbcode(desc) if desc is String else ""
	return host_ok(detail)


func _vmp_log_unknown(what: String, v: Variant) -> void:
	if _vmp_unknown_logged.has(what):
		return
	_vmp_unknown_logged[what] = true
	var shape: Variant = (v as Dictionary).keys() if v is Dictionary else type_string(typeof(v))
	_log_warning("[Host] Vostok Mods %s has an unknown shape: %s" % [what, str(shape).left(40)])


## A manifest's mods as display rows {name, slug, version, available, reason, page_url},
## in loadOrder.
func _vmp_modpack_mods(manifest: Dictionary) -> Array:
	var mods: Variant = manifest.get("mods")
	if not (mods is Array):
		return []
	var ordered := []
	for m_v in (mods as Array):
		if not (m_v is Dictionary):
			continue
		var m: Dictionary = m_v
		var slug := _host_str(m.get("slug")).strip_edges()
		if slug.is_empty():
			continue
		var page := _vmp_site_url(_host_str(m.get("pageUrl")))
		var name := _host_str(m.get("name")).strip_edges()
		var load_order := _host_count(m.get("loadOrder"))
		ordered.append([load_order if load_order > 0 else ordered.size() + 1, ordered.size(), {
			"name": name if name != "" else slug,
			"slug": slug,
			"version": _host_str(m.get("version")).strip_edges(),
			"available": _json_truthy(m.get("available", true)),
			"reason": _host_str(m.get("reason")).strip_edges(),
			"page_url": page if page != "" else _vmp_mod_page_url(slug),
		}])
	ordered.sort_custom(func(a: Array, b: Array) -> bool: return a[0] < b[0] or (a[0] == b[0] and a[1] < b[1]))
	var rows := []
	for o in ordered:
		rows.append(o[2])
	return rows


## The manifest URL for a pasted manifest link, pack page (with or without scheme) or bare
## slug; "" for anything not on vostokmods.net, so a link never picks the host fetched from.
func _vmp_modpack_manifest_url(text: String) -> String:
	var t := text.strip_edges()
	if t.is_empty():
		return ""
	var lower := t.to_lower()
	var rest := ""
	if lower.begins_with("https://") or lower.begins_with("http://"):
		rest = t.substr(t.find("//") + 2)
	elif lower.begins_with("vostokmods.net") or lower.begins_with("www.vostokmods.net"):
		rest = t
	else:
		return _vmp_manifest_url_for_slug(lower) if _vmp_valid_slug(lower) else ""
	if not _vmp_is_site_host(rest):
		return ""
	var slash := rest.find("/")
	var path := "" if slash < 0 else rest.substr(slash)
	var parts := path.get_slice("?", 0).get_slice("#", 0).split("/", false)
	# /api/modpacks/<slug>/manifest  or  /modpack/<slug>
	var slug := ""
	if parts.size() == 4 and parts[0] == "api" and parts[1] == "modpacks" and parts[3] == "manifest":
		slug = parts[2]
	elif parts.size() == 2 and (parts[0] == "modpack" or parts[0] == "modpacks"):
		slug = parts[1]
	slug = slug.uri_decode().strip_edges().to_lower()
	if slug.is_empty() or not _vmp_valid_slug(slug):
		return ""
	return _vmp_manifest_url_for_slug(slug)


## Lowercase letters, digits and hyphens, as the site mints pack slugs.
func _vmp_valid_slug(s: String) -> bool:
	for ch in s:
		if not ((ch >= "a" and ch <= "z") or (ch >= "0" and ch <= "9") or ch == "-"):
			return false
	return true


func _vmp_manifest_url_for_slug(slug: String) -> String:
	return VM_API_BASE + "/modpacks/" + slug.uri_encode() + "/manifest"


## "" when the manifest is usable, else a one-line reason.
func _vmp_validate_manifest(m: Variant) -> String:
	if not (m is Dictionary):
		return "the manifest is not a JSON object"
	var d: Dictionary = m
	var format := _host_count(d.get("format"))
	if format > VM_MODPACK_FORMAT:
		return "this modpack was made for a newer version of the mod loader -- update the mod loader and try again"
	if format < 1:
		return "the manifest has no format number"
	if _host_str(d.get("slug")).strip_edges().is_empty():
		return "the manifest has no slug"
	if not (d.get("mods") is Array):
		return "the manifest has no mod list"
	return ""


## Not cached: the site caps its own cache at 60s and a refresh has to show the current list.
func _vmp_fetch_modpack_manifest(url: String) -> Dictionary:
	if not url.begins_with(VM_API_BASE + "/modpacks/"):
		return host_err(HOST_ERR_NOT_FOUND, 0, "not a Vostok Mods modpack link")
	var res := await _hnet_get_json(HOST_VOSTOKMODS, url, 0)
	if not res["ok"]:
		return res
	var why := _vmp_validate_manifest(res["data"])
	if why != "":
		return host_err(HOST_ERR_BAD_RESPONSE, 0, why)
	# The pack file is named after the manifest's slug, so another pack's would replace that one.
	var asked := url.trim_prefix(VM_API_BASE + "/modpacks/").get_slice("/", 0).uri_decode().to_lower()
	var got := _host_str((res["data"] as Dictionary).get("slug")).strip_edges()
	if got.to_lower() != asked:
		return host_err(HOST_ERR_BAD_RESPONSE, 0, "the link asked for pack %s but got pack %s" % [asked, got])
	var manifest: Dictionary = (res["data"] as Dictionary).duplicate()
	manifest["manifest_url"] = url
	return host_ok(manifest)
