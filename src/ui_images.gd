## Thumbnail controls, image decoding, disk cache and session texture cache.
## Async completions check the target control before updating it.

# Decode an image buffer by sniffing its magic bytes rather than trying every
# decoder in turn: each failed attempt pushes engine errors into the console,
# and an HTML error page or truncated download would print nine of them.
# Returns null when the buffer is not a supported format.
func _decode_image_buffer(bytes: PackedByteArray) -> Image:
	if bytes.size() < 12:
		return null
	var img := Image.new()
	# PNG: 89 'P' 'N' 'G'
	if bytes[0] == 0x89 and bytes[1] == 0x50 and bytes[2] == 0x4E and bytes[3] == 0x47:
		return img if img.load_png_from_buffer(bytes) == OK else null
	# JPEG: FF D8 FF
	if bytes[0] == 0xFF and bytes[1] == 0xD8 and bytes[2] == 0xFF:
		return img if img.load_jpg_from_buffer(bytes) == OK else null
	# WebP: "RIFF" <4-byte size> "WEBP"
	if bytes[0] == 0x52 and bytes[1] == 0x49 and bytes[2] == 0x46 and bytes[3] == 0x46 \
			and bytes[8] == 0x57 and bytes[9] == 0x45 and bytes[10] == 0x42 and bytes[11] == 0x50:
		return img if img.load_webp_from_buffer(bytes) == OK else null
	return null

# Caption for a thumbnail cell with no texture yet, centered in the cell's
# parent PanelContainer. Three states, so a fetch in flight, a host that
# has no image, and a broken download do not look alike. Safe to call after
# awaits and idempotent per cell.
const _THUMB_STATE_TEXT := {"loading": "loading...", "none": "no thumbnail", "failed": "load failed"}

func _set_thumb_state(rect: TextureRect, state: String) -> void:
	if not is_instance_valid(rect):
		return
	var wrap := rect.get_parent() as Control
	if not is_instance_valid(wrap):
		return
	var caption: String = _THUMB_STATE_TEXT.get(state, state)
	if wrap.has_node("ThumbStateLabel"):
		var existing := wrap.get_node("ThumbStateLabel") as Label
		if existing != null:
			existing.text = caption
		return
	var lbl := Label.new()
	lbl.name = "ThumbStateLabel"
	lbl.text = caption
	lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	lbl.add_theme_color_override("font_color", COL_TEXT_DIM)
	lbl.add_theme_font_size_override("font_size", FS_META)
	wrap.add_child(lbl)

# Paint a texture into a thumbnail cell, clearing the state caption first.
# Every texture-setting path goes through here.
func _set_thumb_ready(rect: TextureRect, tex: Texture2D) -> void:
	if not is_instance_valid(rect):
		return
	var wrap := rect.get_parent() as Control
	if is_instance_valid(wrap) and wrap.has_node("ThumbStateLabel"):
		var stale := wrap.get_node("ThumbStateLabel")
		wrap.remove_child(stale)
		stale.queue_free()
	rect.texture = tex

# Build an image cell: a surface-coloured PanelContainer holding a TextureRect,
# captioned "loading..." until an image lands or the loader reports that
# there is none or the fetch failed. Every image cell in the
# launcher (Mods rows, Browse rows, the detail banner) comes from here.
# cover=true crops to fill, for small row tiles; cover=false letterboxes so
# the whole image stays visible (the detail banner). shrink_center keeps the
# cell at its natural height. Returns the TextureRect to paint into.
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
	_set_thumb_state(rect, "loading")
	return rect


# Session memo of decoded thumbnail textures keyed by storage filename, so a
# Mods-tab rebuild or Browse re-render does not re-read and re-decode every
# image. FIFO-bounded (Dictionary preserves insertion order).
var _thumb_texture_cache: Dictionary = {}
const _THUMB_TEXTURE_CACHE_MAX := 256

func _thumb_texture_cache_store(fn: String, tex: Texture2D) -> void:
	while _thumb_texture_cache.size() >= _THUMB_TEXTURE_CACHE_MAX:
		_thumb_texture_cache.erase(_thumb_texture_cache.keys()[0])
	_thumb_texture_cache[fn] = tex


# Async thumbnail loader for an ImageRef {url, thumb_url, cache_key}. A
# non-empty cache_key is the on-disk cache filename under user://mws_cache/thumbs/;
# "" means the host promises nothing, so the image lives only in the session memo.
func _browse_load_thumbnail_async(rect: TextureRect, image: Dictionary) -> void:
	var url := str(image.get("url", ""))
	if url.is_empty():
		_set_thumb_state(rect, "none")
		return
	# Host-provided key headed into a path: accept only a bare basename.
	var cache_key := str(image.get("cache_key", ""))
	if cache_key != "" and not _is_safe_basename(cache_key):
		cache_key = ""
	var memo_key := cache_key if cache_key != "" else url

	var memo_tex_v: Variant = _thumb_texture_cache.get(memo_key)
	if memo_tex_v is Texture2D:
		_set_thumb_ready(rect, memo_tex_v as Texture2D)
		return

	var cache_path := ""
	if cache_key != "":
		var cache_dir := "user://mws_cache/thumbs"
		DirAccess.make_dir_recursive_absolute(cache_dir)
		cache_path = cache_dir.path_join(cache_key)
		# Disk hit; a decode error falls through to a refetch.
		if FileAccess.file_exists(cache_path):
			var f := FileAccess.open(cache_path, FileAccess.READ)
			if f != null:
				var bytes := f.get_buffer(f.get_length())
				f.close()
				if bytes.size() > 0:
					var img := _decode_image_buffer(bytes)
					if img != null:
						var disk_tex := ImageTexture.create_from_image(img)
						_thumb_texture_cache_store(memo_key, disk_tex)
						_set_thumb_ready(rect, disk_tex)
						return

	_set_thumb_state(rect, "loading")
	# 1MB cap defends against a malformed response; real covers run 100-300KB.
	var req := HTTPRequest.new()
	req.timeout = API_CHECK_TIMEOUT
	req.download_body_size_limit = 1024 * 1024
	add_child(req)
	var err := req.request(url, PackedStringArray(["User-Agent: " + (HOST_USER_AGENT_TEMPLATE % MODLOADER_VERSION)]))
	if err != OK:
		req.queue_free()
		_set_thumb_state(rect, "failed")
		return

	var res: Array = await req.request_completed
	req.queue_free()
	if res[0] != HTTPRequest.RESULT_SUCCESS or res[1] < 200 or res[1] >= 300:
		_set_thumb_state(rect, "failed")
		return
	var body: PackedByteArray = res[3]
	if body.is_empty():
		_set_thumb_state(rect, "failed")
		return

	var img := _decode_image_buffer(body)
	if img == null:
		_set_thumb_state(rect, "failed")
		return

	# The CDN serves full-size images while row cells render at 96x54, so
	# downscale before caching. The detail banner reads the same cache at
	# about 220px tall, so cap the longest side at 640px rather than keying
	# a separate small variant. Re-encoded as lossy WebP; the cache-hit
	# reader sniffs the format, so the container swap is safe.
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

	# Stash for next launch; a failed write only means a refetch next time.
	# store_buffer returns bool; drop a partial file rather than leave a
	# truncated cache entry.
	if cache_path != "":
		var out := FileAccess.open(cache_path, FileAccess.WRITE)
		if out != null:
			var wrote := out.store_buffer(cache_bytes)
			out.close()
			if not wrote:
				DirAccess.remove_absolute(cache_path)

	var net_tex := ImageTexture.create_from_image(img)
	_thumb_texture_cache_store(memo_key, net_tex)
	_set_thumb_ready(rect, net_tex)
