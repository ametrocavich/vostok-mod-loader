# Per-script registry injection. Scripts with a matching entry in the
# REGISTRY_INJECTIONS map below get extra code appended: a runtime dict for
# mod-registered entries and a _get() override that serves them transparently.
# Vanilla game code calling Node.get(name) falls through to _get() when the
# name isn't a declared property/const, which is how we expose mod data
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
	# Database.gd is just an appendix here. The REAL transform is done up
	# front in _rtv_rewrite_database_constants(): every vanilla `const X =
	# preload(...)` is converted to an entry in _rtv_vanilla_scenes, so
	# Database.get() can route through _get() and pick up mod overrides.
	#
	# What this appendix adds:
	#   _rtv_mod_scenes[name]      -> new scenes mods registered (lib.register)
	#   _rtv_override_scenes[name] -> scenes mods overrode (lib.override)
	#   _get()                     -> lookup order: override > mod > vanilla
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

# Walks Database.gd's source, moves every top-level `const X = preload("...")`
# into a single _rtv_vanilla_scenes dictionary var. All other content
# (extends, @export, @tool, functions, non-preload consts) stays put.
#
# Why: GDScript's compile-time const lookup bypasses _get(), so mods can't
# override what Database.get("Potato") returns. Consts can't be shadowed at
# runtime. Moving them into a dict lets _get() see every name and route
# through the mod override layer.
#
# ExecuteUpdate() in @tool mode reads get_script_constant_map() to build
# LT_Master at edit time. That's editor-only and irrelevant to runtime
# modding, but we also swap that call for an iteration over
# _rtv_vanilla_scenes so @tool still works if someone opens the script.
# ANCHOR: vanilla Database.gd -- top-level `const X = preload("...")` declarations; silent no-op if the game changes the decl style.
func _rtv_rewrite_database_constants(source: String) -> String:
	var lines: PackedStringArray = source.split("\n")
	var entries: PackedStringArray = []  # "KEY = PRELOAD"
	var out_lines: PackedStringArray = []
	# Regex: top-level `const NAME = preload("path")` with optional trailing
	# comment. Captures the name and the full preload expression verbatim so
	# we don't disturb whitespace/quoting.
	var re := RegEx.new()
	# Detokenized source never carries comments (the tokenizer drops them),
	# but the plain-text fallback path in _detokenize_script can.
	re.compile('^const\\s+(\\w+)\\s*=\\s*(preload\\s*\\(\\s*"[^"]+"\\s*\\))\\s*(?:#.*)?$')
	for line: String in lines:
		var m := re.search(line)
		if m != null:
			entries.append("\t\"%s\": %s," % [m.get_string(1), m.get_string(2)])
			continue
		out_lines.append(line)
	if entries.is_empty():
		# Not survivable silently: the registry appendix appended later
		# references _rtv_vanilla_scenes, which only this transform declares.
		# Without it the rewritten Database.gd fails to compile, killing
		# Database hooks AND the scenes registry in one stroke.
		_log_critical("[RTVCodegen] Database.gd: vanilla const layout changed (no 'const X = preload(...)' found) -- the scenes registry and Database hooks will NOT work. Update the modloader.")
		return source
	# Inject the dict var right after the extends/script-annotation preamble.
	# Safe place: before any function. Walk until we find the first `func ` or
	# class_name and insert above it. If none found, append at end.
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

# Loader.gd transform: `const shelters = [...]` -> `var shelters = [...]`.
# GDScript consts can't be mutated, but the registry needs to append mod
# shelter names at runtime. Only the one shelters line is affected; the
# scene-path consts (const Cabin = "...", etc.) stay consts because
# LoadScene's body references them by name directly. The prelude injection
# handles mod scene paths without touching those consts.
#
# Also stashes a snapshot var `_rtv_vanilla_shelters` so the registry can
# compute "what's vanilla vs mod" for integrity checks / revert.
# ANCHOR: vanilla Loader.gd -- top-level `const shelters = [...]` declaration; silent no-op if renamed/restructured.
func _rtv_rewrite_loader_shelters(source: String) -> String:
	var lines: PackedStringArray = source.split("\n")
	var re := RegEx.new()
	# Match: optional leading whitespace (shouldn't happen at top level but
	# tolerate), "const shelters" followed by the rest of the declaration.
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
		# `shelters` stays const, so the appended add_shelter()/registry
		# appends will fail at runtime. Only user-impacting when a mod
		# actually uses the registry/B_Loader surface -- which is gated by
		# _any_mod_declared_registry.
		if _any_mod_declared_registry:
			_log_critical("[RTVCodegen] Loader.gd: vanilla 'const shelters' declaration not found (game update?) -- mod shelters/maps will NOT work. Update the modloader.")
		else:
			_log_debug("[RTVCodegen] Loader.gd: 'const shelters' not found; const-to-var transform skipped (inert, no [registry] declared)")
		return source
	return "\n".join(lines)

# Function-body prelude injection dispatcher. Returns lines array (may be
# unchanged). Called after the rename pass -- the target function has
# already been renamed to _rtv_vanilla_<Name>, so we look for the renamed
# signature.
func _rtv_apply_prelude_injections(filename: String, lines: PackedStringArray, rename_prefix: String, indent_unit: String = "\t") -> PackedStringArray:
	match filename:
		"Loader.gd":
			return _rtv_inject_prelude(lines, rename_prefix + "LoadScene", _rtv_loader_loadscene_prelude(), false, indent_unit, filename)
		"FishPool.gd":
			return _rtv_inject_prelude(lines, rename_prefix + "_ready", _rtv_fishpool_ready_prelude(), false, indent_unit, filename)
		"AI.gd":
			return _rtv_inject_prelude(lines, rename_prefix + "SelectWeapon", _rtv_ai_selectweapon_prelude(), false, indent_unit, filename)
		"Compiler.gd":
			# Spawn's prelude assigns to vanilla's `spawnTarget` local, which
			# is declared on the first body line. Insert after the run of
			# leading var decls so spawnTarget is in scope.
			return _rtv_inject_prelude(lines, rename_prefix + "Spawn", _rtv_compiler_spawn_prelude(), true, indent_unit, filename)
		_:
			return lines

# Finds `func <func_name>(` at top level and inserts `prelude_lines` right
# after its signature (before any body code). The function was already
# renamed by the rewriter's pass 1, so callers pass the renamed name.
# If the function has multiple blank lines at the top of its body, the
# prelude slots in before them.
#
# `after_var_decls`: when true, insertion happens AFTER the run of leading
# `var ...` and blank lines at the top of the body, rather than directly
# under the signature. Use this when the prelude needs to reference a
# local declared by vanilla (e.g. Compiler.Spawn's `spawnTarget`).
func _rtv_inject_prelude(lines: PackedStringArray, func_name: String, prelude_lines: PackedStringArray, after_var_decls: bool = false, indent_unit: String = "\t", context_file: String = "") -> PackedStringArray:
	var needle := "func " + func_name + "("
	var sig_target := -1
	for i in lines.size():
		var line: String = lines[i]
		if line.begins_with(needle):
			sig_target = i
			break
	if sig_target < 0:
		# Two very different situations land here:
		#   (a) A mod declared [registry], so this script was wrapped whole-
		#       script and the target method SHOULD have been renamed. Its
		#       absence means the registry feature this prelude feeds is dead
		#       (game update removed/changed the method, or its signature
		#       failed to parse). That is user-impacting: registrations
		#       silently stop applying. CRITICAL.
		#   (b) No mod declared [registry]: the script entered the wrap
		#       surface via [hooks]/.hook() with a per-method mask that does
		#       not include this method, so it was never renamed. The prelude
		#       is inert scaffolding in that session -- nothing a user or mod
		#       author needs to act on. Dev-mode debug only.
		if _any_mod_declared_registry:
			_log_critical("[RTVCodegen] %s: registry code for %s could not be installed (method missing from the wrapped script -- game update?). Mod content registered against it will NOT appear." \
					% [context_file, func_name])
		else:
			_log_debug("[RTVCodegen] %s: prelude target %s not in this script's hook mask and no [registry] declared -- prelude skipped (inert this session)" \
					% [context_file, func_name])
		return lines
	var insert_after := sig_target
	if after_var_decls:
		# Advance past leading body lines that are blank or indented `var ...`
		# declarations. Stop on the first indented line that isn't a var
		# declaration. If we hit a top-level line first (next func or EOF),
		# the function body was empty -- fall back to inserting at signature.
		var j := sig_target + 1
		while j < lines.size():
			var ln: String = lines[j]
			var stripped: String = ln.strip_edges()
			if stripped == "":
				j += 1
				continue
			# Top-level line means we ran out of body.
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
				# Prelude templates are authored with tab indentation;
				# re-indent to the target file's unit so tab/space mixing
				# can't break a space-indented source.
				var pls: String = pl
				var n := 0
				while n < pls.length() and pls[n] == "\t":
					n += 1
				result.append(indent_unit.repeat(n) + pls.substr(n))
	return result

# The LoadScene prelude. Checks the mod + override scene-path dicts at
# the top of the function; on match, sets `scenePath` and applies the
# mod's gameData flag overrides. Does NOT early-return.
#
# Design rationale: vanilla LoadScene's structure is:
#     FadeInLoading(); gameData.freeze = true
#     <label visibility setup>
#     if scene == "Cabin": scenePath = Cabin; <flags>
#     elif ...
#     <tail> await timer; get_tree().change_scene_to_file(scenePath)
#
# We insert right after the func signature, so our prelude runs BEFORE
# the fade/label setup AND the if-elif. If the scene name is a mod
# registration, we set scenePath + flags here. The if-elif then falls
# through with no match (mod names aren't vanilla), and the tail code
# picks up our scenePath for change_scene_to_file. Vanilla fade/label
# setup still runs (harmless side-effects we want).
#
# This means mod scene_paths registrations:
#   - reuse vanilla's full loading flow (fade, label, timer, scene change)
#   - can override vanilla scenes (override takes precedence in the check)
#   - don't need to replicate any vanilla scene-change logic
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
	# Apply gameData flags if the mod specified them. Defaults favor a
	# generic non-shelter non-tutorial non-permadeath zone.
	p.append("\t\tgameData.menu = _rtv_scene_entry.get(\"menu\", false)")
	p.append("\t\tgameData.shelter = _rtv_scene_entry.get(\"shelter\", false)")
	p.append("\t\tgameData.permadeath = _rtv_scene_entry.get(\"permadeath\", false)")
	p.append("\t\tgameData.tutorial = _rtv_scene_entry.get(\"tutorial\", false)")
	# B_Loader compat: if the entry carries a transition_text, reassign the
	# `scene` arg so vanilla's `label.text = \"Loading \" + scene + \"...\"`
	# below uses the modder's preferred display name. Vanilla never reads
	# `scene` again after the label code, so it's safe to clobber.
	p.append("\t\tvar _rtv_label: String = String(_rtv_scene_entry.get(\"transition_text\", \"\"))")
	p.append("\t\tif _rtv_label != \"\":")
	p.append("\t\t\tscene = _rtv_label")
	p.append("\t# Fall through: vanilla if-elif won't match mod names; the tail")
	p.append("\t# runs change_scene_to_file(scenePath) with our path set above.")
	return p

func _rtv_inject_loader_registry(indent: String) -> String:
	# Loader.gd registry appendix. Adds the mod-scene-path dicts, a snapshot
	# of the vanilla shelters list for integrity/revert, and the rich
	# shelter/map entries that Compiler.Spawn's prelude consults at world
	# transition time (B_Loader-style add_shelter / add_map fields:
	# transition_text, exit_spawn, entrance_spawn, connected_to,
	# connected_content, shelter:bool).
	#
	# Also injects B_Loader compat shim methods (add_shelter / add_map) so
	# mods written against the BitByteBytes B_Loader project keep working
	# without requiring B_Loader as a dependency. The shim translates the
	# legacy dict shape (map_name + scene_path) to our internal entry
	# format and writes directly to _rtv_mod_shelters + shelters +
	# _rtv_mod_scene_paths, mirroring what _register_shelter_or_map does on
	# the RTVModLib side. Mods can migrate to lib.register at their own
	# pace; until then, the existing call site Just Works.
	#
	# Note: _rtv_vanilla_shelters is captured at @onready time from the
	# shelters var (which the const->var rewrite left populated with the
	# vanilla list). The registry can diff shelters against this snapshot
	# to tell vanilla entries apart from mod additions.
	var I1 := indent
	var I2 := indent + indent
	var I3 := indent + indent + indent
	var out: String = "\n\n# --- Metro mod loader: Loader registry state ---\n" \
		+ "var _rtv_mod_scene_paths: Dictionary = {}\n" \
		+ "var _rtv_override_scene_paths: Dictionary = {}\n" \
		+ "var _rtv_mod_shelters: Dictionary = {}\n" \
		+ "@onready var _rtv_vanilla_shelters: Array = shelters.duplicate()\n"
	# B_Loader compat shim. Same dict shape as BitByteBytes/B_Loader README.
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
	# B_Loader uses 'scene_path'; our schema uses 'path'. Accept both.
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
	# Auto-register a scene_paths entry if a scene path was provided so the
	# LoadScene prelude can route to it. Mirrors what _register_shelter_or_map
	# does on the RTVModLib side.
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

# AISpawner.gd transform: rewrite each `agent = <name>` inside _ready() so
# the assignment goes through the _rtv_resolve_ai_type helper (defined in
# the registry appendix). That helper reads Engine.get_meta(
# "_rtv_ai_overrides", {}) to decide between the vanilla scene and any
# mod-registered replacement for the current zone.
#
# Pattern matched: the exact 5-line block `if zone == Zone.Foo: agent = bar`
# -- we search for leading-whitespace + `agent =` and rewrite it. Only
# vanilla fields (bandit/guard/military/punisher) should trigger this; any
# other `agent = <literal>` outside those cases is left alone.
# ANCHOR: vanilla AISpawner.gd::_ready -- `agent = <ident>` assignment lines inside the Zone if/elif; silent no-op if the mapping moves.
func _rtv_rewrite_aispawner_agent_assignments(source: String) -> String:
	var lines: PackedStringArray = source.split("\n")
	# Regex: optional indent, "agent" "=" then an identifier (the vanilla
	# preloaded name) with optional trailing comment/whitespace.
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
		# Leave numeric / keyword RHS alone (won't happen in vanilla but be safe).
		if name in ["true", "false", "null"]:
			continue
		lines[i] = "%sagent = _rtv_resolve_ai_type(zone, %s)" % [indent, name]
		rewrites += 1
	if rewrites == 0:
		# The ai_types override resolver was not wired into any assignment;
		# registered AI overrides would silently never spawn. Only user-
		# impacting when the registry surface is actually in use.
		if _any_mod_declared_registry:
			_log_critical("[RTVCodegen] AISpawner.gd: vanilla 'agent = <name>' assignments not found (game update?) -- AI type overrides will NOT work. Update the modloader.")
		else:
			_log_debug("[RTVCodegen] AISpawner.gd: no 'agent = <name>' assignments matched; ai_types resolver not wired (inert, no [registry] declared)")
	return "\n".join(lines)

# FishPool._ready() prelude: appends mod-registered species to the local
# `species: Array[PackedScene]` var BEFORE vanilla's random-spawn loop
# picks from it. The registry stores a flat list in Engine meta; each
# FishPool instance filters by its own node name (or "all" as a wildcard).
#
# Dedupe: if a mod registers the same scene twice (or another mod does too),
# we don't re-append. Keeps the random-pick weight stable when the same
# scene would otherwise multiply.
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

# Compiler.Spawn prelude: handles two B_Loader-style cases at function head.
#
#   1. Player just transitioned INTO a registered shelter or map. Run the
#      vanilla load sequence (LoadWorld + LoadCharacter + optional
#      LoadShelter + Simulation.simulate=true), set spawnTarget to the
#      entry's exit_spawn, run the transition-pose loop ourselves, fire
#      the gameData.* resets, and `return` so vanilla's if-elif chain
#      doesn't double-process.
#
#   2. Player transitioned INTO a vanilla map that has at least one
#      registered shelter/map hanging off it via `connected_to`. Spawn
#      the connected_content props into /root/Map/Content additively. If
#      the player is arriving FROM a registered shelter (previousMap is a
#      mod entry name), pre-set spawnTarget to that entry's
#      entrance_spawn -- vanilla's if-elif then runs LoadWorld/LoadChar
#      etc as normal but its inner `if previousMap == ...` checks only
#      know vanilla map names, so our spawnTarget survives. Fall through
#      to vanilla so it handles the rest.
#
# Conditions for handling are checked against Loader._rtv_mod_shelters
# (populated by _register_shelter_or_map). When the mod shelters dict is
# empty (no relevant mod loaded), the prelude is effectively a tight
# branch + early continue with no behavior change vs vanilla.
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
	# Run the transition-pose loop ourselves so we can early-return. Reuses
	# vanilla's `transitions` local declared above (the prelude lands after
	# var decls thanks to after_var_decls=true on the inject call).
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
	# Refresh the locals `transitions` and `waypoints`: vanilla captured
	# them at the top of Spawn() BEFORE our connected_content was added,
	# so any Transition / AI_WP node inside the freshly spawned scenes
	# wouldn't be in the original snapshot. Without this, the tail's
	# pose-loop misses the entrance_spawn target and any modded waypoint
	# spawn never participates in the random-pick fallback.
	p.append("\t\t\ttransitions = get_tree().get_nodes_in_group(\"Transition\")")
	p.append("\t\t\twaypoints = get_tree().get_nodes_in_group(\"AI_WP\")")
	# If player is arriving from this mod shelter, pre-set entrance_spawn.
	p.append("\t\t\tif String(gameData.previousMap) == _rtv_key:")
	p.append("\t\t\t\tspawnTarget = String(_rtv_e.get(\"entrance_spawn\", \"\"))")
	p.append("\t# Fall through to vanilla if-elif (which handles vanilla maps).")
	return p

# AI.SelectWeapon prelude: calls the loadout-application helper before
# vanilla picks a weapon. Helper iterates the ai_loadouts engine-meta
# entries, rolls per entry, instantiates matching weapon scenes and
# adds them to self.weapons. Vanilla SelectWeapon then runs as written
# and picks one at random from the augmented pool.
# ANCHOR: vanilla AI.gd::SelectWeapon -- relies on the `weapons` child container + hidden-until-picked child contract.
func _rtv_ai_selectweapon_prelude() -> PackedStringArray:
	var p := PackedStringArray()
	p.append("\t# --- Metro mod loader: ai_loadouts registry prelude ---")
	p.append("\t_rtv_apply_ai_loadouts()")
	return p

# ANCHOR: vanilla AI.gd fields `weapons`/`boss`/`AISpawner` + AISpawner.Zone enum key names "Area05"/"BorderZone"/"Vostok" (hardcoded in the emitted match below).
func _rtv_inject_ai_registry(indent: String) -> String:
	# AI.gd registry appendix. Helper functions read the ai_loadouts
	# Engine-meta list and inject weapon scene instances into self.weapons
	# before vanilla SelectWeapon picks. Category derivation uses self.boss
	# + self.AISpawner.zone (vanilla AISpawner is the per-AI back-reference
	# set during CreatePools).
	var I1 := indent
	var out := "\n\n# --- Metro mod loader: AI loadouts registry ---\n"
	out += "func _rtv_apply_ai_loadouts() -> void:\n"
	out += I1 + "var entries: Array = Engine.get_meta(\"_rtv_ai_loadouts\", [])\n"
	out += I1 + "if entries.is_empty():\n"
	out += I1 + I1 + "return\n"
	# weapons may be null on AI scenes that don't declare it (mod-defined
	# AI scenes might omit the @export). Bail rather than crash.
	out += I1 + "if weapons == null:\n"
	out += I1 + I1 + "return\n"
	out += I1 + "var category: String = _rtv_ai_category()\n"
	out += I1 + "if category == \"\":\n"
	out += I1 + I1 + "return\n"
	out += I1 + "for e in entries:\n"
	# Defensive checks -- entries originate from the registry validator
	# but Engine.meta is process-global so other code could in theory
	# write nonsense in. Skip silently rather than crash.
	out += I1 + I1 + "if not (e is Dictionary):\n"
	out += I1 + I1 + I1 + "continue\n"
	out += I1 + I1 + "var ai_types: Array = e.get(\"ai_types\", [])\n"
	out += I1 + I1 + "if not (category in ai_types):\n"
	out += I1 + I1 + I1 + "continue\n"
	out += I1 + I1 + "if randf() > float(e.get(\"chance\", 1.0)):\n"
	out += I1 + I1 + I1 + "continue\n"
	out += I1 + I1 + "if bool(e.get(\"replace\", false)):\n"
	out += I1 + I1 + I1 + "for child in weapons.get_children():\n"
	out += I1 + I1 + I1 + I1 + "child.queue_free()\n"
	out += I1 + I1 + "var scene: PackedScene = e.get(\"weapon_scene\")\n"
	out += I1 + I1 + "if scene == null:\n"
	out += I1 + I1 + I1 + "continue\n"
	out += I1 + I1 + "var inst: Node = scene.instantiate()\n"
	out += I1 + I1 + "weapons.add_child(inst)\n"
	# Vanilla SelectWeapon expects every child of weapons to be hidden
	# initially; show() runs only on the picked one. Match that contract
	# so vanilla logic stays correct.
	out += I1 + I1 + "if inst.has_method(\"hide\"):\n"
	out += I1 + I1 + I1 + "inst.hide()\n"
	out += "\n"
	out += "func _rtv_ai_category() -> String:\n"
	# self.boss is set by AISpawner.CreatePools() (true for the punisher
	# in BPool, false for the regular agents in APool). AISpawner is the
	# back-reference also set there. Without AISpawner we can't tell which
	# zone-driven category this AI belongs to, so we bail.
	out += I1 + "if boss:\n"
	out += I1 + I1 + "return \"Punisher\"\n"
	out += I1 + "if AISpawner == null:\n"
	out += I1 + I1 + "return \"\"\n"
	# Zone is an int (enum). AISpawner.Zone.keys() yields the string form
	# at the same index, matching the convention used by ai_types.
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
	# AISpawner.gd registry appendix. Adds the resolver helper used by the
	# rewritten `agent = _rtv_resolve_ai_type(zone, vanilla)` assignments.
	# The override lookup goes through Engine metadata rather than node
	# instance state because AISpawner is a per-scene Node3D -- there are
	# multiple instances, and mods write to one shared registry that every
	# spawner reads on _ready.
	#
	# Zone keys are the string form of the Zone enum (e.g. "Area05"). The
	# resolver uses Zone.keys()[zone_int] to convert the enum value to its
	# declared name, matching what the registry stores.
	var I1 := indent
	var out := "\n\n# --- Metro mod loader: AI type override resolver ---\n"
	out += "func _rtv_resolve_ai_type(z: int, vanilla: Variant) -> Variant:\n"
	out += I1 + "var overrides: Dictionary = Engine.get_meta(\"_rtv_ai_overrides\", {})\n"
	out += I1 + "if overrides.is_empty():\n"
	out += I1 + I1 + "return vanilla\n"
	# Zone.keys() returns Array (untyped), so `:=` can't infer. Type
	# explicitly for strict-mode GDScript parsers.
	out += I1 + "var key: String = Zone.keys()[z]\n"
	out += I1 + "if overrides.has(key):\n"
	out += I1 + I1 + "return overrides[key]\n"
	out += I1 + "return vanilla\n"
	return out

