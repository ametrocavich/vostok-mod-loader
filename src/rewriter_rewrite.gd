# Inline source-rewrite generator (Option C / Phase 1 Step A).
#
# Produces the full rewritten source of a vanilla script where each hookable
# method <name> is renamed to _rtv_vanilla_<name> and a new <name> method is
# appended that dispatches through RTVModLib hooks, then calls the renamed
# original.
#
# Rewrites the vanilla script itself rather than generating a separate
# wrapper class. When shipped at res://Scripts/<Name>.gd via a hook pack,
# it becomes the script Godot compiles for that path -- no extends chain,
# no class_name registry asymmetry, no bug #83542 regardless of what mods
# do with take_over_path.
#
# Caller MUST pass pristine vanilla source (e.g. from .gdc bytecode via
# _read_vanilla_source / _detokenize_script). Passing already-rewritten source
# produces duplicate-function parse errors.

func _rtv_rewrite_vanilla_source(source: String, parsed: Dictionary, method_mask: Dictionary = {}) -> String:
	# method_mask (v3.0.1): Dictionary[method_name, true] restricting which
	# methods get renamed + wrapped. Empty = wrap every non-static method
	# (REGISTRY_TARGETS needing whole-script injection, and the user-facing
	# "[hooks] <path> = *" wildcard sentinel).
	# Non-empty = wrap only declared methods; matches godot-mod-loader's
	# per-path method_mask. Other methods stay vanilla, no dispatch
	# overhead, no rename.
	var apply_mask: bool = not method_mask.is_empty()
	var hookable: Array = []
	for fe in parsed["functions"]:
		if fe["is_static"]:
			continue
		# Mask keys are lowercased (built from .hook() calls; see
		# add_hook() in hooks_api.gd). Match case-insensitively
		# so "updatetooltip" matches vanilla "UpdateToolTip".
		if apply_mask and not method_mask.has(fe["name"].to_lower()):
			continue
		hookable.append(fe)

	# LOUD mask validation: every declared hook method must correspond to a
	# non-static vanilla method, or the mod's hook silently never fires --
	# the "declared a hook, nothing happened, no log" failure mode. (When the
	# WHOLE mask misses, _generate_hook_pack already warns and skips; this
	# covers the partial case where some declared methods match and the rest
	# would previously vanish without a trace.)
	if apply_mask:
		var _mask_nonstatic: Dictionary = {}
		var _mask_static: Dictionary = {}
		for fe in parsed["functions"]:
			if fe["is_static"]:
				_mask_static[str(fe["name"]).to_lower()] = true
			else:
				_mask_nonstatic[str(fe["name"]).to_lower()] = true
		for mk in method_mask:
			if _mask_nonstatic.has(mk):
				continue
			if _mask_static.has(mk):
				_log_warning("[RTVCodegen] Hook on %s::%s will NEVER fire: it is a static function, and static functions cannot be hooked." \
						% [parsed.get("filename", "?"), mk])
			else:
				_log_warning("[RTVCodegen] Hook on %s::%s will NEVER fire: no such method in vanilla. Check the spelling, or the game update renamed/removed it." \
						% [parsed.get("filename", "?"), mk])

	if hookable.is_empty():
		return source

	# Build set of hookable method names for fast lookup during rename pass.
	var hookable_names: Dictionary = {}
	for fe in hookable:
		hookable_names[fe["name"]] = true

	# Normalize line endings. IXP ships CRLF-encoded source; our appended
	# wrappers use LF only. Mixing CRLF and LF in a single file confuses
	# GDScript's parser with a "tab character for indentation" error (even
	# when there are no tabs -- the misleading error is triggered by the
	# ending mismatch). Strip all CR so the whole file is pure LF.
	var src: String = source.replace("\r\n", "\n").replace("\r", "\n")

	# Maximum-compat pass: repair sloppy / Godot-3-era GDScript that the
	# parser would reject. Runs before our rename+wrapper pipeline so
	# every downstream step sees valid source. No-op for clean files.
	var autofix := _rtv_autofix_legacy_syntax(src)
	src = autofix["source"]
	var af_total: int = int(autofix["bodyless"]) + int(autofix["tool"]) \
			+ int(autofix["onready"]) + int(autofix["export"]) + int(autofix.get("base", 0))
	if af_total > 0:
		_log_info("[Autofix] %s: %d bodyless, %d @tool, %d @onready, %d @export, %d base()->super -- legacy syntax normalized" \
				% [parsed.get("filename", "?"), autofix["bodyless"], autofix["tool"], autofix["onready"], autofix["export"], autofix.get("base", 0)])

	# Per-script declaration-level transforms. Each case makes otherwise-
	# compile-time-immutable declarations runtime-mutable so the registry
	# can swap them under the hood.
	var fn: String = parsed.get("filename", "")
	# Database.gd: convert `const X = preload("...")` -> _rtv_vanilla_scenes
	# dict entries so Database.get(name) flows through _get() and sees mod
	# overrides instead of resolving via direct const lookup.
	if fn == "Database.gd":
		src = _rtv_rewrite_database_constants(src)
	# Loader.gd: convert `const shelters = [...]` -> var so the registry
	# can append mod shelter names. Scene-path consts (const Cabin = "..."
	# etc.) stay consts because LoadScene references them directly inside
	# its body; we inject a mod-lookup prelude into LoadScene instead.
	elif fn == "Loader.gd":
		src = _rtv_rewrite_loader_shelters(src)
	# AISpawner.gd: the vanilla if-elif that maps Zone -> agent is rewritten
	# so each `agent = <name>` becomes `agent = _rtv_resolve_ai_type(zone,
	# <name>)`. The helper (appended as part of registry injection) checks
	# the override dict and returns that or the vanilla scene. Lets mods
	# swap the agent spawned in any vanilla zone without touching _ready.
	elif fn == "AISpawner.gd":
		src = _rtv_rewrite_aispawner_agent_assignments(src)

	# Pass 1: rename top-level "func <name>(" to "func _rtv_vanilla_<name>("
	# AND rewrite bare super() calls inside that body to super.<name>().
	# Only matches at line start (static methods already filtered). Inner-class
	# methods (indented) keep their names. class_name stays intact -- scripts
	# ship at res://Scripts/<Name>.gd matching the PCK's class-cache
	# registration, and extends-by-path from other scripts needs the target
	# to carry a class_name to resolve.
	#
	# super() rewrite rationale: in IXP's Loader.gd `func CheckVersion(): ...
	# return super()`, `super()` means "parent's version of the current
	# function". After we rename the enclosing func to _rtv_vanilla_CheckVersion,
	# GDScript's strict reload parser looks for _rtv_vanilla_CheckVersion on the
	# parent -- which vanilla Loader doesn't have. Rewriting to
	# `super.CheckVersion()` keeps it resolving to the original method name on
	# parent (which is now our dispatch wrapper). `super.<explicit_method>()`
	# and `super.OtherMethod()` are already explicit and pass through untouched.
	var lines: PackedStringArray = src.split("\n")
	var current_hooked_method: String = ""
	var renamed_methods: Dictionary = {}
	for i in lines.size():
		var line: String = lines[i]
		# Top-level line (no indent): may open or close a method block.
		if not line.is_empty() and line[0] != "\t" and line[0] != " ":
			current_hooked_method = ""
			if line.begins_with("func "):
				var open_paren := line.find("(")
				if open_paren >= 0:
					var name_end := open_paren
					while name_end > 5 and line[name_end - 1] == " ":
						name_end -= 1
					var method_name := line.substr(5, name_end - 5)
					if hookable_names.has(method_name):
						lines[i] = "func _rtv_vanilla_" + method_name + line.substr(name_end)
						current_hooked_method = method_name
						renamed_methods[method_name] = true
			continue
		# Indented line: inside some block. If inside a renamed method, rewrite
		# bare super( / super ( to super.<orig_name>( so it still resolves.
		if current_hooked_method.is_empty():
			continue
		if not ("super" in line):
			continue
		lines[i] = _rewrite_bare_super(line, current_hooked_method)

	# Rename invariant: every hookable method MUST have been renamed to
	# _rtv_vanilla_<name> by the pass above (renamed_methods records each
	# rename as it happens -- an O(1) check instead of re-scanning every
	# line per method). If the rename missed one (formatting drift between
	# the parse and the rename scan -- e.g. extra spaces in the
	# declaration), the wrapper appended below DUPLICATES the still-
	# unrenamed vanilla method and the whole rewritten script fails to
	# compile, taking every hook on this script down with it. Scream at
	# generation time, with the cause, instead of a bare engine parse error.
	for fe in hookable:
		if not renamed_methods.has(fe["name"]):
			_log_critical("[RTVCodegen] %s: internal rename failure on method '%s' -- the rewritten script will fail to compile and ALL hooks on this script are disabled. Please report this modloader bug (include game version)." \
					% [parsed.get("filename", "?"), str(fe["name"])])

	# Pass 1.5: function-body prelude injection. Some registries need a
	# check at the TOP of a specific vanilla function body (e.g., Loader's
	# LoadScene needs to consult _rtv_mod_scene_paths before the if-elif
	# chain fires). The function was just renamed to _rtv_vanilla_<Name>,
	# so we inject right after its signature line.
	var indent := _detect_indent_style(src)
	lines = _rtv_apply_prelude_injections(parsed.get("filename", ""), lines, "_rtv_vanilla_", indent)

	# Pass 2: append dispatch wrappers at EOF. Match the source's indent
	# style -- GDScript rejects tab/space mixing in a single file. IXP uses
	# 4-space indent; vanilla RTV uses tabs.
	var prefix := _rtv_script_hook_prefix(parsed["filename"])
	var appended := "\n\n# --- Metro mod loader inline hook dispatch wrappers ---\n"
	for fe in hookable:
		appended += _rtv_dispatch_inline_src(fe, prefix, indent) + "\n"

	# Per-script registry injections. The REGISTRY_TARGETS gate in
	# _generate_hook_pack already ensures these only fire for declared
	# registry-opt-in paths.
	appended += _rtv_registry_injection(parsed["filename"], indent)

	return "\n".join(lines) + appended

# Rewrite bare `super(` / `super (` in a line to `super.<method>(`. Preserves
# the rest of the line verbatim. Skips `super.<something>(` (already explicit)
# and anything at/after the first `#` (comment heuristic). String literals are
# NOT tracked: a "super(" inside a string before any `#` would be rewritten,
# altering that string's text (never code structure). Detokenized vanilla input
# makes this a non-case; add real quote tracking if a script ever hits it.
# Called per-line within a renamed method's body.
func _rewrite_bare_super(line: String, method_name: String) -> String:
	# Strip inline comment/string content before matching to avoid false hits.
	# Simple heuristic: search the part of the line before the first # (not in
	# a string). Strings with # are rare enough that we accept false negatives.
	var scan_end := line.length()
	var comment_idx := line.find("#")
	if comment_idx >= 0:
		scan_end = comment_idx
	var out := line
	var cursor := 0
	while cursor < scan_end:
		var idx := out.find("super", cursor)
		if idx < 0 or idx >= scan_end:
			break
		# Must be a whole word: preceding char can't be alphanumeric or _ or .
		# (dot would mean this is `x.super...` -- not a super call).
		if idx > 0:
			var prev := out[idx - 1]
			if prev == "." or prev == "_" or prev.to_upper() != prev.to_lower() \
					or (prev >= "0" and prev <= "9"):
				cursor = idx + 5
				continue
		# After "super", skip optional whitespace, then require "(".
		var after := idx + 5
		while after < out.length() and out[after] == " ":
			after += 1
		if after >= out.length() or out[after] != "(":
			cursor = idx + 5
			continue
		# Rewrite "super(" segment to "super.<method>(", keeping the rest.
		var before := out.substr(0, idx)
		var rest := out.substr(after)  # from "("
		out = before + "super." + method_name + rest
		# Advance past the replaced region and update scan_end for shift.
		var delta := 1 + method_name.length()  # added ".<name>"
		cursor = idx + 5 + delta + 1  # past "super.<name>("
		scan_end += delta
	return out

# Scan source for the first indented (non-empty, non-comment) line and return
# its leading whitespace as the indent unit. Falls back to tab when the file
# has no indentation (rare -- empty method bodies use `pass` which is typically
# indented). Used to make generated wrappers match the file's existing style,
# since GDScript forbids mixing tabs and spaces.
func _detect_indent_style(source: String) -> String:
	for line: String in source.split("\n"):
		if line.is_empty():
			continue
		var ch: String = line[0]
		if ch != "\t" and ch != " ":
			continue
		# Skip pure-whitespace lines.
		var stripped := line.strip_edges()
		if stripped.is_empty() or stripped.begins_with("#"):
			continue
		if ch == "\t":
			return "\t"
		var n := 0
		while n < line.length() and line[n] == " ":
			n += 1
		if n > 0:
			return " ".repeat(n)
	return "\t"

# Returns the run of leading tabs+spaces on a line.
func _rtv_leading_indent(line: String) -> String:
	var n := 0
	while n < line.length() and (line[n] == "\t" or line[n] == " "):
		n += 1
	return line.substr(0, n)

# Produces ONE inline dispatch wrapper that calls _rtv_vanilla_<name>(...).
# The wrapper is appended to the rewritten vanilla source, co-existing with
# the renamed body in the same class -- no inheritance chain, so no
# _rtv_ready_done flag is needed. `await` is prepended when the vanilla
# method is a coroutine so the wrapper doesn't return before the body
# resolves.

func _rtv_dispatch_inline_src(fe: Dictionary, prefix: String, indent: String = "\t") -> String:
	var method_name: String = fe["name"]
	var params: String = fe["params"]
	var param_names_str: String = ", ".join(fe["param_names"])
	var hook_base: String = "%s-%s" % [prefix, method_name.to_lower()]
	var vanilla_call: String = "_rtv_vanilla_%s(%s)" % [method_name, param_names_str]
	var args_array: String = "[]" if param_names_str.is_empty() else "[%s]" % param_names_str
	var is_coro: bool = bool(fe["is_coroutine"])
	var is_engine_void: bool = method_name in RTV_ENGINE_VOID_METHODS
	var is_void: bool = is_engine_void or not bool(fe["has_return_value"])
	var aw: String = "await " if is_coro else ""

	# Preserve the return type annotation so callers can still type-infer
	# from wrapper returns (e.g. `var chargeLen = self.ChargeShot()` when
	# ChargeShot is `-> int`). Without the annotation, GDScript's strict
	# parser infers Variant and rejects untyped var decls in chained mod
	# subclasses, cascading parse failures through the extends chain.
	var return_annot: String = ""
	var rt = fe.get("return_type")
	if rt != null and not (rt as String).is_empty():
		return_annot = " -> " + (rt as String)
	var sig: String = "func %s()%s:" % [method_name, return_annot] if params.is_empty() \
			else "func %s(%s)%s:" % [method_name, params, return_annot]

	# Indent levels. GDScript requires consistent tabs-or-spaces per file;
	# IXP uses 4-space, vanilla RTV uses tabs. Caller passes the source's
	# detected indent so the emitted wrapper matches.
	var I1: String = indent
	var I2: String = indent + indent
	var I3: String = indent + indent + indent

	var out := ""
	# Step C re-entry guard: when a mod's rewritten wrapper fires and its body
	# calls super() into vanilla's rewritten wrapper, the nested wrapper would
	# dispatch again. Guard checks _lib._wrapper_active for this hook_base and
	# if already set, skips ALL dispatch + replace lookup and just runs the
	# vanilla body. One dispatch per logical call regardless of chain depth.
	if not is_void:
		out += "%s\n" % sig
		# Engine.get_meta with a Nil default still prints an error when the key
		# is absent (Godot 4.6 Object::get_meta at object.cpp:1155). Guard with
		# has_meta so early-boot wrappers that fire before _register_rtv_modlib_meta
		# (e.g. the 16 preempted class_name scripts) don't flood the log.
		out += "%sif not Engine.has_meta(\"RTVModLib\"):\n" % I1
		out += "%sreturn %s%s\n" % [I2, aw, vanilla_call]
		out += "%svar _lib = Engine.get_meta(\"RTVModLib\")\n" % I1
		# Global short-circuit: if no mod has called hook() this session, the
		# whole dispatch pipeline is dead weight. Single bool check skips
		# ~10 dict ops + meta/prop/fn calls. Matches godot-mod-loader.
		out += "%sif not _lib._any_mod_hooked:\n" % I1
		out += "%sreturn %s%s\n" % [I2, aw, vanilla_call]
		# Per-hook-base short-circuit: even when SOME mod has hooked SOMETHING
		# (which makes _any_mod_hooked sticky-true forever), most wrapped
		# methods still have no hooks of their own. One Dictionary.has() lets
		# them fast-path past the full _wrapper_active/_caller/_dispatch
		# pipeline.
		out += "%sif not _lib._hooked_bases.has(\"%s\"):\n" % [I1, hook_base]
		out += "%sreturn %s%s\n" % [I2, aw, vanilla_call]
		# Dev-mode-only per-method dispatch counter. Gated by a property
		# read so non-dev users pay ~1 branch per call; dev users see a
		# top-15 summary at 30s that pinpoints runaway method calls (e.g.
		# a mod's _ready firing 3000x -- typical cause of connect-already-
		# connected error spam). Counts only hook dispatches (after the
		# _any_mod_hooked short-circuit), not every wrapped call, so the
		# total stays meaningful even with hundreds of wrapped methods.
		out += "%sif _lib._developer_mode:\n" % I1
		out += "%s_lib._dispatch_counts[\"%s\"] = int(_lib._dispatch_counts.get(\"%s\", 0)) + 1\n" % [I2, hook_base, hook_base]
		out += "%svar _rtv_wa_key: String = str(get_instance_id()) + \":%s\"\n" % [I1, hook_base]
		out += "%sif _lib._wrapper_active.has(_rtv_wa_key):\n" % I1
		out += "%sreturn %s%s\n" % [I2, aw, vanilla_call]
		out += "%s_lib._wrapper_active[_rtv_wa_key] = true\n" % I1
		# Save prior _caller so nested-wrapper clobbering inside the
		# vanilla body (or replace hook) doesn't leak stale values to
		# whoever called us. Re-set _caller before the post-dispatch so
		# our post hooks see the correct caller even after nested
		# wrappers fired during the body.
		out += "%svar _rtv_prev_caller = _lib._caller\n" % I1
		out += "%s_lib._caller = self\n" % I1
		out += "%s_lib._dispatch(\"%s-pre\", %s)\n" % [I1, hook_base, args_array]
		out += "%svar _result\n" % I1
		out += "%svar _repl = _lib._get_hooks(\"%s\")\n" % [I1, hook_base]
		out += "%sif _repl.size() > 0:\n" % I1
		out += "%svar _prev_skip = _lib._skip_super\n" % I2
		out += "%s_lib._skip_super = false\n" % I2
		# Gated on is_coro via `aw`, NOT unconditional. In GDScript any function
		# whose body contains `await` IS a coroutine -- so an unconditional
		# await here turned every wrapped vanilla method into a coroutine, and
		# every existing caller then failed at PARSE time with "Function X is a
		# coroutine, so it must be called with await". Runtime cost was nil
		# (awaiting a non-coroutine Callable returns immediately); the damage
		# was entirely the coroutine marking, and it scaled with the wrap
		# surface -- 384 hook points across 35 scripts in the reported case.
		#
		# This does not change the hook contract. docs/wiki/Hooks.md has always
		# told authors to suspend inside a replace callback ONLY when the
		# vanilla method they replaced is itself a coroutine -- the wrapper
		# just failed to enforce it, and marked every wrapped method as a
		# coroutine to no benefit. Coroutine targets keep full async support.
		out += "%svar _replret = %s_repl[0].callv(%s)\n" % [I2, aw, args_array]
		out += "%svar _did_skip = _lib._skip_super\n" % I2
		out += "%s_lib._skip_super = _prev_skip\n" % I2
		out += "%sif _did_skip:\n" % I2
		out += "%s_result = _replret\n" % I3
		out += "%selse:\n" % I2
		out += "%s_result = %s%s\n" % [I3, aw, vanilla_call]
		out += "%selse:\n" % I1
		out += "%s_result = %s%s\n" % [I2, aw, vanilla_call]
		out += "%s_lib._caller = self\n" % I1
		# Post hooks for non-void methods get the chained-mutator dispatch:
		# each callback receives args + [_result], returning non-null to
		# replace _result for downstream callbacks. The 2-arg legacy form
		# (callback declared without trailing _result) still works -- the
		# dispatcher detects arity and calls the appropriate shape, with a
		# one-shot deprecation warning. See hooks_api._dispatch_post.
		out += "%s_result = _lib._dispatch_post(\"%s-post\", %s, _result)\n" % [I1, hook_base, args_array]
		out += "%s_lib._dispatch_deferred(\"%s-callback\", %s)\n" % [I1, hook_base, args_array]
		out += "%s_lib._wrapper_active.erase(_rtv_wa_key)\n" % I1
		out += "%s_lib._caller = _rtv_prev_caller\n" % I1
		out += "%sreturn _result\n" % I1
	else:
		out += "%s\n" % sig
		# Same has_meta guard as non-void branch above.
		out += "%sif not Engine.has_meta(\"RTVModLib\"):\n" % I1
		out += "%s%s%s\n" % [I2, aw, vanilla_call]
		out += "%sreturn\n" % I2
		out += "%svar _lib = Engine.get_meta(\"RTVModLib\")\n" % I1
		# Global short-circuit: see non-void branch above.
		out += "%sif not _lib._any_mod_hooked:\n" % I1
		out += "%s%s%s\n" % [I2, aw, vanilla_call]
		out += "%sreturn\n" % I2
		# Per-hook-base short-circuit: see non-void branch above.
		out += "%sif not _lib._hooked_bases.has(\"%s\"):\n" % [I1, hook_base]
		out += "%s%s%s\n" % [I2, aw, vanilla_call]
		out += "%sreturn\n" % I2
		# Dev-mode-only per-method dispatch counter (see non-void branch).
		out += "%sif _lib._developer_mode:\n" % I1
		out += "%s_lib._dispatch_counts[\"%s\"] = int(_lib._dispatch_counts.get(\"%s\", 0)) + 1\n" % [I2, hook_base, hook_base]
		out += "%svar _rtv_wa_key: String = str(get_instance_id()) + \":%s\"\n" % [I1, hook_base]
		out += "%sif _lib._wrapper_active.has(_rtv_wa_key):\n" % I1
		out += "%s%s%s\n" % [I2, aw, vanilla_call]
		out += "%sreturn\n" % I2
		out += "%s_lib._wrapper_active[_rtv_wa_key] = true\n" % I1
		# See non-void branch above for rationale on save/re-set/restore
		# of _caller. Same pattern, applied to the void-return template.
		out += "%svar _rtv_prev_caller = _lib._caller\n" % I1
		out += "%s_lib._caller = self\n" % I1
		out += "%s_lib._dispatch(\"%s-pre\", %s)\n" % [I1, hook_base, args_array]
		out += "%svar _repl = _lib._get_hooks(\"%s\")\n" % [I1, hook_base]
		out += "%sif _repl.size() > 0:\n" % I1
		out += "%svar _prev_skip = _lib._skip_super\n" % I2
		out += "%s_lib._skip_super = false\n" % I2
		# Void path -- same gating and same contract as the value-returning
		# branch above; see the comment there for why this must not be an
		# unconditional await.
		out += "%s%s_repl[0].callv(%s)\n" % [I2, aw, args_array]
		out += "%svar _did_skip = _lib._skip_super\n" % I2
		out += "%s_lib._skip_super = _prev_skip\n" % I2
		out += "%sif !_did_skip:\n" % I2
		out += "%s%s%s\n" % [I3, aw, vanilla_call]
		out += "%selse:\n" % I1
		out += "%s%s%s\n" % [I2, aw, vanilla_call]
		out += "%s_lib._caller = self\n" % I1
		out += "%s_lib._dispatch(\"%s-post\", %s)\n" % [I1, hook_base, args_array]
		out += "%s_lib._dispatch_deferred(\"%s-callback\", %s)\n" % [I1, hook_base, args_array]
		out += "%s_lib._wrapper_active.erase(_rtv_wa_key)\n" % I1
		out += "%s_lib._caller = _rtv_prev_caller\n" % I1
	return out

