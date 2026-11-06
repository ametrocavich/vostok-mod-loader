## PCK introspection: the res://Scripts/*.gd list from the game PCK's file table
## (DirAccess cannot list PCK contents in Godot 4.6) and the vanilla class_name map.

func _build_class_name_lookup() -> void:
	_class_name_to_path.clear()
	var cache := ConfigFile.new()
	if cache.load("res://.godot/global_script_class_cache.cfg") != OK:
		_log_warning("[RTVCodegen] Could not load global_script_class_cache.cfg -- using hardcoded fallback")
		_class_name_to_path = _get_hardcoded_class_map()
		return
	# A mounted mod (MCM, say) can shadow this file with any shape or a tiny map.
	var raw_list: Variant = cache.get_value("", "list", [])
	var class_list: Array = raw_list if raw_list is Array else []
	for entry in class_list:
		if not entry is Dictionary:
			continue
		var cn: String = str(entry.get("class", ""))
		var path: String = str(entry.get("path", ""))
		if cn != "" and path != "":
			_class_name_to_path[cn] = path
	if _class_name_to_path.size() < 10:
		_log_warning("[RTVCodegen] Class cache has only %d entries (raw=%d), a mod shadows it; using fallback" \
				% [_class_name_to_path.size(), class_list.size()])
		_class_name_to_path = _get_hardcoded_class_map()
	else:
		_log_info("[RTVCodegen] Loaded %d class_name mappings from game cache" % _class_name_to_path.size())

# Vanilla global_script_class_cache.cfg; re-capture on a game update.
# tests/ingame/rehearse_build.sh parses this body, one entry per line.
func _get_hardcoded_class_map() -> Dictionary:
	return {
		"AIData": "res://Scripts/AIData.gd",
		"AimModifier": "res://Scripts/AimModifier.gd",
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
		"GrenadeData": "res://Scripts/GrenadeData.gd",
		"Grid": "res://Scripts/Grid.gd",
		"Hitbox": "res://Scripts/Hitbox.gd",
		"ImpulseModifier": "res://Scripts/ImpulseModifier.gd",
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

# res://Scripts/*.gd in the game PCK, or [] when the table is unreadable.
func _enumerate_game_scripts() -> Array[String]:
	if not _all_game_script_paths.is_empty():
		return _all_game_script_paths
	var cached := _load_script_index_cache()
	if not cached.is_empty():
		_all_game_script_paths = cached
		_log_debug("[RTVCodegen] script index: %d path(s) from cache (PCK parse skipped)" % cached.size())
		return _all_game_script_paths
	var pck_path := _locate_game_pck()
	if pck_path == "":
		return []
	var paths := _parse_pck_file_list(pck_path)
	if paths.is_empty():
		return []
	var scripts: Array[String] = []
	var seen: Dictionary = {}
	for p in paths:
		var normalized := p if p.begins_with("res://") else "res://" + p.trim_prefix("/")
		if not normalized.begins_with("res://Scripts/"):
			continue
		var canonical := normalized.trim_suffix(".remap")
		if canonical.ends_with(".gdc"):
			canonical = canonical.trim_suffix(".gdc") + ".gd"
		if canonical.ends_with(".gd") and not seen.has(canonical):
			seen[canonical] = true
			scripts.append(canonical)
	_log_info("[RTVCodegen] parsed %s -- %d total file(s), %d .gd script(s) under res://Scripts/" \
			% [pck_path.get_file(), paths.size(), scripts.size()])
	_all_game_script_paths = scripts
	_save_script_index_cache(scripts)
	return scripts

# "<exe mtime>|<PCK stamp>" then one path per line; "!" lines restore
# _pck_zero_byte_paths, or zero-byte scripts read as a build mismatch.
const _SCRIPT_INDEX_CACHE := "user://modloader_hooks/script_index.txt"

func _script_index_stamp() -> String:
	return "%d|%s" % [FileAccess.get_modified_time(OS.get_executable_path()), _game_pck_stamp()]

func _load_script_index_cache() -> Array[String]:
	var out: Array[String] = []
	if not FileAccess.file_exists(_SCRIPT_INDEX_CACHE):
		return out
	var lines := FileAccess.get_file_as_string(_SCRIPT_INDEX_CACHE).split("\n", false)
	if lines.size() < 2 or lines[0].strip_edges() != _script_index_stamp():
		return out
	for i in range(1, lines.size()):
		var p := lines[i].strip_edges()
		if p.begins_with("!"):
			var zb := p.substr(1)
			if zb.begins_with("res://") and zb.ends_with(".gd"):
				_pck_zero_byte_paths[zb] = true
		# A hand-edited cache must not widen the wrap surface.
		elif p.begins_with("res://Scripts/") and p.ends_with(".gd"):
			out.append(p)
	return out

func _save_script_index_cache(scripts: Array[String]) -> void:
	DirAccess.make_dir_recursive_absolute(
		ProjectSettings.globalize_path(_SCRIPT_INDEX_CACHE.get_base_dir()))
	# Write-then-rename: a truncated index would pass every stamp check.
	var tmp := _SCRIPT_INDEX_CACHE + ".tmp"
	var f := FileAccess.open(tmp, FileAccess.WRITE)
	if f == null:
		return
	var body := _script_index_stamp() + "\n" + "\n".join(scripts)
	for zb: String in _pck_zero_byte_paths:
		body += "\n!" + zb
	var wrote := f.store_string(body)
	var werr := f.get_error()
	f.close()
	if not wrote or werr != OK:
		DirAccess.remove_absolute(tmp)
		return
	DirAccess.rename_absolute(tmp, _SCRIPT_INDEX_CACHE)

# The warning for a mod .pck from Godot 4.7+ (format v4), "" for any other file.
static func _pck_v4_warning(pck_path: String) -> String:
	var f := FileAccess.open(pck_path, FileAccess.READ)
	if f == null:
		return ""
	var v4 := f.get_length() >= 16 and f.get_32() == 0x43504447 and f.get_32() == PACK_FORMAT_V4
	# The exporting engine version follows the format version.
	var ver_major := f.get_32() if v4 else 0
	var ver_minor := f.get_32() if v4 else 0
	f.close()
	if not v4:
		return ""
	return "[PCK] %s: mod .pck uses pack format v4, exported with Godot %d.%d. This game runs Godot 4.6, which cannot read v4 packs. Ask the mod author to export with Godot 4.6.x, or to ship the mod as a .zip instead." \
			% [pck_path, ver_major, ver_minor]

# PCK header and file table (core/io/file_access_pack.cpp): V2 has 16 reserved dwords
# before the directory, V3 a 64-bit directory offset. Offsets returned are absolute.
# {"entries": [{path, offset, size}], "error": ""}, or the [PCK] reason the table is
# empty or ends early; entries read before a bad entry are kept.
func _pck_read_table(pck_path: String) -> Dictionary:
	const MAGIC_GDPC: int = 0x43504447  # "GDPC" little-endian
	const PACK_DIR_ENCRYPTED := 1
	var entries: Array = []
	var f := FileAccess.open(pck_path, FileAccess.READ)
	if f == null:
		return {"entries": entries, "error": "[PCK] cannot open: %s" % pck_path}

	var magic: int = f.get_32()
	if magic != MAGIC_GDPC:
		f.close()
		return {"entries": entries, "error": "[PCK] %s: not a standalone PCK (magic=0x%x)" % [pck_path, magic]}

	var pack_format_version: int = f.get_32()
	if pack_format_version < PACK_FORMAT_V2 or pack_format_version > PACK_FORMAT_V3:
		var why := "[PCK] %s: unsupported format version %d" % [pck_path, pack_format_version]
		if pack_format_version == PACK_FORMAT_V4:
			# The exporting engine version follows the format version.
			var ver_major: int = f.get_32()
			var ver_minor: int = f.get_32()
			why = "[PCK] %s: pack format v4, exported with Godot %d.%d; this game runs Godot 4.6" \
					% [pck_path, ver_major, ver_minor]
		f.close()
		return {"entries": entries, "error": why}

	f.get_32()  # godot major
	f.get_32()  # godot minor
	f.get_32()  # godot patch
	var pack_flags: int = f.get_32()
	var file_base: int = f.get_64()  # directory offsets are relative to this

	if pack_format_version == PACK_FORMAT_V3:
		f.seek(f.get_64())  # explicit dir offset; absolute for standalone PCK
	else:
		for i in 16:
			f.get_32()  # reserved

	if pack_flags & PACK_DIR_ENCRYPTED:
		f.close()
		return {"entries": entries, "error": "[PCK] %s: directory encrypted -- can't enumerate" % pck_path}

	var error := ""
	var file_count: int = f.get_32()
	for i in file_count:
		var path_len: int = f.get_32()
		if path_len == 0 or path_len > 4096:
			error = "[PCK] %s: suspicious path_len=%d at entry %d -- abort" % [pck_path, path_len, i]
			break
		var path := f.get_buffer(path_len).get_string_from_utf8()
		var offset: int = f.get_64()
		var size: int = f.get_64()
		f.get_buffer(16)        # md5
		f.get_32()              # per-file flags (V2 and V3)
		if not path.is_empty():
			entries.append({"path": path, "offset": file_base + offset, "size": size})
	f.close()
	return {"entries": entries, "error": error}

# Every entry path in the PCK's file table; zero-byte .gd entries go to
# _pck_zero_byte_paths so the detokenizer skips them instead of warning.
func _parse_pck_file_list(pck_path: String) -> PackedStringArray:
	var table := _pck_read_table(pck_path)
	if table["error"] != "":
		_log_warning(table["error"])
	var result := PackedStringArray()
	for e: Dictionary in table["entries"]:
		var path: String = e["path"]
		result.append(path)
		if e["size"] == 0 and path.ends_with(".gd"):
			var res_path := path if path.begins_with("res://") else "res://" + path.trim_prefix("/")
			_pck_zero_byte_paths[res_path] = true
	return result
