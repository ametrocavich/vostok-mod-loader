## ----- host_api.gd -----
## The seam: every operation against a mod host goes through exactly one
## function here, which dispatches on a provider id to the adapter.
##
## Dispatch is an explicit `match` (mirroring registry.gd), not a Callable
## table: with the concrete callee visible, the synchronous operations stay
## statically synchronous. A Callable table would make each one `await`, and
## host_mod_page_url is called from code that must return a Control, not a
## coroutine.
##
## Adapter naming: _<tag>p_<operation> (modworkshop -> _mwsp_*, vostokmods ->
## _vmp_*). Every arm returns a HostResult (host_types.gd). The `_:` fallback
## fires when an on-disk source names a provider this build does not
## implement, e.g. after a loader downgrade.


## Providers this build can dispatch to, in display order. Distinct from
## HOST_PROVIDERS_KNOWN (what the on-disk parser accepts). Browse-style
## listings use host_browse_providers(), which filters on caps.browse.
func host_providers() -> PackedStringArray:
	# Order is the product decision: index 0 is what the Browse tab opens on.
	return PackedStringArray([HOST_VOSTOKMODS, HOST_MODWORKSHOP])


## host_providers() filtered by caps.browse. The Browse provider switcher is
## built from this, never from host_providers() directly. Synchronous and
## network-free, safe during widget construction.
func host_browse_providers() -> PackedStringArray:
	var out := PackedStringArray()
	for p in host_providers():
		if host_caps(p)["browse"]:
			out.append(p)
	return out


# ----- async operations -----

## List, search or filter a host's catalog. q keys, all optional: query,
## sort_key, category_ref, cursor ("" for the first page), limit. One
## dictionary so a new filter adds a key, not an edit to every arm.
func host_list_mods(provider: String, q: Dictionary) -> Dictionary:
	var out: Dictionary
	match provider:
		HOST_MODWORKSHOP: out = await _mwsp_list_mods(q)
		HOST_VOSTOKMODS: out = await _vmp_list_mods(q)
		_: out = _host_unwired("host_list_mods", provider)
	return _host_check_result(provider, "host_list_mods", out)


## Full detail for one mod. Data is a ModDetail record.
func host_get_mod(ref: Dictionary) -> Dictionary:
	if not host_ref_valid(ref):
		return host_err(HOST_ERR_NOT_FOUND, 0, "invalid mod reference")
	var provider := str(ref.get("provider", ""))
	var out: Dictionary
	match provider:
		HOST_MODWORKSHOP: out = await _mwsp_get_mod(ref)
		HOST_VOSTOKMODS: out = await _vmp_get_mod(ref)
		_: out = _host_unwired("host_get_mod", provider)
	return _host_check_result(provider, "host_get_mod", out)


## Every downloadable version of one mod, newest first. Data is an Array of
## FileRecord. Only meaningful when caps.file_history is true.
func host_list_files(ref: Dictionary) -> Dictionary:
	if not host_ref_valid(ref):
		return host_err(HOST_ERR_NOT_FOUND, 0, "invalid mod reference")
	var provider := str(ref.get("provider", ""))
	var out: Dictionary
	match provider:
		HOST_MODWORKSHOP: out = await _mwsp_list_files(ref)
		HOST_VOSTOKMODS: out = await _vmp_list_files(ref)
		_: out = _host_unwired("host_list_files", provider)
	return _host_check_result(provider, "host_list_files", out)


## The one file to install for this mod. version "" means "whatever the host
## considers current"; a non-empty version pins an exact release and returns
## HOST_ERR_VERSION_NOT_FOUND rather than silently substituting another.
func host_resolve_file(ref: Dictionary, version: String = "") -> Dictionary:
	if not host_ref_valid(ref):
		return host_err(HOST_ERR_NOT_FOUND, 0, "invalid mod reference")
	var provider := str(ref.get("provider", ""))
	var out: Dictionary
	match provider:
		HOST_MODWORKSHOP: out = await _mwsp_resolve_file(ref, version)
		HOST_VOSTOKMODS: out = await _vmp_resolve_file(ref, version)
		_: out = _host_unwired("host_resolve_file", provider)
	return _host_check_result(provider, "host_resolve_file", out)


## The host's category tree. Data is an Array of Category.
func host_list_categories(provider: String) -> Dictionary:
	var out: Dictionary
	match provider:
		HOST_MODWORKSHOP: out = await _mwsp_list_categories()
		HOST_VOSTOKMODS: out = await _vmp_list_categories()
		_: out = _host_unwired("host_list_categories", provider)
	return _host_check_result(provider, "host_list_categories", out)


## Current version string for many mods at once, for the Updates tab.
## on_progress is called with {done, total, partial} as answers arrive,
## partial holding only the newly resolved {ref_key -> version} pairs; hosts
## without a batch endpoint resolve one mod per request, so streaming keeps
## partial results when the rate budget runs out.
func host_latest_versions(provider: String, ids: PackedStringArray, on_progress: Callable) -> Dictionary:
	var out: Dictionary
	match provider:
		HOST_MODWORKSHOP: out = await _mwsp_latest_versions(ids, on_progress)
		HOST_VOSTOKMODS: out = await _vmp_latest_versions(ids, on_progress)
		_: out = _host_unwired("host_latest_versions", provider)
	return _host_check_result(provider, "host_latest_versions", out)


# ----- synchronous operations -----
#
# None of these may await, directly or transitively. They are called from
# widget construction and from functions that return a value, not a coroutine.

## Host name for user-facing copy; falls back to the provider id so an
## unknown host still reads as something mid-sentence.
func host_display_name(provider: String) -> String:
	match provider:
		HOST_MODWORKSHOP: return "ModWorkshop"
		HOST_VOSTOKMODS: return "VostokMods"
		_: return provider


func host_caps(provider: String) -> Dictionary:
	match provider:
		HOST_MODWORKSHOP: return _mwsp_caps()
		HOST_VOSTOKMODS: return _vmp_caps()
		_: return host_empty_caps()


## Browser URL for a mod's page, or "" when the host has none, in which case
## the UI hides the button.
func host_mod_page_url(ref: Dictionary) -> String:
	if not host_ref_valid(ref):
		return ""
	match str(ref["provider"]):
		HOST_MODWORKSHOP: return _mwsp_mod_page_url(str(ref["id"]))
		HOST_VOSTOKMODS: return _vmp_mod_page_url(str(ref["id"]))
		_: return ""


## Let the adapter read its own rate-limit dialect off a completed response
## and arm the cooldown. Called on every response, including 2xx: most hosts
## report a remaining budget there.
func host_note_rate_headers(provider: String, status: int, headers: PackedStringArray) -> void:
	match provider:
		HOST_MODWORKSHOP: _mwsp_note_rate_headers(status, headers)
		HOST_VOSTOKMODS: _vmp_note_rate_headers(status, headers)


## Non-boolean provider policy: sorts, landing sections, and limits.
func _host_scalars(provider: String) -> Dictionary:
	match provider:
		HOST_MODWORKSHOP: return _mwsp_scalars()
		HOST_VOSTOKMODS: return _vmp_scalars()
		_: return host_empty_scalars()


# ----- typed accessors over _host_scalars -----

func host_limit(provider: String, key: String, fallback: int) -> int:
	var v: Variant = _host_scalars(provider).get(key)
	return int(v) if v is int else fallback


## Sort options as [{key, label}], in menu order; empty hides the control.
func host_sorts(provider: String) -> Array:
	var v: Variant = _host_scalars(provider).get("sorts")
	return v if v is Array else []


## Landing sections as [{key, title, sort_key, limit}]; empty means the
## Browse tab opens straight into the full listing.
func host_sections(provider: String) -> Array:
	var v: Variant = _host_scalars(provider).get("landing_sections")
	return v if v is Array else []


## One-line status for a failed call: the rate-limit message when a cooldown
## is running (the likely cause), otherwise the caller's own copy.
func host_error_status(provider: String, fallback: String) -> String:
	var secs := host_rate_cooldown_seconds(provider)
	if secs <= 0:
		return fallback
	return "%s rate limit reached. Try again in %ds." % [host_display_name(provider), secs]


## Human-readable copy for the failure codes every host shares; adapters set
## `message` for anything host-specific.
func host_error_message(provider: String, result: Dictionary) -> String:
	var host := host_display_name(provider)
	match str(result.get("code", "")):
		HOST_ERR_OFFLINE: return "Could not reach %s. Check your connection." % host
		HOST_ERR_RATE_LIMITED: return host_error_status(provider, "%s is rate limiting requests." % host)
		HOST_ERR_AUTH: return "%s refused the request." % host
		HOST_ERR_NOT_FOUND: return "Not found on %s." % host
		HOST_ERR_NO_FILE: return "That mod has no downloadable file on %s." % host
		HOST_ERR_VERSION_NOT_FOUND: return "That version is no longer available on %s." % host
		HOST_ERR_SERVER: return "%s is having trouble. Try again shortly." % host
		HOST_ERR_TOO_LARGE: return "%s sent more data than expected." % host
		HOST_ERR_BAD_RESPONSE: return "%s sent an unexpected response." % host
		HOST_ERR_UNSUPPORTED: return "%s does not support that." % host
		_: return str(result.get("message", "Something went wrong."))


# ----- dispatch plumbing -----

## No arm for this provider. Distinct from HOST_ERR_UNSUPPORTED (a declared
## capability off): here the caps say yes and the wiring says no, which is
## our bug and is logged as one.
func _host_unwired(op: String, provider: String) -> Dictionary:
	_log_warning("[Host] %s has no arm for provider '%s'" % [op, provider])
	return host_err(HOST_ERR_UNWIRED, 0, "%s is not implemented for %s" % [op, provider])


## An adapter that returns something other than a HostResult fails here,
## with the operation named, not three frames later on ["ok"].
func _host_check_result(provider: String, op: String, out: Variant) -> Dictionary:
	if out is Dictionary and (out as Dictionary).has("ok"):
		return out
	_log_warning("[Host] %s (%s) returned a malformed result" % [op, provider])
	return host_err(HOST_ERR_BAD_RESPONSE, 0, "malformed adapter result")
