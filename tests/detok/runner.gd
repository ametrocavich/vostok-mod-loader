## runner.gd -- GDSC detokenizer harness. NOT part of the shipped loader.
## Executed by check_detok.sh inside a THROWAWAY Godot project assembled
## under the system temp dir; never run it against this repo or against the
## Road to Vostok install.
##
## WHY THIS EXISTS: the detokenizer had zero test coverage. Its only
## correctness check was STABILITY canary C, which runs at game launch on the
## user's machine. That is why the v100 token-index shift (every index from
## 83 up sits one lower in bytecode v100 than in the v101 table the
## detokenizer carries) sat undetected: the version gate accepts v100, so a
## v100 .gdc decoded ":" as "...", NEWLINE as "_", and never terminated on
## EOF -- and the garbage was then cached as pristine vanilla source.
##
## WHAT THIS PROVES, AND WHAT IT DOES NOT:
##   PROVES  -- token-index normalization across bytecode versions, the
##              reconstruction pass (line placement, indentation, spacing,
##              literal rendering), and TK_EMPTY handling.
##   DOES NOT PROVE -- that our understanding of the CONTAINER layout matches
##              the real engine. The fixtures below are synthesized against
##              this repo's own reader, so a shared misreading of the header
##              would be invisible here. Canary C, which round-trips a real
##              .gdc from the shipped PCK, remains the only check of that.
##              Do not delete canary C on the strength of this harness.
##
## Unlike check_codegen.sh this needs no decompiled vanilla corpus, so it
## runs on any machine.
extends SceneTree

const MODLOADER_PATH := "res://modloader_neutered.gd"

# Bytecode versions, mirroring constants.gd.
const V100 := 100
const V101 := 101

# Token indices in the v101 table (what the detokenizer carries).
const T_ANNOTATION := 1
const T_IDENTIFIER := 2
const T_LITERAL := 3
const T_RETURN := 48
const T_FUNC := 60
const T_VAR := 70
const T_BRACKET_OPEN := 73
const T_BRACKET_CLOSE := 74
const T_PAREN_OPEN := 77
const T_PAREN_CLOSE := 78
const T_COMMA := 79
const T_PERIOD := 81
# --- everything from here up is shifted by one in v100 ---
const T_PERIOD_PERIOD_PERIOD := 83
const T_COLON := 84
const T_DOLLAR := 85
const T_ARROW := 86
const T_UNDERSCORE := 87
const T_NEWLINE := 88
const T_EOF := 99

# The index at and above which v101 gained one slot ("..." at 83).
const SHIFT_FROM := 83

var _failures: PackedStringArray = []
var _assertions := 0

func _init() -> void:
	print("[detok] harness start")

func _process(_delta: float) -> bool:
	_run()
	return true

func _run() -> void:
	var ml_script := load(MODLOADER_PATH) as GDScript
	if ml_script == null:
		_fail("could not load " + MODLOADER_PATH)
		_finish()
		return
	var ml: Object = ml_script.new()
	# Same guard the codegen harness uses: prove the boot static-init really
	# was neutralized before we touch anything on this instance.
	var mounted: Variant = ml.get("_filescope_mounted")
	if typeof(mounted) != TYPE_DICTIONARY or not (mounted as Dictionary).is_empty():
		_fail("modloader boot static-init was NOT neutralized -- refusing to run")
		_finish()
		return

	_t1_v101_baseline(ml)
	_t2_v100_matches_v101(ml)
	_t3_no_placeholders(ml)
	_t4_tk_empty_skipped(ml)
	_t5_shifted_indices_all_render(ml)
	_t6_vfs_read_is_not_cached(ml)
	_t7_pck_wins_over_vfs(ml)
	_t8_old_cache_format_is_dropped(ml)

	_finish()

# --- Fixture -----------------------------------------------------------------

# One synthetic script, expressed as (token, data index) pairs plus line/column
# maps. Deliberately dense in indices >= 83 (":", "->", "$", "_", NEWLINE, EOF)
# because those are exactly the ones the v100 shift moves.
#
#   func foo(_a) -> int:
#       return 1
#
# Columns are 1-based and assume 4-space source indentation, which is what
# _indent_from_column's `col / 4` decodes (see the long note above it).
func _fixture_tokens() -> Array:
	return [
		# [token, data_index, line, column]  (column 0 = no col_map entry)
		[T_FUNC, 0, 1, 1],
		[T_IDENTIFIER, 0, 1, 6],       # foo
		[T_PAREN_OPEN, 0, 1, 9],
		[T_UNDERSCORE, 0, 1, 10],      # _
		[T_PAREN_CLOSE, 0, 1, 11],
		[T_ARROW, 0, 1, 13],           # ->
		[T_IDENTIFIER, 1, 1, 16],      # int
		[T_COLON, 0, 1, 19],           # :
		[T_NEWLINE, 0, 1, 20],
		[T_RETURN, 0, 2, 5],
		[T_LITERAL, 0, 2, 12],         # 1
		[T_NEWLINE, 0, 2, 13],
		[T_EOF, 0, 3, 1],
	]

func _fixture_identifiers() -> Array:
	return ["foo", "int"]

func _fixture_constants() -> Array:
	return [1]

# --- Tests -------------------------------------------------------------------

func _t1_v101_baseline(ml: Object) -> void:
	var src := _detok(ml, V101, _fixture_tokens(), "synth_v101.gd")
	_assert(not src.is_empty(), "T1: v101 fixture reconstructed to something")
	_assert(src.contains("func foo"), "T1: declaration survives (got: %s)" % _oneline(src))
	_assert(src.contains("->"), "T1: return-arrow token (86) renders")
	_assert(src.contains(":"), "T1: colon token (84) renders as ':' not '...'")
	_assert(src.contains("return 1"), "T1: body statement renders")
	# The body must be indented. col 5 with 4-space source => exactly one tab.
	var body_ok := false
	for line in src.split("\n"):
		if line.begins_with("\t") and line.contains("return"):
			body_ok = true
	_assert(body_ok, "T1: body line is tab-indented (col/4 math) -- got: %s" % _oneline(src))

# THE F1 REGRESSION LOCK. Same logical token stream, encoded once with v101
# indices under a v101 header and once with v100 indices under a v100 header.
# Both must reconstruct to byte-identical source. Before the normalization in
# _detokenize_script this failed loudly: the v100 stream rendered ":" as "...",
# NEWLINE as "_", and fell through to "<tk98>" instead of terminating on EOF.
func _t2_v100_matches_v101(ml: Object) -> void:
	var v101_src := _detok(ml, V101, _fixture_tokens(), "synth_a101.gd")
	var v100_src := _detok(ml, V100, _to_v100_indices(_fixture_tokens()), "synth_a100.gd")
	_assert(not v100_src.is_empty(), "T2: v100 fixture reconstructed to something")
	_assert(v100_src == v101_src,
			"T2: v100 and v101 must reconstruct identically.\n    v101: %s\n    v100: %s"
					% [_oneline(v101_src), _oneline(v100_src)])

func _t3_no_placeholders(ml: Object) -> void:
	for spec in [[V101, _fixture_tokens(), "synth_p101.gd"], [V100, _to_v100_indices(_fixture_tokens()), "synth_p100.gd"]]:
		var src := _detok(ml, spec[0], spec[1], spec[2])
		_assert(not src.contains("<tk"),
				"T3: v%d output contains an unmapped-token placeholder: %s" % [spec[0], _oneline(src)])
		_assert(not src.contains("<ident?>"),
				"T3: v%d output contains an unresolved identifier" % spec[0])

# F3: TK_EMPTY (index 0) is the tokenizer's placeholder and is never emitted
# into a real stream, but upstream skips it explicitly. Without the guard it
# falls through to "<tk0>".
func _t4_tk_empty_skipped(ml: Object) -> void:
	var toks := _fixture_tokens()
	toks.insert(2, [0, 0, 1, 9])  # TK_EMPTY spliced mid-line
	var src := _detok(ml, V101, toks, "synth_empty.gd")
	_assert(not src.contains("<tk0>"), "T4: TK_EMPTY must be skipped, not rendered")
	_assert(src.contains("func foo"), "T4: TK_EMPTY does not derail the rest of the stream")

# Every index the v100 shift touches must render to real text in BOTH
# encodings. A table entry that only exists on one side shows up here rather
# than as mystery output on a user's machine.
func _t5_shifted_indices_all_render(ml: Object) -> void:
	var shifted := [T_PERIOD_PERIOD_PERIOD, T_COLON, T_DOLLAR, T_ARROW, T_UNDERSCORE]
	for tk in shifted:
		var toks := [[tk, 0, 1, 1], [T_NEWLINE, 0, 1, 2], [T_EOF, 0, 2, 1]]
		var a := _detok(ml, V101, toks, "synth_s101_%d.gd" % tk)
		_assert(not a.contains("<tk"), "T5: v101 index %d has no table entry" % tk)
		# "..." is the token v101 ADDED, so it has no v100 counterpart and
		# there is nothing to compare. Every index above it does.
		if tk == T_PERIOD_PERIOD_PERIOD:
			continue
		var b := _detok(ml, V100, _to_v100_indices(toks), "synth_s100_%d.gd" % tk)
		_assert(a == b, "T5: index %d renders differently across versions (v101 %s vs v100 %s)"
				% [tk, _oneline(a), _oneline(b)])

# --- Encoder -----------------------------------------------------------------

# Map a v101 token stream to the v100 indices that encode the SAME tokens.
# v100 predates "..." at 83, so everything from 83 up sits one lower.
# --- Vanilla-cache poisoning (B1) --------------------------------------------
#
# Hook-pack generation reads vanilla scripts after mod archives are mounted.
# A mod shipping a plain-text res://Scripts/X.gd used to be read through the
# VFS, accepted as vanilla, and cached forever. These three tests pin the
# fix: a VFS read is never cached, the game's PCK bytes win over whatever the
# VFS serves, and a cache written by an older loader is dropped.

const CACHE_DIR := "user://modloader_hooks/vanilla"

# A pack-format-2 .pck holding plain-text files, laid out the way
# _security_pck_list_with_offsets reads it back.
func _write_fake_pck(path: String, files: Dictionary) -> bool:
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return false
	f.store_32(0x43504447)  # "GDPC"
	f.store_32(2)           # PACK_FORMAT_V2
	f.store_32(4); f.store_32(6); f.store_32(0)
	f.store_32(0)           # pack flags: not encrypted
	var file_base_pos := f.get_position()
	f.store_64(0)           # file_base, patched below
	for i in 16:
		f.store_32(0)
	f.store_32(files.size())
	var entries := []
	var data_offset := 0
	for p in files:
		var bytes: PackedByteArray = str(files[p]).to_utf8_buffer()
		entries.append({"path": str(p), "offset": data_offset, "bytes": bytes})
		data_offset += bytes.size()
	for e in entries:
		var pb: PackedByteArray = str(e["path"]).to_utf8_buffer()
		f.store_32(pb.size())
		f.store_buffer(pb)
		f.store_64(int(e["offset"]))
		f.store_64((e["bytes"] as PackedByteArray).size())
		f.store_buffer(PackedByteArray([0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]))
		f.store_32(0)
	var file_base := f.get_position()
	for e in entries:
		f.store_buffer(e["bytes"])
	f.seek(file_base_pos)
	f.store_64(file_base)
	f.close()
	return true

func _write_text(path: String, text: String) -> bool:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(path.get_base_dir()))
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return false
	f.store_string(text)
	f.close()
	return true

func _reset_detok_state(ml: Object) -> void:
	ml.set("_game_pck_index", {})
	ml.set("_game_pck_path", "")
	ml.set("_game_pck_indexed", false)
	ml.set("_vanilla_cache_checked", false)
	var dir := ProjectSettings.globalize_path(CACHE_DIR)
	if DirAccess.dir_exists_absolute(dir):
		ml._wipe_shallow_tree(dir)
		DirAccess.remove_absolute(dir)

func _t6_vfs_read_is_not_cached(ml: Object) -> void:
	_reset_detok_state(ml)
	# No game PCK anywhere near this harness: the VFS fallback serves the
	# planted file, exactly what a mounted mod would look like in the game.
	ml.set("_game_pck_path_override", "")
	_assert(_write_text("res://Scripts/Poison.gd", "extends Node\nvar poisoned = true\n"),
			"T6: planted a plain-text script in the project")
	var src := str(ml._read_vanilla_source("res://Scripts/Poison.gd"))
	_assert(src.contains("poisoned"), "T6: with no PCK the VFS text is still returned (nothing better exists)")
	_assert(not bool(ml.get("_last_detokenize_from_pck")), "T6: the read is flagged as not from the PCK")
	_assert(not FileAccess.file_exists(CACHE_DIR + "/Scripts/Poison.gd"),
			"T6: a VFS read must never be written to the vanilla cache")

func _t7_pck_wins_over_vfs(ml: Object) -> void:
	_reset_detok_state(ml)
	var pck := "user://fake_game.pck"
	_assert(_write_fake_pck(pck, {
		"res://Scripts/Foo.gd": "extends Node\nvar from_pck = true\n",
		"res://Scripts/Bar.gd": "extends Node\nvar bar_from_pck = true\n",
	}), "T7: wrote a synthetic game pack")
	ml.set("_game_pck_path_override", ProjectSettings.globalize_path(pck))
	# The VFS serves a different file at the same path: a mod's override.
	_assert(_write_text("res://Scripts/Foo.gd", "extends Node\nvar poisoned = true\n"),
			"T7: planted a competing plain-text script in the project")
	var src := str(ml._read_vanilla_source("res://Scripts/Foo.gd"))
	_assert(src.contains("from_pck") and not src.contains("poisoned"),
			"T7: the PCK bytes win over the VFS file (got: %s)" % _oneline(src))
	_assert(bool(ml.get("_last_detokenize_from_pck")), "T7: the read is flagged as from the PCK")
	var cached := FileAccess.get_file_as_string(CACHE_DIR + "/Scripts/Foo.gd")
	_assert(cached.contains("from_pck") and not cached.contains("poisoned"),
			"T7: the cache holds the PCK text, never the VFS text")
	_assert(FileAccess.get_file_as_string(CACHE_DIR + "/format").strip_edges() == "2",
			"T7: the cache carries its format stamp")
	# Second read comes from the cache and still says the same thing.
	var again := str(ml._read_vanilla_source("res://Scripts/Foo.gd"))
	_assert(again == src, "T7: the cached read matches the first read")

func _t8_old_cache_format_is_dropped(ml: Object) -> void:
	_reset_detok_state(ml)
	var pck := "user://fake_game.pck"
	ml.set("_game_pck_path_override", ProjectSettings.globalize_path(pck))
	# A cache written by an older loader: no stamp, and a poisoned entry.
	_assert(_write_text(CACHE_DIR + "/Scripts/Bar.gd", "extends Node\nvar poisoned = true\n"),
			"T8: planted an unstamped, poisoned cache entry")
	var src := str(ml._read_vanilla_source("res://Scripts/Bar.gd"))
	_assert(src.contains("bar_from_pck") and not src.contains("poisoned"),
			"T8: an unstamped cache is wiped and the PCK text is used (got: %s)" % _oneline(src))
	var cached := FileAccess.get_file_as_string(CACHE_DIR + "/Scripts/Bar.gd")
	_assert(cached.contains("bar_from_pck"), "T8: the rebuilt cache holds the PCK text")
	# Cleanup so the throwaway project's res:// stays clean for --prove.
	DirAccess.remove_absolute(ProjectSettings.globalize_path("res://Scripts/Foo.gd"))
	DirAccess.remove_absolute(ProjectSettings.globalize_path("res://Scripts/Poison.gd"))

func _to_v100_indices(toks: Array) -> Array:
	var out: Array = []
	for t in toks:
		var tk: int = t[0]
		if tk == T_PERIOD_PERIOD_PERIOD:
			# "..." does not exist in v100 at all; nothing to encode.
			continue
		if tk >= SHIFT_FROM:
			tk -= 1
		out.append([tk, t[1], t[2], t[3]])
	return out

# Build a GDSC buffer this repo's reader accepts, write it, detokenize it.
func _detok(ml: Object, version: int, toks: Array, fname: String) -> String:
	var buf := _encode(version, toks, _fixture_identifiers(), _fixture_constants())
	var path := "res://" + fname
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		_fail("could not write fixture " + path)
		return ""
	f.store_buffer(buf)
	f.close()
	return str(ml._detokenize_script(path))

func _encode(version: int, toks: Array, idents: Array, consts: Array) -> PackedByteArray:
	var body := PackedByteArray()

	# -- Metadata. v101: ident/const/line/token at 0/4/8/12 (16 bytes).
	#    v100: same but token_count at 16, with 4 bytes of padding at 12.
	_u32(body, idents.size())
	_u32(body, consts.size())
	_u32(body, toks.size())        # line_count: one map entry per token
	if version == V100:
		_u32(body, 0)              # padding slot the reader skips
	_u32(body, toks.size())

	# -- Identifiers: u32 length, then length UTF-32 code points XOR 0xb6.
	for s in idents:
		var text: String = str(s)
		_u32(body, text.length())
		for i in text.length():
			var cp := text.unicode_at(i)
			body.append((cp & 0xFF) ^ 0xb6)
			body.append(((cp >> 8) & 0xFF) ^ 0xb6)
			body.append(((cp >> 16) & 0xFF) ^ 0xb6)
			body.append(((cp >> 24) & 0xFF) ^ 0xb6)

	# -- Constants: sequential Variant encoding, exactly what the reader
	#    advances over with var_to_bytes().
	for c in consts:
		body.append_array(var_to_bytes(c))

	# -- Line map, then column map: (token_index, value) pairs.
	for i in toks.size():
		_u32(body, i)
		_u32(body, toks[i][2])
	for i in toks.size():
		_u32(body, i)
		_u32(body, toks[i][3])

	# -- Token stream. Bit 7 of the low byte selects the wide form; the
	#    reader takes tk_type from bits 0-6 and the data index from bits 8+.
	for t in toks:
		var tk: int = t[0]
		var data: int = t[1]
		if data > 0:
			_u32(body, tk | 0x80 | (data << 8))
			for _p in 4:
				body.append(0)
		else:
			_u32(body, tk)
			body.append(0)

	# -- Container header: magic, version, decompressed size (0 = stored
	#    uncompressed, which the reader handles directly).
	var out := PackedByteArray()
	out.append_array("GDSC".to_ascii_buffer())
	_u32(out, version)
	_u32(out, 0)
	out.append_array(body)
	return out

func _u32(buf: PackedByteArray, value: int) -> void:
	buf.append(value & 0xFF)
	buf.append((value >> 8) & 0xFF)
	buf.append((value >> 16) & 0xFF)
	buf.append((value >> 24) & 0xFF)

# --- Reporting ---------------------------------------------------------------

func _oneline(s: String) -> String:
	return s.replace("\n", "\\n").replace("\t", "\\t")

func _assert(cond: bool, msg: String) -> void:
	_assertions += 1
	if not cond:
		_failures.append(msg)

func _fail(msg: String) -> void:
	_failures.append(msg)

func _finish() -> void:
	if _failures.is_empty():
		print("[detok] PASS: %d assertion(s) across T1..T8" % _assertions)
		quit(0)
		return
	for m in _failures:
		printerr("[detok] FAIL: " + m)
	printerr("[detok] FAILED: %d of %d assertion(s)" % [_failures.size(), _assertions])
	quit(1)
