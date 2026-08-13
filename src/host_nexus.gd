## ----- host_nexus.gd -----
## Nexus Mods adapter (nexusmods.com/roadtovostok).
##
## STATUS: link-out only, by policy rather than by gap, and permanently.
## Nexus has an API, but its keys are personal per-user credentials and
## automated downloading is restricted, so this provider will never list,
## search, resolve or download. It declares exactly one capability, page_url:
## given "nexus:<int>" it composes the public mod-page URL. That single true
## flag is a real, supported state -- a mod installed by hand from Nexus
## keeps its provenance, its page stays one click away, and every control
## that would need the network stays hidden because every other capability
## is honestly false.
##
## WARNING to future contributors -- do not "finish" this adapter:
##   - no scraping: never fetch or parse nexusmods.com pages, in any form
##   - no embedded API key: Nexus keys are personal credentials; shipping one
##     in a public loader both leaks a credential and violates their terms
##   - no automated downloads: restricted by Nexus policy; "Open page" is the
##     entire install story for this host
## If Nexus ever ships an application-friendly integration path, that is a
## new design conversation with its own review, not a patch to this file.

## Road to Vostok's section of the site (Metro Mod Loader itself is mod 20
## there). The game domain is baked into the template because this loader
## only loads RTV mods, which is what lets the id stay a bare integer.
const NEXUS_PAGE_URL_TEMPLATE := "https://www.nexusmods.com/roadtovostok/mods/%s"


func _nxp_caps() -> Dictionary:
	var caps := host_empty_caps()
	caps["page_url"] = true
	# Everything else stays false by policy, not because it is unbuilt or
	# unconfirmed. The UI consequences ARE the design: no Browse entry, no
	# update check, no Download button, no metric chips -- just the link.
	return caps


func _nxp_scalars() -> Dictionary:
	# Defaults untouched: no operation on this provider ever reads them.
	# Empty sorts and landing_sections are the supported "renders nothing"
	# state, and the limits gate requests that are never made.
	return host_empty_scalars()


## Only a bare positive decimal id composes a URL. OS.shell_open is
## ShellExecute on Windows (see the description-link note in ui.gd), so a
## hand-authored id like "51/../x" or a pasted full URL must yield no button
## at all, never a composed string handed to the shell.
func _nxp_mod_page_url(id: String) -> String:
	if not id.is_valid_int() or id.to_int() <= 0:
		return ""
	return NEXUS_PAGE_URL_TEMPLATE % str(id.to_int())


## Unreachable in practice: this adapter never issues a request, so the
## transport never has a nexus response to report. The arm exists so
## host_note_rate_headers keeps one arm per provider and an audit of the
## dispatch finds no hole.
func _nxp_note_rate_headers(_status: int, _headers: PackedStringArray) -> void:
	pass


## Result for every network operation. Unlike _vmp_unsupported this is not
## "endpoint not documented yet" -- it is a permanent, deliberate refusal,
## and the copy points at the one thing that does work.
func _nxp_unsupported(op: String) -> Dictionary:
	return host_err(HOST_ERR_UNSUPPORTED, 0,
			"Nexus Mods is link-out only; %s cannot be served. Use the mod's Nexus page instead." % op)
