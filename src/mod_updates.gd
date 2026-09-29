## Installed mod update checks and the result state consumed by the Mods tab.
## Uses host-qualified sources and version rules shared with discovery.

# Update check for every installed mod with a downloadable host and a version.
# Populates _mod_updates_state. Returns {checked, with_updates, errors,
# no_version, providers}: the last two are the mods skipped for declaring no
# version and the hosts that were asked.
func _run_updates_check_for_mods() -> Dictionary:
	if _mod_updates_check_in_progress:
		return {"checked": 0, "with_updates": 0, "errors": 0}
	_mod_updates_check_in_progress = true
	var skipped := {}
	var pending := _updates_check_candidates(_ui_mod_entries, _get_persisted_mod_sources(), skipped)
	var summary := {"checked": 0, "with_updates": 0, "errors": 0}
	var providers: Array = []
	if not pending.is_empty():
		var refs: Array = []
		for p in pending:
			var ref: Dictionary = (p as Dictionary)["ref"]
			refs.append(ref)
			if not providers.has(str(ref["provider"])):
				providers.append(str(ref["provider"]))
		summary = _updates_check_apply(pending, await fetch_latest_versions(refs))
	summary["no_version"] = int(skipped.get("no_version", 0))
	summary["providers"] = providers
	_mod_updates_check_in_progress = false
	return summary

# The toast for a finished update check. Errored checks are reported, not
# counted as up to date; when every check failed while a host's rate-limit
# cooldown is running, that is the reason given.
func _updates_check_message(summary: Dictionary, providers: Array) -> String:
	var n := int(summary.get("with_updates", 0))
	var ck := int(summary.get("checked", 0))
	var er := int(summary.get("errors", 0))
	var no_version := int(summary.get("no_version", 0))
	if ck == 0:
		if no_version > 0:
			return "Nothing to check: %d mod(s) name a site but no version, so there is nothing to compare." % no_version
		return "No installed mods say where they came from, so there is nothing to check."
	if er >= ck:
		var msg := "Could not check any mods. Check your connection and try again."
		for provider in providers:
			msg = host_error_status(str(provider), msg)
		return msg
	var tail := ""
	if er > 0:
		tail += " %d could not be checked." % er
	if no_version > 0:
		tail += " %d skipped for having no version." % no_version
	if n == 0:
		return "Everything is up to date. Checked %d mod(s).%s" % [ck - er, tail]
	return "%d update(s) available.%s" % [n, tail]

# The installed mods an update check asks about, as {profile_key, ref,
# version, full_path, mod_name}. Skipped: a mod with no readable mod.txt, a
# developer folder (a downloaded archive would land beside it), a mod with no
# host or a host that cannot serve files, and a mod with no declared version.
func _updates_check_candidates(entries: Array[Dictionary], persisted_sources: Dictionary, skipped: Dictionary = {}) -> Array:
	var pending: Array = []
	for entry in entries:
		var cfg: ConfigFile = entry.get("cfg")
		if cfg == null:
			continue
		if str(entry.get("ext", "")) == "folder":
			continue
		var ref := _entry_host_ref(entry, persisted_sources)
		if ref.is_empty() or not bool(host_caps(str(ref["provider"]))["resolve_file"]):
			continue
		var version := str(cfg.get_value("mod", "version", "")).strip_edges()
		if version == "":
			# The one skip the player can act on; `skipped` lets the toast say so.
			skipped["no_version"] = int(skipped.get("no_version", 0)) + 1
			continue
		pending.append({
			"profile_key": str(entry.get("profile_key", "")),
			"ref": ref,
			"version": version,
			"full_path": str(entry.get("full_path", "")),
			"mod_name": str(entry.get("mod_name", "?")),
		})
	return pending

# Fold the sites' answers (host ref key -> latest version, or null) into
# _mod_updates_state and return {checked, with_updates, errors}. A missing
# answer is an error; an installed version that is equal or newer clears any
# stale entry; an older one records the update the row button acts on.
func _updates_check_apply(pending: Array, latest: Dictionary) -> Dictionary:
	var summary := {"checked": 0, "with_updates": 0, "errors": 0}
	for p in pending:
		summary["checked"] += 1
		var info: Dictionary = p
		var raw = latest.get(host_ref_key(info["ref"]), null)
		if raw == null:
			summary["errors"] += 1
			continue
		var latest_v := str(raw)
		if latest_v.is_empty():
			continue
		if compare_versions(str(info["version"]), latest_v) >= 0:
			_mod_updates_state.erase(info["profile_key"])
			continue
		summary["with_updates"] += 1
		_mod_updates_state[info["profile_key"]] = {
			"latest_version": latest_v,
			"current_version": info["version"],
			"ref": info["ref"],
			"full_path": info["full_path"],
			"mod_name": info["mod_name"],
		}
	return summary
