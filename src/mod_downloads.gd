## Downloads and updates of mod archives: file names, validation and the swap on disk.

# HTTPRequest.timeout covers the whole transfer, not just the connect.
const API_DOWNLOAD_TIMEOUT := 300.0
# The body is held in memory before it is written, so this bounds RAM too.
const DOWNLOAD_MAX_BYTES := 1024 * 1024 * 1024
# Shares the result's `code` key with the HOST_ERR_* values, so it must not equal one.
const DOWNLOAD_ALREADY_INSTALLED := "already_installed"

func _filename_from_content_disposition(headers: PackedStringArray) -> String:
	for line: String in headers:
		var colon := line.find(":")
		if colon < 0 or line.substr(0, colon).strip_edges().to_lower() != "content-disposition":
			continue
		var value := line.substr(colon + 1).strip_edges()
		var star_val := _extract_disposition_param(value, "filename*")
		if star_val != "":
			# RFC 5987: charset'language'value, and the language may be set.
			var q1 := star_val.find("'")
			var q2 := star_val.find("'", q1 + 1) if q1 >= 0 else -1
			if q2 >= 0:
				star_val = star_val.substr(q2 + 1).uri_decode()
			if _is_safe_mod_filename(star_val):
				return star_val.get_file()
		var plain_val := _extract_disposition_param(value, "filename")
		if plain_val != "":
			# CDNs percent-encode plain filename= too.
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

func _is_safe_basename(name: String) -> bool:
	# get_file() splits only on "/", so "..\evil.zip" would pass a basename check.
	if name.is_empty() or "\\" in name or "/" in name or ":" in name or name.begins_with("."):
		return false
	# Names Windows cannot create would fail the final rename for good;
	# is_valid_filename also refuses "%", which Windows allows.
	if not name.replace("%", "_").is_valid_filename() or name.ends_with(".") or name.ends_with(" "):
		return false
	var stem := name.split(".")[0].to_lower()
	if stem in ["con", "prn", "aux", "nul"] or (stem.length() == 4 and (stem.begins_with("com") or stem.begins_with("lpt")) and stem[3].is_valid_int()):
		return false
	return true

func _is_safe_mod_filename(name: String) -> bool:
	if not _is_safe_basename(name):
		return false
	return name.get_extension().to_lower() in MOD_ARCHIVE_EXTENSIONS

func _derive_updated_filename(old_file_name: String, headers: PackedStringArray, new_version: String) -> String:
	var server_name := _filename_from_content_disposition(headers)
	if server_name != "":
		return server_name
	# new_version is server text; separators would land outside the mods dir.
	if new_version.is_empty() or not new_version.lstrip("vV").is_valid_filename():
		return old_file_name
	var ext := old_file_name.get_extension()
	var rx := RegEx.new()
	rx.compile("[_-][vV]\\d+(?:\\.\\d+)*$")
	var new_stem := rx.sub(old_file_name.get_basename(), "") + "_v" + new_version.lstrip("vV")
	return new_stem if ext.is_empty() else new_stem + "." + ext

func replace_mod_from_ref(target_path: String, ref: Dictionary) -> Dictionary:
	if not host_ref_valid(ref):
		return _fail("This mod has no download source recorded.", target_path)
	# A mounted .zip/.pck stays locked until exit (a .vmz mounts via a cache copy): fail early.
	if _filescope_mounted.has(target_path) and target_path.get_extension().to_lower() != "vmz":
		return _fail("The game has this mod's archive open while the mod is enabled. Disable the mod, relaunch the game, then update it.", target_path, "", true)
	var provider := str(ref["provider"])
	var resolved := await host_resolve_file(ref, "")
	if not resolved["ok"]:
		return _fail(_download_resolve_failure_copy(provider, resolved, ""), target_path)
	var file: Dictionary = resolved["data"]
	var temp_path := target_path + ".download"
	var dl := await _http_download_to_temp(provider, str(file["download_url"]),
			PackedStringArray([_host_user_agent_header()]), temp_path)
	if not dl["ok"]:
		return _fail(dl["error"], target_path)
	return _adopt_update(target_path, temp_path, dl["headers"], ref, str(file["version"]))

func _adopt_update(target_path: String, temp_path: String, headers: PackedStringArray,
		ref: Dictionary, file_version: String) -> Dictionary:
	var backup_path := target_path + ".bak"
	# Only now: until the download lands, a leftover .bak may be the one old copy.
	_static_remove_file(backup_path)
	var new_cfg: ConfigFile = _inspect_download(temp_path, target_path.get_extension())["cfg"]
	if new_cfg == null:
		return _fail("Downloaded file is not a valid mod archive (no readable mod.txt)", target_path, temp_path, true)
	var other_mod := _update_names_another_mod(target_path, new_cfg, str(ref["provider"]))
	if other_mod != "":
		return _fail(other_mod, target_path, temp_path, true)
	var dir_access := DirAccess.open(target_path.get_base_dir())
	if dir_access == null:
		return _fail("Could not open the mods folder", target_path, temp_path, true)

	var old_file_name := target_path.get_file()
	var new_file_name := _derive_updated_filename(old_file_name, headers, str(new_cfg.get_value("mod", "version", "")))
	var new_path := target_path.get_base_dir().path_join(new_file_name)
	# Read before the old archive goes: an id-less mod's key moves to the new name.
	var old_key := ""
	if FileAccess.file_exists(target_path):
		old_key = _archive_profile_key(old_file_name, target_path)

	if not _same_file_name(new_file_name, old_file_name) and FileAccess.file_exists(new_path):
		DirAccess.remove_absolute(temp_path)
		if not _update_already_installed_at(new_path, new_cfg):
			return _fail("A different file named \"%s\" is already in the mods folder -- move or delete it and retry" % new_file_name, target_path, "", true)
		# An earlier update put this version there; the next scan hides the older copy.
		if FileAccess.file_exists(target_path) and DirAccess.remove_absolute(target_path) != OK:
			_log_warning("[Updates] %s is already installed as %s; could not remove the old copy"
					% [old_file_name, new_file_name])
		_finish_install(new_path, ref, _cfg_mod_version(read_mod_config(new_path)["cfg"]), old_key)
		return {"ok": true, "new_file_name": new_file_name}

	if FileAccess.file_exists(target_path) and dir_access.rename(old_file_name, backup_path.get_file()) != OK:
		return _fail("Could not back up the current archive (file in use?) -- close anything using it and retry", target_path, temp_path, true)
	if not _place_download(dir_access, temp_path, new_file_name, backup_path):
		return _fail("Could not finalize the update (file may be locked) -- the old version was kept", target_path, temp_path, true)
	_static_remove_file(backup_path)
	_finish_install(new_path, ref, file_version, old_key)
	return {"ok": true, "new_file_name": new_file_name}

func _fail(msg: String, target_path := "", temp_path := "", local := false) -> Dictionary:
	if temp_path != "":
		DirAccess.remove_absolute(temp_path)
	if target_path != "":
		return {"ok": false, "new_file_name": target_path.get_file(), "error": msg, "local": local}
	return {"ok": false, "file_name": "", "error": msg}

func _inspect_download(temp_path: String, ext: String) -> Dictionary:
	if ext.to_lower() == "pck":
		var f := FileAccess.open(temp_path, FileAccess.READ)
		var magic := f.get_buffer(4) if f != null else PackedByteArray()
		if f != null:
			f.close()
		if magic != PackedByteArray([0x47, 0x44, 0x50, 0x43]):  # "GDPC"
			return {"ok": false, "cfg": null, "error": "Downloaded file is not a valid .pck"}
		return {"ok": true, "cfg": null, "error": ""}
	var zr := ZIPReader.new()
	if zr.open(temp_path) != OK:
		return {"ok": false, "cfg": null, "error": "Downloaded file is not a valid archive"}
	zr.close()
	return {"ok": true, "cfg": read_mod_config(temp_path)["cfg"], "error": ""}

func _place_download(dir: DirAccess, temp_path: String, dest_name: String, backup_path: String = "") -> bool:
	if dir.rename(temp_path.get_file(), dest_name) == OK:
		return true
	if backup_path != "" and FileAccess.file_exists(backup_path):
		dir.rename(backup_path.get_file(), backup_path.get_file().get_basename())
	return false

func _finish_install(new_path: String, ref: Dictionary, version: String, old_key: String = "") -> void:
	var new_key := _archive_profile_key(new_path.get_file(), new_path)
	if old_key.begins_with("zip:"):
		_move_profile_key(old_key, new_key)
	_persist_single_mod_source(new_key, {"provider": str(ref["provider"]), "id": str(ref["id"]), "version": version})

func _update_names_another_mod(target_path: String, new_cfg: ConfigFile, provider: String) -> String:
	var old_cfg: ConfigFile = read_mod_config(target_path)["cfg"] if FileAccess.file_exists(target_path) else null
	var old_id := _cfg_mod_id(old_cfg)
	var new_id := _cfg_mod_id(new_cfg)
	if old_id == "" or new_id == "" or old_id == new_id:
		return ""
	return "The file on %s is a different mod (id \"%s\", this one is \"%s\"), so the installed mod was kept. Either the mod page is serving the wrong file or this mod's mod.txt points at the wrong page." \
			% [host_display_name(provider), new_id, old_id]

func _update_already_installed_at(path: String, new_cfg: ConfigFile) -> bool:
	var cfg: ConfigFile = read_mod_config(path)["cfg"]
	if cfg == null or new_cfg == null:
		return false
	var id := _cfg_mod_id(cfg)
	if id == "" or id != _cfg_mod_id(new_cfg):
		return false
	return compare_versions(_cfg_mod_version(cfg), _cfg_mod_version(new_cfg)) >= 0

func _mod_ids_installed_from(ref: Dictionary) -> PackedStringArray:
	var ids := PackedStringArray()
	var page := host_ref_key(ref)
	if page == "":
		return ids
	var page_keys := PackedStringArray([page])
	for alias in host_ref_aliases(page):
		page_keys.append(str(alias))
	var persisted := _get_persisted_mod_sources()
	for entry in _ui_mod_entries:
		var mid := _entry_mod_key(entry)
		if mid == "" or ids.has(mid):
			continue
		for key in _entry_ref_keys(entry, persisted):
			if page_keys.has(key):
				ids.append(mid)
				break
	return ids

func _install_names_another_mod(archive_path: String, installed_ids: PackedStringArray, provider: String) -> String:
	if installed_ids.is_empty():
		return ""
	var got := _cfg_mod_id(read_mod_config(archive_path)["cfg"])
	if got == "" or installed_ids.has(got):
		return ""
	for entry in _ui_mod_entries:
		if _entry_mod_key(entry) == got:
			return "The file on %s is a different mod (id \"%s\") from the one installed from that page (\"%s\"), and that mod is already installed from elsewhere, so it was not installed. The mod page may be serving the wrong file." \
					% [host_display_name(provider), got, installed_ids[0]]
	return ""

func _install_collision(final_path: String, temp_path: String, derived_name: String) -> Dictionary:
	var downloaded_cfg: ConfigFile = read_mod_config(temp_path)["cfg"]
	DirAccess.remove_absolute(temp_path)
	if downloaded_cfg != null and _update_already_installed_at(final_path, downloaded_cfg):
		return {"ok": true, "file_name": derived_name, "error": ""}
	return _install_already_have(derived_name)

func _install_already_have(taken: String, temp_path := "") -> Dictionary:
	var r := _fail("Already have a file named " + taken, "", temp_path)
	r["code"] = DOWNLOAD_ALREADY_INSTALLED
	return r

func _same_file_name(a: String, b: String) -> bool:
	if a == b:
		return true
	return a.to_lower() == b.to_lower() and OS.get_name() in ["Windows", "macOS"]

func _install_downloaded_archive(ref: Dictionary, file: Dictionary, rename_on_collision: bool,
		expected_sha256: String, installed_ids: PackedStringArray) -> Dictionary:
	var provider := str(ref["provider"])
	var mods_dir := _mods_dir_path()
	DirAccess.make_dir_recursive_absolute(mods_dir)
	# ModWorkshop keeps "mws_mod_<id>", the name its earlier installs have.
	var stem := provider + "_" + str(ref["id"]).validate_filename()
	if provider == HOST_MODWORKSHOP:
		stem = "mws_mod_" + str(ref["id"])
	var temp_path := mods_dir.path_join(stem + ".download")
	var dl := await _http_download_to_temp(provider, str(file["download_url"]),
			PackedStringArray([_host_user_agent_header()]), temp_path, expected_sha256)
	if not dl["ok"]:
		return _fail(dl["error"])
	# Before the collision check: modpacks count "Already have" as installed.
	var other_mod := _install_names_another_mod(temp_path, installed_ids, provider)
	if other_mod != "":
		return _fail(other_mod, "", temp_path)

	var file_name := _pick_install_file_name(dl["headers"], file, stem, rename_on_collision)
	if FileAccess.file_exists(mods_dir.path_join(file_name)):
		if not rename_on_collision:
			return _install_collision(mods_dir.path_join(file_name), temp_path, file_name)
		return _install_already_have(file_name + " (and the renamed variant)", temp_path)

	var dl_ext := file_name.get_extension().to_lower()
	var inspected := _inspect_download(temp_path, dl_ext)
	if not inspected["ok"]:
		return _fail(inspected["error"], "", temp_path)
	if dl_ext != "pck" and inspected["cfg"] == null:
		_log_warning("Downloaded '%s' has no root mod.txt; installing it as a plain resource pack" % file_name)
	var dir_access := DirAccess.open(mods_dir)
	if dir_access == null:
		return _fail("Could not open the mods folder", "", temp_path)
	if not _place_download(dir_access, temp_path, file_name):
		return _fail("Could not move the downloaded file into the mods folder (file may be locked) -- close anything using it and retry", "", temp_path)
	return {"ok": true, "file_name": file_name, "error": ""}

func _pick_install_file_name(headers: PackedStringArray, file: Dictionary, stem: String,
		rename_on_collision: bool) -> String:
	var file_name := _filename_from_content_disposition(headers)
	if file_name.is_empty() and _is_safe_mod_filename(str(file["filename_hint"])):
		file_name = str(file["filename_hint"])
	if file_name.is_empty():
		file_name = stem + ".zip"
	if not rename_on_collision or not FileAccess.file_exists(_mods_dir_path().path_join(file_name)):
		return file_name
	# Server text headed into a file name; a timestamp stands in for a bad one.
	var suffix := str(file["version"]).strip_edges().lstrip("vV")
	if suffix.is_empty() or not suffix.is_valid_filename():
		suffix = str(int(Time.get_unix_time_from_system()))
	var ext := file_name.get_extension()
	return file_name.get_basename() + "-v" + suffix + ("." + ext if ext != "" else "")

func _download_failure_text(provider: String, result: int, status: int) -> String:
	if result == HTTPRequest.RESULT_BODY_SIZE_LIMIT_EXCEEDED:
		return "This file is larger than the %d MB the mod loader will download. Get it from the mod's page and put it in the mods folder yourself." % (DOWNLOAD_MAX_BYTES >> 20)
	if result != HTTPRequest.RESULT_SUCCESS:
		return "Download failed (connection error or timeout) -- check your network and retry"
	return host_error_status(provider, "Download failed (HTTP %d)" % status)

func _http_download_to_temp(provider: String, url: String, headers: PackedStringArray,
		temp_path: String, expected_sha256: String = "") -> Dictionary:
	var failure := {"ok": false, "error": "", "headers": PackedStringArray()}
	var req := HTTPRequest.new()
	req.timeout = API_DOWNLOAD_TIMEOUT
	req.body_size_limit = DOWNLOAD_MAX_BYTES
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
	if expected_sha256 != "":
		var ctx := HashingContext.new()
		ctx.start(HashingContext.HASH_SHA256)
		ctx.update(body)
		if ctx.finish().hex_encode() != expected_sha256.to_lower():
			failure["error"] = "The downloaded file does not match the checksum the modpack lists. Try again later; if it keeps failing, the file on the site may have changed."
			return failure
	_static_remove_file(temp_path)
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

func _download_resolve_failure_copy(provider: String, res: Dictionary, version: String) -> String:
	var host := host_display_name(provider)
	match res["code"]:
		HOST_ERR_VERSION_NOT_FOUND:
			return host_error_status(provider, "Version " + version + " not available on " + host)
		HOST_ERR_NOT_SCANNED:
			return "This version has not passed " + host + "'s malware scan, so it cannot be downloaded yet."
		HOST_ERR_NO_FILE:
			return host_error_status(provider, "This mod has no downloadable file on " + host + ". Check its mod page -- the author may host the download elsewhere.")
		HOST_ERR_OFFLINE:
			return "Could not reach " + host + ". Check your connection and try again."
		_:
			return host_error_message(provider, res)

func download_mod_from_ref(ref: Dictionary, version: String = "", allow_rename_on_collision: bool = false,
		expected_sha256: String = "") -> Dictionary:
	if not host_ref_valid(ref):
		return _fail("This mod has no download source recorded.")
	var provider := str(ref["provider"])
	var res := await host_resolve_file(ref, version)
	if not res["ok"]:
		var failure := _fail(_download_resolve_failure_copy(provider, res, version))
		failure["code"] = res["code"]
		return failure
	var file: Dictionary = res["data"]
	# Read after the resolve, which has paired the page's slug and UUID.
	var installed_ids := _mod_ids_installed_from(ref)
	var r := await _install_downloaded_archive(ref, file, allow_rename_on_collision, expected_sha256, installed_ids)
	if r["ok"]:
		_finish_install(_mods_dir_path().path_join(str(r["file_name"])), ref, str(file["version"]))
	return r
