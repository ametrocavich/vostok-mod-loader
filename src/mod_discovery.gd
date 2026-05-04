## ----- mod_discovery.gd -----
## Scans the mods directory, parses mod.txt metadata, builds the ordered list
## of mod entries, and handles ModWorkshop update checking + downloads.
## Everything here feeds the UI (which renders the list) and the loading
## phase (which mounts + applies them).

func collect_mod_metadata() -> Array[Dictionary]:
	var entries: Array[Dictionary] = []
	_mods_dir = OS.get_executable_path().get_base_dir().path_join(MOD_DIR)
	_log_info("Scanning mods dir: " + _mods_dir)
	DirAccess.make_dir_recursive_absolute(_mods_dir)
	var dir := DirAccess.open(_mods_dir)
	if dir == null:
		_log_critical("Failed to open mods dir: " + _mods_dir
				+ " (error " + str(DirAccess.get_open_error()) + ")")
		return entries
	var seen: Dictionary = {}
	var skipped_files: Array[String] = []
	_hidden_folder_profile_keys.clear()
	_hidden_folder_ids.clear()
	dir.list_dir_begin()
	while true:
		var entry_name := dir.get_next()
		if entry_name == "":
			break
		if dir.current_is_dir():
			if entry_name.begins_with("."):
				continue
			if _developer_mode:
				if not seen.has(entry_name):
					seen[entry_name] = true
					entries.append(_build_folder_entry(_mods_dir, entry_name))
			else:
				# Record the folder's profile_key so orphan-detection knows the
				# mod is still on disk, just filtered. Without this, disabling
				# dev mode would flag every installed dev folder as "missing".
				_record_hidden_folder(_mods_dir, entry_name)
			continue
		var ext := entry_name.get_extension().to_lower()
		if ext not in ["vmz", "zip", "pck"]:
			skipped_files.append(entry_name)
			continue
		if seen.has(entry_name):
			continue
		seen[entry_name] = true
		entries.append(_build_archive_entry(_mods_dir, entry_name, ext))
	dir.list_dir_end()
	if skipped_files.size() > 0:
		_log_debug("Skipped " + str(skipped_files.size()) + " non-mod file(s) in mods dir:")
		for sf in skipped_files:
			_log_debug("  " + sf + "  (not .vmz/.pck)")
	if entries.size() == 0:
		_log_warning("No mods found in: " + _mods_dir)
	else:
		_log_info("Found " + str(entries.size()) + " mod(s):")
		for e in entries:
			var tag := " [folder]" if e["ext"] == "folder" else ""
			_log_info("  " + e["file_name"] + " (" + e["mod_name"] + ")" + tag)
	return entries

func _build_archive_entry(mods_dir: String, file_name: String, ext: String) -> Dictionary:
	# Breadcrumb: identifies the mod Godot's UTF-8 C++ warning (printed
	# unconditionally for non-UTF8 bytes in mod.txt / .gd / pck paths) is
	# about to complain about. Without this the user sees "Unicode parsing
	# error, some characters were replaced with ..." and can't tell which
	# mod tripped it.
	_log_info("[ModScan] inspecting " + file_name)
	var full_path := mods_dir.path_join(file_name)
	if ext == "pck":
		_last_mod_txt_status = "pck"
	var cfg: ConfigFile = read_mod_config(full_path) if ext != "pck" else null
	var entry := _entry_from_config(cfg, file_name, full_path, ext)
	entry["warnings"] = _build_entry_warnings(entry)
	entry["security_findings"] = scan_mod(full_path, ext)
	entry["risk_level"] = compute_risk_level(entry["security_findings"])
	_log_security_findings(entry)
	return entry

func _build_folder_entry(mods_dir: String, dir_name: String) -> Dictionary:
	# See _build_archive_entry for rationale.
	_log_info("[ModScan] inspecting " + dir_name + " [folder]")
	var folder_path := mods_dir.path_join(dir_name)
	var cfg: ConfigFile = read_mod_config_folder(folder_path)
	var entry := _entry_from_config(cfg, dir_name, folder_path, "folder")
	entry["warnings"] = _build_entry_warnings(entry)
	entry["security_findings"] = scan_mod(folder_path, "folder")
	entry["risk_level"] = compute_risk_level(entry["security_findings"])
	_log_security_findings(entry)
	return entry

# Track a folder mod that's on disk but excluded from _ui_mod_entries because
# developer mode is off. Lets the orphan scan tell "dev-filtered" apart from
# "truly deleted" when rendering the missing-from-profile list.
func _record_hidden_folder(mods_dir: String, dir_name: String) -> void:
	var folder_path := mods_dir.path_join(dir_name)
	var cfg: ConfigFile = read_mod_config_folder(folder_path)
	var entry := _entry_from_config(cfg, dir_name, folder_path, "folder")
	_hidden_folder_profile_keys[entry["profile_key"]] = true
	if not entry["profile_key"].begins_with("zip:"):
		_hidden_folder_ids[entry["mod_id"]] = true

# Surface scanner findings in the boot log alongside the discovery summary.
# Logged at DEBUG -- findings are *disclosures* of "this mod uses these
# notable APIs", not warnings of malice. The UI surfaces the same data
# as a tappable "Uses N notable APIs" indicator on the mod row; the user
# decides whether the mod's stated purpose matches what it actually does.
# Dev mode enables this dump for deep investigation; regular users
# already see the relevant information in the UI.
func _log_security_findings(entry: Dictionary) -> void:
	var findings: Array = entry.get("security_findings", [])
	if findings.is_empty():
		return
	_log_debug("[ModScan] %s uses %d notable API(s)" \
			% [entry["file_name"], findings.size()])
	for f: Dictionary in findings:
		var loc: String = f["file"]
		if int(f.get("line", 0)) > 0:
			loc += ":" + str(f["line"])
		_log_debug("  %s @ %s -- %s" \
				% [f["rule"], loc, f.get("preview", "")])

func _entry_from_config(cfg: ConfigFile, file_name: String, full_path: String, ext: String) -> Dictionary:
	var mod_name := file_name
	var mod_id   := file_name
	var version  := ""
	var priority := 0
	var has_mod_id := false

	# VostokMods compat: parse "100-ModName.vmz" filename priority prefix.
	# The prefix is stripped from mod_name/mod_id defaults and used as fallback priority.
	var base_name := file_name.get_basename()  # strip extension
	var filename_priority := 0
	var has_filename_priority := false
	if _re_filename_priority:
		var m := _re_filename_priority.search(base_name)
		if m:
			filename_priority = int(m.get_string(1))
			base_name = m.get_string(2)
			has_filename_priority = true
			mod_name = base_name
			mod_id   = base_name

	if cfg:
		mod_name = str(cfg.get_value("mod", "name", mod_name))
		if cfg.has_section_key("mod", "id"):
			mod_id = str(cfg.get_value("mod", "id"))
			has_mod_id = true
		version = str(cfg.get_value("mod", "version", ""))
		if cfg.has_section_key("mod", "priority"):
			priority = int(str(cfg.get_value("mod", "priority")))
		elif has_filename_priority:
			priority = filename_priority
	elif has_filename_priority:
		priority = filename_priority
	priority = clampi(priority, PRIORITY_MIN, PRIORITY_MAX)

	# Profile key identifies the mod across ZIP renames. Uses "<id>@<version>"
	# when mod.txt declares an id (empty version allowed, yielding "<id>@"),
	# otherwise falls back to "zip:<file_name>" -- without a declared id the
	# filename is all we have and renames still orphan those profile entries.
	var profile_key := ("zip:" + file_name) if not has_mod_id else (mod_id + "@" + version)

	var entry := {
		"file_name": file_name, "full_path": full_path, "ext": ext,
		"mod_name": mod_name, "mod_id": mod_id, "version": version,
		"profile_key": profile_key,
		"priority": priority, "enabled": true,
		"cfg": cfg, "mod_txt_status": _last_mod_txt_status,
		"mod_txt_error": _last_mod_txt_error,
	}
	return entry

func _build_entry_warnings(entry: Dictionary) -> Array[String]:
	var warnings: Array[String] = []
	var ext: String = entry["ext"]
	if ext == "pck" or ext == "folder":
		return warnings
	var status: String = entry.get("mod_txt_status", "none")
	if status == "none":
		warnings.append("Invalid mod -- may not work correctly. Try re-downloading.")
	elif status == "parse_error":
		# Surface the line/section the parser tripped on so authors can
		# self-correct instead of staring at a generic "re-download" hint
		# when the real problem is a typo in their own mod.txt.
		var detail: String = entry.get("mod_txt_error", "")
		if detail.is_empty():
			warnings.append("Invalid mod -- mod.txt failed to parse. Try re-downloading.")
		else:
			warnings.append("mod.txt parse error at " + detail)
	elif status.begins_with("nested:"):
		warnings.append("Invalid mod -- packaged incorrectly. Try re-downloading.")
	return warnings

# Config persistence


func _compare_load_order(a: Dictionary, b: Dictionary) -> bool:
	if a["priority"] != b["priority"]:
		return a["priority"] < b["priority"]
	var a_name := (a["mod_name"] as String).to_lower()
	var b_name := (b["mod_name"] as String).to_lower()
	if a_name != b_name:
		return a_name < b_name
	# Filename tiebreaker for stable sort.
	return (a["file_name"] as String).to_lower() < (b["file_name"] as String).to_lower()

# Returns -1/0/1 for version comparison (a < b, equal, a > b).
func compare_versions(a: String, b: String) -> int:
	if a.is_empty() or b.is_empty():
		return 0 if a == b else (-1 if a.is_empty() else 1)
	var pa := a.lstrip("vV").split(".")
	var pb := b.lstrip("vV").split(".")
	var n: int = max(pa.size(), pb.size())
	for i in n:
		var sa := pa[i] if i < pa.size() else "0"
		var sb := pb[i] if i < pb.size() else "0"
		var va := int(sa) if sa.is_valid_int() else 0
		var vb := int(sb) if sb.is_valid_int() else 0
		if va < vb: return -1
		if va > vb: return 1
	return 0

func fetch_latest_modworkshop_versions(ids: Array[int]) -> Dictionary:
	var latest_versions := {}
	for chunk_ids in _chunk_int_array(ids, MODWORKSHOP_BATCH_SIZE):
		var req := HTTPRequest.new()
		req.timeout = API_CHECK_TIMEOUT
		add_child(req)
		var err := req.request(MODWORKSHOP_VERSIONS_URL,
			PackedStringArray(["Content-Type: application/json", "Accept: application/json"]),
			HTTPClient.METHOD_GET, JSON.stringify({"mod_ids": chunk_ids}))
		if err != OK:
			req.queue_free()
			continue

		var res: Array = await req.request_completed
		req.queue_free()
		if res[0] != HTTPRequest.RESULT_SUCCESS or res[1] < 200 or res[1] >= 300:
			continue
		var parsed = JSON.parse_string((res[3] as PackedByteArray).get_string_from_utf8())
		if parsed is Dictionary:
			latest_versions.merge(parsed, true)
	return latest_versions

# Pull a usable filename out of the response's Content-Disposition header.
# Supports the common attachment; filename=X and quoted filename="X" forms,
# plus the RFC 5987 filename*=UTF-8''X variant some CDNs emit. Returns "" if
# the header is missing or the value isn't a safe basename with one of the
# extensions we already accept on disk -- we never let a server pick a path
# we wouldn't have scanned in the first place.
func _filename_from_content_disposition(headers: PackedStringArray) -> String:
	for raw in headers:
		var line: String = raw
		var colon := line.find(":")
		if colon < 0:
			continue
		if line.substr(0, colon).strip_edges().to_lower() != "content-disposition":
			continue
		var value := line.substr(colon + 1).strip_edges()
		# Try filename* first -- RFC 5987 form is unicode-safe, and servers
		# that emit both prefer the encoded one for non-ASCII names.
		var star_val := _extract_disposition_param(value, "filename*")
		if star_val != "":
			var sep := star_val.find("''")
			if sep >= 0:
				star_val = star_val.substr(sep + 2).uri_decode()
			if _is_safe_mod_filename(star_val):
				return star_val.get_file()
		var plain_val := _extract_disposition_param(value, "filename")
		if plain_val != "" and _is_safe_mod_filename(plain_val):
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

# Reject anything that isn't a plain basename with one of the mod extensions
# we accept. Stops a malicious or misconfigured server from writing under a
# parent dir or with an executable extension.
func _is_safe_mod_filename(name: String) -> bool:
	if name.is_empty():
		return false
	if name != name.get_file():
		return false
	return name.get_extension().to_lower() in ["vmz", "zip", "pck"]

# Pick the filename the validated download should land under. Prefers
# Content-Disposition; falls back to splicing the new mod.txt version onto
# the old stem (CoolMod_v1.0.zip -> CoolMod_v1.1.zip) so the filename never
# claims an older version than its contents. Returns the original filename
# unchanged when neither path produces something better -- a rename is
# best-effort and must never block an update.
func _derive_updated_filename(old_file_name: String, headers: PackedStringArray, new_version: String) -> String:
	var server_name := _filename_from_content_disposition(headers)
	if server_name != "":
		return server_name
	if new_version.is_empty():
		return old_file_name
	var ext := old_file_name.get_extension()
	var stem := old_file_name.get_basename()
	var rx := RegEx.new()
	rx.compile("[_-][vV]\\d+(?:\\.\\d+)*$")
	var stripped := rx.sub(stem, "")
	var new_stem := stripped + "_v" + new_version.lstrip("vV")
	return new_stem if ext.is_empty() else new_stem + "." + ext

# Returns { ok: bool, new_path: String, new_file_name: String }. On success
# new_path / new_file_name reflect the on-disk filename the download landed
# under -- which may differ from target_path when the server provided a
# Content-Disposition or the mod.txt version-bumped (CoolMod_v1.0.zip ->
# CoolMod_v1.1.zip). On failure the temp + backup are cleaned up and the
# original file is left intact; new_path / new_file_name echo target_path.
func download_and_replace_mod(target_path: String, modworkshop_id: int) -> Dictionary:
	var failure := {"ok": false, "new_path": target_path, "new_file_name": target_path.get_file()}

	var req := HTTPRequest.new()
	req.timeout = API_DOWNLOAD_TIMEOUT
	req.download_body_size_limit = 256 * 1024 * 1024
	add_child(req)
	var err := req.request(MODWORKSHOP_DOWNLOAD_URL_TEMPLATE % str(modworkshop_id))
	if err != OK:
		req.queue_free()
		return failure
	# request_completed -> [result, http_code, headers, body]
	var res: Array = await req.request_completed
	req.queue_free()

	if res[0] != HTTPRequest.RESULT_SUCCESS or res[1] < 200 or res[1] >= 300:
		return failure
	var headers: PackedStringArray = res[2]
	var response_body: PackedByteArray = res[3]
	if response_body.is_empty():
		return failure

	var temp_path   := target_path + ".download"
	var backup_path := target_path + ".bak"
	if FileAccess.file_exists(temp_path):   DirAccess.remove_absolute(temp_path)
	if FileAccess.file_exists(backup_path): DirAccess.remove_absolute(backup_path)

	var out := FileAccess.open(temp_path, FileAccess.WRITE)
	if out == null:
		return failure
	out.store_buffer(response_body)
	out.close()

	var new_cfg: ConfigFile = read_mod_config(temp_path)
	if new_cfg == null:
		DirAccess.remove_absolute(temp_path)
		return failure

	var dir_access := DirAccess.open(target_path.get_base_dir())
	if dir_access == null:
		DirAccess.remove_absolute(temp_path)
		return failure

	# Decide where the validated download should land.
	var old_file_name := target_path.get_file()
	var new_version := str(new_cfg.get_value("mod", "version", ""))
	var new_file_name := _derive_updated_filename(old_file_name, headers, new_version)
	var new_path := target_path.get_base_dir().path_join(new_file_name)

	# Refuse to overwrite an unrelated archive that already lives at the
	# derived path. Better to fail loudly than silently clobber a different
	# mod that happens to share the new versioned name.
	if new_file_name != old_file_name and FileAccess.file_exists(new_path):
		DirAccess.remove_absolute(temp_path)
		return failure

	# Stash the old archive under .bak so a failed rename can roll back.
	if FileAccess.file_exists(target_path):
		if dir_access.rename(target_path.get_file(), backup_path.get_file()) != OK:
			DirAccess.remove_absolute(temp_path)
			return failure

	if dir_access.rename(temp_path.get_file(), new_file_name) != OK:
		if FileAccess.file_exists(backup_path):
			dir_access.rename(backup_path.get_file(), target_path.get_file())
		DirAccess.remove_absolute(temp_path)
		return failure

	# New file is in place; the .bak (which is the old archive) can go.
	if FileAccess.file_exists(backup_path):
		DirAccess.remove_absolute(backup_path)
	return {"ok": true, "new_path": new_path, "new_file_name": new_file_name}

func _chunk_int_array(arr: Array[int], chunk_size: int) -> Array:
	var result: Array = []
	for i in range(0, arr.size(), chunk_size):
		result.append(arr.slice(i, i + chunk_size))
	return result
