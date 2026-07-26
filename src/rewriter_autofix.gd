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
	var fix_base := 0

	# Pre-pass: track which method a line belongs to, so `base(...)` inside
	# a method body can be rewritten to `super.<method>(...)`. Godot 3's
	# `base()` is no longer valid in Godot 4; parser fails with
	# `Function "base()" not found in base self` and the failure cascades
	# through chain-via-extends. Single autofix converts the common case.
	var current_method: String = ""
	var method_line_indent: String = ""

	for i in lines.size():
		var line: String = lines[i]

		# Track enclosing method for `base()` rewrite. Top-level line (no
		# indent) with `func <name>(` opens a method; top-level line without
		# that closes the prior method's scope.
		var lead := _rtv_leading_indent(line)
		if lead.is_empty() and not line.strip_edges().is_empty():
			var stripped_top := line.strip_edges()
			if stripped_top.begins_with("func "):
				var open_paren := stripped_top.find("(")
				if open_paren > 5:
					current_method = stripped_top.substr(5, open_paren - 5).strip_edges()
					method_line_indent = ""
			elif stripped_top.begins_with("static func ") or stripped_top.begins_with("@"):
				# Skip static funcs and annotations (they don't open a "self"
				# method where base() would resolve).
				current_method = ""
			else:
				current_method = ""

		# Rewrite `base(` / `base (` to `super.<method>(` when inside a
		# method body. Don't touch literal `.base(` calls (already qualified).
		if not current_method.is_empty() and "base" in line:
			var rewritten := _rtv_rewrite_bare_base(line, current_method)
			if rewritten != line:
				line = rewritten
				fix_base += 1

		# Annotation migrations (line-local rewrites).
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

# Rewrite bare `base(args)` or `base (args)` in a line to `super.<method>(args)`.
# Skips `self.base(`, `<ident>.base(`, etc. -- only rewrites standalone `base(`
# (possibly preceded by `=`, `+`, `(`, `[`, `,`, or whitespace). Per-line so
# strings/comments past a `#` stay unchanged.
#
# Chained-call form `base(...).<chained>(<args>)`: Godot 3's `base()` returned
# the parent instance, so mods wrote `base().Foo(x)` to call parent's Foo.
# A plain substitution ("super.<enclosing>") would yield
# "super.<enclosing>().Foo(x)" -- syntactically valid but chained onto the
# void return of enclosing's super call, which is wrong (parent's Foo never
# runs with the passed args, and the chained .Foo(x) fires on null). We
# detect the chain and rewrite to "super.<chained>(<args>)", which is how
# Godot 4 expresses "call parent's <chained> method" directly.
func _rtv_rewrite_bare_base(line: String, method_name: String) -> String:
	var comment_start := line.find("#")
	var head: String = line if comment_start < 0 else line.substr(0, comment_start)
	var tail: String = "" if comment_start < 0 else line.substr(comment_start)
	# Walk from left to right looking for the word `base` not preceded by a
	# letter/digit/underscore/dot (i.e. not part of an identifier or already
	# qualified). Replace with `super.<method>`.
	var i := 0
	var rewritten := ""
	while i < head.length():
		if i + 4 <= head.length() and head.substr(i, 4) == "base":
			# Check preceding character (word-boundary).
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
			# Check trailing char is `(` or whitespace-then-`(`.
			var j := i + 4
			while j < head.length() and (head[j] == " " or head[j] == "\t"):
				j += 1
			if prev_ok and j < head.length() and head[j] == "(":
				# Chained-call detection: find matching `)` for base(),
				# peek past it for `.<ident>(`. If present, rewrite the
				# entire `base().<ident>` region to `super.<ident>`.
				# Only empty-parens base() gets the chain absorb -- with
				# args, the arg is meaningful (call parent's enclosing
				# method with it) and must be preserved. `base(arg).foo(x)`
				# falls through to the plain `super.<enclosing>(arg)` path,
				# which yields `super.<enclosing>(arg).foo(x)` -- still
				# semantically correct (Godot 4's super() returns the
				# parent method's value so chaining works).
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

# Scans from an open paren at open_idx and returns the index of the matching
# close paren, or -1 if not found. Tracks double-quoted strings so parens
# inside "..." don't affect depth. Used by _rtv_rewrite_bare_base to span
# `base(...)` before checking for a chained `.<method>(...)` call.
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

# True for identifier-continuation chars (ASCII [A-Za-z0-9_]). Non-ASCII
# identifiers aren't legal in GDScript so ASCII coverage is sufficient.
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

# Comment out `<var>.reload()` lines inside mod helper functions that also
# call `take_over_path`. Rationale: mod override helpers (RTVCoop's _override,
# CustomItemTest's override_script, etc.) often do:
#   var script = load(modPath); script.reload(); script.take_over_path(gamePath)
# The reload() call is a no-op unless source changed between load and call.
# Our hook pack owns the mod subclass source, so reload is always redundant.
# Worse: if the mod had already set_script(script) on a live node earlier
# (RTVCoop does this for /root/Loader), reload fails at gdscript.cpp:756 with
# "Cannot reload script while instances exist." take_over_path succeeds right
# after, so the override still works, but the error spams stderr each launch.
# Stripping the reload eliminates the error with no behavior change.
#
# Scope: only strips lines where the stripped-edges content ends with
# ".reload()" AND the enclosing function body contains ".take_over_path(".
# Comments out with a "# modloader stripped" note so the change is visible
# if a mod author inspects the rewritten source.
#
# Source must be LF-normalized by the caller.
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
		# Collect function body: header + subsequent indented lines.
		var start: int = i
		var end: int = i + 1
		while end < lines.size():
			var bl: String = lines[end]
			if bl.length() > 0 and not (bl[0] == "\t" or bl[0] == " "):
				break
			end += 1
		# Does this function body call take_over_path anywhere?
		var has_tov: bool = false
		for k in range(start, end):
			if ".take_over_path(" in lines[k]:
				has_tov = true
				break
		if has_tov:
			for k in range(start, end):
				var bl: String = lines[k]
				var trimmed: String = bl.strip_edges()
				# Match bare `<ident>.reload()` statement lines (nothing else
				# on the line). Preserves the original indent and leaves a
				# comment trail.
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

