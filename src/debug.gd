## ----- debug.gd -----
## Developer-mode probes (_dev_preactivate_summary and _dev_hook_probes, run
## by hook_pack.gd only when developer mode is on) and the test-pack
## scaffolding gated behind the test_pack_precedence flag in mod_config.cfg,
## which exercises the pack-over-bytecode precedence trick and verifies what
## took over which vanilla paths after autoloads run.

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

	# Explicit load(IXP_PATH, REUSE/IGNORE) triggers #83542 after IXP's
	# take_over_path (cold cache -> fresh compile -> find_class("Controller")
	# fails). FileAccess-only ground truth avoids the forced recompile.
	const IXP_PATH := "res://ImmersiveXP/Controller.gd"
	if FileAccess.file_exists(IXP_PATH):
		var bytes := FileAccess.get_file_as_bytes(IXP_PATH)
		var txt := bytes.get_string_from_utf8()
		_log_info(TAG + "   FileAccess IXP/Controller.gd: " + str(bytes.size()) + " bytes, has marker: " + str("TEST-HOOK-IXP" in txt))

# Developer-mode classification of the rewritten scripts before activation:
# rewrite live from static init, source matches but methods do not, empty
# source (bytecode), or other. Called from _activate_rewritten_scripts.
func _dev_preactivate_summary(res_paths: Array[String]) -> void:
	var pre_a := 0
	var pre_b := 0
	var pre_c := 0
	var pre_d := 0
	var pre_b_names: PackedStringArray = []
	var pre_c_names: PackedStringArray = []
	for res_path: String in res_paths:
		if _scripts_with_scene_preloads.has(res_path):
			continue
		var c := load(res_path) as GDScript
		if c == null:
			pre_d += 1
			continue
		var pre_rename := false
		for m in c.get_script_method_list():
			if str(m["name"]).begins_with("_rtv_vanilla_"):
				pre_rename = true
				break
		var srclen: int = c.source_code.length()
		if pre_rename:
			pre_a += 1
		elif srclen > 0:
			pre_b += 1
			pre_b_names.append(res_path)
		else:
			pre_c += 1
			pre_c_names.append(res_path)
	_log_debug("[RTVCodegen] PRE-ACTIVATE summary: inline-live=%d, pinned-with-source=%d, pinned-tokenized=%d, other=%d / total=%d" \
			% [pre_a, pre_b, pre_c, pre_d, res_paths.size()])
	if pre_b > 0:
		_log_debug("[RTVCodegen]   pinned-with-source (GDScriptCache has our text but compiled methods are vanilla): %s" \
				% ", ".join(Array(pre_b_names).slice(0, 25)))
	if pre_c > 0:
		_log_debug("[RTVCodegen]   pinned-tokenized (PCK .gdc, our static-init preload missed): %s" \
				% ", ".join(Array(pre_c_names).slice(0, 25)))

# Developer-mode end-to-end probes, called once from _activate_rewritten_scripts:
# real hooks on known methods across menu tick, menu click and gameplay, the
# autoload inspection, the registry smoke probe and the 30-second report
# timer. The first set fires and the last does not: timing. None fire but
# the dispatch counter is high: the _hooks lookup is broken.
func _dev_hook_probes() -> void:
	var probe_counts := {
		"loader_pp": 0, "simulation_proc": 0, "profiler_proc": 0,
		"menu_ready": 0, "settings_load": 0,
		"controller_pp": 0, "character_pp": 0, "camera_pp": 0,
	}
	Engine.set_meta("_rtv_probe_counts", probe_counts)
	Engine.set_meta("_rtv_probe_first_args", {})
	var _bump := func(key: String, arg):
		var pc: Dictionary = Engine.get_meta("_rtv_probe_counts", {})
		pc[key] = int(pc.get(key, 0)) + 1
		Engine.set_meta("_rtv_probe_counts", pc)
		var fa: Dictionary = Engine.get_meta("_rtv_probe_first_args", {})
		if not fa.has(key):
			fa[key] = str(arg)
			Engine.set_meta("_rtv_probe_first_args", fa)
	hook("loader-_physics_process-pre", func(d): _bump.call("loader_pp", d), 100)
	hook("simulation-_process-pre", func(d): _bump.call("simulation_proc", d), 100)
	hook("profiler-_process-pre", func(d): _bump.call("profiler_proc", d), 100)
	hook("menu-_ready-pre", func(): _bump.call("menu_ready", "(no args)"), 100)
	hook("settings-loadpreferences-pre", func(): _bump.call("settings_load", "(no args)"), 100)
	hook("controller-_physics_process-pre", func(d): _bump.call("controller_pp", d), 100)
	hook("character-_physics_process-pre", func(d): _bump.call("character_pp", d), 100)
	hook("camera-_physics_process-pre", func(d): _bump.call("camera_pp", d), 100)

	# Autoload inspection (dev-only): a live autoload node can still hold the
	# original bytecode via get_script() even when the resource shows the renames.
	var autoload_names: Array[String] = ["Database", "GameData", "Settings",
			"Menu", "Loader", "Inputs", "Mode", "Profiler", "Simulation"]
	var root := get_tree().root
	for aname: String in autoload_names:
		var node: Node = root.get_node_or_null(aname)
		if node == null:
			_log_info("[RTVCodegen] AUTOLOAD-CHECK %s: node NOT in tree" % aname)
			continue
		var scr := node.get_script() as GDScript
		if scr == null:
			_log_info("[RTVCodegen] AUTOLOAD-CHECK %s: no script attached" % aname)
			continue
		var has_rename := false
		for m in scr.get_script_method_list():
			if str(m["name"]).begins_with("_rtv_vanilla_"):
				has_rename = true
				break
		# The node itself should report an _rtv_vanilla_ method.
		var instance_methods_has_rename := false
		for m in node.get_method_list():
			if str(m["name"]).begins_with("_rtv_vanilla_"):
				instance_methods_has_rename = true
				break
		_log_info("[RTVCodegen] AUTOLOAD-CHECK %s: script=%s script_has_rename=%s instance_has_rename=%s" \
				% [aname, scr.resource_path, has_rename, instance_methods_has_rename])

	# Registry smoke probe (dev-only): the Database rewrite and _get() serve scenes at runtime.
	var db_node: Node = get_tree().root.get_node_or_null("Database")
	if db_node == null:
		_log_warning("[RegistryProbe] Database autoload not in tree -- cannot verify const->dict transform")
	elif not ("_rtv_vanilla_scenes" in db_node):
		_log_warning("[RegistryProbe] Database._rtv_vanilla_scenes missing -- const->dict rewrite did not execute; lib.register/override will not see vanilla ids")
	else:
		var vs: Dictionary = db_node._rtv_vanilla_scenes
		var scene_count: int = vs.size()
		if scene_count == 0:
			_log_warning("[RegistryProbe] Database._rtv_vanilla_scenes empty -- regex extracted no entries from Database.gd; check vanilla const syntax")
		else:
			var probe_key: String = vs.keys()[0]
			var probe_result = db_node.get(probe_key)
			if probe_result is PackedScene:
				_log_info("[RegistryProbe] Database: _rtv_vanilla_scenes=%d entries; get('%s') returns PackedScene -- const->dict transform + _get() injection OK" \
						% [scene_count, probe_key])
			else:
				_log_warning("[RegistryProbe] Database: _rtv_vanilla_scenes=%d entries but get('%s') returned %s (not PackedScene) -- _get() injection broken" \
						% [scene_count, probe_key, type_string(typeof(probe_result))])

	# 30s lets the player reach gameplay so controller-level hooks can fire.
	_dispatch_counts.clear()
	get_tree().create_timer(30.0).timeout.connect(func():
		var pc: Dictionary = Engine.get_meta("_rtv_probe_counts", {})
		var fa: Dictionary = Engine.get_meta("_rtv_probe_first_args", {})
		# Top 20 hot methods, no generic threshold (physics-tick methods run hot).
		# Lifecycle methods fire once per node, so counts > 10 flag a mod looping them.
		if _developer_mode and _dispatch_counts.size() > 0:
			var pairs: Array = []
			for k: String in _dispatch_counts:
				pairs.append([k, int(_dispatch_counts[k])])
			pairs.sort_custom(func(a, b): return a[1] > b[1])
			_log_info("[RTVCodegen] DISPATCH-COUNT top %d / %d tracked methods (dev mode, 30s window):" \
					% [min(20, pairs.size()), pairs.size()])
			for i in range(min(20, pairs.size())):
				_log_info("[RTVCodegen]   %-48s %d" % [pairs[i][0], pairs[i][1]])
			var lifecycle_runaway: Array = []
			for p in pairs:
				var name: String = p[0]
				if (name.ends_with("-_ready") or name.ends_with("-_enter_tree") \
						or name.ends_with("-_init")) and int(p[1]) > 10:
					lifecycle_runaway.append("%s=%d" % [name, p[1]])
			if lifecycle_runaway.size() > 0:
				_log_critical("[RTVCodegen] LIFECYCLE-RUNAWAY: %s -- these should fire once per node; elevated counts usually mean a mod is explicitly calling them from a loop or frequent callback, which cascades into connect-already-connected error spam" \
						% ", ".join(lifecycle_runaway))
		var total := 0
		for k: String in ["loader_pp", "simulation_proc", "profiler_proc",
				"menu_ready", "settings_load",
				"controller_pp", "character_pp", "camera_pp"]:
			var v := int(pc.get(k, 0))
			total += v
			_log_info("[RTVCodegen] HOOK-API %s: count=%d first_arg=%s" \
					% [k, v, fa.get(k, "n/a")])
		if total > 0:
			_log_info("[RTVCodegen] HOOK-API-LIVE: %d callback fires total across probes -- full chain verified" % total)
		else:
			_log_critical("[RTVCodegen] HOOK-API-DEAD: 0 callback fires -- dispatch runs but _hooks lookup/callback is broken")
		# IXP takeover check: with take_over_path active the base chain walks IXP -> rewrite -> engine class.
		var check_classes: Array[String] = ["Controller", "Camera", "WeaponRig"]
		for cls_name: String in check_classes:
			var found: Array = []
			_rtv_collect_nodes_by_class(get_tree().root, cls_name, found)
			if found.is_empty():
				_log_info("[IXP-VERIFY] No %s node in tree yet" % cls_name)
				continue
			var node: Node = found[0]
			var scr := node.get_script() as GDScript
			if scr == null:
				_log_info("[IXP-VERIFY] %s: no script attached" % cls_name)
				continue
			var src: String = scr.source_code
			var has_ixp := "ImmersiveXP" in src or "IXP " in src or "overrideScript" in src
			var has_rewrite := "_rtv_vanilla_" in src
			_log_info("[IXP-VERIFY] %s instance script: path=%s src_len=%d ixp_content=%s rewrite_content=%s" \
					% [cls_name, scr.resource_path, src.length(), has_ixp, has_rewrite])
			var base := scr.get_base_script() as GDScript
			var depth := 1
			while base != null and depth < 6:
				var b_src: String = base.source_code
				var b_has_ixp := "ImmersiveXP" in b_src or "IXP " in b_src
				var b_has_rewrite := "_rtv_vanilla_" in b_src
				_log_info("[IXP-VERIFY]   base[%d]: path=%s src_len=%d ixp=%s rewrite=%s" \
						% [depth, base.resource_path, b_src.length(), b_has_ixp, b_has_rewrite])
				base = base.get_base_script() as GDScript
				depth += 1
	)

# Pass 2 only: mount the test pack again after load_all_mods re-mounted the
# archives, from a fresh copy because load_resource_pack dedupes by path.
func _test_pack_reapply() -> void:
	# Sweep prior sessions' reapply copies; nothing else deletes them.
	var user_dir_abs := ProjectSettings.globalize_path("user://")
	var user_dir := DirAccess.open(user_dir_abs)
	if user_dir != null:
		user_dir.list_dir_begin()
		while true:
			var stale_name := user_dir.get_next()
			if stale_name == "":
				break
			if stale_name.begins_with("test_pack_reapply_") and stale_name.ends_with(".zip"):
				DirAccess.remove_absolute(user_dir_abs.path_join(stale_name))
		user_dir.list_dir_end()
	var src_abs := ProjectSettings.globalize_path("user://test_pack_precedence.zip")
	var reapply_abs := ProjectSettings.globalize_path("user://test_pack_reapply_" \
			+ str(Time.get_ticks_msec()) + ".zip")
	if FileAccess.file_exists(src_abs):
		var src := FileAccess.open(src_abs, FileAccess.READ)
		var dst := FileAccess.open(reapply_abs, FileAccess.WRITE)
		if src and dst:
			# A short write (disk full) would otherwise mount a truncated zip.
			var write_ok := dst.store_buffer(src.get_buffer(src.get_length()))
			src.close()
			dst.close()
			if not write_ok:
				_log_warning("[TEST-REMAP] Pass 2: copy write failed")
				DirAccess.remove_absolute(reapply_abs)
			elif ProjectSettings.load_resource_pack(reapply_abs, true):
				_log_info("[TEST-REMAP] Pass 2: re-applied test pack via copy " + reapply_abs.get_file())
				# Verify VFS state post-reapply
				if FileAccess.file_exists("res://ImmersiveXP/Controller.gd"):
					var chk := FileAccess.get_file_as_bytes("res://ImmersiveXP/Controller.gd")
					var has_marker := "TEST-HOOK-IXP" in chk.get_string_from_utf8()
					_log_info("[TEST-REMAP] Pass 2 post-reapply: IXP/Controller.gd = " \
							+ str(chk.size()) + " bytes, has marker: " + str(has_marker))
			else:
				_log_warning("[TEST-REMAP] Pass 2: load_resource_pack on copy failed")
		else:
			_log_warning("[TEST-REMAP] Pass 2: failed to copy test pack")

# Pack-over-bytecode precedence test, gated behind the test_pack_precedence
# flag in mod_config.cfg: does a mounted .gd + .gd.remap beat the PCK's
# .gdc + .gd.remap for a given resource path.

# Static so the file-scope mount in boot.gd can read it before any instance
# exists.
static func _load_test_pack_flag() -> bool:
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

	# --- pre-mount diagnostics ---
	_log_info(TAG + " === PRE-MOUNT VFS state ===")
	_log_info(TAG + "   FileAccess.file_exists(.gd):       " + str(FileAccess.file_exists(TARGET_PATH)))
	_log_info(TAG + "   FileAccess.file_exists(.gdc):      " + str(FileAccess.file_exists(GDC_PATH)))
	_log_info(TAG + "   FileAccess.file_exists(.gd.remap): " + str(FileAccess.file_exists(REMAP_PATH)))
	_log_info(TAG + "   ResourceLoader.exists(.gd):   " + str(ResourceLoader.exists(TARGET_PATH)))
	_log_info(TAG + "   ResourceLoader.exists(.gdc):  " + str(ResourceLoader.exists(GDC_PATH)))
	if FileAccess.file_exists(REMAP_PATH):
		var pre_remap := FileAccess.get_file_as_string(REMAP_PATH)
		_log_info(TAG + "   PCK's .remap content: " + pre_remap.replace("\n", "|"))

	# --- build the test pack ---
	# No load(TARGET_PATH) here: that caches the bytecode version and stops
	# the mounted .gd winning later. Detokenize the .gdc path explicitly so a
	# stale test pack mounted at static init can't feed back its own
	# rewritten .gd (duplicate-function parse error).
	var vanilla_source := _detokenize_script(GDC_PATH)
	if vanilla_source.is_empty():
		_log_critical(TAG + " FAIL: could not detokenize vanilla source")
		return

	# Capture pristine IXP/Controller.gd via ZIPReader against the .vmz,
	# bypassing the VFS: stale mount entries from a deleted prior test pack,
	# or an already-rewritten prior-session copy, would poison the input.
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

	# Feed pristine vanilla through the production generator, which renames
	# each non-static method to _rtv_vanilla_<name> and appends dispatch
	# wrappers at the original names.
	var parsed := _rtv_parse_script(TARGET_PATH.get_file(), vanilla_source)
	var hookable_count := 0
	for fe in parsed["functions"]:
		if not fe["is_static"]:
			hookable_count += 1
	_log_info(TAG + " parsed %d function(s), %d hookable (non-static)" \
			% [(parsed["functions"] as Array).size(), hookable_count])

	var rewritten := _rtv_rewrite_vanilla_source(vanilla_source, parsed)

	# Append a marker method to verify the compiled class via new() + call().
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

	# Test 4B: also pre-wrap ImmersiveXP's Controller.gd.
	# IXP's autoload take_over_path's its own Controller.gd onto the vanilla
	# path; pre-wrapping it makes hooks fire through the mod's chain. Uses
	# captured_ixp_source from above -- reading IXP_PATH here fails once the
	# old test pack zip is deleted (stale VFS mount entries).
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
				# Match the source's indentation style; GDScript errors on
				# mixed tabs/spaces.
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
				# Ship a .gd.remap pointing back at .gd in case IXP shipped a
				# remap (Godot-exported mod archives often do).
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

	# --- mount ---
	if not ProjectSettings.load_resource_pack(TEST_ZIP, true):
		_log_critical(TAG + " FAIL: load_resource_pack returned false")
		return
	_log_info(TAG + " mounted test pack OK (replace_files=true)")

	# --- post-mount diagnostics ---
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
	const IXP_PATH_CHECK := "res://ImmersiveXP/Controller.gd"
	if FileAccess.file_exists(IXP_PATH_CHECK):
		var ixp_bytes := FileAccess.get_file_as_bytes(IXP_PATH_CHECK)
		var ixp_content := ixp_bytes.get_string_from_utf8()
		var has_our_hook := "TEST-HOOK-IXP" in ixp_content
		_log_info(TAG + "   IXP/Controller.gd bytes: " + str(ixp_bytes.size()) + " has our marker: " + str(has_our_hook))
		if not has_our_hook and ixp_content.length() > 0:
			_log_info(TAG + "   IXP/Controller.gd first 80: " + ixp_content.substr(0, 80).replace("\n", "|"))

	# --- load tests ---
	_log_info(TAG + " === LOAD ATTEMPTS (cache should be cold -- we never pre-loaded) ===")

	# Attempt 1: default load(), same as any game code; if this carries the
	# marker, production scripts resolve to the same version.
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

	# Attempt 5, the definitive test: instantiate the script and call the marker method.
	var instantiate_ok := false
	var call_returned: Variant = null
	var call_err := ""
	if post and marker_in_method_list:
		# new() on a Node-derived script needs freeing; CharacterBody3D init
		# may fail without scene context.
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
			_log_info(TAG + " Movement rename + dispatch wrapper both compiled OK")
			_log_info(TAG + " (wrapper prints nothing by itself; [TEST-HOOK-IXP] from IXP-side wrapper is the in-game signal)")
		else:
			_log_warning(TAG + " Movement intercept NOT compiled (vanilla_in=%s, wrapper_in=%s)" \
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
