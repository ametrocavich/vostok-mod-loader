# Text formatting for the launcher: ages, sizes, timestamps, and the
# Markdown-to-BBCode converter for host descriptions.

func _format_age(saved_at_unix: int) -> String:
	var delta := int(Time.get_unix_time_from_system()) - saved_at_unix
	if delta < 60:
		return "just now"
	if delta < 60 * 60:
		return "%dm ago" % int(delta / 60.0)
	if delta < 24 * 60 * 60:
		return "%dh ago" % int(delta / 3600.0)
	return "%dd ago" % int(delta / 86400.0)


# bool(null) is a runtime error, so untrusted JSON goes through here.
func _json_truthy(v: Variant) -> bool:
	return (v is bool and v) or ((v is int or v is float) and v != 0)


func _format_size(bytes: int) -> String:
	if bytes < 1024:
		return str(bytes) + " B"
	if bytes < 1024 * 1024:
		return "%.1f KB" % (bytes / 1024.0)
	return "%.1f MB" % (bytes / (1024.0 * 1024.0))


# "2026-04-12T17:42:11Z" -> "2026-04-12 17:42"; anything without a T as is.
func _format_iso_datetime(iso: String) -> String:
	if iso.is_empty():
		return ""
	if not iso.contains("T"):
		return iso
	var parts := iso.split("T")
	return parts[0] + " " + parts[1].substr(0, 5)


# RegEx.sub would read the replacement's backslashes as backreferences.
func _re_replace(re: RegEx, s: String, repl: Callable) -> String:
	var out := ""
	var last := 0
	for m in re.search_all(s):
		out += s.substr(last, m.get_start() - last)
		out += str(repl.call(m))
		last = m.get_end()
	out += s.substr(last)
	return out


func _markdown_to_bbcode(md: String) -> String:
	# STX/ETX stand in for generated brackets while the user's literal ones
	# are escaped; they are stripped from the input so it cannot inject tags.
	var LB := char(2)
	var RB := char(3)
	var s := md.replace("\r\n", "\n").replace("\r", "\n")
	s = s.replace(LB, "").replace(RB, "")
	s = s.replace(":::", "")  # ModWorkshop colored-block delimiters

	# Before escaping '[': images first, since an image is a link with a '!'.
	s = _re_replace(_re_md_image, s, func(m): return m.get_string(1))
	# A literal ']' in the URL would end the url= tag; '%' is never encoded.
	var link := func(m: RegExMatch) -> String:
		var url := m.get_string(2).replace("[", "%5B").replace("]", "%5D")
		url = url.replace("_", "%5F").replace("*", "%2A").replace("~", "%7E")
		return LB + "url=" + url + RB + m.get_string(1) + LB + "/url" + RB
	s = _re_replace(_re_md_link, s, link)
	s = _re_replace(_re_md_color, s, func(m): return LB + "color=#" + m.get_string(1) + RB + m.get_string(2) + LB + "/color" + RB)

	s = s.replace("[", "[lb]")

	# Block level before inline, so a bullet's '*' is gone before italics run.
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

	# Bold before italic, or '*' would eat half of '**'.
	s = _re_replace(_re_md_bold, s, func(m): return LB + "b" + RB + m.get_string(1) + LB + "/b" + RB)
	s = _re_replace(_re_md_bold_underscore, s, func(m): return LB + "b" + RB + m.get_string(1) + LB + "/b" + RB)
	s = _re_replace(_re_md_strike, s, func(m): return LB + "s" + RB + m.get_string(1) + LB + "/s" + RB)
	s = _re_replace(_re_md_italic, s, func(m): return LB + "i" + RB + m.get_string(1) + LB + "/i" + RB)

	return s.replace(LB, "[").replace(RB, "]")
