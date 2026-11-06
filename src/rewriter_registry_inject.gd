# Registry code per target script: transforms that make vanilla consts mutable,
# preludes spliced into method bodies, and appendices that serve mod entries.

# Logs a vanilla anchor that no longer matches: critical when a mod declared
# [registry], since registrations then stop applying, and debug when it is inert.
func _anchor_missing(critical: String, inert: String) -> void:
	if _any_mod_declared_registry:
		_log_critical(critical)
	else:
		_log_debug(inert)

# Templates are tab-indented; each leading tab becomes one indent unit of the target.
func _reindent(template: Array, unit: String) -> PackedStringArray:
	var out := PackedStringArray()
	for line: String in template:
		var tabs := line.length() - line.lstrip("\t").length()
		out.append(unit.repeat(tabs) + line.substr(tabs))
	return out

# Moves the top-level const preloads into one _rtv_vanilla_scenes dict: a const
# lookup is compile time and bypasses _get(), the dict lets _get() serve mod entries.
# Vanilla anchor: top-level `const X = preload("...")` declarations in Database.gd; silent no-op if the game changes the decl style.
func _database_consts_to_dict(source: String) -> String:
	var entries := PackedStringArray()
	var kept := PackedStringArray()
	for line in source.split("\n"):
		var m := _rtv_re_database_const.search(line)
		if m != null:
			entries.append("\t\"%s\": %s," % [m.get_string(1), m.get_string(2)])
		else:
			kept.append(line)
	if entries.is_empty():
		_log_critical("[RTVCodegen] Database.gd: vanilla const layout changed -- the scenes registry will NOT work")
		return source
	var dict_block := "\n# --- Metro mod loader: vanilla scene dict (rewritten from const declarations) ---\n" \
		+ "var _rtv_vanilla_scenes: Dictionary = {\n" + "\n".join(entries) + "\n}\n"
	# Above the first func on the raw line: a column-0 var inside an inner class does not compile.
	for i in kept.size():
		if kept[i].begins_with("func ") or kept[i].begins_with("static func "):
			return "\n".join(kept.slice(0, i)) + "\n" + dict_block + "\n" + "\n".join(kept.slice(i))
	return "\n".join(kept) + dict_block

# `const shelters` becomes a var so the registry can append mod shelters at run time.
# Vanilla anchor: top-level `const shelters = [...]` declaration in Loader.gd; silent no-op if renamed or restructured.
func _shelters_to_var(source: String) -> String:
	var lines := source.split("\n")
	var changed := false
	for i in lines.size():
		var m := _rtv_re_loader_shelters.search(lines[i])
		if m != null:
			lines[i] = m.get_string(1) + "var shelters " + m.get_string(2)
			changed = true
	if not changed:
		_anchor_missing("[RTVCodegen] Loader.gd: no vanilla 'const shelters' (game update?) -- mod shelters/maps will NOT work",
				"[RTVCodegen] Loader.gd: no 'const shelters'; const-to-var skipped (inert, no [registry])")
		return source
	return "\n".join(lines)

# Routes each `enemy = <name>` through _rtv_resolve_ai_type, which picks a mod override per zone.
# Vanilla anchor: AISpawner.gd::Initialize (`_ready` before Build 2) `enemy = <ident>` / `agent = <ident>` assignment lines inside the Zone if/elif; silent no-op if the mapping moves.
func _route_enemy_assignments(source: String) -> String:
	var lines := source.split("\n")
	var rewrites := 0
	for i in lines.size():
		var m := _rtv_re_aispawner_assign.search(lines[i])
		if m == null or m.get_string(3) in ["true", "false", "null"]:
			continue
		lines[i] = "%s%s = _rtv_resolve_ai_type(zone, %s)" % [m.get_string(1), m.get_string(2), m.get_string(3)]
		rewrites += 1
	if rewrites == 0:
		_anchor_missing("[RTVCodegen] AISpawner.gd: no 'enemy = <name>' lines (game update?) -- AI overrides will NOT work",
				"[RTVCodegen] AISpawner.gd: no 'enemy = <name>' lines; resolver not wired (inert, no [registry])")
	return "\n".join(lines)

# Runs after the rename pass, so each target is the renamed _rtv_vanilla_<name>.
func _apply_preludes(filename: String, lines: PackedStringArray, indent: String) -> PackedStringArray:
	match filename:
		"Loader.gd":
			var with_prelude := _insert_prelude(lines, filename, "LoadScene", _LOADSCENE_PRELUDE, indent)
			# The re-apply reads the prelude's locals.
			if with_prelude.size() == lines.size():
				return with_prelude
			return _loadscene_reapply(with_prelude, indent)
		"FishPool.gd":
			return _insert_prelude(lines, filename, "_ready", _FISHPOOL_PRELUDE, indent)
		"AI.gd":
			return _insert_prelude(lines, filename, "SelectWeapon", _AI_PRELUDE, indent)
		"Compiler.gd":
			# After the leading var lines, where vanilla's spawnTarget local is in scope.
			return _insert_prelude(lines, filename, "Spawn", _COMPILER_PRELUDE, indent, true)
	return lines

# Splices the prelude in after the declaration of the renamed method, or after the
# run of `var` lines that opens its body when after_vars is set.
func _insert_prelude(lines: PackedStringArray, filename: String, method: String, prelude: Array[String],
		indent: String, after_vars := false) -> PackedStringArray:
	var func_name := _RTV_VANILLA_PREFIX + method
	var sig_at := -1
	for i in lines.size():
		if _rtv_strip_decl_prefix(lines[i]).begins_with("func " + func_name + "("):
			sig_at = i
			break
	if sig_at < 0:
		_anchor_missing("[RTVCodegen] %s: registry code for %s not installed (method missing, game update?)" % [filename, func_name],
				"[RTVCodegen] %s: prelude target %s not wrapped, no [registry] -- skipped" % [filename, func_name])
		return lines
	var insert_after := sig_at
	if after_vars:
		for j in range(sig_at + 1, lines.size()):
			var code := lines[j].strip_edges()
			if code == "":
				continue
			if not _is_indented(lines[j]) or not code.begins_with("var "):
				break
			insert_after = j
		if insert_after == sig_at:
			_log_warning("[RTVCodegen] %s: %s no longer opens with 'var' lines (game update?); registry code may not compile" \
					% [filename, func_name])
	var result := lines.slice(0, insert_after + 1)
	result.append_array(_reindent(prelude, indent))
	result.append_array(lines.slice(insert_after + 1))
	return result

# Sets scenePath and the flags for a registered scene and falls through, so mods reuse the
# vanilla flow; the chain still reassigns a vanilla name, which _loadscene_reapply fixes.
# Vanilla anchor: Loader.gd::LoadScene relies on locals `scenePath` + `scene`, gameData.menu/shelter/permadeath/tutorial flags, and the tail change_scene_to_file(scenePath).
const _LOADSCENE_PRELUDE: Array[String] = [
	"\t# --- Metro mod loader: scene_paths registry prelude ---",
	"\tvar _rtv_scene_entry: Dictionary = {}",
	"\tvar _rtv_scene_name: String = scene",
	"\tif _rtv_override_scene_paths.has(scene):",
	"\t\t_rtv_scene_entry = _rtv_override_scene_paths[scene]",
	"\telif _rtv_mod_scene_paths.has(scene):",
	"\t\t_rtv_scene_entry = _rtv_mod_scene_paths[scene]",
	"\tif not _rtv_scene_entry.is_empty():",
	"\t\tscenePath = _rtv_scene_entry.get(\"path\", \"\")",
	"\t\t_rtv_scene_entry_flags(_rtv_scene_entry, _rtv_scene_name, gameData)",
	"\t\tvar _rtv_label: String = String(_rtv_scene_entry.get(\"transition_text\", \"\"))",
	"\t\tif _rtv_label != \"\" and not _rtv_is_vanilla_scene(_rtv_scene_name):",
	"\t\t\tscene = _rtv_label",
	"\t# Fall through: vanilla if-elif won't match mod names; the tail",
	"\t# runs change_scene_to_file(scenePath) with our path set above.",
]

const _LOADSCENE_REAPPLY: Array[String] = [
	"\t# --- Metro mod loader: scene_paths registry, after the vanilla chain ---",
	"\tif not _rtv_scene_entry.is_empty():",
	"\t\tscenePath = _rtv_scene_entry.get(\"path\", \"\")",
	"\t\t_rtv_scene_entry_flags(_rtv_scene_entry, _rtv_scene_name, gameData)",
]

# The vanilla if/elif reassigns scenePath (and most flags) for a vanilla scene name, so
# the entry is applied again before the tail's timer and scene change.
# Vanilla anchor: Loader.gd::LoadScene ends with body-level `await get_tree().create_timer(...).timeout` then `get_tree().change_scene_to_file(scenePath)`.
func _loadscene_reapply(lines: PackedStringArray, indent: String) -> PackedStringArray:
	var func_name := _RTV_VANILLA_PREFIX + "LoadScene"
	var start := -1
	for i in lines.size():
		if lines[i].begins_with("func " + func_name + "("):
			start = i
			break
	if start < 0:
		return lines
	var target := -1
	for i in range(start + 1, lines.size()):
		var ln := lines[i]
		if ln.strip_edges() != "" and not _is_indented(ln):
			break
		# Body level only: a scene change nested in a branch is not the tail.
		if _is_body_level(ln, indent) \
				and ln.strip_edges().replace(" ", "").trim_suffix(";") == "get_tree().change_scene_to_file(scenePath)":
			target = i
	if target < 0:
		_log_critical("[RTVCodegen] Loader.gd: LoadScene lacks its tail change_scene_to_file(scenePath); overrides off")
		return lines
	# Land before the timer the scene change waits on, where vanilla's branch set the flags.
	var insert_at := target
	var j := target - 1
	while j > start and lines[j].strip_edges() == "":
		j -= 1
	if _is_body_level(lines[j], indent) and lines[j].strip_edges().begins_with("await "):
		insert_at = j
	var result := lines.slice(0, insert_at)
	result.append_array(_reindent(_LOADSCENE_REAPPLY, indent))
	result.append_array(lines.slice(insert_at))
	return result

# A line indented exactly one unit: a statement of the function body itself.
func _is_body_level(line: String, indent: String) -> bool:
	return line.begins_with(indent) and not line.substr(indent.length()).begins_with(indent[0])

# Adds the mod species for this pool ("all" matches every pool) before vanilla's random
# pick; a scene already listed is skipped to keep the pick weights.
# Vanilla anchor: FishPool.gd::_ready relies on local `species: Array[PackedScene]` declared before the random-spawn loop.
const _FISHPOOL_PRELUDE: Array[String] = [
	"\t# --- Metro mod loader: fish_species registry prelude ---",
	"\tvar _rtv_mod_fish: Array = Engine.get_meta(\"" + _FISH_ENGINE_META_KEY + "\", [])",
	"\tfor _rtv_fe in _rtv_mod_fish:",
	"\t\tif _rtv_fe.pool_id == \"all\" or _rtv_fe.pool_id == name:",
	"\t\t\tif not (_rtv_fe.scene in species):",
	"\t\t\t\tspecies.append(_rtv_fe.scene)",
]

# Arriving in a registered shelter or map runs the vanilla load steps and returns; arriving
# in a vanilla map adds the connected_content of entries connected_to it and falls through.
# Vanilla anchor: Compiler.gd::Spawn relies on locals `spawnTarget`/`transitions`/`waypoints`/`controller` (leading var decls), gameData.previousMap, and /root/Map.mapName.
const _COMPILER_PRELUDE: Array[String] = [
	"\t# --- Metro mod loader: shelters/maps registry prelude ---",
	"\tvar _rtv_map_node: Node = get_tree().current_scene.get_node_or_null(\"/root/Map\")",
	"\tif _rtv_map_node != null and \"_rtv_mod_shelters\" in Loader:",
	"\t\tvar _rtv_mn: String = String(_rtv_map_node.mapName)",
	"\t\tvar _rtv_entry: Dictionary = Loader._rtv_mod_shelters.get(_rtv_mn, {})",
	"\t\tif not _rtv_entry.is_empty():",
	"\t\t\tLoader.LoadWorld()",
	"\t\t\tLoader.LoadCharacter()",
	"\t\t\tif bool(_rtv_entry.get(\"shelter\", false)):",
	"\t\t\t\tLoader.LoadShelter(_rtv_mn)",
	"\t\t\tSimulation.simulate = true",
	"\t\t\tspawnTarget = String(_rtv_entry.get(\"exit_spawn\", \"\"))",
	"\t\t\tif spawnTarget != \"\":",
	"\t\t\t\tfor _rtv_t in transitions:",
	"\t\t\t\t\tif _rtv_t.owner.name == spawnTarget:",
	"\t\t\t\t\t\tvar _rtv_sp = _rtv_t.owner.spawn",
	"\t\t\t\t\t\tif _rtv_sp:",
	"\t\t\t\t\t\t\tcontroller.global_transform.basis = _rtv_sp.global_transform.basis",
	"\t\t\t\t\t\t\tcontroller.global_transform.basis = controller.global_transform.basis.rotated(Vector3.UP, deg_to_rad(180))",
	"\t\t\t\t\t\t\tcontroller.global_position = _rtv_sp.global_position",
	"\t\t\tgameData.isTransitioning = false",
	"\t\t\tgameData.isSleeping = false",
	"\t\t\tgameData.isOccupied = false",
	"\t\t\tgameData.freeze = false",
	"\t\t\treturn",
	"\t\tfor _rtv_key in Loader._rtv_mod_shelters:",
	"\t\t\tvar _rtv_e: Dictionary = Loader._rtv_mod_shelters[_rtv_key]",
	"\t\t\tif String(_rtv_e.get(\"connected_to\", \"\")) != _rtv_mn:",
	"\t\t\t\tcontinue",
	"\t\t\tvar _rtv_content: Node = get_tree().current_scene.get_node_or_null(\"/root/Map/Content\")",
	"\t\t\tif _rtv_content != null:",
	"\t\t\t\tvar _rtv_items: Array = _rtv_e.get(\"connected_content\", [])",
	"\t\t\t\tfor _rtv_item in _rtv_items:",
	"\t\t\t\t\tif not (_rtv_item is Dictionary):",
	"\t\t\t\t\t\tcontinue",
	"\t\t\t\t\tvar _rtv_p: String = String(_rtv_item.get(\"path\", \"\"))",
	"\t\t\t\t\tif _rtv_p == \"\":",
	"\t\t\t\t\t\tcontinue",
	"\t\t\t\t\tvar _rtv_packed = load(_rtv_p)",
	"\t\t\t\t\tif _rtv_packed == null:",
	"\t\t\t\t\t\tpush_warning(\"[Registry] connected_content: failed to load \" + _rtv_p)",
	"\t\t\t\t\t\tcontinue",
	"\t\t\t\t\tvar _rtv_inst = _rtv_packed.instantiate()",
	"\t\t\t\t\tif \"position\" in _rtv_item:",
	"\t\t\t\t\t\t_rtv_inst.position = _rtv_item[\"position\"]",
	"\t\t\t\t\tif \"rotation\" in _rtv_item:",
	"\t\t\t\t\t\t_rtv_inst.rotation_degrees = _rtv_item[\"rotation\"]",
	"\t\t\t\t\t_rtv_content.add_child(_rtv_inst)",
	# Vanilla took these before connected_content existed; the tail's pose loop reads them.
	"\t\t\ttransitions = get_tree().get_nodes_in_group(\"Transition\")",
	"\t\t\twaypoints = get_tree().get_nodes_in_group(\"AI_WP\")",
	"\t\t\tif String(gameData.previousMap) == _rtv_key:",
	"\t\t\t\tspawnTarget = String(_rtv_e.get(\"entrance_spawn\", \"\"))",
	"\t# Fall through to vanilla if-elif (which handles vanilla maps).",
]

# Vanilla anchor: AI.gd::SelectWeapon relies on the `weapons` child container + hidden-until-picked child contract.
const _AI_PRELUDE: Array[String] = [
	"\t# --- Metro mod loader: ai_loadouts registry prelude ---",
	"\t_rtv_apply_ai_loadouts()",
]

# The code appended at the end of a registry target, after its wrappers; "" for the rest.
func _registry_appendix(filename: String, indent: String, source: String) -> String:
	var template: Array = []
	match filename:
		"Database.gd":
			template = _DATABASE_APPENDIX
		"Loader.gd":
			template = _LOADER_APPENDIX
		"AISpawner.gd":
			template = _AISPAWNER_APPENDIX
		"AI.gd":
			# The source picks the AI category shape it compiles against.
			template = _AI_APPENDIX + (_AI_CATEGORIES_BY_VARIANT if _rtv_re_ai_variant.search(source) != null \
					else _AI_CATEGORIES_BY_ZONE)
		_:
			return ""
	var text := "\n\n" + "\n".join(_reindent(template, indent)) + "\n"
	_log_info("[RTVCodegen] Injected registry into %s (%d chars)" % [filename, text.length()])
	return text

# _get() serves names in the order override > mod > vanilla.
const _DATABASE_APPENDIX: Array[String] = [
	"# --- Metro mod loader registry injection ---",
	"var _rtv_mod_scenes: Dictionary = {}",
	"var _rtv_override_scenes: Dictionary = {}",
	"",
	"func _get(property: StringName):",
	"\tvar key := String(property)",
	"\tif _rtv_override_scenes.has(key):",
	"\t\treturn _rtv_override_scenes[key]",
	"\tif _rtv_mod_scenes.has(key):",
	"\t\treturn _rtv_mod_scenes[key]",
	"\tif _rtv_vanilla_scenes.has(key):",
	"\t\treturn _rtv_vanilla_scenes[key]",
	"\treturn null",
]

# The scene-path dicts, a snapshot that tells vanilla shelters from mod ones, and
# BitByteBytes' B_Loader add_shelter/add_map, so mods written for it keep working.
const _LOADER_APPENDIX: Array[String] = [
	"# --- Metro mod loader: Loader registry state ---",
	"var _rtv_mod_scene_paths: Dictionary = {}",
	"var _rtv_override_scene_paths: Dictionary = {}",
	"var _rtv_mod_shelters: Dictionary = {}",
	"@onready var _rtv_vanilla_shelters: Array = shelters.duplicate()",
	"",
	"# --- Metro mod loader: scene_paths helpers ---",
	# A subclass replacing Loader.gd moves the scene consts to its base script, and a
	# script's constant map lists only its own.
	"func _rtv_is_vanilla_scene(scene_name: String) -> bool:",
	"\tvar s: Script = get_script()",
	"\twhile s != null:",
	"\t\tif s.get_script_constant_map().has(scene_name):",
	"\t\t\treturn true",
	"\t\ts = s.get_base_script()",
	"\treturn false",
	"",
	# A mod scene gets every flag; a vanilla name keeps the chain's flags unless named.
	"func _rtv_scene_entry_flags(entry: Dictionary, scene_name: String, data: Object) -> void:",
	"\tvar vanilla_name: bool = _rtv_is_vanilla_scene(scene_name)",
	"\tfor flag in [\"menu\", \"shelter\", \"permadeath\", \"tutorial\"]:",
	"\t\tif entry.has(flag) or not vanilla_name:",
	"\t\t\tdata.set(flag, entry.get(flag, false))",
	"",
	"# --- Metro mod loader: B_Loader compat shim ---",
	"func add_shelter(d: Dictionary) -> bool:",
	"\treturn _rtv_bloader_compat_register(d, true)",
	"",
	"func add_map(d: Dictionary) -> bool:",
	"\treturn _rtv_bloader_compat_register(d, false)",
	"",
	"func _rtv_bloader_compat_register(d: Dictionary, default_shelter: bool) -> bool:",
	"\tif not (d is Dictionary):",
	"\t\tpush_warning(\"[B_Loader compat] add_shelter/add_map expects a Dictionary\")",
	"\t\treturn false",
	"\tvar id: String = String(d.get(\"map_name\", \"\"))",
	"\tif id == \"\":",
	"\t\tpush_warning(\"[B_Loader compat] dict is missing 'map_name'\")",
	"\t\treturn false",
	"\tif _rtv_mod_shelters.has(id):",
	"\t\tpush_warning(\"[B_Loader compat] '\" + id + \"' already registered\")",
	"\t\treturn false",
	"\tif id in shelters:",
	"\t\tpush_warning(\"[B_Loader compat] '\" + id + \"' already in vanilla shelters list\")",
	"\t\treturn false",
	"\tvar is_shelter: bool = bool(d.get(\"shelter\", default_shelter))",
	# B_Loader says scene_path where the registry says path.
	"\tvar scene_path: String = String(d.get(\"path\", d.get(\"scene_path\", \"\")))",
	# A path under a vanilla scene name would replace that map, as register() refuses.
	"\tif scene_path != \"\" and _rtv_is_vanilla_scene(id):",
	"\t\tpush_warning(\"[B_Loader compat] '\" + id + \"' is a vanilla scene name; pick a new name\")",
	"\t\treturn false",
	"\tvar entry: Dictionary = {",
	"\t\t\"shelter\": is_shelter,",
	"\t\t\"transition_text\": String(d.get(\"transition_text\", id)),",
	"\t\t\"exit_spawn\": String(d.get(\"exit_spawn\", \"\")),",
	"\t\t\"entrance_spawn\": String(d.get(\"entrance_spawn\", \"\")),",
	"\t\t\"connected_to\": String(d.get(\"connected_to\", \"\")),",
	"\t\t\"connected_content\": d.get(\"connected_content\", []),",
	"\t}",
	"\t_rtv_mod_shelters[id] = entry",
	"\tshelters.append(id)",
	"\tif scene_path != \"\":",
	"\t\tvar sp: Dictionary = {",
	"\t\t\t\"path\": scene_path,",
	"\t\t\t\"shelter\": is_shelter,",
	"\t\t\t\"transition_text\": entry[\"transition_text\"],",
	"\t\t}",
	"\t\tif d.has(\"menu\"): sp[\"menu\"] = d[\"menu\"]",
	"\t\tif d.has(\"permadeath\"): sp[\"permadeath\"] = d[\"permadeath\"]",
	"\t\tif d.has(\"tutorial\"): sp[\"tutorial\"] = d[\"tutorial\"]",
	"\t\t_rtv_mod_scene_paths[id] = sp",
	"\tprint(\"[B_Loader compat] registered '\" + id + \"' (shelter=\" + str(is_shelter) + \", connected_to='\" + entry[\"connected_to\"] + \"')\")",
	"\treturn true",
]

# Vanilla anchor: AI.gd field `weapons` (the child container) plus one of two
# category shapes. Build 2 (Nomads) and later: `variant: AIData` with
# `faction` (enum Faction{Nomad, Bandit, Guard, Military, Boss}) and `name`
# ("Punisher", "Bogeyman", ...). Before Build 2: fields `boss`/`AISpawner` +
# AISpawner.Zone key names "Area05"/"BorderZone"/"Vostok". The source picks.
const _AI_APPENDIX: Array[String] = [
	"# --- Metro mod loader: AI loadouts registry ---",
	"func _rtv_apply_ai_loadouts() -> void:",
	"\tvar entries: Array = Engine.get_meta(\"" + _AI_LOADOUTS_ENGINE_META_KEY + "\", [])",
	"\tif entries.is_empty():",
	"\t\treturn",
	"\tif weapons == null:",
	"\t\treturn",
	"\tvar categories: Array = _rtv_ai_categories()",
	"\tif categories.is_empty():",
	"\t\treturn",
	"\tfor e in entries:",
	"\t\tif not (e is Dictionary):",
	"\t\t\tcontinue",
	"\t\tvar ai_types: Array = e.get(\"ai_types\", [])",
	"\t\tvar matched: bool = false",
	"\t\tfor c in categories:",
	"\t\t\tif c in ai_types:",
	"\t\t\t\tmatched = true",
	"\t\tif not matched:",
	"\t\t\tcontinue",
	"\t\tif randf() > float(e.get(\"chance\", 1.0)):",
	"\t\t\tcontinue",
	"\t\tif bool(e.get(\"replace\", false)):",
	# queue_free() alone leaves the node in get_children() until the frame ends.
	"\t\t\tfor child in weapons.get_children():",
	"\t\t\t\tweapons.remove_child(child)",
	"\t\t\t\tchild.queue_free()",
	"\t\tvar scene: PackedScene = e.get(\"weapon_scene\")",
	"\t\tif scene == null:",
	"\t\t\tcontinue",
	"\t\tvar inst: Node = scene.instantiate()",
	"\t\tweapons.add_child(inst)",
	"\t\tif inst.has_method(\"hide\"):",
	"\t\t\tinst.hide()",
	"",
	"func _rtv_ai_categories() -> Array:",
	"\tvar out: Array = []",
]

# SelectVariant() runs before SelectWeapon(): the faction names the category, the
# variant name adds the specific one ("Punisher").
const _AI_CATEGORIES_BY_VARIANT: Array[String] = [
	"\tif variant == null:",
	"\t\treturn out",
	"\tvar faction_keys: Array = AIData.Faction.keys()",
	"\tvar f: int = int(variant.faction)",
	"\tif f >= 0 and f < faction_keys.size():",
	"\t\tout.append(String(faction_keys[f]))",
	"\tvar variant_name: String = String(variant.name)",
	"\tif variant_name != \"\" and not (variant_name in out):",
	"\t\tout.append(variant_name)",
	"\treturn out",
]

# The pre-Build 2 shape (a boss flag and the spawner's zone). Without the AISpawner
# back-reference the zone is unknowable, so the AI matches no entry.
const _AI_CATEGORIES_BY_ZONE: Array[String] = [
	"\tif boss:",
	"\t\tout.append(\"Punisher\")",
	"\t\treturn out",
	"\tif AISpawner == null:",
	"\t\treturn out",
	"\tvar z: int = AISpawner.zone",
	"\tvar zone_keys: Array = AISpawner.Zone.keys()",
	"\tif z < 0 or z >= zone_keys.size():",
	"\t\treturn out",
	"\tmatch zone_keys[z]:",
	"\t\t\"Area05\":",
	"\t\t\tout.append(\"Bandit\")",
	"\t\t\"BorderZone\":",
	"\t\t\tout.append(\"Guard\")",
	"\t\t\"Vostok\":",
	"\t\t\tout.append(\"Military\")",
	"\treturn out",
]

# Engine meta, because every AISpawner in a scene shares one registry.
# Vanilla anchor: AISpawner.gd Zone enum; the emitted resolver converts the zone int via Zone.keys().
const _AISPAWNER_APPENDIX: Array[String] = [
	"# --- Metro mod loader: AI type override resolver ---",
	"func _rtv_resolve_ai_type(z: int, vanilla: Variant) -> Variant:",
	"\tvar overrides: Dictionary = Engine.get_meta(\"" + _AI_ENGINE_META_KEY + "\", {})",
	"\tif overrides.is_empty():",
	"\t\treturn vanilla",
	# Zone.keys() is untyped, so `:=` cannot infer.
	"\tvar key: String = Zone.keys()[z]",
	"\tif overrides.has(key):",
	"\t\treturn overrides[key]",
	"\treturn vanilla",
]
