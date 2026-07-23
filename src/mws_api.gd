## ----- mws_api.gd -----
## ModWorkshop API client. Thin async wrappers over HTTPRequest; callers await
## a parsed Variant (Dictionary or Array) or null on failure.
##
## All endpoints documented at github.com/ModWorkshop/site (backend/routes/api.php).
## Rate budget per RouteServiceProvider::configureRateLimiting: 90 req/min/IP
## unauthenticated; x-ratelimit-remaining surfaced on every response. Phase 1 of
## the Browse + download work: this module only adds NEW endpoints used by the
## Browse tab. The legacy fetch_latest_modworkshop_versions / download_and_replace_mod
## in mod_discovery.gd stay where they are until the dedicated migration phase.
##
## Conventions:
##   - Methods named mws_* are public; _mws_* are private helpers.
##   - Callers receive parsed JSON Variant directly. Envelope unwrap (data vs
##     popular/latest vs bare object) is the caller's job because the shape
##     varies by endpoint -- see github.com/ModWorkshop/site for which is which.
##   - All requests carry a User-Agent. api.modworkshop.net rejects empty/default
##     UAs with a bodyless 403, so the template is mandatory.
##   - All requests also carry Accept: application/json (see
##     _mws_default_headers). Error bodies are discarded (_mws_get_json
##     collapses non-2xx to null), so the header only matters if a caller
##     ever starts reading error responses.
##   - GETs opt into a per-URL in-memory TTL cache via _mws_get_json(url,
##     cache_ttl_ms); TTLs are the _MWS_TTL_* consts below. Failures are
##     never cached, so a flake retries the network on the next call.
##   - mws_list_mods requests limit=50 (MWS_PAGE_LIMIT); the API returns
##     422 for larger values, so page instead of raising the limit.
##   - Failures (network, HTTP error, malformed JSON) collapse to null. Callers
##     decide how to surface them -- usually a status label in the tab.
##   - 429-aware backoff: a 429 (or a spent X-RateLimit-Remaining budget)
##     arms a module-wide cooldown; calls during it fail fast to null and
##     callers wrap their error copy in mws_error_status() so the status
##     reads "rate limit reached, try again in Ns" instead of a generic
##     connection hint. See the _MWS_COOLDOWN_* block below.
##   - Offline grace: the discover landing write-throughs its last fully-
##     populated payload to memory + user://mws_cache/discover_snapshot.json
##     (_mws_discover_snapshot_store). When a live fetch fails, the Browse
##     tab reads mws_discover_snapshot() and renders it behind a cached-
##     results banner instead of an empty error state. Discover ONLY --
##     filter/search responses are never snapshotted.

# Build the request headers for any GET. Identical for every endpoint right now;
# split into a helper so future auth / rate-budget tracking has one place to
# inject behavior.
func _mws_default_headers() -> PackedStringArray:
	return PackedStringArray([
		"User-Agent: " + (MWS_USER_AGENT_TEMPLATE % MODLOADER_VERSION),
		"Accept: application/json",
	])

# In-memory response cache helpers. Read evicts expired entries lazily; write
# replaces any existing entry for the same URL. Failed requests don't write,
# so a 5xx flake won't poison the cache with a null result -- the next call
# retries the network.
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

# Async GET that parses JSON. Returns the parsed Variant on 2xx with a non-empty
# body, otherwise null. Caller awaits this -- it spawns its own HTTPRequest as a
# child of the modloader autoload, queue_frees on completion. Pass cache_ttl_ms
# > 0 to read/write the in-memory response cache; 0 bypasses caching entirely.
func _mws_get_json(url: String, cache_ttl_ms: int = 0, allow_rate_wait: bool = true, allow_transport_retry: bool = true) -> Variant:
	_mws_last_transport_failed = false
	if cache_ttl_ms > 0:
		var cached: Variant = _mws_cache_get(url)
		if cached != null:
			return cached

	# Rate-limit cooldown gate (see the _MWS_COOLDOWN_* block above). Fail
	# fast to null while the window is closed -- callers already treat null
	# as failure and can surface mws_rate_limit_message(). Only a cooldown
	# in its final moments is waited out here, so a user click right at the
	# boundary succeeds instead of failing by 100ms.
	var cooldown_ms := _mws_rate_cooldown_ms()
	if cooldown_ms > 0:
		if not allow_rate_wait or cooldown_ms > _MWS_RATE_WAIT_MAX_MS:
			return null
		if get_tree() == null:
			return null
		await get_tree().create_timer(float(cooldown_ms + 100) / 1000.0).timeout
		# Another in-flight request may have hit a 429 and pushed the cooldown
		# further out while we waited. Re-check instead of firing into a window
		# that just closed again -- that request would 429 and re-arm anyway.
		if _mws_rate_cooldown_ms() > 0:
			return null

	var req := HTTPRequest.new()
	req.timeout = API_CHECK_TIMEOUT
	# JSON list responses run ~100KB at limit=50. Cap the buffer so a captive
	# portal or a misbehaving proxy streaming a huge 2xx body can't grow
	# unbounded for the whole timeout window.
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
			# Single retry for a transient transport flake (cold DNS/TLS often
			# fails the very first request after launch). The retry passes
			# allow_transport_retry=false so it can never loop: a second
			# failure falls through to the flagged null below.
			await get_tree().create_timer(1.0).timeout
			return await _mws_get_json(url, cache_ttl_ms, allow_rate_wait, false)
		# Flag it so download callers can distinguish this from a 404 and show
		# connection copy.
		_mws_last_transport_failed = true
		return null
	var status: int = res[1]
	_mws_note_rate_headers(status, res[2])
	if status == 429 and allow_rate_wait and _mws_rate_cooldown_ms() <= _MWS_RATE_WAIT_MAX_MS:
		# Single retry for the user-initiated action that tripped the limit,
		# and only when the server-stated wait is short. The retry passes
		# allow_rate_wait=false so it can never loop: a second 429 falls
		# through the cooldown gate to a plain null.
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

# Cache TTLs (milliseconds). Tuned by browse pattern: list responses go stale
# quickly (new mods, bumped order changes) so 5 minutes; mod-detail and file
# history change rarely so 30 minutes; categories barely change so 1 hour.
# Primary-file fetches preceding a Get use a short TTL so a stale download_url
# doesn't outlive a CDN rotation.
const _MWS_TTL_LIST_MS  := 5 * 60 * 1000
const _MWS_TTL_DETAIL_MS := 30 * 60 * 1000
const _MWS_TTL_CATEGORIES_MS := 60 * 60 * 1000
const _MWS_TTL_PRIMARY_MS := 60 * 1000

# 429-aware backoff. The guest budget is 90 req/min/IP; Laravel's throttler
# answers 429 with Retry-After (seconds) once it's spent, and stamps
# X-RateLimit-Remaining on every response. On a 429 -- or a 2xx whose
# Remaining hit 0, i.e. the last request the window allows -- we arm
# _mws_cooldown_until_ms (declared in constants.gd next to _mws_cache).
# While armed, fresh network calls fail fast to null instead of hammering
# the API; the response cache still serves, and callers surface
# mws_rate_limit_message() / mws_error_status(). A cooldown about to expire
# (<= _MWS_RATE_WAIT_MAX_MS) is waited out inside the call so a click near
# the boundary still succeeds -- at most one wait + one retry, never a loop.
const _MWS_COOLDOWN_DEFAULT_MS := 60 * 1000
const _MWS_RATE_WAIT_MAX_MS := 2000

# Milliseconds left on the rate-limit cooldown; 0 when requests may go out.
func _mws_rate_cooldown_ms() -> int:
	return maxi(0, _mws_cooldown_until_ms - Time.get_ticks_msec())

# Whole seconds left on the rate-limit cooldown, rounded up; 0 when idle.
# Public so the Browse offline banner can render its "Try again in Ns"
# copy without duplicating the cooldown math.
func mws_rate_cooldown_seconds() -> int:
	return ceili(_mws_rate_cooldown_ms() / 1000.0)

# Friendly status for rate-limited failures. Empty string when no cooldown
# is active, so callers can fall back to their own error copy.
func mws_rate_limit_message() -> String:
	var ms := _mws_rate_cooldown_ms()
	if ms <= 0:
		return ""
	return "ModWorkshop rate limit reached. Try again in %ds." % ceili(ms / 1000.0)

# One-line message plumbing for callers: the rate-limit status when one is
# active (the likely cause of the failure they just saw), else their own
# error copy unchanged.
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

# Read rate-limit headers off a completed response and arm the cooldown when
# the budget is gone. Retry-After is seconds from Laravel (never the
# HTTP-date form; to_int() on one would yield 0 -> default window, safe).
# A 2xx with X-RateLimit-Remaining: 0 succeeded but was the last request the
# window allows; success responses don't say when the window resets, so
# assume the full minute rather than eat a guaranteed 429.
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

# Offline-grace snapshot of the discover landing. Not a general response
# cache (the TTL'd _mws_cache is that): one slot, keyed by nothing, holding
# the LAST fully-populated popular-and-latest payload plus the unix time it
# was stored. The Browse tab falls back to it when a live discover fetch
# fails, so first-launch-offline still shows something. Disk write-through
# lives under user://mws_cache/ next to the thumbnail cache (already on
# modpacks.gd's MODPACK_OVERRIDE_DENY_PREFIXES list, so packs can't poison
# it).
const _MWS_DISCOVER_SNAPSHOT_PATH := "user://mws_cache/discover_snapshot.json"

func _mws_discover_snapshot_store(data: Dictionary) -> void:
	_mws_discover_snapshot = {
		"data": data,
		"saved_at_unix": int(Time.get_unix_time_from_system()),
	}
	# Best-effort disk write-through: a failed write just means the grace
	# window is memory-only this session, never an error the user sees.
	DirAccess.make_dir_recursive_absolute(_MWS_DISCOVER_SNAPSHOT_PATH.get_base_dir())
	# Write-then-rename: a crash mid-write would otherwise truncate the live
	# snapshot in place, losing the offline grace window in exactly the crash
	# case it exists to cover.
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

# Last-good discover payload: {"data": {popular, latest}, "saved_at_unix":
# int}, or {} when none exists yet. Memory first, then a lazy one-time disk
# load. Every field the Browse render path touches is shape-checked here so
# a hand-edited or truncated snapshot file degrades to {} (= the plain
# failure state), never a crash. saved_at_unix arrives as a float after a
# JSON round-trip -- callers int() it.
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
	# .get()'s default only covers an ABSENT key; a present-but-null value
	# would crash int() (no int(Nil) constructor in Godot 4), so type-guard
	# like the fields above. `is float` keeps the JSON round-trip valid.
	var saved_v: Variant = snap.get("saved_at_unix", 0)
	if not (saved_v is int or saved_v is float) or int(saved_v) <= 0:
		return {}
	_mws_discover_snapshot = snap
	return snap

# RTV-scoped landing page for the Browse tab. Returns
# {popular: [ModSummary], latest: [ModSummary]} -- NOT wrapped in {data}.
#
# The dedicated /games/{id}/popular-and-latest route is DEAD upstream: the
# route is commented out in ModWorkshop's routes/api.php and the handler
# body literally returns `[] //NOT USED` (verified against the site source
# + a live 404, 2026-06-10). Compose the same payload from two working
# list queries instead -- weekly popularity score for Popular, bump date
# for Latest -- trimmed to 10 rows each so the landing stays light. Each
# underlying query goes through mws_list_mods' own cache; null only when
# BOTH queries fail (offline), matching the old single-endpoint contract.
func mws_get_popular_and_latest() -> Variant:
	var popular: Variant = await mws_list_mods("", "weekly_score", 0, 1)
	var latest: Variant = await mws_list_mods("", "bumped_at", 0, 1)
	# One flake out of two sequential requests must not kill the whole landing:
	# re-issue only the failed leg once before giving up. The healthy leg's
	# result is kept as-is (never re-fetched), so this adds at most one request.
	if not (popular is Dictionary):
		popular = await mws_list_mods("", "weekly_score", 0, 1)
	if not (latest is Dictionary):
		latest = await mws_list_mods("", "bumped_at", 0, 1)
	# Treat EITHER query failing as a failed fetch. The two run sequentially,
	# so the guest budget can expire between them (popular 2xx arms the
	# cooldown, latest fails fast at the gate) -- returning a half payload
	# would render a landing with one section silently empty and clear the
	# offline banner. Null instead lets the Browse tab fall back to the last
	# complete snapshot behind the cached-results banner. A first-run with no
	# snapshot still shows the plain error+retry state (unchanged).
	if not (popular is Dictionary) or not (latest is Dictionary):
		return null
	var pop_rows: Array = _mws_data_rows(popular).slice(0, 10)
	var lat_rows: Array = _mws_data_rows(latest).slice(0, 10)
	var out := {"popular": pop_rows, "latest": lat_rows}
	# Snapshot only a fully-populated landing: a half payload (one query
	# flaked) must not clobber an older complete snapshot -- when we're
	# degraded enough to need the snapshot, the complete one serves better.
	if not pop_rows.is_empty() and not lat_rows.is_empty():
		# Only restamp when the payload actually changed. Both queries can be
		# served from the 5-min in-memory cache with zero network, and rewriting
		# the snapshot then would advance saved_at_unix without a real refresh --
		# making the offline banner's "Last refreshed X ago" under-report age.
		var prev: Variant = _mws_discover_snapshot.get("data") if not _mws_discover_snapshot.is_empty() else null
		if not (prev is Dictionary and prev == out):
			_mws_discover_snapshot_store(out)
	return out

# Safely pull the "data" array out of a list response. The `as Array` cast
# would crash if the API returns data:null or a non-array (contract change,
# partial outage, error page served 2xx) -- the .get() default only covers an
# ABSENT key, not a present-but-wrong-typed one.
func _mws_data_rows(resp: Variant) -> Array:
	if not (resp is Dictionary):
		return []
	var d: Variant = (resp as Dictionary).get("data", [])
	return d if d is Array else []

# Search / sort / filter the RTV catalog. Returns {data: [ModSummary], meta: {...}}.
# Search param is `query` (max 150); the API silently ignores `search`/`q`/`name`,
# so passing those would look like results-with-no-filter. limit caps at 50;
# values >50 get a 422. Empty `query` -> unfiltered listing. Sort enum: bumped_at
# (default), published_at, likes, downloads, views, score, weekly_score,
# daily_score, random, best_match, name.
func mws_list_mods(query: String = "", sort: String = "bumped_at", category_id: int = 0, page: int = 1) -> Variant:
	var params := PackedStringArray()
	if query != "":
		# Clamp rather than let the API 422 -- an over-limit query would surface
		# as "check your connection", a diagnosis no retry can ever fix.
		params.append("query=" + query.substr(0, MWS_QUERY_MAX_LEN).uri_encode())
	params.append("sort=" + sort)
	params.append("limit=" + str(MWS_PAGE_LIMIT))
	params.append("page=" + str(page))
	if category_id > 0:
		params.append("category_id=" + str(category_id))
	var url := MWS_API_BASE + "/games/" + str(MWS_RTV_GAME_ID) + "/mods?" + "&".join(params)
	return await _mws_get_json(url, _MWS_TTL_LIST_MS)

# Hierarchical category list for the Browse tab filter. Returns
# {data: [Category], meta}. Categories are tree-shaped via parent_id; top-level
# nodes have parent_id == null. ~40 categories for RTV at last count.
func mws_get_categories() -> Variant:
	return await _mws_get_json(MWS_API_BASE + "/games/" + str(MWS_RTV_GAME_ID) + "/categories", _MWS_TTL_CATEGORIES_MS)

# Author-pinned default download (display_order = 0). Use this for "Get this
# mod" actions -- /files/latest sorts by author-controlled display_order and
# can return an OLDER file than primary. Returns a single File with download_url
# pointing directly at storage.modworkshop.net (skip the redirect endpoint).
func mws_get_primary_file(mod_id: int) -> Variant:
	return await _mws_get_json(MWS_API_BASE + "/mods/" + str(mod_id) + "/files/primary", _MWS_TTL_PRIMARY_MS)

# Lookup a specific version of a mod's File record. Version-pinned modpack
# applies use this to fetch the EXACT file the modpack author bundled,
# not whichever version happens to be primary at install time. Returns
# null if the version doesn't exist (author deleted it / never uploaded);
# caller should surface that to the user, NOT silently fall back to
# primary -- silent substitution is exactly what version pinning is meant
# to prevent.
func mws_get_file_by_version(mod_id: int, version: String) -> Variant:
	if version.is_empty():
		return null
	return await _mws_get_json(MWS_API_BASE + "/mods/" + str(mod_id) + "/files/" + version.uri_encode(), _MWS_TTL_PRIMARY_MS)

# Latest file by the API's sort key (semver desc, display_order desc,
# updated_at desc -- excludes prereleases by default). Used as a fallback
# when /files/primary returns null because the author hasn't designated a
# primary download (display_order=0); /files/latest still finds something
# usable for those mods.
func mws_get_latest_file(mod_id: int) -> Variant:
	return await _mws_get_json(MWS_API_BASE + "/mods/" + str(mod_id) + "/files/latest", _MWS_TTL_PRIMARY_MS)

# Full file history for the mod detail modal. Returns {data: [File], meta} with
# every uploaded version. Each File has its own version + size + created_at +
# download_url, so we can render historical versions and (eventually) install
# any of them by hitting their download_url directly.
func mws_list_files(mod_id: int) -> Variant:
	return await _mws_get_json(MWS_API_BASE + "/mods/" + str(mod_id) + "/files", _MWS_TTL_DETAIL_MS)

# Full mod detail for one mod id -- name, user, description (desc/short_desc),
# thumbnail + banner image records. Lets the Mods tab show an installed mod's
# ModWorkshop info (thumbnail, author, description) without the user having to
# hunt it down in the Browse listing. Returns the mod object dict, or null on
# failure/offline. The /mods/{id} route returns the object directly; callers
# that also feed it listing rows unwrap a {data} envelope defensively.
func mws_get_mod(mod_id: int) -> Variant:
	return await _mws_get_json(MWS_API_BASE + "/mods/" + str(mod_id), _MWS_TTL_DETAIL_MS)

# Build a full URL for an Image record (mod thumbnail or screenshot). Image
# objects have a .file (storage filename, opaque) and .has_thumb (bool); when
# has_thumb is true and want_thumb is true, prefer the smaller /thumbs/ variant.
# Phase 5 (thumbnail caching) calls this; included now so the URL convention has
# one home.
func mws_image_url(image_record: Dictionary, want_thumb: bool = false) -> String:
	var fn: String = str(image_record.get("file", ""))
	if fn.is_empty():
		return ""
	var has_thumb: bool = bool(image_record.get("has_thumb", false))
	if want_thumb and has_thumb:
		return MWS_STORAGE_BASE + "/mods/images/thumbs/" + fn
	return MWS_STORAGE_BASE + "/mods/images/" + fn
