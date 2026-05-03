## ----- native_extensions.gd -----
## Optional GDExtension support. Parses [gdextension] in mod.txt, validates
## paths, and at load time copies each .gdextension plus its referenced
## libraries into user://modloader_native/<safe_id>/<key>/ so
## GDExtensionManager.load_extension has a stable on-disk file to dlopen.
## Materialize+load runs after archive mount and before bridge autoloads
## instantiate, so the bridge's _ready can construct native classes and
## register them through the normal hook API.
##
## Native code can't be sandboxed -- it runs as the game process, and it's
## opaque to the source-rewrite scanner. Hook surfaces have to be declared
## explicitly via [hooks], and the launcher gates Launch behind a
## confirmation dialog whenever an enabled mod declares this section.

# Parse the [gdextension] section into the entry. Always sets all three
# keys so the UI / state hash / loader can read them without guarding:
#   entry["gdextension"]        valid entries -> { name: res_path }
#   entry["gdextension_errors"] human-readable messages, one per bad line
#   entry["has_native"]         true if the section exists at all
# An all-invalid section still flips has_native true so the launcher warns
# and the row shows the badge -- the loader map just stays empty and
# nothing materializes.
func _annotate_native_extensions(entry: Dictionary, cfg: ConfigFile) -> void:
	var ge: Dictionary = {}
	var errors: Array[String] = []
	var has_any := false
	if cfg != null and cfg.has_section("gdextension"):
		has_any = true
		for key in cfg.get_section_keys("gdextension"):
			var name := str(key).strip_edges()
			if name.is_empty():
				errors.append("[gdextension] empty key -- skipped")
				continue
			var raw_val: Variant = cfg.get_value("gdextension", key, "")
			if not (raw_val is String):
				errors.append("[gdextension] %s: value must be a quoted res:// path" % name)
				continue
			var val := str(raw_val).strip_edges()
			var v := _validate_native_res_path(val)
			if not v["ok"]:
				errors.append("[gdextension] %s: %s" % [name, v["error"]])
				continue
			ge[name] = val
	entry["gdextension"] = ge
	entry["gdextension_errors"] = errors
	entry["has_native"] = has_any

# Validate one [gdextension] value. Returns {"ok": bool, "error": String}.
func _validate_native_res_path(p: String) -> Dictionary:
	if p.is_empty():
		return {"ok": false, "error": "empty path"}
	if "\\" in p:
		return {"ok": false, "error": "backslash in path -- use forward slashes"}
	if not p.begins_with("res://"):
		return {"ok": false, "error": "must be a res:// path inside the mod archive (got '%s')" % p}
	if not p.to_lower().ends_with(".gdextension"):
		return {"ok": false, "error": ".gdextension suffix required (got '%s')" % p.get_file()}
	return _validate_safe_relative_path(p.substr(6))

# Block any pattern that could escape the archive or the cache root. Reused
# by the .gdextension path check and by every [libraries] entry inside it.
func _validate_safe_relative_path(rel: String) -> Dictionary:
	if rel.is_empty():
		return {"ok": false, "error": "empty path after res://"}
	if "\\" in rel:
		return {"ok": false, "error": "backslash in path -- use forward slashes"}
	if rel.begins_with("/"):
		return {"ok": false, "error": "leading slash"}
	if rel.length() >= 2 and rel.substr(1, 1) == ":":
		return {"ok": false, "error": "drive letter ('%s')" % rel.substr(0, 2)}
	if rel.begins_with("//"):
		return {"ok": false, "error": "UNC/network path"}
	for seg in rel.split("/"):
		if seg == "..":
			return {"ok": false, "error": "'..' segment"}
		if seg.begins_with("~"):
			return {"ok": false, "error": "tilde-prefixed segment ('%s')" % seg}
	return {"ok": true, "error": ""}

# Squash an arbitrary string into something safe to use as a cache dir
# name. Keeps [a-z0-9_-.], replaces the rest with "_". Empty in -> "_".
func _safe_native_id(raw: String) -> String:
	var out := ""
	for ch in raw:
		var lower := ch.to_lower()
		if (lower >= "a" and lower <= "z") or (lower >= "0" and lower <= "9") \
				or lower == "_" or lower == "-" or lower == ".":
			out += lower
		else:
			out += "_"
	return out if not out.is_empty() else "_"

# Per-mod cache dir: NATIVE_CACHE_DIR/<safe_id>/<cache_key>/. Prefer the
# declared mod version for cache_key; fall back to "mtime<N>" so a rebuilt
# mod with no version bump still gets a fresh tree on disk.
func _native_cache_dir_for(mod_id: String, version: String, archive_full_path: String) -> String:
	var key := version
	if key.strip_edges().is_empty():
		key = "mtime%d" % FileAccess.get_modified_time(archive_full_path)
	return NATIVE_CACHE_DIR.path_join(_safe_native_id(mod_id)).path_join(_safe_native_id(key))

# Copy one .gdextension and its libraries into the per-mod cache, rewriting
# [libraries] entries to user:// so dlopen reads from the cache rather than
# the mounted archive. Returns the user:// path of the cached .gdextension,
# or "" if anything failed.
func _materialize_native_extension(res_path: String, mod_id: String, version: String,
		archive_full_path: String, mod_name: String) -> String:
	var bytes := FileAccess.get_file_as_bytes(res_path)
	if bytes.is_empty():
		_log_critical("[NativeExt] cannot read .gdextension via VFS: %s [%s]" % [res_path, mod_name])
		return ""
	var src_text := bytes.get_string_from_utf8()
	var src_cfg := ConfigFile.new()
	if src_cfg.parse(src_text) != OK:
		_log_critical("[NativeExt] failed to parse .gdextension: %s [%s]" % [res_path, mod_name])
		return ""

	var cache_dir := _native_cache_dir_for(mod_id, version, archive_full_path)
	var cache_dir_abs := ProjectSettings.globalize_path(cache_dir)
	# Wipe any leftover partial materialization from a prior run -- the dir
	# only holds files we put there, so this is safe.
	_wipe_native_cache_dir(cache_dir_abs)
	if DirAccess.make_dir_recursive_absolute(cache_dir_abs) != OK \
			and not DirAccess.dir_exists_absolute(cache_dir_abs):
		_log_critical("[NativeExt] cannot create cache dir: %s [%s]" % [cache_dir_abs, mod_name])
		return ""

	var gdext_dir := res_path.get_base_dir()  # e.g. res://BetterBallistics/bin
	if src_cfg.has_section("libraries"):
		for key in src_cfg.get_section_keys("libraries"):
			var raw_lib_val: Variant = src_cfg.get_value("libraries", key, "")
			if not (raw_lib_val is String):
				_log_critical("[NativeExt] %s [libraries] %s: non-string value [%s]" \
						% [res_path, key, mod_name])
				return ""
			var lib_val := str(raw_lib_val).strip_edges()
			if lib_val.is_empty():
				continue
			var lib_res_path := lib_val
			if not lib_res_path.begins_with("res://"):
				while lib_res_path.begins_with("./"):
					lib_res_path = lib_res_path.substr(2)
				var rel_check := _validate_safe_relative_path(lib_res_path)
				if not rel_check["ok"]:
					_log_critical("[NativeExt] %s [libraries] %s: unsafe relative path '%s' (%s) [%s]" \
							% [res_path, key, lib_val, rel_check["error"], mod_name])
					return ""
				lib_res_path = gdext_dir.path_join(lib_res_path)
			else:
				var abs_check := _validate_safe_relative_path(lib_res_path.substr(6))
				if not abs_check["ok"]:
					_log_critical("[NativeExt] %s [libraries] %s: unsafe path '%s' (%s) [%s]" \
							% [res_path, key, lib_val, abs_check["error"], mod_name])
					return ""

			# Mirror the lib's offset from the .gdextension's dir into the
			# cache: "windows/foo.dll" -> <cache>/windows/foo.dll. Libs
			# that live above the .gdextension dir flatten to basename.
			var rel_in_cache := _path_relative_to_dir(lib_res_path, gdext_dir)
			if rel_in_cache.is_empty():
				rel_in_cache = lib_res_path.get_file()
			var out_user := cache_dir.path_join(rel_in_cache)
			var out_abs := ProjectSettings.globalize_path(out_user)
			# Final containment check after path_join normalizes the path.
			# Catches anything pathological that slipped through the
			# per-segment validator above.
			if not _path_is_within(out_abs, cache_dir_abs):
				_log_critical("[NativeExt] %s [libraries] %s: cache path escapes root: %s [%s]" \
						% [res_path, key, out_abs, mod_name])
				return ""

			var lib_bytes := FileAccess.get_file_as_bytes(lib_res_path)
			if lib_bytes.is_empty():
				# Mods often ship only their host-platform binary, so the
				# Linux/macOS entries simply don't exist on a Windows-only
				# pack. Drop the missing entry and keep loading -- the
				# feature tag for an absent OS won't fire anyway.
				_log_debug("[NativeExt] %s [libraries] %s: library not packaged (%s) -- skipping entry [%s]" \
						% [res_path, key, lib_res_path, mod_name])
				src_cfg.erase_section_key("libraries", key)
				continue
			DirAccess.make_dir_recursive_absolute(out_abs.get_base_dir())
			var f := FileAccess.open(out_abs, FileAccess.WRITE)
			if f == null:
				_log_critical("[NativeExt] failed to open cache file for write: %s [%s]" \
						% [out_abs, mod_name])
				return ""
			f.store_buffer(lib_bytes)
			f.close()
			src_cfg.set_value("libraries", key, out_user)

	# [icon] is editor-only and frequently points at paths outside the mod
	# (icon=res://addons/...). Just drop it -- runtime doesn't care.
	if src_cfg.has_section("icon"):
		src_cfg.erase_section("icon")

	var out_gdext := cache_dir.path_join(res_path.get_file())
	var out_gdext_abs := ProjectSettings.globalize_path(out_gdext)
	if not _path_is_within(out_gdext_abs, cache_dir_abs):
		_log_critical("[NativeExt] cached .gdextension path escapes root: %s [%s]" \
				% [out_gdext_abs, mod_name])
		return ""
	if src_cfg.save(out_gdext) != OK:
		_log_critical("[NativeExt] failed to save cached .gdextension: %s [%s]" \
				% [out_gdext, mod_name])
		return ""
	return out_gdext

# Walk enabled mods, materialize every declared .gdextension, hand each
# cached path to GDExtensionManager.load_extension. Has to run after
# load_all_mods (archive contents reachable via VFS) and before bridge
# autoloads instantiate (so the bridge can `Native.new()` in _ready).
func _load_native_extensions_for_enabled_mods() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(NATIVE_CACHE_DIR))
	for entry in _ui_mod_entries:
		if not entry.get("enabled", false):
			continue
		var ge: Dictionary = entry.get("gdextension", {})
		if ge.is_empty():
			continue
		var mod_name: String = entry["mod_name"]
		var mod_id: String = entry["mod_id"]
		var version: String = entry.get("version", "")
		var full_path: String = entry["full_path"]
		_log_info("[NativeExt] %s declares %d native extension(s)" % [mod_name, ge.size()])
		for ext_name: String in ge:
			var res_path: String = ge[ext_name]
			var cache_path := _materialize_native_extension(res_path, mod_id, version,
					full_path, mod_name)
			if cache_path.is_empty():
				_log_critical("[NativeExt] %s: %s failed to materialize -- extension NOT loaded" \
						% [mod_name, ext_name])
				continue
			var abs_cache := ProjectSettings.globalize_path(cache_path)
			if _loaded_native_extensions.has(abs_cache):
				_log_debug("[NativeExt] %s: %s already loaded this session -- skipping" \
						% [mod_name, ext_name])
				continue
			var status := GDExtensionManager.load_extension(cache_path)
			if status == GDExtensionManager.LOAD_STATUS_OK \
					or status == GDExtensionManager.LOAD_STATUS_ALREADY_LOADED:
				_loaded_native_extensions[abs_cache] = mod_name
				_log_info("[NativeExt] Loaded %s -> %s [%s]" \
						% [ext_name, cache_path, mod_name])
			elif status == GDExtensionManager.LOAD_STATUS_NEEDS_RESTART:
				# Engine wants a hard restart before this lib is fully
				# wired in. The two-pass flow already restarts whenever
				# the state hash changes, so users hit this once and the
				# extension comes up clean on the next launch.
				_log_warning("[NativeExt] %s: %s needs an engine restart to fully activate (LOAD_STATUS_NEEDS_RESTART) [%s]" \
						% [mod_name, ext_name, cache_path])
				_loaded_native_extensions[abs_cache] = mod_name
			else:
				_log_critical("[NativeExt] %s: GDExtensionManager.load_extension('%s') returned status %d [%s]" \
						% [mod_name, cache_path, status, ext_name])

# Sorted "ge:" parts for boot.gd's _compute_state_hash. The archive mtime
# is already in the "a:" parts, but mixing the declared res:// path back
# in here means flipping a [gdextension] line on/off -- without touching
# the archive -- still changes the hash and forces a Pass-2 restart.
func _native_state_hash_parts() -> PackedStringArray:
	var parts := PackedStringArray()
	for entry in _ui_mod_entries:
		if not entry.get("enabled", false):
			continue
		var ge: Dictionary = entry.get("gdextension", {})
		if ge.is_empty():
			continue
		var mod_id: String = entry["mod_id"]
		var full_path: String = entry["full_path"]
		var archive_mt := FileAccess.get_modified_time(full_path)
		for ext_name: String in ge:
			var res_path: String = ge[ext_name]
			parts.append("ge:%s/%s=%s@%d" % [mod_id, ext_name, res_path, archive_mt])
	parts.sort()
	return parts

# Drive the launcher's native-code confirmation gate and the per-row badge.
func _any_enabled_native_mods() -> bool:
	for entry in _ui_mod_entries:
		if entry.get("enabled", false) and entry.get("has_native", false):
			return true
	return false

func _enabled_native_mods() -> Array:
	var out: Array = []
	for entry in _ui_mod_entries:
		if entry.get("enabled", false) and entry.get("has_native", false):
			out.append(entry)
	return out

# Strip `dir/` off the front of `p` if it's there. Returns "" otherwise.
func _path_relative_to_dir(p: String, dir: String) -> String:
	var d := dir
	if not d.ends_with("/"):
		d += "/"
	if p.begins_with(d):
		return p.substr(d.length())
	return ""

# Is `p` under `root`? Normalizes slashes first so a Windows mix of `/`
# and `\` can't fool the prefix check.
func _path_is_within(p: String, root: String) -> bool:
	var pp := p.replace("\\", "/")
	var rr := root.replace("\\", "/")
	if not rr.ends_with("/"):
		rr += "/"
	return (pp + "/").begins_with(rr) or pp == rr.trim_suffix("/")

# Recursive rm of a native-cache subdir. Only called on paths under
# NATIVE_CACHE_DIR before re-materialization -- nothing else.
func _wipe_native_cache_dir(abs_dir: String) -> void:
	if not DirAccess.dir_exists_absolute(abs_dir):
		return
	var dir := DirAccess.open(abs_dir)
	if dir == null:
		return
	dir.list_dir_begin()
	while true:
		var entry := dir.get_next()
		if entry == "":
			break
		var full := abs_dir.path_join(entry)
		if dir.current_is_dir():
			_wipe_native_cache_dir(full)
			DirAccess.remove_absolute(full)
		else:
			DirAccess.remove_absolute(full)
	dir.list_dir_end()
