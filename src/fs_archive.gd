## ----- fs_archive.gd -----
## File and archive helpers. No game-specific logic; just disk I/O, zip
## packing/unpacking, mod.txt parsing, and path normalization. Used by most
## other domains.

# Copies a .vmz to the cache dir as .zip (same content, different extension)
# so ZIPReader can open it. Returns the cached zip path, or "" on failure.
# Cache identity is the source's mtime+size, recorded in a <zip>.src sidecar
# at copy time: ANY mismatch (newer, older, or different size) re-copies, so
# downgrading/restoring a .vmz whose preserved timestamp is older than the
# cache never mounts the previous version's cached content. A missing or
# unreadable sidecar (legacy cache, interrupted copy) also forces a re-copy.
static func _static_vmz_to_zip(vmz_path: String) -> String:
	var cache_dir := ProjectSettings.globalize_path(TMP_DIR)
	if not DirAccess.dir_exists_absolute(cache_dir):
		DirAccess.make_dir_recursive_absolute(cache_dir)
	# Defensive: never return a stale cache pointer when the source is gone.
	# Both current call sites verify existence first, so this is a no-op for
	# the happy path; the guard prevents future callers from accidentally
	# resurrecting deleted-source content via a same-basename cache hit.
	if not FileAccess.file_exists(vmz_path):
		return ""
	var zip_name := vmz_path.get_file().get_basename() + ".zip"
	var zip_path := cache_dir.path_join(zip_name)
	var sidecar_path := zip_path + ".src"
	var src := FileAccess.open(vmz_path, FileAccess.READ)
	if src == null:
		return ""
	var src_stamp := "%d:%d" % [FileAccess.get_modified_time(vmz_path), src.get_length()]
	if FileAccess.file_exists(zip_path):
		var cached_stamp := ""
		var sf := FileAccess.open(sidecar_path, FileAccess.READ)
		if sf != null:
			cached_stamp = sf.get_as_text().strip_edges()
			sf.close()
		if cached_stamp == src_stamp:
			src.close()
			return zip_path
	# Drop the old sidecar before rewriting the zip so an interrupted copy can
	# never leave a stamp that vouches for mismatched content.
	if FileAccess.file_exists(sidecar_path):
		DirAccess.remove_absolute(sidecar_path)
	var dst := FileAccess.open(zip_path, FileAccess.WRITE)
	if dst == null:
		src.close()
		return ""
	var src_len := src.get_length()
	while src.get_position() < src_len:
		var chunk := src.get_buffer(65536)
		# A failed read (yanked device, file shrunk under us) returns an empty
		# buffer WITHOUT advancing the position -- break instead of spinning
		# forever; the length re-verification below rejects the truncated copy.
		if chunk.is_empty():
			break
		dst.store_buffer(chunk)
	var copy_ok := dst.get_error() == OK
	src.close()
	dst.close()
	# Verify the cache zip is complete before writing the .src stamp that
	# vouches for it. store_buffer() returns a bool since Godot 4.3, but the
	# loop above doesn't check per-chunk (get_error() below catches it), so a
	# disk-full / IO failure mid-copy would otherwise leave a truncated zip
	# with a valid-looking stamp that every future launch trusts as good.
	var chk := FileAccess.open(zip_path, FileAccess.READ)
	var written_len := chk.get_length() if chk != null else -1
	if chk != null:
		chk.close()
	if not copy_ok or written_len != src_len:
		DirAccess.remove_absolute(zip_path)
		return ""
	var out := FileAccess.open(sidecar_path, FileAccess.WRITE)
	if out != null:
		out.store_string(src_stamp)
		out.close()
	# A failed sidecar write just means the next launch re-copies -- safe.
	return zip_path

# Prints all log lines AND dumps them to user://modloader_filescope.log for
# post-mortem inspection. Called from _mount_previous_session after the static
# init pass finishes (before any normal logging is wired up).
static func _write_filescope_log(lines: PackedStringArray) -> void:
	for line in lines:
		print(line)
	var f := FileAccess.open("user://modloader_filescope.log", FileAccess.WRITE)
	if f:
		for line in lines:
			f.store_line(line)
		f.close()

# Reads override.cfg and returns lines for sections OTHER than [autoload] and
# [autoload_prepend]. Used to preserve user/game settings ([display], [input],
# etc.) when rewriting autoload sections.
static func _read_preserved_cfg_sections(cfg_path: String) -> String:
	if not FileAccess.file_exists(cfg_path):
		return ""
	var f := FileAccess.open(cfg_path, FileAccess.READ)
	if f == null:
		return ""
	var text := f.get_as_text()
	f.close()
	var result := PackedStringArray()
	var in_autoload_section := false
	for line in text.split("\n"):
		var stripped := line.strip_edges()
		if stripped.begins_with("["):
			var section := stripped.to_lower()
			in_autoload_section = section == "[autoload]" or section == "[autoload_prepend]"
			if not in_autoload_section:
				result.append(line)
			continue
		if not in_autoload_section and stripped != "":
			result.append(line)
	var preserved := "\n".join(result).strip_edges()
	if preserved.is_empty():
		return ""
	return "\n" + preserved + "\n"

# Converts zip-relative paths to res:// paths for tracked file extensions.
# Returns "" for paths we don't want to track (hidden files, mod.txt, etc.)
func _normalize_to_res_path(zip_path: String) -> String:
	var path := zip_path.replace("\\", "/")
	if path.begins_with("res://"):   return path
	if path.begins_with("/"):        return "res:/" + path
	if path.begins_with(".") or path == "mod.txt": return ""
	if path.get_extension().to_lower() in TRACKED_EXTENSIONS:
		return "res://" + path
	return ""

# Mount a .pck or .vmz archive via ProjectSettings.load_resource_pack, with
# vmz->zip caching for .vmz files. Resolves .remap entries in the archive
# after a successful mount so preload()/load() calls targeting original
# .tscn/.tres paths work (load_resource_pack doesn't follow remaps).
func _try_mount_pack(path: String) -> bool:
	if ProjectSettings.load_resource_pack(path):
		_resolve_remaps(path)
		return true
	if path.get_extension().to_lower() != "vmz":
		return false
	var zip_path := _static_vmz_to_zip(path)
	if not zip_path.is_empty() and ProjectSettings.load_resource_pack(zip_path):
		_resolve_remaps(zip_path)
		return true
	return false

# Resolve .remap files in a mounted archive so preload()/load() work with
# the original .tscn/.tres paths (load_resource_pack doesn't follow remaps).
func _resolve_remaps(archive_path: String) -> void:
	var remap_count := _static_resolve_remaps(archive_path)
	if remap_count > 0:
		_log_debug("  Resolved %d .remap file(s)" % remap_count)

# Same as _resolve_remaps but static, callable from _mount_previous_session
# at static-init time (before the node has instance state).
static func _static_resolve_remaps(archive_path: String) -> int:
	var zr := ZIPReader.new()
	if zr.open(archive_path) != OK:
		return 0

	var count := 0
	for f: String in zr.get_files():
		if not f.ends_with(".remap"):
			continue
		var remap_bytes := zr.read_file(f)
		if remap_bytes.is_empty():
			continue
		var cfg := ConfigFile.new()
		if cfg.parse(remap_bytes.get_string_from_utf8()) != OK:
			continue
		var target: String = cfg.get_value("remap", "path", "")
		if target.is_empty():
			continue
		# Skip remaps pointing to .godot/exported/ bakes. Mods like MCM ship
		# their own .godot cache with pre-compiled scenes; eagerly take_over_path'ing
		# those before mod scripts register causes UID resolution failures that
		# break the mod's UI. Godot resolves these lazily via the .remap files
		# when actually needed. Credit: tetrahydroc.
		if target.begins_with("res://.godot/exported/"):
			continue
		var original_path := f.trim_suffix(".remap")
		if not original_path.begins_with("res://"):
			original_path = "res://" + original_path
		var res: Resource = load(target)
		if res != null:
			res.take_over_path(original_path)
			count += 1
	zr.close()
	return count

# mod.txt parser

func read_mod_config(path: String) -> ConfigFile:
	_last_mod_txt_status = "none"
	# Reset diagnostic alongside status: paths below (empty mod.txt, missing
	# mod.txt, ZIPReader open failure) set parse_error without going through
	# _parse_mod_txt, so without this reset the prior mod's error message
	# would leak into the next mod's launcher warning.
	_last_mod_txt_error = ""
	var zr := ZIPReader.new()
	if zr.open(path) != OK:
		return null
	if not zr.file_exists("mod.txt"):
		# Nested mod.txt (e.g. "SubFolder/mod.txt") means bad packaging.
		for f: String in zr.get_files():
			if f.get_file() == "mod.txt":
				_last_mod_txt_status = "nested:" + f
				zr.close()
				return null
		zr.close()
		return null
	var raw := zr.read_file("mod.txt")
	zr.close()
	if raw.size() == 0:
		_last_mod_txt_status = "parse_error"
		return null
	var text := raw.get_string_from_utf8()
	var cfg := _parse_mod_txt(text)
	if cfg == null:
		_last_mod_txt_status = "parse_error"
		return null
	_last_mod_txt_status = "ok"
	return cfg

func read_mod_config_folder(folder_path: String) -> ConfigFile:
	_last_mod_txt_status = "none"
	_last_mod_txt_error = ""  # see read_mod_config for rationale
	var mod_txt_path := folder_path.path_join("mod.txt")
	if not FileAccess.file_exists(mod_txt_path):
		return null
	var f := FileAccess.open(mod_txt_path, FileAccess.READ)
	if f == null:
		return null
	var text := f.get_as_text()
	f.close()
	var cfg := _parse_mod_txt(text)
	if cfg == null:
		_last_mod_txt_status = "parse_error"
		return null
	_last_mod_txt_status = "ok"
	return cfg

func _parse_mod_txt(text: String) -> ConfigFile:
	_last_mod_txt_error = ""
	if text.begins_with("\uFEFF"):
		text = text.substr(1)
	# Tolerate the wiki-documented [hooks] form. The Hooks/Mod-Format wiki
	# pages show entries like:
	#     res://Scripts/Interface.gd = _ready, update_tooltip
	#     res://Scripts/Controller.gd = *
	# but Godot's ConfigFile uses the Variant parser for values, which
	# rejects unquoted identifier lists, bare `*`, and top-level commas.
	# Authors following the docs verbatim hit a parse_error and the generic
	# "Invalid mod -- try re-downloading" prompt. Quote-wrapping the values
	# before cfg.parse() lets the wiki form land as a string and downstream
	# code (mod_loading.gd's [hooks] reader) handles the comma-split itself.
	# Already-quoted entries pass through unchanged.
	var preprocessed := _quote_unquoted_hooks_values(text)
	var cfg := ConfigFile.new()
	if cfg.parse(preprocessed) != OK:
		# The Variant-parser failure code from cfg.parse() doesn't carry the
		# offending line number. Walk the source per-line to locate it; the
		# diagnostic flows through _last_mod_txt_error -> mod_txt_error on
		# the entry -> launcher warning + boot log so authors see the broken
		# section/line instead of a generic "re-download" hint.
		_last_mod_txt_error = _diagnose_parse_failure(preprocessed)
		return null
	# Godot's ConfigFile drops empty sections, so a bare `[registry]` header
	# with no body gets silently dropped and cfg.has_section("registry") returns
	# false. [registry] is a presence-signal section (its body is parsed by
	# per-kind registry handlers at call sites, not mod-load time), so an empty
	# header is the common legitimate form. Scan the raw text for the header
	# and stash a sentinel key so has_section picks it up downstream.
	for line in text.split("\n"):
		var stripped := line.strip_edges()
		if stripped == "[registry]" and not cfg.has_section("registry"):
			cfg.set_value("registry", "_modloader_header_present", true)
			break
	return cfg

# Quote the values of unquoted entries inside [hooks] sections. Wiki examples
# document `path = method1, method2` / `path = *` / `path =` -- all rejected
# by ConfigFile's Variant parser. Wrap unquoted right-hand-sides in double
# quotes so they parse as plain strings; mod_loading.gd's [hooks] handler
# already comma-splits and lowercases the result.
#
# Already-quoted values (the AI Overhaul pattern) pass through verbatim so
# we don't change behavior for mods that got the syntax right. Inline
# `# comment` / `; comment` on these lines is stripped before wrapping --
# Variant parser eats it natively for raw values, but once we quote the
# right-hand side a trailing comment becomes part of the string.
func _quote_unquoted_hooks_values(text: String) -> String:
	var lines := text.split("\n")
	var out := PackedStringArray()
	var in_hooks := false
	for line in lines:
		var stripped := line.strip_edges()
		# Section header: track whether we just entered/left [hooks].
		if stripped.begins_with("[") and stripped.ends_with("]"):
			in_hooks = stripped.to_lower() == "[hooks]"
			out.append(line)
			continue
		if not in_hooks:
			out.append(line)
			continue
		if stripped.is_empty() or stripped.begins_with("#") or stripped.begins_with(";"):
			out.append(line)
			continue
		var eq_pos := line.find("=")
		if eq_pos < 0:
			out.append(line)
			continue
		var key_part := line.substr(0, eq_pos)
		var val_part := line.substr(eq_pos + 1)
		if val_part.strip_edges(true, false).begins_with("\""):
			# Already quoted -- ConfigFile + Variant parser handle it.
			out.append(line)
			continue
		var comment := ""
		var comment_pos := -1
		for j in val_part.length():
			var ch := val_part[j]
			if ch == "#" or ch == ";":
				comment_pos = j
				break
		if comment_pos >= 0:
			comment = val_part.substr(comment_pos)
			val_part = val_part.substr(0, comment_pos)
		var val_trim := val_part.strip_edges()
		var escaped := val_trim.replace("\\", "\\\\").replace("\"", "\\\"")
		var rebuilt := "%s= \"%s\"" % [key_part, escaped]
		if not comment.is_empty():
			rebuilt += "  " + comment
		out.append(rebuilt)
	return "\n".join(out)

# Locate the first line that ConfigFile.parse() would reject. Used only on
# the failure path -- the per-line probe is O(N) parses but only fires when
# the mod is already broken, and the result lets the launcher tell authors
# *which* line/section to look at instead of "Invalid mod, re-download".
func _diagnose_parse_failure(text: String) -> String:
	var current_section := ""
	var line_num := 0
	for line in text.split("\n"):
		line_num += 1
		var stripped := line.strip_edges()
		if stripped.is_empty() or stripped.begins_with("#") or stripped.begins_with(";"):
			continue
		if stripped.begins_with("[") and stripped.ends_with("]"):
			current_section = stripped.substr(1, stripped.length() - 2)
			continue
		var probe := ConfigFile.new()
		var header := ""
		if current_section != "":
			header = "[%s]\n" % current_section
		if probe.parse(header + line + "\n") != OK:
			var section_label := ("[%s]" % current_section) if current_section != "" else "(no section)"
			return "line %d %s: %s" % [line_num, section_label, _truncate_for_log(stripped)]
	# Fall-through: per-line probes all passed but the full parse failed.
	# Could happen with a section-header / multi-line value interaction we
	# don't model. Return a generic locator so the user at least knows we
	# detected the failure but couldn't pin the line.
	return "could not pin line (full parse failed but per-line probes passed)"

func _truncate_for_log(s: String) -> String:
	if s.length() <= 80:
		return s
	return s.substr(0, 77) + "..."

# Folder -> temp zip (developer mode). Zips a mod's source folder to a temp
# .zip in the cache dir so it can be mounted like any other archive.

# Cache path for a folder mod's temp zip. Shared by zip_folder_to_temp,
# _collect_enabled_archive_paths and _process_mod_candidate's re-mount guard
# -- all of them must agree on the folder's mount identity.
func _folder_dev_zip_path(folder_path: String) -> String:
	return ProjectSettings.globalize_path(TMP_DIR).path_join(
			folder_path.get_file() + "_dev.zip")

# True when the cached temp zip still matches the source folder's current
# content. Compares the folder-state hash recorded in the .src sidecar at
# zip time against _stable_path_mtime's hash of the folder NOW (newest
# mtime + file count + per-file path@mtime set hash -- so deletions and
# timestamp downgrades are caught, not just newer files). A missing zip or
# sidecar reads as stale, which just forces a rebuild.
func _folder_dev_zip_current(tmp_zip_path: String) -> bool:
	if not FileAccess.file_exists(tmp_zip_path):
		return false
	var f := FileAccess.open(tmp_zip_path + ".src", FileAccess.READ)
	if f == null:
		return false
	var stored := f.get_as_text().strip_edges()
	f.close()
	return not stored.is_empty() and stored == str(_stable_path_mtime(tmp_zip_path))

func zip_folder_to_temp(folder_path: String) -> String:
	var folder_name := folder_path.get_file()
	var tmp_zip_path := _folder_dev_zip_path(folder_path)
	# Capture the folder-state hash BEFORE zipping (_stable_path_mtime walks
	# the SOURCE folder for *_dev.zip paths, so this is valid even before the
	# zip exists). Stamping the pre-zip state means an editor save landing
	# mid-zip mismatches on the next launch and forces a rebuild, instead of
	# vouching for content the zip never captured.
	var pre_zip_stamp := str(_stable_path_mtime(tmp_zip_path))
	# Drop the old sidecar before rewriting the zip so an interrupted build
	# can never leave a stamp that vouches for mismatched content (same guard
	# as _static_vmz_to_zip).
	var sidecar := tmp_zip_path + ".src"
	if FileAccess.file_exists(sidecar):
		DirAccess.remove_absolute(sidecar)
	var zp := ZIPPacker.new()
	if zp.open(tmp_zip_path) != OK:
		_log_critical("Failed to create temp zip: " + tmp_zip_path)
		return ""
	# Wrap zip entries under the folder name so res:// paths match what a
	# conventionally-packed .zip mod produces. A folder at <mods>/MyMod/
	# containing data/main.gd mounts as res://MyMod/data/main.gd, the same
	# layout you'd get if MyMod/ were inside a .zip. Without this wrapper,
	# folder mode dropped contents at res:// directly, so a mod.txt path of
	# res://MyMod/data/main.gd worked from .zip but resolved nowhere from
	# the folder. (Pre-v3.1.2 folder mods that relied on the unwrapped
	# layout need their mod.txt paths re-prefixed with the folder name.)
	var zip_ok := _zip_folder_recursive(zp, folder_path, folder_name)
	zip_ok = zp.close() == OK and zip_ok
	# Never stamp a zip that didn't fully write: a mid-zip failure can still
	# close a structurally valid but incomplete zip, and the sidecar would
	# vouch for it on every future launch (_folder_dev_zip_current only
	# compares folder state, never zip integrity).
	if not zip_ok:
		DirAccess.remove_absolute(tmp_zip_path)
		_log_critical("Failed writing temp zip: " + tmp_zip_path)
		return ""
	# Record the folder-state hash captured before zipping so
	# _folder_dev_zip_current can tell a current cache from a stale one. Same
	# .zip.src sidecar convention as the vmz cache -- _clean_stale_cache
	# removes orphans either way.
	var sf := FileAccess.open(sidecar, FileAccess.WRITE)
	if sf != null:
		sf.store_string(pre_zip_stamp)
		sf.close()
	return tmp_zip_path

# Returns false if any entry failed to read or write -- the caller must not
# stamp (or keep) the resulting zip in that case.
func _zip_folder_recursive(zp: ZIPPacker, disk_path: String, archive_prefix: String) -> bool:
	var dir := DirAccess.open(disk_path)
	if dir == null:
		return true
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
			# get_file_as_bytes silently returns an empty buffer for a
			# locked/unreadable file; distinguish that from a legitimately
			# empty file via the open error.
			if data.is_empty() and FileAccess.get_open_error() != OK:
				ok = false
			ok = zp.start_file(arc_path) == OK and ok
			ok = zp.write_file(data) == OK and ok
			ok = zp.close_file() == OK and ok
	dir.list_dir_end()
	return ok
