## ----- security_scan.gd -----
## Lightweight guardrail. Reads each file inside a candidate mod
## (zip/vmz, pck, or developer-mode folder) WITHOUT mounting it and looks
## for combinations of GDScript patterns that are nearly diagnostic of
## known malware: obfuscated string decoding paired with process
## spawning, anti-debug crashes, ransomware-setup calls.
##
## This is NOT a virus scanner. It catches the lazy / copy-paste attacks
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

# Cap individual file size we will fully scan. Almost no legitimate mod
# script is over a couple hundred KB.
const _MAX_TEXT_SCAN_BYTES: int = 8 * 1024 * 1024

# Rules. Each rule's individual presence is not a warning by itself --
# the user only sees a badge when compute_risk_level() returns RISK_RED,
# which fires for solo red triggers (os_crash, disable_save_safety) or
# for combinations (obfuscation + process spawn, runtime-code-build +
# process spawn, both obfuscation patterns together).
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
	"byte_decode_loop", "large_int_array",
]
const _RUNTIME_CODE_RULES: Array = [
	"script_from_string", "marshalls_objects_decode",
	"deserialize_objects", "expression_eval",
]

# Returns RISK_CLEAN or RISK_RED.
#
# Red fires on:
#   - any RED_SOLO rule present
#   - both obfuscation rules together (encoded payload pattern)
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
	match ext:
		"vmz", "zip":
			_security_scan_zip(full_path, findings)
		"pck":
			_security_scan_pck(full_path, findings)
		"folder":
			_security_scan_folder(full_path, "", findings)
	findings.sort_custom(_security_sort_findings)
	return findings

# Sort by file then line so the log reads top-to-bottom.
func _security_sort_findings(a: Dictionary, b: Dictionary) -> bool:
	var fa: String = a.get("file", "")
	var fb: String = b.get("file", "")
	if fa != fb:
		return fa < fb
	return int(a.get("line", 0)) < int(b.get("line", 0))

func _security_scan_zip(zip_path: String, findings: Array) -> void:
	var zr := ZIPReader.new()
	if zr.open(zip_path) != OK:
		return
	for f: String in zr.get_files():
		if findings.size() >= _MAX_FINDINGS_PER_MOD:
			break
		if f == "mod.txt" or f.ends_with("/mod.txt"):
			continue
		var ext := f.get_extension().to_lower()
		if _TEXT_SCAN_EXTS.has(ext):
			var bytes := zr.read_file(f)
			if bytes.size() > _MAX_TEXT_SCAN_BYTES:
				continue
			_security_scan_text(f, bytes.get_string_from_utf8(), findings)
			continue
		if _BINARY_SCAN_EXTS.has(ext) or ext == "gdc":
			_security_scan_binary(f, zr.read_file(f), findings)
	zr.close()

func _security_scan_folder(root: String, rel: String, findings: Array) -> void:
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
			_security_scan_folder(root, rel_path, findings)
			continue
		if entry == "mod.txt":
			continue
		var ext := entry.get_extension().to_lower()
		var disk_path := root.path_join(rel_path)
		if _TEXT_SCAN_EXTS.has(ext):
			var bytes := FileAccess.get_file_as_bytes(disk_path)
			if bytes.size() > _MAX_TEXT_SCAN_BYTES:
				continue
			_security_scan_text(rel_path, bytes.get_string_from_utf8(), findings)
			continue
		if _BINARY_SCAN_EXTS.has(ext) or ext == "gdc":
			_security_scan_binary(rel_path,
					FileAccess.get_file_as_bytes(disk_path), findings)
	dir.list_dir_end()

func _security_scan_pck(pck_path: String, findings: Array) -> void:
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
		if not (_TEXT_SCAN_EXTS.has(ext) or _BINARY_SCAN_EXTS.has(ext) or ext == "gdc"):
			continue
		f.seek(int(entry["offset"]))
		var bytes := f.get_buffer(int(entry["size"]))
		if _TEXT_SCAN_EXTS.has(ext):
			if bytes.size() > _MAX_TEXT_SCAN_BYTES:
				continue
			_security_scan_text(path, bytes.get_string_from_utf8(), findings)
		else:
			_security_scan_binary(path, bytes, findings)
	f.close()

func _security_scan_text(file: String, text: String, findings: Array) -> void:
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
		var m := re.search(stripped)
		if m == null:
			continue
		var pre := stripped.substr(0, m.get_start())
		var line := pre.count("\n") + 1
		var preview := ""
		if line - 1 < orig_lines.size():
			preview = (orig_lines[line - 1] as String).strip_edges()
			if preview.length() > 120:
				preview = preview.substr(0, 117) + "..."
		findings.append({
			"rule": rule["id"],
			"file": file,
			"line": line,
			"preview": preview,
			"description": rule["description"],
		})

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

# Byte-search inside binary resources or .gdc files. Only runs rules
# marked `binary: true` -- those whose match is unique enough not to
# false-positive on legit binary serialized content.
func _security_scan_binary(file: String, bytes: PackedByteArray, findings: Array) -> void:
	if bytes.is_empty():
		return
	var as_text := bytes.get_string_from_utf8()
	if as_text.is_empty():
		var out := PackedByteArray()
		for b in bytes:
			if b >= 32 and b < 127:
				out.append(b)
			else:
				out.append(0x20)
		as_text = out.get_string_from_ascii()
	for rule: Dictionary in _SECURITY_RULES:
		if not bool(rule.get("binary", false)):
			continue
		if findings.size() >= _MAX_FINDINGS_PER_MOD:
			return
		var re: RegEx = _security_compiled.get(rule["id"], null)
		if re == null:
			continue
		if re.search(as_text) == null:
			continue
		findings.append({
			"rule": rule["id"],
			"file": file,
			"line": 0,
			"preview": "(matched in binary file)",
			"description": rule["description"],
		})

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
	var magic: int = f.get_32()
	if magic != MAGIC_GDPC:
		f.close()
		return result
	var version: int = f.get_32()
	if version < PACK_FORMAT_V2 or version > PACK_FORMAT_V3:
		f.close()
		return result
	f.get_32(); f.get_32(); f.get_32()
	var pack_flags: int = f.get_32()
	f.get_64()
	if version == PACK_FORMAT_V3:
		f.seek(f.get_64())
	else:
		for i in 16:
			f.get_32()
	if pack_flags & PACK_DIR_ENCRYPTED:
		f.close()
		return result
	var file_count: int = f.get_32()
	for i in file_count:
		var path_len: int = f.get_32()
		if path_len == 0 or path_len > 4096:
			break
		var path := f.get_buffer(path_len).get_string_from_utf8()
		var offset: int = f.get_64()
		var size: int = f.get_64()
		f.get_buffer(16)
		f.get_32()
		if not path.is_empty():
			result.append({"path": path, "offset": offset, "size": size})
	f.close()
	return result
