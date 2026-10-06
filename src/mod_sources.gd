## Mod host identity on disk: mod.txt, mod_config.cfg and profile.json.
## The source precedence and serialization are shared by discovery and downloads.

# ----- provider-qualified mod sources ------------------------------------
# Canonical record: {"provider", "id", "version"}, every field present;
# provider "" is the single "no source" test. Three disk surfaces carry it:
#   mod.txt [updates]      source="<provider>:<id>", plus legacy modworkshop=<int>
#   mod_config.cfg         [mod_sources] <profile_key> = <json>
#   modpack profile.json   "sources": {<profile_key>: <record>}
# The JSON record is {provider, id, modworkshop_id?, version?}; modworkshop_id
# is a compat mirror emitted only for ModWorkshop, since a pre-source loader
# reading it on another host's record would download the wrong mod.
# When mod.txt and the stored record disagree, _resolve_mod_source ranks them.

## mod.txt `source=` value -> canonical record (version ""), {} on reject.
## Delegates to host_ref_from_key; bare no-colon values are rejected, not defaulted.
func _parse_source_token(raw: String) -> Dictionary:
	var ref := host_ref_from_key(raw.strip_edges())
	if ref.is_empty():
		return {}
	var provider := str(ref["provider"])
	var id := str(ref["id"])
	# Canonicalize a ModWorkshop id like the legacy path, or update checks never match.
	if provider == HOST_MODWORKSHOP and id.is_valid_int():
		id = str(id.to_int())
	return {"provider": provider, "id": id, "version": ""}


## The one reader of a mod.txt source declaration. source= wins; a malformed
## one falls through to legacy modworkshop=, which must be a pure integer
## (to_int() would mint id 12 out of "12abc"). The record carries a fourth
## key, `explicit`: true when it came from source=, false for the legacy key
## or no declaration. _resolve_mod_source ranks the two differently.
func _mod_source_from_cfg(cfg: ConfigFile) -> Dictionary:
	if cfg == null:
		return {"provider": "", "id": "", "version": "", "explicit": false}
	var version := str(cfg.get_value("mod", "version", "")).strip_edges()
	if cfg.has_section_key("updates", "source"):
		var rec := _parse_source_token(str(cfg.get_value("updates", "source", "")))
		if not rec.is_empty():
			rec["version"] = version
			rec["explicit"] = true
			return rec
	if cfg.has_section_key("updates", "modworkshop"):
		var legacy := str(cfg.get_value("updates", "modworkshop", "")).strip_edges()
		if legacy.is_valid_int() and legacy.to_int() > 0:
			# Round-trip through int so "0123" and "+123" normalize to the wire id.
			return {"provider": HOST_MODWORKSHOP, "id": str(legacy.to_int()), "version": version, "explicit": false}
	return {"provider": "", "id": "", "version": "", "explicit": false}


## Rank a mod.txt declaration (from _mod_source_from_cfg) against the stored
## [mod_sources] record for the same mod (normalized, or {}). An explicit
## source= wins. Otherwise the stored record wins: the launcher wrote it at
## download or pack-install time, so it names the host the file came from,
## while a legacy modworkshop= line is what vostokmods.net serves in every
## file. Legacy is used only when nothing is stored. Returns the canonical
## {provider, id, version}, provider "" when neither names a host.
func _resolve_mod_source(declared: Dictionary, stored: Dictionary) -> Dictionary:
	var from_mod_txt := {
		"provider": str(declared.get("provider", "")),
		"id": str(declared.get("id", "")),
		"version": str(declared.get("version", "")),
	}
	if bool(declared.get("explicit", false)) and from_mod_txt["provider"] != "":
		return from_mod_txt
	if str(stored.get("provider", "")) != "":
		return {
			"provider": str(stored["provider"]),
			"id": str(stored.get("id", "")),
			"version": str(stored.get("version", "")),
		}
	return from_mod_txt


## The host reference an installed mod resolves to, or {} when it has none.
## `persisted` is _get_persisted_mod_sources().
func _entry_host_ref(entry: Dictionary, persisted: Dictionary) -> Dictionary:
	var rec := _entry_source_record(entry, persisted)
	if str(rec["provider"]) == "":
		return {}
	return host_ref(str(rec["provider"]), str(rec["id"]))


## The full source record behind _entry_host_ref: {provider, id, version},
## provider "" when the mod has no known host. _resolve_mod_source ranks the
## mod.txt declaration against the stored record.
func _entry_source_record(entry: Dictionary, persisted: Dictionary) -> Dictionary:
	var declared := _mod_source_from_cfg(entry.get("cfg"))
	var stored := _normalize_source_record(persisted.get(str(entry.get("profile_key", ""))))
	return _resolve_mod_source(declared, stored)


## Every ref key an installed mod answers to: the one _entry_host_ref
## resolves, then the ids its host is known to give the same mod. The
## Mods-tab memo holds the id a host answered a detail under (asked by UUID,
## answered by slug), and host_ref_aliases the pairs host responses carried.
## A pack or a Browse row matched against these finds the mod whichever id
## it was written with. Empty when the mod has no host.
func _entry_ref_keys(entry: Dictionary, persisted: Dictionary) -> PackedStringArray:
	var keys := PackedStringArray()
	var primary := host_ref_key(_entry_host_ref(entry, persisted))
	if primary == "":
		return keys
	keys.append(primary)
	_mods_meta_sidecar_load()
	var meta_v: Variant = _mods_meta_by_key.get(primary)
	if meta_v is Dictionary and (meta_v as Dictionary).get("ref") is Dictionary:
		var answered := host_ref_key((meta_v as Dictionary)["ref"])
		if answered != "" and not keys.has(answered):
			keys.append(answered)
	for known in keys.duplicate():
		for alias in host_ref_aliases(known):
			if not keys.has(str(alias)):
				keys.append(str(alias))
	return keys


## Normalize a [mod_sources]/profile.json record of either era. With a
## "provider" key present, modworkshop_id is never consulted, even as a fallback.
func _normalize_source_record(v: Variant) -> Dictionary:
	if not (v is Dictionary):
		return {"provider": "", "id": "", "version": ""}
	var rec: Dictionary = v
	var ver_raw: Variant = rec.get("version", "")
	var version := str(ver_raw) if ver_raw is String else ""
	if rec.has("provider"):
		var provider := str(rec.get("provider", ""))
		var id := str(rec.get("id", "")).strip_edges()
		if HOST_PROVIDERS_KNOWN.has(provider) and not id.is_empty():
			# Same id canonicalization as the legacy path.
			if provider == HOST_MODWORKSHOP and id.is_valid_int():
				id = str(id.to_int())
			return {"provider": provider, "id": id, "version": version}
		return {"provider": "", "id": "", "version": ""}
	# Legacy {"modworkshop_id": N}: floats from JSON, and hand-edited packs have
	# carried null and quoted ids. Only ints, floats and pure-integer strings count.
	var mws_raw: Variant = rec.get("modworkshop_id", 0)
	var mws_id := 0
	if mws_raw is int:
		mws_id = mws_raw
	elif mws_raw is float:
		mws_id = int(mws_raw)
	elif mws_raw is String and str(mws_raw).strip_edges().is_valid_int():
		mws_id = str(mws_raw).strip_edges().to_int()
	if mws_id > 0:
		return {"provider": HOST_MODWORKSHOP, "id": str(mws_id), "version": version}
	return {"provider": "", "id": "", "version": ""}


## A record's ModWorkshop integer id, or 0; the only place a record becomes an int.
func _source_mws_id(rec: Dictionary) -> int:
	if str(rec.get("provider", "")) != HOST_MODWORKSHOP:
		return 0
	var id := str(rec.get("id", ""))
	if not id.is_valid_int():
		return 0
	var n := id.to_int()
	return n if n > 0 else 0


## Payload shared by the [mod_sources] cache and profile.json. Key order is
## fixed: the persist functions diff the serialized string against the stored one.
func _mod_source_payload(rec: Dictionary) -> Dictionary:
	var payload: Dictionary = {
		"provider": str(rec.get("provider", "")),
		"id": str(rec.get("id", "")),
	}
	var mws_id := _source_mws_id(rec)
	if mws_id > 0:
		payload["modworkshop_id"] = mws_id
	var version := str(rec.get("version", ""))
	if not version.is_empty():
		payload["version"] = version
	return payload


# Dictionaries keep insertion order, so identical records serialize identically.
func _serialize_mod_source_rec(rec: Dictionary) -> String:
	return JSON.stringify(_mod_source_payload(rec))


# Whether a [mod_sources] write must stand down after mod_config.cfg failed to
# load, logging why. Both cases keep the rolling backup usable. A file that
# exists but does not parse, or is blank beside a backup (_ui_cfg_load),
# would be saved over. A missing file with a .bak
# beside it is what _load_ui_config recovers from: the scan runs before that
# load, a fresh file written here would hide the loss from it, and the next
# save would copy the near-empty file over the backup. A missing file with no
# backup is a fresh install, and the write proceeds.
func _mod_sources_write_blocked(load_err: int, what: String) -> bool:
	if load_err == OK:
		return false
	if FileAccess.file_exists(UI_CONFIG_PATH):
		_log_critical("mod_config.cfg exists but failed to load (error %d) -- skipped saving %s so the config backup stays usable. The launcher will attempt backup recovery when it loads." \
				% [load_err, what])
		return true
	if FileAccess.file_exists(UI_CONFIG_PATH + ".bak"):
		_log_info("mod_config.cfg is missing and a backup exists -- skipped saving %s until the launcher has recovered the backup." % what)
		return true
	return false

# Persist each scanned mod's source so missing-mod stubs can offer Download.
# Follows the _resolve_mod_source ranking: a legacy modworkshop= line never
# displaces a record another host's download wrote.
func _persist_mod_sources_for_entries(entries: Array[Dictionary]) -> void:
	var cfg := ConfigFile.new()
	var load_err := _ui_cfg_load(cfg)
	if _mod_sources_write_blocked(load_err, "the mod-source cache"):
		return
	var changed := false
	for entry in entries:
		var declared := _mod_source_from_cfg(entry.get("cfg"))
		if declared["provider"] == "":
			continue
		var pk: String = str(entry.get("profile_key", ""))
		if pk == "":
			continue
		var current := str(cfg.get_value("mod_sources", pk, ""))
		if not bool(declared["explicit"]) and current != "":
			var stored := _normalize_source_record(JSON.parse_string(current))
			if stored["provider"] != "" and stored["provider"] != declared["provider"]:
				continue
		var serialized := _serialize_mod_source_rec(declared)
		if current != serialized:
			cfg.set_value("mod_sources", pk, serialized)
			changed = true
	if changed:
		_persist_ui_cfg(cfg)


# Persisted [mod_sources] cache as {profile_key -> canonical record}, normalized.
func _get_persisted_mod_sources() -> Dictionary:
	var out: Dictionary = {}
	var cfg := ConfigFile.new()
	if _ui_cfg_load(cfg) != OK:
		return out
	if not cfg.has_section("mod_sources"):
		return out
	for key in cfg.get_section_keys("mod_sources"):
		var raw := str(cfg.get_value("mod_sources", key, ""))
		if raw == "":
			continue
		var rec := _normalize_source_record(JSON.parse_string(raw))
		if rec["provider"] != "":
			out[key] = rec
	return out


# Add one source entry; modpack apply records sources for mods it has not installed.
func _persist_single_mod_source(profile_key: String, rec: Dictionary) -> void:
	if profile_key.is_empty() or str(rec.get("provider", "")) == "":
		return
	var cfg := ConfigFile.new()
	var load_err := _ui_cfg_load(cfg)
	if _mod_sources_write_blocked(load_err, "the mod source for '" + profile_key + "'"):
		return
	var serialized := _serialize_mod_source_rec(rec)
	var current := str(cfg.get_value("mod_sources", profile_key, ""))
	if current != serialized:
		cfg.set_value("mod_sources", profile_key, serialized)
		_persist_ui_cfg(cfg)
