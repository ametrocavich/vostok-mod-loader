## ----- host_mws.gd -----
## ModWorkshop adapter: the reference implementation of the host seam.
##
## For now these functions wrap the existing mws_api.gd client and normalize
## its payloads into the records in host_types.gd. The client itself moves in
## here once every caller has been migrated off the mws_* names, at which
## point mws_api.gd is deleted; keeping the wrap thin is what makes that a
## deletion rather than a rewrite.
##
## Endpoint behavior is documented in mws_api.gd. What lives here is only the
## translation: MWS vocabulary in, seam vocabulary out.

func _mwsp_caps() -> Dictionary:
	var caps := host_empty_caps()
	caps["browse"] = true
	caps["search"] = true
	caps["categories"] = true
	caps["file_history"] = true
	caps["version_pin"] = true
	caps["page_url"] = true
	caps["total_count"] = true
	# The API ignores `sort` whenever `query` is non-empty, so the Browse tab
	# re-sorts search results client-side to honor the chosen order.
	caps["sort_ignored_with_query"] = true
	caps["metrics"] = PackedStringArray(["downloads", "likes", "views"])
	return caps


func _mwsp_scalars() -> Dictionary:
	var s := host_empty_scalars()
	# Menu order, and the single definition of it. "Featured" is deliberately
	# absent: it is not a sort but the curated landing below.
	s["sorts"] = [
		{"key": "bumped_at", "label": "Recently updated"},
		{"key": "downloads", "label": "Most downloaded"},
		{"key": "likes", "label": "Most liked"},
		{"key": "views", "label": "Most viewed"},
		{"key": "published_at", "label": "Newest"},
	]
	# The dedicated popular-and-latest route is dead upstream (see the note in
	# mws_api.gd), so the landing is two ordinary list queries composed here.
	s["landing_sections"] = [
		{"key": "popular", "title": "Popular this week", "sort_key": "weekly_score", "limit": 10},
		{"key": "latest", "title": "Latest", "sort_key": "bumped_at", "limit": 10},
	]
	s["query_max_len"] = MWS_QUERY_MAX_LEN
	s["page_size"] = MWS_PAGE_LIMIT
	# /mods/{id} one at a time; there is no batch version endpoint.
	s["version_batch_size"] = 1
	return s


func _mwsp_mod_page_url(id: String) -> String:
	if id.is_empty():
		return ""
	return MODWORKSHOP_PAGE_URL_TEMPLATE % id


## Rate-limit dialect: Laravel answers a spent budget with 429 + Retry-After
## in seconds, and stamps X-RateLimit-Remaining on every response.
##
## Only reached once MWS traffic moves onto the shared transport. Until then
## the wrapped client arms its own cooldown, which is what
## _mwsp_failure() reads.
func _mwsp_note_rate_headers(status: int, headers: PackedStringArray) -> void:
	_mws_note_rate_headers(status, headers)
	var wait_s := _hnet_header_value(headers, "Retry-After").to_int()
	if status == 429:
		host_arm_cooldown(HOST_MODWORKSHOP, clampi(wait_s, 1, 900) * 1000)
		return
	var remaining := _hnet_header_value(headers, "X-RateLimit-Remaining")
	# A 2xx with nothing left succeeded, but it was the last request this
	# window allows. Success responses do not say when the window resets, so
	# assume a full minute rather than spend the next request on a certain 429.
	if remaining.is_valid_int() and remaining.to_int() <= 0:
		host_arm_cooldown(HOST_MODWORKSHOP, 0)


## Turn the wrapped client's "null means something went wrong" into a code.
## The client keeps just enough state to tell the three cases apart, and this
## is the only place that knowledge is needed.
func _mwsp_failure() -> Dictionary:
	var cooldown := mws_rate_cooldown_seconds()
	if cooldown > 0:
		return host_err(HOST_ERR_RATE_LIMITED, 429, "rate limited", cooldown)
	if _mws_last_transport_failed:
		return host_err(HOST_ERR_OFFLINE, 0, "could not reach ModWorkshop")
	return host_err(HOST_ERR_BAD_RESPONSE, 0, "ModWorkshop sent an unexpected response")


# ----- normalizers -----

## MWS Image record ({file, has_thumb}) -> ImageRef.
##
## `file` is an opaque storage filename that never changes for a given image,
## which is exactly the immutability the disk thumbnail cache needs, so it
## doubles as the cache key.
func _mwsp_image(v: Variant) -> Dictionary:
	if not (v is Dictionary):
		return host_image("", "", "")
	var rec: Dictionary = v
	var fn := str(rec.get("file", ""))
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
	s["name"] = str(row.get("name", ""))
	if s["name"] == "":
		s["name"] = id
	var user: Variant = row.get("user")
	if user is Dictionary:
		s["author_name"] = str((user as Dictionary).get("name", ""))
	var category: Variant = row.get("category")
	if category is Dictionary:
		s["category_name"] = str((category as Dictionary).get("name", ""))
	s["version"] = str(row.get("version", "")).strip_edges()
	s["downloads"] = _host_count(row.get("downloads"))
	s["likes"] = _host_count(row.get("likes"))
	s["views"] = _host_count(row.get("views"))
	s["updated_at"] = str(row.get("bumped_at", ""))
	s["published_at"] = str(row.get("published_at", ""))
	s["short_description"] = str(row.get("short_desc", ""))
	s["thumbnail"] = _mwsp_image(row.get("thumbnail"))
	return s


func _mwsp_file(v: Variant) -> Dictionary:
	var f := host_empty_file()
	if not (v is Dictionary):
		return f
	var rec: Dictionary = v
	f["id"] = _host_id_str(rec.get("id", ""))
	f["version"] = str(rec.get("version", "")).strip_edges()
	f["download_url"] = str(rec.get("download_url", ""))
	f["size"] = _host_count(rec.get("size"))
	f["created_at"] = str(rec.get("created_at", ""))
	f["filename_hint"] = _mwsp_filename_hint(f["download_url"])
	return f


## Storage links carry the real filename in a ?filename= parameter. Reading it
## here means the install tail takes a hint field and parses no URLs.
func _mwsp_filename_hint(download_url: String) -> String:
	var q := download_url.find("?filename=")
	if q < 0:
		return ""
	return download_url.substr(q + 10).uri_decode().get_file()


# ----- operations -----

func _mwsp_list_mods(q: Dictionary) -> Dictionary:
	# MWS pages by number; the seam speaks cursors, so the page number is
	# carried as a cursor string and converted back here.
	var page := maxi(1, str(q.get("cursor", "")).to_int())
	var raw: Variant = await mws_list_mods(
		str(q.get("query", "")),
		str(q.get("sort_key", "bumped_at")),
		str(q.get("category_ref", "")).to_int(),
		page)
	if not (raw is Dictionary):
		return _mwsp_failure()

	var rows := []
	for row in _mws_data_rows(raw):
		var summary := _mwsp_summary(row)
		# A row without a resolvable id cannot be opened, downloaded or
		# tracked, so it is dropped rather than rendered as a dead entry.
		if host_ref_valid(summary["ref"]):
			rows.append(summary)

	var meta_v: Variant = (raw as Dictionary).get("meta")
	var meta: Dictionary = meta_v if meta_v is Dictionary else {}
	var last_page := _host_count(meta.get("last_page"))
	var has_more := last_page > page
	var next_cursor := str(page + 1) if has_more else ""
	return host_ok(host_page(rows, has_more, next_cursor, _host_count(meta.get("total"))))


func _mwsp_get_mod(ref: Dictionary) -> Dictionary:
	var raw: Variant = await mws_get_mod(str(ref["id"]).to_int())
	if not (raw is Dictionary):
		return _mwsp_failure()
	# /mods/{id} returns the object directly, but callers also feed listing
	# rows through here, so unwrap a {data} envelope when one is present.
	var row: Dictionary = raw
	var inner: Variant = row.get("data")
	if inner is Dictionary:
		row = inner

	var detail := host_empty_detail()
	detail.merge(_mwsp_summary(row), true)
	detail["banner"] = _mwsp_image(row.get("banner"))
	detail["description"] = _markdown_to_bbcode(str(row.get("desc", row.get("short_desc", ""))))
	return host_ok(detail)


func _mwsp_list_files(ref: Dictionary) -> Dictionary:
	var raw: Variant = await mws_list_files(str(ref["id"]).to_int())
	if not (raw is Dictionary):
		return _mwsp_failure()
	var files := []
	for row in _mws_data_rows(raw):
		var f := _mwsp_file(row)
		if str(f["download_url"]) != "":
			files.append(f)
	return host_ok(files)


func _mwsp_resolve_file(ref: Dictionary, version: String) -> Dictionary:
	var mod_id := str(ref["id"]).to_int()

	if version != "":
		var pinned: Variant = await mws_get_file_by_version(mod_id, version)
		if not (pinned is Dictionary):
			# The wrapped client collapses offline, rate-limited and 5xx into
			# the same null a genuine 404 produces, so ask it which happened
			# first. Reporting "that version is gone" for what is really a
			# dropped connection pushes the user into installing a DIFFERENT
			# version -- the exact substitution pinning exists to prevent.
			if _mws_last_transport_failed or mws_rate_cooldown_seconds() > 0:
				return _mwsp_failure()
			# Genuinely absent: the author deleted that upload or never made it.
			return host_err(HOST_ERR_VERSION_NOT_FOUND, 404,
					"version %s is not available" % version)
		return _mwsp_file_result(pinned)

	# Author-pinned default first. /files/latest sorts by an author-controlled
	# display_order and can return an OLDER file, so it is the fallback for
	# mods whose author never designated a primary, not the first choice.
	var primary: Variant = await mws_get_primary_file(mod_id)
	if primary is Dictionary:
		return _mwsp_file_result(primary)
	var latest: Variant = await mws_get_latest_file(mod_id)
	if latest is Dictionary:
		return _mwsp_file_result(latest)
	if _mws_last_transport_failed or mws_rate_cooldown_seconds() > 0:
		return _mwsp_failure()
	return host_err(HOST_ERR_NO_FILE, 404, "that mod has no downloadable file")


func _mwsp_file_result(raw: Variant) -> Dictionary:
	var f := _mwsp_file(raw)
	if str(f["download_url"]) == "":
		return host_err(HOST_ERR_NO_FILE, 0, "that mod has no downloadable file")
	return host_ok(f)


func _mwsp_list_categories() -> Dictionary:
	var raw: Variant = await mws_get_categories()
	if not (raw is Dictionary):
		return _mwsp_failure()
	var out := []
	for row in _mws_data_rows(raw):
		if not (row is Dictionary):
			continue
		var rec: Dictionary = row
		var id := _host_id_str(rec.get("id", ""))
		if id.is_empty():
			continue
		# parent_id arrives as null for top-level nodes, which _host_id_str
		# renders as "" -- the seam's own "no parent" sentinel.
		var parent: Variant = rec.get("parent_id")
		var parent_id := "" if parent == null else _host_id_str(parent)
		out.append(host_category(id, str(rec.get("name", "")), parent_id))
	return host_ok(out)


## One request per mod: there is no batch endpoint. Results are streamed so a
## rate limit part-way through still leaves the user with the answers already
## collected instead of nothing.
func _mwsp_latest_versions(ids: PackedStringArray, on_progress: Callable) -> Dictionary:
	var versions := {}
	var done := 0
	var failures := 0
	for id in ids:
		var ref := host_ref(HOST_MODWORKSHOP, id)
		var res := await _mwsp_resolve_file(ref, "")
		done += 1
		if not res["ok"]:
			failures += 1
			# Neither a rate limit nor a dead connection clears inside this
			# loop, so stop rather than spend the rest of the list on certain
			# failures -- offline, that is one doomed request per installed
			# mod, each with its own timeout and retry.
			var code := str(res["code"])
			if code == HOST_ERR_RATE_LIMITED or code == HOST_ERR_OFFLINE:
				# Nothing resolved at all: report the failure instead of an
				# empty success, which the Updates tab would render as the
				# far more damaging "everything is up to date".
				if versions.is_empty():
					return res
				return host_ok(versions)
			continue
		var file: Dictionary = res["data"]
		var version := str(file["version"])
		if version == "":
			continue
		var key := host_ref_key(ref)
		versions[key] = version
		if on_progress.is_valid():
			on_progress.call({"done": done, "total": ids.size(), "partial": {key: version}})
	# Every single mod failed for its own reason (all 404, all malformed).
	# An empty success here means "checked everything, nothing to update",
	# which is the one answer the user must not be given when in truth we
	# learned nothing at all.
	if versions.is_empty() and failures > 0:
		return host_err(HOST_ERR_BAD_RESPONSE, 0,
				"could not read a version for any of the %d mods checked" % failures)
	return host_ok(versions)
