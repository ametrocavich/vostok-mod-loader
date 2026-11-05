## Vostok Mods modpacks: a site manifest becomes an ordinary local pack zip in mods/.

const HOSTED_PACK_FILE_PREFIX := "vostokmods-"
# Pack keys are vostokmods:<slug> until the apply-time reconcile rewrites them.
const HOSTED_KEY_PREFIX := "vostokmods:"
const MCM_MAX_FILES := 32
const MCM_MAX_BYTES := 65536
const MCM_EXTENSIONS := ["ini", "json", "cfg"]
const PACK_APPLY_BUSY := "Wait for the current apply to finish."

## Pack key to the mod name a manifest gave this session, for the failure rows.
var _pack_mod_names: Dictionary = {}

func _hosted_manifest_to_profile(manifest: Dictionary) -> Dictionary:
	var warnings := PackedStringArray()
	var enabled := {}
	var priority := {}
	var sources := {}
	var unavailable := {}
	var checksums := {}
	var order := 0
	for m_v in manifest["mods"]:
		if not (m_v is Dictionary):
			continue
		var m: Dictionary = m_v
		var slug := _host_str(m.get("slug")).strip_edges()
		if slug.is_empty():
			warnings.append("a mod entry with no slug was skipped")
			continue
		order += 1
		var key := HOSTED_KEY_PREFIX + slug
		var load_order := _host_count(m.get("loadOrder"))
		enabled[key] = true
		priority[key] = clampi(load_order if load_order > 0 else order, PRIORITY_MIN, PRIORITY_MAX)
		if not _json_truthy(m.get("available", true)):
			unavailable[key] = _host_str(m.get("reason")).strip_edges()
			continue
		var rec := {"provider": HOST_VOSTOKMODS, "id": slug}
		var version := _host_str(m.get("version")).strip_edges()
		if version != "":
			rec["version"] = version
		sources[key] = rec
		var sha := _host_str(m.get("sha256")).strip_edges().to_lower()
		if sha.length() == 64:
			checksums[key] = sha
	var profile := {
		"metroprofile": 1,
		"name": _host_str(manifest.get("name")).strip_edges(),
		"modloader_version": MODLOADER_VERSION,
		"exported_at": _host_str(manifest.get("updatedAt")),
		"enabled": enabled,
		"priority": priority,
	}
	var summary := _host_str(manifest.get("summary")).strip_edges()
	if summary != "":
		profile["description"] = summary
	var author := _host_str(manifest.get("ownerDisplayName")).strip_edges()
	if author != "":
		profile["author"] = author
	if not sources.is_empty():
		profile["sources"] = sources
	if not unavailable.is_empty():
		profile["unavailable"] = unavailable
	if not checksums.is_empty():
		profile["checksums"] = checksums
	var cover := _host_str(manifest.get("thumbnailUrl")).strip_edges()
	profile["hosted"] = {
		"provider": HOST_VOSTOKMODS,
		"slug": _host_str(manifest.get("slug")).strip_edges().to_lower(),
		"url": _host_str(manifest.get("url")),
		"manifest_url": _host_str(manifest.get("manifest_url")),
		"hash": _host_str(manifest.get("hash")),
		"format": _host_count(manifest.get("format")),
		"thumbnail_url": _https_url(cover),
	}
	var mcm := _hosted_mcm_files(manifest.get("mcmConfig"), warnings)
	return {"profile": profile, "mcm": mcm, "warnings": warnings}

## Pack key to mod name from a manifest, also kept in _pack_mod_names.
func _manifest_names(manifest: Dictionary) -> Dictionary:
	var names := {}
	for m: Dictionary in _vmp_modpack_mods(manifest):
		names[HOSTED_KEY_PREFIX + str(m["slug"])] = m["name"]
	_pack_mod_names.merge(names, true)
	return names

## mcmConfig as {path under MCM/: text}. A "<modId>/config.ini" key is a raw MCM file;
## a root .ini carrying ImportModData is an MCM Export, merged per mod as MCM's Import does.
func _hosted_mcm_files(mcm_v: Variant, warnings: PackedStringArray) -> Dictionary:
	var out := {}
	if not (mcm_v is Dictionary):
		return out
	var exports: Array[String] = []
	for k_v in mcm_v:
		var rel := str(k_v).strip_edges().replace("\\", "/")
		var content_v: Variant = mcm_v[k_v]
		if not (content_v is String):
			warnings.append("MCM entry %s is not text and was skipped" % rel)
			continue
		if rel.is_empty():
			warnings.append("an MCM entry with no name was skipped")
			continue
		if rel.begins_with("/") or rel.contains("..") or rel.contains(":"):
			warnings.append("MCM entry %s has an unsafe path and was skipped" % rel)
			continue
		if rel.contains("/"):
			if not (rel.get_file().get_extension().to_lower() in MCM_EXTENSIONS):
				warnings.append("MCM entry %s is not an .ini, .json or .cfg file and was skipped" % rel)
				continue
			out[rel] = content_v
		elif rel.get_extension().to_lower() == "ini" and content_v.contains("ImportModData"):
			exports.append(content_v)
		else:
			warnings.append("MCM entry %s is not a per-mod file or an MCM export and was skipped" % rel)
	_merge_mcm_exports(exports, out, warnings)
	return out

# An export section is a mod id; each value names its section in that mod's config
# through import_data.section. MCM's per-type property check needs its registry.
func _merge_mcm_exports(exports: Array[String], out: Dictionary, warnings: PackedStringArray) -> void:
	for text in exports:
		var export := ConfigFile.new()
		if export.parse(text) != OK:
			warnings.append("an MCM export in the pack could not be parsed and was skipped")
			continue
		for mod_id_v in export.get_sections():
			var mod_id := str(mod_id_v).strip_edges()
			if mod_id.is_empty() or mod_id.contains("/") or mod_id.contains("..") or mod_id.contains(":"):
				warnings.append("MCM export names an unsafe mod id and that section was skipped")
				continue
			var target_path := mod_id + "/config.ini"
			var target := ConfigFile.new()
			if out.has(target_path) and target.parse(out[target_path]) != OK:
				target = ConfigFile.new()
			var merged := 0
			for key: String in export.get_section_keys(mod_id):
				var value: Variant = export.get_value(mod_id, key)
				if key == "ImportModData" or not (value is Dictionary):
					continue
				var data: Dictionary = (value as Dictionary).duplicate(true)
				var import_v: Variant = data.get("import_data")
				if not (import_v is Dictionary):
					continue
				var section := str((import_v as Dictionary).get("section", "")).strip_edges()
				if section.is_empty():
					continue
				data.erase("import_data")
				target.set_value(section, key, data)
				merged += 1
			if merged > 0:
				out[target_path] = target.encode_to_text()

## The first cap the files written under MCM/ break, or "". Values are text or bytes.
func _mcm_cap_error(mcm: Dictionary) -> String:
	if mcm.size() > MCM_MAX_FILES:
		return "The pack carries more than %d mod settings files, so it was not imported." % MCM_MAX_FILES
	for rel in mcm:
		if _mcm_size(mcm[rel]) > MCM_MAX_BYTES:
			return "The pack's mod settings file %s is over 64 KiB, so it was not imported." % rel
	return ""

func _mcm_size(v: Variant) -> int:
	return (v as PackedByteArray).size() if v is PackedByteArray else str(v).to_utf8_buffer().size()

## A pack zip's MCM/ members within the importer's caps, for the apply-time restore.
## A ":" path or an over-cap member is skipped with a warning, so the pack still applies.
func _mcm_restore_files(data: Dictionary) -> Dictionary:
	var out := {}
	for rel: String in data:
		var why := ""
		if rel.contains(":"):
			why = "has an unsafe path"
		elif _mcm_size(data[rel]) > MCM_MAX_BYTES:
			why = "is over 64 KiB"
		elif out.size() >= MCM_MAX_FILES:
			why = "is past the %d-file limit" % MCM_MAX_FILES
		if why == "":
			out[rel] = data[rel]
		else:
			_log_warning("[Modpack] skipped MCM/%s: it %s" % [rel.left(40), why])
	return out

func _hosted_pack_file_path(slug: String) -> String:
	var safe := ""
	for ch in slug.to_lower():
		if (ch >= "a" and ch <= "z") or (ch >= "0" and ch <= "9") or ch == "-":
			safe += ch
	if safe.is_empty():
		return ""
	return _mods_dir_path().path_join(HOSTED_PACK_FILE_PREFIX + safe + ".zip")

## Written to a .part and renamed into place, so a half-written zip is never scanned as a pack.
func _hosted_write_pack_zip(profile: Dictionary, mcm: Dictionary, path: String) -> Dictionary:
	var tmp := path + ".part"
	var packer := ZIPPacker.new()
	if packer.open(tmp) != OK:
		return {"ok": false, "error": "Cannot write to your mods folder."}
	var ok := packer.start_file("profile.json") == OK \
			and packer.write_file(JSON.stringify(profile, "  ").to_utf8_buffer()) == OK \
			and packer.close_file() == OK
	if ok:
		for rel_v in mcm:
			var data: Variant = mcm[rel_v]
			if packer.start_file("MCM/" + str(rel_v)) != OK \
					or packer.write_file(data if data is PackedByteArray else str(data).to_utf8_buffer()) != OK \
					or packer.close_file() != OK:
				ok = false
				break
	if packer.close() != OK:
		ok = false
	if not ok:
		DirAccess.remove_absolute(tmp)
		return {"ok": false, "error": "The modpack could not be written completely. Check disk space and try again."}
	_static_remove_file(path)
	_modpack_zip_memo.erase(path)
	if DirAccess.rename_absolute(tmp, path) != OK:
		DirAccess.remove_absolute(tmp)
		return {"ok": false, "error": "Could not replace the existing modpack file. Is it open in another program?"}
	return {"ok": true, "error": ""}

func _hosted_import_manifest(manifest: Dictionary) -> Dictionary:
	var conv := _hosted_manifest_to_profile(manifest)
	var profile: Dictionary = conv["profile"]
	var warn := {"warnings": conv["warnings"]}
	var slug: String = profile["hosted"]["slug"]
	var path := _hosted_pack_file_path(slug)
	if path.is_empty():
		return _pack_fail("The pack has no usable name.", "", warn)
	# A name with no cased letters or digits (CJK, Arabic, emoji) sanitizes to
	# nothing, and the pack could never apply.
	if _sanitize_profile_name(profile["name"]).strip_edges().is_empty():
		profile["name"] = slug
	var name: String = profile["name"]
	_manifest_names(manifest)
	var previous := _build_modpack_entry(path) if FileAccess.file_exists(path) else {}
	var previous_hosted: Dictionary = previous.get("hosted", {})
	var hosted: Dictionary = profile["hosted"]
	var old_slot := _pack_list_slot(path, str(previous.get("sanitized_name", "")))
	var limit := _mcm_cap_error(conv["mcm"])
	if hosted["hash"] != "" and hosted["hash"] == str(previous_hosted.get("hash", "")):
		# The same setup: only what an older loader left out is added. Over the caps
		# the pack on disk stays as it is rather than failing the Refresh.
		var err := ""
		if limit == "":
			if profile.has("checksums") and _modpack_checksums(previous).is_empty():
				err = _rewrite_pack(profile, conv["mcm"], path, old_slot, "file checksums")
			elif hosted["thumbnail_url"] != "" and _host_str(previous_hosted.get("thumbnail_url")) == "":
				err = _add_pack_cover(hosted, path, old_slot)
		if err != "":
			return _pack_fail(err, name, warn)
		return {"ok": true, "error": "", "file_path": path, "name": name, "warnings": conv["warnings"], "changed": false}
	if limit != "":
		return _pack_fail(limit, name, warn)
	var active := get_active_modpack()
	if active != "" and (active == old_slot or (old_slot == "" and active == _sanitize_profile_name(name))):
		var shown: String = previous.get("raw_name", name)
		return _pack_fail("Unload \"" + shown + "\" before replacing its modpack file.", name, warn)
	var w := _hosted_write_pack_zip(profile, conv["mcm"], path)
	if not w["ok"]:
		return _pack_fail(w["error"], name, warn)
	# Every import invalidates the slot built from the replaced zip.
	_modpack_forget_slot(old_slot)
	for line in conv["warnings"]:
		_log_warning("[Modpack] " + slug + ": " + line)
	return {"ok": true, "error": "", "file_path": path, "name": name, "warnings": conv["warnings"], "changed": true}

## In place, so the kept slot and the active pack stay. "" or the error.
func _rewrite_pack(profile: Dictionary, mcm: Dictionary, path: String, old_slot: String, what: String) -> String:
	var w := _hosted_write_pack_zip(profile, mcm, path)
	if not w["ok"]:
		return w["error"]
	_restamp_pack_slot(old_slot, path)
	_log_info("[Modpack] %s: added the site's %s to the pack" % [profile["hosted"]["slug"], what])
	return ""

## Only the hosted record changes: the zip's own mod list and settings are kept.
func _add_pack_cover(hosted: Dictionary, path: String, old_slot: String) -> String:
	var reader := ZIPReader.new()
	var pd: Variant = null
	var kept := {}
	if reader.open(path) == OK:
		pd = _parse_profile_bytes(reader.read_file("profile.json"))
		for f in reader.get_files():
			if f.begins_with("MCM/") and not f.ends_with("/"):
				kept[f.substr(4)] = reader.read_file(f)
		reader.close()
	if pd == null:
		return "Cannot read the existing modpack file."
	pd["hosted"] = hosted
	return _rewrite_pack(pd, kept, path, old_slot, "cover")

func _pack_list_slot(path: String, fallback: String) -> String:
	if FileAccess.file_exists(path):
		for e in collect_modpack_metadata():
			if e["file_path"] == path:
				return e["sanitized_name"]
	return fallback

func _pack_fail(error: String, name: String = "", extra: Dictionary = {}) -> Dictionary:
	var r := {"ok": false, "error": error, "file_path": "", "name": name}
	r.merge(extra)
	return r

## A refused manifest carries its reason (a too-new format); the shared copy would hide it.
func _hosted_fetch_error_copy(res: Dictionary) -> String:
	var reason := str(res["message"]).strip_edges()
	if res["code"] == HOST_ERR_BAD_RESPONSE and reason != "":
		return "Vostok Mods sent a modpack the loader cannot use: " + reason
	return host_error_message(HOST_VOSTOKMODS, res)

func _hosted_pack_from_link(text: String) -> Dictionary:
	if _modpack_apply_in_progress:
		return _pack_fail(PACK_APPLY_BUSY)
	var url := _vmp_modpack_manifest_url(text)
	if url.is_empty():
		return _pack_fail("That is not a Vostok Mods modpack link. Paste the pack's page address or its pack link.")
	var res := await _vmp_fetch_modpack_manifest(url)
	# An apply that started during the fetch reads this zip.
	if _modpack_apply_in_progress:
		return _pack_fail(PACK_APPLY_BUSY)
	if not res["ok"]:
		if res["code"] == HOST_ERR_NOT_FOUND:
			return _pack_fail("Vostok Mods has no modpack at that link.")
		return _pack_fail(_hosted_fetch_error_copy(res))
	return _hosted_import_manifest(res["data"])

## A hand-edited manifest_url is re-normalized, so it cannot point the fetch off the site.
func _pack_manifest_url(hosted: Dictionary) -> String:
	var url := _vmp_modpack_manifest_url(str(hosted.get("manifest_url", "")))
	if url.is_empty():
		url = _vmp_modpack_manifest_url(str(hosted.get("slug", "")))
	return url

func _hosted_refresh_pack(entry: Dictionary) -> Dictionary:
	var name: String = entry["raw_name"]
	if _modpack_apply_in_progress:
		return _pack_fail(PACK_APPLY_BUSY, name, {"changed": false})
	var url := _pack_manifest_url(entry["hosted"])
	if url.is_empty():
		return _pack_fail("This pack does not record where it came from.", name, {"changed": false})
	var res := await _vmp_fetch_modpack_manifest(url)
	if _modpack_apply_in_progress:
		return _pack_fail(PACK_APPLY_BUSY, name, {"changed": false})
	if not res["ok"]:
		if res["code"] == HOST_ERR_NOT_FOUND:
			return _pack_fail("This pack is no longer on Vostok Mods.", name, {"changed": false})
		return _pack_fail(_hosted_fetch_error_copy(res), name, {"changed": false})
	var imp := _hosted_import_manifest(res["data"])
	if not imp["ok"]:
		return _pack_fail(imp["error"], name, {"changed": false})
	return {"ok": true, "error": "", "changed": imp["changed"], "name": imp["name"]}

func _hosted_unavailable_copy(reason: String) -> String:
	match reason:
		"removed":
			return "this mod was removed from Vostok Mods -- install it manually"
		"scanning":
			return "this mod's file is still being scanned by Vostok Mods -- try again in a while"
		"no_files":
			return "this mod has no downloadable file on Vostok Mods yet -- try again later"
		_:
			return "Vostok Mods cannot serve this mod right now -- install it manually"
