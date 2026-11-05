# Shared HTTP transport for every mod host: one GET, one response cache, one cooldown table.

const HOST_USER_AGENT_TEMPLATE := "vostok-mod-loader/%s (+https://github.com/ametrocavich/vostok-mod-loader)"

const HOST_JSON_BODY_LIMIT := 8 * 1024 * 1024

# Assumed when a host says "slow down" without saying for how long.
const _HOST_COOLDOWN_DEFAULT_MS := 60 * 1000

# A shorter cooldown is waited out inside the call; anything longer fails fast.
const _HOST_RATE_WAIT_MAX_MS := 2000

var _host_cooldown_until_ms: Dictionary = {}

## {ref key -> [other ref keys]}: Vostok Mods rows carry the slug, the mod.txt it serves the UUID.
var _host_ref_aliases: Dictionary = {}


## Hosts answer an empty or default User-Agent with a bodyless 403.
func _host_user_agent_header() -> String:
	return "User-Agent: " + (HOST_USER_AGENT_TEMPLATE % MODLOADER_VERSION)


func _hnet_cache_put(url: String, data: Variant, ttl_ms: int) -> void:
	_host_cache[url] = {"data": data, "expires_at": Time.get_ticks_msec() + ttl_ms}


func _cooldown_ms(provider: String) -> int:
	return maxi(0, int(_host_cooldown_until_ms.get(provider, 0)) - Time.get_ticks_msec())


func host_rate_cooldown_seconds(provider: String) -> int:
	return ceili(_cooldown_ms(provider) / 1000.0)


func host_arm_cooldown(provider: String, wait_ms: int) -> void:
	var ms := wait_ms if wait_ms > 0 else _HOST_COOLDOWN_DEFAULT_MS
	var until := Time.get_ticks_msec() + ms
	_host_cooldown_until_ms[provider] = maxi(int(_host_cooldown_until_ms.get(provider, 0)), until)


func _header_value(headers: PackedStringArray, header_name: String) -> String:
	var prefix := header_name.to_lower() + ":"
	for h in headers:
		if h.to_lower().begins_with(prefix):
			return h.substr(prefix.length()).strip_edges()
	return ""


func _hnet_get_json(provider: String, url: String, ttl_ms: int = 0,
		allow_rate_wait: bool = true, allow_transport_retry: bool = true) -> Dictionary:
	# Outside the tree HTTPRequest never fires request_completed; get_tree() checks cover awaits.
	if not is_inside_tree():
		return host_err(HOST_ERR_OFFLINE, 0, "loader is not in the scene tree")
	if ttl_ms > 0 and _host_cache.has(url):
		if Time.get_ticks_msec() <= int(_host_cache[url]["expires_at"]):
			return host_ok(_host_cache[url]["data"])
		_host_cache.erase(url)

	var cooldown_ms := _cooldown_ms(provider)
	if cooldown_ms > 0:
		if not allow_rate_wait or cooldown_ms > _HOST_RATE_WAIT_MAX_MS:
			return _rate_limited()
		await get_tree().create_timer(float(cooldown_ms + 100) / 1000.0).timeout
		# Another request may have hit a 429 and pushed the window out while this one waited.
		if _cooldown_ms(provider) > 0:
			return _rate_limited()

	var req := HTTPRequest.new()
	req.timeout = API_CHECK_TIMEOUT
	# A captive portal streaming an endless 2xx body cannot grow past this.
	req.body_size_limit = HOST_JSON_BODY_LIMIT
	add_child(req)

	var err := req.request(url, PackedStringArray([_host_user_agent_header(), "Accept: application/json"]),
			HTTPClient.METHOD_GET)
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
		# A cold DNS/TLS handshake often fails the first request: one retry, never after a timeout.
		if allow_transport_retry and result != HTTPRequest.RESULT_TIMEOUT and get_tree() != null:
			await get_tree().create_timer(1.0).timeout
			return await _hnet_get_json(provider, url, ttl_ms, allow_rate_wait, false)
		return host_err(HOST_ERR_OFFLINE, 0, "could not reach the server")

	var status: int = res[1]
	var headers: PackedStringArray = res[2]
	host_note_rate_headers(provider, status, headers)

	# A short 429 is waited out once (host_note_rate_headers armed a window); others fail below.
	if status == 429 and allow_rate_wait and _cooldown_ms(provider) <= _HOST_RATE_WAIT_MAX_MS and get_tree() != null:
		await get_tree().create_timer(float(_cooldown_ms(provider) + 100) / 1000.0).timeout
		return await _hnet_get_json(provider, url, ttl_ms, false, allow_transport_retry)
	var status_err := _hnet_status_error(status)
	if not status_err.is_empty():
		return status_err

	var body: PackedByteArray = res[3]
	if body.is_empty():
		return host_err(HOST_ERR_BAD_RESPONSE, status, "empty response body")
	var parsed: Variant = JSON.parse_string(body.get_string_from_utf8())
	if parsed == null:
		return host_err(HOST_ERR_BAD_RESPONSE, status, "response was not JSON")

	if ttl_ms > 0:
		_hnet_cache_put(url, parsed, ttl_ms)
	return host_ok(parsed)


func _hnet_status_error(status: int) -> Dictionary:
	if status == 429:
		return _rate_limited()
	if status == 401 or status == 403:
		return host_err(HOST_ERR_AUTH, status, "the server refused the request")
	if status == 404:
		return host_err(HOST_ERR_NOT_FOUND, status, "not found")
	if status >= 500:
		return host_err(HOST_ERR_SERVER, status, "the server is having trouble")
	if status < 200 or status >= 300:
		return host_err(HOST_ERR_CLIENT, status, "unexpected response " + str(status))
	return {}


func _rate_limited() -> Dictionary:
	return host_err(HOST_ERR_RATE_LIMITED, 429, "rate limited")


func _hnet_query(params: Dictionary) -> String:
	if params.is_empty():
		return ""
	var parts := PackedStringArray()
	for k in params.keys():
		parts.append(str(k) + "=" + str(params[k]).uri_encode())
	return "?" + "&".join(parts)
