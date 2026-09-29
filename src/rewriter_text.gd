## ----- rewriter_text.gd -----
## Text helpers the rewriter shares: a string- and comment-aware mask of
## GDScript source, and the identifier-character test.

# Hide literal contents and comments while preserving character positions,
# newlines and quote delimiters. Only a matching, unescaped quote closes a
# literal; comment text never opens one.
func _rtv_code_mask(source: String) -> String:
	var out := ""
	var quote := ""
	var comment := false
	var i := 0
	while i < source.length():
		var c := source[i]
		if c == "\n":
			out += c
			comment = false
			i += 1
			continue
		if comment:
			out += " "
			i += 1
			continue
		if not quote.is_empty():
			if c == "\\" and i + 1 < source.length():
				out += " " + ("\n" if source[i + 1] == "\n" else " ")
				i += 2
			elif source.substr(i, quote.length()) == quote:
				out += quote
				i += quote.length()
				quote = ""
			else:
				out += " "
				i += 1
			continue
		if c == "#":
			comment = true
			out += " "
			i += 1
		elif c == "\"" or c == "'":
			quote = c.repeat(3) if source.substr(i, 3) == c.repeat(3) else c
			out += quote
			i += quote.length()
		else:
			out += c
			i += 1
	return out

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
