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
##   baseline=false  pristine source is INTENTIONALLY invalid Godot 4 syntax
##                   (legacy-autofix fixture): skip the pristine compile and
##                   the body-verbatim check; the REWRITTEN output must still
##                   compile because _rtv_autofix_legacy_syntax repairs it.
##   mask=[...]      also run the rewrite with this per-method mask and
##                   assert only the masked methods were renamed + wrapped.
const FIXTURES: Array[Dictionary] = [
	# Synthetic fixtures (from tests/codegen/, copied in by check_codegen.sh).
	{"file": "FixtureDefaults.gd", "mask": ["DefaultsTricky", "CoroutineValue"]},
	{"file": "FixtureSub.gd"},                     # extends-by-path + bare super()
	{"file": "FixtureLegacy.gd", "baseline": false},
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
	"AISpawner.gd": ["_ready"],
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
	for fx in FIXTURES:
		_check_fixture(ml, fx)
	ml.free()
	if not _saw_sync_value:
		_fail("coverage", "no fixture exercised a synchronous value-returning method")
	if not _saw_void:
		_fail("coverage", "no fixture exercised a void method")
	if not _saw_coroutine:
		_fail("coverage", "no fixture exercised a coroutine method")
	if not _saw_defaults:
		_fail("coverage", "no fixture exercised default parameter values")
	if not _saw_validateshelter:
		_fail("coverage", "Loader.gd::ValidateShelter (the known-good 3.3.0 fixture) was not checked")
	_finish(t0)

func _finish(t0: int) -> void:
	var ms := Time.get_ticks_msec() - t0
	if _failures.is_empty():
		print("[codegen] PASS: %d fixture(s), all rewritten outputs + caller stubs compile (%d ms in-engine)" % [FIXTURES.size(), ms])
		quit(0)
	else:
		printerr("[codegen] FAILED: %d problem(s) (%d ms in-engine); first: %s" % [_failures.size(), ms, _failures[0]])
		quit(1)

func _fail(where: String, msg: String) -> void:
	_failures.append(where + ": " + msg)
	printerr("[codegen] FAIL " + where + ": " + msg)

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

	for fe in nonstatic:
		_check_method(fname, fe, plines, rlines, marker_idx, fx)

	# Static funcs must never be renamed or wrapped.
	for fe in parsed["functions"]:
		if not fe["is_static"]:
			continue
		var sdecl := _decl_line(plines, fe)
		if sdecl != "" and _find_line(rlines, "func _rtv_vanilla_" + sdecl.trim_prefix("static func "), 0) >= 0:
			_fail(fname, "static func %s was renamed/wrapped -- static methods must stay untouched" % fe["name"])

	if not _compile_at_path(fname, path, rewritten, "COMPILE (wrap-all)"):
		return
	_check_caller(fname, path, nonstatic, plines)
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
