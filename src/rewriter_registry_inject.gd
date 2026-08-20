# Per-script registry injection. Scripts with a matching entry in the
# REGISTRY_INJECTIONS map below get extra code appended: a runtime dict for
# mod-registered entries and a _get() override that serves them transparently.
# Vanilla game code calling Node.get(name) falls through to _get() when the
# name isn't a declared property/const, which is how mod data is exposed
# without modifying the vanilla lookup call sites.
func _rtv_registry_injection(filename: String, indent: String) -> String:
	match filename:
		"Database.gd":
			var inj := _rtv_inject_database_registry(indent)
			_log_info("[RTVCodegen] Injected registry into %s (%d chars)" % [filename, inj.length()])
			return inj
		"Loader.gd":
			var inj := _rtv_inject_loader_registry(indent)
			_log_info("[RTVCodegen] Injected registry into %s (%d chars)" % [filename, inj.length()])
			return inj
		"AISpawner.gd":
			var inj := _rtv_inject_aispawner_registry(indent)
			_log_info("[RTVCodegen] Injected registry into %s (%d chars)" % [filename, inj.length()])
			return inj
		"AI.gd":
			var inj := _rtv_inject_ai_registry(indent)
			_log_info("[RTVCodegen] Injected registry into %s (%d chars)" % [filename, inj.length()])
			return inj
		_:
			return ""

func _rtv_inject_database_registry(indent: String) -> String:
	# The real transform is _rtv_rewrite_database_constants(); this appendix
	# adds the mod/override dicts plus a _get() with lookup order
	# override > mod > vanilla.
	var I1 := indent
	return "\n\n# --- Metro mod loader registry injection ---\n" \
		+ "var _rtv_mod_scenes: Dictionary = {}\n" \
		+ "var _rtv_override_scenes: Dictionary = {}\n" \
		+ "\n" \
		+ "func _get(property: StringName):\n" \
		+ I1 + "var key := String(property)\n" \
		+ I1 + "if _rtv_override_scenes.has(key):\n" \
		+ I1 + I1 + "return _rtv_override_scenes[key]\n" \
		+ I1 + "if _rtv_mod_scenes.has(key):\n" \
		+ I1 + I1 + "return _rtv_mod_scenes[key]\n" \
		+ I1 + "if _rtv_vanilla_scenes.has(key):\n" \
		+ I1 + I1 + "return _rtv_vanilla_scenes[key]\n" \
		+ I1 + "return null\n"

# Moves every top-level `const X = preload("...")` in Database.gd into one
# _rtv_vanilla_scenes dict var; everything else stays put. Compile-time
# const lookup bypasses _get() and consts can't be shadowed at runtime, so
# the dict is what lets _get() route names through the mod override layer.
# ANCHOR: vanilla Database.gd -- top-level `const X = preload("...")` declarations; silent no-op if the game changes the decl style.
func _rtv_rewrite_database_constants(source: String) -> String:
	var lines: PackedStringArray = source.split("\n")
	var entries: PackedStringArray = []  # "KEY = PRELOAD"
	var out_lines: PackedStringArray = []
	var re := RegEx.new()
	# Trailing comments allowed: detokenized source has none, but the
	# plain-text fallback path in _detokenize_script can carry them.
	re.compile('^const\\s+(\\w+)\\s*=\\s*(preload\\s*\\(\\s*"[^"]+"\\s*\\))\\s*(?:#.*)?$')
	for line: String in lines:
		var m := re.search(line)
		if m != null:
			entries.append("\t\"%s\": %s," % [m.get_string(1), m.get_string(2)])
			continue
		out_lines.append(line)
	if entries.is_empty():
		# The registry appendix references _rtv_vanilla_scenes, which only
		# this transform declares; without it Database.gd fails to compile.
		_log_critical("[RTVCodegen] Database.gd: vanilla const layout changed (no 'const X = preload(...)' found) -- the scenes registry and Database hooks will NOT work. Update the modloader.")
		return source
	# Insert the dict var above the first func (or append at end).
	var dict_block := "\n# --- Metro mod loader: vanilla scene dict (rewritten from const declarations) ---\n" \
		+ "var _rtv_vanilla_scenes: Dictionary = {\n" \
		+ "\n".join(entries) + "\n" \
		+ "}\n"
	var insert_at := -1
	for i in out_lines.size():
		var trimmed: String = (out_lines[i] as String).strip_edges()
		if trimmed.begins_with("func ") or trimmed.begins_with("static func "):
			insert_at = i
			break
	if insert_at < 0:
		return "\n".join(out_lines) + dict_block
	var before := out_lines.slice(0, insert_at)
	var after := out_lines.slice(insert_at)
	return "\n".join(before) + "\n" + dict_block + "\n" + "\n".join(after)

# Loader.gd: `const shelters = [...]` -> `var` so the registry can append
# mod shelter names at runtime. The scene-path consts (const Cabin = "...")
# stay consts -- LoadScene references them directly; the prelude injection
# handles mod scene paths instead.
# ANCHOR: vanilla Loader.gd -- top-level `const shelters = [...]` declaration; silent no-op if renamed/restructured.
func _rtv_rewrite_loader_shelters(source: String) -> String:
	var lines: PackedStringArray = source.split("\n")
	var re := RegEx.new()
	re.compile('^(\\s*)const\\s+shelters\\s*(=.*)$')
	var changed := false
	for i in lines.size():
		var line: String = lines[i]
		var m := re.search(line)
		if m == null:
			continue
		lines[i] = m.get_string(1) + "var shelters " + m.get_string(2)
		changed = true
	if not changed:
		# shelters stays const and registry appends would fail at runtime;
		# only user-impacting when a mod uses the registry/B_Loader surface.
		if _any_mod_declared_registry:
			_log_critical("[RTVCodegen] Loader.gd: vanilla 'const shelters' declaration not found (game update?) -- mod shelters/maps will NOT work. Update the modloader.")
		else:
			_log_debug("[RTVCodegen] Loader.gd: 'const shelters' not found; const-to-var transform skipped (inert, no [registry] declared)")
		return source
	return "\n".join(lines)

# Prelude injection dispatcher. Runs after the rename pass, so targets
# match the renamed _rtv_vanilla_<Name> signature.
func _rtv_apply_prelude_injections(filename: String, lines: PackedStringArray, rename_prefix: String, indent_unit: String = "\t") -> PackedStringArray:
	match filename:
		"Loader.gd":
			return _rtv_inject_prelude(lines, rename_prefix + "LoadScene", _rtv_loader_loadscene_prelude(), false, indent_unit, filename)
		"FishPool.gd":
			return _rtv_inject_prelude(lines, rename_prefix + "_ready", _rtv_fishpool_ready_prelude(), false, indent_unit, filename)
		"AI.gd":
			return _rtv_inject_prelude(lines, rename_prefix + "SelectWeapon", _rtv_ai_selectweapon_prelude(), false, indent_unit, filename)
		"Compiler.gd":
			# Insert after the leading var decls so vanilla's `spawnTarget`
			# local is in scope for the prelude.
			return _rtv_inject_prelude(lines, rename_prefix + "Spawn", _rtv_compiler_spawn_prelude(), true, indent_unit, filename)
		_:
			return lines

# Inserts prelude_lines right after the signature of `func <func_name>(`.
# `after_var_decls` shifts the insertion past the run of leading `var`
# lines, for preludes that reference a vanilla-declared local.
func _rtv_inject_prelude(lines: PackedStringArray, func_name: String, prelude_lines: PackedStringArray, after_var_decls: bool = false, indent_unit: String = "\t", context_file: String = "") -> PackedStringArray:
	var needle := "func " + func_name + "("
	var sig_target := -1
	for i in lines.size():
		var line: String = lines[i]
		if line.begins_with(needle):
			sig_target = i
			break
	if sig_target < 0:
		# With [registry] declared the method should have been renamed, so
		# its absence means registrations silently stop applying: critical.
		# Without [registry] the script was wrapped via a per-method mask
		# that excludes this method and the prelude is inert: debug only.
		if _any_mod_declared_registry:
			_log_critical("[RTVCodegen] %s: registry code for %s could not be installed (method missing from the wrapped script -- game update?). Mod content registered against it will NOT appear." \
					% [context_file, func_name])
		else:
			_log_debug("[RTVCodegen] %s: prelude target %s not in this script's hook mask and no [registry] declared -- prelude skipped (inert this session)" \
					% [context_file, func_name])
		return lines
	var insert_after := sig_target
	if after_var_decls:
		# Advance past blank/`var` body lines; an empty body falls back to
		# inserting at the signature.
		var j := sig_target + 1
		while j < lines.size():
			var ln: String = lines[j]
			var stripped: String = ln.strip_edges()
			if stripped == "":
				j += 1
				continue
			# Top-level line means the body ended.
			if not (ln.begins_with("\t") or ln.begins_with(" ")):
				break
			if stripped.begins_with("var "):
				insert_after = j
				j += 1
				continue
			break
		if insert_after == sig_target:
			_log_warning("[RTVCodegen] %s: %s no longer starts with the expected 'var' declarations (game update?) -- the injected registry code may not compile; registry features on this script may not work." \
					% [context_file, func_name])
	var result := PackedStringArray()
	for i in lines.size():
		result.append(lines[i])
		if i == insert_after:
			for pl in prelude_lines:
				if indent_unit == "\t":
					result.append(pl)
					continue
				# Prelude templates are tab-indented; re-indent to the target
				# file's unit so tab/space mixing can't break the source.
				var pls: String = pl
				var n := 0
				while n < pls.length() and pls[n] == "\t":
					n += 1
				result.append(indent_unit.repeat(n) + pls.substr(n))
	return result

# LoadScene prelude: checks the mod + override scene-path dicts; on match
# sets `scenePath` and gameData flags, then falls through (no early
# return). Vanilla's if-elif won't match mod names, so the tail's
# change_scene_to_file picks up the scenePath set here and mods reuse the
# full vanilla loading flow (fade, label, timer, scene change).
# ANCHOR: vanilla Loader.gd::LoadScene -- relies on locals `scenePath` + `scene`, gameData.menu/shelter/permadeath/tutorial flags, and the tail change_scene_to_file(scenePath).
func _rtv_loader_loadscene_prelude() -> PackedStringArray:
	var p := PackedStringArray()
	p.append("\t# --- Metro mod loader: scene_paths registry prelude ---")
	p.append("\tvar _rtv_scene_entry: Dictionary = {}")
	p.append("\tif _rtv_override_scene_paths.has(scene):")
	p.append("\t\t_rtv_scene_entry = _rtv_override_scene_paths[scene]")
	p.append("\telif _rtv_mod_scene_paths.has(scene):")
	p.append("\t\t_rtv_scene_entry = _rtv_mod_scene_paths[scene]")
	p.append("\tif not _rtv_scene_entry.is_empty():")
	p.append("\t\tscenePath = _rtv_scene_entry.get(\"path\", \"\")")
	# Flag defaults favor a generic non-shelter non-tutorial zone.
	p.append("\t\tgameData.menu = _rtv_scene_entry.get(\"menu\", false)")
	p.append("\t\tgameData.shelter = _rtv_scene_entry.get(\"shelter\", false)")
	p.append("\t\tgameData.permadeath = _rtv_scene_entry.get(\"permadeath\", false)")
	p.append("\t\tgameData.tutorial = _rtv_scene_entry.get(\"tutorial\", false)")
	# B_Loader compat: transition_text reassigns the `scene` arg so the
	# vanilla loading label shows it. Vanilla never reads `scene` again
	# after the label code, so clobbering is safe.
	p.append("\t\tvar _rtv_label: String = String(_rtv_scene_entry.get(\"transition_text\", \"\"))")
	p.append("\t\tif _rtv_label != \"\":")
	p.append("\t\t\tscene = _rtv_label")
	p.append("\t# Fall through: vanilla if-elif won't match mod names; the tail")
	p.append("\t# runs change_scene_to_file(scenePath) with our path set above.")
	return p

func _rtv_inject_loader_registry(indent: String) -> String:
	# Loader.gd registry appendix: mod-scene-path dicts, a vanilla-shelters
	# snapshot (captured at @onready, lets the registry tell vanilla entries
	# from mod additions), and B_Loader compat shims (add_shelter/add_map)
	# so mods written against BitByteBytes' B_Loader keep working without
	# it as a dependency. The shims mirror _register_shelter_or_map on the
	# RTVModLib side.
	var I1 := indent
	var I2 := indent + indent
	var I3 := indent + indent + indent
	var out: String = "\n\n# --- Metro mod loader: Loader registry state ---\n" \
		+ "var _rtv_mod_scene_paths: Dictionary = {}\n" \
		+ "var _rtv_override_scene_paths: Dictionary = {}\n" \
		+ "var _rtv_mod_shelters: Dictionary = {}\n" \
		+ "@onready var _rtv_vanilla_shelters: Array = shelters.duplicate()\n"
	# Same dict shape as BitByteBytes/B_Loader README.
	out += "\n# --- Metro mod loader: B_Loader compat shim ---\n"
	out += "func add_shelter(d: Dictionary) -> bool:\n"
	out += I1 + "return _rtv_bloader_compat_register(d, true)\n"
	out += "\n"
	out += "func add_map(d: Dictionary) -> bool:\n"
	out += I1 + "return _rtv_bloader_compat_register(d, false)\n"
	out += "\n"
	out += "func _rtv_bloader_compat_register(d: Dictionary, default_shelter: bool) -> bool:\n"
	out += I1 + "if not (d is Dictionary):\n"
	out += I2 + "push_warning(\"[B_Loader compat] add_shelter/add_map expects a Dictionary\")\n"
	out += I2 + "return false\n"
	out += I1 + "var id: String = String(d.get(\"map_name\", \"\"))\n"
	out += I1 + "if id == \"\":\n"
	out += I2 + "push_warning(\"[B_Loader compat] dict is missing 'map_name'\")\n"
	out += I2 + "return false\n"
	out += I1 + "if _rtv_mod_shelters.has(id):\n"
	out += I2 + "push_warning(\"[B_Loader compat] '\" + id + \"' already registered\")\n"
	out += I2 + "return false\n"
	out += I1 + "if id in shelters:\n"
	out += I2 + "push_warning(\"[B_Loader compat] '\" + id + \"' already in vanilla shelters list\")\n"
	out += I2 + "return false\n"
	out += I1 + "var is_shelter: bool = bool(d.get(\"shelter\", default_shelter))\n"
	# B_Loader uses 'scene_path'; this schema uses 'path'. Accept both.
	out += I1 + "var scene_path: String = String(d.get(\"path\", d.get(\"scene_path\", \"\")))\n"
	out += I1 + "var entry: Dictionary = {\n"
	out += I2 + "\"shelter\": is_shelter,\n"
	out += I2 + "\"transition_text\": String(d.get(\"transition_text\", id)),\n"
	out += I2 + "\"exit_spawn\": String(d.get(\"exit_spawn\", \"\")),\n"
	out += I2 + "\"entrance_spawn\": String(d.get(\"entrance_spawn\", \"\")),\n"
	out += I2 + "\"connected_to\": String(d.get(\"connected_to\", \"\")),\n"
	out += I2 + "\"connected_content\": d.get(\"connected_content\", []),\n"
	out += I1 + "}\n"
	out += I1 + "_rtv_mod_shelters[id] = entry\n"
	out += I1 + "shelters.append(id)\n"
	# Auto-register a scene_paths entry so the LoadScene prelude can route.
	out += I1 + "if scene_path != \"\":\n"
	out += I2 + "var sp: Dictionary = {\n"
	out += I3 + "\"path\": scene_path,\n"
	out += I3 + "\"shelter\": is_shelter,\n"
	out += I3 + "\"transition_text\": entry[\"transition_text\"],\n"
	out += I2 + "}\n"
	out += I2 + "if d.has(\"menu\"): sp[\"menu\"] = d[\"menu\"]\n"
	out += I2 + "if d.has(\"permadeath\"): sp[\"permadeath\"] = d[\"permadeath\"]\n"
	out += I2 + "if d.has(\"tutorial\"): sp[\"tutorial\"] = d[\"tutorial\"]\n"
	out += I2 + "_rtv_mod_scene_paths[id] = sp\n"
	out += I1 + "print(\"[B_Loader compat] registered '\" + id + \"' (shelter=\" + str(is_shelter) + \", connected_to='\" + entry[\"connected_to\"] + \"')\")\n"
	out += I1 + "return true\n"
	return out

# AISpawner.gd: rewrite each `agent = <name>` so the assignment routes
# through _rtv_resolve_ai_type (defined in the registry appendix), which
# picks between the vanilla scene and a mod override for the zone.
# ANCHOR: vanilla AISpawner.gd::_ready -- `agent = <ident>` assignment lines inside the Zone if/elif; silent no-op if the mapping moves.
func _rtv_rewrite_aispawner_agent_assignments(source: String) -> String:
	var lines: PackedStringArray = source.split("\n")
	var re := RegEx.new()
	re.compile('^(\\s*)agent\\s*=\\s*(\\w+)\\s*(#.*)?$')
	var rewrites := 0
	for i in lines.size():
		var line: String = lines[i]
		var m := re.search(line)
		if m == null:
			continue
		var indent := m.get_string(1)
		var name := m.get_string(2)
		# Leave keyword RHS alone.
		if name in ["true", "false", "null"]:
			continue
		lines[i] = "%sagent = _rtv_resolve_ai_type(zone, %s)" % [indent, name]
		rewrites += 1
	if rewrites == 0:
		# No assignment got the resolver wired in; registered AI overrides
		# would silently never spawn.
		if _any_mod_declared_registry:
			_log_critical("[RTVCodegen] AISpawner.gd: vanilla 'agent = <name>' assignments not found (game update?) -- AI type overrides will NOT work. Update the modloader.")
		else:
			_log_debug("[RTVCodegen] AISpawner.gd: no 'agent = <name>' assignments matched; ai_types resolver not wired (inert, no [registry] declared)")
	return "\n".join(lines)

# FishPool._ready() prelude: appends mod-registered species to the local
# `species` array before vanilla's random-spawn loop picks from it. Each
# instance filters by its own node name ("all" is a wildcard). Duplicate
# scenes are skipped to keep the random-pick weight stable.
# ANCHOR: vanilla FishPool.gd::_ready -- relies on local `species: Array[PackedScene]` declared before the random-spawn loop.
func _rtv_fishpool_ready_prelude() -> PackedStringArray:
	var p := PackedStringArray()
	p.append("\t# --- Metro mod loader: fish_species registry prelude ---")
	p.append("\tvar _rtv_mod_fish: Array = Engine.get_meta(\"_rtv_fish_species\", [])")
	p.append("\tfor _rtv_fe in _rtv_mod_fish:")
	p.append("\t\tif _rtv_fe.pool_id == \"all\" or _rtv_fe.pool_id == name:")
	p.append("\t\t\tif not (_rtv_fe.scene in species):")
	p.append("\t\t\t\tspecies.append(_rtv_fe.scene)")
	return p

# Compiler.Spawn prelude, two B_Loader-style cases:
#   1. Arriving in a registered shelter/map: run the vanilla load sequence,
#      set spawnTarget to the entry's exit_spawn, run the transition-pose
#      loop, reset gameData.* flags, and return so vanilla's if-elif
#      doesn't double-process.
#   2. Arriving in a vanilla map with registered entries connected_to it:
#      spawn connected_content additively; if arriving from a registered
#      shelter, pre-set spawnTarget to its entrance_spawn (vanilla's inner
#      previousMap checks only know vanilla names, so it survives), then
#      fall through to vanilla.
# With no relevant mod loaded the prelude is a tight branch with no
# behavior change.
# ANCHOR: vanilla Compiler.gd::Spawn -- relies on locals `spawnTarget`/`transitions`/`waypoints`/`controller` (leading var decls), gameData.previousMap, and /root/Map.mapName.
func _rtv_compiler_spawn_prelude() -> PackedStringArray:
	var p := PackedStringArray()
	p.append("\t# --- Metro mod loader: shelters/maps registry prelude ---")
	p.append("\tvar _rtv_map_node: Node = get_tree().current_scene.get_node_or_null(\"/root/Map\")")
	p.append("\tif _rtv_map_node != null and \"_rtv_mod_shelters\" in Loader:")
	p.append("\t\tvar _rtv_mn: String = String(_rtv_map_node.mapName)")
	p.append("\t\tvar _rtv_entry: Dictionary = Loader._rtv_mod_shelters.get(_rtv_mn, {})")
	# Case 1: arriving in a registered shelter / map.
	p.append("\t\tif not _rtv_entry.is_empty():")
	p.append("\t\t\tLoader.LoadWorld()")
	p.append("\t\t\tLoader.LoadCharacter()")
	p.append("\t\t\tif bool(_rtv_entry.get(\"shelter\", false)):")
	p.append("\t\t\t\tLoader.LoadShelter(_rtv_mn)")
	p.append("\t\t\tSimulation.simulate = true")
	p.append("\t\t\tspawnTarget = String(_rtv_entry.get(\"exit_spawn\", \"\"))")
	# Pose loop reuses vanilla's `transitions` local (prelude lands after
	# the var decls via after_var_decls=true).
	p.append("\t\t\tif spawnTarget != \"\":")
	p.append("\t\t\t\tfor _rtv_t in transitions:")
	p.append("\t\t\t\t\tif _rtv_t.owner.name == spawnTarget:")
	p.append("\t\t\t\t\t\tvar _rtv_sp = _rtv_t.owner.spawn")
	p.append("\t\t\t\t\t\tif _rtv_sp:")
	p.append("\t\t\t\t\t\t\tcontroller.global_transform.basis = _rtv_sp.global_transform.basis")
	p.append("\t\t\t\t\t\t\tcontroller.global_transform.basis = controller.global_transform.basis.rotated(Vector3.UP, deg_to_rad(180))")
	p.append("\t\t\t\t\t\t\tcontroller.global_position = _rtv_sp.global_position")
	p.append("\t\t\tgameData.isTransitioning = false")
	p.append("\t\t\tgameData.isSleeping = false")
	p.append("\t\t\tgameData.isOccupied = false")
	p.append("\t\t\tgameData.freeze = false")
	p.append("\t\t\treturn")
	# Case 2: this map is connected_to for one or more registered shelters/maps.
	p.append("\t\tfor _rtv_key in Loader._rtv_mod_shelters:")
	p.append("\t\t\tvar _rtv_e: Dictionary = Loader._rtv_mod_shelters[_rtv_key]")
	p.append("\t\t\tif String(_rtv_e.get(\"connected_to\", \"\")) != _rtv_mn:")
	p.append("\t\t\t\tcontinue")
	# Spawn connected_content additively.
	p.append("\t\t\tvar _rtv_content: Node = get_tree().current_scene.get_node_or_null(\"/root/Map/Content\")")
	p.append("\t\t\tif _rtv_content != null:")
	p.append("\t\t\t\tvar _rtv_items: Array = _rtv_e.get(\"connected_content\", [])")
	p.append("\t\t\t\tfor _rtv_item in _rtv_items:")
	p.append("\t\t\t\t\tif not (_rtv_item is Dictionary):")
	p.append("\t\t\t\t\t\tcontinue")
	p.append("\t\t\t\t\tvar _rtv_p: String = String(_rtv_item.get(\"path\", \"\"))")
	p.append("\t\t\t\t\tif _rtv_p == \"\":")
	p.append("\t\t\t\t\t\tcontinue")
	p.append("\t\t\t\t\tvar _rtv_packed = load(_rtv_p)")
	p.append("\t\t\t\t\tif _rtv_packed == null:")
	p.append("\t\t\t\t\t\tpush_warning(\"[Registry] connected_content: failed to load \" + _rtv_p)")
	p.append("\t\t\t\t\t\tcontinue")
	p.append("\t\t\t\t\tvar _rtv_inst = _rtv_packed.instantiate()")
	p.append("\t\t\t\t\tif \"position\" in _rtv_item:")
	p.append("\t\t\t\t\t\t_rtv_inst.position = _rtv_item[\"position\"]")
	p.append("\t\t\t\t\tif \"rotation\" in _rtv_item:")
	p.append("\t\t\t\t\t\t_rtv_inst.rotation_degrees = _rtv_item[\"rotation\"]")
	p.append("\t\t\t\t\t_rtv_content.add_child(_rtv_inst)")
	# Refresh `transitions`/`waypoints`: vanilla snapshotted them before
	# connected_content was added, so nodes in the freshly spawned scenes
	# would be missed by the tail's pose loop and waypoint fallback.
	p.append("\t\t\ttransitions = get_tree().get_nodes_in_group(\"Transition\")")
	p.append("\t\t\twaypoints = get_tree().get_nodes_in_group(\"AI_WP\")")
	# If player is arriving from this mod shelter, pre-set entrance_spawn.
	p.append("\t\t\tif String(gameData.previousMap) == _rtv_key:")
	p.append("\t\t\t\tspawnTarget = String(_rtv_e.get(\"entrance_spawn\", \"\"))")
	p.append("\t# Fall through to vanilla if-elif (which handles vanilla maps).")
	return p

# AI.SelectWeapon prelude: applies ai_loadouts entries to self.weapons
# before vanilla picks at random from the augmented pool.
# ANCHOR: vanilla AI.gd::SelectWeapon -- relies on the `weapons` child container + hidden-until-picked child contract.
func _rtv_ai_selectweapon_prelude() -> PackedStringArray:
	var p := PackedStringArray()
	p.append("\t# --- Metro mod loader: ai_loadouts registry prelude ---")
	p.append("\t_rtv_apply_ai_loadouts()")
	return p

# ANCHOR: vanilla AI.gd fields `weapons`/`boss`/`AISpawner` + AISpawner.Zone enum key names "Area05"/"BorderZone"/"Vostok" (hardcoded in the emitted match below).
func _rtv_inject_ai_registry(indent: String) -> String:
	# AI.gd registry appendix: reads the ai_loadouts Engine-meta list and
	# injects weapon instances into self.weapons. Category comes from
	# self.boss + self.AISpawner.zone (back-reference set in CreatePools).
	var I1 := indent
	var out := "\n\n# --- Metro mod loader: AI loadouts registry ---\n"
	out += "func _rtv_apply_ai_loadouts() -> void:\n"
	out += I1 + "var entries: Array = Engine.get_meta(\"_rtv_ai_loadouts\", [])\n"
	out += I1 + "if entries.is_empty():\n"
	out += I1 + I1 + "return\n"
	# Mod-defined AI scenes might omit the weapons @export; bail, not crash.
	out += I1 + "if weapons == null:\n"
	out += I1 + I1 + "return\n"
	out += I1 + "var category: String = _rtv_ai_category()\n"
	out += I1 + "if category == \"\":\n"
	out += I1 + I1 + "return\n"
	out += I1 + "for e in entries:\n"
	# Engine meta is process-global; skip malformed entries, don't crash.
	out += I1 + I1 + "if not (e is Dictionary):\n"
	out += I1 + I1 + I1 + "continue\n"
	out += I1 + I1 + "var ai_types: Array = e.get(\"ai_types\", [])\n"
	out += I1 + I1 + "if not (category in ai_types):\n"
	out += I1 + I1 + I1 + "continue\n"
	out += I1 + I1 + "if randf() > float(e.get(\"chance\", 1.0)):\n"
	out += I1 + I1 + I1 + "continue\n"
	out += I1 + I1 + "if bool(e.get(\"replace\", false)):\n"
	out += I1 + I1 + I1 + "for child in weapons.get_children():\n"
	# Unparent before freeing: queue_free() alone leaves the replaced
	# weapons in get_children() until end of frame, and vanilla could pick
	# a node that is about to disappear.
	out += I1 + I1 + I1 + I1 + "weapons.remove_child(child)\n"
	out += I1 + I1 + I1 + I1 + "child.queue_free()\n"
	out += I1 + I1 + "var scene: PackedScene = e.get(\"weapon_scene\")\n"
	out += I1 + I1 + "if scene == null:\n"
	out += I1 + I1 + I1 + "continue\n"
	out += I1 + I1 + "var inst: Node = scene.instantiate()\n"
	out += I1 + I1 + "weapons.add_child(inst)\n"
	# Vanilla SelectWeapon expects every weapons child hidden until picked.
	out += I1 + I1 + "if inst.has_method(\"hide\"):\n"
	out += I1 + I1 + I1 + "inst.hide()\n"
	out += "\n"
	out += "func _rtv_ai_category() -> String:\n"
	# boss + AISpawner are set by AISpawner.CreatePools(); without the
	# back-reference the zone category is unknowable, so bail.
	out += I1 + "if boss:\n"
	out += I1 + I1 + "return \"Punisher\"\n"
	out += I1 + "if AISpawner == null:\n"
	out += I1 + I1 + "return \"\"\n"
	# Zone.keys() yields the enum's string form at the same index, matching
	# the ai_types convention.
	out += I1 + "var z: int = AISpawner.zone\n"
	out += I1 + "var zone_keys: Array = AISpawner.Zone.keys()\n"
	out += I1 + "if z < 0 or z >= zone_keys.size():\n"
	out += I1 + I1 + "return \"\"\n"
	out += I1 + "match zone_keys[z]:\n"
	out += I1 + I1 + "\"Area05\":\n"
	out += I1 + I1 + I1 + "return \"Bandit\"\n"
	out += I1 + I1 + "\"BorderZone\":\n"
	out += I1 + I1 + I1 + "return \"Guard\"\n"
	out += I1 + I1 + "\"Vostok\":\n"
	out += I1 + I1 + I1 + "return \"Military\"\n"
	out += I1 + I1 + "_:\n"
	out += I1 + I1 + I1 + "return \"\"\n"
	return out

# ANCHOR: vanilla AISpawner.gd Zone enum -- emitted resolver converts zone int via Zone.keys().
func _rtv_inject_aispawner_registry(indent: String) -> String:
	# Resolver helper for the rewritten `agent = _rtv_resolve_ai_type(...)`
	# assignments. Lookup goes through Engine metadata because AISpawner is
	# a per-scene Node3D with multiple instances sharing one registry.
	var I1 := indent
	var out := "\n\n# --- Metro mod loader: AI type override resolver ---\n"
	out += "func _rtv_resolve_ai_type(z: int, vanilla: Variant) -> Variant:\n"
	out += I1 + "var overrides: Dictionary = Engine.get_meta(\"_rtv_ai_overrides\", {})\n"
	out += I1 + "if overrides.is_empty():\n"
	out += I1 + I1 + "return vanilla\n"
	# Zone.keys() is untyped, so `:=` can't infer; type explicitly.
	out += I1 + "var key: String = Zone.keys()[z]\n"
	out += I1 + "if overrides.has(key):\n"
	out += I1 + I1 + "return overrides[key]\n"
	out += I1 + "return vanilla\n"
	return out

