# Parses detokenized vanilla source: top-level declarations and each method's await/return shape.

# Head-only: a `[^)]*` parameter regex would stop at the `)` of a default like
# Vector2(1, 2), so _scan_signature reads the list. Group 1 holds the annotations.
var _rtv_re_func := RegEx.create_from_string('^((?:@\\w+(?:\\([^)]*\\))?\\s+)*)func\\s+(\\w+)\\s*\\(')
var _rtv_re_static_func := RegEx.create_from_string('^((?:@\\w+(?:\\([^)]*\\))?\\s+)*)static\\s+func\\s+(\\w+)\\s*\\(')
# The return annotation runs to the colon that ends the declaration (Dictionary[String, int]).
var _rtv_re_sig_tail := RegEx.create_from_string('^\\s*(?:->\\s*([^:]+?)\\s*)?:(.*)$')
var _rtv_re_param_name := RegEx.create_from_string('^[A-Za-z_]\\w*')
var _rtv_re_ret_value := RegEx.create_from_string('(?:^|[:;])\\s*return\\b\\s*[^\\s#]')
var _rtv_re_await := RegEx.create_from_string('\\bawait\\b')
# A lambda opener, not a call to a function whose name ends in "func".
var _rtv_re_lambda := RegEx.create_from_string('(?<![\\w.])func\\s*\\(')
var _rtv_re_annot_line := RegEx.create_from_string('^(?:@\\w+(?:\\([^)]*\\))?\\s*)+$')
var _rtv_re_ret_lambda := RegEx.create_from_string('(?:^|[:;])\\s*return\\s*$')
var _rtv_re_decl_prefix := RegEx.create_from_string('^(?:@\\w+(?:\\([^)]*\\))?\\s+)*')
var _rtv_re_scene_preload := RegEx.create_from_string("preload\\(\"(res://[^\"]+\\.(?:tscn|scn))\"\\)")
# A trailing comment is allowed: the plain-text fallback of _detokenize_script keeps them.
var _rtv_re_database_const := RegEx.create_from_string('^const\\s+(\\w+)\\s*=\\s*(preload\\s*\\(\\s*"[^"]+"\\s*\\))\\s*(?:#.*)?$')
var _rtv_re_loader_shelters := RegEx.create_from_string('^(\\s*)const\\s+shelters\\s*(=.*)$')
var _rtv_re_aispawner_assign := RegEx.create_from_string('^(\\s*)(enemy|agent)\\s*=\\s*(\\w+)\\s*(#.*)?$')
var _rtv_re_ai_variant := RegEx.create_from_string("(?m)^var variant\\s*:\\s*AIData\\b")

func _is_indented(line: String) -> bool:
	return line.begins_with("\t") or line.begins_with(" ")

func _scan_char(c: String, state: Dictionary) -> bool:
	if state["in_str"] != "":
		if state["escaped"]:
			state["escaped"] = false
		elif c == "\\":
			state["escaped"] = true
		elif c == state["in_str"]:
			state["in_str"] = ""
		return false
	if c == "\"" or c == "'":
		state["in_str"] = c
		return false
	if c == "(" or c == "[" or c == "{":
		state["depth"] += 1
	elif c == ")" or c == "]" or c == "}":
		state["depth"] -= 1
	return true

func _scan_signature(line: String, params_start: int) -> Dictionary:
	var state := {"depth": 1, "in_str": "", "escaped": false}
	var i := params_start
	var n := line.length()
	while i < n:
		if _scan_char(line[i], state) and state["depth"] == 0:
			break
		i += 1
	if i >= n or line[i] != ")":
		return {}
	var m_tail := _rtv_re_sig_tail.search(line.substr(i + 1))
	if m_tail == null:
		return {}
	var ret_type = m_tail.get_string(1).strip_edges() if m_tail.get_start(1) != -1 else null
	return {"params": line.substr(params_start, i - params_start), "return_type": ret_type,
			"inline_body": m_tail.get_string(2).strip_edges()}

func _split_params(params: String) -> Array[String]:
	var parts: Array[String] = []
	var state := {"depth": 0, "in_str": "", "escaped": false}
	var start := 0
	for i in params.length():
		var c := params[i]
		if _scan_char(c, state) and c == "," and state["depth"] == 0:
			parts.append(params.substr(start, i - start))
			start = i + 1
	parts.append(params.substr(start))
	return parts

func _rtv_strip_decl_prefix(line: String) -> String:
	var m := _rtv_re_decl_prefix.search(line)
	if m == null or m.get_end(0) <= 0:
		return line
	return line.substr(m.get_end(0))

# An @rpc wrapper would declare the rpc twice; a rest parameter cannot be forwarded by name.
func _unwrappable_reason(fe: Dictionary) -> String:
	if "@rpc" in str(fe.get("decl_prefix", "")):
		return "the method is an @rpc, which cannot be wrapped"
	for p in _split_params(fe["params"]):
		if p.strip_edges().begins_with("..."):
			return "the method takes a rest parameter (...), which a wrapper cannot forward"
	return ""

func _rtv_select_hookable(parsed: Dictionary, method_mask: Dictionary) -> Dictionary:
	var apply_mask: bool = not _mask_is_wildcard(method_mask)
	var hookable: Array = []
	var matched_keys: Dictionary = {}
	var unwrappable: Dictionary = {}
	for fe in parsed["functions"]:
		if fe["is_static"]:
			continue
		var key: String = str(fe["name"]).to_lower()
		if apply_mask and not method_mask.has(key):
			continue
		var why := _unwrappable_reason(fe)
		if why != "":
			if apply_mask:
				unwrappable[key] = why
			continue
		if apply_mask:
			matched_keys[key] = true
		hookable.append(fe)
	return {"hookable": hookable, "matched_keys": matched_keys, "unwrappable": unwrappable}

# The pack calls this once per script, since the probe may rewrite a script twice.
func _rtv_warn_mask_misses(parsed: Dictionary, method_mask: Dictionary) -> void:
	if _mask_is_wildcard(method_mask):
		return
	var filename: String = parsed["filename"]
	var nonstatic: Dictionary = {}
	var statics: Dictionary = {}
	var unparsed: Dictionary = {}
	for fe in parsed["functions"]:
		var key: String = str(fe["name"]).to_lower()
		if fe["is_static"]:
			statics[key] = true
			continue
		nonstatic[key] = true
		if method_mask.has(key):
			var why := _unwrappable_reason(fe)
			if why != "":
				_warn_never_fires(filename, str(fe["name"]), why + ".")
	for un in parsed["unparsed"]:
		unparsed[str(un).to_lower()] = true
	for mk in method_mask:
		if nonstatic.has(mk):
			continue
		if unparsed.has(mk):
			_warn_never_fires(filename, mk, "its declaration spans several lines, which the rewriter does not read.")
		elif statics.has(mk):
			_warn_never_fires(filename, mk, "it is a static function, and static functions cannot be hooked.")
		else:
			_warn_never_fires(filename, mk,
					"no such method in vanilla. Check the spelling, or the game update renamed/removed it.")

func _warn_never_fires(filename: String, method: String, why: String) -> void:
	_log_warning("[RTVCodegen] Hook on %s::%s will NEVER fire: %s" % [filename, method, why])

func _lambda_opens_block(masked: String, at: int) -> bool:
	var open_idx := masked.find("(", at)
	if open_idx < 0:
		return false
	var depth := 0
	for i in range(open_idx, masked.length()):
		var c := masked[i]
		if c == "(":
			depth += 1
		elif c == ")":
			depth -= 1
			if depth == 0:
				var tail := masked.substr(i + 1).strip_edges()
				if tail.begins_with("->"):
					var m_tail := _rtv_re_sig_tail.search(tail)
					return m_tail != null and m_tail.get_string(2).strip_edges() == ""
				return tail == ":"
	return false

func _rtv_parse_script(filename: String, source: String) -> Dictionary:
	var lines: PackedStringArray = source.split("\n")
	var unparsed: Array = []
	var decls := _collect_declarations(filename, lines, unparsed)
	var functions: Array = []
	for idx in decls.size():
		var decl: Dictionary = decls[idx]
		var body_end: int = decls[idx + 1]["line_num"] if idx + 1 < decls.size() else lines.size()
		var shape := _analyze_body(lines, decl, body_end)
		functions.append({
			"name": decl["name"],
			"params": decl["params"],
			"param_names": decl["param_names"],
			"line_number": decl["line_num"] + 1,
			"is_static": decl["is_static"],
			"return_type": decl["return_type"],
			"is_coroutine": shape["is_coroutine"],
			"has_return_value": shape["has_return_value"],
			"decl_prefix": decl["decl_prefix"],
		})
	return {"filename": filename, "functions": functions, "unparsed": unparsed}

func _collect_declarations(filename: String, lines: PackedStringArray, unparsed: Array) -> Array:
	var decls: Array = []
	var pending_annotations := PackedStringArray()
	for line_num in lines.size():
		var line: String = lines[line_num]
		if _is_indented(line):
			continue
		var trimmed := line.strip_edges()
		if trimmed.is_empty():
			continue
		if _rtv_re_annot_line.search(trimmed) != null:
			# Only function annotations travel down; a class one (@tool) breaks the wrapper.
			if trimmed.begins_with("@rpc") or trimmed.begins_with("@warning_ignore("):
				pending_annotations.append(trimmed)
			continue
		# A comment between an annotation and its declaration does not detach it.
		if trimmed.begins_with("#"):
			continue
		var above_prefix := ""
		if not pending_annotations.is_empty():
			above_prefix = " ".join(pending_annotations) + " "
			pending_annotations.clear()
		var is_static := true
		var m := _rtv_re_static_func.search(trimmed)
		if m == null:
			is_static = false
			m = _rtv_re_func.search(trimmed)
		if m == null:
			continue
		var sig := _scan_signature(trimmed, m.get_end(0))
		if sig.is_empty():
			unparsed.append(m.get_string(2))
			_log_debug("[RTVCodegen] %s: %sfunc %s at line %d: multi-line or malformed signature, not hookable" \
					% [filename, "static " if is_static else "", m.get_string(2), line_num + 1])
			continue
		var param_names: Array = []
		for p in _split_params(sig["params"]):
			var pm := _rtv_re_param_name.search(p.strip_edges())
			if pm != null:
				param_names.append(pm.get_string(0))
		decls.append({
			"line_num": line_num,
			"name": m.get_string(2),
			"params": sig["params"],
			"param_names": param_names,
			"is_static": is_static,
			"return_type": sig["return_type"],
			"decl_prefix": above_prefix + m.get_string(1),
			"inline_body": sig["inline_body"],
		})
	return decls

func _analyze_body(lines: PackedStringArray, decl: Dictionary, body_end: int) -> Dictionary:
	var is_coroutine := false
	var has_return_value := false
	var body: Array = []  # [indent width, text]
	if decl["inline_body"] != "":
		body.append([1, decl["inline_body"]])
	for i in range(decl["line_num"] + 1, body_end):
		var raw_body := lines[i]
		var body_line := raw_body.strip_edges()
		# A column-0 comment is legal in a body; a column-0 statement ends it.
		# An await past it would mark the method a coroutine and break every caller.
		if body_line.is_empty() or body_line.begins_with("#"):
			continue
		if not _is_indented(raw_body):
			break
		body.append([raw_body.length() - raw_body.lstrip(" \t").length(), body_line])
	# A lambda's await or return is its own: deeper block lines and the lambda's span on
	# its line (to the comma or bracket that closes it) are blanked; the rest is scanned.
	var lambda_indent := -1
	for item in body:
		var ind: int = item[0]
		if lambda_indent >= 0:
			if ind > lambda_indent:
				continue
			lambda_indent = -1
		var masked := _code_mask(item[1])
		var m_lambda := _rtv_re_lambda.search(masked)
		while m_lambda != null:
			var at := m_lambda.get_start(0)
			if _lambda_opens_block(masked, at):
				lambda_indent = ind
			# `return func(...)` returns the lambda: a value.
			if _rtv_re_ret_lambda.search(masked.substr(0, at)) != null:
				has_return_value = true
			var depth := 0
			var end := at
			while end < masked.length():
				var c := masked[end]
				if c == "(" or c == "[" or c == "{":
					depth += 1
				elif c == ")" or c == "]" or c == "}":
					depth -= 1
				if depth < 0 or (depth == 0 and c == ","):
					break
				end += 1
			masked = masked.substr(0, at) + " ".repeat(end - at) + masked.substr(end)
			m_lambda = _rtv_re_lambda.search(masked, end)
		if _rtv_re_await.search(masked) != null:
			is_coroutine = true
		if _rtv_re_ret_value.search(masked) != null:
			has_return_value = true
	var return_type = decl["return_type"]
	if return_type != null:
		has_return_value = return_type != "void"
	return {"is_coroutine": is_coroutine, "has_return_value": has_return_value}
