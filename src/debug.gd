## ----- debug.gd -----
## Test scaffolding gated behind the test_pack_precedence flag in
## mod_config.cfg. Exercises the pack-over-bytecode precedence trick and
## verifies what took over which vanilla paths after autoloads run.
## Removable once the rewrite system is proven stable in production.

func _test_post_autoload_verify() -> void:
	const TAG := "[TEST-REMAP-POST]"
	_log_info(TAG + " === DEFERRED VERIFY: 1s after all autoloads ===")
	var s := load("res://Scripts/Controller.gd") as GDScript
	if s == null:
		_log_critical(TAG + " load() returned null")
		return
	var sc: String = s.source_code
	var methods := s.get_script_method_list()
	var names: Array = []
	for m in methods:
		names.append(m["name"])
	_log_info(TAG + "   Scripts/Controller.gd:")
	_log_info(TAG + "     source_code length: " + str(sc.length()))
	_log_info(TAG + "     has vanilla-side marker: " + str("_rtv_test_remap_marker" in sc))
	_log_info(TAG + "     has IXP-side marker: " + str("TEST-HOOK-IXP" in sc))
	_log_info(TAG + "     _rtv_vanilla_Movement in methods: " + str("_rtv_vanilla_Movement" in names))
	_log_info(TAG + "     Movement in methods: " + str("Movement" in names))
	_log_info(TAG + "     method count: " + str(names.size()))
	_log_info(TAG + "     global_name: '" + str(s.get_global_name()) + "'")
	_log_info(TAG + "     script instance_id: " + str(s.get_instance_id()))

	# Verified 2026-04-17: explicit load(IXP_PATH, REUSE/IGNORE) triggers
	# #83542 after IXP's take_over_path (cache cold -> fresh compile ->
	# find_class("Controller") fails against the IXP overlay at vanilla path).
	# FileAccess-only ground truth avoids the forced recompile.
	const IXP_PATH := "res://ImmersiveXP/Controller.gd"
	if FileAccess.file_exists(IXP_PATH):
		var bytes := FileAccess.get_file_as_bytes(IXP_PATH)
		var txt := bytes.get_string_from_utf8()
		_log_info(TAG + "   FileAccess IXP/Controller.gd: " + str(bytes.size()) + " bytes, has marker: " + str("TEST-HOOK-IXP" in txt))

# =============================================================================
# TEMPORARY: Pack-over-bytecode precedence test. Gated behind a setting flag
# in mod_config.cfg. Remove after verifying whether mounting .gd + .gd.remap
# beats the PCK's .gdc + .gd.remap for a specific resource path.
# =============================================================================

func _load_test_pack_flag() -> bool:
	var cfg := ConfigFile.new()
	if cfg.load(UI_CONFIG_PATH) != OK:
		return false
	return bool(cfg.get_value("settings", "test_pack_precedence", false))

func _test_pack_precedence() -> void:
	const TAG := "[TEST-REMAP]"
	const TARGET_PATH := "res://Scripts/Controller.gd"
	const REMAP_PATH := "res://Scripts/Controller.gd.remap"
	const GDC_PATH := "res://Scripts/Controller.gdc"
	const MARKER_SYMBOL := "_rtv_test_remap_marker"
	const TEST_ZIP := "user://test_pack_precedence.zip"
	_log_info(TAG + " starting pack-over-bytecode test for " + TARGET_PATH)

	# --- PRE-MOUNT DIAGNOSTICS ---
	_log_info(TAG + " === PRE-MOUNT VFS state ===")
	_log_info(TAG + "   FileAccess.file_exists(.gd):       " + str(FileAccess.file_exists(TARGET_PATH)))
	_log_info(TAG + "   FileAccess.file_exists(.gdc):      " + str(FileAccess.file_exists(GDC_PATH)))
	_log_info(TAG + "   FileAccess.file_exists(.gd.remap): " + str(FileAccess.file_exists(REMAP_PATH)))
	_log_info(TAG + "   ResourceLoader.exists(.gd):   " + str(ResourceLoader.exists(TARGET_PATH)))
	_log_info(TAG + "   ResourceLoader.exists(.gdc):  " + str(ResourceLoader.exists(GDC_PATH)))
	if FileAccess.file_exists(REMAP_PATH):
		var pre_remap := FileAccess.get_file_as_string(REMAP_PATH)
		_log_info(TAG + "   PCK's .remap content: " + pre_remap.replace("\n", "|"))

	# --- BUILD TEST PACK ---
	# IMPORTANT: do NOT call load(TARGET_PATH) here -- that would cache the
	# bytecode version and prevent our mounted .gd from winning on subsequent
	# loads. Go straight to detokenize, and explicitly target the .gdc path so
	# a stale test pack mounted at static init can't pollute the input with
	# its own rewritten .gd (duplicate-function parse error -> game breaks).
	var vanilla_source := _detokenize_script(GDC_PATH)
	if vanilla_source.is_empty():
		_log_critical(TAG + " FAIL: could not detokenize vanilla source")
		return

	# Capture PRISTINE IXP/Controller.gd source via ZIPReader directly against
	# the .vmz -- bypasses the VFS entirely, so we're immune to either
	#   (a) destructive ops on a previously-mounted test pack leaving stale
	#       mount entries pointing at a deleted file (old crash path), or
	#   (b) reading an already-rewritten version from a prior session's pack
	#       that got mounted at static init (double-rewrite duplicate funcs).
	var mods_dir := OS.get_executable_path().get_base_dir().path_join(MOD_DIR)
	var ixp_vmz_path := mods_dir.path_join("ImmersiveXP.vmz")
	var captured_ixp_source := ""
	if FileAccess.file_exists(ixp_vmz_path):
		var ixp_zr := ZIPReader.new()
		if ixp_zr.open(ixp_vmz_path) == OK:
			var ixp_bytes := ixp_zr.read_file("ImmersiveXP/Controller.gd")
			ixp_zr.close()
			captured_ixp_source = ixp_bytes.get_string_from_utf8()
			if captured_ixp_source.is_empty():
				_log_warning(TAG + " IXP source read from vmz returned empty")
			else:
				_log_info(TAG + " Captured pristine IXP source from vmz: " \
						+ str(captured_ixp_source.length()) + " bytes")
		else:
			_log_warning(TAG + " ZIPReader.open failed on " + ixp_vmz_path)
	else:
		_log_info(TAG + " ImmersiveXP.vmz not present, TEST 4B will skip")

	# Step A (2026-04-17): feed the pristine vanilla through the production
	# generator _rtv_rewrite_vanilla_source(). It renames EVERY non-static
	# method to _rtv_vanilla_<name> and appends full dispatch wrappers at the
	# original names. This proves the generator produces runtime-correct
	# output for all methods (not just Movement like the prior inline
	# rewrite did).
	var parsed := _rtv_parse_script(TARGET_PATH.get_file(), vanilla_source)
	var hookable_count := 0
	for fe in parsed["functions"]:
		if not fe["is_static"]:
			hookable_count += 1
	_log_info(TAG + " Step A: parsed %d function(s), %d hookable (non-static)" \
			% [(parsed["functions"] as Array).size(), hookable_count])

	var rewritten := _rtv_rewrite_vanilla_source(vanilla_source, parsed)

	# Append the test-remap marker (non-hookable callable) so we can verify the
	# compiled class is usable via script.new() + call(marker) below.
	var marker_block: String = "\n# rtv test-remap marker\nfunc " + MARKER_SYMBOL \
			+ "() -> String:\n\treturn \"test-remap-ok\"\n"
	rewritten += marker_block

	_log_info(TAG + " rewritten source length: " + str(rewritten.length()) + " chars (+" \
			+ str(rewritten.length() - vanilla_source.length()) + ")")

	# Which variant to test. Toggle by editing the next few lines:
	var variant := "A"  # "A"=.gd + self-ref remap, "B"=.gd only, "C"=empty remap, "D"=.gd + .gdc-remap
	_log_info(TAG + " VARIANT: " + variant)

	var test_zip_abs := ProjectSettings.globalize_path(TEST_ZIP)
	if FileAccess.file_exists(test_zip_abs):
		DirAccess.remove_absolute(test_zip_abs)
	var zp := ZIPPacker.new()
	if zp.open(test_zip_abs) != OK:
		_log_critical(TAG + " FAIL: cannot open test zip")
		return
	zp.start_file("Scripts/Controller.gd")
	zp.write_file(rewritten.to_utf8_buffer())
	zp.close_file()
	match variant:
		"A":  # .gd + self-referencing .remap (redirect-the-redirect)
			zp.start_file("Scripts/Controller.gd.remap")
			zp.write_file("[remap]\npath=\"res://Scripts/Controller.gd\"\n".to_utf8_buffer())
			zp.close_file()
		"B":  # .gd only, no .remap override
			pass
		"C":  # .gd + empty .remap (no path key)
			zp.start_file("Scripts/Controller.gd.remap")
			zp.write_file("[remap]\n".to_utf8_buffer())
			zp.close_file()
		"D":  # .gd + .remap pointing at same .gdc as before (no-op override)
			zp.start_file("Scripts/Controller.gd.remap")
			zp.write_file("[remap]\npath=\"res://Scripts/Controller.gdc\"\n".to_utf8_buffer())
			zp.close_file()

	# === TEST 4B: also pre-wrap ImmersiveXP's Controller.gd ===
	# When ImmersiveXP's autoload does load("res://ImmersiveXP/Controller.gd")
	# .take_over_path(vanilla_path), it'll load our pre-wrapped version and
	# move THAT to the vanilla path. Hooks fire through the mod's chain.
	# Uses captured_ixp_source captured at top of function -- reading IXP_PATH
	# HERE fails after we delete the old test pack zip above (VFS has stale
	# mount entries pointing at the deleted file).
	const IXP_PATH := "res://ImmersiveXP/Controller.gd"
	if not captured_ixp_source.is_empty():
		var ixp_source := captured_ixp_source
		if not ixp_source.is_empty():
			_log_info(TAG + " IXP Controller source length: " + str(ixp_source.length()))
			var ixp_lines: PackedStringArray = ixp_source.split("\n")
			var ixp_renamed := false
			for i in ixp_lines.size():
				var line_str := str(ixp_lines[i])
				if line_str.strip_edges().begins_with("func Movement("):
					ixp_lines[i] = line_str.replace("func Movement(", "func _rtv_vanilla_Movement(")
					ixp_renamed = true
					break
			var ixp_new_lines: Array = []
			for line in ixp_lines:
				ixp_new_lines.append(line)
			if ixp_renamed:
				# Detect indentation style: if source uses spaces, our appended
				# wrapper must too (GDScript errors on mixed tabs/spaces).
				var uses_spaces := false
				for line in ixp_lines:
					var line_str2 := str(line)
					if line_str2.begins_with("    ") and not line_str2.begins_with("\t"):
						uses_spaces = true
						break
					if line_str2.begins_with("\t"):
						break
				var ind := "    " if uses_spaces else "\t"
				_log_info(TAG + " IXP indent style: " + ("spaces" if uses_spaces else "tabs"))
				ixp_new_lines.append("")
				ixp_new_lines.append("func Movement(delta):")
				ixp_new_lines.append(ind + "if Engine.get_frames_drawn() % 60 == 0:")
				ixp_new_lines.append(ind + ind + 'print("[TEST-HOOK-IXP] Movement called (frame %d)" % Engine.get_frames_drawn())')
				ixp_new_lines.append(ind + "_rtv_vanilla_Movement(delta)")
				ixp_new_lines.append("")
				var ixp_rewritten := "\n".join(ixp_new_lines)
				zp.start_file("ImmersiveXP/Controller.gd")
				zp.write_file(ixp_rewritten.to_utf8_buffer())
				zp.close_file()
				# Also ship .gd.remap pointing back at .gd in case ImmersiveXP
				# shipped a remap (mod archives from Godot export often do).
				zp.start_file("ImmersiveXP/Controller.gd.remap")
				zp.write_file("[remap]\npath=\"res://ImmersiveXP/Controller.gd\"\n".to_utf8_buffer())
				zp.close_file()
				_log_info(TAG + " TEST 4B: wrote pre-wrapped ImmersiveXP/Controller.gd (" \
						+ str(ixp_rewritten.length()) + " chars)")
			else:
				_log_warning(TAG + " TEST 4B: Movement not found in IXP source, skipped")
		else:
			_log_info(TAG + " TEST 4B: IXP Controller source empty, skipped")
	else:
		_log_info(TAG + " TEST 4B: IXP Controller not in VFS (ImmersiveXP disabled?)")

	zp.close()
	_log_info(TAG + " wrote test pack")

	# --- MOUNT ---
	if not ProjectSettings.load_resource_pack(TEST_ZIP, true):
		_log_critical(TAG + " FAIL: load_resource_pack returned false")
		return
	_log_info(TAG + " mounted test pack OK (replace_files=true)")

	# --- POST-MOUNT DIAGNOSTICS ---
	_log_info(TAG + " === POST-MOUNT VFS state ===")
	_log_info(TAG + "   FileAccess.file_exists(.gd):       " + str(FileAccess.file_exists(TARGET_PATH)))
	_log_info(TAG + "   FileAccess.file_exists(.gdc):      " + str(FileAccess.file_exists(GDC_PATH)))
	_log_info(TAG + "   FileAccess.file_exists(.gd.remap): " + str(FileAccess.file_exists(REMAP_PATH)))
	if FileAccess.file_exists(REMAP_PATH):
		var post_remap := FileAccess.get_file_as_string(REMAP_PATH)
		_log_info(TAG + "   .remap content post-mount: " + post_remap.replace("\n", "|"))
	if FileAccess.file_exists(TARGET_PATH):
		var gd_bytes := FileAccess.get_file_as_bytes(TARGET_PATH)
		_log_info(TAG + "   .gd bytes readable: " + str(gd_bytes.size()) + " bytes")
		if gd_bytes.size() > 0:
			var first_80 := gd_bytes.slice(0, 80).get_string_from_utf8()
			_log_info(TAG + "   .gd first 80 bytes: " + first_80.replace("\n", "|"))
	# Also verify IXP path post-mount
	const IXP_PATH_CHECK := "res://ImmersiveXP/Controller.gd"
	if FileAccess.file_exists(IXP_PATH_CHECK):
		var ixp_bytes := FileAccess.get_file_as_bytes(IXP_PATH_CHECK)
		var ixp_content := ixp_bytes.get_string_from_utf8()
		var has_our_hook := "TEST-HOOK-IXP" in ixp_content
		_log_info(TAG + "   IXP/Controller.gd bytes: " + str(ixp_bytes.size()) + " has our marker: " + str(has_our_hook))
		if not has_our_hook and ixp_content.length() > 0:
			_log_info(TAG + "   IXP/Controller.gd first 80: " + ixp_content.substr(0, 80).replace("\n", "|"))

	# --- LOAD TESTS ---
	_log_info(TAG + " === LOAD ATTEMPTS (cache should be cold -- we never pre-loaded) ===")

	# Attempt 1: default load(), same as any game code. If this has our marker,
	# production scripts will get our version too.
	var post := load(TARGET_PATH) as GDScript
	if post:
		var post_source: String = post.source_code
		_log_info(TAG + "   load(.gd) [default=REUSE]: source_code length=" + str(post_source.length()) \
				+ " has_marker=" + str(MARKER_SYMBOL in post_source))
	else:
		_log_critical(TAG + "   load(.gd) [default=REUSE]: returned null")

	# Attempt 2: load again -- confirm cache is stable (returns same instance)
	var post2 := load(TARGET_PATH) as GDScript
	if post and post2:
		_log_info(TAG + "   load(.gd) [2nd]: same_instance=" + str(post == post2) \
				+ " same_source_length=" + str(post.source_code.length() == post2.source_code.length()))

	# Attempt 3: ResourceLoader.CACHE_MODE_IGNORE (fresh VFS fetch, bypass cache)
	var post_ignore := ResourceLoader.load(TARGET_PATH, "", ResourceLoader.CACHE_MODE_IGNORE) as GDScript
	if post_ignore:
		var ignore_source: String = post_ignore.source_code
		_log_info(TAG + "   load(.gd, IGNORE): source_code length=" + str(ignore_source.length()) \
				+ " has_marker=" + str(MARKER_SYMBOL in ignore_source))

	# Attempt 4: deeper diagnostics on the compiled script
	var marker_in_method_list := false
	if post:
		_log_info(TAG + "   global_name: " + str(post.get_global_name()))
		_log_info(TAG + "   instance_base_type: " + post.get_instance_base_type())
		var methods := post.get_script_method_list()
		var method_names: Array = []
		for m in methods:
			method_names.append(m["name"])
		marker_in_method_list = MARKER_SYMBOL in method_names
		_log_info(TAG + "   method list count: " + str(method_names.size()) \
				+ "  marker_in_list: " + str(marker_in_method_list))

	# Attempt 5: DEFINITIVE test -- instantiate the script and call the marker method
	var instantiate_ok := false
	var call_returned: Variant = null
	var call_err := ""
	if post and marker_in_method_list:
		# Script.new() for Node-derived scripts creates a new instance; must free() it.
		# Wrap in a safety check -- CharacterBody3D init may fail without scene context.
		var inst = null
		var new_ok := false
		inst = post.new() if post.can_instantiate() else null
		new_ok = inst != null
		_log_info(TAG + "   script.new() returned non-null: " + str(new_ok))
		if new_ok:
			instantiate_ok = true
			if inst.has_method(MARKER_SYMBOL):
				call_returned = inst.call(MARKER_SYMBOL)
				_log_info(TAG + "   instance.call(marker): returned " + str(call_returned))
			else:
				call_err = "instance lacks marker method despite class having it"
				_log_info(TAG + "   " + call_err)
			# Clean up -- don't leak Node instances
			if inst is Node:
				(inst as Node).queue_free()
			else:
				inst = null

	# Check Movement method rewrite landed in compiled class
	var vanilla_movement_in_list := false
	var wrapper_movement_in_list := false
	if post:
		var methods2 := post.get_script_method_list()
		for m in methods2:
			if m["name"] == "_rtv_vanilla_Movement":
				vanilla_movement_in_list = true
			elif m["name"] == "Movement":
				wrapper_movement_in_list = true
		_log_info(TAG + "   _rtv_vanilla_Movement in method list: " + str(vanilla_movement_in_list))
		_log_info(TAG + "   Movement (wrapper) in method list: " + str(wrapper_movement_in_list))

	# Final verdict
	var final_sc := (post.source_code if post else "") as String
	if marker_in_method_list and call_returned == "test-remap-ok":
		_log_info(TAG + " ====== CONFIRMED SUCCESS: rewrite compiled AND callable ======")
		if vanilla_movement_in_list and wrapper_movement_in_list:
			_log_info(TAG + " Step A: Movement rename + dispatch wrapper both compiled OK")
			_log_info(TAG + " (wrapper prints nothing by itself; [TEST-HOOK-IXP] from IXP-side wrapper is the in-game signal)")
		else:
			_log_warning(TAG + " Step A: Movement intercept NOT compiled (vanilla_in=%s, wrapper_in=%s)" \
					% [vanilla_movement_in_list, wrapper_movement_in_list])
	elif marker_in_method_list:
		_log_info(TAG + " ====== LIKELY SUCCESS: compiled script has marker method ======")
		_log_info(TAG + " (couldn't instantiate to call -- instantiate_ok=" + str(instantiate_ok) \
				+ " err='" + call_err + "')")
	elif MARKER_SYMBOL in final_sc:
		_log_critical(TAG + " ====== SOURCE-ONLY: text has marker but compiled class does not ======")
	elif final_sc.is_empty():
		_log_critical(TAG + " ====== FAIL: got bytecode, source empty ======")
	else:
		_log_critical(TAG + " ====== UNKNOWN: got source but no marker ======")
