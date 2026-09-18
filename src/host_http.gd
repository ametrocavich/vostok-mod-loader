## ----- host_http.gd -----
## Shared HTTP transport for every mod host: one GET helper, one response
## cache, one cooldown table, so adapters inherit the timeout, body cap,
## retry policy and rate-limit handling. Host-specific header dialects stay
## out (dispatched through host_note_rate_headers). Returns a HostResult
## (host_types.gd), never a bare null, so callers can tell offline from 404
## from rate-limited.

const MWS_USER_AGENT_TEMPLATE := "vostok-mod-loader/%s (+https://github.com/ametrocavich/vostok-mod-loader)"
const HOST_USER_AGENT_TEMPLATE := MWS_USER_AGENT_TEMPLATE

const HOST_JSON_BODY_LIMIT := 8 * 1024 * 1024

# Assumed cooldown when a host says "slow down" without saying for how long.
const _HOST_COOLDOWN_DEFAULT_MS := 60 * 1000

# A cooldown with less than this left is waited out inside the call, so a
# click just before the window opens succeeds; anything longer fails fast.
const _HOST_RATE_WAIT_MAX_MS := 2000

# Rate-limit cooldowns, provider id -> ticks_msec resume moment.
# Per-provider: hosts have independent budgets.
var _host_cooldown_until_ms: Dictionary = {}


func _hnet_default_headers() -> PackedStringArray:
	return PackedStringArray([
		"User-Agent: " + (HOST_USER_AGENT_TEMPLATE % MODLOADER_VERSION),
		"Accept: application/json",
	])


# ----- response cache -----

func _hnet_cache_get(url: String) -> Variant:
	if not _host_cache.has(url):
		return null
	var entry: Dictionary = _host_cache[url]
	if Time.get_ticks_msec() > int(entry["expires_at"]):
		_host_cache.erase(url)
		return null
	return entry["data"]


func _hnet_cache_put(url: String, data: Variant, ttl_ms: int) -> void:
	_host_cache[url] = {"data": data, "expires_at": Time.get_ticks_msec() + ttl_ms}


# ----- rate-limit cooldown -----

## Milliseconds left on this provider's cooldown; 0 when requests may go out.
func _hnet_cooldown_ms(provider: String) -> int:
	return maxi(0, int(_host_cooldown_until_ms.get(provider, 0)) - Time.get_ticks_msec())


## Whole seconds left, rounded up; public for the UI's "try again in Ns".
func host_rate_cooldown_seconds(provider: String) -> int:
	return ceili(_hnet_cooldown_ms(provider) / 1000.0)


## Arm (or extend) a provider's cooldown; wait_ms <= 0 uses the default.
func host_arm_cooldown(provider: String, wait_ms: int) -> void:
	var ms := wait_ms if wait_ms > 0 else _HOST_COOLDOWN_DEFAULT_MS
	var until := Time.get_ticks_msec() + ms
	_host_cooldown_until_ms[provider] = maxi(int(_host_cooldown_until_ms.get(provider, 0)), until)


## Case-insensitive response-header lookup. "" when absent.
func _hnet_header_value(headers: PackedStringArray, header_name: String) -> String:
	var prefix := header_name.to_lower() + ":"
	for h in headers:
		if h.to_lower().begins_with(prefix):
			return h.substr(prefix.length()).strip_edges()
	return ""


# ----- the GET -----

## Async JSON GET returning host_ok(parsed) or a coded host_err. ttl_ms > 0
## reads and writes the response cache; failures are never cached. The two
## retry flags exist so the recursive retries cannot loop: each retry passes
## its own flag false.
func _hnet_get_json(provider: String, url: String, ttl_ms: int = 0,
		allow_rate_wait: bool = true, allow_transport_retry: bool = true) -> Dictionary:
	# An HTTPRequest under a node outside the tree never gets _process, so
	# request_completed never fires and the caller would suspend forever.
	# The get_tree() checks below cover the points reached after an await.
	if not is_inside_tree():
		return host_err(HOST_ERR_OFFLINE, 0, "loader is not in the scene tree")
	if ttl_ms > 0:
		var cached: Variant = _hnet_cache_get(url)
		if cached != null:
			return host_ok(cached)

	var cooldown_ms := _hnet_cooldown_ms(provider)
	if cooldown_ms > 0:
		if not allow_rate_wait or cooldown_ms > _HOST_RATE_WAIT_MAX_MS or get_tree() == null:
			return host_err(HOST_ERR_RATE_LIMITED, 429, "rate limited",
					host_rate_cooldown_seconds(provider))
		await get_tree().create_timer(float(cooldown_ms + 100) / 1000.0).timeout
		# Another in-flight request may have 429d and pushed the window out
		# while we waited; re-check rather than fire into it.
		if _hnet_cooldown_ms(provider) > 0:
			return host_err(HOST_ERR_RATE_LIMITED, 429, "rate limited",
					host_rate_cooldown_seconds(provider))

	var req := HTTPRequest.new()
	req.timeout = API_CHECK_TIMEOUT
	# Cap so a captive portal streaming an endless 2xx body cannot grow unbounded.
	req.download_body_size_limit = HOST_JSON_BODY_LIMIT
	add_child(req)

	var err := req.request(url, _hnet_default_headers(), HTTPClient.METHOD_GET)
	if err != OK:
		req.queue_free()
		return host_err(HOST_ERR_OFFLINE, 0, "request could not be started")

	# request_completed -> [result, http_code, headers, body]
	var res: Array = await req.request_completed
	req.queue_free()

	var result: int = res[0]
	if result == HTTPRequest.RESULT_BODY_SIZE_LIMIT_EXCEEDED:
		return host_err(HOST_ERR_TOO_LARGE, 0, "response exceeded the size limit")
	if result != HTTPRequest.RESULT_SUCCESS:
		# No HTTP response at all: offline, DNS, TLS or timeout.
		if allow_transport_retry and get_tree() != null:
			# A cold DNS/TLS handshake often fails the first request after launch.
			await get_tree().create_timer(1.0).timeout
			return await _hnet_get_json(provider, url, ttl_ms, allow_rate_wait, false)
		return host_err(HOST_ERR_OFFLINE, 0, "could not reach the server")

	var status: int = res[1]
	var headers: PackedStringArray = res[2]
	host_note_rate_headers(provider, status, headers)

	if status == 429:
		# host_note_rate_headers armed a window even when the host named none,
		# so the retry below never goes straight back out.
		var wait_s := host_rate_cooldown_seconds(provider)
		if allow_rate_wait and _hnet_cooldown_ms(provider) <= _HOST_RATE_WAIT_MAX_MS and get_tree() != null:
			await get_tree().create_timer(float(_hnet_cooldown_ms(provider) + 100) / 1000.0).timeout
			return await _hnet_get_json(provider, url, ttl_ms, false, allow_transport_retry)
		return host_err(HOST_ERR_RATE_LIMITED, 429, "rate limited", wait_s)
	if status == 401 or status == 403:
		return host_err(HOST_ERR_AUTH, status, "the server refused the request")
	if status == 404:
		return host_err(HOST_ERR_NOT_FOUND, status, "not found")
	if status >= 500:
		return host_err(HOST_ERR_SERVER, status, "the server is having trouble")
	if status < 200 or status >= 300:
		return host_err(HOST_ERR_CLIENT, status, "unexpected response " + str(status))

	var body: PackedByteArray = res[3]
	if body.is_empty():
		return host_err(HOST_ERR_BAD_RESPONSE, status, "empty response body")
	var parsed: Variant = JSON.parse_string(body.get_string_from_utf8())
	if parsed == null:
		# Most often a captive portal or an error page served with a 2xx.
		return host_err(HOST_ERR_BAD_RESPONSE, status, "response was not JSON")

	if ttl_ms > 0:
		_hnet_cache_put(url, parsed, ttl_ms)
	return host_ok(parsed)


## Query string from {key: value}; values uri_encode()d, keys are ours and
## are not. Empty dictionary yields "".
func _hnet_query(params: Dictionary) -> String:
	if params.is_empty():
		return ""
	var parts := PackedStringArray()
	for k in params.keys():
		parts.append(str(k) + "=" + str(params[k]).uri_encode())
	return "?" + "&".join(parts)
