## Source from Godot's binary-tokenized .gdc (GDSC) scripts, TOKENIZER_VERSION 100
## (Godot 4.3-4.4) and 101 (4.5-4.6), plus the vanilla-source cache.

const _GDSC_MAGIC := "GDSC"
const _GDSC_TOKEN_BITS := 8
const _GDSC_TOKEN_MASK := 0x7F
const _GDSC_TOKEN_WIDE_FLAG := 0x80
# First v101 index that does not exist in v100. "..." was inserted here during
# 4.5 development; 0..82 are identical between the two versions.
const _GDSC_V100_SHIFT_FROM := 83

# v101 token ids; _TOKEN_TEXT has the printable ones. 0 EMPTY, 1 ANNOTATION, 2 IDENTIFIER,
# 3 LITERAL, 88-90 NEWLINE INDENT DEDENT, 95 VCS conflict marker, 98 ERROR, 99 EOF.
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

# Tokens that take a space before them when the line already has text.
const _SPACE_BEFORE := [
	4, 5, 6, 7, 8, 9,            # < <= > >= == !=
	10, 11, 12, 13, 14, 15,      # and or not && || !
	16, 17, 19, 20, 21,          # & | ^ << >>
	22, 23, 24, 25, 26, 27,      # + - * ** / %
	28, 29, 30, 31, 32, 33,      # = += -= *= **= /=
	34, 35, 36, 37, 38, 39,      # %= <<= >>= &= |= ^=
	40, 42, 51, 61, 62,          # if else as in is
	86,                          # ->
]

# Tokens that take a space after them, besides every keyword (40-72).
const _SPACE_AFTER := [
	1, 2, 3,                     # annotation, identifier, literal
	4, 5, 6, 7, 8, 9,            # < <= > >= == !=
	10, 11, 12, 13, 14, 15,      # and or not && || !
	16, 17, 19, 20, 21,          # & | ^ << >>
	22, 23, 24, 25, 26, 27,      # + - * ** / %
	28, 29, 30, 31, 32, 33,      # = += -= *= **= /=
	34, 35, 36, 37, 38, 39,      # %= <<= >>= &= |= ^=
	74, 76, 78,                  # ] } )
	79, 80, 84, 86, 87,          # , ; : -> _
	91, 92, 93, 94,              # PI TAU INF NAN
]

# After these an identifier, literal, annotation or keyword takes no space; -1 is line start.
const _NO_SPACE_AFTER := [77, 73, 81, 85, 18, 15, 89, 88, -1]  # ( [ . $ ~ ! INDENT NEWLINE

const _TK_EMPTY := 0
const _TK_ANNOTATION := 1
const _TK_IDENTIFIER := 2
const _TK_LITERAL := 3
const _TK_KW_FIRST := 40   # "if"
const _TK_KW_WHEN := 50    # "when", the last control-flow keyword
const _TK_AWAIT := 53
const _TK_KW_LAST := 72    # "yield"
const _TK_PAREN_OPEN := 77
const _TK_NEWLINE := 88
const _TK_INDENT := 89
const _TK_DEDENT := 90
const _TK_EOF := 99

# After mods mount, res://Scripts/X.gd can be a mod's file, so vanilla bytes come out of
# the game .pck by offset; the VFS (editor, harnesses) is a fallback that is never cached.
var _game_pck_index: Dictionary = {}  # "Scripts/X.gdc" -> {path, offset, size}
var _game_pck_path: String = ""
var _game_pck_indexed: bool = false
var _game_pck_path_override: String = ""  # tests; "" looks beside the executable
var _last_detokenize_from_pck: bool = false

func _locate_game_pck() -> String:
	if _game_pck_path_override != "":
		return _game_pck_path_override
	return _static_game_pck_path()

func _game_pck_stamp() -> String:
	return _static_game_pck_stamp(_locate_game_pck())

func _ensure_game_pck_index() -> void:
	if _game_pck_indexed:
		return
	_game_pck_indexed = true
	_game_pck_path = _locate_game_pck()
	if _game_pck_path == "":
		return
	# The table reader's own [PCK] reason is not logged here; the warning below says it once.
	for e: Dictionary in _pck_read_table(_game_pck_path)["entries"]:
		var rel: String = e["path"].trim_prefix("res://").trim_prefix("/")
		if rel != "":
			_game_pck_index[rel] = e
	if _game_pck_index.is_empty():
		_log_warning("[Detokenize] %s has no readable file table; vanilla scripts come from the VFS, uncached" \
				% _game_pck_path)

# A vanilla script's stored bytes, its .gdc first and then the .gd; empty when the PCK has neither.
func _vanilla_bytes_from_pck(script_path: String) -> PackedByteArray:
	_ensure_game_pck_index()
	if _game_pck_index.is_empty():
		return PackedByteArray()
	var rel := script_path.trim_prefix("res://")
	for cand in [rel.trim_suffix(".gd") + ".gdc", rel]:
		if not _game_pck_index.has(cand):
			continue
		var e: Dictionary = _game_pck_index[cand]
		var size: int = e["size"]
		if size <= 0:
			continue
		var f := FileAccess.open(_game_pck_path, FileAccess.READ)
		if f == null:
			return PackedByteArray()
		f.seek(e["offset"])
		var bytes := f.get_buffer(size)
		f.close()
		if bytes.size() == size:
			return bytes
	return PackedByteArray()

func _detokenize_script(script_path: String) -> String:
	_last_detokenize_from_pck = false
	if _pck_zero_byte_paths.has(script_path):
		return ""
	var raw := _read_script_bytes(script_path)
	if raw.is_empty():
		_log_warning("[Detokenize] Cannot read bytes from: %s (tried the game PCK, res://, globalized, .gdc)" % script_path)
		return ""

	if raw.size() < 12:
		return ""
	if raw.slice(0, 4).get_string_from_ascii() != _GDSC_MAGIC:
		# A build can ship a script as plain text; pass it through as is.
		var text := raw.get_string_from_utf8()
		if not text.is_empty() and (text.begins_with("extends") or text.begins_with("class_name") or text.begins_with("@")):
			return text
		_log_warning("[Detokenize] Not a GDSC file: " + script_path)
		return ""

	var version := raw.decode_u32(4)
	if version != GDSC_VERSION_V100 and version != GDSC_VERSION_V101:
		_log_critical("[Detokenize] Unsupported GDSC version %d in %s (expected %d or %d)" \
				% [version, script_path, GDSC_VERSION_V100, GDSC_VERSION_V101])
		return ""

	var decompressed_size := raw.decode_u32(8)
	var buf := raw.slice(12)
	if decompressed_size != 0:
		buf = buf.decompress(decompressed_size, FileAccess.COMPRESSION_ZSTD)
		if buf.is_empty():
			_log_critical("[Detokenize] ZSTD decompression failed for: " + script_path)
			return ""

	var sections := _decode_sections(buf, version, script_path)
	if sections.is_empty():
		return ""
	var tokens: Array = sections["tokens"]
	var result := _reconstruct_source(tokens, sections["identifiers"], sections["constants"],
			sections["line_map"], sections["col_map"])
	if result.is_empty():
		return ""
	_log_info("[Detokenize] Reconstructed: %s (%d tokens, %d lines)" \
			% [script_path, tokens.size(), result.count("\n") + 1])
	return result

# The game PCK first (setting _last_detokenize_from_pck), else the VFS: FileAccess on
# res:// can fail for PCK-embedded files, so the globalized path and the .gdc follow.
func _read_script_bytes(script_path: String) -> PackedByteArray:
	var raw := _vanilla_bytes_from_pck(script_path)
	if not raw.is_empty():
		_last_detokenize_from_pck = true
		return raw
	for path in [script_path, ProjectSettings.globalize_path(script_path)]:
		var f := FileAccess.open(path, FileAccess.READ)
		if f:
			raw = f.get_buffer(f.get_length())
			f.close()
			if not raw.is_empty():
				return raw
	return FileAccess.get_file_as_bytes(script_path.trim_suffix(".gd") + ".gdc")

# {identifiers, constants, line_map, col_map, tokens} of a decompressed body, or {}
# when the sections do not match the header counts.
func _decode_sections(buf: PackedByteArray, version: int, script_path: String) -> Dictionary:
	var meta_size := 20 if version == GDSC_VERSION_V100 else 16  # v100 has 4-byte padding
	if buf.size() < meta_size:
		return {}
	var ident_count: int = buf.decode_u32(0)
	var const_count: int = buf.decode_u32(4)
	var line_count: int = buf.decode_u32(8)
	var token_count: int = buf.decode_u32(16 if version == GDSC_VERSION_V100 else 12)
	var offset := meta_size

	# Identifiers: UTF-32, every byte XOR 0xb6.
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

	var constants: Array = []
	for _i in const_count:
		if offset + 4 > buf.size():
			break
		# bytes_to_var() does not report consumed size; round-trip through var_to_bytes().
		var val = bytes_to_var(buf.slice(offset))
		constants.append(val)
		offset += var_to_bytes(val).size()

	# line_count (token index, line) pairs, then as many (token index, column) pairs.
	var line_map := {}
	var col_map := {}
	for m: Dictionary in [line_map, col_map]:
		for _i in line_count:
			if offset + 8 > buf.size():
				break
			m[buf.decode_u32(offset)] = buf.decode_u32(offset + 4)
			offset += 8

	var tokens: Array = []  # [type, data_index]
	for _i in token_count:
		if offset >= buf.size():
			break
		var token_len := 8 if (buf[offset] & _GDSC_TOKEN_WIDE_FLAG) else 5
		if offset + token_len > buf.size():
			break
		var raw_type: int = buf.decode_u32(offset)
		var tk_type: int = raw_type & _GDSC_TOKEN_MASK
		# v100 has no "..." token, so indices 83+ sit one lower than the v101 table;
		# unnormalized, ":" reads as "..." and EOF is missed.
		if version == GDSC_VERSION_V100 and tk_type >= _GDSC_V100_SHIFT_FROM:
			tk_type += 1
		tokens.append([tk_type, raw_type >> _GDSC_TOKEN_BITS])
		offset += token_len

	# The loops above stop silently on overrun and a failed bytes_to_var desyncs the
	# offset; the header counts make bad input fail loudly.
	if identifiers.size() != ident_count or constants.size() != const_count or tokens.size() != token_count:
		_log_critical("[Detokenize] Section desync in %s: idents %d/%d consts %d/%d tokens %d/%d, refusing" \
				% [script_path, identifiers.size(), ident_count, constants.size(), const_count, tokens.size(), token_count])
		return {}
	return {"identifiers": identifiers, "constants": constants, "line_map": line_map,
			"col_map": col_map, "tokens": tokens}

func _reconstruct_source(tokens: Array, identifiers: Array[String], constants: Array,
		line_map: Dictionary, col_map: Dictionary) -> String:
	var lines := PackedStringArray()
	var current_line := ""
	var current_line_num := 1
	var need_space := false
	var prev_tk := -1
	var line_started := false

	for i in tokens.size():
		var tk: int = tokens[i][0]
		var idx: int = tokens[i][1]

		if line_map.has(i):
			var new_line: int = line_map[i]
			# Line values are raw u32s; a corrupt map would spin this loop for billions of lines.
			if new_line - current_line_num > 10000:
				_log_critical("[Detokenize] Absurd line jump %d -> %d -- corrupt line map, aborting reconstruction" \
						% [current_line_num, new_line])
				return ""
			while current_line_num < new_line:
				lines.append(current_line)
				current_line = ""
				current_line_num += 1
				need_space = false
				line_started = false

		if tk == _TK_EOF:
			break
		if tk == _TK_NEWLINE:
			lines.append(current_line)
			current_line = ""
			current_line_num += 1
			need_space = false
			line_started = false
			prev_tk = tk
			continue
		# Indentation comes from col_map, not from INDENT/DEDENT.
		if tk == _TK_INDENT or tk == _TK_DEDENT:
			prev_tk = tk
			continue
		if tk == _TK_EMPTY:
			continue

		var text := ""
		if tk == _TK_IDENTIFIER:
			text = identifiers[idx] if idx < identifiers.size() else "<ident?>"
		elif tk == _TK_ANNOTATION:
			var aname: String = identifiers[idx] if idx < identifiers.size() else "?"
			text = aname if aname.begins_with("@") else ("@" + aname)
		elif tk == _TK_LITERAL:
			text = _variant_to_source(constants[idx] if idx < constants.size() else null)
		elif _TOKEN_TEXT.has(tk):
			text = _TOKEN_TEXT[tk]
		else:
			text = "<tk%d>" % tk

		if not line_started:
			line_started = true
			if col_map.has(i):
				for _t in _indent_from_column(col_map[i]):
					current_line += "\t"

		var add_space_before := false
		if need_space and not current_line.is_empty() and not current_line.ends_with("\t"):
			if tk in _SPACE_BEFORE:
				add_space_before = true
			elif tk == _TK_IDENTIFIER or tk == _TK_LITERAL or tk == _TK_ANNOTATION \
					or (tk >= _TK_KW_FIRST and tk <= _TK_KW_LAST):
				# An identifier or annotation right after an annotation takes no space;
				# a keyword does (`@export var`).
				var after_anno := prev_tk == _TK_ANNOTATION and (tk == _TK_IDENTIFIER or tk == _TK_ANNOTATION)
				add_space_before = not after_anno and prev_tk not in _NO_SPACE_AFTER
			elif tk == _TK_PAREN_OPEN:
				# Control-flow keywords and await take a space before ( (the rewriter's
				# coroutine check reads the keyword as a word); func/preload/super do not.
				add_space_before = (prev_tk >= _TK_KW_FIRST and prev_tk <= _TK_KW_WHEN) or prev_tk == _TK_AWAIT

		if add_space_before and not current_line.ends_with(" ") and not current_line.ends_with("\t"):
			current_line += " "
		current_line += text
		need_space = tk in _SPACE_AFTER or (tk >= _TK_KW_FIRST and tk <= _TK_KW_LAST)
		prev_tk = tk

	if not current_line.is_empty():
		lines.append(current_line)
	var result := "\n".join(lines)
	if not result.ends_with("\n"):
		result += "\n"
	return result

# Godot counts a column per character and vanilla RTV is 4-space indented; tab or 2-space
# source collapses to depth 0 (canary C), and a relative indent stack breaks inside ( or [.
func _indent_from_column(col: int) -> int:
	@warning_ignore("integer_division")
	return col / 4

func _variant_to_source(value: Variant) -> String:
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
			# Vectors and arrays arrive as constructor tokens; str() of anything else is not GDScript.
			_log_critical("[Detokenize] Constant pool holds an unexpected Variant type %d; the rewrite will not compile" \
					% typeof(value))
			return "null"

# Stamp files at the cache root; a mismatch on either wipes it. "format" is the cache
# layout version, "build" the stamp of the PCK the text was read from.
const _VANILLA_CACHE_FORMAT := 2
const _VANILLA_CACHE_STAMP := "format"
const _VANILLA_CACHE_BUILD_STAMP := "build"
var _vanilla_cache_checked: bool = false

func _vanilla_cache_stamp_read(stamp_name: String) -> String:
	var stamp_file := VANILLA_CACHE_DIR.path_join(stamp_name)
	if not FileAccess.file_exists(stamp_file):
		return ""
	return FileAccess.get_file_as_string(stamp_file).strip_edges()

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
	for stamp: Array in [[_VANILLA_CACHE_STAMP, str(_VANILLA_CACHE_FORMAT)], [_VANILLA_CACHE_BUILD_STAMP, want_build]]:
		if stamp[1] == "":
			continue
		var f := FileAccess.open(VANILLA_CACHE_DIR.path_join(stamp[0]), FileAccess.WRITE)
		if f != null:
			f.store_string(stamp[1])
			f.close()

func _read_vanilla_source(script_path: String) -> String:
	# Never load(script_path) here: a load() caches the PCK's tokenized script at that
	# path, and later hook-pack loads would hit it instead of the rewrite.
	_ensure_vanilla_cache_current()
	var cache_file := VANILLA_CACHE_DIR.path_join(script_path.trim_prefix("res://"))
	if FileAccess.file_exists(cache_file):
		var cached := FileAccess.get_file_as_string(cache_file)
		if not cached.is_empty():
			return cached

	var source := _detokenize_script(script_path)
	if source.is_empty():
		return ""
	# A rewrite served at the vanilla path means a stale mount contaminated the input.
	if "_rtv_ready_done" in source or 'Engine.get_meta("RTVModLib"' in source:
		_log_critical("[Detokenize] Detokenized source for %s already contains rewrite markers; delete %s and restart" \
				% [script_path, ProjectSettings.globalize_path(HOOK_PACK_DIR)])
		return ""
	# A VFS read may have come from a mounted mod; caching it would keep that mod's
	# code running after uninstall.
	if _last_detokenize_from_pck:
		_save_vanilla_source(script_path, source)
	else:
		_log_debug("[Detokenize] %s read through the VFS (no game PCK) -- not cached" % script_path)
	return source

func _save_vanilla_source(script_path: String, source: String) -> void:
	if source.is_empty():
		return
	var cache_file := VANILLA_CACHE_DIR.path_join(script_path.trim_prefix("res://"))
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(cache_file.get_base_dir()))
	# Write a .tmp sibling and rename it into place; a truncated file would be trusted forever.
	var tmp_file := cache_file + ".tmp"
	var f := FileAccess.open(tmp_file, FileAccess.WRITE)
	if f == null:
		return
	var ok := f.store_string(source)
	var err := f.get_error()
	f.close()
	if not ok or err != OK:
		_log_warning("[Detokenize] Vanilla cache write failed for %s (err %d) -- removing partial file" % [cache_file, err])
		DirAccess.remove_absolute(ProjectSettings.globalize_path(tmp_file))
		return
	var rename_err := DirAccess.rename_absolute(
		ProjectSettings.globalize_path(tmp_file),
		ProjectSettings.globalize_path(cache_file))
	if rename_err != OK:
		_log_warning("[Detokenize] Vanilla cache rename failed for %s (err %d) -- skipped this session" % [cache_file, rename_err])
		DirAccess.remove_absolute(ProjectSettings.globalize_path(tmp_file))

# The scripts canaries B and C probe. If a game update renames all four, canary B
# reads -1 and hook-pack generation runs unprotected.
const _GDSC_PROBE_SCRIPTS: Array[String] = ["res://Scripts/Camera.gd", "res://Scripts/Controller.gd",
		"res://Scripts/Audio.gd", "res://Scripts/AI.gd"]

# A probe script's bytecode through the VFS (the .gd, then the .gdc), or empty without a GDSC header.
func _gdsc_probe_bytes(path: String) -> PackedByteArray:
	var raw := FileAccess.get_file_as_bytes(path)
	if raw.size() < 12:
		raw = FileAccess.get_file_as_bytes(path.trim_suffix(".gd") + ".gdc")
	if raw.size() < 12 or raw.slice(0, 4).get_string_from_ascii() != _GDSC_MAGIC:
		return PackedByteArray()
	return raw

# Canary B: the bytecode version of the first readable probe, or -1.
func _probe_gdsc_version() -> int:
	for p in _GDSC_PROBE_SCRIPTS:
		var raw := _gdsc_probe_bytes(p)
		if not raw.is_empty():
			return int(raw.decode_u32(4))
	return -1
