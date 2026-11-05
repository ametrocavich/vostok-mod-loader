## Where each installed mod came from: the source record and its precedence.

# The JSON mirrors the id as modworkshop_id only for ModWorkshop: a loader that
# predates source= reads that key on any record and would fetch the wrong mod.

func _parse_source_token(raw: String) -> Dictionary:
	var ref := host_ref_from_key(raw.strip_edges())
	if ref.is_empty():
		return {}
	var provider := str(ref["provider"])
	return {"provider": provider, "id": _canonical_source_id(provider, str(ref["id"])), "version": ""}

## A ModWorkshop id round-trips through int, so "0123" matches the wire id 123.
func _canonical_source_id(provider: String, id: String) -> String:
	if provider == HOST_MODWORKSHOP and id.is_valid_int():
		return str(id.to_int())
	return id

func _mod_source_from_cfg(cfg: ConfigFile) -> Dictionary:
	var none := {"provider": "", "id": "", "version": "", "explicit": false}
	if cfg == null:
		return none
	var version := _cfg_mod_version(cfg)
	if cfg.has_section_key("updates", "source"):
		var rec := _parse_source_token(str(cfg.get_value("updates", "source")))
		if not rec.is_empty():
			rec["version"] = version
			rec["explicit"] = true
			return rec
	if cfg.has_section_key("updates", "modworkshop"):
		# to_int() alone would mint id 12 out of "12abc".
		var legacy := str(cfg.get_value("updates", "modworkshop")).strip_edges()
		if legacy.is_valid_int() and legacy.to_int() > 0:
			return {"provider": HOST_MODWORKSHOP, "id": _canonical_source_id(HOST_MODWORKSHOP, legacy),
					"version": version, "explicit": false}
	return none

## Explicit source= wins, else the stored record: vostokmods.net serves legacy modworkshop= lines.
func _resolve_mod_source(declared: Dictionary, stored: Dictionary) -> Dictionary:
	var pick := declared if declared["explicit"] or stored["provider"] == "" else stored
	return {"provider": pick["provider"], "id": pick["id"], "version": pick["version"]}

func _entry_host_ref(entry: Dictionary, persisted: Dictionary) -> Dictionary:
	var rec := _entry_source_record(entry, persisted)
	if rec["provider"] == "":
		return {}
	return host_ref(rec["provider"], rec["id"])

# entry.get: the tests/ui row fixtures carry no "cfg".
func _entry_source_record(entry: Dictionary, persisted: Dictionary) -> Dictionary:
	var stored := _normalize_source_record(persisted.get(entry["profile_key"]))
	return _resolve_mod_source(_mod_source_from_cfg(entry.get("cfg")), stored)

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

func _source_record_names_ref(rec: Dictionary, ref: Dictionary) -> bool:
	if ref.is_empty() or rec["provider"] == "" or rec["provider"] != ref["provider"]:
		return false
	var want := host_ref_key(ref)
	var have := host_ref_key(host_ref(rec["provider"], rec["id"]))
	return have != "" and (have == want or host_ref_aliases(want).has(have))

# A site can label a file above its mod.txt version; the update check compares against this.
func _served_version(stored: Dictionary, ref: Dictionary, version: String) -> String:
	if _source_record_names_ref(stored, ref) and compare_versions(stored["version"], version) > 0:
		return stored["version"]
	return version

func _normalize_source_record(v: Variant) -> Dictionary:
	var none := {"provider": "", "id": "", "version": ""}
	if not (v is Dictionary):
		return none
	var rec: Dictionary = v
	var ver_raw: Variant = rec.get("version", "")
	var version := str(ver_raw) if ver_raw is String else ""
	if rec.has("provider"):
		var provider := str(rec["provider"])
		var id := str(rec.get("id", "")).strip_edges()
		if HOST_PROVIDERS_KNOWN.has(provider) and not id.is_empty():
			return {"provider": provider, "id": _canonical_source_id(provider, id), "version": version}
		return none
	# Legacy {"modworkshop_id": N}: a JSON float, or null or a quoted id in hand-edited packs.
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
	return none

func _source_mws_id(rec: Dictionary) -> int:
	if str(rec.get("provider", "")) != HOST_MODWORKSHOP:
		return 0
	var id := str(rec["id"])
	if not id.is_valid_int():
		return 0
	return maxi(id.to_int(), 0)

## Key order is fixed: the persist functions compare the serialized string with the stored one.
func _mod_source_payload(rec: Dictionary) -> Dictionary:
	var payload: Dictionary = {"provider": str(rec["provider"]), "id": str(rec["id"])}
	var mws_id := _source_mws_id(rec)
	if mws_id > 0:
		payload["modworkshop_id"] = mws_id
	if str(rec["version"]) != "":
		payload["version"] = str(rec["version"])
	return payload

func _serialize_mod_source_rec(rec: Dictionary) -> String:
	return JSON.stringify(_mod_source_payload(rec))

## A missing file beside a .bak is _load_ui_config's to recover; a write first would hide it.
func _mod_sources_write_blocked(load_err: int, what: String) -> bool:
	if load_err == OK:
		return false
	if FileAccess.file_exists(UI_CONFIG_PATH):
		_log_critical("[Config] mod_config.cfg failed to load (error %d); skipped saving %s" % [load_err, what])
		return true
	if FileAccess.file_exists(UI_CONFIG_PATH + ".bak"):
		_log_info("[Config] mod_config.cfg is missing beside a backup; skipped saving %s" % what)
		return true
	return false

func _persist_mod_sources_for_entries(entries: Array[Dictionary]) -> void:
	var cfg := ConfigFile.new()
	if _mod_sources_write_blocked(_ui_cfg_load(cfg), "the mod-source cache"):
		return
	var changed := false
	for entry in entries:
		var declared := _mod_source_from_cfg(entry["cfg"])
		if declared["provider"] == "":
			continue
		var pk: String = entry["profile_key"]
		var current := str(cfg.get_value("mod_sources", pk, ""))
		if current != "":
			var stored := _normalize_source_record(JSON.parse_string(current))
			if not declared["explicit"] and stored["provider"] != "" and stored["provider"] != declared["provider"]:
				continue
			var ref := host_ref(declared["provider"], declared["id"])
			declared["version"] = _served_version(stored, ref, declared["version"])
		var serialized := _serialize_mod_source_rec(declared)
		if current != serialized:
			cfg.set_value("mod_sources", pk, serialized)
			changed = true
	if changed:
		_persist_ui_cfg(cfg)

func _get_persisted_mod_sources() -> Dictionary:
	var out: Dictionary = {}
	var cfg := ConfigFile.new()
	if _ui_cfg_load(cfg) != OK or not cfg.has_section("mod_sources"):
		return out
	for key in cfg.get_section_keys("mod_sources"):
		var raw := str(cfg.get_value("mod_sources", key))
		if raw == "":
			continue
		var rec := _normalize_source_record(JSON.parse_string(raw))
		if rec["provider"] != "":
			out[key] = rec
	return out

func _persist_single_mod_source(profile_key: String, rec: Dictionary) -> void:
	if rec["provider"] == "":
		return
	var cfg := ConfigFile.new()
	if _mod_sources_write_blocked(_ui_cfg_load(cfg), "the mod source for '" + profile_key + "'"):
		return
	var serialized := _serialize_mod_source_rec(rec)
	if str(cfg.get_value("mod_sources", profile_key, "")) != serialized:
		cfg.set_value("mod_sources", profile_key, serialized)
		_persist_ui_cfg(cfg)
