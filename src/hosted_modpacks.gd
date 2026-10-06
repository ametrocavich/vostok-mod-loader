## ----- hosted_modpacks.gd -----
## Modpacks published on vostokmods.net. The site serves a manifest (format
## 2: the ordered mod list, each with slug, version and download details,
## plus the pack's MCM settings). The loader turns that manifest into an
## ordinary local modpack zip in mods/, so Apply, Unload and the failure
## dialog all work unchanged. Packs are a Vostok Mods feature by
## the site's decision, so this file talks to the _vmp_* adapter directly
## instead of going through the host seam.
##
## Nothing in the manifest is trusted for downloads: every mod is fetched by
## slug through host_resolve_file, and the manifest's sha256 (when present)
## is checked against the downloaded bytes.

const HOSTED_PACK_FILE_PREFIX := "vostokmods-"
# Profile keys for mods in a hosted pack, before the apply-time reconcile
# rewrites them to the installed mod's own key.
const HOSTED_KEY_PREFIX := "vostokmods:"


# ----- manifest -> pack ------------------------------------------------------

## Convert a validated manifest into {profile: <profile.json dict>,
## mcm: {relative path: text}, warnings: PackedStringArray}. Pure: no I/O.
func _hosted_manifest_to_profile(manifest: Dictionary) -> Dictionary:
	var warnings := PackedStringArray()
	var enabled := {}
	var priority := {}
	var sources := {}
	var unavailable := {}
	var checksums := {}
	var mods: Array = manifest.get("mods", []) if manifest.get("mods") is Array else []
	var order := 0
	for m_v in mods:
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
		if _json_truthy(m.get("available", true)):
			var rec := {"provider": HOST_VOSTOKMODS, "id": slug}
			var version := _host_str(m.get("version")).strip_edges()
			if version != "":
				rec["version"] = version
			sources[key] = rec
			var sha := _host_str(m.get("sha256")).strip_edges().to_lower()
			if sha.length() == 64:
				checksums[key] = sha
		else:
			unavailable[key] = _host_str(m.get("reason")).strip_edges()
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
	profile["hosted"] = {
		"provider": HOST_VOSTOKMODS,
		"slug": _host_str(manifest.get("slug")).strip_edges(),
		"url": _host_str(manifest.get("url")),
		"manifest_url": _host_str(manifest.get("manifest_url")),
		"hash": _host_str(manifest.get("hash")),
		"format": _host_count(manifest.get("format")),
	}
	var mcm := _hosted_mcm_files(manifest.get("mcmConfig"), warnings)
	return {"profile": profile, "mcm": mcm, "warnings": warnings}


## The manifest's mcmConfig as {relative path under MCM/: text}. Two shapes
## can appear, mixed. A key with a directory part ("<modId>/config.ini") is a
## raw MCM file and is kept as is. A root-level .ini whose content carries
## ImportModData is the file MCM's own Export menu writes; it is merged into
## each mod's config.ini the way MCM's Import does, so the pack's settings
## land in the default profile file MCM copies from. Pure: no I/O.
func _hosted_mcm_files(mcm_v: Variant, warnings: PackedStringArray) -> Dictionary:
	var out := {}
	if not (mcm_v is Dictionary):
		return out
	var exports := []
	for k_v in (mcm_v as Dictionary):
		var rel := str(k_v).strip_edges().replace("\\", "/")
		var content_v: Variant = (mcm_v as Dictionary)[k_v]
		if not (content_v is String):
			warnings.append("MCM entry %s is not text and was skipped" % rel)
			continue
		if rel.is_empty() or rel.begins_with("/") or rel.contains("..") or rel.contains(":"):
			warnings.append("MCM entry %s has an unsafe path and was skipped" % rel)
			continue
		if not rel.contains("/"):
			if rel.get_extension().to_lower() == "ini" and str(content_v).contains("ImportModData"):
				exports.append(str(content_v))
			else:
				warnings.append("MCM entry %s is not a per-mod file or an MCM export and was skipped" % rel)
			continue
		out[rel] = str(content_v)
	for text in exports:
		_hosted_mcm_merge_export(str(text), out, warnings)
	return out


## Merge one MCM export file into `files` (path -> text), in place. The
## export is a ConfigFile: one section per mod id, one key per setting, the
## value a Dictionary carrying import_data.section that names the section in
## that mod's own config. Mirrors MCM_Import_Menu.ImportSettings minus its
## per-type required-property check, which needs MCM's type registry.
func _hosted_mcm_merge_export(text: String, files: Dictionary, warnings: PackedStringArray) -> void:
	var export := ConfigFile.new()
	if export.parse(text) != OK:
		warnings.append("an MCM export in the pack could not be parsed and was skipped")
		return
	for mod_id_v in export.get_sections():
		var mod_id := str(mod_id_v).strip_edges()
		if mod_id.is_empty() or mod_id.contains("/") or mod_id.contains("..") or mod_id.contains(":"):
			warnings.append("MCM export names an unsafe mod id and that section was skipped")
			continue
		var target_path := mod_id + "/config.ini"
		var target := ConfigFile.new()
		if files.has(target_path):
			if target.parse(str(files[target_path])) != OK:
				target = ConfigFile.new()
		var merged := 0
		for key_v in export.get_section_keys(mod_id):
			var key := str(key_v)
			if key == "ImportModData":
				continue
			var value: Variant = export.get_value(mod_id, key)
			if not (value is Dictionary):
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
			files[target_path] = target.encode_to_text()


## Where a hosted pack lives on disk: mods/vostokmods-<slug>.zip. The slug
## is reduced to [a-z0-9-] so it can never name a path.
func _hosted_pack_file_path(slug: String) -> String:
	var safe := ""
	for ch in slug.to_lower():
		if (ch >= "a" and ch <= "z") or (ch >= "0" and ch <= "9") or ch == "-":
			safe += ch
	if safe.is_empty():
		return ""
	if _mods_dir.is_empty():
		_mods_dir = OS.get_executable_path().get_base_dir().path_join(MOD_DIR)
	return _mods_dir.path_join(HOSTED_PACK_FILE_PREFIX + safe + ".zip")


## Write profile.json + MCM/ files as a pack zip. Written beside the target
## and renamed into place, so a half-written zip is never scanned as a pack.
## Returns {ok, error}.
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
			var rel := str(rel_v)
			if packer.start_file("MCM/" + rel) != OK \
					or packer.write_file(str(mcm[rel_v]).to_utf8_buffer()) != OK \
					or packer.close_file() != OK:
				ok = false
				break
	if packer.close() != OK:
		ok = false
	if not ok:
		DirAccess.remove_absolute(tmp)
		return {"ok": false, "error": "The modpack could not be written completely. Check disk space and try again."}
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(path)
	if DirAccess.rename_absolute(tmp, path) != OK:
		DirAccess.remove_absolute(tmp)
		return {"ok": false, "error": "Could not replace the existing modpack file. Is it open in another program?"}
	return {"ok": true, "error": ""}


## Manifest -> pack zip in mods/. Returns {ok, error, file_path, name,
## warnings, changed}.
func _hosted_import_manifest(manifest: Dictionary) -> Dictionary:
	var conv := _hosted_manifest_to_profile(manifest)
	var profile: Dictionary = conv["profile"]
	var slug := str((profile["hosted"] as Dictionary)["slug"])
	var path := _hosted_pack_file_path(slug)
	if path.is_empty():
		return {"ok": false, "error": "The pack has no usable name.", "file_path": "", "name": "", "warnings": conv["warnings"]}
	# The slot is the sanitized name; a name with no cased letters or digits
	# (CJK, Arabic, emoji) sanitizes to nothing and the pack could never apply.
	if _sanitize_profile_name(str(profile["name"])).strip_edges().is_empty():
		profile["name"] = slug
	var previous := _build_modpack_entry(path) if FileAccess.file_exists(path) else {}
	var previous_hosted: Dictionary = previous.get("hosted", {})
	var next_hash := str((profile["hosted"] as Dictionary).get("hash", ""))
	if next_hash != "" and next_hash == str(previous_hosted.get("hash", "")):
		return {"ok": true, "error": "", "file_path": path, "name": str(profile["name"]), "warnings": conv["warnings"], "changed": false}
	var old_slot := str(previous.get("sanitized_name", ""))
	var active := get_active_modpack()
	if active != "" and (active == old_slot or active == _sanitize_profile_name(str(profile["name"]))):
		return {"ok": false, "error": "Unload " + active + " before replacing its modpack file.", "file_path": "", "name": str(profile["name"]), "warnings": conv["warnings"]}
	var w := _hosted_write_pack_zip(profile, conv["mcm"], path)
	if not w["ok"]:
		return {"ok": false, "error": w["error"], "file_path": "", "name": str(profile["name"]), "warnings": conv["warnings"]}
	# Every import path invalidates the slot built from the replaced zip.
	_modpack_forget_slot(old_slot)
	for line in (conv["warnings"] as PackedStringArray):
		_log_warning("[Modpack] " + slug + ": " + line)
	return {"ok": true, "error": "", "file_path": path, "name": str(profile["name"]), "warnings": conv["warnings"], "changed": true}


# ----- network entry points --------------------------------------------------

## Copy for a failed manifest fetch. A manifest the validator refused carries
## its reason (a too-new format says to update the loader); the shared copy
## for that code would hide it.
func _hosted_fetch_error_copy(res: Dictionary) -> String:
	var reason := str(res.get("message", "")).strip_edges()
	if str(res.get("code", "")) == HOST_ERR_BAD_RESPONSE and reason != "":
		return "Vostok Mods sent a modpack the loader cannot use: " + reason
	return host_error_message(HOST_VOSTOKMODS, res)


## Fetch a manifest from a pasted link (or a slug) and import it. Returns
## {ok, error, file_path, name}.
func _hosted_pack_from_link(text: String) -> Dictionary:
	var url := _vmp_modpack_manifest_url(text)
	if url.is_empty():
		return {"ok": false, "error": "That is not a Vostok Mods modpack link. Paste the pack's page address or its loader link.", "file_path": "", "name": ""}
	var res := await _vmp_fetch_modpack_manifest(url)
	if not res["ok"]:
		if str(res["code"]) == HOST_ERR_NOT_FOUND:
			return {"ok": false, "error": "Vostok Mods has no modpack at that link.", "file_path": "", "name": ""}
		return {"ok": false, "error": _hosted_fetch_error_copy(res), "file_path": "", "name": ""}
	return _hosted_import_manifest(res["data"])


## Re-fetch a hosted pack's manifest and rewrite the local zip when the
## site's hash differs. Returns {ok, error, changed, name}.
func _hosted_refresh_pack(entry: Dictionary) -> Dictionary:
	var hosted: Dictionary = entry.get("hosted", {}) if entry.get("hosted") is Dictionary else {}
	var url := _vmp_modpack_manifest_url(str(hosted.get("manifest_url", "")))
	if url.is_empty():
		url = _vmp_modpack_manifest_url(str(hosted.get("slug", "")))
	if url.is_empty():
		return {"ok": false, "error": "This pack does not record where it came from.", "changed": false, "name": str(entry.get("raw_name", ""))}
	var res := await _vmp_fetch_modpack_manifest(url)
	if not res["ok"]:
		if str(res["code"]) == HOST_ERR_NOT_FOUND:
			return {"ok": false, "error": "This pack is no longer on Vostok Mods.", "changed": false, "name": str(entry.get("raw_name", ""))}
		return {"ok": false, "error": _hosted_fetch_error_copy(res), "changed": false, "name": str(entry.get("raw_name", ""))}
	var manifest: Dictionary = res["data"]
	if str(manifest.get("hash", "")) != "" and str(manifest.get("hash", "")) == str(hosted.get("hash", "")):
		return {"ok": true, "error": "", "changed": false, "name": str(manifest.get("name", entry.get("raw_name", "")))}
	var imp := _hosted_import_manifest(manifest)
	if not imp["ok"]:
		return {"ok": false, "error": imp["error"], "changed": false, "name": str(entry.get("raw_name", ""))}
	return {"ok": true, "error": "", "changed": bool(imp.get("changed", true)), "name": imp["name"]}


## Failure-row copy for a mod the site lists but cannot serve.
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
