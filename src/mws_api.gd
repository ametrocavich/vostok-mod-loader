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
##   - Failures (network, HTTP error, malformed JSON) collapse to null. Callers
##     decide how to surface them -- usually a status label in the tab.

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
func _mws_get_json(url: String, cache_ttl_ms: int = 0) -> Variant:
	if cache_ttl_ms > 0:
		var cached: Variant = _mws_cache_get(url)
		if cached != null:
			return cached

	var req := HTTPRequest.new()
	req.timeout = API_CHECK_TIMEOUT
	add_child(req)

	var err := req.request(url, _mws_default_headers(), HTTPClient.METHOD_GET)
	if err != OK:
		req.queue_free()
		return null

	# request_completed -> [result, http_code, headers, body]
	var res: Array = await req.request_completed
	req.queue_free()

	if res[0] != HTTPRequest.RESULT_SUCCESS:
		return null
	var status: int = res[1]
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

# RTV-scoped landing page for the Browse tab. Returns
# {popular: [ModSummary], latest: [ModSummary]} -- NOT wrapped in {data}.
# Suitable for a default no-search view; popular is daily_score sorted, latest
# is bumped_at sorted.
func mws_get_popular_and_latest() -> Variant:
	return await _mws_get_json(MWS_API_BASE + "/games/" + str(MWS_RTV_GAME_ID) + "/popular-and-latest", _MWS_TTL_LIST_MS)

# Search / sort / filter the RTV catalog. Returns {data: [ModSummary], meta: {...}}.
# Search param is `query` (max 150); the API silently ignores `search`/`q`/`name`,
# so passing those would look like results-with-no-filter. limit caps at 50;
# values >50 get a 422. Empty `query` -> unfiltered listing. Sort enum: bumped_at
# (default), published_at, likes, downloads, views, score, weekly_score,
# daily_score, random, best_match, name.
func mws_list_mods(query: String = "", sort: String = "bumped_at", category_id: int = 0, page: int = 1) -> Variant:
	var params := PackedStringArray()
	if query != "":
		params.append("query=" + query.uri_encode())
	params.append("sort=" + sort)
	params.append("limit=" + str(MWS_PAGE_LIMIT))
	params.append("page=" + str(page))
	if category_id > 0:
		params.append("category_id=" + str(category_id))
	var url := MWS_API_BASE + "/games/" + str(MWS_RTV_GAME_ID) + "/mods?" + "&".join(params)
	return await _mws_get_json(url, _MWS_TTL_LIST_MS)

# Full mod payload for the detail modal. Returns a bare Mod object (NOT wrapped
# in {data} -- inconsistent with the list endpoints, just the API's quirk). Has
# images[], dependencies[], breadcrumb, files_count, plus everything in ModSummary.
func mws_get_mod(mod_id: int) -> Variant:
	return await _mws_get_json(MWS_API_BASE + "/mods/" + str(mod_id), _MWS_TTL_DETAIL_MS)

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

# Same convention for the per-game thumbnail field on Game records and the
# per-mod thumbnail field on Mod records (different storage path).
func mws_thumbnail_url(thumbnail_filename: String) -> String:
	if thumbnail_filename.is_empty():
		return ""
	return MWS_STORAGE_BASE + "/mods/thumbnails/" + thumbnail_filename
