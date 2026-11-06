## Update checks for installed mods, and the _mod_updates_state the Mods tab
## reads.

## Check every installed mod with a downloadable host and a version, then every site pack.
## Returns {checked, with_updates, errors, no_version, providers} plus the pack counts.
func _run_updates_check_for_mods() -> Dictionary:
	if _mod_updates_check_in_progress:
		return {"checked": 0, "with_updates": 0, "errors": 0, "no_version": 0, "providers": [],
				"packs_checked": 0, "packs_changed": 0, "packs_failed": 0, "active_pack_changed": ""}
	_mod_updates_check_in_progress = true
	var candidates := _updates_check_candidates(_ui_mod_entries, _get_persisted_mod_sources())
	var pending: Array = candidates["pending"]
	var summary := {"checked": 0, "with_updates": 0, "errors": 0}
	var providers: Array = []
	if not pending.is_empty():
		var refs: Array = []
		for p in pending:
			refs.append(p["ref"])
			if not providers.has(p["ref"]["provider"]):
				providers.append(p["ref"]["provider"])
		summary = _updates_check_apply(pending, await fetch_latest_versions(refs))
	summary["no_version"] = candidates["no_version"]
	summary["providers"] = providers
	summary.merge({"packs_checked": 0, "packs_changed": 0, "packs_failed": 0, "active_pack_changed": ""})
	# A pack from the site has changed when its manifest hash moved.
	var active := get_active_modpack()
	for entry in collect_modpack_metadata():
		var url := _pack_manifest_url(entry["hosted"])
		if url.is_empty():
			continue
		var res := await _vmp_fetch_modpack_manifest(url)
		if not res["ok"]:
			summary["packs_failed"] += 1
			_log_warning("[Updates] pack %s check failed: %s"
					% [entry["file_name"], host_error_message(HOST_VOSTOKMODS, res)])
			continue
		summary["packs_checked"] += 1
		# A served pack with no hash cannot be compared, so it counts as changed, as on import.
		var served := _host_str(res["data"].get("hash"))
		if served != "" and served == _host_str(entry["hosted"].get("hash")):
			continue
		summary["packs_changed"] += 1
		if entry["sanitized_name"] == active:
			summary["active_pack_changed"] = entry["raw_name"]
	_mod_updates_check_in_progress = false
	return summary

## {ref_key: latest version} for many mods, one request batch per host; a mod
## with no answer could not be checked.
func fetch_latest_versions(refs: Array) -> Dictionary:
	var ids_by_provider: Dictionary = {}
	for ref_v in refs:
		if not host_ref_valid(ref_v):
			continue
		var provider := str(ref_v["provider"])
		var ids: PackedStringArray = ids_by_provider.get(provider, PackedStringArray())
		var id := str(ref_v["id"])
		if not ids.has(id):
			ids.append(id)
		ids_by_provider[provider] = ids
	var out := {}
	for provider in ids_by_provider:
		var res := await host_latest_versions(provider, ids_by_provider[provider])
		if res["ok"]:
			out.merge(res["data"], true)
		else:
			_log_warning("[Updates] %s version check failed: %s"
					% [host_display_name(provider), host_error_message(provider, res)])
	return out

## The toast for a finished check. When every check failed during a host's
## rate-limit cooldown, the cooldown is the reason given.
func _updates_check_message(summary: Dictionary) -> String:
	var updates: int = summary["with_updates"]
	var checked: int = summary["checked"]
	var errors: int = summary["errors"]
	var no_version: int = summary["no_version"]
	var msg := ""
	if checked == 0:
		if no_version > 0:
			msg = "Nothing to check: %d mod(s) name a site but no version, so there is nothing to compare." % no_version
		else:
			msg = "No installed mods say where they came from, so there is nothing to check."
	elif errors >= checked:
		msg = "Could not check any mods. Check your connection and try again."
		for provider in summary["providers"]:
			msg = host_error_status(str(provider), msg)
	else:
		var tail := ""
		if errors > 0:
			tail += " %d could not be checked." % errors
		if no_version > 0:
			tail += " %d skipped for having no version." % no_version
		if updates == 0:
			msg = "Everything is up to date. Checked %d mod(s).%s" % [checked - errors, tail]
		else:
			msg = "%d update(s) available.%s" % [updates, tail]
	# T22 hands in summaries from before the pack probe.
	var changed: int = summary.get("packs_changed", 0)
	if changed > 0:
		msg += " %d pack(s) changed; Refresh them on the Modpacks tab." % changed
	var active: String = summary.get("active_pack_changed", "")
	if active != "":
		msg += " Unload %s before you refresh it." % active
	var failed: int = summary.get("packs_failed", 0)
	if failed > 0 and summary.get("packs_checked", 0) == 0:
		msg += " Could not check %d pack(s) on Vostok Mods." % failed
	return msg

## {pending, no_version}: one {profile_key, ref, version, full_path, mod_name}
## per mod to ask about. Skipped: no mod.txt, a developer folder, no host that
## serves files, and no version (counted, since the player can fix it).
func _updates_check_candidates(entries: Array[Dictionary], persisted_sources: Dictionary) -> Dictionary:
	var pending: Array = []
	var no_version := 0
	for entry in entries:
		var cfg: ConfigFile = entry["cfg"]
		if cfg == null or entry["ext"] == "folder":
			continue
		var ref := _entry_host_ref(entry, persisted_sources)
		if ref.is_empty() or not bool(host_caps(ref["provider"])["resolve_file"]):
			continue
		var version := _cfg_mod_version(cfg)
		if version == "":
			no_version += 1
			continue
		# Unless the served version wins here, the same file is offered forever.
		var stored := _normalize_source_record(persisted_sources.get(entry["profile_key"]))
		version = _served_version(stored, ref, version)
		pending.append({
			"profile_key": entry["profile_key"],
			"ref": ref,
			"version": version,
			"full_path": entry["full_path"],
			"mod_name": entry["mod_name"],
		})
	return {"pending": pending, "no_version": no_version}

## Fold the hosts' answers ({ref_key: latest version}) into _mod_updates_state.
## Returns {checked, with_updates, errors}; an absent answer is an error.
func _updates_check_apply(pending: Array, latest: Dictionary) -> Dictionary:
	var summary := {"checked": 0, "with_updates": 0, "errors": 0}
	for info: Dictionary in pending:
		summary["checked"] += 1
		var raw: Variant = latest.get(host_ref_key(info["ref"]))
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
