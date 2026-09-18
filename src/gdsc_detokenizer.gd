## ----- gdsc_detokenizer.gd -----
## Reconstructs source from Godot's binary-tokenized .gdc (GDSC) scripts;
## load().source_code is empty for the tokenized export path. Covers
## TOKENIZER_VERSION 100 (Godot 4.3-4.4) and 101 (Godot 4.5-4.6). Also owns
## the vanilla-source cache helpers.

const _GDSC_MAGIC := "GDSC"
const _GDSC_TOKEN_BITS := 8
const _GDSC_TOKEN_MASK := (1 << (_GDSC_TOKEN_BITS - 1)) - 1  # 0x7F
const _GDSC_TOKEN_BYTE_MASK := 0x80
# First v101 index that does not exist in v100. "..." was inserted here during
# 4.5 development; 0..82 are identical between the two versions.
const _GDSC_V100_SHIFT_FROM := 83

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
# Raw int keys: Godot forbids enum refs in const dictionary initializers.
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

# Tokens that want a space before them (binary operators, keywords after exprs).
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

# Tokens that want a space after them.
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

# Named indices for _gdsc_reconstruct; values match the table above.
const TK_EMPTY := 0
const TK_ANNOTATION := 1
const TK_IDENTIFIER := 2
const TK_LITERAL := 3
const TK_NOT := 12
const TK_BANG := 15
const TK_TILDE := 18
const TK_KW_FIRST := 40   # "if" -- first keyword
const TK_KW_WHEN := 50    # "when" -- last control-flow keyword (if..when)
const TK_KW_LAST := 72    # "yield" -- last keyword
const TK_BRACKET_OPEN := 73
const TK_BRACKET_CLOSE := 74
const TK_BRACE_CLOSE := 76
const TK_PAREN_OPEN := 77
const TK_PAREN_CLOSE := 78
const TK_DOT := 81
const TK_DOLLAR := 85
const TK_UNDERSCORE := 87
const TK_NEWLINE := 88
const TK_INDENT := 89
const TK_DEDENT := 90
const TK_PI := 91
const TK_TAU := 92
const TK_INF := 93
const TK_NAN := 94
const TK_EOF := 99

# ----- vanilla bytes straight from the game's PCK ---------------------------
# Hook-pack generation runs after mod archives are mounted, so a VFS read at
# res://Scripts/X.gd can return a mod's file. The detokenizer reads the bytes
# out of the game's own .pck by offset, and only that source is ever cached.
# The VFS is a fallback for builds with no PCK (editor, harnesses), never cached.

# "Scripts/X.gdc" -> {path, offset, size}, built once per session.
var _game_pck_index: Dictionary = {}
var _game_pck_path: String = ""
var _game_pck_indexed: bool = false
# Tests point this at a synthetic pack; "" means look beside the executable.
var _game_pck_path_override: String = ""
# Set by _detokenize_script: whether the bytes it decoded came from the PCK.
var _last_detokenize_from_pck: bool = false

func _locate_game_pck() -> String:
	if _game_pck_path_override != "":
		return _game_pck_path_override
	return _static_game_pck_path()

## Stamp of the game PCK this session reads (see _static_game_pck_stamp).
func _game_pck_stamp() -> String:
	return _static_game_pck_stamp(_locate_game_pck())

func _ensure_game_pck_index() -> void:
	if _game_pck_indexed:
		return
	_game_pck_indexed = true
	_game_pck_path = _locate_game_pck()
	if _game_pck_path == "":
		return
	for e_v in _security_pck_list_with_offsets(_game_pck_path):
		var e: Dictionary = e_v
		# Same decode as _parse_pck_file_list: utf8 decode stops at the NUL padding.
		var rel := str(e["path"]).trim_prefix("res://").trim_prefix("/")
		if rel != "":
			_game_pck_index[rel] = e
	if _game_pck_index.is_empty():
		_log_warning("[Detokenize] %s has no readable file table (encrypted or unknown format) -- vanilla scripts will be read through the VFS and not cached" % _game_pck_path)

## The stored bytes for a vanilla script: its compiled .gdc first, then the
## plain .gd. Empty when the PCK is unavailable or has no such entry.
func _vanilla_bytes_from_pck(script_path: String) -> PackedByteArray:
	_ensure_game_pck_index()
	if _game_pck_index.is_empty():
		return PackedByteArray()
	var rel := script_path.trim_prefix("res://")
	var candidates := [rel.trim_suffix(".gd") + ".gdc", rel]
	for cand in candidates:
		if not _game_pck_index.has(cand):
			continue
		var e: Dictionary = _game_pck_index[cand]
		var size := int(e["size"])
		if size <= 0:
			continue
		var f := FileAccess.open(_game_pck_path, FileAccess.READ)
		if f == null:
			return PackedByteArray()
		f.seek(int(e["offset"]))
		var bytes := f.get_buffer(size)
		f.close()
		if bytes.size() == size:
			return bytes
	return PackedByteArray()

func _detokenize_script(script_path: String) -> String:
	_last_detokenize_from_pck = false
	# Zero-byte PCK entries have nothing to decode; not an IO failure.
	if _pck_zero_byte_paths.has(script_path):
		return ""
	var raw := _gdsc_read_script_bytes(script_path)
	if raw.is_empty():
		_log_warning("[Detokenize] Cannot read bytes from: %s (tried the game PCK, res://, globalized, .gdc)" % script_path)
		return ""

	# -- Header (12 bytes) --
	if raw.size() < 12:
		return ""
	var magic := raw.slice(0, 4).get_string_from_ascii()
	if magic != _GDSC_MAGIC:
		# Might be plain text that load() failed on for another reason.
		var text := raw.get_string_from_utf8()
		if not text.is_empty() and (text.begins_with("extends") or text.begins_with("class_name") or text.begins_with("@")):
			return text
		_log_warning("[Detokenize] Not a GDSC file: " + script_path)
		return ""

	var version := raw.decode_u32(4)
	if version != GDSC_VERSION_V100 and version != GDSC_VERSION_V101:
		_log_critical("[Detokenize] Unsupported GDSC version %d in %s (expected %d or %d)" % [version, script_path, GDSC_VERSION_V100, GDSC_VERSION_V101])
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

	var sections := _gdsc_decode_sections(buf, version, script_path)
	if sections.is_empty():
		return ""
	var tokens: Array = sections["tokens"]
	var result := _gdsc_reconstruct(tokens, sections["identifiers"], sections["constants"],
			sections["line_map"], sections["col_map"])
	if result.is_empty():
		return ""
	_log_info("[Detokenize] Reconstructed: %s (%d tokens, %d lines) -- parse OK" \
			% [script_path, tokens.size(), result.count("\n") + 1])
	return result


# The raw bytes of a vanilla script: the game PCK first (and then
# _last_detokenize_from_pck is set), else the VFS. Empty when nothing readable.
func _gdsc_read_script_bytes(script_path: String) -> PackedByteArray:
	var raw := _vanilla_bytes_from_pck(script_path)
	if not raw.is_empty():
		_last_detokenize_from_pck = true
		return raw
	# No PCK: fall back to the VFS. FileAccess on res:// can fail for
	# PCK-embedded files; try res://, then globalized, then .gdc.
	var f := FileAccess.open(script_path, FileAccess.READ)
	if f:
		raw = f.get_buffer(f.get_length())
		f.close()
	if raw.is_empty():
		var glob_path := ProjectSettings.globalize_path(script_path)
		f = FileAccess.open(glob_path, FileAccess.READ)
		if f:
			raw = f.get_buffer(f.get_length())
			f.close()
	if raw.is_empty():
		var gdc_path := script_path.replace(".gd", ".gdc")
		raw = FileAccess.get_file_as_bytes(gdc_path)
	return raw


# Decode the identifier, constant, line/column and token sections of a
# decompressed GDSC body. Returns {identifiers, constants, line_map, col_map,
# tokens}, or {} when the sections do not match the header counts.
func _gdsc_decode_sections(buf: PackedByteArray, version: int, script_path: String) -> Dictionary:
	# -- Metadata --
	var meta_size := 20 if version == GDSC_VERSION_V100 else 16  # v100 has 4-byte padding
	if buf.size() < meta_size:
		return {}
	var ident_count: int = buf.decode_u32(0)
	var const_count: int = buf.decode_u32(4)
	var line_count: int  = buf.decode_u32(8)
	var token_count: int
	if version == GDSC_VERSION_V100:
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
		# bytes_to_var() does not report consumed size; round-trip through var_to_bytes().
		var remaining := buf.slice(offset)
		var val = bytes_to_var(remaining)
		constants.append(val)
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
		# v100 has no "..." token, so indices 83+ sit one lower than the v101 table;
		# unnormalized, ":" reads as "..." and EOF is missed.
		if version == GDSC_VERSION_V100 and tk_type >= _GDSC_V100_SHIFT_FROM:
			tk_type += 1
		var data_idx: int = raw_type >> _GDSC_TOKEN_BITS
		tokens.append([tk_type, data_idx])
		offset += token_len

	# The section loops break silently on overrun and a failed bytes_to_var
	# desyncs the offset; cross-check the header counts so bad input fails loudly.
	if identifiers.size() != ident_count or constants.size() != const_count or tokens.size() != token_count:
		_log_critical("[Detokenize] Section truncation/desync in %s: idents %d/%d consts %d/%d tokens %d/%d -- refusing partial reconstruction" \
				% [script_path, identifiers.size(), ident_count, constants.size(), const_count, tokens.size(), token_count])
		return {}
	return {"identifiers": identifiers, "constants": constants, "line_map": line_map,
			"col_map": col_map, "tokens": tokens}

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

		if line_map.has(i):
			var new_line: int = line_map[i]
			# Line values are raw u32s; a corrupt buffer could spin this loop for billions of iterations.
			if new_line - current_line_num > 10000:
				_log_critical("[Detokenize] Absurd line jump %d -> %d -- corrupt line map, aborting reconstruction" % [current_line_num, new_line])
				return ""
			while current_line_num < new_line:
				lines.append(current_line)
				current_line = ""
				current_line_num += 1
				need_space = false
				line_started = false

		if tk == TK_EOF:
			break

		if tk == TK_NEWLINE:
			lines.append(current_line)
			current_line = ""
			current_line_num += 1
			need_space = false
			line_started = false
			prev_tk = tk
			continue

		if tk == TK_INDENT or tk == TK_DEDENT:  # skip, we use col_map instead
			prev_tk = tk
			continue

		# TK_EMPTY would fall through to the "<tk0>" placeholder.
		if tk == TK_EMPTY:
			continue

		var text := ""
		if tk == TK_IDENTIFIER:
			text = identifiers[idx] if idx < identifiers.size() else "<ident?>"
		elif tk == TK_ANNOTATION:
			var aname: String = identifiers[idx] if idx < identifiers.size() else "?"
			text = aname if aname.begins_with("@") else ("@" + aname)
		elif tk == TK_LITERAL:
			text = _gdsc_variant_to_source(constants[idx] if idx < constants.size() else null)
		elif _TOKEN_TEXT.has(tk):
			text = _TOKEN_TEXT[tk]
		else:
			text = "<tk%d>" % tk

		# Indentation comes from column data on the first visible token.
		if not line_started:
			line_started = true
			if col_map.has(i):
				var col: int = col_map[i]
				var tabs: int = _indent_from_column(col)
				for _t in tabs:
					current_line += "\t"

		var add_space_before := false
		if need_space and not current_line.is_empty() and not current_line.ends_with("\t"):
			if _SPACE_BEFORE.has(tk):
				add_space_before = true
			elif tk == TK_IDENTIFIER or tk == TK_LITERAL or tk == TK_ANNOTATION or (tk >= TK_KW_FIRST and tk <= TK_KW_LAST):
				# IDENTIFIER, LITERAL, ANNOTATION, or any keyword: space before unless prev
				# was an opener, dot, $, ~, !, indent, newline. The annotation exclusion
				# applies only to identifiers, not to keywords like var/func after @export.
				var skip_anno := (prev_tk == TK_ANNOTATION and (tk == TK_IDENTIFIER or tk == TK_ANNOTATION))  # ident/anno after anno
				if not skip_anno \
						and prev_tk != TK_PAREN_OPEN and prev_tk != TK_BRACKET_OPEN \
						and prev_tk != TK_DOT and prev_tk != TK_DOLLAR \
						and prev_tk != TK_TILDE \
						and prev_tk != TK_BANG and prev_tk != TK_INDENT \
						and prev_tk != TK_NEWLINE and prev_tk != -1:
					add_space_before = true
			elif tk == TK_PAREN_OPEN:
				# Space before ( after control-flow keywords, not after func/preload/super/assert/await.
				if prev_tk >= TK_KW_FIRST and prev_tk <= TK_KW_WHEN:  # if..when (control flow)
					add_space_before = true
			elif tk == TK_NOT or tk == TK_BANG:
				add_space_before = true

		if add_space_before and not current_line.ends_with(" ") and not current_line.ends_with("\t"):
			current_line += " "

		current_line += text

		# Identifiers, literals, closers, PI/TAU/INF/NAN and _ also want a space after.
		need_space = _SPACE_AFTER.has(tk) or tk == TK_IDENTIFIER or tk == TK_LITERAL \
				or tk == TK_PAREN_CLOSE or tk == TK_BRACKET_CLOSE or tk == TK_BRACE_CLOSE \
				or tk == TK_PI or tk == TK_TAU or tk == TK_INF \
				or tk == TK_NAN or tk == TK_UNDERSCORE

		prev_tk = tk

	if not current_line.is_empty():
		lines.append(current_line)

	var result := "\n".join(lines)
	if not result.ends_with("\n"):
		result += "\n"
	return result

# Column -> leading tab count. Godot counts one column per character, and
# RTV's vanilla source is 4-space indented, so col / 4 recovers the depth.
# Tab or 2-space source would collapse to depth 0; canary C catches that. A
# relative indent stack would corrupt depth on statements wrapped inside ( or [.
func _indent_from_column(col: int) -> int:
	@warning_ignore("integer_division")
	return col / 4

func _gdsc_variant_to_source(value: Variant) -> String:
	if value == null:
		return "null"
	match typeof(value):
		TYPE_BOOL:
			return "true" if value else "false"
		TYPE_INT:
			return str(value)
		TYPE_FLOAT:
			# str() renders bare "inf"/"nan", which are not valid GDScript.
			if is_inf(value):
				return "INF" if value > 0.0 else "-INF"
			if is_nan(value):
				return "NAN"
			var s := str(value)
			if "." not in s and "e" not in s:
				s += ".0"
			return s
		TYPE_STRING:
			return '"%s"' % str(value).c_escape()
		TYPE_STRING_NAME:
			return '&"%s"' % str(value).c_escape()
		TYPE_NODE_PATH:
			return '^"%s"' % str(value).c_escape()
		_:
			# The constant pool only holds literals; vectors and arrays arrive as
			# constructor tokens. str() on an unexpected type is not valid GDScript.
			_log_critical("[Detokenize] Constant pool holds an unexpected Variant type %d -- cannot render it as source. The rewritten script would not compile." % typeof(value))
			return "null"

# Two stamp files at the cache root; a mismatch on either wipes the
# directory. "format" names the cache layout: format 2 is the first that holds
# only PCK-sourced text, so every earlier cache is dropped as possibly
# poisoned by a mod's file read through the VFS. "build" names the PCK the
# text was read from, so a game update that replaces the PCK drops the cache.
const _VANILLA_CACHE_FORMAT := 2
const _VANILLA_CACHE_STAMP := "format"
const _VANILLA_CACHE_BUILD_STAMP := "build"
var _vanilla_cache_checked: bool = false

func _vanilla_cache_stamp_read(stamp_name: String) -> String:
	var stamp_file := VANILLA_CACHE_DIR.path_join(stamp_name)
	if not FileAccess.file_exists(stamp_file):
		return ""
	return FileAccess.get_file_as_string(stamp_file).strip_edges()

func _vanilla_cache_stamp_write(stamp_name: String, value: String) -> void:
	if value == "":
		return
	var f := FileAccess.open(VANILLA_CACHE_DIR.path_join(stamp_name), FileAccess.WRITE)
	if f != null:
		f.store_string(value)
		f.close()

func _ensure_vanilla_cache_current() -> void:
	if _vanilla_cache_checked:
		return
	_vanilla_cache_checked = true
	var dir := ProjectSettings.globalize_path(VANILLA_CACHE_DIR)
	var have_format := _vanilla_cache_stamp_read(_VANILLA_CACHE_STAMP)
	var want_build := _game_pck_stamp()
	var format_current := have_format == str(_VANILLA_CACHE_FORMAT)
	if format_current and _vanilla_cache_stamp_read(_VANILLA_CACHE_BUILD_STAMP) == want_build:
		return
	if DirAccess.dir_exists_absolute(dir):
		if format_current:
			_log_info("[Detokenize] the game PCK changed since the vanilla cache was written -- rebuilding it")
		else:
			_log_info("[Detokenize] vanilla cache is format '%s', want %d -- rebuilding it" % [have_format, _VANILLA_CACHE_FORMAT])
		_remove_tree(dir, true)
	DirAccess.make_dir_recursive_absolute(dir)
	_vanilla_cache_stamp_write(_VANILLA_CACHE_STAMP, str(_VANILLA_CACHE_FORMAT))
	_vanilla_cache_stamp_write(_VANILLA_CACHE_BUILD_STAMP, want_build)

func _read_vanilla_source(script_path: String) -> String:
	# On-disk cache first. Never call load(script_path) here: any load() caches
	# the PCK's tokenized result at that path, and later hook-pack loads hit it
	# instead of the rewrite. The cache must stay cold until the pack is mounted.
	_ensure_vanilla_cache_current()
	var cache_file := VANILLA_CACHE_DIR.path_join(script_path.trim_prefix("res://"))
	if FileAccess.file_exists(cache_file):
		var cached := FileAccess.get_file_as_string(cache_file)
		if not cached.is_empty():
			return cached

	# Detokenize uses FileAccess only, so no cache entry is created.
	var source := _detokenize_script(script_path)
	if source.is_empty():
		return ""

	# A rewrite served at the vanilla path means a stale mount contaminated the input.
	if "_rtv_ready_done" in source or 'Engine.get_meta("RTVModLib"' in source:
		_log_critical("[Hooks] Detokenized source for %s already contains rewrite markers -- possible stale overlay. Delete %s and restart." \
				% [script_path, ProjectSettings.globalize_path(HOOK_PACK_DIR)])
		return ""
	# Only text read from the game's PCK is cached. A VFS read may have come
	# from a mounted mod, and caching it would keep that mod's code running after uninstall.
	if _last_detokenize_from_pck:
		_save_vanilla_source(script_path, source)
	else:
		_log_debug("[Detokenize] %s read through the VFS (no game PCK) -- not cached" % script_path)
	return source

func _save_vanilla_source(script_path: String, source: String) -> void:
	if source.is_empty():
		return  # never write 0-byte cache files
	var cache_file := VANILLA_CACHE_DIR.path_join(script_path.trim_prefix("res://"))
	DirAccess.make_dir_recursive_absolute(
		ProjectSettings.globalize_path(cache_file.get_base_dir()))
	# Write to a .tmp sibling and rename into place; a truncated file would be trusted forever.
	var tmp_file := cache_file + ".tmp"
	var f := FileAccess.open(tmp_file, FileAccess.WRITE)
	if f == null:
		return
	# store_string returns bool; remove the partial file on any write error.
	var ok := f.store_string(source)
	var err := f.get_error()
	f.close()
	if not ok or err != OK:
		_log_warning("[Detokenize] Vanilla cache write failed for %s (err %d) -- removing partial file" % [cache_file, err])
		DirAccess.remove_absolute(ProjectSettings.globalize_path(tmp_file))
		return
	# rename_absolute replaces an existing target, so a stale file cannot block the swap.
	var rename_err := DirAccess.rename_absolute(
		ProjectSettings.globalize_path(tmp_file),
		ProjectSettings.globalize_path(cache_file))
	if rename_err != OK:
		_log_warning("[Detokenize] Vanilla cache rename failed for %s (err %d) -- cache skipped this session" % [cache_file, rename_err])
		DirAccess.remove_absolute(ProjectSettings.globalize_path(tmp_file))

# Assumes vanilla RTV ships Camera/Controller/Audio/AI under res://Scripts/.
# If a game update renames all four this returns -1, and _generate_hook_pack
# then proceeds without canary B protection.
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
