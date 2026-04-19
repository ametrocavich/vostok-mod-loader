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
		var class_list: Array = cache.get_value("", "list", [])
		var skipped := 0
		for entry in class_list:
			var cn: String = str(entry.get("class", ""))
			var path: String = str(entry.get("path", ""))
			if cn != "" and path != "":
				_class_name_to_path[cn] = path
			else:
				skipped += 1
		if _class_name_to_path.size() < 10:
			# A mounted mod (e.g., MCM) may shadow the game's cache with its own
			# 1-entry version.  Fall back to the hardcoded map.
			_log_warning("Class cache has only %d entries (raw=%d) -- mod shadowing detected, using hardcoded fallback" \
					% [_class_name_to_path.size(), class_list.size()])
			_class_name_to_path = _get_hardcoded_class_map()
		else:
			_log_info("Loaded %d class_name mappings from game cache" % _class_name_to_path.size())
	else:
		_log_warning("Could not load global_script_class_cache.cfg -- using hardcoded fallback")
		_class_name_to_path = _get_hardcoded_class_map()

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

func _enumerate_game_scripts() -> Array[String]:
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
		for p in paths:
			# Packed paths lack the res:// prefix; Godot adds it on load.
			var normalized := p
			if not normalized.begins_with("res://"):
				normalized = "res://" + normalized.trim_prefix("/")
			if not normalized.begins_with("res://Scripts/"):
				continue
			# Canonicalize .gdc / .gd.remap / .remap to .gd.
			var canonical := normalized
			if canonical.ends_with(".gd.remap"):
				canonical = canonical.substr(0, canonical.length() - 6)
			elif canonical.ends_with(".remap"):
				canonical = canonical.substr(0, canonical.length() - 6)
			if canonical.ends_with(".gdc"):
				canonical = canonical.substr(0, canonical.length() - 4) + ".gd"
			if canonical.ends_with(".gd") and canonical not in scripts:
				scripts.append(canonical)
		_log_info("[RTVCodegen] parsed %s -- %d total file(s), %d .gd script(s) under res://Scripts/" \
				% [cand, paths.size(), scripts.size()])
		_all_game_script_paths = scripts
		return scripts
	return []

# Collect module-scope `preload("...tscn|scn")` paths from source. Module-scope
# = line starts at column 0 (no leading whitespace). Such preloads fire at
# script parse time, BEFORE mod autoloads run overrideScript(). If the
# preloaded scene has a Script ext_resource pointing to a path a mod intends
# to override, the scene bakes a Ref<> to the pre-override vanilla script.
# take_over_path later clears the vanilla's path_cache, leaving the scene
# holding an orphaned (empty-path) script. Subsequent instantiate() produces
# nodes with that orphan, and the mod's body never runs.
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

# Minimal PCK header + file-table parser. V2 (Godot 4.0–4.5) has 16 reserved
# dwords before the directory; V3 (Godot 4.6+) replaces them with an explicit
# 64-bit directory offset. Reference: core/io/file_access_pack.cpp.
func _parse_pck_file_list(pck_path: String) -> PackedStringArray:
	const MAGIC_GDPC: int = 0x43504447  # "GDPC" little-endian
	const PACK_DIR_ENCRYPTED := 1
	const PACK_FORMAT_V2 := 2
	const PACK_FORMAT_V3 := 3
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
		f.get_64()        # offset
		f.get_64()        # size
		f.get_buffer(16)  # md5
		f.get_32()        # per-file flags (V2 and V3)
		if not path.is_empty():
			result.append(path)

	f.close()
	return result

# STABILITY canary B: probe the first readable vanilla script for its GDSC
# tokenizer version. Returns 100 (Godot 4.0-4.4), 101 (Godot 4.5-4.6), or
# -1 if the file isn't binary-tokenized / unreadable. Used to bail out
# cleanly when Godot ships a new tokenizer format (v102+) rather than
# cascading "Empty detokenized source" warnings through every script.
