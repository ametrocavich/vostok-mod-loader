## Codegen harness: rewrites each fixture with the real rewriter, then compiles it and a caller stub.
## Proves what compiles and what the text holds; check_dispatch.sh proves what the wrappers do.
extends SceneTree

const H := preload("res://harness.gd")

## "file" is a res://Scripts/ basename; "mask" also rewrites with that
## per-method mask and checks that only the masked methods were wrapped.
const FIXTURES: Array[Dictionary] = [
	{"file": "FixtureDefaults.gd", "mask": ["DefaultsTricky", "CoroutineValue"]},
	{"file": "FixtureSub.gd"},     # after FixtureDefaults.gd: compiles against the rewritten parent
	{"file": "FixtureShapes.gd"},
	{"file": "Loader.gd", "mask": ["ValidateShelter", "LoadScene", "FadeIn"]},
	{"file": "Database.gd"},       # const->dict declaration transform + _get() appendix
	{"file": "AISpawner.gd"},      # agent-assignment rewrite + Zone resolver appendix
	{"file": "AI.gd"},             # SelectWeapon prelude + loadouts appendix
	{"file": "FishPool.gd"},       # _ready prelude
	{"file": "Compiler.gd"},       # Spawn prelude (after_var_decls insertion)
	{"file": "Camera.gd"},         # class_name script
	{"file": "Character.gd"},      # large, several coroutines
	{"file": "Menu.gd", "mask": ["_ready"]},
	{"file": "Bed.gd"},            # small, await-heavy
]

## Methods whose body the rewriter changes on purpose (preludes); only the
## body-verbatim check skips them. Bodies with a bare super() are skipped too.
const BODY_MODIFIED := {
	"Loader.gd": ["LoadScene"],
	"Compiler.gd": ["Spawn"],
	"FishPool.gd": ["_ready"],
	"AI.gd": ["SelectWeapon"],
	"AISpawner.gd": ["_ready", "Initialize"],
}

const WRAPPER_MARKER := "# --- Metro mod loader inline hook dispatch wrappers ---"

## method -> [is_coroutine, has_return_value] the parser must report.
const EXPECTED_SHAPES := {
	"FixtureShapes.gd": {
		"BindLater": [false, false],
		"ReturnInLambda": [false, false],
		"MultiLineLambdaReturn": [false, false],
		"CoroNoSpace": [true, true],
		"NotAwait": [false, false],
		"IsDead": [false, true],
		"OneLineAwait": [true, false],
		"Collide": [false, true],
		"TypedDict": [false, true],
		"InnerArray": [false, true],
		"Annotated": [false, true],
		"PickAfterLambdaHeader": [false, true],
		"AwaitAfterLambdaHeader": [true, false],
		"AnnotatedAbove": [false, true],
		"TypedLambdaAwait": [false, false],
		"TypedLambdaReturn": [false, false],
		"UnderGroup": [false, true],
		"ReturnsLambda": [false, true],
		"ValueAfterLambda": [false, true],
		"AwaitAfterLambda": [true, false],
		"ReturnOnlyInLambda": [false, false],
		"RegionStart": [false, true],
		"RegionEnd": [false, false],
	},
}

## method -> what its wrapper holds: "value" returns the result, "void" does not,
## "await" awaits the vanilla call; any other entry is the exact declaration prefix.
const WRAPPER_FORMS := {
	"FixtureShapes.gd": {
		"ValueAfterLambda": ["value", ""],
		"AwaitAfterLambda": ["void", "await"],
		"ReturnOnlyInLambda": ["void"],
		"RegionStart": ["value", ""],
		"RegionEnd": ["void", ""],
		"AnnotatedAbove": ["value", "@warning_ignore(\"unused_parameter\") "],
	},
}

const UNWRAPPED := {
	"FixtureShapes.gd": ["Variadic"],
}

## A vanilla member each registry target's injected code names; renaming it is
## what a game update looks like. tests/ingame/rehearse_build.sh parses this table.
const GAME_RENAMES := {
	"AI.gd": "weapons",
	"AISpawner.gd": "Zone",
	"Loader.gd": "shelters",
	"FishPool.gd": "species",
	"Compiler.gd": "spawnTarget",
}

## No engine call lists the builtin types the compiler accepts as parameters.
const BUILTIN_TYPES := ["int", "float", "bool", "String", "StringName", "NodePath",
	"Vector2", "Vector2i", "Vector3", "Vector3i", "Vector4", "Vector4i", "Color",
	"Rect2", "Rect2i", "Basis", "Quaternion", "Transform2D", "Transform3D", "AABB",
	"Plane", "Dictionary", "Array", "Callable", "Signal", "RID", "Variant",
	"PackedByteArray", "PackedStringArray", "PackedInt32Array", "PackedInt64Array",
	"PackedFloat32Array", "PackedFloat64Array", "PackedVector2Array",
	"PackedVector3Array", "PackedColorArray"]

const PLACEHOLDERS := {"": "null", "Variant": "null", "int": "0", "float": "0.0", "bool": "false",
	"String": "\"\"", "StringName": "&\"\"", "Dictionary": "{}"}

var _report := H.Report.new("codegen", "fixtures")
var _started := false
var _global_classes := {}
## Shapes the fixture set exercised; the coverage step demands each one.
var _seen := {}
var _renames_vetted := 0

# The marker prints on the first frame, after the game autoloads' startup noise.
func _process(_delta: float) -> bool:
	if _started:
		printerr("[codegen] FAIL: the first frame stopped before the report")
		quit(1)
		return true
	_started = true
	print("[codegen] harness start")
	var script := load("res://modloader_neutered.gd") as GDScript
	var ml: Object = script.new() if script != null else null
	var mounted: Variant = ml.get("_filescope_mounted") if ml != null else null
	if _report.check(mounted is Dictionary and (mounted as Dictionary).is_empty(), "no loader, or boot static-init ran"):
		var before := _report.assertions
		_run(ml)
		if _report.assertions == before:
			_report.fail("no assertions ran")
	elif ml != null:
		ml.free()
	_report.finish(self)
	return true

func _run(ml: Object) -> void:
	for gc in ProjectSettings.get_global_class_list():
		_global_classes[str(gc["class"])] = true
	# check_codegen.sh leaves this marker when the decompiled game source is absent.
	var synthetic_only := FileAccess.file_exists("res://synthetic_only")
	var run := 0
	for fx in FIXTURES:
		if synthetic_only and not str(fx["file"]).begins_with("Fixture"):
			continue
		_check_fixture(ml, fx)
		run += 1
	_check_parser_edges(ml)
	ml.free()
	_report.begin("coverage")
	var need := ["sync value", "void", "coroutine", "defaults", "excluded verdict"]
	if not synthetic_only:
		need.append("ValidateShelter")
		_report.check_eq(_renames_vetted, GAME_RENAMES.size(), "renamed-member cases run")
	for what in need:
		_report.check(_seen.has(what), "no fixture exercised " + what)
	_report.scope = "%d fixture(s)" % run

# In-memory sources: a two-line signature, own-line annotations, the
# declaration-prefix stripper, the shared method selection and its warnings.
func _check_parser_edges(ml: Object) -> void:
	_report.begin("Edges.gd")
	var two := "extends Node\nfunc Two(a,\n\t\tb):\n\treturn a\n\nfunc One():\n\treturn 1\n"
	var parsed: Dictionary = ml._rtv_parse_script("Edges.gd", two)
	var unparsed: Array = parsed.get("unparsed", [])
	_report.check("Two" in unparsed, "two-line signature not unparsed (got %s)" % str(unparsed))
	_report.check_eq(str(ml._rtv_strip_decl_prefix("@warning_ignore(\"x\") @onready func _rtv_vanilla_Foo(a):")),
			"func _rtv_vanilla_Foo(a):", "stripped annotated declaration")
	_report.check_eq(str(ml._rtv_strip_decl_prefix("func Bar():")), "func Bar():", "stripped plain declaration")

	var prefix_of := func(p: Dictionary, fn: String) -> String:
		var out := ""
		for fe in p["functions"]:
			if str(fe["name"]) == fn:
				out = str(fe.get("decl_prefix", ""))
		return out
	_report.begin("Rpc.gd")
	var rpc_src := "extends Node\n@rpc(\"any_peer\")\nfunc Sync(x):\n\treturn x\n\nfunc Plain():\n\treturn 1\n"
	var rpc_parsed: Dictionary = ml._rtv_parse_script("Rpc.gd", rpc_src)
	var prefix: String = prefix_of.call(rpc_parsed, "Sync")
	_report.check("@rpc" in prefix, "@rpc above Sync not in decl_prefix ('%s')" % prefix)
	var rpc_out: String = ml._rtv_rewrite_vanilla_source(rpc_src, rpc_parsed, {"sync": true, "plain": true})
	_report.check(not ("_rtv_vanilla_Sync" in rpc_out), "an @rpc method was wrapped")
	_report.check("_rtv_vanilla_Plain" in rpc_out, "the plain method beside it unwrapped")
	_report.begin("RpcDoc.gd")
	var rpc_doc := "extends Node\n@rpc(\"any_peer\")\n# doc comment\nfunc Sync(x):\n\treturn x\n"
	prefix = prefix_of.call(ml._rtv_parse_script("RpcDoc.gd", rpc_doc), "Sync")
	_report.check("@rpc" in prefix, "a comment detached @rpc (prefix '%s')" % prefix)
	_report.begin("Grp.gd")
	var grp := "extends Node\n@export_group(\"Debug\")\n\nfunc Under():\n\treturn 1\n"
	_report.check_eq(prefix_of.call(ml._rtv_parse_script("Grp.gd", grp), "Under"), "", "decl_prefix under @export_group")

	# Mask keys are lowercase; statics and unwrappable methods are never
	# selected, and only a named unwrappable method is reported with its reason.
	_report.begin("Select.gd")
	var sel_src := "extends Node\n@rpc(\"any_peer\")\nfunc Sync(x):\n\treturn x\n\nfunc Rest(...args):\n\tpass\n\n" \
			+ "static func Helper():\n\tpass\n\nfunc UpdateToolTip():\n\tpass\n\nfunc Other():\n\tpass\n"
	var sel_parsed: Dictionary = ml._rtv_parse_script("Select.gd", sel_src)
	var mask := {"sync": true, "rest": true, "helper": true, "updatetooltip": true, "missing": true}
	var names_of := func(sel: Dictionary) -> PackedStringArray:
		var out := PackedStringArray()
		for fe in sel["hookable"]:
			out.append(str(fe["name"]))
		return out
	var sel: Dictionary = ml._rtv_select_hookable(sel_parsed, mask)
	_report.check_eq(names_of.call(sel), PackedStringArray(["UpdateToolTip"]), "masked selection")
	_report.check_eq((sel["matched_keys"] as Dictionary).keys(), ["updatetooltip"], "matched_keys")
	var unw: Dictionary = sel["unwrappable"]
	_report.check(unw.keys() == ["sync", "rest"] and str(unw.get("sync", "")).contains("@rpc")
			and str(unw.get("rest", "")).contains("rest parameter"), "unwrappable is %s" % str(unw))
	var all: Dictionary = ml._rtv_select_hookable(sel_parsed, {})
	_report.check(names_of.call(all) == PackedStringArray(["UpdateToolTip", "Other"])
			and (all["matched_keys"] as Dictionary).is_empty() and (all["unwrappable"] as Dictionary).is_empty(),
			"wildcard selection is %s" % str(all))
	# The probe may rewrite a script twice, so only the pack warns, once per script.
	var lines: Array = ml.get("_report_lines")
	lines.clear()
	ml._rtv_rewrite_vanilla_source(sel_src, sel_parsed, mask)
	_report.check(lines.is_empty(), "the rewriter logged %s" % str(lines))
	ml._rtv_warn_mask_misses(sel_parsed, mask)
	ml._rtv_warn_mask_misses(parsed, {"two": true})
	ml._rtv_warn_mask_misses(sel_parsed, {})
	var got: Array = lines.map(func(l): return str(l).trim_prefix("[ModLoader][Warning] [RTVCodegen] "))
	_report.check_eq(got, [
		"Hook on Select.gd::Sync will NEVER fire: the method is an @rpc, which cannot be wrapped.",
		"Hook on Select.gd::Rest will NEVER fire: the method takes a rest parameter (...), which a wrapper cannot forward.",
		"Hook on Select.gd::helper will NEVER fire: it is a static function, and static functions cannot be hooked.",
		"Hook on Select.gd::missing will NEVER fire: no such method in vanilla. Check the spelling, or the game update renamed/removed it.",
		"Hook on Edges.gd::two will NEVER fire: its declaration spans several lines, which the rewriter does not read.",
	], "mask warnings")
	lines.clear()
	_check_rewriter_units(ml)

# Rewriter helpers called directly on lines no fixture holds.
func _check_rewriter_units(ml: Object) -> void:
	_report.begin("BareSuper")
	for c in [["\tsuper (1)", "\tsuper.Foo(1)"], ["\tvar a = helper_super(1)", "\tvar a = helper_super(1)"],
			["\t_super(2)", "\t_super(2)"], ["\tx.super(1)", "\tx.super(1)"],
			["\tsuper(1) # super(2)", "\tsuper.Foo(1) # super(2)"]]:
		_report.check_eq(str(ml._rewrite_bare_super(c[0], "Foo")), c[1], "bare super of '%s'" % c[0])

	var lines: Array = ml.get("_report_lines")
	_report.begin("LineEnds.gd")
	var lf := "extends Node\nfunc Foo():\n\treturn 1\n"
	var cr_out: String = ml._rtv_rewrite_vanilla_source(lf.replace("\n", "\r"),
			ml._rtv_parse_script("LineEnds.gd", lf), {})
	_report.check(not ("\r" in cr_out) and "func _rtv_vanilla_Foo(" in cr_out, "CR-only source not normalized")
	lines.clear()

	_report.begin("SpaceIndent.gd")
	var sp := "extends Node\nfunc Foo():\n  # odd comment\n    return 1\n"
	var sp_out: String = ml._rtv_rewrite_vanilla_source(sp, ml._rtv_parse_script("SpaceIndent.gd", sp), {})
	_report.check(WRAPPER_MARKER in sp_out, "space-indented wrapper emitted")
	var widths := []
	for l in sp_out.substr(sp_out.find(WRAPPER_MARKER)).split("\n"):
		if l.begins_with(" ") and (l.length() - l.lstrip(" ").length()) % 4 != 0:
			widths.append(l)
	_report.check(widths.is_empty(), "wrapper indent not 4 spaces: %s" % str(widths.slice(0, 1)))

	_report.begin("ColZero.gd")
	var cz := "extends Node\nfunc A():\n\tpass\nvar x = 1\n\tawait foo()\nfunc B():\n\tpass\n"
	var cz_funcs: Array = ml._rtv_parse_script("ColZero.gd", cz)["functions"]
	_report.check_eq(cz_funcs.size(), 2, "ColZero functions parsed")
	for fe in cz_funcs:
		_report.check(not fe["is_coroutine"], "%s coroutine past a column-0 line" % fe["name"])

	_report.begin("EnemyRoute")
	var routed: String = ml._route_enemy_assignments(
			"\tenemy = null\n\tenemy = true\n\tagent = false\n\tenemy = Bandit")
	_report.check_eq(routed, "\tenemy = null\n\tenemy = true\n\tagent = false\n" \
			+ "\tenemy = _rtv_resolve_ai_type(zone, Bandit)", "only the named enemy routed")

	_report.begin("Prelude")
	var pre: Array[String] = ["\tPRE"]
	var spawn := PackedStringArray(["func _rtv_vanilla_Spawn():", "\tvar a = 1", "\tvar b = 2",
			"\tif a:", "\t\tvar c = 3", "\tpass"])
	var spliced: PackedStringArray = ml._insert_prelude(spawn, "Compiler.gd", "Spawn", pre, "\t", true)
	_report.check_eq(spliced.find("\tPRE"), 3, "prelude after the opening vars")
	lines.clear()

	_report.begin("LoadSceneTail")
	for c in [["\tx", "\t", true], ["\t\tx", "\t", false], ["  x", "  ", true], ["    x", "  ", false]]:
		_report.check_eq(bool(ml._is_body_level(c[0], c[1])), c[2], "body level of '%s'" % c[0].c_escape())
	var head := "func _rtv_vanilla_LoadScene(scene):"
	var tail := "get_tree().change_scene_to_file(scenePath)"
	var nested := PackedStringArray([head, "\tif x:", "\t\t" + tail])
	_report.check_eq(ml._loadscene_reapply(nested, "\t"), nested, "nested tail left unchanged")
	_report.check(lines.size() == 1 and "lacks its tail" in str(lines[0]), "nested-only tail not critical")
	lines.clear()
	var awaited: PackedStringArray = ml._loadscene_reapply(
			PackedStringArray([head, "\tif x:", "\t\tawait foo", "\t" + tail]), "\t")
	_report.check(awaited[3].begins_with("\t# --- Metro mod loader"), "re-apply not after nested await")

func _vet(ml: Object, path: String, source: String, parsed: Dictionary) -> Dictionary:
	ml.set("_hook_pack_vetting", true)
	ml.set("_hook_pack_pre_restart", true)
	(ml.get("_hook_pack_demotions") as Dictionary).clear()
	return ml._hook_pack_vet_rewrite(path, source, parsed, {}, false)

func _check_vetting(ml: Object, fname: String, path: String, raw: String, parsed: Dictionary) -> void:
	_report.check_eq(str(_vet(ml, path, raw, parsed)["mode"]), "full", "VET: verdict on the real script")

	if GAME_RENAMES.has(fname):
		var member: String = GAME_RENAMES[fname]
		var renamed_src := RegEx.create_from_string("\\b" + member + "\\b").sub(raw, member + "Renamed", true)
		if not _report.check(renamed_src != raw, "VET: fixture lacks GAME_RENAMES member " + member):
			return
		var full_attempt: String = ml._rtv_rewrite_vanilla_source(renamed_src, ml._rtv_parse_script(fname, renamed_src), {})
		_report.check(not ml._rtv_probe_compiles(full_attempt, true), "VET: renaming %s breaks nothing" % member)
		var verdict: Dictionary = _vet(ml, path, renamed_src, ml._rtv_parse_script(fname, renamed_src))
		var source := str(verdict["source"])
		if _report.check_eq(str(verdict["mode"]), "wrap_only", "VET: verdict with %s renamed" % member) \
				and _report.check(ml._rtv_probe_compiles(source, true), "VET: wrap-only source does not compile"):
			_report.check(not ("Metro mod loader" in source.replace(WRAPPER_MARKER, "")),
					"VET: wrap-only source has registry code")
		_report.check_eq(str((ml.get("_hook_pack_demotions") as Dictionary).get(path, "")), "wrap_only",
				"VET: recorded demotion")
		_renames_vetted += 1

	# The scenes appendix reads the dict the declaration transform builds.
	if fname == "Database.gd":
		var no_consts := raw.replace("\nconst ", "\nvar ")
		var db: Dictionary = _vet(ml, path, no_consts, ml._rtv_parse_script(fname, no_consts))
		_report.check(str(db["mode"]) != "excluded" and ml._rtv_probe_compiles(str(db["source"]), true),
				"VET: const-less Database.gd not shipped hooked (%s)" % str(db["mode"]))
		_report.check(not ("_rtv_mod_scenes" in str(db["source"])), "VET: scenes appendix kept without its transform")

	if fname == "FixtureSub.gd":
		var bogus: Dictionary = parsed.duplicate(true)
		(bogus["functions"] as Array).append({"name": "NoSuchMethod", "params": "", "param_names": [],
				"line_number": 1, "is_static": false, "return_type": null,
				"is_coroutine": false, "has_return_value": false, "decl_prefix": ""})
		_report.check_eq(str(_vet(ml, path, raw, bogus)["mode"]), "excluded", "VET: verdict on an uncompilable rewrite")
		_seen["excluded verdict"] = true

	# A generation after a vetted one repeats the persisted verdicts unprobed.
	if fname == "AI.gd":
		ml.set("_hook_pack_vetting", false)
		ml.set("_hook_pack_demotions", {path: "wrap_only"})
		var repeated: Dictionary = ml._hook_pack_vet_rewrite(path, raw, parsed, {}, false)
		_report.check(str(repeated["mode"]) == "wrap_only" and not ("_rtv_apply_ai_loadouts" in str(repeated["source"])),
				"VET: persisted wrap-only verdict not repeated")
		ml.set("_hook_pack_demotions", {path: "excluded"})
		_report.check_eq(str(ml._hook_pack_vet_rewrite(path, raw, parsed, {}, false)["mode"]), "excluded",
				"VET: repeated excluded verdict")
	(ml.get("_hook_pack_demotions") as Dictionary).clear()

# Runs the injected registry code on an instance of the rewritten script (never
# in the tree, so @onready never runs) with the Engine meta the registry writes.
func _check_registry_runtime(fname: String, path: String, raw: String) -> void:
	if not (fname in ["AI.gd", "AISpawner.gd", "Database.gd", "Loader.gd"]):
		return
	var scr := ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_IGNORE) as Script
	if not _report.check(scr != null and scr.can_instantiate(), "RUNTIME: rewritten script cannot be instantiated"):
		return
	var obj: Object = scr.new()
	match fname:
		"AI.gd":
			_runtime_ai(obj, raw)
		"AISpawner.gd":
			var scene := PackedScene.new()
			var vanilla := PackedScene.new()
			Engine.set_meta("_rtv_ai_overrides", {"Area05": scene})
			_report.check(obj._rtv_resolve_ai_type(0, vanilla) == scene, "RUNTIME: Area05 override not resolved")
			_report.check(obj._rtv_resolve_ai_type(1, vanilla) == vanilla, "RUNTIME: BorderZone replaced without an override")
			Engine.set_meta("_rtv_ai_overrides", {})
			_report.check(obj._rtv_resolve_ai_type(0, vanilla) == vanilla, "RUNTIME: empty override table ignored")
		"Database.gd":
			var mod_scene := PackedScene.new()
			var over_scene := PackedScene.new()
			obj._rtv_mod_scenes["CodegenMod"] = mod_scene
			_report.check(obj.get("CodegenMod") == mod_scene, "RUNTIME: _get() did not serve a mod scene")
			obj._rtv_override_scenes["CodegenMod"] = over_scene
			_report.check(obj.get("CodegenMod") == over_scene, "RUNTIME: override did not beat a mod scene")
			var vanilla_keys: Array = obj._rtv_vanilla_scenes.keys()
			_report.check(not vanilla_keys.is_empty() and obj.get(vanilla_keys[0]) != null,
					"RUNTIME: _get() did not serve vanilla scenes")
			_report.check(obj.get("NoSuchScene") == null, "RUNTIME: _get() served an unknown name")
		"Loader.gd":
			_runtime_loader(obj, path)
	obj.free()

func _runtime_ai(ai: Object, raw: String) -> void:
	var build2 := "var variant: AIData" in raw
	if build2:
		var v: Object = load("res://Scripts/AIData.gd").new()
		v.faction = 4  # Faction.Boss
		v.name = "Punisher"
		ai.variant = v
		_report.check_eq(ai._rtv_ai_categories(), ["Boss", "Punisher"], "RUNTIME: Boss/Punisher categories")
		v.faction = 1  # Faction.Bandit
		v.name = "Bandit"
		_report.check_eq(ai._rtv_ai_categories(), ["Bandit"], "RUNTIME: Bandit categories")
		ai.variant = null
		_report.check((ai._rtv_ai_categories() as Array).is_empty(), "RUNTIME: no variant gave categories")
		ai.variant = v
		v.faction = 4
		v.name = "Punisher"
	else:
		ai.boss = true
		_report.check_eq(ai._rtv_ai_categories(), ["Punisher"], "RUNTIME: boss categories")
		ai.boss = false
		ai.AISpawner = null
		_report.check((ai._rtv_ai_categories() as Array).is_empty(), "RUNTIME: no spawner gave categories")
		ai.boss = true
	var weapon := PackedScene.new()
	var wn := Node3D.new()
	wn.name = "InjectedWeapon"
	weapon.pack(wn)
	wn.free()
	# Build 2 types `weapons` as BoneAttachment3D (a Node3D before it).
	var container := BoneAttachment3D.new()
	container.add_child(Node3D.new())
	ai.weapons = container
	Engine.set_meta("_rtv_ai_loadouts", [
		{"weapon_scene": weapon, "ai_types": ["Guard"], "chance": 1.0, "replace": false},
		{"weapon_scene": weapon, "ai_types": ["Punisher"], "chance": 1.0, "replace": false},
		"not a dictionary",
	])
	ai._rtv_apply_ai_loadouts()
	_report.check(container.get_child_count() == 2 and container.get_child(1).name == "InjectedWeapon"
			and not container.get_child(1).visible, "RUNTIME: loadout gave %d weapons children" % container.get_child_count())
	Engine.set_meta("_rtv_ai_loadouts", [
		{"weapon_scene": weapon, "ai_types": ["Boss"], "chance": 1.0, "replace": true},
	])
	ai._rtv_apply_ai_loadouts()
	_report.check(not build2 or (container.get_child_count() == 1 and container.get_child(0).name == "InjectedWeapon"),
			"RUNTIME: replace loadout left %d children" % container.get_child_count())
	Engine.set_meta("_rtv_ai_loadouts", [])
	container.free()

func _runtime_loader(ldr: Object, path: String) -> void:
	_report.check("Cabin" in ldr.shelters, "RUNTIME: shelters is %s" % str(ldr.shelters))
	var ok: bool = ldr.add_shelter({"map_name": "CodegenShelter", "path": "res://Scenes/Cabin.tscn", "exit_spawn": "X"})
	_report.check(ok and "CodegenShelter" in ldr.shelters and ldr._rtv_mod_scene_paths.has("CodegenShelter"),
			"RUNTIME: add_shelter did not register (ok=%s)" % str(ok))
	_report.check(not ldr.add_shelter({"map_name": "Cabin"}), "RUNTIME: add_shelter accepted a vanilla name")
	_report.check(not ldr.add_map({"path": "res://x.tscn"}), "RUNTIME: add_map accepted no map_name")
	_report.check(not ldr.add_map({"map_name": "Village", "path": "res://Scenes/Cabin.tscn"}),
			"RUNTIME: add_map would replace a vanilla map")
	# A Cabin loaded with shelter=false resets the character on quit.
	var flags_script := GDScript.new()
	flags_script.source_code = "extends RefCounted\nvar menu := false\nvar shelter := false\nvar permadeath := false\nvar tutorial := false\n"
	flags_script.reload()
	var data: Object = flags_script.new()
	data.shelter = true
	ldr._rtv_scene_entry_flags({"path": "res://Scenes/Cabin.tscn"}, "Cabin", data)
	_report.check(data.shelter, "RUNTIME: flagless Cabin override dropped shelter")
	ldr._rtv_scene_entry_flags({"path": "res://Scenes/Cabin.tscn", "shelter": false}, "Cabin", data)
	_report.check(not data.shelter, "RUNTIME: Cabin override shelter=false not applied")
	data.shelter = true
	data.tutorial = true
	ldr._rtv_scene_entry_flags({"path": "res://Scenes/Cabin.tscn"}, "CodegenPlace", data)
	_report.check(not (data.shelter or data.tutorial or data.menu or data.permadeath),
			"RUNTIME: mod scene kept vanilla flags")
	_report.check(ldr._rtv_is_vanilla_scene("Village") and not ldr._rtv_is_vanilla_scene("CodegenPlace"),
			"RUNTIME: _rtv_is_vanilla_scene misjudges names")
	# The vanilla if/elif reassigns scenePath for a vanilla name, so the entry is
	# applied again after the chain, or an override of "Cabin" is a no-op.
	var src := FileAccess.get_file_as_string(path)
	var start := src.find("func _rtv_vanilla_LoadScene(")
	var next := src.find("\nfunc ", start + 1)
	var body := src.substr(start, next - start if next > start else -1)
	var at_prelude := body.find("scene_paths registry prelude")
	var at_last_branch := body.rfind("elif scene ==")
	var at_reapply := body.find("scene_paths registry, after the vanilla chain")
	var at_change := body.rfind("change_scene_to_file(scenePath)")
	_report.check(start >= 0 and at_prelude >= 0 and at_prelude < at_last_branch and at_last_branch < at_reapply
			and at_reapply < at_change, "RUNTIME: LoadScene order %s" % str([at_prelude, at_last_branch, at_reapply, at_change]))
	# The prelude relabels only a mod scene: renaming "Cabin" loses its flag branch.
	var prelude := ""
	if at_prelude >= 0 and at_last_branch > at_prelude:
		prelude = body.substr(at_prelude, at_last_branch - at_prelude)
	_report.check(body.count("_rtv_scene_entry_flags(") >= 2 and prelude.count("_rtv_scene_entry_flags(") == 1,
			"RUNTIME: LoadScene sets flags not before and after")
	_report.check(prelude.contains("not _rtv_is_vanilla_scene(_rtv_scene_name)"),
			"RUNTIME: prelude relabels vanilla scene names")

func _check_fixture(ml: Object, fx: Dictionary) -> void:
	var fname: String = fx["file"]
	var path := "res://Scripts/" + fname
	_report.begin(fname)
	var fails_before := _report.failures.size()
	if not _report.check(FileAccess.file_exists(path), "fixture file missing at " + path):
		return
	var raw := FileAccess.get_file_as_string(path)
	var plines := raw.replace("\r\n", "\n").replace("\r", "\n").split("\n")
	var base := ResourceLoader.load(path) as Script
	if not _report.check(base != null and base.can_instantiate(),
			"BASELINE: pristine source fails (harness, not rewriter)"):
		return

	var parsed: Dictionary = ml._rtv_parse_script(fname, raw)
	var unwrapped: Array = UNWRAPPED.get(fname, [])
	var hookable: Array = (parsed["functions"] as Array).filter(
			func(fe): return not fe["is_static"] and not (str(fe["name"]) in unwrapped))
	if not _report.check(not hookable.is_empty(), "fixture has no hookable methods"):
		return
	var shapes: Dictionary = EXPECTED_SHAPES.get(fname, {})
	for mname in shapes:
		var found: Array = (parsed["functions"] as Array).filter(func(fe): return str(fe["name"]) == mname)
		if not _report.check(not found.is_empty(), "SHAPE: %s not parsed" % mname):
			continue
		_report.check_eq(bool(found[-1]["is_coroutine"]), shapes[mname][0], "SHAPE: %s is_coroutine" % mname)
		_report.check_eq(bool(found[-1]["has_return_value"]), shapes[mname][1], "SHAPE: %s has_return_value" % mname)

	# Masked first: the wrap-all output written last is what later fixtures see.
	if fx.has("mask"):
		_check_masked(ml, fname, path, raw, fx["mask"], plines, parsed, hookable)

	var rewritten: String = ml._rtv_rewrite_vanilla_source(raw, parsed, {})
	if not _report.check(rewritten != raw, "wrap-all rewrite changed nothing"):
		return
	var rlines := rewritten.split("\n")
	var marker_idx := rlines.find(WRAPPER_MARKER)
	if not _report.check(marker_idx >= 0, "wrapper marker missing from the rewrite"):
		return
	# A registry transform anchored to vanilla text no-ops silently when the game moves it.
	var markers: Dictionary = ml.get("REGISTRY_EXPECTED_MARKERS")
	if markers.has(fname):
		_report.check(str(markers[fname]) in rewritten, "REGISTRY: marker '%s' missing" % str(markers[fname]))

	for fe in hookable:
		_check_method(fname, fe, plines, rlines, marker_idx)
	_check_forms(fname, rlines, marker_idx)
	for un in unwrapped:
		_report.check(not (("_rtv_vanilla_" + str(un)) in rewritten), "%s (rest parameter) was wrapped" % str(un))
	for fe in parsed["functions"]:
		if fe["is_static"]:
			var sdecl := _decl_line(plines, fe)
			_report.check(sdecl == "" or rlines.find("func _rtv_vanilla_" + sdecl.trim_prefix("static func ")) < 0,
					"static func %s was wrapped" % fe["name"])

	# Before the rewrite overwrites the pristine file the probe has to judge.
	_check_vetting(ml, fname, path, raw, parsed)
	if not _compile_at_path(path, rewritten, "COMPILE (wrap-all)"):
		return
	_check_caller(fname, path, hookable, plines)
	_check_registry_runtime(fname, path, raw)
	if _report.failures.size() == fails_before:
		print("[codegen] OK %s: %d method(s) wrapped; output and caller stub compile" % [fname, hookable.size()])

func _check_forms(fname: String, rlines: PackedStringArray, marker_idx: int) -> void:
	var forms: Dictionary = WRAPPER_FORMS.get(fname, {})
	for mname in forms:
		var re := RegEx.create_from_string("^(.*)func " + mname + "\\(")
		var at := -1
		var prefix := ""
		for i in range(marker_idx, rlines.size()):
			var m := re.search(rlines[i])
			if m != null:
				at = i
				prefix = m.get_string(1)
				break
		if not _report.check(at >= 0, "FORM: %s has no wrapper" % mname):
			continue
		var body := "\n".join(_body_block(rlines, at))
		for want in forms[mname]:
			match want:
				"value":
					_report.check("return _rtv_result" in body, "FORM: %s wrapper drops the value" % mname)
				"void":
					_report.check(not ("return _rtv_result" in body), "FORM: %s wrapper returns a value" % mname)
				"await":
					_report.check(("await _rtv_vanilla_" + mname) in body, "FORM: %s wrapper not awaited" % mname)
				_:
					_report.check_eq(prefix, want, "FORM: %s declaration prefix" % mname)

# Overwrites the fixture and reloads it uncached at its res:// path, the load the game does.
func _compile_at_path(path: String, source: String, stage: String) -> bool:
	if not _report.check(H.write_text(path, source), stage + ": cannot overwrite the fixture"):
		return false
	var scr := ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_IGNORE) as Script
	return _report.check(scr != null and scr.can_instantiate(), stage + ": output does not compile (see SCRIPT ERROR)")

# The declaration the emitter must produce: prefix, name, params verbatim, " -> T".
func _wrapper_sig(fe: Dictionary) -> String:
	var rt: Variant = fe["return_type"]
	var annot := " -> " + str(rt) if rt != null and not str(rt).is_empty() else ""
	return "%sfunc %s(%s)%s:" % [str(fe.get("decl_prefix", "")), fe["name"], fe["params"], annot]

func _check_method(fname: String, fe: Dictionary, plines: PackedStringArray, rlines: PackedStringArray,
		marker_idx: int) -> void:
	var name: String = fe["name"]
	var decl := _decl_line(plines, fe)
	var at := decl.find(" func ")
	var prefix := decl.substr(0, at + 1) if decl.begins_with("@") and at >= 0 else ""
	if not _report.check(prefix != "" or decl.begins_with("func "), "%s: line_number misses its declaration" % name):
		return
	var renamed_decl := prefix + "func _rtv_vanilla_" + decl.substr(prefix.length() + 5)
	var renamed_idx := rlines.find(renamed_decl)
	if renamed_idx < 0 and "super" in decl:
		# A one-line body's bare super() becomes super.<name>() on the declaration line.
		var head_end := renamed_decl.find("):")
		if head_end > 0:
			var head := renamed_decl.substr(0, head_end + 2)
			for i in rlines.size():
				if rlines[i].begins_with(head) and ("super." + name + "(") in rlines[i]:
					renamed_idx = i
					break
	if prefix == "":
		# Function annotations on their own lines above ride on the wrapper's line.
		var parts := PackedStringArray()
		var i := int(fe["line_number"]) - 2
		while i >= 0:
			var t := plines[i].strip_edges()
			if not (t.is_empty() or t.begins_with("#")):
				if not t.begins_with("@"):
					break
				if t.begins_with("@rpc") or t.begins_with("@warning_ignore("):
					parts.insert(0, t)
			i -= 1
		if not parts.is_empty():
			prefix = " ".join(parts) + " "
	if not _report.check(renamed_idx >= 0, "%s: renamed vanilla body not found" % name):
		return
	# Params, not the whole line: the decompiled corpus writes "-> void :", which the emitter normalizes.
	if not _report.check(("(" + str(fe["params"]) + ")") in decl,
			"%s: params '%s' not in its declaration" % [name, fe["params"]]):
		return
	var sig := _wrapper_sig(fe)
	if prefix != "" and not sig.begins_with(prefix):
		sig = prefix + sig
	var wrap_idx := rlines.find(sig, marker_idx)
	if not _report.check(wrap_idx >= 0, "%s: no wrapper '%s'" % [name, sig]):
		return
	var pbody := _body_block(plines, int(fe["line_number"]) - 1)
	var pbody_text := "\n".join(pbody)
	var wbody_text := "\n".join(_body_block(rlines, wrap_idx))
	var coro := _pristine_awaits(decl, pbody)
	if coro:
		_report.check("await " in wbody_text, "%s: coroutine wrapper has no await" % name)
	else:
		_report.check(RegEx.create_from_string("\\bawait\\b").search(wbody_text) == null,
				"%s: non-coroutine wrapper awaits; its callers break" % name)
	if not (name in BODY_MODIFIED.get(fname, []) or "super" in pbody_text):
		_report.check("\n".join(_body_block(rlines, renamed_idx)) == pbody_text,
				"%s: renamed body differs from vanilla" % name)
	_seen["coroutine" if coro else ("sync value" if fe["has_return_value"] else "void")] = true
	if "=" in str(fe["params"]):
		_seen["defaults"] = true
	if fname == "Loader.gd" and name == "ValidateShelter":
		if _report.check(not coro and fe["has_return_value"], "ValidateShelter no longer parses sync value-returning"):
			_seen["ValidateShelter"] = true

func _check_masked(ml: Object, fname: String, path: String, raw: String, mask_names: Array,
		plines: PackedStringArray, parsed: Dictionary, hookable: Array) -> void:
	var mask := {}
	for m in mask_names:
		mask[str(m).to_lower()] = true
	var masked: String = ml._rtv_rewrite_vanilla_source(raw, parsed, mask)
	if not _report.check(masked != raw, "MASKED: mask %s matched nothing" % str(mask_names)):
		return
	var mlines := masked.split("\n")
	var mmarker := mlines.find(WRAPPER_MARKER)
	if not _report.check(mmarker >= 0, "MASKED: wrapper marker missing"):
		return
	for fe in hookable:
		var name: String = fe["name"]
		var decl := _decl_line(plines, fe)
		if decl == "":
			continue
		var renamed := mlines.find("func _rtv_vanilla_" + decl.substr(5))
		if mask.has(name.to_lower()):
			_report.check(renamed >= 0, "MASKED: %s masked but not renamed" % name)
			_report.check(mlines.find(_wrapper_sig(fe), mmarker) >= 0, "MASKED: %s masked but has no wrapper" % name)
		else:
			_report.check(renamed < 0, "MASKED: %s unmasked but renamed" % name)
			var d := mlines.find(decl)
			_report.check(d >= 0 and d <= mmarker, "MASKED: %s unmasked but its declaration is gone" % name)
	_compile_at_path(path, masked, "COMPILE (masked)")

# Calls every wrapped method the way game code and mods do: no await unless the
# vanilla body awaits. Only a call site shows that a wrapper became a coroutine.
func _check_caller(fname: String, path: String, hookable: Array, plines: PackedStringArray) -> void:
	var lines := PackedStringArray([
		"# Compile-only caller stub for the rewritten " + fname,
		"const TargetScript = preload(\"" + path + "\")",
		"",
		"func _rtv_codegen_probe(t: TargetScript) -> void:",
	])
	var n := 0
	for fe in hookable:
		var args: Variant = _call_args(str(fe["params"]))
		if args == null:
			print("[codegen] note: %s::%s left out of the caller stub (type not reachable)" % [fname, fe["name"]])
			continue
		n += 1
		var call := "t.%s(%s)" % [fe["name"], args]
		var rt: Variant = fe["return_type"]
		var has_value: bool = fe["has_return_value"] and (rt == null or str(rt) != "void")
		if _pristine_awaits(_decl_line(plines, fe), _body_block(plines, int(fe["line_number"]) - 1)):
			lines.append("\tvar r%d = await %s" % [n, call] if has_value else "\tawait " + call)
		elif has_value and rt != null and _type_resolvable(str(rt)):
			lines.append("\tvar r%d: %s = %s" % [n, str(rt), call])
		elif has_value:
			lines.append("\tvar r%d = %s" % [n, call])
		else:
			lines.append("\t" + call)
	if n == 0:
		lines.append("\tpass")
	var caller_path := "res://callers/Caller_" + fname
	if not _report.check(H.write_text(caller_path, "\n".join(lines) + "\n"), "CALLER: cannot write " + caller_path):
		return
	var scr := ResourceLoader.load(caller_path, "", ResourceLoader.CACHE_MODE_IGNORE) as Script
	_report.check(scr != null and scr.can_instantiate(), "CALLER: unawaited calls do not compile (%s)" % caller_path)

# Placeholder arguments for the required parameters, or null when a type is not
# reachable from the stub. Splits params itself rather than trust the loader's splitter.
func _call_args(params: String) -> Variant:
	var parts := []
	var depth := 0
	var quote := ""
	var escaped := false
	var start := 0
	for i in params.length():
		var c := params[i]
		if quote != "":
			if escaped:
				escaped = false
			elif c == "\\":
				escaped = true
			elif c == quote:
				quote = ""
		elif c == "\"" or c == "'":
			quote = c
		elif c in "([{":
			depth += 1
		elif c in ")]}":
			depth -= 1
		elif c == "," and depth == 0:
			parts.append(params.substr(start, i - start))
			start = i + 1
	parts.append(params.substr(start))
	var args := PackedStringArray()
	for part in parts:
		var p := str(part).strip_edges()
		if p.is_empty():
			continue
		if "=" in p:
			break
		var colon := p.find(":")
		var t := p.substr(colon + 1).strip_edges() if colon >= 0 else ""
		if t.begins_with("Array"):
			args.append("[]")
		elif PLACEHOLDERS.has(t):
			args.append(PLACEHOLDERS[t])
		elif t in BUILTIN_TYPES:
			args.append(t + "()")
		elif ClassDB.class_exists(t) or _global_classes.has(t):
			args.append("null")
		else:
			return null
	return ", ".join(args)

func _type_resolvable(t: String) -> bool:
	if t.begins_with("Array["):
		return _type_resolvable(t.trim_prefix("Array[").trim_suffix("]"))
	return t in BUILTIN_TYPES or ClassDB.class_exists(t) or _global_classes.has(t)

# Ground truth for "is this vanilla method a coroutine", independent of the
# loader's parser: an await in its body or one-line body, outside lambdas.
func _pristine_awaits(decl: String, body: PackedStringArray) -> bool:
	var re := RegEx.create_from_string("\\bawait\\b")
	var lines := PackedStringArray()
	var colon := decl.rfind(":")
	if colon >= 0 and colon + 1 < decl.length():
		lines.append("\t" + decl.substr(colon + 1))
	lines.append_array(body)
	var lambda_indent := -1
	for ln in lines:
		var stripped := ln.strip_edges()
		if stripped.is_empty() or stripped.begins_with("#"):
			continue
		var ind := ln.length() - ln.lstrip(" \t").length()
		if lambda_indent >= 0 and ind > lambda_indent:
			continue
		lambda_indent = -1
		var code := ln
		var lf := _find_lambda(code, 0)
		while lf >= 0:
			# A lambda whose line ends at its colon owns the more-indented lines below.
			var depth := 0
			for i in range(code.find("(", lf), code.length()):
				depth += int(code[i] == "(") - int(code[i] == ")")
				if depth == 0:
					var tail := code.substr(i + 1).strip_edges()
					var typed := tail.begins_with("->")
					tail = tail.trim_prefix("->").strip_edges()
					if (tail.length() > 1 and tail.find(":") == tail.length() - 1) if typed else tail == ":":
						lambda_indent = ind
					break
			# The lambda runs to the comma or bracket that closes it; text after is the method's.
			depth = 0
			var quote := ""
			var end := lf
			while end < code.length():
				var c := code[end]
				if quote != "":
					if c == "\\":
						end += 1
					elif c == quote:
						quote = ""
				elif c == "\"" or c == "'":
					quote = c
				elif c == "#":
					end = code.length()
					break
				elif c in "([{":
					depth += 1
				elif c in ")]}":
					depth -= 1
					if depth < 0:
						break
				elif c == "," and depth == 0:
					break
				end += 1
			code = code.substr(0, lf) + code.substr(end)
			lf = _find_lambda(code, lf)
		if re.search(code) != null:
			return true
	return false

func _find_lambda(code: String, from: int) -> int:
	var a := code.find("func(", from)
	var b := code.find("func (", from)
	return b if a < 0 or (b >= 0 and b < a) else a

func _decl_line(plines: PackedStringArray, fe: Dictionary) -> String:
	var ln := int(fe["line_number"]) - 1
	return plines[ln] if ln >= 0 and ln < plines.size() else ""

# The indented block under a declaration, trailing blank lines dropped.
func _body_block(lines: PackedStringArray, decl_idx: int) -> PackedStringArray:
	var out := PackedStringArray()
	for i in range(decl_idx + 1, lines.size()):
		if not lines[i].is_empty() and lines[i][0] != "\t" and lines[i][0] != " ":
			break
		out.append(lines[i])
	while not out.is_empty() and out[-1].strip_edges().is_empty():
		out.remove_at(out.size() - 1)
	return out
