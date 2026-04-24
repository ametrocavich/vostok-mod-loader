## ----- security_scan.gd -----
## Lightweight guardrail. Reads each file inside a candidate mod
## (zip/vmz, pck, or developer-mode folder) WITHOUT mounting it and looks
## for combinations of GDScript patterns that are nearly diagnostic of
## known malware: obfuscated string decoding paired with process
## spawning, anti-debug crashes, ransomware-setup calls.
##
## This is NOT a virus scanner. It catches the lazy / copy/paste attacks
## (see the Road to Vostok dropper that motivated this branch); a
## determined attacker with the modloader source can evade specific
## patterns. Loading is never blocked. Only mods that hit a red trigger
## get a "suspicious code" tag in the launcher and a confirmation
## dialog at Launch time.

# Source files we run regex content scans on (GDScript text + text-form
# Godot resources that can embed inline GDScript).
const _TEXT_SCAN_EXTS: Dictionary = {
	"gd": true, "tscn": true, "tres": true, "gdshader": true,
}

# Binary resources that may embed compiled GDScript or string payloads.
# Byte-scanned for ASCII substrings of binary-safe rule patterns.
const _BINARY_SCAN_EXTS: Dictionary = {
	"scn": true, "res": true,
}

# Cap findings per mod so a deliberately-noisy archive can't bury the UI.
const _MAX_FINDINGS_PER_MOD: int = 50

# Cap individual file sizes we will fully scan. Almost no legitimate mod
# script is over a couple hundred KB, and huge binary resources aren't
# useful signal for this heuristic scanner.
const _MAX_TEXT_SCAN_BYTES: int = 8 * 1024 * 1024
const _MAX_BINARY_SCAN_BYTES: int = 16 * 1024 * 1024
const _MAX_MATCHES_PER_RULE_PER_FILE: int = 3

# Guardrails for malformed PCK / GDSC metadata.
const _MAX_PCK_ENTRY_COUNT: int = 100000
const _MAX_PCK_PATH_BYTES: int = 4096
const _MAX_GDSC_DECOMPRESSED_BYTES: int = 32 * 1024 * 1024
const _MAX_GDSC_TABLE_ENTRIES: int = 1000000

# Rules. Each rule's individual presence is not a warning by itself --
# the user only sees a badge when compute_risk_level() returns RISK_RED,
# which fires for solo red triggers (os_crash, disable_save_safety) or
# for combinations (obfuscation + process spawn, runtime-code-build +
# process spawn, the encoded-payload pair byte_decode_loop + large_int_array).
const _SECURITY_RULES: Array = [
	# --- Process spawning (combo with obfuscation/runtime_code -> red) ----
	{
		"id": "os_execute",
		"pattern": "\\bOS\\.execute\\s*\\(",
		"description": "Runs a system command via OS.execute.",
		"binary": true,
	},
	{
		"id": "os_create_process",
		"pattern": "\\bOS\\.create_process\\s*\\(",
		"description": "Spawns a process via OS.create_process.",
		"binary": true,
	},
	{
		"id": "os_create_instance",
		"pattern": "\\bOS\\.create_instance\\s*\\(",
		"description": "Spawns another copy of the game via OS.create_instance, with custom CLI args.",
		"binary": true,
	},
	{
		"id": "os_shell_open",
		# Skip http/https URL literals -- those go through the browser
		# (e.g. mods linking to their modworkshop page).
		"pattern": "\\bOS\\.shell_open\\s*\\((?!\\s*\"https?://)",
		"description": "Calls OS.shell_open on a path or URI (not an http(s) URL). The OS handler decides what to launch.",
		"binary": false,
	},
	{
		"id": "os_kill",
		"pattern": "\\bOS\\.kill\\s*\\(",
		"description": "Terminates a process by PID via OS.kill.",
		"binary": true,
	},
	# --- Solo red triggers (almost zero legit use) ------------------------
	{
		"id": "os_crash",
		"pattern": "\\bOS\\.crash\\s*\\(",
		"description": "Forces an engine crash via OS.crash. Used by malware as anti-debug or to defeat scanners.",
		"binary": true,
	},
	{
		"id": "disable_save_safety",
		"pattern": "\\bOS\\.set_use_file_access_save_and_swap\\s*\\(\\s*false\\b",
		"description": "Disables Godot's atomic-write save protection. No legitimate use in a mod.",
		"binary": true,
	},
	# --- Runtime code build (combo with process spawn -> red) -------------
	{
		"id": "expression_eval",
		"pattern": "\\bExpression\\.new\\s*\\(",
		"description": "Parses and runs GDScript-flavored code from a string at runtime via Expression.new().",
		"binary": true,
	},
	{
		"id": "script_from_string",
		"pattern": "\\.set_source_code\\s*\\(",
		"description": "Builds a GDScript from a runtime string via .set_source_code(). The source isn't part of the shipped files.",
		"binary": true,
	},
	{
		"id": "deserialize_objects",
		"pattern": "\\b(?:bytes_to_var_with_objects|var_to_bytes_with_objects|str_to_var)\\s*\\(",
		"description": "Uses bytes_to_var_with_objects / str_to_var. These rebuild Object instances from bytes (including any attached scripts).",
		"binary": true,
	},
	{
		"id": "marshalls_objects_decode",
		"pattern": "\\bMarshalls\\.base64_to_variant\\s*\\([^)]*\\btrue\\b",
		"description": "Uses Marshalls.base64_to_variant with allow_objects=true. Reconstructs Object instances from a base64 string.",
		"binary": true,
	},
	# --- Obfuscation signatures (combo with each other or spawn -> red) ---
	{
		"id": "base64_decode",
		"pattern": "\\bMarshalls\\.(?:base64_to_raw|base64_to_utf8|base64_to_variant)\\s*\\(",
		"description": "Decodes base64 at runtime. Often used as an obfuscation layer when paired with process spawning or runtime code generation.",
		"binary": true,
	},
	{
		"id": "byte_decode_loop",
		# `for <ident> in <expr>:` ... `<acc> += char(<ident>)` -- the
		# string-decoding loop attackers use to hide the real argument
		# passed to OS.execute or FileAccess.
		"pattern": "for\\s+\\w+\\s+in[^:]{1,200}:[\\s\\S]{0,200}?\\+=\\s*(?:char|String\\.chr)\\s*\\(",
		"description": "Contains a byte-array decode loop (`for c in bytes: acc += char(c)`). This pattern is often used to obfuscate string literals.",
		"binary": false,
	},
	{
		"id": "large_int_array",
		# 16+ comma-separated numeric literals in a single literal -- the
		# encoded-payload shape that almost always pairs with byte_decode_loop.
		"pattern": "\\[\\s*\\d+(?:\\s*,\\s*\\d+){15,}",
		"description": "Contains a large integer literal (16+ entries). Often appears alongside obfuscated string-decoding loops.",
		"binary": false,
	},
]

# Risk level for a mod's combined findings: clean or red. There is no
# middle tier -- the UI shows nothing for clean findings (even if
# individual rules matched) and a red "suspicious code" tag with a
# launch-time confirmation dialog when red triggers fire.
const RISK_CLEAN := 0
const RISK_RED := 2

# Rules that, alone, push the mod to red. Almost zero legit use cases.
const _RED_SOLO_RULES: Dictionary = {
	"os_crash": true,
	"disable_save_safety": true,
}

# Rule families used in red combination logic.
const _PROCESS_SPAWN_RULES: Array = [
	"os_execute", "os_create_process", "os_create_instance",
	"os_shell_open", "os_kill",
]
const _OBFUSCATION_RULES: Array = [
	"base64_decode", "byte_decode_loop", "large_int_array",
]
const _RUNTIME_CODE_RULES: Array = [
	"script_from_string", "marshalls_objects_decode",
	"deserialize_objects", "expression_eval",
]

# Minimal GDSC token maps copied locally so the scanner can detokenize
# compiled mod scripts before the later codegen modules are loaded.
const _SECURITY_GDSC_MAGIC := "GDSC"
const _SECURITY_GDSC_TOKEN_BITS := 8
const _SECURITY_GDSC_TOKEN_MASK := (1 << (_SECURITY_GDSC_TOKEN_BITS - 1)) - 1
const _SECURITY_GDSC_TOKEN_BYTE_MASK := 0x80
const _SECURITY_GDSC_TOKEN_TEXT := {
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
const _SECURITY_GDSC_SPACE_BEFORE := {
	4: 1, 5: 1, 6: 1, 7: 1, 8: 1, 9: 1,
	10: 1, 11: 1, 12: 1, 13: 1, 14: 1,
	16: 1, 17: 1, 19: 1, 20: 1, 21: 1,
	22: 1, 23: 1, 24: 1, 25: 1, 26: 1, 27: 1,
	28: 1, 29: 1, 30: 1, 31: 1, 32: 1, 33: 1,
	34: 1, 35: 1, 36: 1, 37: 1, 38: 1, 39: 1,
	40: 1, 42: 1, 51: 1, 61: 1, 62: 1,
	86: 1,
}
const _SECURITY_GDSC_SPACE_AFTER := {
	79: 1, 80: 1, 86: 1,
	4: 1, 5: 1, 6: 1, 7: 1, 8: 1, 9: 1,
	10: 1, 11: 1, 12: 1, 13: 1, 14: 1, 15: 1,
	16: 1, 17: 1, 19: 1, 20: 1, 21: 1,
	22: 1, 23: 1, 24: 1, 25: 1, 26: 1, 27: 1,
	28: 1, 29: 1, 30: 1, 31: 1, 32: 1, 33: 1,
	34: 1, 35: 1, 36: 1, 37: 1, 38: 1, 39: 1,
	84: 1,
	1: 1,
	40: 1, 41: 1, 42: 1, 43: 1, 44: 1,
	45: 1, 46: 1, 47: 1, 48: 1, 49: 1, 50: 1,
	51: 1, 52: 1, 53: 1, 54: 1, 55: 1,
	56: 1, 57: 1, 58: 1, 59: 1, 60: 1,
	61: 1, 62: 1, 63: 1, 64: 1, 65: 1,
	66: 1, 67: 1, 68: 1, 69: 1, 70: 1,
	71: 1, 72: 1,
}

# Returns RISK_CLEAN or RISK_RED.
#
# Red fires on:
#   - any RED_SOLO rule present
#   - the encoded-payload pair byte_decode_loop + large_int_array
#   - obfuscation + process spawn (decoded execute)
#   - runtime-code-build + process spawn (constructed execute)
# Otherwise: clean. Findings are still stored on the entry for logging
# but the user sees nothing.
func compute_risk_level(findings: Array) -> int:
	if findings.is_empty():
		return RISK_CLEAN
	var present: Dictionary = {}
	for f: Dictionary in findings:
		present[str(f.get("rule", ""))] = true
	for solo in _RED_SOLO_RULES:
		if present.has(solo):
			return RISK_RED
	if present.has("byte_decode_loop") and present.has("large_int_array"):
		return RISK_RED
	var has_obf := _any_present(present, _OBFUSCATION_RULES)
	var has_spawn := _any_present(present, _PROCESS_SPAWN_RULES)
	var has_runtime := _any_present(present, _RUNTIME_CODE_RULES)
	if has_obf and has_spawn:
		return RISK_RED
	if has_runtime and has_spawn:
		return RISK_RED
	return RISK_CLEAN

func _any_present(present: Dictionary, rules: Array) -> bool:
	for r in rules:
		if present.has(r):
			return true
	return false

# Compiled regex cache, indexed by rule id. Lazy-populated on first scan.
var _security_compiled: Dictionary = {}

func _security_compile_rules() -> void:
	if not _security_compiled.is_empty():
		return
	for rule: Dictionary in _SECURITY_RULES:
		var re := RegEx.new()
		if re.compile(str(rule["pattern"])) == OK:
			_security_compiled[rule["id"]] = re
		else:
			_log_warning("[SecurityScan] Failed to compile rule pattern: " + str(rule["id"]))

# Top-level entry. Returns Array[Dictionary] of findings for the mod.
# Empty array = clean. Each finding dict shape:
#   {rule, file, line, preview, description}
func scan_mod(full_path: String, ext: String) -> Array:
	_security_compile_rules()
	var findings: Array = []
	var seen: Dictionary = {}
	match ext:
		"vmz", "zip":
			_security_scan_zip(full_path, findings, seen)
		"pck":
			_security_scan_pck(full_path, findings, seen)
		"folder":
			_security_scan_folder(full_path, "", findings, seen)
	findings.sort_custom(_security_sort_findings)
	return findings

# Sort by file then line so the log reads top-to-bottom.
func _security_sort_findings(a: Dictionary, b: Dictionary) -> bool:
	var fa: String = a.get("file", "")
	var fb: String = b.get("file", "")
	if fa != fb:
		return fa < fb
	return int(a.get("line", 0)) < int(b.get("line", 0))

func _security_scan_zip(zip_path: String, findings: Array, seen: Dictionary) -> void:
	var zr := ZIPReader.new()
	if zr.open(zip_path) != OK:
		return
	for f: String in zr.get_files():
		if findings.size() >= _MAX_FINDINGS_PER_MOD:
			break
		if f == "mod.txt" or f.ends_with("/mod.txt"):
			continue
		var ext := f.get_extension().to_lower()
		if not (_TEXT_SCAN_EXTS.has(ext) or _BINARY_SCAN_EXTS.has(ext) or ext == "gdc"):
			continue
		_security_scan_entry(f, ext, zr.read_file(f), findings, seen)
	zr.close()

func _security_scan_folder(root: String, rel: String, findings: Array, seen: Dictionary) -> void:
	var dir := DirAccess.open(root.path_join(rel))
	if dir == null:
		return
	dir.list_dir_begin()
	while findings.size() < _MAX_FINDINGS_PER_MOD:
		var entry := dir.get_next()
		if entry == "":
			break
		if entry.begins_with("."):
			continue
		var rel_path := entry if rel == "" else rel.path_join(entry)
		if dir.current_is_dir():
			_security_scan_folder(root, rel_path, findings, seen)
			continue
		if entry == "mod.txt":
			continue
		var ext := entry.get_extension().to_lower()
		if not (_TEXT_SCAN_EXTS.has(ext) or _BINARY_SCAN_EXTS.has(ext) or ext == "gdc"):
			continue
		_security_scan_disk_entry(root.path_join(rel_path), rel_path, ext, findings, seen)
	dir.list_dir_end()

func _security_scan_pck(pck_path: String, findings: Array, seen: Dictionary) -> void:
	var entries := _security_pck_list_with_offsets(pck_path)
	if entries.is_empty():
		return
	var f := FileAccess.open(pck_path, FileAccess.READ)
	if f == null:
		return
	for entry: Dictionary in entries:
		if findings.size() >= _MAX_FINDINGS_PER_MOD:
			break
		var path: String = entry["path"]
		var ext := path.get_extension().to_lower()
		var size := int(entry["size"])
		if not _security_is_size_allowed(ext, size):
			continue
		f.seek(int(entry["offset"]))
		_security_scan_entry(path, ext, f.get_buffer(size), findings, seen)
	f.close()

func _security_scan_disk_entry(disk_path: String, rel_path: String, ext: String,
		findings: Array, seen: Dictionary) -> void:
	var f := FileAccess.open(disk_path, FileAccess.READ)
	if f == null:
		return
	var size := f.get_length()
	if not _security_is_size_allowed(ext, size):
		f.close()
		return
	_security_scan_entry(rel_path, ext, f.get_buffer(size), findings, seen)
	f.close()

func _security_is_size_allowed(ext: String, byte_count: int) -> bool:
	if byte_count < 0:
		return false
	if ext == "gdc":
		return byte_count <= max(_MAX_BINARY_SCAN_BYTES, _MAX_GDSC_DECOMPRESSED_BYTES)
	if _TEXT_SCAN_EXTS.has(ext):
		return byte_count <= _MAX_TEXT_SCAN_BYTES
	if _BINARY_SCAN_EXTS.has(ext):
		return byte_count <= _MAX_BINARY_SCAN_BYTES
	return false

func _security_scan_entry(file: String, ext: String, bytes: PackedByteArray,
		findings: Array, seen: Dictionary) -> void:
	if bytes.is_empty() or findings.size() >= _MAX_FINDINGS_PER_MOD:
		return
	if ext == "gdc":
		_security_scan_gdc(file, bytes, findings, seen)
		return
	if _TEXT_SCAN_EXTS.has(ext):
		if bytes.size() > _MAX_TEXT_SCAN_BYTES:
			return
		var text := bytes.get_string_from_utf8()
		if text.is_empty():
			text = bytes.get_string_from_ascii()
		_security_scan_text(file, text, findings, seen)
		return
	if _BINARY_SCAN_EXTS.has(ext):
		_security_scan_binary(file, bytes, findings, seen)

func _security_scan_text(file: String, text: String, findings: Array, seen: Dictionary) -> void:
	if text.is_empty():
		return
	# Strip GDScript line comments before matching so docstrings mentioning
	# API names don't false-positive. Newlines preserved so line numbers
	# stay accurate; preview is pulled from the original (uncommented) text.
	var stripped := _strip_gdscript_comments(text)
	var orig_lines := text.split("\n")
	for rule: Dictionary in _SECURITY_RULES:
		if findings.size() >= _MAX_FINDINGS_PER_MOD:
			return
		var re: RegEx = _security_compiled.get(rule["id"], null)
		if re == null:
			continue
		var offset := 0
		var added_for_rule := 0
		var seen_lines: Dictionary = {}
		while offset <= stripped.length() and added_for_rule < _MAX_MATCHES_PER_RULE_PER_FILE:
			if findings.size() >= _MAX_FINDINGS_PER_MOD:
				return
			var m := re.search(stripped, offset)
			if m == null:
				break
			var start := m.get_start()
			var end := m.get_end()
			offset = max(start + 1, end)
			var line := stripped.substr(0, start).count("\n") + 1
			if seen_lines.has(line):
				continue
			seen_lines[line] = true
			if _security_add_finding(findings, seen, {
				"rule": rule["id"],
				"file": file,
				"line": line,
				"preview": _security_preview_for_line(orig_lines, line),
				"description": rule["description"],
			}):
				added_for_rule += 1

func _security_preview_for_line(lines: PackedStringArray, line: int) -> String:
	if line <= 0 or line - 1 >= lines.size():
		return ""
	var preview := (lines[line - 1] as String).strip_edges()
	if preview.length() > 120:
		preview = preview.substr(0, 117) + "..."
	return preview

func _security_add_finding(findings: Array, seen: Dictionary, finding: Dictionary) -> bool:
	if findings.size() >= _MAX_FINDINGS_PER_MOD:
		return false
	var key := "%s|%s|%d|%s" % [
		str(finding.get("rule", "")),
		str(finding.get("file", "")),
		int(finding.get("line", 0)),
		str(finding.get("preview", "")),
	]
	if seen.has(key):
		return false
	seen[key] = true
	findings.append(finding)
	return true

# Strip GDScript line comments (# ...) before pattern matching. Tracks
# string-literal state so a # inside "..." isn't treated as a comment
# start. Newlines preserved so line-number arithmetic stays correct.
func _strip_gdscript_comments(text: String) -> String:
	if text.is_empty():
		return text
	var out := PackedStringArray()
	for line in text.split("\n"):
		out.append(_strip_line_comment(line))
	return "\n".join(out)

func _strip_line_comment(line: String) -> String:
	var in_str := ""
	var prev := ""
	for i in line.length():
		var c := line[i]
		if in_str != "":
			if c == in_str and prev != "\\":
				in_str = ""
		elif c == "\"" or c == "'":
			in_str = c
		elif c == "#":
			return line.substr(0, i)
		prev = c
	return line

func _security_scan_gdc(file: String, bytes: PackedByteArray, findings: Array, seen: Dictionary) -> void:
	var text := _security_detokenize_gdsc_bytes(bytes)
	if not text.is_empty():
		_security_scan_text(file, text, findings, seen)
		return
	_security_scan_binary(file, bytes, findings, seen)

# Byte-search inside binary resources. Only runs rules marked `binary: true`
# -- those whose match is unique enough not to false-positive on legit
# binary serialized content.
func _security_scan_binary(file: String, bytes: PackedByteArray, findings: Array, seen: Dictionary) -> void:
	if bytes.is_empty() or bytes.size() > _MAX_BINARY_SCAN_BYTES:
		return
	var as_text := _security_bytes_to_scan_text(bytes)
	if as_text.is_empty():
		return
	for rule: Dictionary in _SECURITY_RULES:
		if not bool(rule.get("binary", false)):
			continue
		if findings.size() >= _MAX_FINDINGS_PER_MOD:
			return
		var re: RegEx = _security_compiled.get(rule["id"], null)
		if re == null or re.search(as_text) == null:
			continue
		_security_add_finding(findings, seen, {
			"rule": rule["id"],
			"file": file,
			"line": 0,
			"preview": "(matched in binary file)",
			"description": rule["description"],
		})

func _security_bytes_to_scan_text(bytes: PackedByteArray) -> String:
	var as_text := bytes.get_string_from_utf8()
	if not as_text.is_empty():
		return as_text
	var out := PackedByteArray()
	for b in bytes:
		if b >= 32 and b < 127:
			out.append(b)
		else:
			out.append(0x20)
	return out.get_string_from_ascii()

func _security_detokenize_gdsc_bytes(raw: PackedByteArray) -> String:
	if raw.size() < 12:
		return ""
	var magic := raw.slice(0, 4).get_string_from_ascii()
	if magic != _SECURITY_GDSC_MAGIC:
		var plain_text := raw.get_string_from_utf8()
		var head := plain_text.strip_edges(true, false)
		if not plain_text.is_empty() and (head.begins_with("extends")
				or head.begins_with("class_name")
				or head.begins_with("@")
				or "func " in plain_text):
			return plain_text
		return ""
	var version := int(raw.decode_u32(4))
	if version != 100 and version != 101:
		return ""
	var decompressed_size := int(raw.decode_u32(8))
	if decompressed_size < 0 or decompressed_size > _MAX_GDSC_DECOMPRESSED_BYTES:
		return ""
	var buf: PackedByteArray
	if decompressed_size == 0:
		buf = raw.slice(12)
	else:
		buf = raw.slice(12).decompress(decompressed_size, FileAccess.COMPRESSION_ZSTD)
		if buf.is_empty():
			return ""

	var meta_size := 20 if version == 100 else 16
	if buf.size() < meta_size:
		return ""
	var ident_count: int = int(buf.decode_u32(0))
	var const_count: int = int(buf.decode_u32(4))
	var line_count: int = int(buf.decode_u32(8))
	var token_count: int = int(buf.decode_u32(16)) if version == 100 else int(buf.decode_u32(12))
	if ident_count > _MAX_GDSC_TABLE_ENTRIES \
			or const_count > _MAX_GDSC_TABLE_ENTRIES \
			or line_count > _MAX_GDSC_TABLE_ENTRIES \
			or token_count > _MAX_GDSC_TABLE_ENTRIES:
		return ""

	var offset := meta_size
	var identifiers: Array[String] = []
	for _i in ident_count:
		if offset + 4 > buf.size():
			return ""
		var str_len: int = int(buf.decode_u32(offset))
		offset += 4
		if str_len < 0 or str_len > _MAX_GDSC_TABLE_ENTRIES:
			return ""
		var s := ""
		for _j in str_len:
			if offset + 4 > buf.size():
				return ""
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
			return ""
		var remaining := buf.slice(offset)
		var val = bytes_to_var(remaining)
		var encoded := var_to_bytes(val)
		if encoded.is_empty():
			return ""
		constants.append(val)
		offset += encoded.size()
		if offset > buf.size():
			return ""

	var line_map := {}
	var col_map := {}
	for _i in line_count:
		if offset + 8 > buf.size():
			return ""
		line_map[int(buf.decode_u32(offset))] = int(buf.decode_u32(offset + 4))
		offset += 8
	for _i in line_count:
		if offset + 8 > buf.size():
			return ""
		col_map[int(buf.decode_u32(offset))] = int(buf.decode_u32(offset + 4))
		offset += 8

	var tokens: Array = []
	for _i in token_count:
		if offset >= buf.size():
			return ""
		var token_len := 8 if (buf[offset] & _SECURITY_GDSC_TOKEN_BYTE_MASK) else 5
		if offset + token_len > buf.size():
			return ""
		var raw_type: int = int(buf.decode_u32(offset))
		var tk_type: int = raw_type & _SECURITY_GDSC_TOKEN_MASK
		var data_idx: int = raw_type >> _SECURITY_GDSC_TOKEN_BITS
		tokens.append([tk_type, data_idx])
		offset += token_len

	return _security_gdsc_reconstruct(tokens, identifiers, constants, line_map, col_map)

func _security_gdsc_reconstruct(tokens: Array, identifiers: Array[String], constants: Array,
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
			while current_line_num < new_line:
				lines.append(current_line)
				current_line = ""
				current_line_num += 1
				need_space = false
				line_started = false

		if tk == 99:
			break
		if tk == 88:
			lines.append(current_line)
			current_line = ""
			current_line_num += 1
			need_space = false
			line_started = false
			prev_tk = tk
			continue
		if tk == 89 or tk == 90:
			prev_tk = tk
			continue

		var text := ""
		if tk == 2:
			text = identifiers[idx] if idx < identifiers.size() else "<ident?>"
		elif tk == 1:
			var aname: String = identifiers[idx] if idx < identifiers.size() else "?"
			text = aname if aname.begins_with("@") else ("@" + aname)
		elif tk == 3:
			text = _security_gdsc_variant_to_source(constants[idx] if idx < constants.size() else null)
		elif _SECURITY_GDSC_TOKEN_TEXT.has(tk):
			text = _SECURITY_GDSC_TOKEN_TEXT[tk]
		else:
			text = "<tk%d>" % tk

		if not line_started:
			line_started = true
			if col_map.has(i):
				var col: int = col_map[i]
				var tabs: int = col / 4
				for _t in tabs:
					current_line += "\t"

		var add_space_before := false
		if need_space and not current_line.is_empty() and not current_line.ends_with("\t"):
			if _SECURITY_GDSC_SPACE_BEFORE.has(tk):
				add_space_before = true
			elif tk == 2 or tk == 3 or tk == 1 or (tk >= 40 and tk <= 72):
				var skip_anno := (prev_tk == 1 and (tk == 2 or tk == 1))
				if not skip_anno \
						and prev_tk != 77 and prev_tk != 73 \
						and prev_tk != 81 and prev_tk != 85 \
						and prev_tk != 18 \
						and prev_tk != 15 and prev_tk != 89 \
						and prev_tk != 88 and prev_tk != -1:
					add_space_before = true
			elif tk == 77:
				if prev_tk >= 40 and prev_tk <= 50:
					add_space_before = true
			elif tk == 12 or tk == 15:
				add_space_before = true

		if add_space_before and not current_line.ends_with(" ") and not current_line.ends_with("\t"):
			current_line += " "

		current_line += text
		need_space = _SECURITY_GDSC_SPACE_AFTER.has(tk) or tk == 2 or tk == 3 \
				or tk == 78 or tk == 74 or tk == 76 \
				or tk == 91 or tk == 92 or tk == 93 \
				or tk == 94 or tk == 87
		prev_tk = tk

	if not current_line.is_empty():
		lines.append(current_line)

	var result := "\n".join(lines)
	if not result.ends_with("\n"):
		result += "\n"
	return result

func _security_gdsc_variant_to_source(value: Variant) -> String:
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
			return "Vector2(%s, %s)" % [_security_gdsc_variant_to_source(value.x), _security_gdsc_variant_to_source(value.y)]
		TYPE_VECTOR2I:
			return "Vector2i(%s, %s)" % [value.x, value.y]
		TYPE_VECTOR3:
			return "Vector3(%s, %s, %s)" % [_security_gdsc_variant_to_source(value.x), _security_gdsc_variant_to_source(value.y), _security_gdsc_variant_to_source(value.z)]
		TYPE_VECTOR3I:
			return "Vector3i(%s, %s, %s)" % [value.x, value.y, value.z]
		TYPE_COLOR:
			return "Color(%s, %s, %s, %s)" % [_security_gdsc_variant_to_source(value.r), _security_gdsc_variant_to_source(value.g), _security_gdsc_variant_to_source(value.b), _security_gdsc_variant_to_source(value.a)]
		TYPE_ARRAY:
			var parts := PackedStringArray()
			for item in value:
				parts.append(_security_gdsc_variant_to_source(item))
			return "[%s]" % ", ".join(parts)
		TYPE_DICTIONARY:
			var parts := PackedStringArray()
			for k in value:
				parts.append("%s: %s" % [_security_gdsc_variant_to_source(k), _security_gdsc_variant_to_source(value[k])])
			return "{%s}" % ", ".join(parts)
		_:
			return str(value)

# PCK file-table parser that also returns per-entry offset+size so the
# scanner can read individual blobs without mounting the pck.
func _security_pck_list_with_offsets(pck_path: String) -> Array:
	const MAGIC_GDPC: int = 0x43504447  # "GDPC"
	const PACK_DIR_ENCRYPTED := 1
	const PACK_FORMAT_V2 := 2
	const PACK_FORMAT_V3 := 3
	var result: Array = []
	var f := FileAccess.open(pck_path, FileAccess.READ)
	if f == null:
		return result
	var file_length: int = f.get_length()
	if file_length < 32:
		f.close()
		return result

	var magic: int = f.get_32()
	if magic != MAGIC_GDPC:
		f.close()
		return result
	var version: int = f.get_32()
	if version < PACK_FORMAT_V2 or version > PACK_FORMAT_V3:
		f.close()
		return result
	f.get_32()
	f.get_32()
	f.get_32()
	var pack_flags: int = f.get_32()
	f.get_64()
	var dir_offset := f.get_position()
	if version == PACK_FORMAT_V3:
		dir_offset = int(f.get_64())
	else:
		for _i in 16:
			f.get_32()
		dir_offset = f.get_position()
	if pack_flags & PACK_DIR_ENCRYPTED:
		f.close()
		return result
	if dir_offset < 0 or dir_offset + 4 > file_length:
		f.close()
		return result
	f.seek(dir_offset)

	var file_count: int = f.get_32()
	if file_count < 0 or file_count > _MAX_PCK_ENTRY_COUNT:
		f.close()
		return result
	for _i in file_count:
		if f.get_position() + 4 > file_length:
			break
		var path_len: int = f.get_32()
		if path_len <= 0 or path_len > _MAX_PCK_PATH_BYTES:
			break
		if f.get_position() + path_len + 8 + 8 + 16 + 4 > file_length:
			break
		var path := f.get_buffer(path_len).get_string_from_utf8()
		var offset: int = int(f.get_64())
		var size: int = int(f.get_64())
		f.get_buffer(16)
		f.get_32()
		if path.is_empty():
			continue
		if offset < 0 or size < 0 or offset > file_length or size > file_length - offset:
			continue
		result.append({"path": path, "offset": offset, "size": size})
	f.close()
	return result
