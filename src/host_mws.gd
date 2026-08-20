## ----- host_mws.gd -----
## ModWorkshop adapter: reference implementation of the host seam. Wraps the
## mws_api.gd client and normalizes its payloads into host_types.gd records;
## the client moves in here (and mws_api.gd is deleted) once every caller has
## migrated off the mws_* names, so keep the wrap thin. Endpoint behavior is
## documented in mws_api.gd.

func _mwsp_caps() -> Dictionary:
	var caps := host_empty_caps()
	caps["browse"] = true
	caps["search"] = true
	caps["categories"] = true
	caps["file_history"] = true
	caps["version_pin"] = true
	caps["page_url"] = true
	caps["total_count"] = true
	# The API ignores `sort` when `query` is non-empty; Browse re-sorts
	# search results client-side.
	caps["sort_ignored_with_query"] = true
	caps["metrics"] = PackedStringArray(["downloads", "likes", "views"])
	return caps


func _mwsp_scalars() -> Dictionary:
	var s := host_empty_scalars()
	# Menu order. "Featured" is not a sort; it is the curated landing below.
	s["sorts"] = [
		{"key": "bumped_at", "label": "Recently updated"},
		{"key": "downloads", "label": "Most downloaded"},
		{"key": "likes", "label": "Most liked"},
		{"key": "views", "label": "Most viewed"},
		{"key": "published_at", "label": "Newest"},
	]
	# The popular-and-latest route is dead upstream (see mws_api.gd), so the
	# landing is two ordinary list queries.
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


## Laravel dialect: 429 + Retry-After in seconds, X-RateLimit-Remaining on
## every response. Only reached once MWS traffic moves onto the shared
## transport; until then the wrapped client arms its own cooldown, which is
## what _mwsp_failure() reads.
func _mwsp_note_rate_headers(status: int, headers: PackedStringArray) -> void:
	_mws_note_rate_headers(status, headers)
	var wait_s := _hnet_header_value(headers, "Retry-After").to_int()
	if status == 429:
		# An absent or HTTP-date Retry-After gives wait_s == 0; pass 0 through
		# so host_arm_cooldown applies its 60s default. Clamping 0 up to 1
		# would arm a 1s cooldown the transport waits out and retries into.
		host_arm_cooldown(HOST_MODWORKSHOP, clampi(wait_s, 1, 900) * 1000 if wait_s > 0 else 0)
		return
	var remaining := _hnet_header_value(headers, "X-RateLimit-Remaining")
	# A 2xx with 0 remaining was the last request this window allows; success
	# responses do not say when the window resets, so assume a full minute.
	if remaining.is_valid_int() and remaining.to_int() <= 0:
		host_arm_cooldown(HOST_MODWORKSHOP, 0)


## Turn the wrapped client's null-on-failure into a code; the client keeps
## just enough state to tell the three cases apart.
func _mwsp_failure() -> Dictionary:
	var cooldown := mws_rate_cooldown_seconds()
	if cooldown > 0:
		return host_err(HOST_ERR_RATE_LIMITED, 429, "rate limited", cooldown)
	if _mws_last_transport_failed:
		return host_err(HOST_ERR_OFFLINE, 0, "could not reach ModWorkshop")
	return host_err(HOST_ERR_BAD_RESPONSE, 0, "ModWorkshop sent an unexpected response")


# ----- normalizers -----

## MWS Image record ({file, has_thumb}) -> ImageRef. `file` is an opaque
## storage filename that never changes for a given image, so it doubles as
## the disk cache key.
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
	# _host_str, not str: a null download_url must read as "" so
	# _mwsp_file_result returns HOST_ERR_NO_FILE.
	f["download_url"] = _host_str(rec.get("download_url"))
	f["size"] = _host_count(rec.get("size"))
	f["created_at"] = str(rec.get("created_at", ""))
	f["filename_hint"] = _mwsp_filename_hint(f["download_url"])
	return f


## Storage links carry the real filename in a ?filename= parameter.
func _mwsp_filename_hint(download_url: String) -> String:
	var q := download_url.find("?filename=")
	if q < 0:
		return ""
	return download_url.substr(q + 10).uri_decode().get_file()


# ----- operations -----

func _mwsp_list_mods(q: Dictionary) -> Dictionary:
	# MWS pages by number; the seam speaks cursors, so convert here.
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
		# A row without a resolvable id cannot be opened or downloaded; drop it.
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
			# The client collapses offline, rate-limited and 5xx into the same
			# null a real 404 produces; ask it which happened before reporting
			# "that version is gone" for what may be a dropped connection.
			if _mws_last_transport_failed or mws_rate_cooldown_seconds() > 0:
				return _mwsp_failure()
			# Genuinely absent: the author deleted the upload or never made it.
			return host_err(HOST_ERR_VERSION_NOT_FOUND, 404,
					"version %s is not available" % version)
		return _mwsp_file_result(pinned)

	# Author-pinned default first; /files/latest can return an older file
	# (see mws_api.gd), so it is only the fallback.
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
		# parent_id is null for top-level nodes; "" is the seam's sentinel.
		var parent: Variant = rec.get("parent_id")
		var parent_id := "" if parent == null else _host_id_str(parent)
		out.append(host_category(id, str(rec.get("name", "")), parent_id))
	return host_ok(out)


## One request per mod: there is no batch endpoint. Results stream so a rate
## limit part-way through still leaves the answers already collected.
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
			# loop; stop rather than spend the rest of the list on certain
			# failures.
			var code := str(res["code"])
			if code == HOST_ERR_RATE_LIMITED or code == HOST_ERR_OFFLINE:
				# Nothing resolved: report the failure, not an empty success
				# the Updates tab would render as "everything is up to date".
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
	# Every mod failed for its own reason (all 404, all malformed); learning
	# nothing must not read as "checked everything, nothing to update".
	if versions.is_empty() and failures > 0:
		return host_err(HOST_ERR_BAD_RESPONSE, 0,
				"could not read a version for any of the %d mods checked" % failures)
	return host_ok(versions)
