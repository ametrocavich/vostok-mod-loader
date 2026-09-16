## ----- rewriter_parse.gd -----
## Source-rewrite codegen. Parses detokenized vanilla source and (with
## rewriter_rewrite.gd) renames each masked non-static method to
## _rtv_vanilla_<name>, appending a dispatch wrapper at the original name.
## Empty mask = wrap every non-static method. Only vanilla source is
## rewritten; mods compose through Godot's own extends resolution.
##
## Pipeline: PCK enumeration (pck_enumeration.gd) -> detokenize
## (gdsc_detokenizer.gd) -> hook/registry declarations build the wrap mask
## (mod_loading.gd, hooks_api.gd) -> rewrite (this file) -> pack + mount +
## activate (hook_pack.gd). Runtime dispatch flows from the emitted
## wrappers into hooks_api.gd via Engine.get_meta("RTVModLib").
##
## Adding a rewrite target touches, in sync (all dispatch on the bare
## filename string): hook_pack.gd REGISTRY_TARGETS (the file must not be
## in constants.gd's RTV_SKIP_LIST / RTV_RESOURCE_*_SKIP, which win
## silently); the transform chain here (_rtv_rewrite_vanilla_source,
## _rtv_apply_prelude_injections, _rtv_registry_injection); and a registry
## section if mods register data against it (recipe in registry.gd's
## header). A new hook-suffix variant touches hooks_api.gd hook() +
## _hook_base_of + a dispatcher, _re_hook_call below, and both emitter
## branches of _rtv_dispatch_inline_src.

# Rewriter regex (compiled in _rtv_compile_codegen_regex)
var _rtv_re_extends: RegEx
var _rtv_re_class_name: RegEx
var _rtv_re_func: RegEx
var _rtv_re_static_func: RegEx
var _rtv_re_sig_tail: RegEx
var _rtv_re_param_name: RegEx
var _rtv_re_var: RegEx
var _rtv_re_ret_value: RegEx

# A second regex set lives in _rtv_compile_codegen_regex below. They parse
# the same grammar but are not equivalent (this set: whole-blob, name-only
# captures; that set: per-line, full-signature, trailing-colon). Do not
# dedup them without diffing both parsers on a script corpus.
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
	# .hook("<prefix>-<method>[-pre|-post|-callback]"): captures the script
	# stem and method name that feed the per-path wrap mask. The suffix is
	# a dispatch variant, not part of the method name.
	_re_hook_call = RegEx.new()
	_re_hook_call.compile('\\.hook\\s*\\(\\s*"([A-Za-z_][\\w]*)-([A-Za-z_][\\w]*?)(?:-(?:pre|post|callback))?"')
	# Version-token shapes in a mod filename, read by _normalized_mod_stem:
	# [_-.] separator with optional v, space plus explicit v, space plus dotted
	# number, or v attached to the name. A space plus a bare integer is not a
	# version: "Ammo Pack 1" and "Ammo Pack 2" are different mods.
	_re_mod_stem_version = RegEx.new()
	_re_mod_stem_version.compile("^(.*?)(?:[_\\-.]+v?[0-9]+(?:[._][0-9]+)*| +v[0-9]+(?:[._][0-9]+)*| +[0-9]+(?:[._][0-9]+)+|v[0-9]+(?:[._][0-9]+)*)$")
	_re_mod_stem_named = RegEx.new()
	_re_mod_stem_named.compile("[a-z]")

# --- Codegen source parsing (regex compile + script-structure extraction) ---


# Twin of _compile_regex above; see the note there before merging the sets.
func _rtv_compile_codegen_regex() -> void:
	if _rtv_re_extends != null:
		return
	_rtv_re_extends = RegEx.new()
	_rtv_re_extends.compile('^extends\\s+"?([\\w/.:"]+)"?')
	_rtv_re_class_name = RegEx.new()
	_rtv_re_class_name.compile('^class_name\\s+(\\w+)')
	# Head-only match; _rtv_scan_signature extracts the parameter list. A
	# [^)]* regex stops at the first ')', silently skipping signatures with
	# parenthesized defaults like func f(v = Vector2(1, 2)):.
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

# Scan a func declaration from just after the opening paren, tracking
# bracket depth and string literals so nested defaults don't end the list
# early. Returns {params, return_type} for a complete single-line
# declaration, {} otherwise (multi-line signatures are skipped).
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

# Split a parameter list on top-level commas only; commas nested inside
# brackets or strings belong to a default value.
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
		# Top-level lines only: everything recorded here is module-scope
		# syntax. An inner class's indented extends/class_name/func would
		# otherwise pollute the script-level record -- a wildcard mask would
		# then emit a top-level wrapper for an inner-class-only method and
		# the rewritten script would not compile.
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
				# User-facing warning happens in _rtv_rewrite_vanilla_source's
				# mask validation.
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
			# A top-level line between this func and the next is module scope
			# (or an inner class header), not body. Stop here: an `await` past
			# this point would falsely mark the method a coroutine and every
			# caller would fail at parse time with "must be called with await".
			# Column-0 comments inside a body are legal GDScript; skip those.
			if raw_body[0] != "\t" and raw_body[0] != " ":
				if body_line.begins_with("#"):
					continue
				break
			# Never let comment lines set the await/return flags.
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

