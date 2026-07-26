## ----- rewriter_parse.gd -----
## Source-rewrite codegen. Given detokenized vanilla source + a parse
## structure + an optional per-method mask, produces a rewritten script
## where each non-static method in the mask (or every non-static method,
## when the mask is empty) is renamed to _rtv_vanilla_<name> and a
## dispatch wrapper is appended at the original name. The wrappers fire
## pre/replace/post/callback hooks and call the renamed body.
##
## v3.0.1: mod-subclass rewrite removed (was the old Step C). Mods that
## extend wrapped vanilla now compose via Godot's native extends
## resolution -- no _rtv_mod_ prefix, no rewrite of mod source.
##
## Also owns: regex compilation, parse-script, autofix legacy syntax,
## indent detection, bare-super rewriting.
##
## ============================ PIPELINE MAP ============================
## HOW THE PATCH PIPELINE FITS TOGETHER (read before adding a target):
##
## 1. PCK read (pck_enumeration.gd): _enumerate_game_scripts() ->
##    _parse_pck_file_list() walks RTV.pck's GDPC file table, yields every
##    res://Scripts/*.gd and fills _pck_zero_byte_paths;
##    _build_class_name_lookup() maps class_name -> path.
## 2. Detokenize (gdsc_detokenizer.gd): _read_vanilla_source() ->
##    _detokenize_script() reconstructs pristine vanilla source from the
##    PCK's binary-token .gdc (GDSC v100/v101), cached under
##    VANILLA_CACHE_DIR. _probe_gdsc_version() is stability canary B's
##    input, consulted at the top of _generate_hook_pack.
## 3. Declarations -> wrap surface (mod_loading.gd, hooks_api.gd,
##    main_menu_hook.gd): [hooks] sections in mod.txt and source-scanned
##    literal .hook("<stem>-<method>[-pre|-post|-callback]") calls (via
##    _re_hook_call + _merge_hook_calls_into_wrap_mask) populate
##    _hooked_methods (path -> {lowercased method: true}); [registry]
##    sections (or B_Loader call detection) set _any_mod_declared_registry;
##    add_hook() (godot-mod-loader compat) also writes _hooked_methods;
##    _seed_core_hooks() adds the core Menu.gd _ready wrap.
## 4. Rewrite (this file): _rtv_parse_script() parses the detokenized
##    source; _rtv_rewrite_vanilla_source() renames hookable methods to
##    _rtv_vanilla_<name>, applies per-script declaration transforms (the
##    Database/Loader/AISpawner if/elif chain), injects function preludes
##    (_rtv_apply_prelude_injections), appends dispatch wrappers
##    (_rtv_dispatch_inline_src) and registry appendices
##    (_rtv_registry_injection).
## 5. Pack + mount + activate (hook_pack.gd): _generate_hook_pack() gates
##    on the opt-in declarations, writes each rewrite as .gd +
##    self-referencing .gd.remap + empty .gdc into a modloader_hooks zip,
##    mounts it via ProjectSettings.load_resource_pack, then
##    _activate_rewritten_scripts() forces GDScriptCache to serve it
##    (source_code+reload, CACHE_MODE_IGNORE+take_over_path fallback).
##    boot.gd's _mount_previous_session re-mounts last session's pack at
##    static init. Runtime dispatch flows from the emitted wrappers into
##    hooks_api.gd (_dispatch/_dispatch_post/_dispatch_deferred) through
##    Engine.get_meta("RTVModLib").
##
## ADDING A NEW REWRITE TARGET touches, in sync (all dispatch on the bare
## filename string):
##   a. hook_pack.gd REGISTRY_TARGETS (only if whole-script wrap +
##      force-activation is needed). The new file must NOT appear in
##      constants.gd's RTV_SKIP_LIST / RTV_RESOURCE_*_SKIP -- those are
##      checked BEFORE needed_paths in _generate_hook_pack's loop and win
##      silently.
##   b. this file: the declaration-transform if/elif in
##      _rtv_rewrite_vanilla_source, and/or a case in
##      _rtv_apply_prelude_injections, and/or a case in
##      _rtv_registry_injection.
##   c. a new registry section if mods register data against it: a
##      Registry.FOO const + per-verb match-arms in registry.gd, a handler
##      under src/registry/, and a build.sh FILES entry (the full recipe
##      is in registry.gd's file header).
## ADDING A NEW HOOK VARIANT (a 4th suffix besides -pre/-post/-callback)
## touches: hooks_api.gd hook() + _hook_base_of + a new dispatcher, the
## _re_hook_call regex in _compile_regex below, and BOTH emitter branches
## of _rtv_dispatch_inline_src.
## ======================================================================

# NOTE: a second, deliberately separate regex set lives in
# _rtv_compile_codegen_regex below. The two parse the same grammar but are NOT
# equivalent (this set: whole-blob search/search_all, name-only func captures,
# res://-quoted-only extends -- grammar consumers in mod_loading.gd, plus
# _re_filename_priority in mod_discovery.gd; that set: per-line, full-signature
# captures with a trailing-colon requirement -- sole consumer
# _rtv_parse_script). Do not "dedup" them without diffing both parsers on a
# script corpus.
func _compile_regex() -> void:
	_re_take_over = RegEx.new()
	_re_take_over.compile('take_over_path\\s*\\(\\s*"(res://[^"]+)"')
	_re_extends = RegEx.new()
	_re_extends.compile('(?m)^extends\\s+"(res://[^"]+)"')
	_re_extends_classname = RegEx.new()
	_re_extends_classname.compile('(?m)^extends\\s+([A-Z]\\w+)\\s*$')
	_re_class_name = RegEx.new()
	_re_class_name.compile('(?m)^class_name\\s+(\\w+)')
	_re_func = RegEx.new()
	_re_func.compile('(?m)^(?:static\\s+)?func\\s+(\\w+)\\s*\\(')
	_re_preload = RegEx.new()
	_re_preload.compile('preload\\s*\\(\\s*"(res://[^"]+)"\\s*\\)')
	# VostokMods compat: "100-ModName.vmz" encodes priority in the filename.
	_re_filename_priority = RegEx.new()
	_re_filename_priority.compile('^(-?\\d+)-(.*)')
	# .hook("<prefix>-<method>[-pre|-post|-callback]") -- the first capture
	# is the lowercase script stem (e.g. "controller"), the second is the
	# declared method name. _generate_hook_pack uses the (prefix, method)
	# pair to build a per-path, per-method wrap mask so only the methods a
	# mod actually hooks get dispatch wrappers (matches godot-mod-loader's
	# per-path method_mask). Unknown-suffix fallbacks are treated as plain
	# methods (the -pre/-post/-callback suffix is a hook-dispatch variant,
	# not a method-name distinction).
	_re_hook_call = RegEx.new()
	_re_hook_call.compile('\\.hook\\s*\\(\\s*"([A-Za-z_][\\w]*)-([A-Za-z_][\\w]*?)(?:-(?:pre|post|callback))?"')

# --- Codegen source parsing (regex compile + script-structure extraction) ---


# NOTE: twin of _compile_regex above -- deliberately NOT shared; see the note
# there before attempting to merge the two sets.
func _rtv_compile_codegen_regex() -> void:
	if _rtv_re_extends != null:
		return
	_rtv_re_extends = RegEx.new()
	_rtv_re_extends.compile('^extends\\s+"?([\\w/.:"]+)"?')
	_rtv_re_class_name = RegEx.new()
	_rtv_re_class_name.compile('^class_name\\s+(\\w+)')
	# Head-only match: the parameter list is extracted by _rtv_scan_signature,
	# a depth-aware scan. A single [^)]* regex stops at the FIRST ')', so any
	# signature whose parameter default contains parens -- e.g.
	# func f(v = Vector2(1, 2)): -- failed to match and the whole function was
	# silently skipped (never hookable).
	_rtv_re_func = RegEx.new()
	_rtv_re_func.compile('^func\\s+(\\w+)\\s*\\(')
	_rtv_re_static_func = RegEx.new()
	_rtv_re_static_func.compile('^static\\s+func\\s+(\\w+)\\s*\\(')
	_rtv_re_sig_tail = RegEx.new()
	_rtv_re_sig_tail.compile('^\\s*(?:->\\s*([\\w\\[\\]]+)\\s*)?:')
	_rtv_re_param_name = RegEx.new()
	_rtv_re_param_name.compile('^[A-Za-z_]\\w*')
	_rtv_re_var = RegEx.new()
	_rtv_re_var.compile('^(?:@export\\s+)?var\\s+(\\w+)')
	_rtv_re_ret_value = RegEx.new()
	_rtv_re_ret_value.compile('(?:^|[:;])\\s*return\\b\\s*[^\\s#]')

# Scan a func declaration line from just after the opening paren, tracking
# paren/bracket/brace depth and string literals, so parameter defaults like
# Vector2(1, 2), {a = 1, b = 2} or "a,b" don't end the parameter list early.
# Returns {params, return_type (String or null)} for a complete single-line
# declaration, {} otherwise (multi-line signatures stay skipped, as before).
func _rtv_scan_signature(line: String, params_start: int) -> Dictionary:
	var depth := 1
	var in_str := ""
	var escaped := false
	var i := params_start
	var n := line.length()
	while i < n:
		var c := line[i]
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
			if depth == 0:
				break
		i += 1
	if i >= n or line[i] != ")":
		return {}
	var m_tail := _rtv_re_sig_tail.search(line.substr(i + 1))
	if m_tail == null:
		return {}
	var ret_type = m_tail.get_string(1) if m_tail.get_start(1) != -1 else null
	return {"params": line.substr(params_start, i - params_start), "return_type": ret_type}

# Split a parameter list on TOP-LEVEL commas only -- commas nested inside
# (), [], {} or string literals belong to a default value, not the list.
func _rtv_split_params_top_level(params: String) -> Array:
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

func _rtv_extract_param_names(params: String) -> Array:
	var names: Array = []
	if params.strip_edges().is_empty():
		return names
	for p in _rtv_split_params_top_level(params):
		var m := _rtv_re_param_name.search((p as String).strip_edges())
		if m != null:
			names.append(m.get_string(0))
	return names

func _rtv_script_hook_prefix(filename: String) -> String:
	var stem := filename
	if stem.ends_with(".gd"):
		stem = stem.substr(0, stem.length() - 3)
	return stem.to_lower()

# Returns:
#   { filename, path, extends, class_name, var_names, functions }
# Each function entry:
#   { name, params, param_names, line_number, is_static, return_type,
#     is_coroutine, has_return_value }

func _rtv_parse_script(filename: String, source: String) -> Dictionary:
	_rtv_compile_codegen_regex()
	var script := {
		"filename": filename,
		"path": "res://Scripts/" + filename,
		"extends": "",
		"class_name": null,
		"functions": [],
		"var_names": [],
	}
	var lines: PackedStringArray = source.split("\n")
	var func_starts: Array = []  # [line_num, name, params, param_names, is_static, return_type]

	for line_num in lines.size():
		var line: String = lines[line_num]
		# Top-level lines only (column 0, no leading indent). EVERYTHING this
		# pass records -- extends, class_name, vars, funcs -- is module-scope
		# syntax. Two reasons to skip indented lines up front:
		#   1. Correctness: an inner class's own indented `extends X` /
		#      `class_name` / `func` would otherwise clobber or pollute the
		#      script-level record. For funcs specifically, a wrap-mask
		#      (especially the wildcard "*") would then emit a top-level
		#      dispatch wrapper for a method that only exists inside the
		#      inner class -- a rewritten script that cannot compile.
		#   2. Startup cost: indented body lines are ~80% of a script; the
		#      per-line strip_edges + two regex searches they used to get
		#      (extends + class_name ran on EVERY line) were pure overhead,
		#      repeated across every wrapped script on every generation.
		if line.begins_with("\t") or line.begins_with(" "):
			continue
		var trimmed := line.strip_edges()
		if trimmed.is_empty():
			continue

		var m_ext := _rtv_re_extends.search(trimmed)
		if m_ext != null:
			script["extends"] = m_ext.get_string(1)

		var m_cn := _rtv_re_class_name.search(trimmed)
		if m_cn != null:
			script["class_name"] = m_cn.get_string(1)

		var m_var := _rtv_re_var.search(trimmed)
		if m_var != null:
			(script["var_names"] as Array).append(m_var.get_string(1))

		var m_sfunc := _rtv_re_static_func.search(trimmed)
		if m_sfunc != null:
			var sig_s := _rtv_scan_signature(trimmed, m_sfunc.get_end(0))
			if not sig_s.is_empty():
				func_starts.append([
					line_num, m_sfunc.get_string(1), sig_s["params"],
					_rtv_extract_param_names(sig_s["params"]), true,
					sig_s["return_type"],
				])
			else:
				# Parse-internal detail; the user-facing consequence (a
				# declared hook that can't fire) is warned about in
				# _rtv_rewrite_vanilla_source's mask validation.
				_log_debug("[RTVCodegen] %s: static func %s at line %d: signature unparseable (multi-line or malformed) -- invisible to the wrap surface" \
						% [filename, m_sfunc.get_string(1), line_num + 1])
			continue

		var m_func := _rtv_re_func.search(trimmed)
		if m_func != null:
			var sig_f := _rtv_scan_signature(trimmed, m_func.get_end(0))
			if not sig_f.is_empty():
				func_starts.append([
					line_num, m_func.get_string(1), sig_f["params"],
					_rtv_extract_param_names(sig_f["params"]), false,
					sig_f["return_type"],
				])
			else:
				# Parse-internal detail (dev-mode only). If a mod declared
				# a hook on this method, the mask validation in
				# _rtv_rewrite_vanilla_source emits the user-facing warning.
				_log_debug("[RTVCodegen] %s: func %s at line %d: signature unparseable (multi-line or malformed) -- NOT hookable, will not be wrapped" \
						% [filename, m_func.get_string(1), line_num + 1])

	# Second pass: extract function bodies to detect await + return-with-value.
	for idx in func_starts.size():
		var fs: Array = func_starts[idx]
		var line_num: int = fs[0]
		var name: String = fs[1]
		var params: String = fs[2]
		var param_names: Array = fs[3]
		var is_static: bool = fs[4]
		var return_type = fs[5]  # String or null

		var body_start := line_num + 1
		var body_end := lines.size()
		if idx + 1 < func_starts.size():
			body_end = func_starts[idx + 1][0]

		var is_coroutine := false
		var has_return_value := false
		for i in range(body_start, body_end):
			if i >= lines.size():
				break
			var raw_body := lines[i]
			var body_line := raw_body.strip_edges()
			if body_line.is_empty():
				continue
			# A top-level (unindented) line between this func and the next one
			# is NOT part of this body -- it's module scope (e.g. Database.gd's
			# const preload block sits after _ready) or an inner `class` header
			# whose indented methods would otherwise be scanned as OUR body.
			# Stop here: an `await` past this point would falsely mark the
			# method a coroutine, the wrapper would gain `await`, and every
			# caller of the wrapped method would then fail at PARSE time
			# ("must be called with await") -- the exact 3.3.0 bug class.
			# Column-0 comments inside a body are legal GDScript; skip those.
			if raw_body[0] != "\t" and raw_body[0] != " ":
				if body_line.begins_with("#"):
					continue
				break
			# Comment lines can contain the words "await" / "return" without
			# meaning either; never let them set the flags.
			if body_line.begins_with("#"):
				continue
			if "await " in body_line:
				is_coroutine = true
			# "return <something>" (not bare "return").
			if _rtv_re_ret_value.search(body_line) != null:
				has_return_value = true

		# Explicit return type override (void -> no value; anything else -> has value).
		if return_type != null and return_type != "void":
			has_return_value = true
		if return_type != null and return_type == "void":
			has_return_value = false

		(script["functions"] as Array).append({
			"name": name,
			"params": params,
			"param_names": param_names,
			"line_number": line_num + 1,
			"is_static": is_static,
			"return_type": return_type,
			"is_coroutine": is_coroutine,
			"has_return_value": has_return_value,
		})

	return script

