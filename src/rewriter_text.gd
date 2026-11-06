# Blank literal contents and comments, keeping positions, newlines and quote
# delimiters. Only a matching, unescaped quote closes a literal.
func _code_mask(source: String) -> String:
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
