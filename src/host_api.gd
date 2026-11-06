# The host seam. Dispatch is a `match`, not a Callable table, so the synchronous operations stay
# synchronous (a Callable call would have to await); check_host.sh T9 reads every arm.


## Dispatchable providers; index 0 is the host the Browse tab opens on.
func host_providers() -> PackedStringArray:
	return PackedStringArray([HOST_VOSTOKMODS, HOST_MODWORKSHOP])


func host_browse_providers() -> PackedStringArray:
	var out := PackedStringArray()
	for p in host_providers():
		if host_caps(p)["browse"]:
			out.append(p)
	return out


# The loader's own listing per host, hidden from Browse: Download would put the loader in mods/.
const HOST_OWN_LISTINGS := {
	HOST_MODWORKSHOP: "55623",
	HOST_VOSTOKMODS: "metro-mod-loader",
}

## The id is matched per host: another host's mod may carry the same id.
func _host_is_own_listing(provider: String, row: Dictionary) -> bool:
	var own := str(HOST_OWN_LISTINGS.get(provider, ""))
	return own != "" and str(row["ref"]["id"]) == own

## Paging fields are left alone: a page may come back one row short.
func _host_hide_own_listing(provider: String, result: Dictionary) -> Dictionary:
	if HOST_OWN_LISTINGS.has(provider) and result["ok"]:
		result["data"]["rows"] = (result["data"]["rows"] as Array).filter(
				func(row: Dictionary) -> bool: return not _host_is_own_listing(provider, row))
	return result

## q keys, all optional: query, sort_key, category_ref, cursor ("" for page one), limit.
func host_list_mods(provider: String, q: Dictionary) -> Dictionary:
	var out: Dictionary
	match provider:
		HOST_MODWORKSHOP: out = await _mwsp_list_mods(q)
		HOST_VOSTOKMODS: out = await _vmp_list_mods(q)
		_: out = _host_unwired("host_list_mods", provider)
	return _host_hide_own_listing(provider, out)


func host_get_mod(ref: Dictionary) -> Dictionary:
	if not host_ref_valid(ref):
		return host_err(HOST_ERR_NOT_FOUND, 0, "invalid mod reference")
	match str(ref["provider"]):
		HOST_MODWORKSHOP: return await _mwsp_get_mod(ref)
		HOST_VOSTOKMODS: return await _vmp_get_mod(ref)
		_: return _host_unwired("host_get_mod", str(ref["provider"]))


## Every downloadable version, newest first, as FileRecords; needs caps.file_history.
func host_list_files(ref: Dictionary) -> Dictionary:
	if not host_ref_valid(ref):
		return host_err(HOST_ERR_NOT_FOUND, 0, "invalid mod reference")
	match str(ref["provider"]):
		HOST_MODWORKSHOP: return await _mwsp_list_files(ref)
		HOST_VOSTOKMODS: return await _vmp_list_files(ref)
		_: return _host_unwired("host_list_files", str(ref["provider"]))


## version "" is whatever the host calls current; a pinned version that is gone is
## HOST_ERR_VERSION_NOT_FOUND, never another version.
func host_resolve_file(ref: Dictionary, version: String = "") -> Dictionary:
	if not host_ref_valid(ref):
		return host_err(HOST_ERR_NOT_FOUND, 0, "invalid mod reference")
	match str(ref["provider"]):
		HOST_MODWORKSHOP: return await _mwsp_resolve_file(ref, version)
		HOST_VOSTOKMODS: return await _vmp_resolve_file(ref, version)
		_: return _host_unwired("host_resolve_file", str(ref["provider"]))


func host_list_categories(provider: String) -> Dictionary:
	match provider:
		HOST_MODWORKSHOP: return await _mwsp_list_categories()
		HOST_VOSTOKMODS: return await _vmp_list_categories()
		_: return _host_unwired("host_list_categories", provider)


## Data is {ref_key -> version}. A rate limit or lost connection part-way returns the
## answers collected so far, or the failure when there are none.
func host_latest_versions(provider: String, ids: PackedStringArray) -> Dictionary:
	match provider:
		HOST_MODWORKSHOP: return await _mwsp_latest_versions(ids)
		HOST_VOSTOKMODS: return await _vmp_latest_versions(ids)
		_: return _host_unwired("host_latest_versions", provider)


# From here down nothing may await: widget construction and value-returning code call these.

func host_display_name(provider: String) -> String:
	match provider:
		HOST_MODWORKSHOP: return "ModWorkshop"
		HOST_VOSTOKMODS: return "Vostok Mods"
		_: return provider


func host_caps(provider: String) -> Dictionary:
	match provider:
		HOST_MODWORKSHOP: return _mwsp_caps()
		HOST_VOSTOKMODS: return _vmp_caps()
		_: return host_empty_caps()


## "" when the host has no page, which hides the button.
func host_mod_page_url(ref: Dictionary) -> String:
	if not host_ref_valid(ref):
		return ""
	match str(ref["provider"]):
		HOST_MODWORKSHOP: return _mwsp_mod_page_url(str(ref["id"]))
		HOST_VOSTOKMODS: return _vmp_mod_page_url(str(ref["id"]))
		_: return ""


func host_note_same_mod(provider: String, id_a: String, id_b: String) -> void:
	var a := host_ref_key(host_ref(provider, id_a))
	var b := host_ref_key(host_ref(provider, id_b))
	if a == "" or b == "" or a == b:
		return
	for pair in [[a, b], [b, a]]:
		var known: Array = _host_ref_aliases.get(pair[0], [])
		if not known.has(pair[1]):
			known.append(pair[1])
		_host_ref_aliases[pair[0]] = known


func host_ref_aliases(key: String) -> Array:
	return _host_ref_aliases.get(key, [])


## Runs on every response, 2xx included: most hosts report the remaining budget there.
func host_note_rate_headers(provider: String, status: int, headers: PackedStringArray) -> void:
	match provider:
		HOST_MODWORKSHOP: _mwsp_note_rate_headers(status, headers)
		HOST_VOSTOKMODS: _vmp_note_rate_headers(status, headers)
	# A 429 that named no wait still arms the default window, for downloads too.
	if status == 429 and _cooldown_ms(provider) <= 0:
		host_arm_cooldown(provider, 0)


func _host_scalars(provider: String) -> Dictionary:
	match provider:
		HOST_MODWORKSHOP: return _mwsp_scalars()
		HOST_VOSTOKMODS: return _vmp_scalars()
		_: return host_empty_scalars()


func host_limit(provider: String, key: String, fallback: int) -> int:
	return int(_host_scalars(provider).get(key, fallback))


## [{key, label}] in menu order. With caps.sort_ignored_with_query each also names the
## row_field Browse re-sorts search results by.
func host_sorts(provider: String) -> Array:
	return _host_scalars(provider)["sorts"]


## [{title, sort_key, limit}]; empty opens Browse straight into the full listing.
func host_sections(provider: String) -> Array:
	return _host_scalars(provider)["landing_sections"]


## The rate-limit message while a cooldown runs (the likely cause), else the caller's copy.
func host_error_status(provider: String, fallback: String) -> String:
	var secs := host_rate_cooldown_seconds(provider)
	if secs <= 0:
		return fallback
	return "%s rate limit reached. Try again in %ds." % [host_display_name(provider), secs]


func host_error_message(provider: String, result: Dictionary) -> String:
	var host := host_display_name(provider)
	match str(result["code"]):
		HOST_ERR_OFFLINE: return "Could not reach %s. Check your connection." % host
		HOST_ERR_RATE_LIMITED: return host_error_status(provider, "%s is rate limiting requests." % host)
		HOST_ERR_AUTH: return "%s refused the request." % host
		HOST_ERR_NOT_FOUND: return "Not found on %s." % host
		HOST_ERR_NO_FILE: return "That mod has no downloadable file on %s." % host
		HOST_ERR_NOT_SCANNED: return "That version has not passed %s's malware scan yet." % host
		HOST_ERR_VERSION_NOT_FOUND: return "That version is no longer available on %s." % host
		HOST_ERR_SERVER: return "%s is having trouble. Try again shortly." % host
		HOST_ERR_TOO_LARGE: return "%s sent more data than expected." % host
		HOST_ERR_BAD_RESPONSE: return "%s sent an unexpected response." % host
		_: return str(result["message"])


func _host_unwired(op: String, provider: String) -> Dictionary:
	_log_warning("[Host] %s has no arm for provider '%s'" % [op, provider])
	return host_err(HOST_ERR_UNWIRED, 0, "%s is not implemented for %s" % [op, provider])
