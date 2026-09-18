## ----- pck_enumeration.gd -----
## PCK introspection. Parses the game's RTV.pck file table to enumerate
## every res://Scripts/*.gd at runtime (DirAccess can't list PCK contents in
## Godot 4.6). Also builds the class_name -> path lookup consumed by the
## rewriter when scanning mod subclasses.

func _build_class_name_lookup() -> void:
	_class_name_to_path.clear()
	var cache := ConfigFile.new()
	var load_err := cache.load("res://.godot/global_script_class_cache.cfg")
	if load_err == OK:
		# A mod-shadowed cfg can define "list" as any Variant; the [] default
		# only covers an absent key, so type-check before the typed assignment.
		var raw_list: Variant = cache.get_value("", "list", [])
		var class_list: Array = raw_list if raw_list is Array else []
		var skipped := 0
		for entry in class_list:
			if not entry is Dictionary:
				skipped += 1
				continue
			var cn: String = str(entry.get("class", ""))
			var path: String = str(entry.get("path", ""))
			if cn != "" and path != "":
				_class_name_to_path[cn] = path
			else:
				skipped += 1
		if _class_name_to_path.size() < 10:
			# A mounted mod (e.g. MCM) can shadow the game's cache with its
			# own tiny version; fall back to the hardcoded map.
			_log_warning("Class cache has only %d entries (raw=%d) -- mod shadowing detected, using hardcoded fallback" \
					% [_class_name_to_path.size(), class_list.size()])
			_class_name_to_path = _get_hardcoded_class_map()
		else:
			_log_info("Loaded %d class_name mappings from game cache" % _class_name_to_path.size())
	else:
		_log_warning("Could not load global_script_class_cache.cfg -- using hardcoded fallback")
		_class_name_to_path = _get_hardcoded_class_map()

# Snapshot of vanilla RTV's global_script_class_cache.cfg. Fallback only;
# re-capture from a fresh vanilla install when the game updates.
func _get_hardcoded_class_map() -> Dictionary:
	return {
		"AIWeaponData": "res://Scripts/AIWeaponData.gd",
		"Area": "res://Scripts/Area.gd",
		"AttachmentData": "res://Scripts/AttachmentData.gd",
		"AudioEvent": "res://Scripts/AudioEvent.gd",
		"AudioLibrary": "res://Scripts/AudioLibrary.gd",
		"Camera": "res://Scripts/Camera.gd",
		"CasetteData": "res://Scripts/CasetteData.gd",
		"CatData": "res://Scripts/CatData.gd",
		"CharacterSave": "res://Scripts/CharacterSave.gd",
		"ContainerSave": "res://Scripts/ContainerSave.gd",
		"Controller": "res://Scripts/Controller.gd",
		"Door": "res://Scripts/Door.gd",
		"EventData": "res://Scripts/EventData.gd",
		"Events": "res://Scripts/Events.gd",
		"Fish": "res://Scripts/Fish.gd",
		"FishingData": "res://Scripts/FishingData.gd",
		"Flash": "res://Scripts/MuzzleFlash.gd",
		"Furniture": "res://Scripts/Furniture.gd",
		"FurnitureSave": "res://Scripts/FurnitureSave.gd",
		"GameData": "res://Scripts/GameData.gd",
		"Grenade": "res://Scripts/Grenade.gd",
		"GrenadeData": "res://Scripts/GrenadeData.gd",
		"Grid": "res://Scripts/Grid.gd",
		"Hitbox": "res://Scripts/Hitbox.gd",
		"Inspect": "res://Scripts/Inspect.gd",
		"InstrumentData": "res://Scripts/InstrumentData.gd",
		"Item": "res://Scripts/Item.gd",
		"ItemData": "res://Scripts/ItemData.gd",
		"ItemSave": "res://Scripts/ItemSave.gd",
		"Knife": "res://Scripts/KnifeRig.gd",
		"KnifeData": "res://Scripts/KnifeData.gd",
		"LootContainer": "res://Scripts/LootContainer.gd",
		"LootTable": "res://Scripts/LootTable.gd",
		"Lure": "res://Scripts/Lure.gd",
		"Mine": "res://Scripts/Mine.gd",
		"Pickup": "res://Scripts/Pickup.gd",
		"Preferences": "res://Scripts/Preferences.gd",
		"RecipeData": "res://Scripts/RecipeData.gd",
		"Recipes": "res://Scripts/Recipes.gd",
		"Settings": "res://Scripts/Settings.gd",
		"ShelterSave": "res://Scripts/ShelterSave.gd",
		"Slot": "res://Scripts/Slot.gd",
		"SlotData": "res://Scripts/SlotData.gd",
		"SpawnerChunkData": "res://Scripts/SpawnerChunkData.gd",
		"SpawnerData": "res://Scripts/SpawnerData.gd",
		"SpawnerSceneData": "res://Scripts/SpawnerSceneData.gd",
		"SpineData": "res://Scripts/SpineData.gd",
		"Surface": "res://Scripts/Surface.gd",
		"SwitchSave": "res://Scripts/SwitchSave.gd",
		"TaskData": "res://Scripts/TaskData.gd",
		"TrackData": "res://Scripts/TrackData.gd",
		"Trader": "res://Scripts/Trader.gd",
		"TraderData": "res://Scripts/TraderData.gd",
		"TraderSave": "res://Scripts/TraderSave.gd",
		"Validator": "res://Scripts/Validator.gd",
		"WeaponData": "res://Scripts/WeaponData.gd",
		"WeaponRig": "res://Scripts/WeaponRig.gd",
		"WorldSave": "res://Scripts/WorldSave.gd",
	}

# --- Script enumeration -----------------------------------------------------
# DirAccess.get_files_at() can't enumerate PCK contents in Godot 4.6 (it
# returns at most 1 entry on res://Scripts/); parse the PCK file table instead.

# Returns res://Scripts/*.gd paths found in the game's PCK, or [] on failure
# (encrypted pack, embedded pack, new format, missing file). Callers fall
# back to _class_name_to_path when empty.
func _enumerate_game_scripts() -> Array[String]:
	# Memoized; called from two sites per pass.
	if not _all_game_script_paths.is_empty():
		return _all_game_script_paths
	# Disk cache: without it every launch re-parses the PCK's 17k-entry
	# directory for a script list that only changes when the game does.
	# Stamped with the exe's mtime, the same key boot.gd uses to invalidate
	# hook artifacts.
	var cached := _load_script_index_cache()
	if not cached.is_empty():
		_all_game_script_paths = cached
		_log_debug("[RTVCodegen] script index: %d path(s) from cache (PCK parse skipped)" % cached.size())
		return _all_game_script_paths
	var exe_dir := OS.get_executable_path().get_base_dir()
	var candidates := ["RTV.pck", OS.get_executable_path().get_file().get_basename() + ".pck"]
	for cand in candidates:
		var pck_path := exe_dir.path_join(cand)
		if not FileAccess.file_exists(pck_path):
			continue
		var paths := _parse_pck_file_list(pck_path)
		if paths.is_empty():
			continue
		var scripts: Array[String] = []
		# Dictionary membership; `in Array` is a linear scan per candidate
		# (quadratic overall).
		var seen: Dictionary = {}
		for p in paths:
			# Packed paths lack the res:// prefix; Godot adds it on load.
			var normalized := p
			if not normalized.begins_with("res://"):
				normalized = "res://" + normalized.trim_prefix("/")
			if not normalized.begins_with("res://Scripts/"):
				continue
			# Canonicalize .gdc / .gd.remap / .remap to .gd.
			var canonical := normalized
			if canonical.ends_with(".remap"):
				canonical = canonical.substr(0, canonical.length() - 6)
			if canonical.ends_with(".gdc"):
				canonical = canonical.substr(0, canonical.length() - 4) + ".gd"
			if canonical.ends_with(".gd") and not seen.has(canonical):
				seen[canonical] = true
				scripts.append(canonical)
		_log_info("[RTVCodegen] parsed %s -- %d total file(s), %d .gd script(s) under res://Scripts/" \
				% [cand, paths.size(), scripts.size()])
		_all_game_script_paths = scripts
		_save_script_index_cache(scripts)
		return scripts
	return []

# Script-index disk cache: "<exe mtime>|<PCK stamp>\n<path>\n<path>...". Lines prefixed
# "!" carry the PCK's zero-byte .gd entries; a cache hit must restore that
# side channel (_pck_zero_byte_paths) or downstream detokenize/hook-gen
# misdiagnose zero-byte scripts as a game build mismatch. Any stamp mismatch
# falls through to a fresh parse, so the cache can never serve a stale list.
const _SCRIPT_INDEX_CACHE := "user://modloader_hooks/script_index.txt"

func _script_index_stamp() -> String:
	return "%d|%s" % [FileAccess.get_modified_time(OS.get_executable_path()), _game_pck_stamp()]

func _load_script_index_cache() -> Array[String]:
	var empty: Array[String] = []
	var f := FileAccess.open(_SCRIPT_INDEX_CACHE, FileAccess.READ)
	if f == null:
		return empty
	var text := f.get_as_text()
	f.close()
	var lines := text.split("\n", false)
	if lines.size() < 2 or lines[0].strip_edges() != _script_index_stamp():
		return empty
	var out: Array[String] = []
	for i in range(1, lines.size()):
		var p := lines[i].strip_edges()
		# "!"-prefixed zero-byte side channel; the parser records these
		# anywhere in the PCK, not just Scripts/.
		if p.begins_with("!"):
			var zb := p.substr(1)
			if zb.begins_with("res://") and zb.ends_with(".gd"):
				_pck_zero_byte_paths[zb] = true
			continue
		# Only hand back parser-shaped paths -- a hand-edited or truncated
		# cache must not widen the wrap surface.
		if p.begins_with("res://Scripts/") and p.ends_with(".gd"):
			out.append(p)
	return out

func _save_script_index_cache(scripts: Array[String]) -> void:
	DirAccess.make_dir_recursive_absolute(
		ProjectSettings.globalize_path(_SCRIPT_INDEX_CACHE.get_base_dir()))
	# Write-then-rename: a truncated index would silently shrink the wrap
	# surface on the next launch, and every stamp check would still pass.
	var tmp := _SCRIPT_INDEX_CACHE + ".tmp"
	var f := FileAccess.open(tmp, FileAccess.WRITE)
	if f == null:
		return
	var body := _script_index_stamp() + "\n" + "\n".join(scripts)
	# Persist the zero-byte side channel (see the format comment above);
	# populated by the parse that immediately precedes every save.
	for zb: String in _pck_zero_byte_paths:
		body += "\n!" + zb
	var wrote := f.store_string(body)
	var werr := f.get_error()
	f.close()
	if not wrote or werr != OK:
		DirAccess.remove_absolute(tmp)
		return
	DirAccess.rename_absolute(tmp, _SCRIPT_INDEX_CACHE)

# Collect module-scope `preload("...tscn|scn")` paths (line starts at column
# 0). These fire at parse time, before mod autoloads run overrideScript():
# the scene bakes a Ref<> to the pre-override vanilla script, take_over_path
# then orphans it (path_cache cleared), and instantiate() yields nodes whose
# mod body never runs.
func _collect_module_scope_scene_preloads(source: String) -> PackedStringArray:
	var scenes := PackedStringArray()
	var re := RegEx.new()
	re.compile("preload\\(\"(res://[^\"]+\\.(?:tscn|scn))\"\\)")
	for line in source.split("\n"):
		if line.is_empty():
			continue
		var first := line[0]
		if first == "\t" or first == " ":
			continue  # indented -- inside function, block, or conditional
		var trimmed := line.strip_edges(true, false)
		if trimmed.is_empty() or trimmed.begins_with("#"):
			continue
		if "preload(" not in line:
			continue
		for m in re.search_all(line):
			var scene_path := m.get_string(1)
			if scene_path not in scenes:
				scenes.append(scene_path)
	return scenes

# Minimal PCK header + file-table parser. V2 (Godot 4.0-4.5) has 16 reserved
# dwords before the directory; V3 (Godot 4.6+) replaces them with an explicit
# 64-bit directory offset. Reference: core/io/file_access_pack.cpp.
func _parse_pck_file_list(pck_path: String) -> PackedStringArray:
	const MAGIC_GDPC: int = 0x43504447  # "GDPC" little-endian
	const PACK_DIR_ENCRYPTED := 1
	# PACK_FORMAT_V2/V3/V4 bounds live in constants.gd (shared with security_scan.gd).
	var result := PackedStringArray()
	var f := FileAccess.open(pck_path, FileAccess.READ)
	if f == null:
		_log_warning("[PCK] cannot open: %s" % pck_path)
		return result

	var magic: int = f.get_32()
	if magic != MAGIC_GDPC:
		# Would need footer-scan if embedded; not supported.
		_log_warning("[PCK] %s: not a standalone PCK (magic=0x%x)" % [pck_path, magic])
		f.close()
		return result

	var pack_format_version: int = f.get_32()
	if pack_format_version < PACK_FORMAT_V2 or pack_format_version > PACK_FORMAT_V3:
		if pack_format_version == PACK_FORMAT_V4:
			# Godot 4.7+ export; the engine version u32s follow the format
			# version, so name the offending editor.
			var ver_major: int = f.get_32()
			var ver_minor: int = f.get_32()
			_log_warning("[PCK] %s: pack format v4, exported with Godot %d.%d. This game runs Godot 4.6, which cannot read v4 packs. Re-export the .pck with Godot 4.6.x, or ship the mod as a .zip (zip mods are unaffected by pack versions)." \
					% [pck_path, ver_major, ver_minor])
		else:
			_log_warning("[PCK] %s: unsupported format version %d" % [pck_path, pack_format_version])
		f.close()
		return result

	f.get_32()  # godot major
	f.get_32()  # godot minor
	f.get_32()  # godot patch
	var pack_flags: int = f.get_32()
	f.get_64()  # file_base

	if pack_format_version == PACK_FORMAT_V3:
		f.seek(f.get_64())  # explicit dir offset; absolute for standalone PCK
	else:
		for i in 16:
			f.get_32()  # reserved

	if pack_flags & PACK_DIR_ENCRYPTED:
		_log_warning("[PCK] %s: directory encrypted -- can't enumerate" % pck_path)
		f.close()
		return result

	var file_count: int = f.get_32()
	for i in file_count:
		var path_len: int = f.get_32()
		if path_len == 0 or path_len > 4096:
			_log_warning("[PCK] %s: suspicious path_len=%d at entry %d -- abort" \
					% [pck_path, path_len, i])
			break
		var path := f.get_buffer(path_len).get_string_from_utf8()
		f.get_64()              # offset
		var size: int = f.get_64()
		f.get_buffer(16)        # md5
		f.get_32()              # per-file flags (V2 and V3)
		if not path.is_empty():
			result.append(path)
			# Track zero-byte entries so downstream detokenize skips them
			# instead of logging misleading warnings. The base game ships
			# empty .gd entries (e.g. CasettePlayer.gd in RTV 4.6.1) that
			# cannot be hooked regardless of the modloader.
			if size == 0 and path.ends_with(".gd"):
				var res_path := path if path.begins_with("res://") else "res://" + path.trim_prefix("/")
				_pck_zero_byte_paths[res_path] = true

	f.close()
	return result
