## ----- rewriter.gd -----
## Source-rewrite codegen. Given detokenized vanilla source + a parse
## structure, produces a rewritten script where each non-static method is
## renamed to _rtv_vanilla_<name> and dispatch wrappers are appended at the
## original names. The wrappers fire pre/replace/post/callback hooks and
## call the renamed body. Also rewrites mod subclass scripts (Step C) with
## _rtv_mod_ prefix so hooks fire even when mods bypass super().
##
## Also owns: regex compilation, parse-script, autofix legacy syntax,
## indent detection, bare-super rewriting, mod-subclass scanning.
##
## Historical note: the legacy _rtv_generate_override function emits
## Framework<Name>.gd subclass wrappers (same output shape as tetra's Rust
## codegen over a gdre_tools decompile, modulo line endings). Retained for
## the extends-wrapper fallback path; the main rewriter emits inline
## dispatch wrappers instead.

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

# Mod metadata collection (no mounting)


func _rtv_compile_codegen_regex() -> void:
	if _rtv_re_extends != null:
		return
	_rtv_re_extends = RegEx.new()
	_rtv_re_extends.compile('^extends\\s+"?([\\w/.:"]+)"?')
	_rtv_re_class_name = RegEx.new()
	_rtv_re_class_name.compile('^class_name\\s+(\\w+)')
	_rtv_re_func = RegEx.new()
	_rtv_re_func.compile('^func\\s+(\\w+)\\s*\\(([^)]*)\\)(\\s*->\\s*([\\w\\[\\]]+))?\\s*:')
	_rtv_re_static_func = RegEx.new()
	_rtv_re_static_func.compile('^static\\s+func\\s+(\\w+)\\s*\\(([^)]*)\\)(\\s*->\\s*([\\w\\[\\]]+))?\\s*:')
	_rtv_re_var = RegEx.new()
	_rtv_re_var.compile('^(?:@export\\s+)?var\\s+(\\w+)')

func _rtv_extract_param_names(params: String) -> Array:
	var names: Array = []
	if params.strip_edges().is_empty():
		return names
	for p in params.split(","):
		var trimmed := (p as String).strip_edges()
		var without_type := trimmed.split(":")[0]
		var without_default := (without_type as String).split("=")[0]
		var name := (without_default as String).strip_edges()
		if not name.is_empty():
			names.append(name)
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
		var trimmed := line.strip_edges()

		var m_ext := _rtv_re_extends.search(trimmed)
		if m_ext != null:
			script["extends"] = m_ext.get_string(1)

		var m_cn := _rtv_re_class_name.search(trimmed)
		if m_cn != null:
			script["class_name"] = m_cn.get_string(1)

		# Top-level var names (line starts with "var" / "@export var" -- no leading indent).
		if not line.begins_with("\t") and not line.begins_with(" "):
			var m_var := _rtv_re_var.search(trimmed)
			if m_var != null:
				(script["var_names"] as Array).append(m_var.get_string(1))

		var m_sfunc := _rtv_re_static_func.search(trimmed)
		if m_sfunc != null:
			var ret_group = m_sfunc.get_string(4) if m_sfunc.get_start(4) != -1 else null
			func_starts.append([
				line_num, m_sfunc.get_string(1), m_sfunc.get_string(2),
				_rtv_extract_param_names(m_sfunc.get_string(2)), true,
				ret_group,
			])
			continue

		var m_func := _rtv_re_func.search(trimmed)
		if m_func != null:
			var ret_group2 = m_func.get_string(4) if m_func.get_start(4) != -1 else null
			func_starts.append([
				line_num, m_func.get_string(1), m_func.get_string(2),
				_rtv_extract_param_names(m_func.get_string(2)), false,
				ret_group2,
			])

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
			var body_line := lines[i].strip_edges()
			if "await " in body_line:
				is_coroutine = true
			# "return <something>" (not bare "return").
			if body_line.begins_with("return ") and body_line.length() > 7:
				has_return_value = true

		# Explicit return type override (void → no value; anything else → has value).
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

# Produce one Framework<Name>.gd source. Three method templates (matching
# generate_override in the Rust):
#   _ready   -- has a _rtv_ready_done flag so super() doesn't double-fire
#   non-void -- returns a value
#   void    -- engine lifecycle methods, or bodies with no `return <expr>`
func _rtv_generate_override(script: Dictionary) -> String:
	var out := ""
	var prefix := _rtv_script_hook_prefix(script["filename"])
	out += 'extends "%s"\n' % script["path"]

	var has_ready := false
	for func_entry in script["functions"]:
		if func_entry["name"] == "_ready" and not func_entry["is_static"]:
			has_ready = true
			break
	if has_ready:
		out += "var _rtv_ready_done = false\n"
	out += "\n"

	for func_entry in script["functions"]:
		if func_entry["is_static"]:
			continue

		var method_name: String = func_entry["name"]
		var hook_base := "%s-%s" % [prefix, method_name.to_lower()]
		var params: String = func_entry["params"]
		var param_names_str := ", ".join(func_entry["param_names"])

		var sig: String
		if params.is_empty():
			sig = "func %s():" % method_name
		else:
			sig = "func %s(%s):" % [method_name, params]

		var super_call: String
		if param_names_str.is_empty():
			super_call = "super()"
		else:
			super_call = "super(%s)" % param_names_str

		var args_array: String
		if param_names_str.is_empty():
			args_array = "[]"
		else:
			args_array = "[%s]" % param_names_str

		var is_engine_void: bool = method_name in RTV_ENGINE_VOID_METHODS
		var is_void: bool = is_engine_void or not bool(func_entry["has_return_value"])
		var is_ready: bool = method_name == "_ready"

		if is_ready:
			out += "%s\n" % sig
			out += "\tvar _lib = Engine.get_meta(\"RTVModLib\") if Engine.has_meta(\"RTVModLib\") else null\n"
			out += "\tif !_lib:\n"
			out += "\t\tif not _rtv_ready_done:\n"
			out += "\t\t\t%s\n" % super_call
			out += "\t\t\t_rtv_ready_done = true\n"
			out += "\t\treturn\n"
			out += "\t_lib._caller = self\n"
			out += "\t_lib._dispatch(\"%s-pre\", %s)\n" % [hook_base, args_array]
			out += "\tvar _repl = _lib._get_hooks(\"%s\")\n" % hook_base
			out += "\tif _repl.size() > 0:\n"
			out += "\t\tvar _prev_skip = _lib._skip_super\n"
			out += "\t\t_lib._skip_super = false\n"
			out += "\t\t_repl[0].callv(%s)\n" % args_array
			out += "\t\tvar _did_skip = _lib._skip_super\n"
			out += "\t\t_lib._skip_super = _prev_skip\n"
			out += "\t\tif !_did_skip and not _rtv_ready_done:\n"
			out += "\t\t\t%s\n" % super_call
			out += "\t\t\t_rtv_ready_done = true\n"
			out += "\telse:\n"
			out += "\t\tif not _rtv_ready_done:\n"
			out += "\t\t\t%s\n" % super_call
			out += "\t\t\t_rtv_ready_done = true\n"
			out += "\t_lib._dispatch(\"%s-post\", %s)\n" % [hook_base, args_array]
			out += "\t_lib._dispatch_deferred(\"%s-callback\", %s)\n\n" % [hook_base, args_array]
		elif not is_void:
			out += "%s\n" % sig
			out += "\tvar _lib = Engine.get_meta(\"RTVModLib\") if Engine.has_meta(\"RTVModLib\") else null\n"
			out += "\tif !_lib:\n"
			out += "\t\treturn %s\n" % super_call
			out += "\t_lib._caller = self\n"
			out += "\t_lib._dispatch(\"%s-pre\", %s)\n" % [hook_base, args_array]
			out += "\tvar _result\n"
			out += "\tvar _repl = _lib._get_hooks(\"%s\")\n" % hook_base
			out += "\tif _repl.size() > 0:\n"
			out += "\t\tvar _prev_skip = _lib._skip_super\n"
			out += "\t\t_lib._skip_super = false\n"
			out += "\t\tvar _replret = _repl[0].callv(%s)\n" % args_array
			out += "\t\tvar _did_skip = _lib._skip_super\n"
			out += "\t\t_lib._skip_super = _prev_skip\n"
			out += "\t\tif _did_skip:\n"
			out += "\t\t\t_result = _replret\n"
			out += "\t\telse:\n"
			out += "\t\t\t_result = %s\n" % super_call
			out += "\telse:\n"
			out += "\t\t_result = %s\n" % super_call
			out += "\t_lib._dispatch(\"%s-post\", %s)\n" % [hook_base, args_array]
			out += "\t_lib._dispatch_deferred(\"%s-callback\", %s)\n" % [hook_base, args_array]
			out += "\treturn _result\n\n"
		else:
			out += "%s\n" % sig
			out += "\tvar _lib = Engine.get_meta(\"RTVModLib\") if Engine.has_meta(\"RTVModLib\") else null\n"
			out += "\tif !_lib:\n"
			out += "\t\t%s\n" % super_call
			out += "\t\treturn\n"
			out += "\t_lib._caller = self\n"
			out += "\t_lib._dispatch(\"%s-pre\", %s)\n" % [hook_base, args_array]
			out += "\tvar _repl = _lib._get_hooks(\"%s\")\n" % hook_base
			out += "\tif _repl.size() > 0:\n"
			out += "\t\tvar _prev_skip = _lib._skip_super\n"
			out += "\t\t_lib._skip_super = false\n"
			out += "\t\t_repl[0].callv(%s)\n" % args_array
			out += "\t\tvar _did_skip = _lib._skip_super\n"
			out += "\t\t_lib._skip_super = _prev_skip\n"
			out += "\t\tif !_did_skip:\n"
			out += "\t\t\t%s\n" % super_call
			out += "\telse:\n"
			out += "\t\t%s\n" % super_call
			out += "\t_lib._dispatch(\"%s-post\", %s)\n" % [hook_base, args_array]
			out += "\t_lib._dispatch_deferred(\"%s-callback\", %s)\n\n" % [hook_base, args_array]

	return out

# Inline source-rewrite generator (Option C / Phase 1 Step A).
#
# Produces the full rewritten source of a vanilla script where each hookable
# method <name> is renamed to _rtv_vanilla_<name> and a new <name> method is
# appended that dispatches through RTVModLib hooks, then calls the renamed
# original.
#
# Unlike _rtv_generate_override which produces a separate wrapper class that
# extends vanilla, this rewrites the vanilla script itself. When shipped at
# res://Scripts/<Name>.gd via a hook pack, it becomes the script Godot compiles
# for that path -- no extends chain, no class_name registry asymmetry, no bug
# #83542 regardless of what mods do with take_over_path.
#
# Caller MUST pass pristine vanilla source (e.g. from .gdc bytecode via
# _read_vanilla_source / _detokenize_script). Passing already-rewritten source
# produces duplicate-function parse errors.

func _rtv_rewrite_vanilla_source(source: String, parsed: Dictionary, rename_prefix: String = "_rtv_vanilla_") -> String:
	# rename_prefix defaults to "_rtv_vanilla_" for vanilla scripts.
	# Mod subclasses pass "_rtv_mod_" so the renamed mod body doesn't shadow
	# vanilla's renamed body via virtual dispatch. Without this: mod's body
	# is _rtv_vanilla_<name>, vanilla's body is ALSO _rtv_vanilla_<name>, and
	# vanilla's wrapper calls _rtv_vanilla_<name>() on self -- which is a mod
	# instance -- which dispatches to mod's body again. Infinite loop.
	var hookable: Array = []
	for fe in parsed["functions"]:
		if fe["is_static"]:
			continue
		hookable.append(fe)
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
			+ int(autofix["onready"]) + int(autofix["export"])
	if af_total > 0:
		_log_info("[Autofix] %s: %d bodyless block(s), %d @tool, %d @onready, %d @export -- legacy syntax normalized" \
				% [parsed.get("filename", "?"), autofix["bodyless"], autofix["tool"], autofix["onready"], autofix["export"]])

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
						lines[i] = "func " + rename_prefix + method_name + line.substr(name_end)
						current_hooked_method = method_name
			continue
		# Indented line: inside some block. If inside a renamed method, rewrite
		# bare super( / super ( to super.<orig_name>( so it still resolves.
		if current_hooked_method.is_empty():
			continue
		if not ("super" in line):
			continue
		lines[i] = _rewrite_bare_super(line, current_hooked_method)

	# Pass 2: append dispatch wrappers at EOF. Match the source's indent
	# style -- GDScript rejects tab/space mixing in a single file. IXP uses
	# 4-space indent; vanilla RTV uses tabs.
	var indent := _detect_indent_style(src)
	var prefix := _rtv_script_hook_prefix(parsed["filename"])
	var appended := "\n\n# --- Metro mod loader inline hook dispatch wrappers ---\n"
	for fe in hookable:
		appended += _rtv_dispatch_inline_src(fe, prefix, indent, rename_prefix) + "\n"

	return "\n".join(lines) + appended

# Rewrite bare `super(` / `super (` in a line to `super.<method>(`. Preserves
# the rest of the line verbatim. Skips `super.<something>(` (already explicit),
# and skips occurrences inside strings or comments by stopping at the first
# `#` or quote. Called per-line within a renamed method's body.
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

# Detects whether a stripped line is a block-opening header (ends with ':'
# and starts with a block keyword). Used by _rtv_autofix_legacy_syntax to
# decide where to inject a `pass` when a block body is missing.
func _rtv_is_block_header(trimmed: String) -> bool:
	if not trimmed.ends_with(":"):
		return false
	if trimmed == "else:":
		return true
	for kw in ["if ", "elif ", "for ", "while ", "match ", "func ", "class "]:
		if trimmed.begins_with(kw):
			return true
	if trimmed.begins_with("static func "):
		return true
	return false

# MAXIMUM-COMPAT PASS: rewrite sloppy / Godot-3-era GDScript patterns that
# Godot 4's parser rejects outright. Runs before our dispatch-wrapper
# pipeline so every downstream step sees parser-acceptable source.
#
# Handles:
#   (1) Bodyless block headers (`if X:` with no indented body) -- the
#       dominant failure mode in real-world mods (Gotcha #5). Godot 4's
#       parser raises "Expected indented block after 'X' block". We scan
#       forward from each block header; if the next non-blank non-comment
#       line is NOT indented deeper than the header, we inject a `pass`
#       at header_indent + indent_unit. Semantically safe: the empty
#       block was already a no-op in the author's intent (or a latent
#       bug -- we preserve original semantics either way).
#   (2) `tool` first-line keyword -> `@tool` annotation (Godot 4 moved
#       it to the annotation namespace).
#   (3) `onready var` -> `@onready var` (same annotation move).
#   (4) `export var X = Y` (no type paren) -> `@export var X = Y`. Skips
#       `export(Type) var ...` -- that needs type-annotation transform
#       (risky, can break strict-typed references; leave for future
#       pass if a real mod trips it).
#
# Source must be LF-normalized by the caller.
func _rtv_autofix_legacy_syntax(source: String) -> Dictionary:
	var lines: PackedStringArray = source.split("\n")
	var out: PackedStringArray = PackedStringArray()
	var indent_unit := _detect_indent_style(source)
	var fix_bodyless := 0
	var fix_tool := 0
	var fix_onready := 0
	var fix_export := 0

	for i in lines.size():
		var line: String = lines[i]

		# Annotation migrations (line-local rewrites).
		var lead := _rtv_leading_indent(line)
		var body_text := line.substr(lead.length())
		if i == 0 and body_text.strip_edges() == "tool":
			line = lead + "@tool"
			fix_tool += 1
		elif body_text.begins_with("onready var "):
			line = lead + "@onready var " + body_text.substr(12)  # len("onready var ")
			fix_onready += 1
		elif body_text.begins_with("export var "):
			line = lead + "@export var " + body_text.substr(11)  # len("export var ")
			fix_export += 1

		out.append(line)

		# Bodyless-block detection on post-annotation line.
		var trimmed := line.strip_edges()
		if not _rtv_is_block_header(trimmed):
			continue
		var header_indent := _rtv_leading_indent(line)
		var j := i + 1
		var has_body := false
		while j < lines.size():
			var next_line: String = lines[j]
			var next_trimmed := next_line.strip_edges()
			if next_trimmed.is_empty():
				j += 1
				continue
			if next_trimmed.begins_with("#"):
				j += 1
				continue
			var next_indent := _rtv_leading_indent(next_line)
			if next_indent.length() > header_indent.length() \
					and next_indent.begins_with(header_indent):
				has_body = true
			break
		if not has_body:
			out.append(header_indent + indent_unit + "pass  # [Autofix] injected -- original block had no body")
			fix_bodyless += 1

	return {
		"source": "\n".join(out),
		"bodyless": fix_bodyless,
		"tool": fix_tool,
		"onready": fix_onready,
		"export": fix_export,
	}

# Produces ONE inline dispatch wrapper that calls _rtv_vanilla_<name>(...).
#
# Mirrors _rtv_generate_override's templates but:
#  - calls _rtv_vanilla_<name>(...) instead of super(...)
#  - no _rtv_ready_done flag (same class, no inheritance-chain double-fire)
#  - prepends `await` when the vanilla method is a coroutine

func _rtv_dispatch_inline_src(fe: Dictionary, prefix: String, indent: String = "\t", rename_prefix: String = "_rtv_vanilla_") -> String:
	var method_name: String = fe["name"]
	var params: String = fe["params"]
	var param_names_str: String = ", ".join(fe["param_names"])
	var hook_base: String = "%s-%s" % [prefix, method_name.to_lower()]
	var vanilla_call: String = "%s%s(%s)" % [rename_prefix, method_name, param_names_str]
	var args_array: String = "[]" if param_names_str.is_empty() else "[%s]" % param_names_str
	var is_coro: bool = bool(fe["is_coroutine"])
	var is_engine_void: bool = method_name in RTV_ENGINE_VOID_METHODS
	var is_void: bool = is_engine_void or not bool(fe["has_return_value"])
	var aw: String = "await " if is_coro else ""

	var sig: String = "func %s():" % method_name if params.is_empty() \
			else "func %s(%s):" % [method_name, params]

	# Indent levels. GDScript requires consistent tabs-or-spaces per file;
	# IXP uses 4-space, vanilla RTV uses tabs. Caller passes the source's
	# detected indent so the emitted wrapper matches.
	var I1: String = indent
	var I2: String = indent + indent
	var I3: String = indent + indent + indent

	var out := ""
	# Dispatch-live probe: one counter per hook_base via Engine meta dict,
	# plus a one-shot print the first time each wrapper fires. That
	# gives a definitive list of every wrapper that executes at runtime
	# AND proves the wrapper body actually runs (not just that source
	# matches). Remove in Step E.
	var probe: String = ""
	probe += "%svar _rtv_bh = Engine.get_meta(\"_rtv_dispatch_by_hook\", {}) as Dictionary\n" % I1
	probe += "%svar _rtv_prev = int(_rtv_bh.get(\"%s\", 0))\n" % [I1, hook_base]
	probe += "%s_rtv_bh[\"%s\"] = _rtv_prev + 1\n" % [I1, hook_base]
	probe += "%sEngine.set_meta(\"_rtv_dispatch_by_hook\", _rtv_bh)\n" % I1
	probe += "%sEngine.set_meta(\"_rtv_dispatch_count\", int(Engine.get_meta(\"_rtv_dispatch_count\", 0)) + 1)\n" % I1
	probe += "%sif _rtv_prev == 0:\n" % I1
	probe += "%sprint(\"[RTV-WRAPPER-FIRST] %s\")\n" % [I2, hook_base]
	# Step C re-entry guard: when a mod's rewritten wrapper fires and its body
	# calls super() into vanilla's rewritten wrapper, the nested wrapper would
	# dispatch again. Guard checks _lib._wrapper_active for this hook_base and
	# if already set, skips ALL dispatch + replace lookup and just runs the
	# vanilla body. One dispatch per logical call regardless of chain depth.
	if not is_void:
		out += "%s\n" % sig
		out += probe
		out += "%svar _lib = Engine.get_meta(\"RTVModLib\") if Engine.has_meta(\"RTVModLib\") else null\n" % I1
		out += "%sif !_lib:\n" % I1
		out += "%sEngine.set_meta(\"_rtv_dispatch_no_lib\", int(Engine.get_meta(\"_rtv_dispatch_no_lib\", 0)) + 1)\n" % I2
		out += "%sreturn %s%s\n" % [I2, aw, vanilla_call]
		# Global short-circuit: if no mod has called hook() this session, the
		# whole dispatch pipeline is dead weight. Single bool check skips
		# ~10 dict ops + meta/prop/fn calls. Matches godot-mod-loader.
		out += "%sif not _lib._any_mod_hooked:\n" % I1
		out += "%sreturn %s%s\n" % [I2, aw, vanilla_call]
		out += "%sif _lib._wrapper_active.has(\"%s\"):\n" % [I1, hook_base]
		out += "%sreturn %s%s\n" % [I2, aw, vanilla_call]
		out += "%s_lib._wrapper_active[\"%s\"] = true\n" % [I1, hook_base]
		out += "%s_lib._caller = self\n" % I1
		out += "%s_lib._dispatch(\"%s-pre\", %s)\n" % [I1, hook_base, args_array]
		out += "%svar _result\n" % I1
		out += "%svar _repl = _lib._get_hooks(\"%s\")\n" % [I1, hook_base]
		out += "%sif _repl.size() > 0:\n" % I1
		out += "%svar _prev_skip = _lib._skip_super\n" % I2
		out += "%s_lib._skip_super = false\n" % I2
		out += "%svar _replret = _repl[0].callv(%s)\n" % [I2, args_array]
		out += "%svar _did_skip = _lib._skip_super\n" % I2
		out += "%s_lib._skip_super = _prev_skip\n" % I2
		out += "%sif _did_skip:\n" % I2
		out += "%s_result = _replret\n" % I3
		out += "%selse:\n" % I2
		out += "%s_result = %s%s\n" % [I3, aw, vanilla_call]
		out += "%selse:\n" % I1
		out += "%s_result = %s%s\n" % [I2, aw, vanilla_call]
		out += "%s_lib._dispatch(\"%s-post\", %s)\n" % [I1, hook_base, args_array]
		out += "%s_lib._dispatch_deferred(\"%s-callback\", %s)\n" % [I1, hook_base, args_array]
		out += "%s_lib._wrapper_active.erase(\"%s\")\n" % [I1, hook_base]
		out += "%sreturn _result\n" % I1
	else:
		out += "%s\n" % sig
		out += probe
		out += "%svar _lib = Engine.get_meta(\"RTVModLib\") if Engine.has_meta(\"RTVModLib\") else null\n" % I1
		out += "%sif !_lib:\n" % I1
		out += "%sEngine.set_meta(\"_rtv_dispatch_no_lib\", int(Engine.get_meta(\"_rtv_dispatch_no_lib\", 0)) + 1)\n" % I2
		out += "%s%s%s\n" % [I2, aw, vanilla_call]
		out += "%sreturn\n" % I2
		# Global short-circuit: see non-void branch above.
		out += "%sif not _lib._any_mod_hooked:\n" % I1
		out += "%s%s%s\n" % [I2, aw, vanilla_call]
		out += "%sreturn\n" % I2
		out += "%sif _lib._wrapper_active.has(\"%s\"):\n" % [I1, hook_base]
		out += "%s%s%s\n" % [I2, aw, vanilla_call]
		out += "%sreturn\n" % I2
		out += "%s_lib._wrapper_active[\"%s\"] = true\n" % [I1, hook_base]
		out += "%s_lib._caller = self\n" % I1
		out += "%s_lib._dispatch(\"%s-pre\", %s)\n" % [I1, hook_base, args_array]
		out += "%svar _repl = _lib._get_hooks(\"%s\")\n" % [I1, hook_base]
		out += "%sif _repl.size() > 0:\n" % I1
		out += "%svar _prev_skip = _lib._skip_super\n" % I2
		out += "%s_lib._skip_super = false\n" % I2
		out += "%s_repl[0].callv(%s)\n" % [I2, args_array]
		out += "%svar _did_skip = _lib._skip_super\n" % I2
		out += "%s_lib._skip_super = _prev_skip\n" % I2
		out += "%sif !_did_skip:\n" % I2
		out += "%s%s%s\n" % [I3, aw, vanilla_call]
		out += "%selse:\n" % I1
		out += "%s%s%s\n" % [I2, aw, vanilla_call]
		out += "%s_lib._dispatch(\"%s-post\", %s)\n" % [I1, hook_base, args_array]
		out += "%s_lib._dispatch_deferred(\"%s-callback\", %s)\n" % [I1, hook_base, args_array]
		out += "%s_lib._wrapper_active.erase(\"%s\")\n" % [I1, hook_base]
	return out

# Step C: mod-script extends scanner. For each enabled mod, walk the archive
# looking for .gd files whose first non-trivial line is extends-by-literal
# "res://Scripts/<X>.gd" where <X> is a vanilla script we already rewrite.
# Those mod scripts get the same rename+dispatch-wrapper treatment, shipped
# at their own res:// path, so hooks fire even when the mod replaces a
# method without calling super().
#
# Returns Array of Dictionary: { mod_name, res_path, vanilla_filename,
# source, load_index }. res_path is the mod's path (res://ModDir/X.gd),
# vanilla_filename keys hook dispatch prefix ("Controller.gd" -> "controller").
func _scan_mod_extends_targets(vanilla_filenames: Dictionary) -> Array:
	var candidates: Array = []
	var entries := _ui_mod_entries.duplicate()
	entries.sort_custom(_compare_load_order)
	var load_index := 0
	for entry: Dictionary in entries:
		if not entry["enabled"]:
			continue
		var mod_name: String = entry["mod_name"]
		var archive_path: String = entry["full_path"]
		var ext: String = entry["ext"]
		# Resolve to zip path for ZIPReader access.
		var abs_archive: String = archive_path
		if ext == "vmz":
			var cache_dir := ProjectSettings.globalize_path(TMP_DIR)
			var cached := cache_dir.path_join(archive_path.get_file().get_basename() + ".zip")
			if not FileAccess.file_exists(cached):
				load_index += 1
				continue
			abs_archive = cached
		elif ext == "folder":
			# Folder mods materialize to a tmp zip during load_all_mods. Skip
			# if that hasn't happened yet this session (rare path).
			var folder_zip := ProjectSettings.globalize_path(TMP_DIR).path_join(
					archive_path.get_file() + "_dev.zip")
			if not FileAccess.file_exists(folder_zip):
				load_index += 1
				continue
			abs_archive = folder_zip
		elif ext != "zip" and ext != "pck":
			load_index += 1
			continue
		var zr := ZIPReader.new()
		if zr.open(abs_archive) != OK:
			load_index += 1
			continue
		for f: String in zr.get_files():
			var normalized := f.replace("\\", "/")
			if normalized.get_extension().to_lower() != "gd":
				continue
			var bytes := zr.read_file(f)
			if bytes.is_empty():
				continue
			var text := bytes.get_string_from_utf8()
			var ext_target := _parse_extends_literal(text)
			if ext_target.is_empty() or not ext_target.begins_with("res://Scripts/"):
				continue
			var vfn := ext_target.get_file()
			if not vanilla_filenames.has(vfn):
				continue
			candidates.append({
				"mod_name": mod_name,
				"res_path": "res://" + normalized,
				"vanilla_filename": vfn,
				"source": text,
				"load_index": load_index,
			})
		zr.close()
		load_index += 1
	return candidates

# Parse first non-empty non-comment line for `extends "res://..."`. Returns
# the quoted path, or "" if the script uses class-name extends, non-literal
# extends (preload/load/variable), or something else.
func _parse_extends_literal(source: String) -> String:
	for raw in source.split("\n"):
		var s := raw.strip_edges()
		if s.is_empty() or s.begins_with("#"):
			continue
		# Skip tool/icon annotations that may precede extends.
		if s.begins_with("@"):
			continue
		if not s.begins_with("extends"):
			return ""
		# "extends <target>" -- strip keyword + whitespace.
		var rest := s.substr(7).strip_edges()
		if rest.begins_with("\""):
			var close := rest.find("\"", 1)
			if close < 0:
				return ""
			return rest.substr(1, close - 1)
		return ""
	return ""

# --- Script enumeration -----------------------------------------------------
# DirAccess.get_files_at() returns at most 1 entry on res://Scripts/ in
# Godot 4.6 -- it doesn't enumerate PCK contents. Parse the PCK file table
# directly instead.

# Returns res://Scripts/*.gd paths found in the game's PCK, or [] on failure
# (encrypted pack, embedded pack, new format, missing file). Callers fall
# back to _class_name_to_path when empty.
