# Renames each hooked vanilla method to _rtv_vanilla_<name> in place and appends a
# dispatch wrapper under the original name. The input must be pristine vanilla source.

const _RTV_VANILLA_PREFIX := "_rtv_vanilla_"

# An empty method_mask wraps every non-static method. with_registry=false leaves out
# the registry code (transforms, preludes, appendices): the pack's wrap-only fallback.
func _rtv_rewrite_vanilla_source(source: String, parsed: Dictionary, method_mask: Dictionary = {},
		with_registry: bool = true) -> String:
	var hookable: Array = _rtv_select_hookable(parsed, method_mask)["hookable"]
	if hookable.is_empty():
		return source
	var fn: String = parsed["filename"]
	# The wrappers use LF; keep the whole file on one line ending.
	var src: String = source.replace("\r\n", "\n").replace("\r", "\n")
	var inject := with_registry
	if with_registry:
		match fn:
			"Database.gd":
				# The appendix reads _rtv_vanilla_scenes, which only the transform declares.
				var transformed := _database_consts_to_dict(src)
				inject = transformed != src
				src = transformed
			"Loader.gd":
				src = _shelters_to_var(src)
			"AISpawner.gd":
				src = _route_enemy_assignments(src)
	var lines := _rename_hookable(src.split("\n"), hookable, fn)
	# The indent unit is the first indented code line's (tab fallback); RTV uses tabs.
	var indent := "\t"
	for line in src.split("\n"):
		var code := line.strip_edges()
		if not _is_indented(line) or code.is_empty() or code.begins_with("#"):
			continue
		if line[0] == " ":
			indent = " ".repeat(line.length() - line.lstrip(" ").length())
		break
	if inject:
		lines = _apply_preludes(fn, lines, indent)
	var prefix := fn.trim_suffix(".gd").to_lower()
	var appended := "\n\n# --- Metro mod loader inline hook dispatch wrappers ---\n"
	for fe in hookable:
		appended += _wrapper_source(fe, prefix, indent) + "\n"
	if inject:
		appended += _registry_appendix(fn, indent, src)
	return "\n".join(lines) + appended

# Renames each top-level hooked `func <name>(`, keeping class_name and inner classes.
# A bare super() in a renamed body becomes super.<name>(), not the missing _rtv_vanilla_ one.
func _rename_hookable(lines: PackedStringArray, hookable: Array, filename: String) -> PackedStringArray:
	var renamed: Dictionary = {}
	for fe in hookable:
		renamed[fe["name"]] = false
	var current := ""
	for i in lines.size():
		var line: String = lines[i]
		if line != "" and not _is_indented(line):
			current = ""
			var m := _rtv_re_func.search(line)
			if m == null or not renamed.has(m.get_string(2)):
				continue
			var method_name := m.get_string(2)
			var at_name := m.get_start(2)
			var decl := line.substr(0, at_name) + _RTV_VANILLA_PREFIX + line.substr(at_name)
			# A one-line body sits on the declaration line.
			if "super" in decl:
				var sig := _scan_signature(decl, m.get_end(0) + _RTV_VANILLA_PREFIX.length())
				var inline_body: String = sig.get("inline_body", "")
				if inline_body != "" and "super" in inline_body:
					var at := decl.rfind(inline_body)
					if at >= 0:
						decl = decl.substr(0, at) + _rewrite_bare_super(inline_body, method_name)
			lines[i] = decl
			current = method_name
			renamed[method_name] = true
		elif current != "" and "super" in line:
			lines[i] = _rewrite_bare_super(line, current)
	# A method the rename missed would be declared twice once its wrapper is appended.
	for fe in hookable:
		if not renamed[fe["name"]]:
			_log_critical("[RTVCodegen] %s: internal rename failure on '%s' -- the rewrite will not compile" \
					% [filename, str(fe["name"])])
	return lines

# Bare `super(` becomes `super.<method>(`; text after the first `#` is left alone. String
# literals are not tracked, which detokenized vanilla input makes safe.
func _rewrite_bare_super(line: String, method_name: String) -> String:
	var code_end := line.find("#")
	if code_end < 0:
		code_end = line.length()
	var out := ""
	var copied := 0
	var idx := line.find("super")
	while idx >= 0 and idx < code_end:
		# Whole word only: a preceding letter, digit, _ or . is not a super call.
		var prev := line[idx - 1] if idx > 0 else " "
		var whole_word := prev != "." and prev != "_" and prev.to_upper() == prev.to_lower() \
				and not (prev >= "0" and prev <= "9")
		var after := idx + 5
		while after < line.length() and line[after] == " ":
			after += 1
		if whole_word and after < line.length() and line[after] == "(":
			out += line.substr(copied, idx - copied) + "super." + method_name
			copied = after
		idx = line.find("super", idx + 5)
	return out + line.substr(copied)

func _wrapper_source(fe: Dictionary, prefix: String, indent: String) -> String:
	var method_name: String = fe["name"]
	var param_names_str: String = ", ".join(fe["param_names"])
	var hook_base: String = "%s-%s" % [prefix, method_name.to_lower()]
	var vanilla_call: String = "%s%s(%s)" % [_RTV_VANILLA_PREFIX, method_name, param_names_str]
	var args_array: String = "[]" if param_names_str.is_empty() else "[%s]" % param_names_str
	var is_coro: bool = fe["is_coroutine"]
	var is_void: bool = method_name in RTV_ENGINE_VOID_METHODS or not fe["has_return_value"]
	var aw: String = "await " if is_coro else ""
	# The return annotation stays, or a strict-typed override in a mod subclass fails to
	# parse; an annotation (@rpc) belongs to the public name, the wrapper's now.
	var rt = fe["return_type"]
	var sig: String = "%sfunc %s(%s)%s:" % [str(fe.get("decl_prefix", "")), method_name, fe["params"],
			" -> " + rt if rt != null and rt != "" else ""]

	var i1: String = indent
	var i2: String = indent + indent
	var i3: String = indent + indent + indent

	var out := ""
	if not is_void:
		out += "%s\n" % sig
		# Engine.get_meta with a default still prints an error for an absent key.
		out += "%sif not Engine.has_meta(\"RTVModLib\"):\n" % i1
		out += "%sreturn %s%s\n" % [i2, aw, vanilla_call]
		out += "%svar _rtv_lib = Engine.get_meta(\"RTVModLib\")\n" % i1
		out += "%sif not _rtv_lib._any_mod_hooked:\n" % i1
		out += "%sreturn %s%s\n" % [i2, aw, vanilla_call]
		out += "%sif not _rtv_lib._hooked_bases.has(\"%s\"):\n" % [i1, hook_base]
		out += "%sreturn %s%s\n" % [i2, aw, vanilla_call]
		out += "%sif _rtv_lib._developer_mode:\n" % i1
		out += "%s_rtv_lib._dispatch_counts[\"%s\"] = int(_rtv_lib._dispatch_counts.get(\"%s\", 0)) + 1\n" % [i2, hook_base, hook_base]
		# Re-entry guard: a mod override whose body calls super() into this wrapper.
		out += "%svar _rtv_wa_key: String = str(get_instance_id()) + \":%s\"\n" % [i1, hook_base]
		out += "%sif _rtv_lib._wrapper_active.has(_rtv_wa_key):\n" % i1
		out += "%sreturn %s%s\n" % [i2, aw, vanilla_call]
		out += "%s_rtv_lib._wrapper_active[_rtv_wa_key] = true\n" % i1
		out += "%svar _rtv_prev_caller = _rtv_lib._caller\n" % i1
		out += "%s_rtv_lib._caller = self\n" % i1
		out += "%s_rtv_lib._dispatch(\"%s-pre\", %s)\n" % [i1, hook_base, args_array]
		out += "%svar _rtv_result\n" % i1
		out += "%svar _rtv_repl = _rtv_lib._get_hooks(\"%s\")\n" % [i1, hook_base]
		out += "%sif _rtv_repl.size() > 0:\n" % i1
		out += "%svar _rtv_prev_skip = _rtv_lib._skip_super\n" % i2
		out += "%s_rtv_lib._skip_super = false\n" % i2
		# Only through aw: a body holding `await` is a coroutine, and every caller of a
		# wrapped method would then fail to parse without await (both branches).
		out += "%svar _rtv_replret = %s_rtv_repl[0].callv(%s)\n" % [i2, aw, args_array]
		out += "%svar _rtv_did_skip = _rtv_lib._skip_super\n" % i2
		out += "%s_rtv_lib._skip_super = _rtv_prev_skip\n" % i2
		out += "%sif _rtv_did_skip:\n" % i2
		out += "%s_rtv_result = _rtv_replret\n" % i3
		out += "%selse:\n" % i2
		out += "%s_rtv_result = %s%s\n" % [i3, aw, vanilla_call]
		out += "%selse:\n" % i1
		out += "%s_rtv_result = %s%s\n" % [i2, aw, vanilla_call]
		out += "%s_rtv_lib._caller = self\n" % i1
		out += "%s_rtv_result = _rtv_lib._dispatch_post(\"%s-post\", %s, _rtv_result)\n" % [i1, hook_base, args_array]
		out += "%s_rtv_lib._dispatch_deferred(\"%s-callback\", %s)\n" % [i1, hook_base, args_array]
		out += "%s_rtv_lib._wrapper_active.erase(_rtv_wa_key)\n" % i1
		out += "%s_rtv_lib._caller = _rtv_prev_caller\n" % i1
		out += "%sreturn _rtv_result\n" % i1
	else:
		out += "%s\n" % sig
		out += "%sif not Engine.has_meta(\"RTVModLib\"):\n" % i1
		out += "%s%s%s\n" % [i2, aw, vanilla_call]
		out += "%sreturn\n" % i2
		out += "%svar _rtv_lib = Engine.get_meta(\"RTVModLib\")\n" % i1
		out += "%sif not _rtv_lib._any_mod_hooked:\n" % i1
		out += "%s%s%s\n" % [i2, aw, vanilla_call]
		out += "%sreturn\n" % i2
		out += "%sif not _rtv_lib._hooked_bases.has(\"%s\"):\n" % [i1, hook_base]
		out += "%s%s%s\n" % [i2, aw, vanilla_call]
		out += "%sreturn\n" % i2
		out += "%sif _rtv_lib._developer_mode:\n" % i1
		out += "%s_rtv_lib._dispatch_counts[\"%s\"] = int(_rtv_lib._dispatch_counts.get(\"%s\", 0)) + 1\n" % [i2, hook_base, hook_base]
		out += "%svar _rtv_wa_key: String = str(get_instance_id()) + \":%s\"\n" % [i1, hook_base]
		out += "%sif _rtv_lib._wrapper_active.has(_rtv_wa_key):\n" % i1
		out += "%s%s%s\n" % [i2, aw, vanilla_call]
		out += "%sreturn\n" % i2
		out += "%s_rtv_lib._wrapper_active[_rtv_wa_key] = true\n" % i1
		out += "%svar _rtv_prev_caller = _rtv_lib._caller\n" % i1
		out += "%s_rtv_lib._caller = self\n" % i1
		out += "%s_rtv_lib._dispatch(\"%s-pre\", %s)\n" % [i1, hook_base, args_array]
		out += "%svar _rtv_repl = _rtv_lib._get_hooks(\"%s\")\n" % [i1, hook_base]
		out += "%sif _rtv_repl.size() > 0:\n" % i1
		out += "%svar _rtv_prev_skip = _rtv_lib._skip_super\n" % i2
		out += "%s_rtv_lib._skip_super = false\n" % i2
		out += "%s%s_rtv_repl[0].callv(%s)\n" % [i2, aw, args_array]
		out += "%svar _rtv_did_skip = _rtv_lib._skip_super\n" % i2
		out += "%s_rtv_lib._skip_super = _rtv_prev_skip\n" % i2
		out += "%sif !_rtv_did_skip:\n" % i2
		out += "%s%s%s\n" % [i3, aw, vanilla_call]
		out += "%selse:\n" % i1
		out += "%s%s%s\n" % [i2, aw, vanilla_call]
		out += "%s_rtv_lib._caller = self\n" % i1
		out += "%s_rtv_lib._dispatch(\"%s-post\", %s)\n" % [i1, hook_base, args_array]
		out += "%s_rtv_lib._dispatch_deferred(\"%s-callback\", %s)\n" % [i1, hook_base, args_array]
		out += "%s_rtv_lib._wrapper_active.erase(_rtv_wa_key)\n" % i1
		out += "%s_rtv_lib._caller = _rtv_prev_caller\n" % i1
	return out
