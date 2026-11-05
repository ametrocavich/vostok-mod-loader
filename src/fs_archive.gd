## Archives on disk: vmz cache copies, mounting, folder-mod zipping, and reading
## mod.txt (including the unquoted [hooks] lists it allows).

const TRACKED_EXTENSIONS: Array[String] = ["gd", "tscn", "tres", "gdns", "gdnlib", "scn"]

# load_resource_pack picks its reader by extension and refuses .vmz, so a .vmz
# is copied to the cache as .zip; the <zip>.src sidecar holds the source mtime:size.
static func _static_vmz_to_zip(vmz_path: String) -> String:
	var cache_dir := ProjectSettings.globalize_path(TMP_DIR)
	if not DirAccess.dir_exists_absolute(cache_dir):
		DirAccess.make_dir_recursive_absolute(cache_dir)
	if not FileAccess.file_exists(vmz_path):
		return ""
	var zip_path := cache_dir.path_join(vmz_path.get_file().get_basename() + ".zip")
	var sidecar_path := zip_path + ".src"
	var src := FileAccess.open(vmz_path, FileAccess.READ)
	if src == null:
		return ""
	var src_stamp := "%d:%d" % [FileAccess.get_modified_time(vmz_path), src.get_length()]
	if FileAccess.file_exists(zip_path) and FileAccess.file_exists(sidecar_path) \
			and FileAccess.get_file_as_string(sidecar_path).strip_edges() == src_stamp:
		return zip_path
	# The sidecar goes first so an interrupted copy never leaves a stamp vouching for it.
	_static_remove_file(sidecar_path)
	var dst := FileAccess.open(zip_path, FileAccess.WRITE)
	if dst == null:
		return ""
	var src_len := src.get_length()
	while src.get_position() < src_len:
		var chunk := src.get_buffer(65536)
		# A failed read returns an empty buffer without advancing.
		if chunk.is_empty():
			break
		dst.store_buffer(chunk)
	var copy_ok := dst.get_error() == OK
	src.close()
	dst.close()
	# A disk-full copy must not get a stamp every later launch would trust.
	var written_len := -1
	var chk := FileAccess.open(zip_path, FileAccess.READ)
	if chk != null:
		written_len = chk.get_length()
		chk.close()
	if not copy_ok or written_len != src_len:
		DirAccess.remove_absolute(zip_path)
		return ""
	var out := FileAccess.open(sidecar_path, FileAccess.WRITE)
	if out != null:
		out.store_string(src_stamp)
		out.close()
	return zip_path

static func _write_filescope_log(lines: PackedStringArray) -> void:
	for line in lines:
		print(line)
	var f := FileAccess.open("user://modloader_filescope.log", FileAccess.WRITE)
	if f:
		for line in lines:
			f.store_line(line)
		f.close()

# override.cfg minus [autoload] and [autoload_prepend], so user settings survive a rewrite.
static func _read_preserved_cfg_sections(cfg_path: String) -> String:
	if not FileAccess.file_exists(cfg_path):
		return ""
	var result := PackedStringArray()
	var in_autoload := false
	for line in FileAccess.get_file_as_string(cfg_path).split("\n"):
		var stripped := line.strip_edges()
		if stripped.begins_with("["):
			in_autoload = stripped.to_lower() in ["[autoload]", "[autoload_prepend]"]
			if not in_autoload:
				result.append(line)
		elif not in_autoload and stripped != "":
			result.append(line)
	var preserved := "\n".join(result).strip_edges()
	return "" if preserved.is_empty() else "\n" + preserved + "\n"

# A zip entry as a res:// path, or "" for hidden files, mod.txt and untracked types.
func _normalize_to_res_path(zip_path: String) -> String:
	var path := zip_path.replace("\\", "/")
	if path.begins_with("res://"):
		return path
	if path.begins_with("/"):
		return "res:/" + path
	if path.begins_with(".") or path == "mod.txt":
		return ""
	if path.get_extension().to_lower() in TRACKED_EXTENSIONS:
		return "res://" + path
	return ""

# Static so static init mounts through it, hence push_warning. Nothing is loaded: the
# engine follows a mounted .remap itself, and a load() here would pin scripts as vanilla.
static func _try_mount_pack(path: String) -> bool:
	if ProjectSettings.load_resource_pack(path):
		return true
	var ext := path.get_extension().to_lower()
	if ext == "pck":
		var why := _pck_v4_warning(path)
		if why != "":
			push_warning("[ModLoader][Warning] " + why)
	if ext != "vmz":
		return false
	var zip_path := _static_vmz_to_zip(path)
	return not zip_path.is_empty() and ProjectSettings.load_resource_pack(zip_path)

## {cfg, status, error, files}: status is ok, none, parse_error or nested:<path>;
## files holds every archive entry as a res:// path when a root mod.txt exists.
func read_mod_config(path: String) -> Dictionary:
	var read := _mod_txt_read("none")
	var zr := ZIPReader.new()
	if zr.open(path) != OK:
		return read
	if not zr.file_exists("mod.txt"):
		for f: String in zr.get_files():
			if f.get_file() == "mod.txt":
				read["status"] = "nested:" + f
				break
		zr.close()
		return read
	var raw := zr.read_file("mod.txt")
	var files := {}
	for zf: String in zr.get_files():
		files["res://" + zf] = true
	zr.close()
	if raw.size() == 0:
		read["status"] = "parse_error"
	else:
		read = _parse_mod_txt(raw.get_string_from_utf8())
	read["files"] = files
	return read

func read_mod_config_folder(folder_path: String) -> Dictionary:
	var mod_txt_path := folder_path.path_join("mod.txt")
	if not FileAccess.file_exists(mod_txt_path):
		return _mod_txt_read("none")
	var f := FileAccess.open(mod_txt_path, FileAccess.READ)
	if f == null:
		return _mod_txt_read("none")
	return _parse_mod_txt(f.get_as_text())

func _mod_txt_read(status: String) -> Dictionary:
	return {"cfg": null, "status": status, "error": "", "files": {}}

# A read_mod_config record with no files; error names the first line that breaks the parse.
func _parse_mod_txt(text: String) -> Dictionary:
	var read := _mod_txt_read("parse_error")
	if text.begins_with("\uFEFF"):
		text = text.substr(1)
	var preprocessed := _quote_unquoted_hooks_values(text)
	var cfg := ConfigFile.new()
	if cfg.parse(preprocessed) != OK:
		read["error"] = _mod_txt_error_line(preprocessed)
		return read
	# ConfigFile drops empty sections; a bare [registry] is a presence signal and an
	# unknown header must reach the unrecognized-section notice, so both get a key.
	for line in text.split("\n"):
		var stripped := line.strip_edges()
		if not (stripped.begins_with("[") and stripped.ends_with("]")):
			continue
		var section := stripped.substr(1, stripped.length() - 2)
		if cfg.has_section(section):
			continue
		if section == "registry" or not (section in MOD_TXT_KNOWN_SECTIONS):
			cfg.set_value(section, "_modloader_header_present", true)
	read["cfg"] = cfg
	read["status"] = "ok"
	return read

# "line N [section]: text" for the first content line after the last prefix that parses.
# parse() names no line, and a per-line probe would blame a value spanning several lines.
func _mod_txt_error_line(text: String) -> String:
	var lines := text.split("\n")
	var last_ok := 0
	var prefix := ""
	for i in lines.size():
		prefix += lines[i] + "\n"
		if ConfigFile.new().parse(prefix) == OK:
			last_ok = i + 1
	var section := ""
	for i in lines.size():
		var stripped := lines[i].strip_edges()
		if stripped.is_empty() or stripped.begins_with("#") or stripped.begins_with(";"):
			continue
		if i >= last_ok:
			var label := ("[%s]" % section) if section != "" else "(no section)"
			var shown := stripped if stripped.length() <= 80 else stripped.substr(0, 77) + "..."
			return "line %d %s: %s" % [i + 1, label, shown]
		if stripped.begins_with("[") and stripped.ends_with("]"):
			section = stripped.substr(1, stripped.length() - 2)
	return "could not pin line (every prefix of the file parses, the whole does not)"

# ConfigFile rejects the documented unquoted [hooks] lists (`a, b`, `*`), so they are
# quoted; an inline # or ; comment is cut first or it would land inside the string.
func _quote_unquoted_hooks_values(text: String) -> String:
	var out := PackedStringArray()
	var in_hooks := false
	for line in text.split("\n"):
		var stripped := line.strip_edges()
		if stripped.begins_with("[") and stripped.ends_with("]"):
			in_hooks = stripped.to_lower() == "[hooks]"
			out.append(line)
			continue
		var eq_pos := line.find("=")
		if not in_hooks or stripped.is_empty() or stripped.begins_with("#") \
				or stripped.begins_with(";") or eq_pos < 0 \
				or line.substr(eq_pos + 1).strip_edges(true, false).begins_with("\""):
			out.append(line)
			continue
		var val_part := line.substr(eq_pos + 1)
		var comment := ""
		for j in val_part.length():
			if val_part[j] == "#" or val_part[j] == ";":
				comment = val_part.substr(j)
				val_part = val_part.substr(0, j)
				break
		var escaped := val_part.strip_edges().replace("\\", "\\\\").replace("\"", "\\\"")
		var rebuilt := "%s= \"%s\"" % [line.substr(0, eq_pos), escaped]
		if not comment.is_empty():
			rebuilt += "  " + comment
		out.append(rebuilt)
	return "\n".join(out)

# zip_folder_to_temp, _collect_enabled_archive_paths and the re-mount guard in
# _process_mod_candidate must agree on this path.
func _folder_dev_zip_path(folder_path: String) -> String:
	return ProjectSettings.globalize_path(TMP_DIR).path_join(folder_path.get_file() + "_dev.zip")

func _folder_dev_zip_current(tmp_zip_path: String) -> bool:
	var sidecar := tmp_zip_path + ".src"
	if not FileAccess.file_exists(tmp_zip_path) or not FileAccess.file_exists(sidecar):
		return false
	var stored := FileAccess.get_file_as_string(sidecar).strip_edges()
	return not stored.is_empty() and stored == _folder_dev_zip_stamp(tmp_zip_path)

# The "root:" layout token invalidates old caches; a zip layout change needs a new token.
func _folder_dev_zip_stamp(tmp_zip_path: String) -> String:
	return "root:" + str(_stable_path_stamp(tmp_zip_path))

func zip_folder_to_temp(folder_path: String) -> String:
	var tmp_zip_path := _folder_dev_zip_path(folder_path)
	# Stamped before zipping, so an editor save landing mid-zip reads stale next launch.
	var pre_zip_stamp := _folder_dev_zip_stamp(tmp_zip_path)
	var sidecar := tmp_zip_path + ".src"
	_static_remove_file(sidecar)
	var zp := ZIPPacker.new()
	if zp.open(tmp_zip_path) != OK:
		_log_critical("Failed to create temp zip: " + tmp_zip_path)
		return ""
	# Contents at the archive root, so a dev folder mounts like the shipped zip.
	var zip_ok := _zip_folder_recursive(zp, folder_path, "")
	zip_ok = zp.close() == OK and zip_ok
	# _folder_dev_zip_current checks folder state only, never zip integrity.
	if not zip_ok:
		DirAccess.remove_absolute(tmp_zip_path)
		_log_critical("Failed writing temp zip: " + tmp_zip_path)
		return ""
	var sf := FileAccess.open(sidecar, FileAccess.WRITE)
	if sf != null:
		sf.store_string(pre_zip_stamp)
		sf.close()
	return tmp_zip_path

# False when any entry failed to read or write; the caller must not stamp that zip.
func _zip_folder_recursive(zp: ZIPPacker, disk_path: String, archive_prefix: String) -> bool:
	var dir := DirAccess.open(disk_path)
	if dir == null:
		return false
	var ok := true
	dir.list_dir_begin()
	while true:
		var entry := dir.get_next()
		if entry == "":
			break
		if entry.begins_with("."):
			continue
		var full := disk_path.path_join(entry)
		var arc_path := entry if archive_prefix == "" else archive_prefix.path_join(entry)
		if dir.current_is_dir():
			ok = _zip_folder_recursive(zp, full, arc_path) and ok
		else:
			var data := FileAccess.get_file_as_bytes(full)
			# An unreadable file also reads as empty; only the open error tells them apart.
			if data.is_empty() and FileAccess.get_open_error() != OK:
				ok = false
			ok = zp.start_file(arc_path) == OK and ok
			ok = zp.write_file(data) == OK and ok
			ok = zp.close_file() == OK and ok
	dir.list_dir_end()
	return ok
