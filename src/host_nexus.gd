## ----- host_nexus.gd -----
## Nexus Mods adapter (nexusmods.com/roadtovostok): link-out only, by policy,
## permanently. Nexus API keys are personal per-user credentials and
## automated downloading is restricted, so the one capability is page_url:
## "nexus:<int>" composes the public mod-page URL.
##
## Do not "finish" this adapter: no scraping, no embedded API key (a leaked
## credential and a terms violation), no automated downloads. An
## application-friendly Nexus integration would be a new design, not a patch.

## The game domain is baked in (this loader only loads RTV mods), so the id
## stays a bare integer.
const NEXUS_PAGE_URL_TEMPLATE := "https://www.nexusmods.com/roadtovostok/mods/%s"


func _nxp_caps() -> Dictionary:
	var caps := host_empty_caps()
	caps["page_url"] = true
	# Everything else stays false by policy, not because it is unbuilt.
	return caps


func _nxp_scalars() -> Dictionary:
	# Defaults untouched: no operation on this provider ever reads them.
	return host_empty_scalars()


## Only a bare positive decimal id composes a URL. OS.shell_open is
## ShellExecute on Windows (see ui.gd), so an id like "51/../x" or a pasted
## full URL must yield no button, never a composed string handed to the shell.
func _nxp_mod_page_url(id: String) -> String:
	if not id.is_valid_int() or id.to_int() <= 0:
		return ""
	return NEXUS_PAGE_URL_TEMPLATE % str(id.to_int())


## Unreachable in practice (this adapter never issues requests); exists so
## host_note_rate_headers keeps one arm per provider.
func _nxp_note_rate_headers(_status: int, _headers: PackedStringArray) -> void:
	pass


## Result for every network operation: a permanent refusal, with copy
## pointing at the one thing that does work.
func _nxp_unsupported(op: String) -> Dictionary:
	return host_err(HOST_ERR_UNSUPPORTED, 0,
			"Nexus Mods is link-out only; %s cannot be served. Use the mod's Nexus page instead." % op)
