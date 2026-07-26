func _json_int(d: Dictionary, key: String, fallback: int = 0) -> int:
	var v: Variant = d.get(key)
	return int(v) if (v is int or v is float) else fallback


# Render one row in the Browse tab list. Pulls from a ModSummary dict (live
# response shape from /games/{id}/mods or /games/{id}/popular-and-latest).
# Thumbnail loads asynchronously via _browse_load_thumbnail_async; the row
# returns immediately with a gray placeholder. installed=true swaps the Get
# button for a disabled "Installed" indicator -- update detection (delta vs
# MWS' current version) lives in the Updates tab for now and isn't surfaced
# here in this iteration.
# Title for a filtered / searched / category Browse view. The curated landing
# titles its own two sections ("Popular this week" / "Latest") but every other
# view rendered a bare row list, so the only heading in the whole tab belonged
# to Popular -- it read as if that were a permanent title rather than one
# section among several.
#
# Derived from the sort key actually sent to the API, not the dropdown index:
# picking a category while the dropdown still reads "Featured" sends bumped_at,
# and the header has to describe the results, not the control.
func _browse_results_header_text(query: String, sort_key: String, category_name: String) -> String:
	var sort_labels := {
		"bumped_at": "Recently updated",
		"downloads": "Most downloaded",
		"likes": "Most liked",
		"views": "Most viewed",
		"published_at": "Newest",
	}
	var q := query.strip_edges()
	var head: String = ("Results for \"" + q + "\"") if not q.is_empty() \
			else str(sort_labels.get(sort_key, "Results"))
	var cat := category_name.strip_edges()
	if not cat.is_empty():
		head += " in " + cat
	return head

func _browse_render_mod_row(mod_data: Dictionary, install_entry: Variant, on_get: Callable, on_toggle: Callable) -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", SP_L)

	# Same cell the Mods tab builds, so a Browse mod with no image reads
	# "no thumbnail" exactly like an installed one instead of sitting as a
	# bare gray panel.
	var thumb_rect := _make_thumb_cell(row, Vector2(96, 54))

	var thumb_record = mod_data.get("thumbnail")
	if thumb_record is Dictionary:
		_browse_load_thumbnail_async(thumb_rect, thumb_record)

	var info_col := VBoxContainer.new()
	info_col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	info_col.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(info_col)

	# Mod name doubles as the click target for the detail modal. Flat Button,
	# not LinkButton: LinkButton has no clip_text/overrun support, so its min
	# width equals the full text width and one long ModWorkshop name inflated
	# the row past the list, forcing a horizontal scrollbar and pushing the
	# Download/Enabled control out of view. Same recipe as the Mods-tab name
	# link (hover color is the click cue in place of underline).
	var name_lnk := Button.new()
	name_lnk.flat = true
	name_lnk.text = str(mod_data.get("name", "?"))
	name_lnk.clip_text = true
	name_lnk.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	name_lnk.alignment = HORIZONTAL_ALIGNMENT_LEFT
	name_lnk.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	name_lnk.add_theme_font_size_override("font_size", FS_EMPH)
	name_lnk.add_theme_color_override("font_color", COL_TEXT)
	name_lnk.add_theme_color_override("font_hover_color", COL_TEXT_HI)
	name_lnk.tooltip_text = name_lnk.text
	var captured_data_for_detail := mod_data
	name_lnk.pressed.connect(func():
		_show_browse_mod_detail_dialog(captured_data_for_detail, on_get)
	)
	info_col.add_child(name_lnk)

	var user_dict: Dictionary = mod_data.get("user", {}) if mod_data.get("user") is Dictionary else {}
	var category_dict: Dictionary = mod_data.get("category", {}) if mod_data.get("category") is Dictionary else {}
	var author: String = str(user_dict.get("name", ""))
	var version: String = str(mod_data.get("version", "")).strip_edges()
	var downloads: int = _json_int(mod_data, "downloads")
	var likes: int = _json_int(mod_data, "likes")
	var category: String = str(category_dict.get("name", ""))
	var bumped_raw: String = str(mod_data.get("bumped_at", ""))
	var bumped_short: String = _format_iso_datetime(bumped_raw)

	var meta_parts := PackedStringArray()
	if author != "":
		meta_parts.append("by " + author)
	if version != "":
		meta_parts.append("v" + version)
	meta_parts.append(str(downloads) + " downloads")
	if likes > 0:
		meta_parts.append(str(likes) + " likes")
	if category != "":
		meta_parts.append(category)
	if bumped_short != "":
		meta_parts.append("updated " + bumped_short)

	var meta_lbl := Label.new()
	meta_lbl.text = " - ".join(meta_parts)
	meta_lbl.add_theme_font_size_override("font_size", FS_META)
	meta_lbl.add_theme_color_override("font_color", COL_TEXT_DIM)
	meta_lbl.clip_text = true
	# Ellipsis + hover tooltip instead of a hard mid-word cut (Labels default
	# to MOUSE_FILTER_IGNORE, which silently suppresses tooltips).
	meta_lbl.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	meta_lbl.tooltip_text = meta_lbl.text
	meta_lbl.mouse_filter = Control.MOUSE_FILTER_PASS
	info_col.add_child(meta_lbl)

	# Installed mods get an enable toggle bound to the active profile. The
	# checkbox's existence implies install (un-installed mods show a Download
	# button instead, never both), and the label embeds the profile name so
	# users know what they're toggling.
	var installed := install_entry is Dictionary
	if installed:
		var entry: Dictionary = install_entry as Dictionary
		var enable_check := CheckBox.new()
		enable_check.text = "Enabled in " + _active_profile
		enable_check.button_pressed = bool(entry.get("enabled", false))
		enable_check.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		# Tag with the mws id so _refresh_browse_installed_rows can re-derive
		# this baked-at-render-time state when the tab is shown again.
		enable_check.set_meta("browse_mws_id", int(mod_data.get("id", 0)))
		var captured_mws_id := int(mod_data.get("id", 0))
		var captured_check := enable_check
		enable_check.toggled.connect(func(on: bool):
			on_toggle.call(captured_mws_id, on, captured_check)
		)
		row.add_child(enable_check)
		_wire_hint(enable_check, "Toggle this mod in profile: " + _active_profile + ".")
	else:
		var get_btn := Button.new()
		get_btn.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		get_btn.text = "Download"
		# Tag with the mws id so _refresh_browse_installed_rows can flip this
		# to Installed if the mod arrives behind the tab's back (modpack
		# apply, retry downloads).
		get_btn.set_meta("browse_mws_id", int(mod_data.get("id", 0)))
		var captured := mod_data
		var captured_btn := get_btn
		get_btn.pressed.connect(func():
			on_get.call(captured, captured_btn)
		)
		row.add_child(get_btn)
		_wire_hint(get_btn, "Download this mod from ModWorkshop.")

	return row


# Visible terminal state for a thumbnail cell. Without this, "still loading",
# "mod has no image" and "fetch/decode failed" all look like the same bare
# gray panel. Overlays a centered dim label ("load failed" when a fetch or
# decode broke, "no image" when there is nothing to fetch) into the cell's
# parent PanelContainer -- no image asset needed, and FS_META + COL_TEXT_DIM
# keeps it as quiet as the rest of the meta text. Safe to call after awaits
# (guards the rect and its parent) and idempotent per cell.
func _set_thumb_failed(rect: TextureRect, failed: bool) -> void:
	if not is_instance_valid(rect):
		return
	var wrap := rect.get_parent() as Control
	if wrap == null or not is_instance_valid(wrap):
		return
	# Cells are captioned "no thumbnail" the moment they are built, so an
	# existing label is the normal case, not a duplicate to skip: update it, or
	# a fetch that actually broke would keep reading "no thumbnail".
	if wrap.has_node("ThumbStateLabel"):
		var existing := wrap.get_node("ThumbStateLabel") as Label
		if existing != null:
			existing.text = "load failed" if failed else "no thumbnail"
		return
	var lbl := Label.new()
	lbl.name = "ThumbStateLabel"
	lbl.text = "load failed" if failed else "no thumbnail"
	lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	lbl.add_theme_color_override("font_color", COL_TEXT_DIM)
	lbl.add_theme_font_size_override("font_size", FS_META)
	wrap.add_child(lbl)

# Paint a loaded texture into a thumbnail cell, clearing any state caption
# first. Every texture-setting path goes through here: cells now start
# captioned "no thumbnail", so a path that assigned .texture directly would
# leave the caption sitting on top of a perfectly good image.
func _set_thumb_ready(rect: TextureRect, tex: Texture2D) -> void:
	if not is_instance_valid(rect):
		return
	var wrap := rect.get_parent() as Control
	if wrap != null and is_instance_valid(wrap) and wrap.has_node("ThumbStateLabel"):
		var stale := wrap.get_node("ThumbStateLabel")
		wrap.remove_child(stale)
		stale.queue_free()
	rect.texture = tex

# Build an image cell: a surface-coloured PanelContainer holding a TextureRect,
# captioned "no thumbnail" until an image lands. This is the single source of
# truth for every image cell in the launcher. The Mods rows, the Browse rows
# and the detail banner each grew their own copy of this construction, and that
# is exactly how they drifted -- only one of the three ever got a placeholder.
#
# cover=true crops to fill, for small row tiles. cover=false letterboxes inside
# the band so the whole image stays visible, which is what the detail banner
# wants. shrink_center keeps the cell at its natural height instead of
# stretching to the row.
#
# Returns the TextureRect to paint into (via _set_thumb_ready).
func _make_thumb_cell(parent: Control, min_size: Vector2, cover: bool = true,
		shrink_center: bool = false) -> TextureRect:
	var wrap := PanelContainer.new()
	wrap.custom_minimum_size = min_size
	if shrink_center:
		wrap.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	var style := StyleBoxFlat.new()
	style.bg_color = COL_SURFACE_2
	wrap.add_theme_stylebox_override("panel", style)
	parent.add_child(wrap)
	var rect := TextureRect.new()
	rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED if cover \
			else TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	rect.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	rect.size_flags_vertical = Control.SIZE_EXPAND_FILL
	wrap.add_child(rect)
	_set_thumb_failed(rect, false)
	return rect


# Session memo of decoded thumbnail textures keyed by storage filename.
# Without it every Mods-tab rebuild (per filter keystroke) and every Browse
# re-render re-read the disk cache and re-decoded the image into a fresh
# ImageTexture per row -- a visible hitch that grew with each "Load more"
# page. FIFO-bounded so a long Browse session can't hold hundreds of
# 640px textures forever (Dictionary preserves insertion order).
var _thumb_texture_cache: Dictionary = {}
const _THUMB_TEXTURE_CACHE_MAX := 256

func _thumb_texture_cache_store(fn: String, tex: Texture2D) -> void:
	while _thumb_texture_cache.size() >= _THUMB_TEXTURE_CACHE_MAX:
		_thumb_texture_cache.erase(_thumb_texture_cache.keys()[0])
	_thumb_texture_cache[fn] = tex


# Async thumbnail loader. Cache layout: user://mws_cache/thumbs/<storage_filename>.
# Filenames from MWS are opaque/immutable per upload, so the storage filename
# IS the cache key -- a thumbnail replaced by the author gets a different file
# name and we naturally fetch fresh. No TTL needed, no manual cache busting.
# Failures surface via _set_thumb_failed so the cell doesn't stay an
# ambiguous gray panel. 1MB hard cap (download_body_size_limit below) defends
# against malformed responses without limiting real thumbnails.
func _browse_load_thumbnail_async(rect: TextureRect, image_record: Dictionary) -> void:
	var fn: String = str(image_record.get("file", ""))
	if fn.is_empty():
		_set_thumb_failed(rect, false)
		return
	# Server-provided name: accept only a bare basename so path_join cannot
	# escape the cache dir (same never-trust-a-server-name posture as the
	# _is_safe_mod_filename gate on mod download names). get_file() only
	# splits on "/", so reject backslashes and ".." explicitly too.
	if fn != fn.get_file() or fn.contains("\\") or fn.contains(".."):
		_set_thumb_failed(rect, false)
		return

	# Memory hit: already decoded this session -- no disk read, no decode.
	var memo_tex_v: Variant = _thumb_texture_cache.get(fn)
	if memo_tex_v is Texture2D:
		_set_thumb_ready(rect, memo_tex_v as Texture2D)
		return

	var cache_dir := "user://mws_cache/thumbs"
	DirAccess.make_dir_recursive_absolute(cache_dir)
	var cache_path := cache_dir.path_join(fn)

	# Cache hit: try to deserialize bytes. load_*_from_buffer returns OK on
	# match, so fall through to refetch on any decode error rather than
	# trusting the on-disk file unconditionally.
	if FileAccess.file_exists(cache_path):
		var f := FileAccess.open(cache_path, FileAccess.READ)
		if f != null:
			var bytes := f.get_buffer(f.get_length())
			f.close()
			if bytes.size() > 0:
				var img := Image.new()
				if img.load_webp_from_buffer(bytes) == OK \
						or img.load_jpg_from_buffer(bytes) == OK \
						or img.load_png_from_buffer(bytes) == OK:
					var disk_tex := ImageTexture.create_from_image(img)
					_thumb_texture_cache_store(fn, disk_tex)
					_set_thumb_ready(rect, disk_tex)
					return

	# Cache miss: fetch from CDN. The /mods/images/thumbs/ path returns 404
	# in practice even when the record claims has_thumb=true, so use the
	# full-size image URL. Mod thumbnails are typically 100-300KB; 1MB cap
	# gives margin for higher-res covers without letting a malformed response
	# eat memory.
	var url := mws_image_url(image_record, false)
	if url.is_empty():
		_set_thumb_failed(rect, false)
		return

	var req := HTTPRequest.new()
	req.timeout = API_CHECK_TIMEOUT
	req.download_body_size_limit = 1024 * 1024
	add_child(req)
	var headers := PackedStringArray([
		"User-Agent: " + (MWS_USER_AGENT_TEMPLATE % MODLOADER_VERSION),
	])
	var err := req.request(url, headers)
	if err != OK:
		req.queue_free()
		_set_thumb_failed(rect, true)
		return

	var res: Array = await req.request_completed
	req.queue_free()
	if res[0] != HTTPRequest.RESULT_SUCCESS or res[1] < 200 or res[1] >= 300:
		_set_thumb_failed(rect, true)
		return
	var body: PackedByteArray = res[3]
	if body.is_empty():
		_set_thumb_failed(rect, true)
		return

	var img := Image.new()
	var ok := img.load_webp_from_buffer(body) == OK \
			or img.load_jpg_from_buffer(body) == OK \
			or img.load_png_from_buffer(body) == OK
	if not ok:
		_set_thumb_failed(rect, true)
		return

	# The CDN serves full-size images (100-300KB+) while the row cells render
	# at 96x54, so downscale before caching. This ONE cache is also read by
	# the detail dialog's banner (a ~220px-tall letterboxed band), so rather
	# than keying a separate small variant -- which risks serving a tiny stale
	# entry where the banner expects a large one -- cap the longest side at
	# 640px: still crisp for the banner band, while cutting typical cached
	# files by roughly an order of magnitude. Re-encoded as lossy WebP; the
	# cache-hit reader above tries webp/jpg/png regardless of the stored
	# filename's extension, so the container swap is safe.
	var thumb_cache_max := 640
	var cache_bytes := body
	if maxi(img.get_width(), img.get_height()) > thumb_cache_max:
		var scale := float(thumb_cache_max) / float(maxi(img.get_width(), img.get_height()))
		img.resize(
			maxi(1, int(round(img.get_width() * scale))),
			maxi(1, int(round(img.get_height() * scale))),
			Image.INTERPOLATE_LANCZOS
		)
		var resized := img.save_webp_to_buffer(true, 0.85)
		if resized.size() > 0:
			cache_bytes = resized

	# Stash for next launch. Failure to write is non-fatal -- we still display
	# the texture this session, just refetch next time. store_buffer returns
	# bool since 4.3; drop a partial file rather than leaving a truncated
	# cache entry around.
	var out := FileAccess.open(cache_path, FileAccess.WRITE)
	if out != null:
		var wrote := out.store_buffer(cache_bytes)
		out.close()
		if not wrote:
			DirAccess.remove_absolute(cache_path)

	var net_tex := ImageTexture.create_from_image(img)
	_thumb_texture_cache_store(fn, net_tex)
	_set_thumb_ready(rect, net_tex)


# Format a byte count as a compact human-readable string. Used by the mod
# detail modal's file list and the Remove confirmation dialog.
func _format_size(bytes: int) -> String:
	if bytes < 1024:
		return str(bytes) + " B"
	if bytes < 1024 * 1024:
		return "%.1f KB" % (bytes / 1024.0)
	return "%.1f MB" % (bytes / (1024.0 * 1024.0))


# Format a MWS ISO-8601 string ("2026-04-12T17:42:11.000000Z") as a compact
# "2026-04-12 17:42" -- date plus HH:MM, dropping seconds + microsecond noise
# and the Z suffix. UTC; the dropdown labels in the UI don't claim a timezone.
# Returns the input unchanged if it doesn't look like an ISO timestamp.
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
	# "17:42:11.000000Z" -> "17:42"; safe even if the seconds segment is short.
	var hm: String = time_part.substr(0, 5) if time_part.length() >= 5 else time_part
	return date_part + " " + hm


## Replace every match of `re` in `s` using a callable that maps a RegExMatch to
## its replacement. Avoids RegEx.sub's backreference syntax (unused elsewhere in
## this codebase) -- get_string()/get_start()/get_end() are unambiguous.
func _re_replace(re: RegEx, s: String, repl: Callable) -> String:
	var out := ""
	var last := 0
	for m in re.search_all(s):
		out += s.substr(last, m.get_start() - last)
		out += str(repl.call(m))
		last = m.get_end()
	out += s.substr(last)
	return out

## Convert ModWorkshop's Markdown-flavored description into Godot BBCode for a
## RichTextLabel: headings, bold/italic/strikethrough, bullet lists, blockquotes,
## horizontal rules, links, and MWS's {#hex}(text) / :::{#hex}(...):::
## color spans. Inline images (![alt](url)) collapse to their alt text --
## RichTextLabel can't load remote images inline without extra async work.
## Best-effort and non-crashing: malformed input just renders imperfectly.
func _markdown_to_bbcode(md: String) -> String:
	# Sentinels stand in for our own '[' / ']' while we escape the user's literal
	# brackets, so escaping can't mangle tags we generate. STX/ETX never appear
	# in real descriptions.
	var LB := char(2)
	var RB := char(3)
	var s := md.replace("\r\n", "\n").replace("\r", "\n")
	# Untrusted remote input must NOT contain our sentinels -- the final restore
	# would turn them into real brackets and inject BBCode past the [lb] escape.
	s = s.replace(LB, "").replace(RB, "")
	s = s.replace(":::", "")  # drop MWS colored-block delimiters; keep {#hex}(..)

	# Bracket/paren constructs, converted BEFORE escaping literal '['. Images
	# first (a link with a leading '!').
	var re_img := RegEx.new()
	re_img.compile("!\\[([^\\]]*)\\]\\([^)]*\\)")
	s = _re_replace(re_img, s, func(m): return m.get_string(1))
	var re_link := RegEx.new()
	re_link.compile("\\[([^\\]]*)\\]\\(([^)\\s]+)\\)")
	# Percent-encode BBCode/markdown-sensitive chars in the URL so the later '['
	# escape + emphasis passes can't corrupt the url= parameter (a literal ']'
	# would end the tag early). '_' and '~' are RFC-3986 unreserved; %2A/%5B/%5D
	# are handled identically by servers and OS.shell_open. Never encode '%'.
	s = _re_replace(re_link, s, func(m): return LB + "url=" + m.get_string(2).replace("[", "%5B").replace("]", "%5D").replace("_", "%5F").replace("*", "%2A").replace("~", "%7E") + RB + m.get_string(1) + LB + "/url" + RB)
	var re_color := RegEx.new()
	re_color.compile("\\{#([0-9a-fA-F]{3,8})\\}\\(([^)]*)\\)")
	s = _re_replace(re_color, s, func(m): return LB + "color=#" + m.get_string(1) + RB + m.get_string(2) + LB + "/color" + RB)

	# Escape remaining literal '[' so stray user brackets aren't read as tags.
	# Only '[' matters to the parser; a lone ']' renders literally.
	s = s.replace("[", "[lb]")

	# Block level: strip line markers, wrap in sentinel tags. Done BEFORE inline
	# emphasis so a bullet's leading '*' is gone before the '*italic*' rule runs.
	var re_h := RegEx.new()
	re_h.compile("^(#{1,6})\\s+(.*)$")
	var re_li := RegEx.new()
	re_li.compile("^\\s*[-*+]\\s+(.*)$")
	var lines := PackedStringArray()
	for line in s.split("\n"):
		var t := line.strip_edges()
		if t == "---" or t == "***" or t == "___":
			lines.append(LB + "color=#555555" + RB + "--------------------" + LB + "/color" + RB)
			continue
		var mh := re_h.search(line)
		if mh != null:
			var lvl := mh.get_string(1).length()
			var sz := 22 if lvl == 1 else (19 if lvl == 2 else 17)
			lines.append(LB + "font_size=" + str(sz) + RB + LB + "b" + RB + mh.get_string(2) + LB + "/b" + RB + LB + "/font_size" + RB)
			continue
		if line.begins_with(">"):
			lines.append(LB + "indent" + RB + LB + "color=#a0a0a0" + RB + line.substr(1).strip_edges() + LB + "/color" + RB + LB + "/indent" + RB)
			continue
		var ml := re_li.search(line)
		if ml != null:
			lines.append(LB + "indent" + RB + "- " + ml.get_string(1) + LB + "/indent" + RB)
			continue
		lines.append(line)
	s = "\n".join(lines)

	# Inline emphasis, whole string. Bold before italic so '**' isn't eaten by '*'.
	var re_bold := RegEx.new()
	re_bold.compile("\\*\\*([^*]+)\\*\\*")
	s = _re_replace(re_bold, s, func(m): return LB + "b" + RB + m.get_string(1) + LB + "/b" + RB)
	var re_bold2 := RegEx.new()
	re_bold2.compile("__([^_]+)__")
	s = _re_replace(re_bold2, s, func(m): return LB + "b" + RB + m.get_string(1) + LB + "/b" + RB)
	var re_strike := RegEx.new()
	re_strike.compile("~~([^~]+)~~")
	s = _re_replace(re_strike, s, func(m): return LB + "s" + RB + m.get_string(1) + LB + "/s" + RB)
	var re_ital := RegEx.new()
	re_ital.compile("(?<![\\w*])\\*([^*\\n]+)\\*(?![\\w*])")
	s = _re_replace(re_ital, s, func(m): return LB + "i" + RB + m.get_string(1) + LB + "/i" + RB)

	# Restore our tags to real brackets, last, so escaping never touched them.
	s = s.replace(LB, "[").replace(RB, "]")
	return s

# Detail modal for a Browse-tab row. Opens with whatever ModSummary fields the
# list endpoint returned (name, desc, image, downloads, etc.) and async-loads
# the file history (/mods/{id}/files) into a separate section once available.
# The Get button forwards to the same on_get callback the list rows use, so
# install state stays consistent between the row and the modal.
func _show_browse_mod_detail_dialog(mod_data: Dictionary, on_get: Callable) -> void:
	var d := AcceptDialog.new()
	d.title = str(mod_data.get("name", "?"))
	d.ok_button_text = "Close"
	# Clamped to the launcher: the fixed 660x540 exceeded the launcher's
	# 640x420 minimum in BOTH axes and got clipped by the embedder.
	d.min_size = _dialog_fit_size(Vector2i(660, 540))

	# Single content child for the AcceptDialog (it stacks added children over
	# the same rect): scroll on top, a download-status line pinned below it so
	# feedback stays visible regardless of scroll position.
	var outer := VBoxContainer.new()
	outer.add_theme_constant_override("separation", SP_S)
	d.add_child(outer)

	var scroll := ScrollContainer.new()
	# Track the (possibly clamped) dialog size, keeping the original
	# 20x60 chrome allowance (660x540 dialog held a 640x480 scroll).
	scroll.custom_minimum_size = Vector2(d.min_size - Vector2i(20, 60))
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	outer.add_child(scroll)

	# In-dialog download status. This modal is exclusive and covers the Browse
	# tab's status label, so a download started HERE used to fail (or dedupe)
	# with no visible feedback -- the button just flipped back to "Download".
	# The Download button below carries this Label in its
	# "browse_dialog_status" meta; build_browse_tab's set_dl_status mirror
	# fills it. Hidden until the first message so it costs no height. clip
	# + ellipsis, never autowrap: a long error must not inflate the dialog's
	# min width (the tooltip carries the full text, set by the mirror).
	var dl_status := Label.new()
	dl_status.visible = false
	dl_status.add_theme_font_size_override("font_size", FS_BODY)
	dl_status.add_theme_color_override("font_color", COL_TEXT_DIM)
	dl_status.clip_text = true
	dl_status.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	dl_status.mouse_filter = Control.MOUSE_FILTER_PASS
	outer.add_child(dl_status)

	# Right-margin wrap so content doesn't sit under the scrollbar -- same
	# trick the Browse tab's main list uses.
	var inner_wrap := MarginContainer.new()
	inner_wrap.add_theme_constant_override("margin_right", SP_XL)
	inner_wrap.add_theme_constant_override("margin_left", SP_S)
	inner_wrap.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(inner_wrap)

	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", SP_L)
	box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	inner_wrap.add_child(box)

	# Banner first if available, fall back to thumbnail. Both are Image
	# records at /mods/images/{file}; the loader caches by filename so a
	# thumbnail viewed here shares cache with the row's smaller render.
	var banner_record = mod_data.get("banner")
	var thumb_record = mod_data.get("thumbnail")
	var img_record = banner_record if banner_record is Dictionary else thumb_record
	# cover=false so the whole banner letterboxes inside the 220px band (the
	# cell's surface colour mattes it) instead of being cover-cropped; row
	# tiles keep the crop. Built only when there IS an image: unlike a 96x54
	# row tile, a 220px band captioned "no thumbnail" is worse than no band.
	if img_record is Dictionary:
		var banner_rect := _make_thumb_cell(box, Vector2(0, 220), false)
		_browse_load_thumbnail_async(banner_rect, img_record)

	var user_dict: Dictionary = mod_data.get("user", {}) if mod_data.get("user") is Dictionary else {}
	var category_dict: Dictionary = mod_data.get("category", {}) if mod_data.get("category") is Dictionary else {}
	var meta := Label.new()
	var parts := PackedStringArray()
	var author := str(user_dict.get("name", ""))
	if author != "":
		parts.append("by " + author)
	var version := str(mod_data.get("version", "")).strip_edges()
	if version != "":
		parts.append("v" + version)
	parts.append(str(_json_int(mod_data, "downloads")) + " downloads")
	parts.append(str(_json_int(mod_data, "likes")) + " likes")
	if category_dict.has("name"):
		parts.append(str(category_dict["name"]))
	var bumped := _format_iso_datetime(str(mod_data.get("bumped_at", "")))
	if bumped != "":
		parts.append("updated " + bumped)
	meta.text = " - ".join(parts)
	meta.add_theme_font_size_override("font_size", FS_META)
	meta.add_theme_color_override("font_color", COL_TEXT_DIM)
	meta.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(meta)

	# Description: prefer the long-form `desc`, fall back to `short_desc`.
	# ModWorkshop descriptions are Markdown (plus its {#hex}(...) color
	# extension). Convert to BBCode and render in a RichTextLabel so headings,
	# bold, lists, quotes, colors and links show instead of raw markup.
	var desc_str := str(mod_data.get("desc", "")).strip_edges()
	if desc_str.is_empty():
		desc_str = str(mod_data.get("short_desc", "")).strip_edges()
	if desc_str != "":
		box.add_child(HSeparator.new())
		var desc_hdr := Label.new()
		desc_hdr.text = "Description"
		desc_hdr.add_theme_font_size_override("font_size", FS_HEAD)
		desc_hdr.add_theme_color_override("font_color", COL_TEXT)
		box.add_child(desc_hdr)
		var desc_rt := RichTextLabel.new()
		desc_rt.bbcode_enabled = true
		desc_rt.text = _markdown_to_bbcode(desc_str)
		desc_rt.fit_content = true
		desc_rt.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		desc_rt.selection_enabled = true
		desc_rt.meta_underlined = true
		desc_rt.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		desc_rt.add_theme_color_override("default_color", COL_TEXT)
		# Markdown links become [url=...]; open them in the system browser.
		# Allowlist web schemes only. The URL comes from an untrusted remote
		# description; OS.shell_open is ShellExecute on Windows, so an unchecked
		# file://, UNC (\\host\share\x.exe), or custom-scheme link could launch
		# arbitrary handlers off a link whose visible text looks harmless.
		desc_rt.meta_clicked.connect(func(meta):
			var u := str(meta).strip_edges()
			if u.to_lower().begins_with("http://") or u.to_lower().begins_with("https://"):
				OS.shell_open(u)
		)
		box.add_child(desc_rt)

	box.add_child(HSeparator.new())
	var files_hdr := Label.new()
	files_hdr.text = "Files"
	files_hdr.add_theme_font_size_override("font_size", FS_HEAD)
	files_hdr.add_theme_color_override("font_color", COL_TEXT)
	box.add_child(files_hdr)
	var files_status := Label.new()
	files_status.text = "Loading file list..."
	files_status.add_theme_font_size_override("font_size", FS_BODY)
	files_status.add_theme_color_override("font_color", COL_TEXT_DIM)
	box.add_child(files_status)
	var files_list := VBoxContainer.new()
	files_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	box.add_child(files_list)

	var mod_id := int(mod_data.get("id", 0))
	# Pin Get + Open-page to the dialog's native button bar (alongside Close)
	# so they stay visible regardless of scroll position. add_button returns
	# the actual Button so we can update its text/disabled during the install
	# flow. right=false puts a button to the LEFT of the OK/Close button;
	# right=true puts it on the right.
	var page_btn := d.add_button("Open mod page in browser", false, "")
	page_btn.pressed.connect(func():
		OS.shell_open(MODWORKSHOP_PAGE_URL_TEMPLATE % str(mod_id))
	)
	# Check install state inline (no access to the build_browse_tab closures
	# from here). If installed, render Get as disabled "Installed" so the
	# button reflects reality -- enable toggling lives on the list row.
	var already_installed := false
	for entry in _ui_mod_entries:
		var cfg_e: ConfigFile = entry.get("cfg")
		if cfg_e == null or not cfg_e.has_section_key("updates", "modworkshop"):
			continue
		if int(str(cfg_e.get_value("updates", "modworkshop", "0"))) == mod_id:
			already_installed = true
			break
	var get_btn := d.add_button("Installed" if already_installed else "Download", true, "")
	if already_installed:
		get_btn.disabled = true
	else:
		# The dialog's one primary action (spec section 6). List rows keep
		# bare-theme Download buttons -- primary is at most one per surface.
		style_primary_button(get_btn)
		# Tag the button with the in-dialog status label so the Browse tab's
		# download paths (set_dl_status) render feedback inside this dialog.
		get_btn.set_meta("browse_dialog_status", dl_status)
		var captured_data := mod_data
		get_btn.pressed.connect(func():
			on_get.call(captured_data, get_btn)
		)

	var primary_file_id := _json_int(mod_data, "download_id")
	var load_files := func():
		var files_resp: Variant = await mws_list_files(mod_id)
		if not is_instance_valid(files_status):
			return
		if not (files_resp is Dictionary):
			files_status.text = mws_error_status("Could not load the file list. Check your connection and try again.")
			files_status.add_theme_color_override("font_color", COL_ERR)
			return
		var files: Array = _mws_data_rows(files_resp)
		if files.is_empty():
			files_status.text = "No downloadable files yet."
			return
		files_status.queue_free()
		for file_v in files:
			if not (file_v is Dictionary):
				continue
			var fd: Dictionary = file_v
			var f_row := HBoxContainer.new()
			f_row.add_theme_constant_override("separation", SP_L)
			files_list.add_child(f_row)

			var v_lbl := Label.new()
			var v_str: String = "v" + str(fd.get("version", ""))
			if _json_int(fd, "id") == primary_file_id and primary_file_id > 0:
				v_str += " (primary)"
			v_lbl.text = v_str
			v_lbl.custom_minimum_size.x = 140
			v_lbl.clip_text = true
			v_lbl.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
			v_lbl.tooltip_text = v_lbl.text
			v_lbl.mouse_filter = Control.MOUSE_FILTER_PASS
			f_row.add_child(v_lbl)

			var size_lbl := Label.new()
			size_lbl.text = _format_size(_json_int(fd, "size"))
			size_lbl.custom_minimum_size.x = 80
			size_lbl.add_theme_color_override("font_color", COL_TEXT_DIM)
			f_row.add_child(size_lbl)

			var date_str := str(fd.get("created_at", ""))
			if date_str.contains("T"):
				date_str = date_str.split("T")[0]
			var date_lbl := Label.new()
			date_lbl.text = date_str
			date_lbl.add_theme_color_override("font_color", COL_TEXT_DIM)
			f_row.add_child(date_lbl)
	load_files.call()

	_attach_ui_dialog(d)
	_wire_accept_dismiss(d)
	d.popup_centered()


