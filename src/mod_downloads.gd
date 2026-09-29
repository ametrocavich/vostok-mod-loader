## Host-neutral downloads, archive validation and replacement on disk.
## UI and pack callers enter through download_mod_from_ref or replace_mod_from_ref.
## Host adapters resolve files; mod_sources.gd records their installed origin.

# HTTPRequest.timeout covers the whole transfer; mod bodies run to ~256MB.
const API_DOWNLOAD_TIMEOUT := 300.0

## Current version of many installed mods, grouped by host. Returns
## {ref_key: version}; an absent mod could not be checked. A host without the
## resolve_file capability is skipped.
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
		if not bool(host_caps(provider)["resolve_file"]):
			continue
		var res := await host_latest_versions(provider, ids_by_provider[provider], Callable())
		if not res["ok"]:
			_log_warning("[Updates] %s version check failed: %s" % [host_display_name(provider), host_error_message(provider, res)])
			continue
		if res["data"] is Dictionary:
			out.merge(res["data"], true)
	return out

# Filename from Content-Disposition (plain, quoted, and RFC 5987 filename*).
# Returns "" unless the value is a safe basename with an accepted extension.
func _filename_from_content_disposition(headers: PackedStringArray) -> String:
	for raw in headers:
		var line: String = raw
		var colon := line.find(":")
		if colon < 0:
			continue
		if line.substr(0, colon).strip_edges().to_lower() != "content-disposition":
			continue
		var value := line.substr(colon + 1).strip_edges()
		# filename* first: unicode-safe, and dual-emitting servers prefer it.
		var star_val := _extract_disposition_param(value, "filename*")
		if star_val != "":
			var sep := star_val.find("''")
			if sep >= 0:
				star_val = star_val.substr(sep + 2).uri_decode()
			if _is_safe_mod_filename(star_val):
				return star_val.get_file()
		var plain_val := _extract_disposition_param(value, "filename")
		if plain_val != "":
			# CDNs percent-encode plain filename=; decode, then validate.
			if plain_val.contains("%"):
				plain_val = plain_val.uri_decode()
			if _is_safe_mod_filename(plain_val):
				return plain_val.get_file()
		return ""
	return ""

func _extract_disposition_param(header_value: String, param: String) -> String:
	var pos := header_value.to_lower().find(param.to_lower() + "=")
	if pos < 0:
		return ""
	var rest := header_value.substr(pos + param.length() + 1).strip_edges()
	if rest.begins_with("\""):
		var end := rest.find("\"", 1)
		if end < 0:
			return ""
		return rest.substr(1, end - 1)
	var semi := rest.find(";")
	if semi < 0:
		return rest.strip_edges()
	return rest.substr(0, semi).strip_edges()

# True when a server-supplied name is a bare filename safe to path_join.
# get_file() only splits on "/", so "..\evil.zip" would pass a basename check;
# both separators, drive and ADS colons, and dot-prefixed names are rejected.
func _is_safe_basename(name: String) -> bool:
	if name.is_empty():
		return false
	if "\\" in name or "/" in name or ":" in name or name.begins_with("."):
		return false
	return name == name.get_file()

func _is_safe_mod_filename(name: String) -> bool:
	if not _is_safe_basename(name):
		return false
	return name.get_extension().to_lower() in ["vmz", "zip", "pck"]

# Filename the download lands under: Content-Disposition, else the old stem
# with the new version spliced on. Best-effort; never blocks an update.
func _derive_updated_filename(old_file_name: String, headers: PackedStringArray, new_version: String) -> String:
	var server_name := _filename_from_content_disposition(headers)
	if server_name != "":
		return server_name
	if new_version.is_empty():
		return old_file_name
	# new_version is untrusted; separators would land outside the mods dir.
	if not new_version.lstrip("vV").is_valid_filename():
		return old_file_name
	var ext := old_file_name.get_extension()
	var stem := old_file_name.get_basename()
	var rx := RegEx.new()
	rx.compile("[_-][vV]\\d+(?:\\.\\d+)*$")
	var stripped := rx.sub(stem, "")
	var new_stem := stripped + "_v" + new_version.lstrip("vV")
	return new_stem if ext.is_empty() else new_stem + "." + ext

# --- Download surfaces ------------------------------------------------------
# Four UI surfaces reach the two entry points below; keep this map current:
#   1. Mods tab "Update" badge (build_mods_tab) -> replace_mod_from_ref
#   2. Browse "Download" and its serial queue (build_browse_tab) -> download_mod_from_ref(ref)
#   3. Missing-mod stub "Download" (build_mods_tab) -> download_mod_from_ref(ref, version, true)
#   4. Modpack apply and retry (modpacks.gd) -> download_mod_from_ref(ref, version, true);
#      the apply loop counts the "Already have" prefix as installed, not failed.
# Each surface has its own busy state and error handling; only Browse
# serializes, so two surfaces can race on the same file (hence the
# _live_full_path re-resolution in profiles.gd).

# Returns {ok, new_path, new_file_name}; failures also carry "error". On
# success new_path may differ from target_path (Content-Disposition or
# version bump). On failure temp and backup are cleaned up and the original is intact.
func replace_mod_from_ref(target_path: String, ref: Dictionary) -> Dictionary:
	# The Mods-tab badge shows "error" verbatim, so it is never "unknown".
	var failure := {"ok": false, "new_path": target_path, "new_file_name": target_path.get_file(), "error": ""}
	if not host_ref_valid(ref):
		failure["error"] = "This mod has no download source recorded."
		return failure
	var provider := str(ref["provider"])
	var resolved := await host_resolve_file(ref, "")
	if not resolved["ok"]:
		failure["error"] = _host_resolve_failure_copy(provider, resolved, "")
		return failure
	var file: Dictionary = resolved["data"]

	var temp_path   := target_path + ".download"
	var backup_path := target_path + ".bak"
	var dl := await _http_download_to_temp(provider, str(file["download_url"]),
			_host_download_headers(file), temp_path)
	if not dl["ok"]:
		failure["error"] = dl["error"]
		return failure
	var headers: PackedStringArray = dl["headers"]
	# A .bak left by an interrupted update goes only now: until the new
	# download has landed it may be the one copy of the old archive.
	if FileAccess.file_exists(backup_path):
		DirAccess.remove_absolute(backup_path)

	var new_cfg: ConfigFile = read_mod_config(temp_path)["cfg"]
	if new_cfg == null:
		DirAccess.remove_absolute(temp_path)
		failure["error"] = "Downloaded file is not a valid mod archive (no readable mod.txt)"
		return failure

	var dir_access := DirAccess.open(target_path.get_base_dir())
	if dir_access == null:
		DirAccess.remove_absolute(temp_path)
		failure["error"] = "Could not open the mods folder"
		return failure

	var old_file_name := target_path.get_file()
	var new_version := str(new_cfg.get_value("mod", "version", ""))
	var new_file_name := _derive_updated_filename(old_file_name, headers, new_version)
	var new_path := target_path.get_base_dir().path_join(new_file_name)

	# Never clobber an unrelated archive at the derived path.
	if not _same_file_name(new_file_name, old_file_name) and FileAccess.file_exists(new_path):
		DirAccess.remove_absolute(temp_path)
		failure["error"] = "A different file named \"%s\" is already in the mods folder -- move or delete it and retry" % new_file_name
		return failure

	# Stash the old archive under .bak so a failed rename can roll back.
	if FileAccess.file_exists(target_path):
		if dir_access.rename(target_path.get_file(), backup_path.get_file()) != OK:
			DirAccess.remove_absolute(temp_path)
			failure["error"] = "Could not back up the current archive (file in use?) -- close anything using it and retry"
			return failure

	if dir_access.rename(temp_path.get_file(), new_file_name) != OK:
		if FileAccess.file_exists(backup_path):
			dir_access.rename(backup_path.get_file(), target_path.get_file())
		DirAccess.remove_absolute(temp_path)
		failure["error"] = "Could not finalize the update (file may be locked) -- the old version was kept"
		return failure

	# New file is in place; the .bak (which is the old archive) can go.
	if FileAccess.file_exists(backup_path):
		DirAccess.remove_absolute(backup_path)
	_record_installed_mod_source(new_file_name, ref, str(file["version"]))
	return {"ok": true, "new_path": new_path, "new_file_name": new_file_name}


# True when two names in one folder are the same file: equal, or equal but for
# case where the file system ignores it. file_exists() finds the installed
# archive under a new name that differs only in case.
func _same_file_name(a: String, b: String) -> bool:
	if a == b:
		return true
	return a.to_lower() == b.to_lower() and OS.get_name() in ["Windows", "macOS"]


# Fetch an archive and adopt it into mods/. Provider-neutral: the caller
# resolved a FileRecord through the seam. Returns {ok, file_name, error}; on
# failure the temp file is cleaned up. The "Already have a file named " prefix
# is a contract: modpacks.gd counts that failure as already-installed.
func _host_install_downloaded_archive(provider: String, download_url: String, headers: PackedStringArray,
		fallback_stem: String, filename_hint: String, version_hint: String,
		allow_rename_on_collision: bool, expected_sha256: String = "") -> Dictionary:
	var failure := {"ok": false, "file_name": "", "error": "unknown"}
	if _mods_dir.is_empty():
		_mods_dir = OS.get_executable_path().get_base_dir().path_join(MOD_DIR)
	DirAccess.make_dir_recursive_absolute(_mods_dir)

	# The final name comes from the response headers, so the download lands
	# under the fallback stem first and is renamed once.
	var temp_path := _mods_dir.path_join(fallback_stem + ".download")
	var dl := await _http_download_to_temp(provider, download_url, headers, temp_path, expected_sha256)
	if not dl["ok"]:
		failure["error"] = dl["error"]
		return failure
	var resp_headers: PackedStringArray = dl["headers"]

	# Same _is_safe_mod_filename gate as the update path. The adapter's
	# filename_hint carries whatever its host knows; the fallback stem is
	# provider-specific so ModWorkshop installs keep their old filenames.
	var derived_name := _filename_from_content_disposition(resp_headers)
	if derived_name.is_empty() and _is_safe_mod_filename(filename_hint):
		derived_name = filename_hint
	if derived_name.is_empty():
		derived_name = fallback_stem + ".zip"
	var final_path := _mods_dir.path_join(derived_name)

	# Collisions: Browse refuses. Modpack apply (allow_rename_on_collision)
	# suffixes the version so a pinned version coexists and dedup picks the higher.
	if FileAccess.file_exists(final_path):
		if not allow_rename_on_collision:
			# Prefix contract with modpacks.gd _apply_modpack_inner; reword it there too.
			DirAccess.remove_absolute(temp_path)
			failure["error"] = "Already have a file named " + derived_name
			return failure
		var meta_version := version_hint.strip_edges().lstrip("vV")
		# Server-controlled string headed into a filename; is_valid_filename rejects traversal and "<null>".
		if not meta_version.is_empty() and not meta_version.is_valid_filename():
			meta_version = ""
		if meta_version.is_empty():
			# Last-ditch: a timestamp suffix so the install can proceed.
			meta_version = str(int(Time.get_unix_time_from_system()))
		var ext := derived_name.get_extension()
		var stem := derived_name.get_basename()
		derived_name = stem + "-v" + meta_version + ("." + ext if ext != "" else "")
		final_path = _mods_dir.path_join(derived_name)
		if FileAccess.file_exists(final_path):
			# Same "Already have" prefix contract as above.
			DirAccess.remove_absolute(temp_path)
			failure["error"] = "Already have a file named " + derived_name + " (and the renamed variant)"
			return failure

	# Validate before adopting, mirroring collect_mod_metadata: a .pck has no
	# readable root mod.txt, so check its container magic instead.
	var dl_ext := derived_name.get_extension().to_lower()
	if dl_ext == "pck":
		if not _looks_like_pck(temp_path):
			DirAccess.remove_absolute(temp_path)
			failure["error"] = "Downloaded file is not a valid .pck"
			return failure
	else:
		# Reject only an invalid container; mod.txt is optional, same as discovery.
		var zr := ZIPReader.new()
		var zip_ok := zr.open(temp_path) == OK
		if zip_ok:
			zr.close()
		if not zip_ok:
			DirAccess.remove_absolute(temp_path)
			failure["error"] = "Downloaded file is not a valid archive"
			return failure
		if read_mod_config(temp_path)["cfg"] == null:
			_log_warning("Downloaded '%s' has no parseable root mod.txt -- installing as a plain resource pack" % derived_name)

	var dir_access := DirAccess.open(_mods_dir)
	if dir_access == null:
		DirAccess.remove_absolute(temp_path)
		failure["error"] = "Could not open the mods folder"
		return failure

	if dir_access.rename(temp_path.get_file(), derived_name) != OK:
		DirAccess.remove_absolute(temp_path)
		failure["error"] = "Could not move the downloaded file into the mods folder (file may be locked) -- close anything using it and retry"
		return failure

	return {"ok": true, "file_name": derived_name, "error": ""}


## The user-facing reason a download request failed. A transport failure has
## no status code; a body over the size cap is its own case, since retrying it
## cannot help.
func _download_failure_text(provider: String, result: int, status: int) -> String:
	if result == HTTPRequest.RESULT_BODY_SIZE_LIMIT_EXCEEDED:
		return "This file is larger than the 256 MB the mod loader will download. Get it from the mod's page and put it in the mods folder yourself."
	if result != HTTPRequest.RESULT_SUCCESS:
		return "Download failed (connection error or timeout) -- check your network and retry"
	return host_error_status(provider, "Download failed (HTTP %d)" % status)


## Download `url` to `temp_path`, replacing any file there, and verify the
## bytes on disk match the body. `expected_sha256`, when set, is checked
## before anything is written. Returns {ok, error, headers}; on failure no
## temp file is left behind and `error` is the user-facing text.
func _http_download_to_temp(provider: String, url: String, headers: PackedStringArray,
		temp_path: String, expected_sha256: String = "") -> Dictionary:
	var failure := {"ok": false, "error": "", "headers": PackedStringArray()}
	var req := HTTPRequest.new()
	req.timeout = API_DOWNLOAD_TIMEOUT
	req.download_body_size_limit = 256 * 1024 * 1024
	add_child(req)
	var err := req.request(url, headers)
	if err != OK:
		req.queue_free()
		failure["error"] = "Could not start the download request (error %d)" % err
		return failure
	var res: Array = await req.request_completed
	req.queue_free()
	host_note_rate_headers(provider, int(res[1]), res[2])
	if res[0] != HTTPRequest.RESULT_SUCCESS or res[1] < 200 or res[1] >= 300:
		failure["error"] = _download_failure_text(provider, int(res[0]), int(res[1]))
		return failure
	var body: PackedByteArray = res[3]
	if body.is_empty():
		failure["error"] = "The download came back empty. Try again later."
		return failure
	# A pack that names the file's checksum gets it checked before it reaches mods/.
	if expected_sha256 != "":
		var ctx := HashingContext.new()
		ctx.start(HashingContext.HASH_SHA256)
		ctx.update(body)
		var got := ctx.finish().hex_encode()
		if got != expected_sha256.to_lower():
			failure["error"] = "The downloaded file does not match the checksum the modpack lists. Try again later; if it keeps failing, the file on the site may have changed."
			return failure
	if FileAccess.file_exists(temp_path):
		DirAccess.remove_absolute(temp_path)
	var out := FileAccess.open(temp_path, FileAccess.WRITE)
	if out == null:
		failure["error"] = "Could not write to the mods folder (permissions or disk full)"
		return failure
	var wrote := out.store_buffer(body)
	out.close()
	var verify := FileAccess.open(temp_path, FileAccess.READ)
	var disk_len: int = verify.get_length() if verify != null else -1
	if verify != null:
		verify.close()
	if not wrote or disk_len != body.size():
		DirAccess.remove_absolute(temp_path)
		failure["error"] = "Could not write the download to disk (disk full?)"
		return failure
	return {"ok": true, "error": "", "headers": res[2]}


## Download headers: our User-Agent (a default one gets a bodyless 403) plus
## the adapter's per-file headers, such as a signed-CDN token.
func _host_download_headers(file: Dictionary) -> PackedStringArray:
	var h := PackedStringArray(["User-Agent: " + (HOST_USER_AGENT_TEMPLATE % MODLOADER_VERSION)])
	var extra: Variant = file.get("headers")
	if extra is PackedStringArray:
		h.append_array(extra)
	return h


## User-facing copy for a failed resolve; codes the install path cares about get specific wording.
func _host_resolve_failure_copy(provider: String, res: Dictionary, version: String) -> String:
	var host := host_display_name(provider)
	match str(res.get("code", "")):
		HOST_ERR_VERSION_NOT_FOUND:
			return host_error_status(provider, "Version " + version + " not available on " + host)
		HOST_ERR_NO_FILE:
			if str(res.get("message", "")).contains("scan"):
				return "This version has not passed " + host + "'s malware scan, so it cannot be downloaded yet."
			return host_error_status(provider, "This mod has no downloadable file on " + host + ". Check its mod page -- the author may host the download elsewhere.")
		HOST_ERR_OFFLINE:
			return "Could not reach " + host + ". Check your connection and try again."
		_:
			return host_error_message(provider, res)


## Record where an installed archive came from, so the update check and a
## modpack apply know its host even when its mod.txt declares no source.
## Only the profile key is needed, so the archive is not security-scanned here.
func _record_installed_mod_source(file_name: String, ref: Dictionary, version: String) -> void:
	var full_path := _mods_dir.path_join(file_name)
	var ext := file_name.get_extension().to_lower()
	var read: Dictionary = read_mod_config(full_path) if ext != "pck" else _mod_txt_read("pck")
	var pk := str(_entry_from_config(read, file_name, full_path, ext).get("profile_key", ""))
	if pk.is_empty():
		return
	_persist_single_mod_source(pk, {"provider": str(ref["provider"]), "id": str(ref["id"]), "version": version})


## Filename stem when neither the server nor the adapter names the file.
## ModWorkshop keeps "mws_mod_<id>" so existing installs are recognized.
func _host_fallback_stem(ref: Dictionary) -> String:
	var id := str(ref["id"])
	if str(ref["provider"]) == HOST_MODWORKSHOP:
		return "mws_mod_" + id
	return str(ref["provider"]) + "_" + id.validate_filename()


# Browse "Get" and modpack apply, for any host. Empty `version` installs the
# host's current file; a set version pins it. Returns {ok, file_name, error}.
func download_mod_from_ref(ref: Dictionary, version: String = "", allow_rename_on_collision: bool = false,
		expected_sha256: String = "") -> Dictionary:
	var failure := {"ok": false, "file_name": "", "error": "unknown"}
	if not host_ref_valid(ref):
		failure["error"] = "This mod has no download source recorded."
		return failure
	var provider := str(ref["provider"])
	var res := await host_resolve_file(ref, version)
	if not res["ok"]:
		failure["error"] = _host_resolve_failure_copy(provider, res, version)
		return failure
	var file: Dictionary = res["data"]
	var r := await _host_install_downloaded_archive(provider, str(file["download_url"]),
			_host_download_headers(file), _host_fallback_stem(ref), str(file["filename_hint"]),
			str(file["version"]), allow_rename_on_collision, expected_sha256)
	if r["ok"]:
		_record_installed_mod_source(str(r["file_name"]), ref, str(file["version"]))
	return r


# .pck archives begin with "GDPC"; a CDN error page under a .pck name is refused.
func _looks_like_pck(path: String) -> bool:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return false
	var magic := f.get_buffer(4)
	f.close()
	return magic == PackedByteArray([0x47, 0x44, 0x50, 0x43])
