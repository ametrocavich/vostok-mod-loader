## ----- mws_api.gd -----
## ModWorkshop API client: thin async wrappers over HTTPRequest. Callers
## await a parsed Variant (Dictionary or Array) or null on any failure
## (network, HTTP error, malformed JSON) and decide how to surface it.
##
## Endpoints documented at github.com/ModWorkshop/site
## (backend/routes/api.php). Rate budget: 90 req/min/IP unauthenticated;
## x-ratelimit-remaining on every response. Envelope shape (data vs
## popular/latest vs bare object) varies by endpoint, so unwrapping is the
## caller's job.
##
## Every request carries a User-Agent: api.modworkshop.net answers an empty
## or default UA with a bodyless 403.
##
## GETs opt into a per-URL in-memory TTL cache (_MWS_TTL_* below); rate-limit
## backoff is the _MWS_COOLDOWN_* block below. The discover landing also
## write-throughs its last full payload to
## user://mws_cache/discover_snapshot.json for offline grace; filter/search
## responses are never snapshotted.

# Identical for every endpoint; one place to inject future auth.
func _mws_default_headers() -> PackedStringArray:
	return PackedStringArray([
		"User-Agent: " + (MWS_USER_AGENT_TEMPLATE % MODLOADER_VERSION),
		"Accept: application/json",
	])

# In-memory response cache. Failed requests never write, so a 5xx flake
# cannot poison an entry; the next call retries the network.
func _mws_cache_get(url: String) -> Variant:
	if not _mws_cache.has(url):
		return null
	var entry: Dictionary = _mws_cache[url]
	if Time.get_ticks_msec() > int(entry.get("expires_at", 0)):
		_mws_cache.erase(url)
		return null
	return entry.get("data")

func _mws_cache_put(url: String, data: Variant, ttl_ms: int) -> void:
	_mws_cache[url] = {
		"data": data,
		"expires_at": Time.get_ticks_msec() + ttl_ms,
	}

# Async JSON GET: parsed Variant on 2xx with a non-empty body, else null.
# cache_ttl_ms > 0 reads/writes the in-memory cache; 0 bypasses it.
func _mws_get_json(url: String, cache_ttl_ms: int = 0, allow_rate_wait: bool = true, allow_transport_retry: bool = true) -> Variant:
	_mws_last_transport_failed = false
	if cache_ttl_ms > 0:
		var cached: Variant = _mws_cache_get(url)
		if cached != null:
			return cached

	# Cooldown gate: fail fast to null while closed; only a cooldown in its
	# final moments is waited out so a boundary click succeeds.
	var cooldown_ms := _mws_rate_cooldown_ms()
	if cooldown_ms > 0:
		if not allow_rate_wait or cooldown_ms > _MWS_RATE_WAIT_MAX_MS:
			return null
		if get_tree() == null:
			return null
		await get_tree().create_timer(float(cooldown_ms + 100) / 1000.0).timeout
		# Another in-flight request may have 429d and pushed the cooldown out
		# during the wait; re-check rather than fire into it.
		if _mws_rate_cooldown_ms() > 0:
			return null

	var req := HTTPRequest.new()
	req.timeout = API_CHECK_TIMEOUT
	# List responses run ~100KB at limit=50; cap the buffer so a misbehaving
	# 2xx stream cannot grow unbounded.
	req.download_body_size_limit = MWS_JSON_BODY_LIMIT
	add_child(req)

	var err := req.request(url, _mws_default_headers(), HTTPClient.METHOD_GET)
	if err != OK:
		req.queue_free()
		return null

	# request_completed -> [result, http_code, headers, body]
	var res: Array = await req.request_completed
	req.queue_free()

	if res[0] != HTTPRequest.RESULT_SUCCESS:
		# No HTTP response at all -- offline / DNS / timeout.
		if allow_transport_retry and get_tree() != null:
			# One retry (cold DNS/TLS often fails the first post-launch
			# request); the retry passes false so it cannot loop.
			await get_tree().create_timer(1.0).timeout
			return await _mws_get_json(url, cache_ttl_ms, allow_rate_wait, false)
		# Flag so download callers can distinguish this from a 404.
		_mws_last_transport_failed = true
		return null
	var status: int = res[1]
	_mws_note_rate_headers(status, res[2])
	if status == 429 and allow_rate_wait and _mws_rate_cooldown_ms() <= _MWS_RATE_WAIT_MAX_MS:
		# One retry for the action that tripped the limit, only when the wait
		# is short; allow_rate_wait=false so a second 429 cannot loop.
		if get_tree() == null:
			return null
		await get_tree().create_timer(float(_mws_rate_cooldown_ms() + 100) / 1000.0).timeout
		return await _mws_get_json(url, cache_ttl_ms, false)
	if status < 200 or status >= 300:
		return null
	var body: PackedByteArray = res[3]
	if body.is_empty():
		return null
	var parsed: Variant = JSON.parse_string(body.get_string_from_utf8())
	if cache_ttl_ms > 0 and parsed != null:
		_mws_cache_put(url, parsed, cache_ttl_ms)
	return parsed

# Cache TTLs: listings go stale fast, detail and history rarely, categories
# barely. Primary-file TTL is short so a stale download_url does not outlive
# a CDN rotation.
const _MWS_TTL_LIST_MS  := 5 * 60 * 1000
const _MWS_TTL_DETAIL_MS := 30 * 60 * 1000
const _MWS_TTL_CATEGORIES_MS := 60 * 60 * 1000
const _MWS_TTL_PRIMARY_MS := 60 * 1000

# A 429, or a 2xx whose Remaining hit 0, arms _mws_cooldown_until_ms
# (declared in constants.gd). While armed, fresh network calls fail fast to
# null; the response cache still serves. A cooldown about to expire
# (<= _MWS_RATE_WAIT_MAX_MS) is waited out inside the call.
const _MWS_COOLDOWN_DEFAULT_MS := 60 * 1000
const _MWS_RATE_WAIT_MAX_MS := 2000

# Milliseconds left on the rate-limit cooldown; 0 when requests may go out.
func _mws_rate_cooldown_ms() -> int:
	return maxi(0, _mws_cooldown_until_ms - Time.get_ticks_msec())

# Whole seconds left, rounded up; public for the Browse banner copy.
func mws_rate_cooldown_seconds() -> int:
	return ceili(_mws_rate_cooldown_ms() / 1000.0)

# "" when no cooldown is active, so callers fall back to their own copy.
func mws_rate_limit_message() -> String:
	var ms := _mws_rate_cooldown_ms()
	if ms <= 0:
		return ""
	return "ModWorkshop rate limit reached. Try again in %ds." % ceili(ms / 1000.0)

# Rate-limit status when one is active, else the caller's own copy.
func mws_error_status(fallback: String) -> String:
	var msg := mws_rate_limit_message()
	return msg if msg != "" else fallback

# Case-insensitive response-header lookup. Returns "" when absent.
func _mws_header_value(headers: PackedStringArray, header_name: String) -> String:
	var prefix := header_name.to_lower() + ":"
	for h in headers:
		if h.to_lower().begins_with(prefix):
			return h.substr(prefix.length()).strip_edges()
	return ""

# Arm the cooldown off response headers. Retry-After is seconds from
# Laravel (an HTTP-date would to_int() to 0 -> default window, safe). A 2xx
# with Remaining: 0 was the window's last request; success responses do not
# say when the window resets, so assume the full minute.
func _mws_note_rate_headers(status: int, headers: PackedStringArray) -> void:
	var wait_ms := 0
	if status == 429:
		var retry_s := _mws_header_value(headers, "Retry-After").to_int()
		wait_ms = (clampi(retry_s, 1, 900) * 1000) if retry_s > 0 else _MWS_COOLDOWN_DEFAULT_MS
	else:
		var remaining := _mws_header_value(headers, "X-RateLimit-Remaining")
		if remaining.is_valid_int() and remaining.to_int() <= 0:
			wait_ms = _MWS_COOLDOWN_DEFAULT_MS
	if wait_ms > 0:
		_mws_cooldown_until_ms = maxi(_mws_cooldown_until_ms, Time.get_ticks_msec() + wait_ms)

# Offline-grace snapshot of the discover landing: one slot holding the last
# fully-populated popular-and-latest payload plus its unix time. Lives under
# user://mws_cache/, which is on modpacks.gd's MODPACK_OVERRIDE_DENY_PREFIXES
# list so packs cannot poison it.
const _MWS_DISCOVER_SNAPSHOT_PATH := "user://mws_cache/discover_snapshot.json"

func _mws_discover_snapshot_store(data: Dictionary) -> void:
	_mws_discover_snapshot = {
		"data": data,
		"saved_at_unix": int(Time.get_unix_time_from_system()),
	}
	# Best-effort: a failed write means the grace window is memory-only.
	DirAccess.make_dir_recursive_absolute(_MWS_DISCOVER_SNAPSHOT_PATH.get_base_dir())
	# Write-then-rename so a crash mid-write cannot truncate the live snapshot.
	var tmp_path := _MWS_DISCOVER_SNAPSHOT_PATH + ".tmp"
	var f := FileAccess.open(tmp_path, FileAccess.WRITE)
	if f == null:
		return
	var wrote := f.store_string(JSON.stringify(_mws_discover_snapshot))
	var werr := f.get_error()
	f.close()
	if not wrote or werr != OK:
		DirAccess.remove_absolute(tmp_path)
		return
	DirAccess.rename_absolute(tmp_path, _MWS_DISCOVER_SNAPSHOT_PATH)

# Last-good discover payload {"data": {popular, latest}, "saved_at_unix"},
# or {} when none exists. Memory first, then one lazy disk load. Every field
# the render path touches is shape-checked so a truncated or hand-edited
# file degrades to {}, never a crash. saved_at_unix arrives as a float after
# a JSON round-trip -- callers int() it.
func mws_discover_snapshot() -> Dictionary:
	if not _mws_discover_snapshot.is_empty():
		return _mws_discover_snapshot
	if not FileAccess.file_exists(_MWS_DISCOVER_SNAPSHOT_PATH):
		return {}
	var f := FileAccess.open(_MWS_DISCOVER_SNAPSHOT_PATH, FileAccess.READ)
	if f == null:
		return {}
	var parsed: Variant = JSON.parse_string(f.get_as_text())
	f.close()
	if not (parsed is Dictionary):
		return {}
	var snap: Dictionary = parsed
	var data_v: Variant = snap.get("data")
	if not (data_v is Dictionary):
		return {}
	var data: Dictionary = data_v
	if not (data.get("popular") is Array) or not (data.get("latest") is Array):
		return {}
	# .get()'s default only covers an absent key; a present-but-null value
	# would crash int() (no int(Nil) constructor in Godot 4), so type-guard.
	# `is float` keeps the JSON round-trip valid.
	var saved_v: Variant = snap.get("saved_at_unix", 0)
	if not (saved_v is int or saved_v is float) or int(saved_v) <= 0:
		return {}
	_mws_discover_snapshot = snap
	return snap

# RTV landing for the Browse tab: {popular: [...], latest: [...]}, not
# wrapped in {data}. The /games/{id}/popular-and-latest route is dead
# upstream (commented out in routes/api.php; the handler returns `[]`), so
# compose it from two list queries -- weekly_score and bumped_at -- trimmed
# to 10 rows each.
func mws_get_popular_and_latest() -> Variant:
	var popular: Variant = await mws_list_mods("", "weekly_score", 0, 1)
	var latest: Variant = await mws_list_mods("", "bumped_at", 0, 1)
	# Re-issue only a failed leg, once; the healthy leg is kept as-is.
	if not (popular is Dictionary):
		popular = await mws_list_mods("", "weekly_score", 0, 1)
	if not (latest is Dictionary):
		latest = await mws_list_mods("", "bumped_at", 0, 1)
	# Either leg failing fails the fetch: the budget can expire between the
	# two sequential queries, and a half payload would render one section
	# silently empty and clear the offline banner. Null lets the Browse tab
	# fall back to the last complete snapshot.
	if not (popular is Dictionary) or not (latest is Dictionary):
		return null
	var pop_rows: Array = _mws_data_rows(popular).slice(0, 10)
	var lat_rows: Array = _mws_data_rows(latest).slice(0, 10)
	var out := {"popular": pop_rows, "latest": lat_rows}
	# Snapshot only a fully-populated landing: a half payload must not
	# clobber an older complete snapshot.
	if not pop_rows.is_empty() and not lat_rows.is_empty():
		# Restamp only on change: both legs can serve from cache with zero
		# network, and rewriting then would advance saved_at_unix and make
		# "Last refreshed X ago" under-report age.
		var prev: Variant = _mws_discover_snapshot.get("data") if not _mws_discover_snapshot.is_empty() else null
		if not (prev is Dictionary and prev == out):
			_mws_discover_snapshot_store(out)
	return out

# Pull the "data" array out of a list response; an `as Array` cast would
# crash on data:null or a non-array (error page served 2xx).
func _mws_data_rows(resp: Variant) -> Array:
	if not (resp is Dictionary):
		return []
	var d: Variant = (resp as Dictionary).get("data", [])
	return d if d is Array else []

# Search / sort / filter the RTV catalog -> {data: [ModSummary], meta}.
# Search param is `query` (max 150; `search`/`q`/`name` are silently
# ignored); "" means unfiltered. limit caps at 50 -- larger values 422.
# Sort enum: bumped_at (default), published_at, likes, downloads, views,
# score, weekly_score, daily_score, random, best_match, name.
func mws_list_mods(query: String = "", sort: String = "bumped_at", category_id: int = 0, page: int = 1) -> Variant:
	var params := PackedStringArray()
	if query != "":
		# Clamp rather than 422; an over-limit query reads as a connection error.
		params.append("query=" + query.substr(0, MWS_QUERY_MAX_LEN).uri_encode())
	params.append("sort=" + sort)
	params.append("limit=" + str(MWS_PAGE_LIMIT))
	params.append("page=" + str(page))
	if category_id > 0:
		params.append("category_id=" + str(category_id))
	var url := MWS_API_BASE + "/games/" + str(MWS_RTV_GAME_ID) + "/mods?" + "&".join(params)
	return await _mws_get_json(url, _MWS_TTL_LIST_MS)

# Category list -> {data: [Category], meta}. Tree-shaped via parent_id;
# top-level nodes have parent_id == null.
func mws_get_categories() -> Variant:
	return await _mws_get_json(MWS_API_BASE + "/games/" + str(MWS_RTV_GAME_ID) + "/categories", _MWS_TTL_CATEGORIES_MS)

# Author-pinned default download (display_order = 0); /files/latest sorts by
# author-controlled display_order and can return an older file than primary.
# Returns one File with download_url pointing directly at storage.modworkshop.net.
func mws_get_primary_file(mod_id: int) -> Variant:
	return await _mws_get_json(MWS_API_BASE + "/mods/" + str(mod_id) + "/files/primary", _MWS_TTL_PRIMARY_MS)

# File record for an exact version, for version-pinned modpack applies.
# Null when the version does not exist; callers surface that, never fall
# back to primary.
func mws_get_file_by_version(mod_id: int, version: String) -> Variant:
	if version.is_empty():
		return null
	return await _mws_get_json(MWS_API_BASE + "/mods/" + str(mod_id) + "/files/" + version.uri_encode(), _MWS_TTL_PRIMARY_MS)

# Latest file by the API's sort key (semver desc, display_order desc,
# updated_at desc; excludes prereleases). Fallback for when /files/primary
# returns null because no primary is designated.
func mws_get_latest_file(mod_id: int) -> Variant:
	return await _mws_get_json(MWS_API_BASE + "/mods/" + str(mod_id) + "/files/latest", _MWS_TTL_PRIMARY_MS)

# Full file history -> {data: [File], meta}; each File carries version,
# size, created_at and its own download_url.
func mws_list_files(mod_id: int) -> Variant:
	return await _mws_get_json(MWS_API_BASE + "/mods/" + str(mod_id) + "/files", _MWS_TTL_DETAIL_MS)

# Full mod detail (name, user, desc/short_desc, thumbnail + banner), or
# null. /mods/{id} returns the object directly; callers that also feed it
# listing rows unwrap a {data} envelope defensively.
func mws_get_mod(mod_id: int) -> Variant:
	return await _mws_get_json(MWS_API_BASE + "/mods/" + str(mod_id), _MWS_TTL_DETAIL_MS)

# Full URL for an Image record ({file, has_thumb}); prefers the smaller
# /thumbs/ variant when wanted and available. The URL convention's one home.
func mws_image_url(image_record: Dictionary, want_thumb: bool = false) -> String:
	var fn: String = str(image_record.get("file", ""))
	if fn.is_empty():
		return ""
	var has_thumb: bool = bool(image_record.get("has_thumb", false))
	if want_thumb and has_thumb:
		return MWS_STORAGE_BASE + "/mods/images/thumbs/" + fn
	return MWS_STORAGE_BASE + "/mods/images/" + fn
