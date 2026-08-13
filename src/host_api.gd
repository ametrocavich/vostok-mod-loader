## ----- host_api.gd -----
## The seam. Every operation the loader performs against a mod host goes
## through exactly one function here, which dispatches on a provider id to the
## adapter that implements it.
##
## Dispatch is an explicit `match` with one arm per provider, mirroring
## registry.gd. It is deliberately boring:
##
##   - The compiler sees the concrete callee, so the seven synchronous
##     operations below stay statically synchronous. A table of Callables
##     would make every one of them `await`, and host_mod_page_url is called
##     from _browse_render_mod_row, which returns a Control. Turning that into
##     a coroutine is the 3.3.0 regression re-committed by hand.
##   - Adding a provider is one arm per operation and a grep-able name. There
##     is no registration order, no boot-time table, and nothing to get out of
##     sync with the capability list.
##
## Adapter naming: _<tag>p_<operation>. modworkshop -> _mwsp_*,
## vostokmods -> _vmp_*. The tag is short because it appears on every arm.
##
## Every arm returns a HostResult (host_types.gd). The `_:` fallback is not
## dead code -- it fires when an on-disk source names a provider this build
## does not implement, which is exactly what happens when a user downgrades
## the loader while keeping their mods.


## Providers this build can actually dispatch to, in display order. Distinct
## from HOST_PROVIDERS_KNOWN, which is the wider set the on-disk parser will
## accept: a source may be readable and still not be servable by this build.
##
## Dispatchable does not mean browsable: a link-out-only host like Nexus
## belongs here (its page_url, display name and provenance all dispatch) but
## can never serve a listing. Anything populating a Browse-style listing
## control must use host_browse_providers() instead of this list.
func host_providers() -> PackedStringArray:
	return PackedStringArray([HOST_MODWORKSHOP, HOST_VOSTOKMODS, HOST_NEXUS])


## Providers whose catalog can populate the Browse tab: host_providers()
## filtered by caps.browse. The provider switcher MUST be built from this,
## never from host_providers() directly -- a switcher entry for a host whose
## every fetch returns UNSUPPORTED is the button-that-can-only-fail the caps
## model exists to prevent.
##
## Placement: this lives in host_api.gd rather than host_types.gd because it
## composes host_providers() and host_caps(), both defined in this file;
## host_types.gd is provider-neutral vocabulary and stays free of dispatch
## knowledge. Synchronous and network-free, safe during widget construction.
func host_browse_providers() -> PackedStringArray:
	var out := PackedStringArray()
	for p in host_providers():
		if host_caps(p)["browse"]:
			out.append(p)
	return out


# ----- async operations -----

## List, search or filter a host's catalog.
##
## q keys, all optional: query (String), sort_key (String), category_ref
## (String), cursor (String, "" for the first page), limit (int).
## One dictionary rather than positional parameters because this is the one
## operation whose parameter set will keep growing, and a new filter should
## add a key rather than edit every arm and every call site.
func host_list_mods(provider: String, q: Dictionary) -> Dictionary:
	var out: Dictionary
	match provider:
		HOST_MODWORKSHOP: out = await _mwsp_list_mods(q)
		HOST_NEXUS: out = _nxp_unsupported("host_list_mods")
		HOST_VOSTOKMODS: out = await _vmp_list_mods(q)
		_: out = _host_unwired("host_list_mods", provider)
	return _host_check_result(provider, "host_list_mods", out)


## Full detail for one mod. Data is a ModDetail record.
func host_get_mod(ref: Dictionary) -> Dictionary:
	var provider := str(ref.get("provider", ""))
	var out: Dictionary
	match provider:
		HOST_MODWORKSHOP: out = await _mwsp_get_mod(ref)
		HOST_NEXUS: out = _nxp_unsupported("host_get_mod")
		HOST_VOSTOKMODS: out = _vmp_unsupported("host_get_mod")
		_: out = _host_unwired("host_get_mod", provider)
	return _host_check_result(provider, "host_get_mod", out)


## Every downloadable version of one mod, newest first. Data is an Array of
## FileRecord. Only meaningful when caps.file_history is true.
func host_list_files(ref: Dictionary) -> Dictionary:
	var provider := str(ref.get("provider", ""))
	var out: Dictionary
	match provider:
		HOST_MODWORKSHOP: out = await _mwsp_list_files(ref)
		HOST_NEXUS: out = _nxp_unsupported("host_list_files")
		HOST_VOSTOKMODS: out = _vmp_unsupported("host_list_files")
		_: out = _host_unwired("host_list_files", provider)
	return _host_check_result(provider, "host_list_files", out)


## The one file to install for this mod. version "" means "whatever the host
## considers current"; a non-empty version pins an exact release and returns
## HOST_ERR_VERSION_NOT_FOUND rather than silently substituting another --
## silent substitution is the failure pinning exists to prevent.
func host_resolve_file(ref: Dictionary, version: String = "") -> Dictionary:
	var provider := str(ref.get("provider", ""))
	var out: Dictionary
	match provider:
		HOST_MODWORKSHOP: out = await _mwsp_resolve_file(ref, version)
		HOST_NEXUS: out = _nxp_unsupported("host_resolve_file")
		HOST_VOSTOKMODS: out = _vmp_unsupported("host_resolve_file")
		_: out = _host_unwired("host_resolve_file", provider)
	return _host_check_result(provider, "host_resolve_file", out)


## The host's category tree. Data is an Array of Category.
func host_list_categories(provider: String) -> Dictionary:
	var out: Dictionary
	match provider:
		HOST_MODWORKSHOP: out = await _mwsp_list_categories()
		HOST_NEXUS: out = _nxp_unsupported("host_list_categories")
		HOST_VOSTOKMODS: out = _vmp_unsupported("host_list_categories")
		_: out = _host_unwired("host_list_categories", provider)
	return _host_check_result(provider, "host_list_categories", out)


## Current version string for many mods at once, for the Updates tab.
##
## on_progress is called with {done: int, total: int, partial: Dictionary} as
## answers arrive, where partial holds only the newly resolved
## {ref_key -> version} pairs. Hosts without a batch endpoint resolve one mod
## per request, and against a 60-per-hour budget the difference between
## streaming and a single terminal result is sixty answers versus none.
func host_latest_versions(provider: String, ids: PackedStringArray, on_progress: Callable) -> Dictionary:
	var out: Dictionary
	match provider:
		HOST_MODWORKSHOP: out = await _mwsp_latest_versions(ids, on_progress)
		HOST_NEXUS: out = _nxp_unsupported("host_latest_versions")
		HOST_VOSTOKMODS: out = _vmp_unsupported("host_latest_versions")
		_: out = _host_unwired("host_latest_versions", provider)
	return _host_check_result(provider, "host_latest_versions", out)


# ----- synchronous operations -----
#
# None of these may await, directly or transitively. They are called from
# widget construction and from functions that return a value, not a coroutine.

## Host name as it should appear in user-facing copy ("ModWorkshop"). Falls
## back to the provider id so an unknown host still reads as something rather
## than as an empty string mid-sentence.
func host_display_name(provider: String) -> String:
	match provider:
		HOST_MODWORKSHOP: return "ModWorkshop"
		HOST_NEXUS: return "Nexus Mods"
		HOST_VOSTOKMODS: return "VostokMods"
		_: return provider


func host_caps(provider: String) -> Dictionary:
	match provider:
		HOST_MODWORKSHOP: return _mwsp_caps()
		HOST_NEXUS: return _nxp_caps()
		HOST_VOSTOKMODS: return _vmp_caps()
		_: return host_empty_caps()


## Browser URL for a mod's page, or "" when the host has none -- in which case
## the UI hides the button rather than opening a dead link.
func host_mod_page_url(ref: Dictionary) -> String:
	if not host_ref_valid(ref):
		return ""
	match str(ref["provider"]):
		HOST_MODWORKSHOP: return _mwsp_mod_page_url(str(ref["id"]))
		HOST_NEXUS: return _nxp_mod_page_url(str(ref["id"]))
		HOST_VOSTOKMODS: return _vmp_mod_page_url(str(ref["id"]))
		_: return ""


## Let the adapter read its own rate-limit dialect off a completed response and
## arm the cooldown. Called by the transport on every response, including
## successful ones, because most hosts report a remaining budget on 2xx and
## waiting for the 429 wastes the request that would have told us.
func host_note_rate_headers(provider: String, status: int, headers: PackedStringArray) -> void:
	match provider:
		HOST_MODWORKSHOP: _mwsp_note_rate_headers(status, headers)
		HOST_NEXUS: _nxp_note_rate_headers(status, headers)
		HOST_VOSTOKMODS: _vmp_note_rate_headers(status, headers)


## Non-boolean provider policy: sorts, landing sections, and limits.
func _host_scalars(provider: String) -> Dictionary:
	match provider:
		HOST_MODWORKSHOP: return _mwsp_scalars()
		HOST_NEXUS: return _nxp_scalars()
		HOST_VOSTOKMODS: return _vmp_scalars()
		_: return host_empty_scalars()


# ----- typed accessors over _host_scalars -----

func host_limit(provider: String, key: String, fallback: int) -> int:
	var v: Variant = _host_scalars(provider).get(key)
	return int(v) if v is int else fallback


## Sort options as [{key, label}], in menu order. Empty means this host offers
## no sorting and the control is hidden.
func host_sorts(provider: String) -> Array:
	var v: Variant = _host_scalars(provider).get("sorts")
	return v if v is Array else []


## Landing-page sections as [{key, title, sort_key, limit}]. Empty means the
## Browse tab opens straight into the full listing.
func host_sections(provider: String) -> Array:
	var v: Variant = _host_scalars(provider).get("landing_sections")
	return v if v is Array else []


## One-line status for a failed call: the rate-limit message when a cooldown is
## running (overwhelmingly the likely cause), otherwise the caller's own copy.
func host_error_status(provider: String, fallback: String) -> String:
	var secs := host_rate_cooldown_seconds(provider)
	if secs <= 0:
		return fallback
	return "%s rate limit reached. Try again in %ds." % [host_display_name(provider), secs]


## Human-readable copy for a HostResult failure. Adapters set `message` for
## anything host-specific; this supplies the wording for the codes every host
## shares, so each call site stops inventing its own.
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

## Result for an operation with no arm for this provider. Distinct from
## HOST_ERR_UNSUPPORTED, which is a provider deliberately declaring a
## capability off: reaching here means the caps say yes and the wiring says no,
## which is our bug and is logged as one.
func _host_unwired(op: String, provider: String) -> Dictionary:
	_log_warning("[Host] %s has no arm for provider '%s'" % [op, provider])
	return host_err(HOST_ERR_UNWIRED, 0, "%s is not implemented for %s" % [op, provider])


## Last line of defence at the seam: an adapter that returns something other
## than a HostResult fails here, with the operation named, instead of failing
## three frames later when a caller indexes ["ok"] on garbage.
func _host_check_result(provider: String, op: String, out: Variant) -> Dictionary:
	if out is Dictionary and (out as Dictionary).has("ok"):
		return out
	_log_warning("[Host] %s (%s) returned a malformed result" % [op, provider])
	return host_err(HOST_ERR_BAD_RESPONSE, 0, "malformed adapter result")
