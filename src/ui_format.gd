## Text formatting and JSON display-value helpers shared by launcher tabs.

# Coarse relative age for cache timestamps ("12m ago"); input unix seconds.
func _format_age(saved_at_unix: int) -> String:
	var delta := int(Time.get_unix_time_from_system()) - saved_at_unix
	if delta < 60:
		return "just now"
	if delta < 60 * 60:
		return "%dm ago" % int(delta / 60.0)
	if delta < 24 * 60 * 60:
		return "%dh ago" % int(delta / 3600.0)
	return "%dd ago" % int(delta / 86400.0)


# Guarded truthiness for one untrusted JSON value (bool(null) is a runtime
# error). _count_truthy (modpacks.gd) is the same rule over a dictionary.
func _json_truthy(v: Variant) -> bool:
	return (v is bool and v) or ((v is int or v is float) and v != 0)

# Format a byte count as a compact human-readable string.
func _format_size(bytes: int) -> String:
	if bytes < 1024:
		return str(bytes) + " B"
	if bytes < 1024 * 1024:
		return "%.1f KB" % (bytes / 1024.0)
	return "%.1f MB" % (bytes / (1024.0 * 1024.0))


# Format an ISO-8601 string ("2026-04-12T17:42:11.000000Z") as "2026-04-12 17:42",
# UTC. Returns the input unchanged if it does not look like a timestamp.
func _format_iso_datetime(iso: String) -> String:
	if iso.is_empty():
		return ""
	if not iso.contains("T"):
		return iso
	var parts := iso.split("T")
	var date_part: String = parts[0]
	if parts.size() < 2:
		return date_part
	var time_part: String = parts[1]
	var hm: String = time_part.substr(0, 5) if time_part.length() >= 5 else time_part
	return date_part + " " + hm


## Replace every match of `re` in `s` with repl(match); avoids RegEx.sub's backreference syntax.
func _re_replace(re: RegEx, s: String, repl: Callable) -> String:
	var out := ""
	var last := 0
	for m in re.search_all(s):
		out += s.substr(last, m.get_start() - last)
		out += str(repl.call(m))
		last = m.get_end()
	out += s.substr(last)
	return out

## Convert ModWorkshop's Markdown-flavored description into BBCode: headings,
## emphasis, lists, blockquotes, rules, links and MWS color spans. Inline images
## collapse to their alt text. Best-effort: malformed input renders imperfectly.
func _markdown_to_bbcode(md: String) -> String:
	# Sentinels stand in for generated brackets while the user's literal ones are
	# escaped. STX/ETX never appear in real descriptions.
	var LB := char(2)
	var RB := char(3)
	var s := md.replace("\r\n", "\n").replace("\r", "\n")
	# Strip the sentinels from the untrusted input, or the final restore injects BBCode.
	s = s.replace(LB, "").replace(RB, "")
	s = s.replace(":::", "")  # drop MWS colored-block delimiters; keep {#hex}(..)

	# Bracket/paren constructs, converted before escaping literal '['. Images
	# first (a link with a leading '!').
	s = _re_replace(_re_md_image, s, func(m): return m.get_string(1))
	# Percent-encode BBCode-sensitive chars in the URL so the later passes cannot
	# corrupt url= (a literal ']' ends the tag). Never encode '%'.
	s = _re_replace(_re_md_link, s, func(m): return LB + "url=" + m.get_string(2).replace("[", "%5B").replace("]", "%5D").replace("_", "%5F").replace("*", "%2A").replace("~", "%7E") + RB + m.get_string(1) + LB + "/url" + RB)
	s = _re_replace(_re_md_color, s, func(m): return LB + "color=#" + m.get_string(1) + RB + m.get_string(2) + LB + "/color" + RB)

	# Escape remaining literal '['; a lone ']' renders literally.
	s = s.replace("[", "[lb]")

	# Block level first, so a bullet's '*' is gone before the italic rule runs.
	var lines := PackedStringArray()
	for line in s.split("\n"):
		var t := line.strip_edges()
		if t == "---" or t == "***" or t == "___":
			lines.append(LB + "color=#555555" + RB + "--------------------" + LB + "/color" + RB)
			continue
		var mh := _re_md_heading.search(line)
		if mh != null:
			var lvl := mh.get_string(1).length()
			var sz := 22 if lvl == 1 else (19 if lvl == 2 else 17)
			lines.append(LB + "font_size=" + str(sz) + RB + LB + "b" + RB + mh.get_string(2) + LB + "/b" + RB + LB + "/font_size" + RB)
			continue
		if line.begins_with(">"):
			lines.append(LB + "indent" + RB + LB + "color=#a0a0a0" + RB + line.substr(1).strip_edges() + LB + "/color" + RB + LB + "/indent" + RB)
			continue
		var ml := _re_md_list_item.search(line)
		if ml != null:
			lines.append(LB + "indent" + RB + "- " + ml.get_string(1) + LB + "/indent" + RB)
			continue
		lines.append(line)
	s = "\n".join(lines)

	# Inline emphasis, whole string. Bold before italic so '**' isn't eaten by '*'.
	s = _re_replace(_re_md_bold, s, func(m): return LB + "b" + RB + m.get_string(1) + LB + "/b" + RB)
	s = _re_replace(_re_md_bold_underscore, s, func(m): return LB + "b" + RB + m.get_string(1) + LB + "/b" + RB)
	s = _re_replace(_re_md_strike, s, func(m): return LB + "s" + RB + m.get_string(1) + LB + "/s" + RB)
	s = _re_replace(_re_md_italic, s, func(m): return LB + "i" + RB + m.get_string(1) + LB + "/i" + RB)

	# Restore generated tags to real brackets last, so escaping never touched them.
	s = s.replace(LB, "[").replace(RB, "]")
	return s
