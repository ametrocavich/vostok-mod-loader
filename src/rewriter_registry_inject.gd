# Per-script registry injection. Scripts with a matching entry in the
# REGISTRY_INJECTIONS map below get extra code appended: a runtime dict for
# mod-registered entries and a _get() override that serves them transparently.
# Vanilla game code calling Node.get(name) falls through to _get() when the
# name isn't a declared property/const, which is how mod data is exposed
# without modifying the vanilla lookup call sites.
func _rtv_registry_injection(filename: String, indent: String, source: String = "") -> String:
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
			var inj := _rtv_inject_ai_registry(indent, source)
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
# Vanilla anchor: top-level `const X = preload("...")` declarations in Database.gd; silent no-op if the game changes the decl style.
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
# Vanilla anchor: top-level `const shelters = [...]` declaration in Loader.gd; silent no-op if renamed or restructured.
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
			var with_prelude := _rtv_inject_prelude(lines, rename_prefix + "LoadScene", _rtv_loader_loadscene_prelude(), false, indent_unit, filename)
			# The re-apply reads the prelude's local, so it needs the prelude.
			if with_prelude.size() == lines.size():
				return with_prelude
			return _rtv_inject_loader_scene_reapply(with_prelude, rename_prefix + "LoadScene", indent_unit)
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
# return), so mods reuse the full vanilla loading flow (fade, label, timer,
# scene change). Vanilla's if-elif won't match a mod name; for a vanilla
# name it reassigns scenePath, and for most it sets that scene's flags too,
# which _rtv_inject_loader_scene_reapply then applies the entry over.
# Vanilla anchor: Loader.gd::LoadScene relies on locals `scenePath` + `scene`, gameData.menu/shelter/permadeath/tutorial flags, and the tail change_scene_to_file(scenePath).
func _rtv_loader_loadscene_prelude() -> PackedStringArray:
	var p := PackedStringArray()
	p.append("\t# --- Metro mod loader: scene_paths registry prelude ---")
	p.append("\tvar _rtv_scene_entry: Dictionary = {}")
	# The name asked for, before transition_text relabels `scene`.
	p.append("\tvar _rtv_scene_name: String = scene")
	p.append("\tif _rtv_override_scene_paths.has(scene):")
	p.append("\t\t_rtv_scene_entry = _rtv_override_scene_paths[scene]")
	p.append("\telif _rtv_mod_scene_paths.has(scene):")
	p.append("\t\t_rtv_scene_entry = _rtv_mod_scene_paths[scene]")
	p.append("\tif not _rtv_scene_entry.is_empty():")
	p.append("\t\tscenePath = _rtv_scene_entry.get(\"path\", \"\")")
	# A mod scene gets every flag (false unless set); a vanilla name only the
	# ones the entry names, the chain below sets that scene's own.
	p.append("\t\t_rtv_scene_entry_flags(_rtv_scene_entry, _rtv_scene_name, gameData)")
	# B_Loader compat: transition_text reassigns the `scene` arg so the
	# vanilla loading label shows it. Vanilla never reads `scene` again
	# after the label code, so clobbering is safe. Not for a vanilla scene
	# name: the chain has to match it to set that scene's flags, or a Cabin
	# override with a label loads with shelter false and quitting there
	# resets the character instead of saving it.
	p.append("\t\tvar _rtv_label: String = String(_rtv_scene_entry.get(\"transition_text\", \"\"))")
	p.append("\t\tif _rtv_label != \"\" and not _rtv_is_vanilla_scene(_rtv_scene_name):")
	p.append("\t\t\tscene = _rtv_label")
	p.append("\t# Fall through: vanilla if-elif won't match mod names; the tail")
	p.append("\t# runs change_scene_to_file(scenePath) with our path set above.")
	return p

# The vanilla if/elif in LoadScene runs after the prelude and reassigns
# scenePath for every vanilla scene name (and, for all but Menu, Intro and
# Death, that scene's gameData flags), so an
# override of a vanilla scene ("Cabin") loaded the vanilla scene anyway, as
# did a mod scene whose transition_text names one. The entry is applied
# again just before the tail's timer and scene change. Its flags go through
# _rtv_scene_entry_flags (Loader appendix): an override of a vanilla scene
# keeps that scene's own flags unless it names them, since a Cabin loaded
# with shelter=false resets the character on quit instead of saving it.
# Vanilla anchor: Loader.gd::LoadScene ends with body-level `await get_tree().create_timer(...).timeout` then `get_tree().change_scene_to_file(scenePath)`.
func _rtv_inject_loader_scene_reapply(lines: PackedStringArray, func_name: String, indent_unit: String) -> PackedStringArray:
	var start := -1
	for i in lines.size():
		if lines[i].begins_with("func " + func_name + "("):
			start = i
			break
	if start < 0:
		return lines
	var target := -1
	var i := start + 1
	while i < lines.size():
		var ln: String = lines[i]
		if ln.strip_edges() != "" and not (ln.begins_with("\t") or ln.begins_with(" ")):
			break
		# Body level only: a scene change nested in a branch is not the tail.
		if _rtv_body_level(ln, indent_unit) \
				and ln.strip_edges().replace(" ", "").trim_suffix(";") == "get_tree().change_scene_to_file(scenePath)":
			target = i
		i += 1
	if target < 0:
		_log_critical("[RTVCodegen] Loader.gd: LoadScene no longer ends in change_scene_to_file(scenePath) (game update?) -- overriding a vanilla scene with scene_paths will NOT work. Update the modloader.")
		return lines
	# Land before the timer the scene change waits on, where vanilla's own
	# branch set the flags.
	var insert_at := target
	var j := target - 1
	while j > start and lines[j].strip_edges() == "":
		j -= 1
	if _rtv_body_level(lines[j], indent_unit) and lines[j].strip_edges().begins_with("await "):
		insert_at = j
	var block := PackedStringArray([
		"# --- Metro mod loader: scene_paths registry, after the vanilla chain ---",
		"if not _rtv_scene_entry.is_empty():",
		"\tscenePath = _rtv_scene_entry.get(\"path\", \"\")",
		"\t_rtv_scene_entry_flags(_rtv_scene_entry, _rtv_scene_name, gameData)",
	])
	var result := lines.slice(0, insert_at)
	for b in block:
		var depth := 0
		while depth < b.length() and b[depth] == "\t":
			depth += 1
		result.append(indent_unit.repeat(depth + 1) + b.substr(depth))
	result.append_array(lines.slice(insert_at))
	return result

# A line indented exactly one unit: a statement of the function body itself.
func _rtv_body_level(line: String, indent_unit: String) -> bool:
	if indent_unit.is_empty():
		return false
	return line.begins_with(indent_unit) and not line.substr(indent_unit.length()).begins_with(indent_unit[0])

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
	# Scene-name consts live on the vanilla script; a mod that replaces
	# Loader.gd with a subclass moves them to the base script, and a
	# script's constant map lists only its own.
	out += "\n# --- Metro mod loader: scene_paths helpers ---\n"
	out += "func _rtv_is_vanilla_scene(scene_name: String) -> bool:\n"
	out += I1 + "var s: Script = get_script()\n"
	out += I1 + "while s != null:\n"
	out += I2 + "if s.get_script_constant_map().has(scene_name):\n"
	out += I3 + "return true\n"
	out += I2 + "s = s.get_base_script()\n"
	out += I1 + "return false\n"
	out += "\n"
	# Before and after the vanilla chain: a mod scene gets every flag, false
	# unless the entry sets it. A vanilla scene name keeps the flags the chain
	# gives it (Menu, Intro and Death keep the ones they arrived with), and an
	# override replaces only the flags it names.
	out += "func _rtv_scene_entry_flags(entry: Dictionary, scene_name: String, data: Object) -> void:\n"
	out += I1 + "var vanilla_name: bool = _rtv_is_vanilla_scene(scene_name)\n"
	out += I1 + "for flag in [\"menu\", \"shelter\", \"permadeath\", \"tutorial\"]:\n"
	out += I2 + "if entry.has(flag) or not vanilla_name:\n"
	out += I3 + "data.set(flag, entry.get(flag, false))\n"
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
	# A path under a vanilla scene name (Village, Bridge) would replace that
	# map in LoadScene; register('scene_paths') refuses the same collision.
	out += I1 + "if scene_path != \"\" and _rtv_is_vanilla_scene(id):\n"
	out += I2 + "push_warning(\"[B_Loader compat] '\" + id + \"' is a vanilla scene name; pick a new name\")\n"
	out += I2 + "return false\n"
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

# AISpawner.gd: rewrite each `enemy = <name>` (Build 2; `agent = <name>`
# before it) so the assignment routes through _rtv_resolve_ai_type (defined
# in the registry appendix), which picks between the vanilla scene and a
# mod override for the zone.
# Vanilla anchor: AISpawner.gd::Initialize (`_ready` before Build 2) `enemy = <ident>` / `agent = <ident>` assignment lines inside the Zone if/elif; silent no-op if the mapping moves.
func _rtv_rewrite_aispawner_agent_assignments(source: String) -> String:
	var lines: PackedStringArray = source.split("\n")
	var re := RegEx.new()
	re.compile('^(\\s*)(enemy|agent)\\s*=\\s*(\\w+)\\s*(#.*)?$')
	var rewrites := 0
	for i in lines.size():
		var line: String = lines[i]
		var m := re.search(line)
		if m == null:
			continue
		var indent := m.get_string(1)
		var target := m.get_string(2)
		var name := m.get_string(3)
		# Leave keyword RHS alone.
		if name in ["true", "false", "null"]:
			continue
		lines[i] = "%s%s = _rtv_resolve_ai_type(zone, %s)" % [indent, target, name]
		rewrites += 1
	if rewrites == 0:
		# No assignment got the resolver wired in; registered AI overrides
		# would silently never spawn.
		if _any_mod_declared_registry:
			_log_critical("[RTVCodegen] AISpawner.gd: vanilla 'enemy = <name>' assignments not found (game update?) -- AI type overrides will NOT work. Update the modloader.")
		else:
			_log_debug("[RTVCodegen] AISpawner.gd: no 'enemy = <name>' assignments matched; ai_types resolver not wired (inert, no [registry] declared)")
	return "\n".join(lines)

# FishPool._ready() prelude: appends mod-registered species to the local
# `species` array before vanilla's random-spawn loop picks from it. Each
# instance filters by its own node name ("all" is a wildcard). Duplicate
# scenes are skipped to keep the random-pick weight stable.
# Vanilla anchor: FishPool.gd::_ready relies on local `species: Array[PackedScene]` declared before the random-spawn loop.
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
# Vanilla anchor: Compiler.gd::Spawn relies on locals `spawnTarget`/`transitions`/`waypoints`/`controller` (leading var decls), gameData.previousMap, and /root/Map.mapName.
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
# Vanilla anchor: AI.gd::SelectWeapon relies on the `weapons` child container + hidden-until-picked child contract.
func _rtv_ai_selectweapon_prelude() -> PackedStringArray:
	var p := PackedStringArray()
	p.append("\t# --- Metro mod loader: ai_loadouts registry prelude ---")
	p.append("\t_rtv_apply_ai_loadouts()")
	return p

# Vanilla anchor: AI.gd field `weapons` (the child container) plus one of two
# category shapes. Build 2 (Nomads) and later: `variant: AIData` with
# `faction` (enum Faction{Nomad, Bandit, Guard, Military, Boss}) and `name`
# ("Punisher", "Bogeyman", ...). Before Build 2: fields `boss`/`AISpawner` +
# AISpawner.Zone key names "Area05"/"BorderZone"/"Vostok". The source picks.
func _rtv_inject_ai_registry(indent: String, source: String = "") -> String:
	# AI.gd registry appendix: reads the ai_loadouts Engine-meta list and
	# injects weapon instances into self.weapons. An AI matches an entry when
	# any of its categories is in the entry's ai_types.
	var I1 := indent
	var out := "\n\n# --- Metro mod loader: AI loadouts registry ---\n"
	out += "func _rtv_apply_ai_loadouts() -> void:\n"
	out += I1 + "var entries: Array = Engine.get_meta(\"_rtv_ai_loadouts\", [])\n"
	out += I1 + "if entries.is_empty():\n"
	out += I1 + I1 + "return\n"
	# Mod-defined AI scenes might omit the weapons @export; bail, not crash.
	out += I1 + "if weapons == null:\n"
	out += I1 + I1 + "return\n"
	out += I1 + "var categories: Array = _rtv_ai_categories()\n"
	out += I1 + "if categories.is_empty():\n"
	out += I1 + I1 + "return\n"
	out += I1 + "for e in entries:\n"
	# Engine meta is process-global; skip malformed entries, don't crash.
	out += I1 + I1 + "if not (e is Dictionary):\n"
	out += I1 + I1 + I1 + "continue\n"
	out += I1 + I1 + "var ai_types: Array = e.get(\"ai_types\", [])\n"
	out += I1 + I1 + "var matched: bool = false\n"
	out += I1 + I1 + "for c in categories:\n"
	out += I1 + I1 + I1 + "if c in ai_types:\n"
	out += I1 + I1 + I1 + I1 + "matched = true\n"
	out += I1 + I1 + "if not matched:\n"
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
	out += "func _rtv_ai_categories() -> Array:\n"
	out += I1 + "var out: Array = []\n"
	if _rtv_ai_source_has_variant_faction(source):
		# Build 2: SelectVariant() runs before SelectWeapon() in Initialize(),
		# so `variant` is set. The faction key names the category ("Bandit",
		# "Boss", ...); the variant name adds the specific one ("Punisher").
		out += I1 + "if variant == null:\n"
		out += I1 + I1 + "return out\n"
		out += I1 + "var faction_keys: Array = AIData.Faction.keys()\n"
		out += I1 + "var f: int = int(variant.faction)\n"
		out += I1 + "if f >= 0 and f < faction_keys.size():\n"
		out += I1 + I1 + "out.append(String(faction_keys[f]))\n"
		out += I1 + "var variant_name: String = String(variant.name)\n"
		out += I1 + "if variant_name != \"\" and not (variant_name in out):\n"
		out += I1 + I1 + "out.append(variant_name)\n"
		out += I1 + "return out\n"
		return out
	# Pre-Build 2 shape, kept while the codegen harness still runs on the
	# rtv0.1.1.3 corpus (VANILLA_SRC): that run is the proof the switch above
	# picks by source, not by loader build. boss + AISpawner are set by
	# AISpawner.CreatePools(); without the back-reference the zone category
	# is unknowable, so bail.
	out += I1 + "if boss:\n"
	out += I1 + I1 + "out.append(\"Punisher\")\n"
	out += I1 + I1 + "return out\n"
	out += I1 + "if AISpawner == null:\n"
	out += I1 + I1 + "return out\n"
	# Zone.keys() yields the enum's string form at the same index, matching
	# the ai_types convention.
	out += I1 + "var z: int = AISpawner.zone\n"
	out += I1 + "var zone_keys: Array = AISpawner.Zone.keys()\n"
	out += I1 + "if z < 0 or z >= zone_keys.size():\n"
	out += I1 + I1 + "return out\n"
	out += I1 + "match zone_keys[z]:\n"
	out += I1 + I1 + "\"Area05\":\n"
	out += I1 + I1 + I1 + "out.append(\"Bandit\")\n"
	out += I1 + I1 + "\"BorderZone\":\n"
	out += I1 + I1 + I1 + "out.append(\"Guard\")\n"
	out += I1 + I1 + "\"Vostok\":\n"
	out += I1 + I1 + I1 + "out.append(\"Military\")\n"
	out += I1 + "return out\n"
	return out

# Build 2 replaced AI.gd's `boss` flag with a `variant: AIData` whose
# `faction` enum carries the category. Matched on the declaration line so a
# vanilla AI.gd of either shape gets the resolver that compiles against it.
func _rtv_ai_source_has_variant_faction(source: String) -> bool:
	if source == "":
		return false
	var re := RegEx.new()
	re.compile("(?m)^var variant\\s*:\\s*AIData\\b")
	return re.search(source) != null

# Vanilla anchor: AISpawner.gd Zone enum; the emitted resolver converts the zone int via Zone.keys().
func _rtv_inject_aispawner_registry(indent: String) -> String:
	# Resolver helper for the rewritten `enemy = _rtv_resolve_ai_type(...)`
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

