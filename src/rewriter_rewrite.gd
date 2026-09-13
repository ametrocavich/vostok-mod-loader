# Inline source-rewrite generator. Renames each hookable method to
# _rtv_vanilla_<name> and appends a <name> wrapper that dispatches through
# RTVModLib hooks, then calls the renamed original.
#
# Rewrites the vanilla script in place rather than generating a wrapper
# class: shipped at res://Scripts/<Name>.gd it is the script Godot compiles
# for that path -- no extends chain, and no bug #83542 regardless of what
# mods do with take_over_path.
#
# Caller must pass pristine vanilla source; already-rewritten input
# produces duplicate-function parse errors.

func _rtv_rewrite_vanilla_source(source: String, parsed: Dictionary, method_mask: Dictionary = {}) -> String:
	# method_mask restricts which methods get renamed + wrapped. Empty =
	# wrap every non-static method (REGISTRY_TARGETS and the "[hooks]
	# <path> = *" wildcard); non-empty = wrap only declared methods, the
	# rest stay vanilla with no dispatch overhead.
	var apply_mask: bool = not method_mask.is_empty()
	var hookable: Array = []
	for fe in parsed["functions"]:
		if fe["is_static"]:
			continue
		# Mask keys are lowercased (see add_hook() in hooks_api.gd), so
		# "updatetooltip" matches vanilla "UpdateToolTip".
		if apply_mask and not method_mask.has(fe["name"].to_lower()):
			continue
		hookable.append(fe)

	# Warn on any declared hook method with no matching non-static vanilla
	# method; otherwise the hook silently never fires.
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

	var hookable_names: Dictionary = {}
	for fe in hookable:
		hookable_names[fe["name"]] = true

	# IXP ships CRLF source; the appended wrappers use LF. Mixed endings
	# make GDScript's parser raise a misleading "tab character for
	# indentation" error, so strip all CR up front.
	var src: String = source.replace("\r\n", "\n").replace("\r", "\n")

	# Repair Godot-3-era syntax before the rename+wrapper pipeline so every
	# downstream step sees valid source. No-op for clean files.
	var autofix := _rtv_autofix_legacy_syntax(src)
	src = autofix["source"]
	var af_total: int = int(autofix["bodyless"]) + int(autofix["tool"]) \
			+ int(autofix["onready"]) + int(autofix["export"]) + int(autofix.get("base", 0))
	if af_total > 0:
		_log_info("[Autofix] %s: %d bodyless, %d @tool, %d @onready, %d @export, %d base()->super -- legacy syntax normalized" \
				% [parsed.get("filename", "?"), autofix["bodyless"], autofix["tool"], autofix["onready"], autofix["export"], autofix.get("base", 0)])

	# Per-script declaration transforms: make compile-time-immutable
	# declarations runtime-mutable so the registry can swap them. Details
	# live on each transform function in rewriter_registry_inject.gd.
	var fn: String = parsed.get("filename", "")
	if fn == "Database.gd":
		src = _rtv_rewrite_database_constants(src)
	elif fn == "Loader.gd":
		src = _rtv_rewrite_loader_shelters(src)
	elif fn == "AISpawner.gd":
		src = _rtv_rewrite_aispawner_agent_assignments(src)

	# Pass 1: rename top-level "func <name>(" to "func _rtv_vanilla_<name>("
	# and rewrite bare super() calls in that body to super.<name>().
	# Inner-class (indented) methods keep their names. class_name stays
	# intact: scripts ship at res://Scripts/<Name>.gd matching the PCK's
	# class-cache registration, and extends-by-path needs it to resolve.
	#
	# super() means "parent's version of the current function"; after the
	# rename it would resolve to _rtv_vanilla_<name> on the parent, which
	# doesn't exist. super.<explicit>() passes through untouched.
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

	# If the rename pass missed a hookable method, the wrapper appended
	# below duplicates the still-unrenamed vanilla method and the whole
	# script fails to compile. Log at generation time, with the cause,
	# instead of leaving a bare engine parse error.
	for fe in hookable:
		if not renamed_methods.has(fe["name"]):
			_log_critical("[RTVCodegen] %s: internal rename failure on method '%s' -- the rewritten script will fail to compile and ALL hooks on this script are disabled. Please report this modloader bug (include game version)." \
					% [parsed.get("filename", "?"), str(fe["name"])])

	# Pass 1.5: prelude injection at the top of specific vanilla function
	# bodies (post-rename, so targets are _rtv_vanilla_<Name>).
	var indent := _detect_indent_style(src)
	lines = _rtv_apply_prelude_injections(parsed.get("filename", ""), lines, "_rtv_vanilla_", indent)

	# Pass 2: append dispatch wrappers at EOF, matching the source's indent
	# style (see _detect_indent_style).
	var prefix := _rtv_script_hook_prefix(parsed["filename"])
	var appended := "\n\n# --- Metro mod loader inline hook dispatch wrappers ---\n"
	for fe in hookable:
		appended += _rtv_dispatch_inline_src(fe, prefix, indent) + "\n"

	# Per-script registry injections (gated upstream by REGISTRY_TARGETS).
	appended += _rtv_registry_injection(parsed["filename"], indent)

	return "\n".join(lines) + appended

# Rewrite bare `super(` / `super (` to `super.<method>(`, preserving the
# rest of the line. Skips `super.<something>(` and anything at/after the
# first `#`. String literals are not tracked: a "super(" inside a string
# would be rewritten (text only, never code structure); detokenized vanilla
# input makes this a non-case.
func _rewrite_bare_super(line: String, method_name: String) -> String:
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
		# Whole word only: a preceding alnum/_/. means it isn't a super call.
		if idx > 0:
			var prev := out[idx - 1]
			if prev == "." or prev == "_" or prev.to_upper() != prev.to_lower() \
					or (prev >= "0" and prev <= "9"):
				cursor = idx + 5
				continue
		var after := idx + 5
		while after < out.length() and out[after] == " ":
			after += 1
		if after >= out.length() or out[after] != "(":
			cursor = idx + 5
			continue
		var before := out.substr(0, idx)
		var rest := out.substr(after)  # from "("
		out = before + "super." + method_name + rest
		var delta := 1 + method_name.length()  # added ".<name>"
		cursor = idx + 5 + delta + 1  # past "super.<name>("
		scan_end += delta
	return out

# Return the leading whitespace of the first indented line as the indent
# unit (tab fallback). Generated code must match the file's style because
# GDScript forbids mixing tabs and spaces; IXP uses 4-space, vanilla RTV tabs.
func _detect_indent_style(source: String) -> String:
	for line: String in source.split("\n"):
		if line.is_empty():
			continue
		var ch: String = line[0]
		if ch != "\t" and ch != " ":
			continue
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

# Produces one inline dispatch wrapper that calls _rtv_vanilla_<name>(...),
# living in the same class as the renamed body (no inheritance chain).

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

	# Preserve the return type annotation: without it callers infer Variant,
	# and strict-typed var decls in mod subclasses fail to parse.
	var return_annot: String = ""
	var rt = fe.get("return_type")
	if rt != null and not (rt as String).is_empty():
		return_annot = " -> " + (rt as String)
	var sig: String = "func %s()%s:" % [method_name, return_annot] if params.is_empty() \
			else "func %s(%s)%s:" % [method_name, params, return_annot]

	var I1: String = indent
	var I2: String = indent + indent
	var I3: String = indent + indent + indent

	var out := ""
	# Re-entry guard (_wrapper_active): a mod wrapper whose body calls
	# super() into vanilla's wrapper would dispatch again; the nested call
	# runs just the vanilla body. One dispatch per logical call.
	if not is_void:
		out += "%s\n" % sig
		# Engine.get_meta with a Nil default still prints an error when the
		# key is absent (Godot 4.6 object.cpp:1155); has_meta keeps
		# early-boot wrappers quiet before _register_rtv_modlib_meta runs.
		out += "%sif not Engine.has_meta(\"RTVModLib\"):\n" % I1
		out += "%sreturn %s%s\n" % [I2, aw, vanilla_call]
		out += "%svar _lib = Engine.get_meta(\"RTVModLib\")\n" % I1
		# Short-circuit when no mod has called hook() this session.
		out += "%sif not _lib._any_mod_hooked:\n" % I1
		out += "%sreturn %s%s\n" % [I2, aw, vanilla_call]
		# Per-hook-base short-circuit: _any_mod_hooked is sticky-true, but
		# most wrapped methods still have no hooks of their own.
		out += "%sif not _lib._hooked_bases.has(\"%s\"):\n" % [I1, hook_base]
		out += "%sreturn %s%s\n" % [I2, aw, vanilla_call]
		# Dev-mode dispatch counter; surfaces runaway method calls in the
		# 30s top-15 summary. Non-dev cost is one branch per dispatch.
		out += "%sif _lib._developer_mode:\n" % I1
		out += "%s_lib._dispatch_counts[\"%s\"] = int(_lib._dispatch_counts.get(\"%s\", 0)) + 1\n" % [I2, hook_base, hook_base]
		out += "%svar _rtv_wa_key: String = str(get_instance_id()) + \":%s\"\n" % [I1, hook_base]
		out += "%sif _lib._wrapper_active.has(_rtv_wa_key):\n" % I1
		out += "%sreturn %s%s\n" % [I2, aw, vanilla_call]
		out += "%s_lib._wrapper_active[_rtv_wa_key] = true\n" % I1
		# Save/restore _caller so nested wrappers don't leak stale values;
		# re-set before post-dispatch so post hooks see the right caller.
		out += "%svar _rtv_prev_caller = _lib._caller\n" % I1
		out += "%s_lib._caller = self\n" % I1
		out += "%s_lib._dispatch(\"%s-pre\", %s)\n" % [I1, hook_base, args_array]
		out += "%svar _result\n" % I1
		out += "%svar _repl = _lib._get_hooks(\"%s\")\n" % [I1, hook_base]
		out += "%sif _repl.size() > 0:\n" % I1
		out += "%svar _prev_skip = _lib._skip_super\n" % I2
		out += "%s_lib._skip_super = false\n" % I2
		# `await` must stay gated on is_coro: any body containing `await` is
		# itself a coroutine in GDScript, so an unconditional await here
		# marks every wrapped method a coroutine and all existing callers
		# fail at parse time with "must be called with await".
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
		# Post hooks get args + [_result]; a non-null return replaces
		# _result for downstream callbacks. See hooks_api._dispatch_post.
		out += "%s_result = _lib._dispatch_post(\"%s-post\", %s, _result)\n" % [I1, hook_base, args_array]
		out += "%s_lib._dispatch_deferred(\"%s-callback\", %s)\n" % [I1, hook_base, args_array]
		out += "%s_lib._wrapper_active.erase(_rtv_wa_key)\n" % I1
		out += "%s_lib._caller = _rtv_prev_caller\n" % I1
		out += "%sreturn _result\n" % I1
	else:
		out += "%s\n" % sig
		# Same guards and short-circuits as the non-void branch above.
		out += "%sif not Engine.has_meta(\"RTVModLib\"):\n" % I1
		out += "%s%s%s\n" % [I2, aw, vanilla_call]
		out += "%sreturn\n" % I2
		out += "%svar _lib = Engine.get_meta(\"RTVModLib\")\n" % I1
		out += "%sif not _lib._any_mod_hooked:\n" % I1
		out += "%s%s%s\n" % [I2, aw, vanilla_call]
		out += "%sreturn\n" % I2
		out += "%sif not _lib._hooked_bases.has(\"%s\"):\n" % [I1, hook_base]
		out += "%s%s%s\n" % [I2, aw, vanilla_call]
		out += "%sreturn\n" % I2
		out += "%sif _lib._developer_mode:\n" % I1
		out += "%s_lib._dispatch_counts[\"%s\"] = int(_lib._dispatch_counts.get(\"%s\", 0)) + 1\n" % [I2, hook_base, hook_base]
		out += "%svar _rtv_wa_key: String = str(get_instance_id()) + \":%s\"\n" % [I1, hook_base]
		out += "%sif _lib._wrapper_active.has(_rtv_wa_key):\n" % I1
		out += "%s%s%s\n" % [I2, aw, vanilla_call]
		out += "%sreturn\n" % I2
		out += "%s_lib._wrapper_active[_rtv_wa_key] = true\n" % I1
		out += "%svar _rtv_prev_caller = _lib._caller\n" % I1
		out += "%s_lib._caller = self\n" % I1
		out += "%s_lib._dispatch(\"%s-pre\", %s)\n" % [I1, hook_base, args_array]
		out += "%svar _repl = _lib._get_hooks(\"%s\")\n" % [I1, hook_base]
		out += "%sif _repl.size() > 0:\n" % I1
		out += "%svar _prev_skip = _lib._skip_super\n" % I2
		out += "%s_lib._skip_super = false\n" % I2
		# Same await gating as the non-void branch above.
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

