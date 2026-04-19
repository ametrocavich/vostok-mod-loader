## ----- gdsc_detokenizer.gd -----
## Reads Godot's binary-tokenized .gdc scripts and reconstructs the source.
## Required because load().source_code is empty for scripts compiled via the
## tokenized export path. Covers TOKENIZER_VERSION 100 (Godot 4.0-4.4) and
## 101 (Godot 4.5-4.6). Also owns the vanilla-source cache helpers.

# --- GDSC Binary Token Detokenizer -------------------------------------------
# Reconstructs GDScript source from Godot's binary-tokenized .gdc format (GDSC).
# Used when the game exports with binary tokenization and load().source_code is
# empty.  Called for all class_name scripts during hook pack generation.
# Supports TOKENIZER_VERSION 100 (Godot 4.0-4.4) and 101 (Godot 4.5-4.6).

const _GDSC_MAGIC := "GDSC"
const _GDSC_TOKEN_BITS := 8
const _GDSC_TOKEN_MASK := (1 << (_GDSC_TOKEN_BITS - 1)) - 1  # 0x7F
const _GDSC_TOKEN_BYTE_MASK := 0x80

# Token type indices -- Godot 4.5-4.6 / TOKENIZER_VERSION 101.
# 0=EMPTY 1=ANNOTATION 2=IDENTIFIER 3=LITERAL
# 4-9: < <= > >= == !=   10-15: and or not && || !
# 16-21: & | ~ ^ << >>   22-27: + - * ** / %
# 28-39: = += -= *= **= /= %= <<= >>= &= |= ^=
# 40-50: if elif else for while break continue pass return match when
# 51-72: as assert await breakpoint class class_name const enum extends func
#        in is namespace preload self signal static super trait var void yield
# 73-78: [ ] { } ( )   79-87: , ; . .. ... : $ -> _
# 88-90: NEWLINE INDENT DEDENT   91-94: PI TAU INF NAN   99: EOF
#
# Raw int keys are used in dictionaries below because Godot does not allow
# enum references in const dictionary initializers.
const _TOKEN_TEXT := {
	4: "<", 5: "<=", 6: ">", 7: ">=", 8: "==", 9: "!=",
	10: "and", 11: "or", 12: "not", 13: "&&", 14: "||", 15: "!",
	16: "&", 17: "|", 18: "~", 19: "^", 20: "<<", 21: ">>",
	22: "+", 23: "-", 24: "*", 25: "**", 26: "/", 27: "%",
	28: "=", 29: "+=", 30: "-=", 31: "*=", 32: "**=", 33: "/=",
	34: "%=", 35: "<<=", 36: ">>=", 37: "&=", 38: "|=", 39: "^=",
	40: "if", 41: "elif", 42: "else", 43: "for", 44: "while",
	45: "break", 46: "continue", 47: "pass", 48: "return", 49: "match", 50: "when",
	51: "as", 52: "assert", 53: "await", 54: "breakpoint", 55: "class",
	56: "class_name", 57: "const", 58: "enum", 59: "extends", 60: "func",
	61: "in", 62: "is", 63: "namespace", 64: "preload", 65: "self",
	66: "signal", 67: "static", 68: "super", 69: "trait", 70: "var",
	71: "void", 72: "yield",
	73: "[", 74: "]", 75: "{", 76: "}", 77: "(", 78: ")",
	79: ",", 80: ";", 81: ".", 82: "..", 83: "...",
	84: ":", 85: "$", 86: "->", 87: "_",
	91: "PI", 92: "TAU", 93: "INF", 94: "NAN",
	96: "`", 97: "?",
}

# Tokens that want a space BEFORE them (binary operators, keywords after exprs).
const _SPACE_BEFORE := {
	4: 1, 5: 1, 6: 1, 7: 1, 8: 1, 9: 1,      # < <= > >= == !=
	10: 1, 11: 1, 12: 1, 13: 1, 14: 1,         # and or not && ||
	16: 1, 17: 1, 19: 1, 20: 1, 21: 1,          # & | ^ << >>
	22: 1, 23: 1, 24: 1, 25: 1, 26: 1, 27: 1,  # + - * ** / %
	28: 1, 29: 1, 30: 1, 31: 1, 32: 1, 33: 1,  # = += -= *= **= /=
	34: 1, 35: 1, 36: 1, 37: 1, 38: 1, 39: 1,  # %= <<= >>= &= |= ^=
	40: 1, 42: 1, 51: 1, 61: 1, 62: 1,          # if else as in is
	86: 1,                                        # ->
}

# Tokens that want a space AFTER them.
const _SPACE_AFTER := {
	79: 1, 80: 1, 86: 1,                          # , ; ->
	4: 1, 5: 1, 6: 1, 7: 1, 8: 1, 9: 1,          # < <= > >= == !=
	10: 1, 11: 1, 12: 1, 13: 1, 14: 1, 15: 1,    # and or not && || !
	16: 1, 17: 1, 19: 1, 20: 1, 21: 1,            # & | ^ << >>
	22: 1, 23: 1, 24: 1, 25: 1, 26: 1, 27: 1,    # + - * ** / %
	28: 1, 29: 1, 30: 1, 31: 1, 32: 1, 33: 1,    # = += -= *= **= /=
	34: 1, 35: 1, 36: 1, 37: 1, 38: 1, 39: 1,    # %= <<= >>= &= |= ^=
	84: 1,                                          # :
	1: 1,                                           # @ annotations
	# All keywords (40-72) need space after:
	40: 1, 41: 1, 42: 1, 43: 1, 44: 1,            # if elif else for while
	45: 1, 46: 1, 47: 1, 48: 1, 49: 1, 50: 1,    # break continue pass return match when
	51: 1, 52: 1, 53: 1, 54: 1, 55: 1,            # as assert await breakpoint class
	56: 1, 57: 1, 58: 1, 59: 1, 60: 1,            # class_name const enum extends func
	61: 1, 62: 1, 63: 1, 64: 1, 65: 1,            # in is namespace preload self
	66: 1, 67: 1, 68: 1, 69: 1, 70: 1,            # signal static super trait var
	71: 1, 72: 1,                                   # void yield
}

func _detokenize_script(script_path: String) -> String:
	# Zero-byte PCK entries (base game ships CasettePlayer.gd empty in RTV
	# 4.6.1) have nothing to decode. Return empty silently so callers don't
	# misread this as an IO failure.
	if _pck_zero_byte_paths.has(script_path):
		return ""
	# Try multiple methods to read raw bytes -- FileAccess on res:// can fail for
	# PCK-embedded files depending on the container format (RSCC, encryption, etc.).
	var raw := PackedByteArray()

	# Method 1: FileAccess.open() on res:// path directly.
	var f := FileAccess.open(script_path, FileAccess.READ)
	if f:
		raw = f.get_buffer(f.get_length())
		f.close()

	# Method 2: Try the globalized path.
	if raw.is_empty():
		var glob_path := ProjectSettings.globalize_path(script_path)
		f = FileAccess.open(glob_path, FileAccess.READ)
		if f:
			raw = f.get_buffer(f.get_length())
			f.close()

	# Method 3: Try loading as a generic Resource and check if it has raw data.
	# (GDScript objects loaded from tokenized files don't expose raw bytes, but
	# we can try get_file_as_bytes with .gdc extension in case Godot mapped it.)
	if raw.is_empty():
		var gdc_path := script_path.replace(".gd", ".gdc")
		raw = FileAccess.get_file_as_bytes(gdc_path)

	if raw.is_empty():
		_log_warning("[Detokenize] Cannot read bytes from: %s (tried res://, globalized, .gdc)" % script_path)
		return ""

	# -- Header (12 bytes) --
	if raw.size() < 12:
		return ""
	var magic := raw.slice(0, 4).get_string_from_ascii()
	if magic != _GDSC_MAGIC:
		# Not a GDSC file -- might be plain text that load() failed on for another reason.
		var text := raw.get_string_from_utf8()
		if not text.is_empty() and (text.begins_with("extends") or text.begins_with("class_name") or text.begins_with("@")):
			return text
		_log_warning("[Detokenize] Not a GDSC file: " + script_path)
		return ""

	var version := raw.decode_u32(4)
	if version != 100 and version != 101:
		_log_critical("[Detokenize] Unsupported GDSC version %d in %s (expected 100 or 101)" % [version, script_path])
		return ""

	var decompressed_size := raw.decode_u32(8)
	var buf: PackedByteArray
	if decompressed_size == 0:
		buf = raw.slice(12)
	else:
		var compressed := raw.slice(12)
		buf = compressed.decompress(decompressed_size, FileAccess.COMPRESSION_ZSTD)
		if buf.is_empty():
			_log_critical("[Detokenize] ZSTD decompression failed for: " + script_path)
			return ""

	# -- Metadata --
	var meta_size := 20 if version == 100 else 16  # v100 has 4-byte padding
	if buf.size() < meta_size:
		return ""
	var ident_count: int = buf.decode_u32(0)
	var const_count: int = buf.decode_u32(4)
	var line_count: int  = buf.decode_u32(8)
	var token_count: int
	if version == 100:
		token_count = buf.decode_u32(16)
	else:
		token_count = buf.decode_u32(12)

	var offset := meta_size

	# -- Identifiers (XOR 0xb6 encoded UTF-32) --
	var identifiers: Array[String] = []
	for _i in ident_count:
		if offset + 4 > buf.size():
			break
		var str_len: int = buf.decode_u32(offset)
		offset += 4
		var s := ""
		for _j in str_len:
			if offset + 4 > buf.size():
				break
			var b0: int = buf[offset] ^ 0xb6
			var b1: int = buf[offset + 1] ^ 0xb6
			var b2: int = buf[offset + 2] ^ 0xb6
			var b3: int = buf[offset + 3] ^ 0xb6
			var code_point: int = b0 | (b1 << 8) | (b2 << 16) | (b3 << 24)
			if code_point > 0:
				s += String.chr(code_point)
			offset += 4
		identifiers.append(s)

	# -- Constants (Variant-encoded, sequential) --
	var constants: Array = []
	for _i in const_count:
		if offset + 4 > buf.size():
			break
		# Decode next Variant from the stream.  We round-trip through
		# var_to_bytes() to determine consumed size since bytes_to_var()
		# doesn't report how many bytes it read.
		var remaining := buf.slice(offset)
		var val = bytes_to_var(remaining)
		constants.append(val)
		# Advance offset by the encoded size.
		var encoded := var_to_bytes(val)
		offset += encoded.size()

	# -- Line/column maps --
	var line_map := {}  # token_index -> line
	var col_map := {}   # token_index -> column
	for _i in line_count:
		if offset + 8 > buf.size():
			break
		var tok_idx: int = buf.decode_u32(offset)
		var line_val: int = buf.decode_u32(offset + 4)
		line_map[tok_idx] = line_val
		offset += 8
	for _i in line_count:
		if offset + 8 > buf.size():
			break
		var tok_idx: int = buf.decode_u32(offset)
		var col_val: int = buf.decode_u32(offset + 4)
		col_map[tok_idx] = col_val
		offset += 8

	# -- Token stream --
	var tokens: Array = []  # Array of [type: int, data_index: int]
	for _i in token_count:
		if offset >= buf.size():
			break
		var token_len := 8 if (buf[offset] & _GDSC_TOKEN_BYTE_MASK) else 5
		if offset + token_len > buf.size():
			break
		var raw_type: int = buf.decode_u32(offset)
		var tk_type: int = raw_type & _GDSC_TOKEN_MASK
		var data_idx: int = raw_type >> _GDSC_TOKEN_BITS
		tokens.append([tk_type, data_idx])
		offset += token_len

	var result := _gdsc_reconstruct(tokens, identifiers, constants, line_map, col_map)
	if result.is_empty():
		return ""
	_log_info("[Detokenize] Reconstructed: %s (%d tokens, %d lines) -- parse OK" \
			% [script_path, tokens.size(), result.count("\n") + 1])
	return result

func _gdsc_reconstruct(tokens: Array, identifiers: Array[String], constants: Array,
		line_map: Dictionary, col_map: Dictionary) -> String:
	var lines := PackedStringArray()
	var current_line := ""
	var current_line_num := 1
	var need_space := false
	var prev_tk := -1
	var line_started := false  # has any visible token been emitted on this line?

	for i in tokens.size():
		var tk: int = tokens[i][0]
		var idx: int = tokens[i][1]

		# Handle line changes via line_map.
		if line_map.has(i):
			var new_line: int = line_map[i]
			while current_line_num < new_line:
				lines.append(current_line)
				current_line = ""
				current_line_num += 1
				need_space = false
				line_started = false

		if tk == 99:  # EOF
			break

		if tk == 88:  # NEWLINE
			lines.append(current_line)
			current_line = ""
			current_line_num += 1
			need_space = false
			line_started = false
			prev_tk = tk
			continue

		if tk == 89 or tk == 90:  # INDENT / DEDENT -- skip, we use col_map instead
			prev_tk = tk
			continue

		# Build the text for this token.
		var text := ""
		if tk == 2:  # IDENTIFIER
			text = identifiers[idx] if idx < identifiers.size() else "<ident?>"
		elif tk == 1:  # ANNOTATION
			var aname: String = identifiers[idx] if idx < identifiers.size() else "?"
			text = aname if aname.begins_with("@") else ("@" + aname)
		elif tk == 3:  # LITERAL
			text = _gdsc_variant_to_source(constants[idx] if idx < constants.size() else null)
		elif _TOKEN_TEXT.has(tk):
			text = _TOKEN_TEXT[tk]
		else:
			text = "<tk%d>" % tk

		# Apply indentation from column data for the first visible token on a line.
		if not line_started:
			line_started = true
			if col_map.has(i):
				var col: int = col_map[i]
				# Convert column to tabs (Godot uses tab_size=4 for indentation).
				var tabs: int = col / 4
				for _t in tabs:
					current_line += "\t"

		# Spacing logic.
		var add_space_before := false
		if need_space and not current_line.is_empty() and not current_line.ends_with("\t"):
			if _SPACE_BEFORE.has(tk):
				add_space_before = true
			elif tk == 2 or tk == 3 or tk == 1 or (tk >= 40 and tk <= 72):
				# IDENTIFIER, LITERAL, ANNOTATION, or any keyword -- space before
				# unless prev was an opener, dot, $, ~, !, indent, newline.
				# Note: annotation (1) excluded only for identifiers (part of the
				# annotation name), NOT for keywords like var/func after @export.
				var skip_anno := (prev_tk == 1 and (tk == 2 or tk == 1))  # ident/anno after anno
				if not skip_anno \
						and prev_tk != 77 and prev_tk != 73 \
						and prev_tk != 81 and prev_tk != 85 \
						and prev_tk != 18 \
						and prev_tk != 15 and prev_tk != 89 \
						and prev_tk != 88 and prev_tk != -1:
					add_space_before = true
			elif tk == 77:  # PAREN_OPEN
				# Space before ( after control-flow keywords, but NOT after
				# function-like keywords (func, preload, super, assert, await).
				if prev_tk >= 40 and prev_tk <= 50:  # if..when (control flow)
					add_space_before = true
			elif tk == 12 or tk == 15:  # NOT, BANG
				add_space_before = true

		if add_space_before and not current_line.ends_with(" ") and not current_line.ends_with("\t"):
			current_line += " "

		current_line += text

		# Set need_space for next token.  _SPACE_AFTER covers operators,
		# keywords, and punctuation.  Also need space after identifiers (2),
		# literals (3), close-parens (78), close-bracket (74), close-brace (76),
		# constants (91-94 PI/TAU/INF/NAN), and underscore (87).
		need_space = _SPACE_AFTER.has(tk) or tk == 2 or tk == 3 \
				or tk == 78 or tk == 74 or tk == 76 \
				or tk == 91 or tk == 92 or tk == 93 \
				or tk == 94 or tk == 87

		prev_tk = tk

	# Flush last line.
	if not current_line.is_empty():
		lines.append(current_line)

	# GDScript files should end with newline.
	var result := "\n".join(lines)
	if not result.ends_with("\n"):
		result += "\n"
	return result

func _gdsc_variant_to_source(value: Variant) -> String:
	if value == null:
		return "null"
	match typeof(value):
		TYPE_BOOL:
			return "true" if value else "false"
		TYPE_INT:
			return str(value)
		TYPE_FLOAT:
			var s := str(value)
			if "." not in s and "e" not in s and "inf" not in s.to_lower() and "nan" not in s.to_lower():
				s += ".0"
			return s
		TYPE_STRING:
			return '"%s"' % str(value).c_escape()
		TYPE_STRING_NAME:
			return '&"%s"' % str(value).c_escape()
		TYPE_NODE_PATH:
			return '^"%s"' % str(value).c_escape()
		TYPE_VECTOR2:
			return "Vector2(%s, %s)" % [_gdsc_variant_to_source(value.x), _gdsc_variant_to_source(value.y)]
		TYPE_VECTOR2I:
			return "Vector2i(%s, %s)" % [value.x, value.y]
		TYPE_VECTOR3:
			return "Vector3(%s, %s, %s)" % [_gdsc_variant_to_source(value.x), _gdsc_variant_to_source(value.y), _gdsc_variant_to_source(value.z)]
		TYPE_VECTOR3I:
			return "Vector3i(%s, %s, %s)" % [value.x, value.y, value.z]
		TYPE_COLOR:
			return "Color(%s, %s, %s, %s)" % [_gdsc_variant_to_source(value.r), _gdsc_variant_to_source(value.g), _gdsc_variant_to_source(value.b), _gdsc_variant_to_source(value.a)]
		TYPE_ARRAY:
			var parts := PackedStringArray()
			for item in value:
				parts.append(_gdsc_variant_to_source(item))
			return "[%s]" % ", ".join(parts)
		TYPE_DICTIONARY:
			var parts := PackedStringArray()
			for k in value:
				parts.append("%s: %s" % [_gdsc_variant_to_source(k), _gdsc_variant_to_source(value[k])])
			return "{%s}" % ", ".join(parts)
		_:
			return str(value)

func _read_vanilla_source(script_path: String) -> String:
	# On-disk cache first (pristine vanilla from a prior session's detokenize).
	# IMPORTANT: do NOT call load(script_path) here, not even to "verify" the
	# live script. Any load() triggers ResourceFormatLoaderGDScript to read
	# the PCK's .gdc (via the PCK's stale .gd.remap) and cache the tokenized
	# result at script_path. Subsequent hook-pack mounts + loads hit that
	# cached entry instead of our rewrite. Cache must stay cold until the
	# hook pack is mounted.
	var cache_file := VANILLA_CACHE_DIR.path_join(script_path.trim_prefix("res://"))
	if FileAccess.file_exists(cache_file):
		var cached := FileAccess.get_file_as_string(cache_file)
		if not cached.is_empty():
			return cached

	# No cache: detokenize from raw .gdc bytes. This uses FileAccess only
	# (never ResourceLoader), so no cache entry is created.
	var source := _detokenize_script(script_path)
	if source.is_empty():
		return ""

	# Detect a rewrite accidentally served at the vanilla path (would mean
	# a prior session left a mount active that contaminated detokenize
	# input -- shouldn't happen in the current design, but catch it loudly
	# so we don't double-rewrite).
	if "_rtv_ready_done" in source or 'Engine.get_meta("RTVModLib"' in source:
		_log_critical("[Hooks] Detokenized source for %s already contains rewrite markers -- possible stale overlay. Delete %s and restart." \
				% [script_path, ProjectSettings.globalize_path(HOOK_PACK_DIR)])
		return ""
	_save_vanilla_source(script_path, source)
	return source

func _save_vanilla_source(script_path: String, source: String) -> void:
	if source.is_empty():
		return  # never write 0-byte cache files
	var cache_file := VANILLA_CACHE_DIR.path_join(script_path.trim_prefix("res://"))
	DirAccess.make_dir_recursive_absolute(
		ProjectSettings.globalize_path(cache_file.get_base_dir()))
	var f := FileAccess.open(cache_file, FileAccess.WRITE)
	if f:
		f.store_string(source)
		f.close()

func _probe_gdsc_version() -> int:
	var probe_paths := ["res://Scripts/Camera.gd", "res://Scripts/Controller.gd",
			"res://Scripts/Audio.gd", "res://Scripts/AI.gd"]
	for p in probe_paths:
		var raw := FileAccess.get_file_as_bytes(p)
		if raw.size() < 12:
			raw = FileAccess.get_file_as_bytes(p.replace(".gd", ".gdc"))
			if raw.size() < 12:
				continue
		if raw.slice(0, 4).get_string_from_ascii() != _GDSC_MAGIC:
			continue
		return int(raw.decode_u32(4))
	return -1

# Build the framework pack: enumerate res://Scripts/*.gd, detokenize each via
# _read_vanilla_source, parse + generate wrappers, zip them, mount the zip.
#
# The zip mounts at res://modloader_hooks/ and wrappers load from there. NOT
# from user:// -- Godot 4.6's extends-chain resolution for class_name parents
# breaks for scripts loaded from user://, which shows up as broken super()
