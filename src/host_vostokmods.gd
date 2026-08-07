## ----- host_vostokmods.gd -----
## VostokMods adapter (vostokmods.net).
##
## STATUS: listing only. VostokMods publishes no API documentation, and its
## robots.txt disallows /api to automated clients, so nothing here was
## reverse-engineered by probing. Every field below was read off a single
## response to GET /api/mods, which is the whole of what is confirmed:
##
##   {"mods":[{"id":4,"slug":"example","name":"Example","author":"Ovrrde",
##     "categories":[{"slug":"category-1","name":"Category 1"}],
##     "thumbnailUrl":"https://files.vostokmods.net/mods/4/screenshots/...png",
##     "downloadsCount":1,"followersCount":1,
##     "updatedAt":"2026-08-07T06:05:11.420Z"}],
##    "total":1,"page":1,"pageCount":1}
##
## Detail, file history, version resolution and download are therefore
## UNSUPPORTED rather than guessed: their dispatch arms in host_api.gd return
## _vmp_unsupported until the site's maintainer supplies the endpoints. A mod
## cannot be installed from this host yet, and the UI will say so rather than
## offering a button that can only fail.
##
## What is genuinely unknown, in the order it needs answering:
##   1. the mod-detail endpoint, and whether a download url appears in it
##   2. how versions are expressed (the listing has no version field at all)
##   3. the search and sort parameters, if any
##   4. whether categories can be filtered on, and how tags are distinguished
##      from categories -- the listing mixes both into one `categories` array
##   5. the public mod-page URL (/mods/example and /mods/4 both 404)

const VM_API_BASE := "https://vostokmods.net/api"

# Listing responses are small, but the tab is re-entered often enough that a
# short cache saves a request per sort flip. Matches the ModWorkshop TTL.
const _VM_TTL_LIST_MS := 5 * 60 * 1000


func _vmp_caps() -> Dictionary:
	var caps := host_empty_caps()
	caps["browse"] = true
	caps["total_count"] = true
	caps["metrics"] = PackedStringArray(["downloads"])
	# Everything else stays false. search, categories, file_history,
	# version_pin and page_url are not "not built yet" -- they are unconfirmed,
	# and declaring a capability the host may not have would put controls in
	# the UI that fail when pressed.
	return caps


func _vmp_scalars() -> Dictionary:
	var s := host_empty_scalars()
	# No sort parameter is known, so the Browse tab renders no sort control
	# and no landing sections for this host: it opens straight into the
	# listing. Both empty arrays are a supported state, not a placeholder.
	s["sorts"] = []
	s["landing_sections"] = []
	# The one observed response returned every row it had, so the real page
	# size is unknown. The seam only uses this to size its own requests, and
	# the host reports pageCount regardless, so a wrong guess costs nothing.
	s["page_size"] = 50
	return s


## No confirmed public page URL: /mods/example and /mods/4 both answer 404, so
## the site's routes are not derivable from the listing payload. Returning ""
## hides the button rather than opening a dead link.
func _vmp_mod_page_url(_id: String) -> String:
	return ""


## No rate-limit headers were present on the observed response, and the site
## sits behind Cloudflare, whose limits are not announced in-band. The
## transport still arms a default cooldown on any 429 it sees; there is simply
## no header dialect to read ahead of one.
func _vmp_note_rate_headers(_status: int, _headers: PackedStringArray) -> void:
	pass


## Result for an operation whose endpoint is not documented yet. Distinct from
## HOST_ERR_UNWIRED, which means the capability claims to exist and the wiring
## is missing -- our bug. This is the honest "we do not know the endpoint".
func _vmp_unsupported(op: String) -> Dictionary:
	return host_err(HOST_ERR_UNSUPPORTED, 0,
			"VostokMods has not published the endpoint %s needs" % op)


## Listing row -> ModSummary.
##
## The host reports followersCount, which is deliberately NOT mapped onto
## `likes`: a follow is a subscription, not an endorsement, and rendering it
## as likes would misreport the number to users comparing hosts.
func _vmp_summary(v: Variant) -> Dictionary:
	var s := host_empty_summary()
	if not (v is Dictionary):
		return s
	var row: Dictionary = v
	var id := _host_id_str(row.get("id", ""))
	if id.is_empty():
		return s
	s["ref"] = host_ref(HOST_VOSTOKMODS, id)
	s["name"] = str(row.get("name", ""))
	if s["name"] == "":
		s["name"] = id
	# `author` is a bare display string here, not a user object.
	s["author_name"] = str(row.get("author", ""))
	s["downloads"] = _host_count(row.get("downloadsCount"))
	s["updated_at"] = str(row.get("updatedAt", ""))
	# The categories array mixes categories and tags with no field telling
	# them apart, so the first entry is shown and the rest are dropped, which
	# is what the single-category row layout can display anyway.
	var cats: Variant = row.get("categories")
	if cats is Array and not (cats as Array).is_empty():
		var first: Variant = (cats as Array)[0]
		if first is Dictionary:
			s["category_name"] = str((first as Dictionary).get("name", ""))
	# thumbnailUrl is already absolute, so there is no URL to compose and no
	# separate thumbnail size. The empty cache_key means "do not write this to
	# the disk cache": the filename carries an upload timestamp and looks
	# stable, but the host has promised nothing, and serving a stale image
	# from disk forever is worse than re-fetching one.
	s["thumbnail"] = host_image(str(row.get("thumbnailUrl", "")), "", "")
	return s


## The only confirmed operation.
##
## `query`, `sort_key` and `category_ref` are accepted and ignored: the host's
## parameter names are unknown, and passing a guessed one would silently
## return an unfiltered listing that looks like a working search. caps.search
## and caps.categories are false so the UI does not offer either.
func _vmp_list_mods(q: Dictionary) -> Dictionary:
	# Page number inferred from the response's own `page` / `pageCount`
	# fields, not from a documented parameter. If it turns out to be wrong,
	# the first page is returned repeatedly and has_more terminates the walk.
	var page := maxi(1, str(q.get("cursor", "")).to_int())
	var url := VM_API_BASE + "/mods" + _hnet_query({"page": page})

	var res := await _hnet_get_json(HOST_VOSTOKMODS, url, _VM_TTL_LIST_MS)
	if not res["ok"]:
		return res
	var payload: Variant = res["data"]
	if not (payload is Dictionary):
		return host_err(HOST_ERR_BAD_RESPONSE, 0, "VostokMods sent an unexpected response")
	var body: Dictionary = payload

	var raw_rows: Variant = body.get("mods")
	var rows := []
	if raw_rows is Array:
		for row in (raw_rows as Array):
			var summary := _vmp_summary(row)
			if host_ref_valid(summary["ref"]):
				rows.append(summary)

	var page_count := _host_count(body.get("pageCount"))
	var has_more := page_count > page
	return host_ok(host_page(rows, has_more, str(page + 1) if has_more else "",
			_host_count(body.get("total"))))
