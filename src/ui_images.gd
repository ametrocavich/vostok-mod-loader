# Thumbnail cells, image decoding, and the disk and in-memory texture caches.

# Sniff the magic bytes instead of trying each decoder: every failed attempt
# prints engine errors, nine for an HTML error page. Null when unsupported.
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
		# libwebp's still-image API refuses the VP8X animation flag (byte 20; VP8X
		# is always the first chunk), and both hosts serve animated covers.
		if bytes.size() >= 30 and bytes[12] == 0x56 and bytes[13] == 0x50 \
				and bytes[14] == 0x38 and bytes[15] == 0x58 and (bytes[20] & 0x02) != 0:
			return _webp_first_frame(bytes)
		return img if img.load_webp_from_buffer(bytes) == OK else null
	return null


# An ANMF payload holds X/2, Y/2, width-1, height-1 and duration as 24-bit LE
# fields and a flags byte, then an optional ALPH and one VP8 or VP8L chunk.
func _webp_first_frame(bytes: PackedByteArray) -> Image:
	var canvas := Vector2i(_webp_u24(bytes, 24) + 1, _webp_u24(bytes, 27) + 1)
	var body := -1
	var size := 0
	var pos := 12
	while pos + 8 <= bytes.size():
		size = bytes.decode_u32(pos + 4)
		if pos + 8 + size > bytes.size():
			return null
		if bytes.slice(pos, pos + 4).get_string_from_ascii() == "ANMF":
			body = pos + 8
			break
		pos += 8 + size + (size & 1)
	if body < 0 or size < 16:
		return null
	var offset := Vector2i(_webp_u24(bytes, body) * 2, _webp_u24(bytes, body + 3) * 2)
	var frame_size := Vector2i(_webp_u24(bytes, body + 6) + 1, _webp_u24(bytes, body + 9) + 1)
	var alph := PackedByteArray()
	var bitstream := PackedByteArray()
	pos = body + 16
	var end := body + size
	while pos + 8 <= end and bitstream.is_empty():
		var chunk_size := bytes.decode_u32(pos + 4)
		if pos + 8 + chunk_size > end:
			return null
		var tag := bytes.slice(pos, pos + 4).get_string_from_ascii()
		if tag == "ALPH":
			alph = bytes.slice(pos, pos + 8 + chunk_size)
		elif tag == "VP8 " or tag == "VP8L":
			bitstream = bytes.slice(pos, pos + 8 + chunk_size)
		pos += 8 + chunk_size + (chunk_size & 1)
	if bitstream.is_empty():
		return null
	var chunks: Array[PackedByteArray] = [bitstream]
	# A still file may carry ALPH only behind a VP8X header whose canvas is
	# the frame. VP8L holds its own alpha.
	if not alph.is_empty() and bitstream[3] == 0x20:
		var w := frame_size.x - 1
		var h := frame_size.y - 1
		var vp8x := PackedByteArray([0x56, 0x50, 0x38, 0x58, 10, 0, 0, 0, 0x10, 0, 0, 0,
				w & 0xFF, (w >> 8) & 0xFF, (w >> 16) & 0xFF, h & 0xFF, (h >> 8) & 0xFF, (h >> 16) & 0xFF])
		chunks = [vp8x, alph, bitstream]
	var riff_body := "WEBP".to_ascii_buffer()
	for chunk in chunks:
		riff_body.append_array(chunk)
		if chunk.size() % 2 == 1:
			riff_body.append(0)
	var still := "RIFF".to_ascii_buffer()
	still.resize(8)
	still.encode_u32(4, riff_body.size())
	still.append_array(riff_body)
	var frame := Image.new()
	if frame.load_webp_from_buffer(still) != OK:
		return null
	if offset == Vector2i.ZERO and frame.get_size() == canvas:
		return frame
	# Past 4096x4096 the canvas is not worth allocating for a thumbnail.
	if canvas.x * canvas.y > 4096 * 4096:
		return frame
	var full := Image.create_empty(canvas.x, canvas.y, false, Image.FORMAT_RGBA8)
	frame.convert(Image.FORMAT_RGBA8)
	full.blit_rect(frame, Rect2i(Vector2i.ZERO, frame.get_size()), offset)
	return full


func _webp_u24(bytes: PackedByteArray, at: int) -> int:
	return bytes[at] | (bytes[at + 1] << 8) | (bytes[at + 2] << 16)


const _THUMB_STATE_TEXT := {"loading": "loading...", "none": "no thumbnail", "failed": "load failed"}

func _set_thumb_state(rect: TextureRect, state: String) -> void:
	if not is_instance_valid(rect):
		return
	var wrap := rect.get_parent() as Control
	if not is_instance_valid(wrap):
		return
	var caption: String = _THUMB_STATE_TEXT[state]
	var existing := wrap.get_node_or_null("ThumbStateLabel") as Label
	if existing != null:
		existing.text = caption
		return
	var lbl := _make_label(caption, COL_TEXT_DIM, FS_META)
	lbl.name = "ThumbStateLabel"
	lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	wrap.add_child(lbl)


func _set_thumb_ready(rect: TextureRect, tex: Texture2D) -> void:
	if not is_instance_valid(rect):
		return
	var wrap := rect.get_parent() as Control
	if is_instance_valid(wrap) and wrap.has_node("ThumbStateLabel"):
		var stale := wrap.get_node("ThumbStateLabel")
		wrap.remove_child(stale)
		stale.queue_free()
	rect.texture = tex


# cover crops to fill (row tiles); otherwise the image is letterboxed (the detail banner).
func _make_thumb_cell(parent: Control, min_size: Vector2, cover: bool = true,
		shrink_center: bool = false) -> TextureRect:
	var wrap := PanelContainer.new()
	wrap.custom_minimum_size = min_size
	if shrink_center:
		wrap.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	wrap.add_theme_stylebox_override("panel", _make_box(COL_SURFACE_2))
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


# Decoded textures by cache key, FIFO-bounded (Dictionary keeps insertion order).
var _thumb_texture_cache: Dictionary = {}
const _THUMB_TEXTURE_CACHE_MAX := 256
# URL -> msec until which a failed fetch is not asked again, so rebuilds share one try.
var _thumb_failed: Dictionary = {}
const _THUMB_RETRY_MS := 30000

func _memo_thumb(memo_key: String, img: Image) -> ImageTexture:
	var tex := ImageTexture.create_from_image(img)
	while _thumb_texture_cache.size() >= _THUMB_TEXTURE_CACHE_MAX:
		_thumb_texture_cache.erase(_thumb_texture_cache.keys()[0])
	_thumb_texture_cache[memo_key] = tex
	return tex


# A disk key for a cover whose host sends none.
func _url_thumb_key(url: String) -> String:
	return "" if url == "" else "url_" + url.sha256_text().left(32)


# cache_key "" means the host promises no immutability: memory only, never disk.
func _browse_load_thumbnail_async(rect: TextureRect, image: Dictionary) -> void:
	var url := str(image.get("url", ""))
	if url.is_empty():
		_set_thumb_state(rect, "none")
		return
	# The host's key becomes a file name: a bare basename only.
	var cache_key := str(image.get("cache_key", ""))
	if cache_key != "" and not _is_safe_basename(cache_key):
		cache_key = ""
	var memo_key := cache_key if cache_key != "" else url

	if _thumb_texture_cache.has(memo_key):
		_set_thumb_ready(rect, _thumb_texture_cache[memo_key])
		return
	if Time.get_ticks_msec() < int(_thumb_failed.get(url, 0)):
		_set_thumb_state(rect, "failed")
		return

	var cache_path := ""
	if cache_key != "":
		var cache_dir := UI_CACHE_DIR.path_join("thumbs")
		DirAccess.make_dir_recursive_absolute(cache_dir)
		cache_path = cache_dir.path_join(cache_key)
		var disk_img := _read_thumb_cache(cache_path)
		if disk_img != null:
			_set_thumb_ready(rect, _memo_thumb(memo_key, disk_img))
			return

	# Again, not only at cell creation: the detail banner repaints a cell that
	# already shows the thumbnail.
	_set_thumb_state(rect, "loading")
	var body: PackedByteArray = await _fetch_thumb(url)
	# A rebuild may have freed the cell; a freed object fails a typed argument.
	var alive := is_instance_valid(rect)
	var img := _decode_image_buffer(body)
	if img == null:
		_thumb_failed[url] = Time.get_ticks_msec() + _THUMB_RETRY_MS
		if alive:
			_set_thumb_state(rect, "failed")
		return
	_write_thumb_cache(cache_path, img, body)
	var tex := _memo_thumb(memo_key, img)
	if alive:
		_set_thumb_ready(rect, tex)


func _read_thumb_cache(cache_path: String) -> Image:
	if not FileAccess.file_exists(cache_path):
		return null
	var f := FileAccess.open(cache_path, FileAccess.READ)
	if f == null:
		return null
	var bytes := f.get_buffer(f.get_length())
	f.close()
	if bytes.is_empty():
		return null
	return _decode_image_buffer(bytes)


func _fetch_thumb(url: String) -> PackedByteArray:
	# Covers are full uploads, often over 1 MB, and HTTPRequest's timeout spans
	# the whole download, so this one is longer than the API's.
	var req := HTTPRequest.new()
	req.timeout = 60.0
	req.body_size_limit = 8 * 1024 * 1024
	add_child(req)
	var err := req.request(url, PackedStringArray([_host_user_agent_header()]))
	if err != OK:
		req.queue_free()
		return PackedByteArray()
	var res: Array = await req.request_completed
	req.queue_free()
	if res[0] != HTTPRequest.RESULT_SUCCESS or res[1] < 200 or res[1] >= 300:
		return PackedByteArray()
	return res[3]


# Shrinks img in place to 640 px (the detail banner's size; rows show 96x54) and,
# with a cache_path, stores it as lossy WebP. The cache reader sniffs the format.
func _write_thumb_cache(cache_path: String, img: Image, body: PackedByteArray) -> void:
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
	# A failed write only costs a refetch; a partial file would be a bad entry.
	if cache_path != "":
		var out := FileAccess.open(cache_path, FileAccess.WRITE)
		if out != null:
			var wrote := out.store_buffer(cache_bytes)
			out.close()
			if not wrote:
				DirAccess.remove_absolute(cache_path)
