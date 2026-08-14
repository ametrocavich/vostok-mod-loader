## ----- host_http.gd -----
## Shared HTTP transport for every mod host. One GET helper, one response
## cache, one cooldown table, so a new adapter inherits the timeout, the body
## cap, the retry policy and the rate-limit handling instead of restating them.
##
## Everything host-specific stays out: reading a rate-limit header is a
## per-provider dialect and is dispatched through host_note_rate_headers.
##
## Returns a HostResult (see host_types.gd), never a bare null. The point is
## that callers can tell offline from 404 from rate-limited, which the older
## collapse-everything-to-null contract could not express.

# Becomes the definition once mws_api.gd is absorbed into host_mws.gd. Aliased
# rather than copied so the two cannot drift in the meantime.
const HOST_USER_AGENT_TEMPLATE := MWS_USER_AGENT_TEMPLATE

# api.modworkshop.net answers an empty or default User-Agent with a bodyless
# 403, and other hosts are likely to be similarly picky, so the header is not
# optional. Accept only matters if a host starts serving useful error bodies.
const HOST_JSON_BODY_LIMIT := 8 * 1024 * 1024

# Assumed cooldown when a host says "slow down" without saying for how long.
const _HOST_COOLDOWN_DEFAULT_MS := 60 * 1000

# A cooldown with less than this left is waited out inside the call, so a
# click landing 100ms before the window opens succeeds instead of failing.
# Anything longer fails fast and lets the UI say how long to wait.
const _HOST_RATE_WAIT_MAX_MS := 2000


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


## Whole seconds left, rounded up. Public so the UI can render "try again in
## Ns" without duplicating the arithmetic.
func host_rate_cooldown_seconds(provider: String) -> int:
	return ceili(_hnet_cooldown_ms(provider) / 1000.0)


## Arm (or extend) a provider's cooldown. Adapters call this from their
## header-reading arm; wait_ms <= 0 uses the default window.
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

## Async JSON GET. Returns host_ok(parsed) or a host_err with the code that
## tells the caller what actually went wrong.
##
## ttl_ms > 0 reads and writes the response cache. Failures are never cached,
## so one 5xx flake does not poison the entry for the whole TTL.
##
## The two retry flags exist only so the recursive retries cannot loop: each
## retry passes its own flag false, so a second failure of the same kind falls
## through to a returned error.
func _hnet_get_json(provider: String, url: String, ttl_ms: int = 0,
		allow_rate_wait: bool = true, allow_transport_retry: bool = true) -> Dictionary:
	# An HTTPRequest added under a node that is not in the tree never gets
	# _process, so request_completed never fires and the timeout never ticks:
	# the caller would suspend forever. Fail fast instead. The per-branch
	# get_tree() checks below cover the points reached after an await.
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
		# Another in-flight request may have hit a 429 and pushed the window
		# out again while we waited. Re-check rather than fire into a window
		# that just closed -- that request would 429 and re-arm anyway.
		if _hnet_cooldown_ms(provider) > 0:
			return host_err(HOST_ERR_RATE_LIMITED, 429, "rate limited",
					host_rate_cooldown_seconds(provider))

	var req := HTTPRequest.new()
	req.timeout = API_CHECK_TIMEOUT
	# Cap the buffer so a captive portal or a misbehaving proxy streaming an
	# endless 2xx body cannot grow unbounded for the whole timeout window.
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
			# A cold DNS/TLS handshake often fails the very first request after
			# launch, so one retry buys a working Browse tab on a slow network.
			await get_tree().create_timer(1.0).timeout
			return await _hnet_get_json(provider, url, ttl_ms, allow_rate_wait, false)
		return host_err(HOST_ERR_OFFLINE, 0, "could not reach the server")

	var status: int = res[1]
	var headers: PackedStringArray = res[2]
	host_note_rate_headers(provider, status, headers)

	if status == 429:
		# A host whose rate-limit dialect we cannot read (no Retry-After, no
		# remaining-budget header) leaves the cooldown unarmed, and an unarmed
		# cooldown reads as "0ms left" -- which would send the retry below
		# straight back out after 100ms and turn a 429 into a hammering loop.
		# An unknown limit deserves more caution than a known one, not less,
		# so arm the default window before deciding anything.
		if _hnet_cooldown_ms(provider) <= 0:
			host_arm_cooldown(provider, 0)
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


## Build a query string from a {key: value} dictionary. Values are
## uri_encode()d; keys are ours and are not. Empty dictionary yields "".
func _hnet_query(params: Dictionary) -> String:
	if params.is_empty():
		return ""
	var parts := PackedStringArray()
	for k in params.keys():
		parts.append(str(k) + "=" + str(params[k]).uri_encode())
	return "?" + "&".join(parts)
