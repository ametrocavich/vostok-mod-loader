## runner.gd -- codegen compile-check harness. NOT part of the shipped
## loader. Executed by check_codegen.sh inside a THROWAWAY Godot project
## assembled under the system temp dir; never run it against this repo or
## against the Road to Vostok install.
##
## What it does, per fixture (a real vanilla script copied from the
## decompiled game source, or a synthetic Fixture*.gd from this directory):
##   1. BASELINE: the pristine source must compile in the harness project.
##      If it doesn't, the harness environment is broken (missing stub /
##      class) -- that is a fixture problem, never a rewriter problem.
##   2. REWRITE: run the real _rtv_parse_script + _rtv_rewrite_vanilla_source
##      from the built modloader (static-init neutralized by check_codegen.sh)
##      with an empty mask (wrap every non-static method), and where the
##      fixture declares one, ALSO with a per-method mask (the partial-rename
##      path v3.0.1 modlists actually take).
##   3. OUTPUT PROPERTIES (asserted on the text, independent of compilation):
##      - the vanilla body survives verbatim under func _rtv_vanilla_<name>
##      - the appended wrapper reproduces the original declaration line
##        byte-for-byte (params, defaults, return annotation)
##      - a wrapper for a NON-coroutine vanilla method contains no `await`
##        (the 3.3.0 bug class: any `await` marks the wrapper a coroutine
##        and breaks every caller at parse time), and a wrapper for a real
##        coroutine keeps its `await`
##      - static funcs and inner-class methods are never renamed or wrapped
##      - masked rewrites rename exactly the masked set and nothing else
##   4. COMPILE: the rewritten source replaces the fixture on disk and is
##      recompiled at its canonical res://Scripts/ path with the real
##      GDScript compiler (CACHE_MODE_IGNORE, same load the game performs).
##   5. CALLER: a generated stub that CALLS every wrapped method without
##      `await` (assigning value returns to typed locals) is compiled. A
##      wrapper that silently became a coroutine parses fine in isolation
##      and only fails at its call sites ("Function X() is a coroutine, so
##      it must be called with await") -- this step is what would have
##      caught 3.3.0 at build time.
##
## ADDING A FIXTURE: see the header of check_codegen.sh.
extends SceneTree

## Fixture table. "file" is a res://Scripts/ basename. Optional keys:
##   baseline=false  pristine source is INTENTIONALLY invalid: skip the
##                   pristine compile and the body-verbatim check.
##   mask=[...]      also run the rewrite with this per-method mask and
##                   assert only the masked methods were renamed + wrapped.
const FIXTURES: Array[Dictionary] = [
	# Synthetic fixtures (from tests/codegen/, copied in by check_codegen.sh).
	{"file": "FixtureDefaults.gd", "mask": ["DefaultsTricky", "CoroutineValue"]},
	{"file": "FixtureSub.gd"},                     # extends-by-path + bare super()
	# Real vanilla scripts (copied from the decompiled game source).
	{"file": "Loader.gd", "mask": ["ValidateShelter", "LoadScene", "FadeIn"]},
	{"file": "Database.gd"},     # const->dict declaration transform + _get() appendix
	{"file": "AISpawner.gd"},    # agent-assignment rewrite + Zone resolver appendix
	{"file": "AI.gd"},           # SelectWeapon prelude + loadouts appendix
	{"file": "FishPool.gd"},     # _ready prelude
	{"file": "Compiler.gd"},     # Spawn prelude (after_var_decls insertion)
	{"file": "Camera.gd"},       # class_name script
	{"file": "Character.gd"},    # large gameplay script, several coroutines
	{"file": "Menu.gd", "mask": ["_ready"]},  # matches _seed_core_hooks reality
	{"file": "Bed.gd"},          # small await-heavy interactable
]

## Methods whose body the rewriter legitimately modifies (prelude injection /
## declaration transforms) -- excluded from the byte-verbatim body check ONLY.
## The wrapper + coroutine assertions still apply to them. Bodies containing
## bare super() are skipped automatically (the super rewrite is intentional).
const BODY_MODIFIED := {
	"Loader.gd": ["LoadScene"],
	"Compiler.gd": ["Spawn"],
	"FishPool.gd": ["_ready"],
	"AI.gd": ["SelectWeapon"],
	"AISpawner.gd": ["_ready", "Initialize"],  # zone if/elif moved to Initialize in Build 2
}

const WRAPPER_MARKER := "# --- Metro mod loader inline hook dispatch wrappers ---"

const BUILTIN_TYPES := ["int", "float", "bool", "String", "StringName", "NodePath",
	"Vector2", "Vector2i", "Vector3", "Vector3i", "Vector4", "Vector4i", "Color",
	"Rect2", "Rect2i", "Basis", "Quaternion", "Transform2D", "Transform3D", "AABB",
	"Plane", "Dictionary", "Array", "Callable", "Signal", "RID", "Variant",
	"PackedByteArray", "PackedStringArray", "PackedInt32Array", "PackedInt64Array",
	"PackedFloat32Array", "PackedFloat64Array", "PackedVector2Array",
	"PackedVector3Array", "PackedColorArray"]

var _failures: PackedStringArray = []
var _done := false
var _global_classes: Dictionary = {}
# Coverage booleans -- the fixture set must keep exercising every shape.
var _saw_sync_value := false
var _saw_void := false
var _saw_coroutine := false
var _saw_defaults := false
var _saw_validateshelter := false
var _vetted_full := 0
var _vetted_renames := 0
var _vetted_excluded := 0
var _fixtures_run := 0

func _process(_delta: float) -> bool:
	if _done:
		return true
	_done = true
	_run()
	return true

func _run() -> void:
	var t0 := Time.get_ticks_msec()
	print("[codegen] harness start")
	for gc in ProjectSettings.get_global_class_list():
		_global_classes[String(gc["class"])] = true
	var ml_script: GDScript = load("res://modloader_neutered.gd")
	if ml_script == null:
		_fail("harness", "could not load res://modloader_neutered.gd -- check_codegen.sh prep failed")
		_finish(t0)
		return
	var ml = ml_script.new()
	# Belt and braces: check_codegen.sh replaced the _mount_previous_session()
	# initializer with {}. If boot code ran anyway, refuse to continue.
	var mounted = ml.get("_filescope_mounted")
	if not (mounted is Dictionary) or not (mounted as Dictionary).is_empty():
		_fail("harness", "_filescope_mounted is not an empty Dictionary -- static-init boot code RAN; the neutering failed")
		ml.free()
		_finish(t0)
		return
	# check_codegen.sh leaves this marker when the decompiled game source is
	# absent; the synthetic fixtures need nothing but the engine.
	var synthetic_only := FileAccess.file_exists("res://synthetic_only")
	for fx in FIXTURES:
		if synthetic_only and not str(fx["file"]).begins_with("Fixture"):
			continue
		_check_fixture(ml, fx)
		_fixtures_run += 1
	ml.free()
	if not _saw_sync_value:
		_fail("coverage", "no fixture exercised a synchronous value-returning method")
	if not _saw_void:
		_fail("coverage", "no fixture exercised a void method")
	if not _saw_coroutine:
		_fail("coverage", "no fixture exercised a coroutine method")
	if not _saw_defaults:
		_fail("coverage", "no fixture exercised default parameter values")
	if _vetted_excluded == 0:
		_fail("coverage", "no fixture exercised the probe's excluded verdict")
	if not synthetic_only and _vetted_renames < GAME_RENAMES.size():
		_fail("coverage", "only %d of %d renamed-member cases ran" % [_vetted_renames, GAME_RENAMES.size()])
	if not synthetic_only and not _saw_validateshelter:
		_fail("coverage", "Loader.gd::ValidateShelter (the known-good 3.3.0 fixture) was not checked")
	_finish(t0)

func _finish(t0: int) -> void:
	var ms := Time.get_ticks_msec() - t0
	if _failures.is_empty():
		print("[codegen] PASS: %d fixture(s), all rewritten outputs + caller stubs compile (%d ms in-engine)" % [_fixtures_run, ms])
		quit(0)
	else:
		printerr("[codegen] FAILED: %d problem(s) (%d ms in-engine); first: %s" % [_failures.size(), ms, _failures[0]])
		quit(1)

func _fail(where: String, msg: String) -> void:
	_failures.append(where + ": " + msg)
	printerr("[codegen] FAIL " + where + ": " + msg)

# --- the pre-ship compile probe ------------------------------------------------

## A vanilla member each registry target's injected code names. Renaming it in
## the fixture's text is what a game update that renames it looks like.
const GAME_RENAMES := {
	"AI.gd": "weapons",
	"AISpawner.gd": "Zone",
	"Loader.gd": "shelters",
	"FishPool.gd": "species",
	"Compiler.gd": "spawnTarget",
}

func _vet(ml, path: String, source: String, parsed: Dictionary) -> Dictionary:
	ml.set("_hook_pack_vetting", true)
	ml.set("_hook_pack_pre_restart", true)
	(ml.get("_hook_pack_demotions") as Dictionary).clear()
	return ml._hook_pack_vet_rewrite(path, source, parsed, {}, false)

func _check_vetting(ml, fname: String, path: String, raw: String, parsed: Dictionary) -> void:
	# 1. No false positive: the rewrite of the real script ships in full. A
	# probe that rejected a good rewrite would switch hooks off for everyone.
	var good: Dictionary = _vet(ml, path, raw, parsed)
	if str(good["mode"]) != "full":
		_fail(fname, "VET: the probe demoted a good rewrite to '%s' -- it would disable hooks on a healthy game" % str(good["mode"]))
	_vetted_full += 1

	# 2. The game renamed a member the registry code names: hooks stay, the
	# registry code goes, and what ships compiles.
	if GAME_RENAMES.has(fname):
		var member: String = GAME_RENAMES[fname]
		var re := RegEx.new()
		re.compile("\\b" + member + "\\b")
		var renamed_src := re.sub(raw, member + "Renamed", true)
		if renamed_src == raw:
			_fail(fname, "VET: fixture no longer contains '%s' -- pick another member for GAME_RENAMES" % member)
			return
		var full_attempt: String = ml._rtv_rewrite_vanilla_source(renamed_src, ml._rtv_parse_script(fname, renamed_src), {})
		if ml._rtv_probe_compiles(full_attempt, true):
			_fail(fname, "VET: the full rewrite still compiles with '%s' renamed -- this case proves nothing, pick a member the injected code names" % member)
		var verdict: Dictionary = _vet(ml, path, renamed_src, ml._rtv_parse_script(fname, renamed_src))
		if str(verdict["mode"]) != "wrap_only":
			_fail(fname, "VET: with '%s' renamed the script must ship wrap-only, got '%s'" % [member, str(verdict["mode"])])
		elif not ml._rtv_probe_compiles(str(verdict["source"]), true):
			_fail(fname, "VET: the wrap-only source does not compile")
		elif "Metro mod loader" in str(verdict["source"]).replace("# --- Metro mod loader inline hook dispatch wrappers ---", ""):
			_fail(fname, "VET: the wrap-only source still carries registry code")
		if str((ml.get("_hook_pack_demotions") as Dictionary).get(path, "")) != "wrap_only":
			_fail(fname, "VET: the demotion was not recorded for the generations that follow")
		_vetted_renames += 1

	# 3. Database's declaration transform found nothing: the appendix that
	# reads its dict must go with it, or Database.gd would not compile.
	if fname == "Database.gd":
		var no_consts := raw.replace("\nconst ", "\nvar ")
		var db_verdict: Dictionary = _vet(ml, path, no_consts, ml._rtv_parse_script(fname, no_consts))
		if str(db_verdict["mode"]) == "excluded" or not ml._rtv_probe_compiles(str(db_verdict["source"]), true):
			_fail(fname, "VET: a Database.gd with no const preloads must still ship a compiling, hooked script (got '%s')" % str(db_verdict["mode"]))
		if "_rtv_mod_scenes" in str(db_verdict["source"]):
			_fail(fname, "VET: the scenes appendix was kept although the transform it depends on found nothing")

	# 4. A rewrite that cannot compile in any form leaves the script vanilla.
	if fname == "FixtureSub.gd":
		var bogus: Dictionary = parsed.duplicate(true)
		(bogus["functions"] as Array).append({"name": "NoSuchMethod", "params": "", "param_names": [],
				"line_number": 1, "is_static": false, "return_type": null,
				"is_coroutine": false, "has_return_value": false})
		var lost: Dictionary = _vet(ml, path, raw, bogus)
		if str(lost["mode"]) != "excluded":
			_fail(fname, "VET: a rewrite that compiles in no form must be excluded, got '%s'" % str(lost["mode"]))
		_vetted_excluded += 1

	# 5. A generation that follows a vetted one repeats its verdicts unprobed.
	if fname == "AI.gd":
		ml.set("_hook_pack_vetting", false)
		ml.set("_hook_pack_demotions", {path: "wrap_only"})
		var repeated: Dictionary = ml._hook_pack_vet_rewrite(path, raw, parsed, {}, false)
		if str(repeated["mode"]) != "wrap_only" or "_rtv_apply_ai_loadouts" in str(repeated["source"]):
			_fail(fname, "VET: a persisted wrap-only verdict was not repeated")
		ml.set("_hook_pack_demotions", {path: "excluded"})
		if str(ml._hook_pack_vet_rewrite(path, raw, parsed, {}, false)["mode"]) != "excluded":
			_fail(fname, "VET: a persisted excluded verdict was not repeated")
	(ml.get("_hook_pack_demotions") as Dictionary).clear()

# --- injected registry code, executed ------------------------------------------

# The compile steps prove the appendices parse; these run them. Each target's
# injected helpers are called on an instance of the rewritten script (never
# added to the tree, so @onready never runs) with the same Engine meta the
# registry writes, and the vanilla-facing result is asserted.
func _check_registry_runtime(fname: String, path: String, raw: String) -> void:
	match fname:
		"AI.gd":
			_runtime_ai(fname, path, raw)
		"AISpawner.gd":
			_runtime_aispawner(fname, path)
		"Database.gd":
			_runtime_database(fname, path)
		"Loader.gd":
			_runtime_loader(fname, path)

func _runtime_instance(fname: String, path: String) -> Object:
	var scr = ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_IGNORE)
	if scr == null or not (scr as Script).can_instantiate():
		_fail(fname, "RUNTIME: rewritten script cannot be instantiated")
		return null
	return (scr as Script).new()

func _runtime_ai(fname: String, path: String, raw: String) -> void:
	var ai = _runtime_instance(fname, path)
	if ai == null:
		return
	var build2 := "var variant: AIData" in raw
	if build2:
		# Build 2: categories come from the AIData variant.
		var data_script = load("res://Scripts/AIData.gd")
		var v = data_script.new()
		v.faction = 4  # Faction.Boss
		v.name = "Punisher"
		ai.variant = v
		var cats: Array = ai._rtv_ai_categories()
		if cats != ["Boss", "Punisher"]:
			_fail(fname, "RUNTIME: Boss/Punisher variant gave categories %s" % str(cats))
		v.faction = 1  # Faction.Bandit
		v.name = "Bandit"
		if ai._rtv_ai_categories() != ["Bandit"]:
			_fail(fname, "RUNTIME: Bandit variant gave categories %s" % str(ai._rtv_ai_categories()))
		ai.variant = null
		if not (ai._rtv_ai_categories() as Array).is_empty():
			_fail(fname, "RUNTIME: no variant must give no categories")
		ai.variant = v
		v.faction = 4
		v.name = "Punisher"
	else:
		# Pre-Build 2: the boss flag and the spawner zone.
		ai.boss = true
		if ai._rtv_ai_categories() != ["Punisher"]:
			_fail(fname, "RUNTIME: boss gave categories %s" % str(ai._rtv_ai_categories()))
		ai.boss = false
		ai.AISpawner = null
		if not (ai._rtv_ai_categories() as Array).is_empty():
			_fail(fname, "RUNTIME: no spawner must give no categories")
		ai.boss = true
	# A loadout for the matching category lands in weapons, hidden; a
	# non-matching one is skipped; replace clears the vanilla children.
	var weapon := PackedScene.new()
	var wn := Node3D.new()
	wn.name = "InjectedWeapon"
	weapon.pack(wn)
	wn.free()
	# Build 2 types `weapons` as BoneAttachment3D (a Node3D before it).
	var container := BoneAttachment3D.new()
	var vanilla_weapon := Node3D.new()
	container.add_child(vanilla_weapon)
	ai.weapons = container
	Engine.set_meta("_rtv_ai_loadouts", [
		{"weapon_scene": weapon, "ai_types": ["Guard"], "chance": 1.0, "replace": false},
		{"weapon_scene": weapon, "ai_types": ["Punisher"], "chance": 1.0, "replace": false},
		"not a dictionary",
	])
	ai._rtv_apply_ai_loadouts()
	if container.get_child_count() != 2 or container.get_child(1).name != "InjectedWeapon" or container.get_child(1).visible:
		_fail(fname, "RUNTIME: loadout injection gave %d weapons children (expected vanilla + one hidden InjectedWeapon)" % container.get_child_count())
	Engine.set_meta("_rtv_ai_loadouts", [
		{"weapon_scene": weapon, "ai_types": ["Boss"], "chance": 1.0, "replace": true},
	])
	ai._rtv_apply_ai_loadouts()
	if build2 and (container.get_child_count() != 1 or container.get_child(0).name != "InjectedWeapon"):
		_fail(fname, "RUNTIME: replace loadout left %d weapons children" % container.get_child_count())
	Engine.set_meta("_rtv_ai_loadouts", [])
	container.free()
	ai.free()

func _runtime_aispawner(fname: String, path: String) -> void:
	var sp = _runtime_instance(fname, path)
	if sp == null:
		return
	var scene := PackedScene.new()
	Engine.set_meta("_rtv_ai_overrides", {"Area05": scene})
	var vanilla := PackedScene.new()
	if sp._rtv_resolve_ai_type(0, vanilla) != scene:
		_fail(fname, "RUNTIME: resolver did not return the Area05 override")
	if sp._rtv_resolve_ai_type(1, vanilla) != vanilla:
		_fail(fname, "RUNTIME: resolver replaced BorderZone without an override")
	Engine.set_meta("_rtv_ai_overrides", {})
	if sp._rtv_resolve_ai_type(0, vanilla) != vanilla:
		_fail(fname, "RUNTIME: resolver ignored an empty override table")
	sp.free()

func _runtime_database(fname: String, path: String) -> void:
	var db = _runtime_instance(fname, path)
	if db == null:
		return
	var mod_scene := PackedScene.new()
	var over_scene := PackedScene.new()
	db._rtv_mod_scenes["CodegenMod"] = mod_scene
	if db.get("CodegenMod") != mod_scene:
		_fail(fname, "RUNTIME: _get() did not serve a mod scene")
	db._rtv_override_scenes["CodegenMod"] = over_scene
	if db.get("CodegenMod") != over_scene:
		_fail(fname, "RUNTIME: an override did not win over a mod scene")
	var vanilla_keys: Array = db._rtv_vanilla_scenes.keys()
	if vanilla_keys.is_empty() or db.get(vanilla_keys[0]) == null:
		_fail(fname, "RUNTIME: _get() did not serve the vanilla scene dict")
	if db.get("NoSuchScene") != null:
		_fail(fname, "RUNTIME: _get() returned something for an unknown name")
	db.free()

func _runtime_loader(fname: String, path: String) -> void:
	var ldr = _runtime_instance(fname, path)
	if ldr == null:
		return
	if not ("Cabin" in ldr.shelters):
		_fail(fname, "RUNTIME: shelters is not the vanilla list (%s)" % str(ldr.shelters))
	var ok: bool = ldr.add_shelter({"map_name": "CodegenShelter", "path": "res://Scenes/Cabin.tscn", "exit_spawn": "X"})
	if not ok or not ("CodegenShelter" in ldr.shelters) or not ldr._rtv_mod_scene_paths.has("CodegenShelter"):
		_fail(fname, "RUNTIME: add_shelter did not register (ok=%s)" % str(ok))
	if ldr.add_shelter({"map_name": "Cabin"}):
		_fail(fname, "RUNTIME: add_shelter accepted a vanilla shelter name")
	if ldr.add_map({"path": "res://x.tscn"}):
		_fail(fname, "RUNTIME: add_map accepted a dict without map_name")
	if ldr.add_map({"map_name": "Village", "path": "res://Scenes/Cabin.tscn"}):
		_fail(fname, "RUNTIME: add_map with a path accepted a vanilla scene name, which would replace that map")
	# The flags applied after the vanilla chain. A Cabin override that names
	# no flags must keep the shelter flag the Cabin branch set: a Cabin
	# loaded with shelter=false resets the character on quit.
	var flags_script := GDScript.new()
	flags_script.source_code = "extends RefCounted\nvar menu := false\nvar shelter := false\nvar permadeath := false\nvar tutorial := false\n"
	flags_script.reload()
	var data = flags_script.new()
	data.shelter = true
	ldr._rtv_scene_entry_flags({"path": "res://Scenes/Cabin.tscn"}, "Cabin", data)
	if not data.shelter:
		_fail(fname, "RUNTIME: an override of Cabin that names no flags dropped the shelter flag the vanilla branch set")
	ldr._rtv_scene_entry_flags({"path": "res://Scenes/Cabin.tscn", "shelter": false}, "Cabin", data)
	if data.shelter:
		_fail(fname, "RUNTIME: an override of Cabin that sets shelter=false did not apply it")
	data.shelter = true
	data.tutorial = true
	ldr._rtv_scene_entry_flags({"path": "res://Scenes/Cabin.tscn"}, "CodegenPlace", data)
	if data.shelter or data.tutorial or data.menu or data.permadeath:
		_fail(fname, "RUNTIME: a mod scene kept flags the vanilla chain set for its relabelled name")
	if not ldr._rtv_is_vanilla_scene("Village") or ldr._rtv_is_vanilla_scene("CodegenPlace"):
		_fail(fname, "RUNTIME: _rtv_is_vanilla_scene does not tell vanilla scene names from mod ones")
	ldr.free()
	# The vanilla if/elif reassigns scenePath (and most of the flags) for a
	# vanilla scene name, so the entry has to be applied again after the
	# chain and before the tail's scene change, or an override of "Cabin"
	# is a no-op.
	var src := FileAccess.get_file_as_string(path)
	var start := src.find("func _rtv_vanilla_LoadScene(")
	var next := src.find("\nfunc ", start + 1)
	var body := src.substr(start, next - start if next > start else -1)
	var at_prelude := body.find("scene_paths registry prelude")
	var at_last_branch := body.rfind("elif scene ==")
	var at_reapply := body.find("scene_paths registry, after the vanilla chain")
	var at_change := body.rfind("change_scene_to_file(scenePath)")
	if start < 0 or not (at_prelude >= 0 and at_prelude < at_last_branch and at_last_branch < at_reapply and at_reapply < at_change):
		_fail(fname, "RUNTIME: LoadScene does not apply the scene_paths entry again between the vanilla chain and the scene change (prelude %d, last branch %d, re-apply %d, change %d)"
				% [at_prelude, at_last_branch, at_reapply, at_change])
	# Both applications set the flags through _rtv_scene_entry_flags, which
	# keeps a vanilla scene's own flags, and the prelude relabels only a mod
	# scene: an override's transition_text must not rename "Cabin", or the
	# chain loses the branch that sets its flags.
	var prelude := body.substr(at_prelude, at_last_branch - at_prelude) if at_prelude >= 0 and at_last_branch > at_prelude else ""
	if body.count("_rtv_scene_entry_flags(") < 2 or prelude.count("_rtv_scene_entry_flags(") != 1:
		_fail(fname, "RUNTIME: LoadScene does not set the scene_paths flags through _rtv_scene_entry_flags both before and after the vanilla chain")
	if not prelude.contains("not _rtv_is_vanilla_scene(_rtv_scene_name)"):
		_fail(fname, "RUNTIME: the LoadScene prelude relabels a scene without checking it is not a vanilla scene name")

# --- fixture pipeline -------------------------------------------------------

func _check_fixture(ml, fx: Dictionary) -> void:
	var fname: String = fx["file"]
	var path := "res://Scripts/" + fname
	var want_baseline: bool = fx.get("baseline", true)
	var fails_before := _failures.size()
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		_fail(fname, "fixture file missing at " + path)
		return
	var raw := f.get_as_text()
	f.close()
	var pristine := raw.replace("\r\n", "\n").replace("\r", "\n")
	var plines: PackedStringArray = pristine.split("\n")

	if want_baseline:
		var base = ResourceLoader.load(path)
		if base == null or not (base as Script).can_instantiate():
			_fail(fname, "BASELINE: the PRISTINE vanilla source does not compile in the harness project. Fix the harness environment (missing preload stub / class cache entry / autoload) or pick another fixture -- this is NOT a rewriter bug.")
			return

	var parsed: Dictionary = ml._rtv_parse_script(fname, raw)
	var nonstatic: Array = []
	for fe in parsed["functions"]:
		if not fe["is_static"]:
			nonstatic.append(fe)
	if nonstatic.is_empty():
		_fail(fname, "fixture has no hookable (non-static) methods -- replace it with a script that has some")
		return

	# Masked rewrite first (wrap-all output is written to disk LAST so later
	# fixtures that depend on this script see the wrap-all version).
	if fx.has("mask"):
		_check_masked(ml, fx, fname, path, raw, plines, parsed, nonstatic)

	var rewritten: String = ml._rtv_rewrite_vanilla_source(raw, parsed, {})
	if rewritten == raw:
		_fail(fname, "wrap-all rewrite returned the source unchanged -- nothing was wrapped")
		return
	var rlines: PackedStringArray = rewritten.split("\n")
	var marker_idx := _find_line(rlines, WRAPPER_MARKER, 0)
	if marker_idx < 0:
		_fail(fname, "wrapper marker comment missing from rewritten output")
		return
	# A registry transform is anchored to vanilla text and no-ops silently when
	# the game moves the pattern (Build 2 renamed AISpawner's `agent =` to
	# `enemy =`); the loader checks the same markers at pack time.
	var expected_markers: Dictionary = ml.get("REGISTRY_EXPECTED_MARKERS")
	if expected_markers.has(fname) and not (str(expected_markers[fname]) in rewritten):
		_fail(fname, "REGISTRY: transform marker '%s' missing from the full rewrite -- the vanilla anchor no longer matches this corpus" % str(expected_markers[fname]))

	for fe in nonstatic:
		_check_method(fname, fe, plines, rlines, marker_idx, fx)

	# Static funcs must never be renamed or wrapped.
	for fe in parsed["functions"]:
		if not fe["is_static"]:
			continue
		var sdecl := _decl_line(plines, fe)
		if sdecl != "" and _find_line(rlines, "func _rtv_vanilla_" + sdecl.trim_prefix("static func "), 0) >= 0:
			_fail(fname, "static func %s was renamed/wrapped -- static methods must stay untouched" % fe["name"])

	# Before the rewrite is written over the pristine file: the probe must
	# judge the real script, and the renamed-member cases read the pristine text.
	_check_vetting(ml, fname, path, raw, parsed)

	if not _compile_at_path(fname, path, rewritten, "COMPILE (wrap-all)"):
		return
	_check_caller(fname, path, nonstatic, plines)
	_check_registry_runtime(fname, path, raw)
	if _failures.size() == fails_before:
		print("[codegen] OK %s: %d method(s) wrapped; rewritten output + caller stub compile" % [fname, nonstatic.size()])

# Overwrite the fixture on disk with generated source and recompile it at its
# canonical res:// path, bypassing the cache -- the same load the game does.
func _compile_at_path(fname: String, path: String, source: String, stage: String) -> bool:
	var wf := FileAccess.open(path, FileAccess.WRITE)
	if wf == null:
		_fail(fname, stage + ": cannot overwrite fixture file for the compile step")
		return false
	wf.store_string(source)
	wf.close()
	var scr = ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_IGNORE)
	if scr == null or not (scr as Script).can_instantiate():
		_fail(fname, stage + ": generated output does NOT compile (see the SCRIPT ERROR lines above for file/line)")
		return false
	return true

# --- per-method output properties -------------------------------------------

# The wrapper signature the emitter is contractually required to produce:
# original name, the params verbatim, the return annotation when the vanilla
# declaration has one. Whitespace is normalized (" -> T", single ":"), which
# is also what _rtv_dispatch_inline_src's callers depend on.
func _expected_wrapper_sig(fe: Dictionary) -> String:
	var annot := ""
	var rt = fe["return_type"]
	if rt != null and not String(rt).is_empty():
		annot = " -> " + String(rt)
	return "func %s(%s)%s:" % [fe["name"], fe["params"], annot]

func _decl_line(plines: PackedStringArray, fe: Dictionary) -> String:
	var ln: int = int(fe["line_number"]) - 1
	if ln < 0 or ln >= plines.size():
		return ""
	return plines[ln]

func _check_method(fname: String, fe: Dictionary, plines: PackedStringArray, rlines: PackedStringArray, marker_idx: int, fx: Dictionary) -> void:
	var name: String = fe["name"]
	var decl := _decl_line(plines, fe)
	if not decl.begins_with("func "):
		_fail(fname, "%s: parsed line_number %d does not hold its declaration" % [name, fe["line_number"]])
		return
	# 1. Vanilla body preserved under the renamed declaration.
	var renamed_decl := "func _rtv_vanilla_" + decl.substr(5)
	var renamed_idx := _find_line(rlines, renamed_decl, 0)
	if renamed_idx < 0:
		_fail(fname, "%s: renamed vanilla body 'func _rtv_vanilla_%s(...)' not found in the rewritten output" % [name, name])
		return
	# 2. Wrapper preserves the signature: same name, the params VERBATIM from
	# the pristine declaration, and the same return annotation. (Not a raw
	# byte-compare of the whole decl line: the decompiled corpus carries
	# spacing artifacts like '-> void :' which the emitter normalizes.)
	# Tie the parsed params back to the pristine text first, so the expected
	# signature cannot drift from what vanilla actually declares.
	if not (("(" + String(fe["params"]) + ")") in decl):
		_fail(fname, "%s: parsed params '%s' are not a verbatim slice of the declaration '%s'" % [name, str(fe["params"]), decl])
		return
	var expected_sig := _expected_wrapper_sig(fe)
	var wrap_idx := _find_line(rlines, expected_sig, marker_idx)
	if wrap_idx < 0:
		_fail(fname, "%s: no wrapper with signature '%s' after the wrapper marker -- params, defaults and return annotation must be preserved" % [name, expected_sig])
		return
	# 3. Coroutine discipline. Ground truth: does the PRISTINE body await?
	var pbody := _body_block(plines, int(fe["line_number"]) - 1)
	var wbody := _body_block(rlines, wrap_idx)
	var pbody_text := "\n".join(pbody)
	var wbody_text := "\n".join(wbody)
	var vanilla_is_coro := "await " in pbody_text
	if vanilla_is_coro:
		if not ("await " in wbody_text):
			_fail(fname, "%s: vanilla method is a coroutine but its wrapper contains no 'await' -- the wrapper would return before the body resolves" % name)
	else:
		if "await" in wbody_text:
			_fail(fname, "%s: wrapper for a NON-coroutine method contains 'await' -- that alone marks the wrapped method a coroutine, and every existing caller then fails at parse time ('must be called with await'). This is the 3.3.0 bug class." % name)
	# 4. Body-verbatim preservation (skipped for legitimately modified bodies).
	var modified: Array = BODY_MODIFIED.get(fname, [])
	var skip: bool = (name in modified) or ("super" in pbody_text) or (not fx.get("baseline", true))
	if not skip:
		var rbody := _body_block(rlines, renamed_idx)
		if "\n".join(rbody) != pbody_text:
			_fail(fname, "%s: body under _rtv_vanilla_%s differs from the vanilla body" % [name, name])
	# Coverage bookkeeping.
	if vanilla_is_coro:
		_saw_coroutine = true
	elif bool(fe["has_return_value"]):
		_saw_sync_value = true
	else:
		_saw_void = true
	if "=" in String(fe["params"]):
		_saw_defaults = true
	if fname == "Loader.gd" and name == "ValidateShelter":
		if vanilla_is_coro or not bool(fe["has_return_value"]):
			_fail(fname, "ValidateShelter is expected to be a synchronous value-returning method; the parser disagrees -- parser regression?")
		else:
			_saw_validateshelter = true

# --- masked rewrite ---------------------------------------------------------

func _check_masked(ml, fx: Dictionary, fname: String, path: String, raw: String, plines: PackedStringArray, parsed: Dictionary, nonstatic: Array) -> void:
	var mask: Dictionary = {}
	for m in fx["mask"]:
		mask[String(m).to_lower()] = true
	var masked: String = ml._rtv_rewrite_vanilla_source(raw, parsed, mask)
	if masked == raw:
		_fail(fname, "MASKED: mask %s matched no methods -- fixture mask is stale" % [str(fx["mask"])])
		return
	var mlines: PackedStringArray = masked.split("\n")
	var mmarker := _find_line(mlines, WRAPPER_MARKER, 0)
	if mmarker < 0:
		_fail(fname, "MASKED: wrapper marker missing")
		return
	for fe in nonstatic:
		var name: String = fe["name"]
		var decl := _decl_line(plines, fe)
		if decl == "":
			continue
		var renamed := "func _rtv_vanilla_" + decl.substr(5)
		if mask.has(name.to_lower()):
			if _find_line(mlines, renamed, 0) < 0:
				_fail(fname, "MASKED: %s is in the mask but was not renamed" % name)
			if _find_line(mlines, _expected_wrapper_sig(fe), mmarker) < 0:
				_fail(fname, "MASKED: %s is in the mask but has no wrapper with the original signature" % name)
		else:
			if _find_line(mlines, renamed, 0) >= 0:
				_fail(fname, "MASKED: %s is NOT in the mask but was renamed -- masked-out methods must stay vanilla" % name)
			var d := _find_line(mlines, decl, 0)
			if d < 0 or d > mmarker:
				_fail(fname, "MASKED: %s is NOT in the mask but its vanilla declaration is gone from the body" % name)
	_compile_at_path(fname, path, masked, "COMPILE (masked)")

# --- caller stub ------------------------------------------------------------

# Generate and compile a stub that CALLS every wrapped method the way real
# game code and mods do: no `await` on methods whose vanilla body is not a
# coroutine, with value returns assigned to locals (typed when the return
# annotation is resolvable from the caller's scope). A wrapper that silently
# became a coroutine compiles fine on its own; only this file catches it.
func _check_caller(fname: String, path: String, nonstatic: Array, plines: PackedStringArray) -> void:
	var body := PackedStringArray()
	var n := 0
	for fe in nonstatic:
		var name: String = fe["name"]
		var args = _caller_args(String(fe["params"]))  # String or null
		if args == null:
			print("[codegen] note: %s::%s left out of the caller stub (parameter type not resolvable from caller scope)" % [fname, name])
			continue
		var pbody_text := "\n".join(_body_block(plines, int(fe["line_number"]) - 1))
		var is_coro := "await " in pbody_text
		var rt = fe["return_type"]  # String or null
		var has_value: bool = bool(fe["has_return_value"]) and (rt == null or String(rt) != "void")
		var call := "t.%s(%s)" % [name, args]
		n += 1
		if is_coro:
			if has_value:
				body.append("\tvar r%d = await %s" % [n, call])
			else:
				body.append("\tawait " + call)
		else:
			if has_value and rt != null and _type_resolvable(String(rt)):
				body.append("\tvar r%d: %s = %s" % [n, String(rt), call])
			elif has_value:
				body.append("\tvar r%d = %s" % [n, call])
			else:
				body.append("\t" + call)
	if body.is_empty():
		body.append("\tpass")
	var lines := PackedStringArray()
	lines.append("# Generated caller stub for the REWRITTEN " + fname + " -- compile-only, never run.")
	lines.append("# Calls every wrapped method WITHOUT await unless the vanilla body is a real")
	lines.append("# coroutine. If a wrapper silently became a coroutine, these calls fail with")
	lines.append("# 'Function X() is a coroutine, so it must be called with \"await\"' -- the")
	lines.append("# exact parse-time breakage 3.3.0 shipped to every mod.")
	lines.append("const TargetScript = preload(\"" + path + "\")")
	lines.append("")
	lines.append("func _rtv_codegen_probe(t: TargetScript) -> void:")
	lines.append_array(body)
	var caller_path := "res://callers/Caller_" + fname
	var wf := FileAccess.open(caller_path, FileAccess.WRITE)
	if wf == null:
		_fail(fname, "CALLER: cannot write " + caller_path)
		return
	wf.store_string("\n".join(lines) + "\n")
	wf.close()
	var scr = ResourceLoader.load(caller_path, "", ResourceLoader.CACHE_MODE_IGNORE)
	if scr == null or not (scr as Script).can_instantiate():
		_fail(fname, "CALLER: calling the wrapped methods without await does not compile -- a wrapper likely became a coroutine, or the signature/return annotation drifted (see SCRIPT ERROR lines above; stub kept at %s)" % caller_path)

# Placeholder argument list for the REQUIRED (non-defaulted) parameters.
# Returns null when a parameter type cannot be satisfied from caller scope.
func _caller_args(params: String):
	if params.strip_edges().is_empty():
		return ""
	var args := PackedStringArray()
	for part in _split_params_top_level(params):
		var p := String(part).strip_edges()
		if p.is_empty():
			continue
		if "=" in p:
			break  # first defaulted param: this and everything after is omittable
		var t := ""
		var colon := p.find(":")
		if colon >= 0:
			t = p.substr(colon + 1).strip_edges()
		var ph := _placeholder_for_type(t)
		if ph == "":
			return null
		args.append(ph)
	return ", ".join(args)

func _placeholder_for_type(t: String) -> String:
	if t.is_empty() or t == "Variant":
		return "null"
	if t.begins_with("Array"):
		return "[]"
	match t:
		"int":
			return "0"
		"float":
			return "0.0"
		"bool":
			return "false"
		"String":
			return "\"\""
		"StringName":
			return "&\"\""
		"Dictionary":
			return "{}"
	if t in BUILTIN_TYPES:
		return t + "()"
	if ClassDB.class_exists(t) or _global_classes.has(t):
		return "null"  # object parameters accept null
	return ""  # unresolvable (script-local enum / inner class) -- skip the probe

func _type_resolvable(t: String) -> bool:
	if t.begins_with("Array["):
		return _type_resolvable(t.trim_prefix("Array[").trim_suffix("]"))
	return t in BUILTIN_TYPES or ClassDB.class_exists(t) or _global_classes.has(t)

# Top-level comma split (commas inside (), [], {} or string literals belong
# to a default value). Deliberately reimplemented here rather than calling
# the loader's _rtv_split_params_top_level: the harness must not trust the
# code under test to slice its own inputs.
func _split_params_top_level(params: String) -> Array:
	var parts: Array = []
	var depth := 0
	var in_str := ""
	var escaped := false
	var start := 0
	for i in params.length():
		var c := params[i]
		if in_str != "":
			if escaped:
				escaped = false
			elif c == "\\":
				escaped = true
			elif c == in_str:
				in_str = ""
		elif c == "\"" or c == "'":
			in_str = c
		elif c == "(" or c == "[" or c == "{":
			depth += 1
		elif c == ")" or c == "]" or c == "}":
			depth -= 1
		elif c == "," and depth == 0:
			parts.append(params.substr(start, i - start))
			start = i + 1
	parts.append(params.substr(start))
	return parts

# --- text helpers -----------------------------------------------------------

func _find_line(lines: PackedStringArray, exact: String, from_idx: int) -> int:
	for i in range(maxi(from_idx, 0), lines.size()):
		if lines[i] == exact:
			return i
	return -1

# The indented block under a declaration line: every following line that is
# blank or indented, stopping at the first top-level line (trailing blanks
# stripped). Matches how the rewriter itself scopes bodies, but computed
# independently here.
func _body_block(lines: PackedStringArray, decl_idx: int) -> PackedStringArray:
	var out := PackedStringArray()
	for i in range(decl_idx + 1, lines.size()):
		var ln := lines[i]
		if not ln.is_empty() and ln[0] != "\t" and ln[0] != " ":
			break
		out.append(ln)
	while out.size() > 0 and out[out.size() - 1].strip_edges().is_empty():
		out.remove_at(out.size() - 1)
	return out
