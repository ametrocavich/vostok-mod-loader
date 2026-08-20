# True when a stripped line is a block-opening header (ends with ':' and
# starts with a block keyword).
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

# Rewrites Godot-3-era GDScript patterns that Godot 4's parser rejects,
# before the dispatch-wrapper pipeline runs. Handles:
#   (1) Bodyless block headers: inject `pass` where the next non-blank
#       non-comment line is not indented deeper (semantics preserved --
#       the empty block was already a no-op).
#   (2) `tool` -> `@tool`, (3) `onready var` -> `@onready var`,
#   (4) `export var` -> `@export var`. `export(Type) var` is left alone:
#       it needs a type-annotation transform that can break strict-typed
#       references.
# Source must be LF-normalized by the caller.
func _rtv_autofix_legacy_syntax(source: String) -> Dictionary:
	var lines: PackedStringArray = source.split("\n")
	var out: PackedStringArray = PackedStringArray()
	var indent_unit := _detect_indent_style(source)
	var fix_bodyless := 0
	var fix_tool := 0
	var fix_onready := 0
	var fix_export := 0
	var fix_base := 0

	# Track the enclosing method so Godot 3's `base(...)` (invalid in
	# Godot 4) can be rewritten to `super.<method>(...)`.
	var current_method: String = ""
	var method_line_indent: String = ""

	for i in lines.size():
		var line: String = lines[i]

		var lead := _rtv_leading_indent(line)
		if lead.is_empty() and not line.strip_edges().is_empty():
			var stripped_top := line.strip_edges()
			if stripped_top.begins_with("func "):
				var open_paren := stripped_top.find("(")
				if open_paren > 5:
					current_method = stripped_top.substr(5, open_paren - 5).strip_edges()
					method_line_indent = ""
			elif stripped_top.begins_with("static func ") or stripped_top.begins_with("@"):
				# Static funcs and annotations don't open a "self" method
				# where base() would resolve.
				current_method = ""
			else:
				current_method = ""

		if not current_method.is_empty() and "base" in line:
			var rewritten := _rtv_rewrite_bare_base(line, current_method)
			if rewritten != line:
				line = rewritten
				fix_base += 1

		lead = _rtv_leading_indent(line)
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
		"base": fix_base,
	}

# Rewrite standalone `base(args)` to `super.<method>(args)`; qualified
# `.base(` and anything past a `#` stay unchanged.
#
# Chained form: Godot 3's base() returned the parent instance, so mods
# wrote `base().Foo(x)`. A plain substitution would chain .Foo(x) onto the
# void return of the super call, so `base().<chained>(...)` is rewritten
# to `super.<chained>(...)` instead.
func _rtv_rewrite_bare_base(line: String, method_name: String) -> String:
	var comment_start := line.find("#")
	var head: String = line if comment_start < 0 else line.substr(0, comment_start)
	var tail: String = "" if comment_start < 0 else line.substr(comment_start)
	var i := 0
	var rewritten := ""
	while i < head.length():
		if i + 4 <= head.length() and head.substr(i, 4) == "base":
			var prev_ok := true
			if i > 0:
				var pc := head[i - 1]
				if pc >= "a" and pc <= "z":
					prev_ok = false
				elif pc >= "A" and pc <= "Z":
					prev_ok = false
				elif pc >= "0" and pc <= "9":
					prev_ok = false
				elif pc == "_" or pc == ".":
					prev_ok = false
			var j := i + 4
			while j < head.length() and (head[j] == " " or head[j] == "\t"):
				j += 1
			if prev_ok and j < head.length() and head[j] == "(":
				# Chain absorb applies only to empty-parens base(); with
				# args the call is meaningful, and `base(arg).foo(x)` falls
				# through to `super.<enclosing>(arg).foo(x)`, still correct
				# since super() returns the parent method's value.
				var close_idx := _rtv_find_matching_paren(head, j)
				if close_idx > j and head.substr(j + 1, close_idx - j - 1).strip_edges().is_empty():
					var k := close_idx + 1
					if k < head.length() and head[k] == ".":
						var name_start := k + 1
						var name_end := name_start
						while name_end < head.length() \
								and _rtv_is_ident_char(head[name_end]):
							name_end += 1
						if name_end > name_start \
								and name_end < head.length() \
								and head[name_end] == "(":
							var chained_name: String = head.substr(name_start, name_end - name_start)
							rewritten += "super." + chained_name
							i = name_end  # advance to chained "("
							continue
				# Plain base(args) -> super.<enclosing>(args).
				rewritten += "super." + method_name
				i += 4
				continue
		rewritten += head[i]
		i += 1
	return rewritten + tail

# Index of the paren matching the one at open_idx, or -1. Tracks string
# literals so parens inside them don't affect depth.
func _rtv_find_matching_paren(s: String, open_idx: int) -> int:
	if open_idx >= s.length() or s[open_idx] != "(":
		return -1
	var depth := 0
	var in_dq := false   # inside "..."
	var in_sq := false   # inside '...'
	var i := open_idx
	while i < s.length():
		var c := s[i]
		if in_dq:
			if c == "\\" and i + 1 < s.length():
				i += 2
				continue
			if c == "\"":
				in_dq = false
		elif in_sq:
			if c == "\\" and i + 1 < s.length():
				i += 2
				continue
			if c == "'":
				in_sq = false
		else:
			if c == "\"":
				in_dq = true
			elif c == "'":
				in_sq = true
			elif c == "(":
				depth += 1
			elif c == ")":
				depth -= 1
				if depth == 0:
					return i
		i += 1
	return -1

# True for ASCII identifier chars; GDScript identifiers are ASCII-only.
func _rtv_is_ident_char(c: String) -> bool:
	if c == "_":
		return true
	if c >= "a" and c <= "z":
		return true
	if c >= "A" and c <= "Z":
		return true
	if c >= "0" and c <= "9":
		return true
	return false

# Comment out bare `<var>.reload()` lines inside functions that also call
# take_over_path. The hook pack owns the mod subclass source, so reload is
# redundant; and if the mod already set_script() a live node (RTVCoop does),
# reload fails at gdscript.cpp:756 "Cannot reload script while instances
# exist" and spams stderr each launch. take_over_path still succeeds, so
# stripping is behavior-neutral. Source must be LF-normalized by the caller.
func _rtv_strip_helper_reload(source: String) -> Dictionary:
	var lines: PackedStringArray = source.split("\n")
	var out: PackedStringArray = PackedStringArray()
	var stripped: int = 0
	var i: int = 0
	while i < lines.size():
		var line: String = lines[i]
		if not line.begins_with("func "):
			out.append(line)
			i += 1
			continue
		var start: int = i
		var end: int = i + 1
		while end < lines.size():
			var bl: String = lines[end]
			if bl.length() > 0 and not (bl[0] == "\t" or bl[0] == " "):
				break
			end += 1
		var has_tov: bool = false
		for k in range(start, end):
			if ".take_over_path(" in lines[k]:
				has_tov = true
				break
		if has_tov:
			for k in range(start, end):
				var bl: String = lines[k]
				var trimmed: String = bl.strip_edges()
				# Bare `<ident>.reload()` statement lines only.
				if trimmed.ends_with(".reload()") and not trimmed.begins_with("#"):
					var before_paren: int = trimmed.find(".reload()")
					var ident_part: String = trimmed.substr(0, before_paren)
					var is_bare_call: bool = true
					for c in ident_part:
						if not (c == "_" or c == "." or (c >= "a" and c <= "z") \
								or (c >= "A" and c <= "Z") or (c >= "0" and c <= "9")):
							is_bare_call = false
							break
					if is_bare_call:
						var indent_len: int = 0
						while indent_len < bl.length() and (bl[indent_len] == "\t" or bl[indent_len] == " "):
							indent_len += 1
						var indent: String = bl.substr(0, indent_len)
						out.append(indent + "# " + bl.substr(indent_len) + "  # modloader: stripped (redundant + fires Cannot-reload error if instance exists)")
						stripped += 1
						continue
				out.append(bl)
		else:
			for k in range(start, end):
				out.append(lines[k])
		i = end
	return {"source": "\n".join(out), "stripped": stripped}

