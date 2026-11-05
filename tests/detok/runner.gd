## GDSC detokenizer harness, run by check_detok.sh on bytecode built here.
## Does not prove the container layout matches the engine's: canary C does.
extends "res://runner_base.gd"

const V100 := 100
const V101 := 101

# v101 token indices; from SHIFT_FROM ("..." at 83) up, v100 sits one lower.
const T_IDENTIFIER := 2
const T_LITERAL := 3
const T_RETURN := 48
const T_ASSIGN := 28
const T_AWAIT := 53
const T_FUNC := 60
const T_VAR := 70
const T_PAREN_OPEN := 77
const T_PAREN_CLOSE := 78
const T_PERIOD := 81
const T_PERIOD_PERIOD_PERIOD := 83
const T_COLON := 84
const T_DOLLAR := 85
const T_ARROW := 86
const T_UNDERSCORE := 87
const T_NEWLINE := 88
const T_EOF := 99
const SHIFT_FROM := 83

const IDENTS := ["foo", "int"]
const CONSTS := [1]
const CACHE_DIR := "user://modloader_hooks/vanilla"
const SCRIPT_INDEX := "user://modloader_hooks/script_index.txt"
# Keyword tokens 40..72 in index order.
const KEYWORDS := ["if", "elif", "else", "for", "while", "break", "continue", "pass",
		"return", "match", "when", "as", "assert", "await", "breakpoint", "class",
		"class_name", "const", "enum", "extends", "func", "in", "is", "namespace",
		"preload", "self", "signal", "static", "super", "trait", "var", "void", "yield"]

func _init() -> void:
	super("detok", "T1..T17")

func _tests(ml: Object) -> void:
	for t in [_t1_v101_baseline, _t2_v100_matches_v101, _t3_no_placeholders, _t4_tk_empty_skipped,
			_t5_shifted_indices, _t6_vfs_read_not_cached, _t7_pck_wins_over_vfs, _t8_old_cache_dropped,
			_t9_gdc_fallback_read, _t10_canary_any_probe, _t11_changed_pck_drops_cache, _t12_await_space,
			_t13_string_escapes, _t14_script_enumeration, _t15_canary_b_version, _t16_keyword_spacing,
			_t17_pck_readers_agree]:
		begin(str(t.get_method()).get_slice("_", 1).to_upper())
		t.call(ml)

# func foo(_a) -> int:
#     return 1
# [token, data index, line, column]; columns are 1-based over 4-space indents.
func _fixture() -> Array:
	return [
		[T_FUNC, 0, 1, 1], [T_IDENTIFIER, 0, 1, 6], [T_PAREN_OPEN, 0, 1, 9], [T_UNDERSCORE, 0, 1, 10],
		[T_PAREN_CLOSE, 0, 1, 11], [T_ARROW, 0, 1, 13], [T_IDENTIFIER, 1, 1, 16], [T_COLON, 0, 1, 19],
		[T_NEWLINE, 0, 1, 20],
		[T_RETURN, 0, 2, 5], [T_LITERAL, 0, 2, 12], [T_NEWLINE, 0, 2, 13],
		[T_EOF, 0, 3, 1],
	]

func _t1_v101_baseline(ml: Object) -> void:
	var src := _detok(ml, V101, _fixture(), "synth_v101.gd")
	_assert(not src.is_empty(), "the v101 fixture reconstructs")
	for want in ["func foo", "->", ":", "return 1"]:
		_assert(src.contains(want), "renders '%s' (got: %s)" % [want, H.oneline(src)])
	var indented := Array(src.split("\n")).any(func(l: String) -> bool: return l.begins_with("\t") and l.contains("return"))
	_assert(indented, "the body line is tab-indented (got: %s)" % H.oneline(src))

# Without the v100 normalization ":" renders as "...", NEWLINE as "_", and
# EOF as "<tk98>".
func _t2_v100_matches_v101(ml: Object) -> void:
	var v101_src := _detok(ml, V101, _fixture(), "synth_a101.gd")
	var v100_src := _detok(ml, V100, _to_v100(_fixture()), "synth_a100.gd")
	_assert(not v100_src.is_empty(), "the v100 fixture reconstructs")
	check_eq(v100_src, v101_src, "v100 source")

func _t3_no_placeholders(ml: Object) -> void:
	for spec in [[V101, _fixture(), "synth_p101.gd"], [V100, _to_v100(_fixture()), "synth_p100.gd"]]:
		var src := _detok(ml, spec[0], spec[1], spec[2])
		_assert(not src.contains("<tk"), "v%d has an unmapped token: %s" % [spec[0], H.oneline(src)])
		_assert(not src.contains("<ident?>"), "v%d has an unresolved identifier" % spec[0])

# _TK_EMPTY (index 0) never appears in a real stream, but upstream skips it.
func _t4_tk_empty_skipped(ml: Object) -> void:
	var toks := _fixture()
	toks.insert(2, [0, 0, 1, 9])
	var src := _detok(ml, V101, toks, "synth_empty.gd")
	_assert(not src.contains("<tk0>"), "_TK_EMPTY is skipped, not rendered")
	_assert(src.contains("func foo"), "the rest of the stream survives")

func _t5_shifted_indices(ml: Object) -> void:
	for tk in [T_PERIOD_PERIOD_PERIOD, T_COLON, T_DOLLAR, T_ARROW, T_UNDERSCORE]:
		var toks := [[tk, 0, 1, 1], [T_NEWLINE, 0, 1, 2], [T_EOF, 0, 2, 1]]
		var a := _detok(ml, V101, toks, "synth_s101_%d.gd" % tk)
		_assert(not a.contains("<tk"), "v101 index %d has a table entry" % tk)
		# "..." is the token v101 added: v100 has nothing to compare.
		if tk == T_PERIOD_PERIOD_PERIOD:
			continue
		var b := _detok(ml, V100, _to_v100(toks), "synth_s100_%d.gd" % tk)
		check_eq(b, a, "v100 rendering of index %d" % tk)

# A mod's plain-text res://Scripts/X.gd is what the VFS serves once mods are
# mounted; cached, it would pass for vanilla forever.
func _t6_vfs_read_not_cached(ml: Object) -> void:
	_reset_cache(ml)
	ml.set("_game_pck_path_override", "")
	_assert(H.write_text("res://Scripts/Poison.gd", "extends Node\nvar poisoned = true\n"), "planted a plain-text script")
	var src := str(ml._read_vanilla_source("res://Scripts/Poison.gd"))
	_assert(src.contains("poisoned"), "with no PCK the VFS text is returned")
	_assert(not bool(ml.get("_last_detokenize_from_pck")), "the read is not flagged as PCK")
	_assert(not FileAccess.file_exists(CACHE_DIR + "/Scripts/Poison.gd"), "a VFS read is never cached")

func _t7_pck_wins_over_vfs(ml: Object) -> void:
	_reset_cache(ml)
	var pck := "user://fake_game.pck"
	_assert(_write_pck(pck, {
		"res://Scripts/Foo.gd": "extends Node\nvar from_pck = true\n",
		"res://Scripts/Bar.gd": "extends Node\nvar bar_from_pck = true\n",
	}), "wrote a synthetic game pack")
	ml.set("_game_pck_path_override", ProjectSettings.globalize_path(pck))
	_assert(H.write_text("res://Scripts/Foo.gd", "extends Node\nvar poisoned = true\n"), "planted a competing script")
	var src := str(ml._read_vanilla_source("res://Scripts/Foo.gd"))
	_assert(src.contains("from_pck") and not src.contains("poisoned"), "the PCK bytes win (got: %s)" % H.oneline(src))
	_assert(bool(ml.get("_last_detokenize_from_pck")), "the read is flagged as from the PCK")
	var cached := FileAccess.get_file_as_string(CACHE_DIR + "/Scripts/Foo.gd")
	_assert(cached.contains("from_pck") and not cached.contains("poisoned"), "the cache holds the PCK text")
	check_eq(FileAccess.get_file_as_string(CACHE_DIR + "/format").strip_edges(), "2", "the cache format stamp")
	check_eq(str(ml._read_vanilla_source("res://Scripts/Foo.gd")), src, "the cached read")

func _t8_old_cache_dropped(ml: Object) -> void:
	_reset_cache(ml)
	ml.set("_game_pck_path_override", ProjectSettings.globalize_path("user://fake_game.pck"))
	_assert(H.write_text(CACHE_DIR + "/Scripts/Bar.gd", "extends Node\nvar poisoned = true\n"),
			"planted an unstamped, poisoned cache entry")
	var src := str(ml._read_vanilla_source("res://Scripts/Bar.gd"))
	_assert(src.contains("bar_from_pck") and not src.contains("poisoned"),
			"an unstamped cache is wiped (got: %s)" % H.oneline(src))
	_assert(FileAccess.get_file_as_string(CACHE_DIR + "/Scripts/Bar.gd").contains("bar_from_pck"),
			"the rebuilt cache holds the PCK text")
	for p in ["res://Scripts/Foo.gd", "res://Scripts/Poison.gd"]:
		DirAccess.remove_absolute(ProjectSettings.globalize_path(p))

# In the game the .gd path is a remap FileAccess cannot open, so the .gdc
# beside it is what serves; a null handle on the way must not abort the read.
func _t9_gdc_fallback_read(ml: Object) -> void:
	_reset_cache(ml)
	ml.set("_game_pck_path_override", "")
	var gdc_path := "res://Scripts/Camera.gdc"
	_assert(H.write_bytes(gdc_path, _encode(V101, _fixture())), "planted a .gdc with no .gd")
	var src := str(ml._detokenize_script("res://Scripts/Camera.gd"))
	_assert(src.contains("func foo"), "the .gd path reads the .gdc (got: %s)" % H.oneline(src))
	DirAccess.remove_absolute(ProjectSettings.globalize_path(gdc_path))

# Canary C passes when any probe passes, fails only when probes produced
# source and none passed, and passes when no probe is readable.
func _t10_canary_any_probe(ml: Object) -> void:
	_reset_cache(ml)
	ml.set("_game_pck_path_override", "")
	var odd := _fixture()
	for t in odd:
		if t[0] == T_RETURN:
			t[3] = 1
		elif t[0] == T_LITERAL:
			t[3] = 8
	var odd_path := "res://Scripts/Camera.gdc"
	var clean_path := "res://Scripts/Controller.gdc"
	_assert(H.write_bytes(odd_path, _encode(V101, odd)), "planted the odd probe")
	var odd_src := str(ml._detokenize_script("res://Scripts/Camera.gd"))
	_assert(not odd_src.is_empty() and not bool(ml._source_has_indented_func_body(odd_src)),
			"the odd probe has no indented body (got: %s)" % H.oneline(odd_src))
	_assert(not bool(ml._canary_detokenizer_roundtrip_ok()), "only an odd probe fails the canary")
	_assert(H.write_bytes(clean_path, _encode(V101, _fixture())), "planted the clean probe")
	_assert(bool(ml._canary_detokenizer_roundtrip_ok()), "a clean probe passes the canary")
	for p in [odd_path, clean_path]:
		DirAccess.remove_absolute(ProjectSettings.globalize_path(p))
	_assert(bool(ml._canary_detokenizer_roundtrip_ok()), "no readable probe is a pass")

# A game update can replace the PCK and leave the executable alone.
func _t11_changed_pck_drops_cache(ml: Object) -> void:
	if not _assert(ml.has_method("_static_game_pck_stamp") and ml.has_method("_game_pck_stamp"),
			"the loader has both PCK stamp functions"):
		return
	_reset_cache(ml)
	var pck := "user://fake_game_build.pck"
	var pck_abs := ProjectSettings.globalize_path(pck)
	_assert(_write_pck(pck, {"res://Scripts/Build.gd": "extends Node\nvar build_one = true\n"}), "wrote the first build")
	ml.set("_game_pck_path_override", pck_abs)
	var first := str(ml._read_vanilla_source("res://Scripts/Build.gd"))
	_assert(first.contains("build_one"), "the first build is read (got: %s)" % H.oneline(first))
	var stamp := str(ml._static_game_pck_stamp(pck_abs))
	_assert(stamp != "" and stamp == str(ml._game_pck_stamp()), "the stamp follows the override (got '%s')" % stamp)
	check_eq(FileAccess.get_file_as_string(CACHE_DIR + "/build").strip_edges(), stamp, "the cache's PCK stamp")
	# A different size moves the stamp even within one mtime second.
	_assert(_write_pck(pck, {"res://Scripts/Build.gd": "extends Node\nvar build_two_is_a_longer_line = true\n"}),
			"wrote the second build over the first")
	_assert(str(ml._static_game_pck_stamp(pck_abs)) != stamp, "the stamp moved with the PCK")
	H.reset_pck_state(ml)
	var second := str(ml._read_vanilla_source("res://Scripts/Build.gd"))
	_assert(second.contains("build_two") and not second.contains("build_one"),
			"a changed PCK drops the cache (got: %s)" % H.oneline(second))
	_assert(str(ml._static_game_pck_stamp("")) == "" and str(ml._static_game_pck_stamp(pck_abs + ".absent")) == "",
			"no PCK reads as the empty stamp")
	ml.set("_game_pck_path_override", "")
	DirAccess.remove_absolute(pck_abs)

# The codegen harness finds coroutines by "await " in wrapper bodies.
func _t12_await_space(ml: Object) -> void:
	var toks := [
		[T_FUNC, 0, 1, 1], [T_IDENTIFIER, 0, 1, 6], [T_PAREN_OPEN, 0, 1, 9], [T_PAREN_CLOSE, 0, 1, 10],
		[T_COLON, 0, 1, 11], [T_NEWLINE, 0, 1, 12],
		[T_AWAIT, 0, 2, 5], [T_PAREN_OPEN, 0, 2, 10], [T_IDENTIFIER, 1, 2, 11], [T_PAREN_CLOSE, 0, 2, 12],
		[T_PERIOD, 0, 2, 13], [T_IDENTIFIER, 2, 2, 14], [T_NEWLINE, 0, 2, 20],
		[T_EOF, 0, 3, 1],
	]
	var src := _detok(ml, V101, toks, "synth_await.gd", ["foo", "x", "done"], [])
	_assert(src.contains("await (x).done"), "await, a space, then the paren (got: %s)" % H.oneline(src))
	_assert(not src.contains("await("), "no 'await(' in the output")

# c_escape() writes "\?", which the GDScript tokenizer rejects.
func _t13_string_escapes(ml: Object) -> void:
	var toks := []
	for i in 3:
		toks.append_array([[T_VAR, 0, i + 1, 1], [T_IDENTIFIER, i, i + 1, 5], [T_ASSIGN, 0, i + 1, 7],
				[T_LITERAL, i, i + 1, 9], [T_NEWLINE, 0, i + 1, 20]])
	toks.append([T_EOF, 0, 4, 1])
	var src := _detok(ml, V101, toks, "synth_escape.gd", ["q", "w", "e"], ["Quit?", "a\"b\\c", "line\nnext\ttab"])
	_assert(src.contains('"Quit?"'), "a question mark is not escaped (got: %s)" % H.oneline(src))
	_assert(not src.contains("\\?"), "no backslash-question in the output")
	_assert(src.contains('"a\\"b\\\\c"'), "quotes and backslashes are escaped (got: %s)" % H.oneline(src))
	_assert(src.contains('"line\\nnext\\ttab"'), "newline and tab are escaped (got: %s)" % H.oneline(src))
	var g := GDScript.new()
	g.source_code = src
	if _assert(g.reload() == OK, "the output compiles (got: %s)" % H.oneline(src)):
		var inst: Variant = g.new()
		_assert(str(inst.get("q")) == "Quit?" and str(inst.get("w")) == "a\"b\\c" and str(inst.get("e")) == "line\nnext\ttab",
				"the compiled constants round-trip")

# Every res://Scripts/ script once as .gd, zero-byte .gd entries in the side
# channel, and a disk index that restores both without a parse.
func _t14_script_enumeration(ml: Object) -> void:
	_reset_cache(ml)
	_reset_enumeration(ml)
	ml.set("_game_pck_path_override", "")
	_assert((ml._enumerate_game_scripts() as Array).is_empty(), "with no game PCK the list is empty")
	var pck := "user://fake_game_scripts.pck"
	var pck_abs := ProjectSettings.globalize_path(pck)
	_assert(_write_pck(pck, {
		"res://Scripts/Foo.gdc": "GDSC-not-decoded-here",
		"res://Scripts/Foo.gd.remap": "[remap]\npath=\"res://Scripts/Foo.gdc\"\n",
		"res://Scripts/Bar.gd": "extends Node\n",
		"res://Scripts/Empty.gd": "",
		"res://Other/Thing.gd": "extends Node\n",
	}), "wrote a synthetic game pack")
	ml.set("_game_pck_path_override", pck_abs)
	_reset_cache(ml)
	_reset_enumeration(ml)
	check_eq((ml._enumerate_game_scripts() as Array).duplicate(),
			["res://Scripts/Foo.gd", "res://Scripts/Bar.gd", "res://Scripts/Empty.gd"], "the enumerated scripts")
	var zero: Dictionary = ml.get("_pck_zero_byte_paths")
	_assert(zero.has("res://Scripts/Empty.gd") and not zero.has("res://Scripts/Bar.gd"),
			"the zero-byte entry is recorded (got %s)" % str(zero.keys()))
	var index := FileAccess.get_file_as_string(SCRIPT_INDEX)
	_assert(index.begins_with(str(ml._script_index_stamp()) + "\n") and index.contains("\n!res://Scripts/Empty.gd"),
			"the index has the stamp and side channel (got: %s)" % H.oneline(index))
	# A hand-trimmed index proves the next launch reads it; a line that is not
	# parser-shaped is dropped.
	_assert(H.write_text(SCRIPT_INDEX, str(ml._script_index_stamp())
			+ "\nres://Scripts/Bar.gd\nres://Other/Thing.gd\n!res://Scripts/Empty.gd\n"), "rewrote the disk index")
	(ml.get("_all_game_script_paths") as Array).clear()
	zero.clear()
	check_eq((ml._enumerate_game_scripts() as Array).duplicate(), ["res://Scripts/Bar.gd"], "the list from the index")
	_assert(zero.has("res://Scripts/Empty.gd"), "the index restores the side channel")
	_reset_enumeration(ml)
	ml.set("_game_pck_path_override", "")
	DirAccess.remove_absolute(pck_abs)

# Canary B reads the version from the first probe with the GDSC magic; -1
# when no probe is readable.
func _t15_canary_b_version(ml: Object) -> void:
	var header := func(version: int) -> PackedByteArray:
		var b := "GDSC".to_ascii_buffer()
		b.append_array(H.uint_le(version))
		b.append_array(H.uint_le(0))
		return b
	var camera := "res://Scripts/Camera.gdc"
	var controller := "res://Scripts/Controller.gdc"
	check_eq(int(ml._probe_gdsc_version()), -1, "no readable probe")
	for v in [100, 101, 102]:
		_assert(H.write_bytes(camera, header.call(v)), "planted a v%d probe header" % v)
		check_eq(int(ml._probe_gdsc_version()), v, "a v%d header" % v)
	_assert(H.write_bytes(camera, "NOPE-not-bytecode".to_ascii_buffer()), "planted a probe without the magic")
	check_eq(int(ml._probe_gdsc_version()), -1, "a probe without the magic")
	_assert(H.write_bytes(controller, header.call(101)), "planted a second probe")
	check_eq(int(ml._probe_gdsc_version()), 101, "the next probe after no magic")
	_assert(H.write_bytes(camera, "GDSC".to_ascii_buffer()), "planted a truncated probe")
	check_eq(int(ml._probe_gdsc_version()), 101, "a probe shorter than the header")
	for p in [camera, controller]:
		DirAccess.remove_absolute(ProjectSettings.globalize_path(p))

# Every keyword wants a space after it, the operator-like ones one before.
func _t16_keyword_spacing(ml: Object) -> void:
	var toks: Array = []
	var want := ""
	var line := 1
	for i in KEYWORDS.size():
		toks.append_array([[40 + i, 0, line, 1], [T_IDENTIFIER, 0, line, 20], [T_NEWLINE, 0, line, 30]])
		want += "%s foo\n" % KEYWORDS[i]
		line += 1
	# foo if int else foo, then foo is int / foo as int / foo in int
	toks.append_array([[T_IDENTIFIER, 0, line, 1], [40, 0, line, 5], [T_IDENTIFIER, 1, line, 8],
			[42, 0, line, 12], [T_IDENTIFIER, 0, line, 17], [T_NEWLINE, 0, line, 20]])
	want += "foo if int else foo\n"
	line += 1
	for kw in [62, 51, 61]:
		toks.append_array([[T_IDENTIFIER, 0, line, 1], [kw, 0, line, 5], [T_IDENTIFIER, 1, line, 8],
				[T_NEWLINE, 0, line, 12]])
		want += "foo %s int\n" % KEYWORDS[kw - 40]
		line += 1
	toks.append([T_EOF, 0, line, 1])
	check_eq(_detok(ml, V101, toks, "synth_keywords.gd"), want, "keyword spacing")

# The enumeration (_parse_pck_file_list, which logs why) and the offset index
# (silent, one empty-table line) read one table; a path_len of 0 ends it.
func _t17_pck_readers_agree(ml: Object) -> void:
	var files := {
		"res://Scripts/One.gd": "extends Node\nvar one = 1\n",
		"res://Scripts/Empty.gd": "",
		"res://Scenes/Room.tscn": "[gd_scene format=3]\n",
	}
	var pck := "user://t17.pck"
	var pck_abs := ProjectSettings.globalize_path(pck)
	var lines: Array = ml.get("_report_lines")
	var zero: Dictionary = ml.get("_pck_zero_byte_paths")
	var pck_index := func(path: String) -> Dictionary:
		_reset_cache(ml)
		ml.set("_game_pck_path_override", path)
		ml._ensure_game_pck_index()
		return (ml.get("_game_pck_index") as Dictionary).duplicate()
	for version in [2, 3]:
		begin("T17 v%d" % version)
		_assert(_write_pck(pck, files, {"version": version}), "wrote the pack")
		zero.clear()
		check_eq(Array(ml._parse_pck_file_list(pck_abs)), files.keys(), "the enumerated entries")
		_assert(zero.has("res://Scripts/Empty.gd") and zero.size() == 1, "the zero-byte entry (got %s)" % str(zero.keys()))
		zero.clear()
		var index: Dictionary = pck_index.call(pck_abs)
		check_eq(index.keys(), ["Scripts/One.gd", "Scripts/Empty.gd", "Scenes/Room.tscn"], "the offset index entries")
		_assert(zero.is_empty(), "the offset index records no zero-byte entry")
		for rel in index:
			var want: PackedByteArray = str(files["res://" + rel]).to_utf8_buffer()
			check_eq(int(index[rel]["size"]), want.size(), "%s size" % rel)
			var f := FileAccess.open(pck_abs, FileAccess.READ)
			f.seek(int(index[rel]["offset"]))
			var got := f.get_buffer(int(index[rel]["size"]))
			f.close()
			_assert(got == want, "%s's offset is absolute (read '%s')" % [rel, got.get_string_from_utf8()])

	for r in [
		[{"flags": 1}, "directory encrypted -- can't enumerate"],
		[{"version": 4}, "pack format v4, exported with Godot 4.6"],
		[{"version": 1}, "unsupported format version 1"],
		[{"magic": 0x12345678}, "not a standalone PCK (magic=0x12345678)"],
	]:
		begin("T17 %s" % str(r[0]))
		_assert(_write_pck(pck, files, r[0]), "wrote the pack")
		lines.clear()
		zero.clear()
		_assert((ml._parse_pck_file_list(pck_abs) as PackedStringArray).is_empty(), "the enumeration lists nothing")
		_assert("\n".join(lines).contains("[PCK] %s: %s" % [pck_abs, r[1]]), "the enumeration says why (got %s)" % str(lines))
		_assert(zero.is_empty(), "nothing is recorded as zero-byte")
		lines.clear()
		_assert((pck_index.call(pck_abs) as Dictionary).is_empty(), "the offset index is empty")
		var said := "\n".join(lines)
		_assert(said.contains("has no readable file table") and not said.contains("[PCK]"),
				"the index says so once, its own way (got %s)" % str(lines))

	begin("T17")
	_assert(_write_pck(pck, files, {"bad_path_at": 1}), "wrote a pack with a bad path_len")
	lines.clear()
	zero.clear()
	check_eq(Array(ml._parse_pck_file_list(pck_abs)), ["res://Scripts/One.gd"], "entries before a 0 path_len")
	_assert("\n".join(lines).contains("[PCK] %s: suspicious path_len=0 at entry 1 -- abort" % pck_abs),
			"the enumeration names the bad entry (got %s)" % str(lines))
	check_eq((pck_index.call(pck_abs) as Dictionary).keys(), ["Scripts/One.gd"], "offset index before a 0 path_len")
	lines.clear()
	_assert((ml._parse_pck_file_list(pck_abs + ".absent") as PackedStringArray).is_empty()
			and "\n".join(lines).contains("[PCK] cannot open: %s.absent" % pck_abs),
			"a missing file lists nothing, says so (got %s)" % str(lines))
	_assert((pck_index.call(pck_abs + ".absent") as Dictionary).is_empty(), "a missing file indexes nothing")
	lines.clear()
	zero.clear()
	_reset_cache(ml)
	ml.set("_game_pck_path_override", "")
	DirAccess.remove_absolute(pck_abs)

func _reset_cache(ml: Object) -> void:
	H.reset_pck_state(ml)
	if DirAccess.dir_exists_absolute(ProjectSettings.globalize_path(CACHE_DIR)):
		ml._remove_tree(ProjectSettings.globalize_path(CACHE_DIR), false)

func _reset_enumeration(ml: Object) -> void:
	(ml.get("_all_game_script_paths") as Array).clear()
	(ml.get("_pck_zero_byte_paths") as Dictionary).clear()
	DirAccess.remove_absolute(ProjectSettings.globalize_path(SCRIPT_INDEX))

# A format-2 (or 3) .pck of plain-text files. opts: "magic", "version" (3
# adds the directory offset and padding), "flags" (1 = encrypted directory),
# "bad_path_at" (that entry gets path_len 0).
func _write_pck(path: String, files: Dictionary, opts := {}) -> bool:
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return false
	var version := int(opts.get("version", 2))
	f.store_32(int(opts.get("magic", 0x43504447)))
	f.store_32(version)
	f.store_32(4)
	f.store_32(6)
	f.store_32(0)
	f.store_32(int(opts.get("flags", 0)))
	var file_base_pos := f.get_position()
	f.store_64(0)
	if version == 3:
		f.store_64(f.get_position() + 8 + 12)
		f.store_buffer(PackedByteArray([7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7]))
	else:
		for i in 16:
			f.store_32(0)
	f.store_32(files.size())
	var bad_at := int(opts.get("bad_path_at", -1))
	var offset := 0
	var i := 0
	for p in files:
		var pb: PackedByteArray = str(p).to_utf8_buffer()
		var size: int = str(files[p]).to_utf8_buffer().size()
		f.store_32(0 if i == bad_at else pb.size())
		f.store_buffer(pb)
		f.store_64(offset)
		f.store_64(size)
		f.store_buffer(PackedByteArray([0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]))
		f.store_32(0)
		offset += size
		i += 1
	var file_base := f.get_position()
	for p in files:
		f.store_buffer(str(files[p]).to_utf8_buffer())
	f.seek(file_base_pos)
	f.store_64(file_base)
	f.close()
	return true

# v100 predates "..." at 83: everything from 83 up sits one lower.
func _to_v100(toks: Array) -> Array:
	var out: Array = []
	for t in toks:
		if t[0] != T_PERIOD_PERIOD_PERIOD:
			out.append([t[0] - 1 if t[0] >= SHIFT_FROM else t[0], t[1], t[2], t[3]])
	return out

func _detok(ml: Object, version: int, toks: Array, fname: String, idents := IDENTS, consts := CONSTS) -> String:
	var path := "res://" + fname
	if not H.write_bytes(path, _encode(version, toks, idents, consts)):
		_fail("could not write fixture " + path)
		return ""
	return str(ml._detokenize_script(path))

func _encode(version: int, toks: Array, idents := IDENTS, consts := CONSTS) -> PackedByteArray:
	var body := PackedByteArray()
	# ident, const, line and token counts; v100 pads 4 bytes before the token count.
	body.append_array(H.uint_le(idents.size()))
	body.append_array(H.uint_le(consts.size()))
	body.append_array(H.uint_le(toks.size()))
	if version == V100:
		body.append_array(H.uint_le(0))
	body.append_array(H.uint_le(toks.size()))
	# Identifiers: a length, then UTF-32 code points XOR 0xb6.
	for s in idents:
		body.append_array(H.uint_le(str(s).length()))
		for i in str(s).length():
			for b in H.uint_le(str(s).unicode_at(i)):
				body.append(b ^ 0xb6)
	for c in consts:
		body.append_array(var_to_bytes(c))
	# Line map, then column map, as (token index, value) pairs.
	for col in [2, 3]:
		for i in toks.size():
			body.append_array(H.uint_le(i))
			body.append_array(H.uint_le(toks[i][col]))
	# Bit 7 of the low byte selects the wide form, which carries the data index.
	for t in toks:
		if t[1] > 0:
			body.append_array(H.uint_le(t[0] | 0x80 | (t[1] << 8)))
			body.append_array(H.uint_le(0))
		else:
			body.append_array(H.uint_le(t[0]))
			body.append(0)
	# Header: magic, version, decompressed size (0 = stored uncompressed).
	var out := "GDSC".to_ascii_buffer()
	out.append_array(H.uint_le(version))
	out.append_array(H.uint_le(0))
	out.append_array(body)
	return out
