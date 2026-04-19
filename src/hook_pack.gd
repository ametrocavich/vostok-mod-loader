## ----- hook_pack.gd -----
## Orchestrates the full rewrite pipeline: enumerate game scripts, call the
## rewriter on each, pack the output into modloader_hooks.zip with the
## three-entry recipe per script (.gd + .gd.remap + empty .gdc), mount it,
## and force-activate the rewritten scripts in Godot's ResourceCache.

# Build the framework pack: enumerate res://Scripts/*.gd, detokenize each via
# _read_vanilla_source, parse + generate wrappers, zip them, mount the zip.
#
# The zip mounts at res://modloader_hooks/ and wrappers load from there. NOT
# from user:// -- Godot 4.6's extends-chain resolution for class_name parents
# breaks for scripts loaded from user://, which shows up as broken super()
# dispatch on class_name-wrapped scripts.
func _generate_hook_pack(defer_activation: bool = false) -> String:
	# Wipe prior-run artifacts even when deferring. Cheap + keeps mode-switches
	# clean.
	var hook_dir := ProjectSettings.globalize_path(HOOK_PACK_DIR)
	DirAccess.make_dir_recursive_absolute(hook_dir)
	var old_zip := ProjectSettings.globalize_path(HOOK_PACK_ZIP)
	if FileAccess.file_exists(old_zip):
		DirAccess.remove_absolute(old_zip)
	var dir := DirAccess.open(hook_dir)
	if dir != null:
		dir.list_dir_begin()
		while true:
			var fname := dir.get_next()
			if fname == "":
				break
			if fname.begins_with("Framework") and fname.ends_with(".gd"):
				DirAccess.remove_absolute(hook_dir.path_join(fname))
		dir.list_dir_end()

	# STABILITY canary B: verify the GDSC tokenizer format is one we support
	# before any rewrite work. Loud, single-message failure beats 126 silent
	# "Empty detokenized source" warnings.
	var tok_version := _probe_gdsc_version()
	if tok_version != -1 and tok_version != 100 and tok_version != 101:
		_log_critical("[STABILITY] Unsupported GDSC tokenizer v%d on Godot %s. This ModLoader supports v100 (Godot 4.0-4.4) and v101 (Godot 4.5-4.6). Hook pack generation disabled -- script hooks will not fire. See README for supported Godot versions." \
				% [tok_version, Engine.get_version_info().get("string", "unknown")])
		return ""
	if tok_version != -1:
		_log_info("[STABILITY] Detokenizer compatible: GDSC v%d on Godot %s" \
				% [tok_version, Engine.get_version_info().get("string", "unknown")])

	if _defer_to_tetra_modlib:
		_log_info("[Hooks] Deferred to tetra's RTVModLib -- wiped stale artifacts, skipping generation")
		return ""
	if _loaded_mod_ids.is_empty():
		return ""

	var script_paths: Array[String] = _enumerate_game_scripts()
	if script_paths.is_empty():
		_log_warning("[RTVCodegen] script enumeration failed -- falling back to class_name list (%d)" % _class_name_to_path.size())
		for path: String in _class_name_to_path.values():
			script_paths.append(path)

	var zip_abs := ProjectSettings.globalize_path(HOOK_PACK_ZIP)
	var zp := ZIPPacker.new()
	if zp.open(zip_abs) != OK:
		_log_critical("[RTVCodegen] Failed to create framework pack zip at %s" % zip_abs)
		return ""

	var script_count := 0
	var hook_count := 0
	var packed_filenames: Array[String] = []
	# Empty allowlist = process ALL hookable vanilla scripts. Used for
	# measuring the pre-compiled-vs-source-compiled split across the
	# full game. After _activate_rewritten_scripts runs, we can count
	# from COMPILE-PROOF log lines how many scripts fell into the
	# GDScriptCache-pinned bucket vs the live-inline bucket.
	var _step_b_allowlist: Array[String] = []
	for script_path: String in script_paths:
		var filename := script_path.get_file()

		if filename in RTV_SKIP_LIST:
			_log_debug("[RTVCodegen] Skipped %s (runtime-sensitive)" % filename)
			continue
		if filename in RTV_RESOURCE_SERIALIZED_SKIP or filename in RTV_RESOURCE_DATA_SKIP:
			continue
		if not _step_b_allowlist.is_empty() and filename not in _step_b_allowlist:
			continue

		# Warn if a [script_overrides] replacement is also in play. For rewritten
		# scripts this is benign (no extends chain into the override) but the
		# override still displaces our rewrite at its own path, so dispatch
		# won't fire for nodes using the override.
		if _override_registry.has(script_path) or _applied_script_overrides.has(script_path):
			var sources: PackedStringArray = []
			if _override_registry.has(script_path):
				for claim in _override_registry[script_path]:
					sources.append(claim["mod_name"])
			for entry in _pending_script_overrides:
				if entry["vanilla_path"] == script_path:
					sources.append(entry["mod_name"] + " [script_overrides]")
			if sources.size() > 0:
				_log_warning("[RTVCodegen] %s is rewritten and also overridden by %s -- override displaces the rewrite, hooks won't fire for that path" \
						% [script_path, ", ".join(sources)])

		var source := _read_vanilla_source(script_path)
		if source.is_empty():
			_log_warning("[RTVCodegen] Empty detokenized source for %s -- skipped" % script_path)
			continue

		var parsed := _rtv_parse_script(filename, source)
		var hookable_count := 0
		for fe in parsed["functions"]:
			if not fe["is_static"]:
				hookable_count += 1
			if fe["name"] == "_ready" and not fe["is_static"]:
				_ready_is_coroutine_by_path[parsed["path"]] = bool(fe["is_coroutine"])
		if hookable_count == 0:
			continue

		# Record scripts whose module-scope preload() pulls in a PackedScene.
		# _activate_rewritten_scripts skips eager load+reload for these paths
		# so the preload fires later, AFTER mod autoloads run overrideScript().
		# VFS mount precedence (.gd + .remap + empty .gdc) still serves our
		# rewrite when game code lazy-compiles the script at first reference.
		var scene_preloads := _collect_module_scope_scene_preloads(source)
		if scene_preloads.size() > 0:
			_scripts_with_scene_preloads[filename] = scene_preloads

		var rewritten := _rtv_rewrite_vanilla_source(source, parsed)
		# Ship at the ORIGINAL vanilla path so class_name registration in the
		# PCK's global_script_class_cache.cfg matches our file. Declaring
		# class_name at a non-registered path triggers "Class X hides a
		# global script class" errors for scripts Godot pre-compiled at
		# startup (Camera, WeaponRig). Same-path keeps the registry
		# consistent with what's at the path.
		var gd_entry := "Scripts/" + filename
		if zp.start_file(gd_entry) != OK:
			_log_warning("[RTVCodegen] Failed to start zip entry %s" % gd_entry)
			continue
		zp.write_file(rewritten.to_utf8_buffer())
		zp.close_file()
		# Self-referencing .gd.remap overrides the PCK's .gd.remap -> .gdc
		# redirect. Godot's _path_remap reads this BEFORE GDScript loader.
		var remap_entry := "Scripts/" + filename + ".remap"
		if zp.start_file(remap_entry) != OK:
			_log_warning("[RTVCodegen] Failed to start zip entry %s" % remap_entry)
			continue
		var remap_body := "[remap]\npath=\"res://Scripts/%s\"\n" % filename
		zp.write_file(remap_body.to_utf8_buffer())
		zp.close_file()
		# Empty .gdc to shadow the PCK's bytecode. Godot's GDScript loader
		# prefers a sibling .gdc when present at the same base path -- even
		# after our self-referencing remap redirects to .gd. A zero-byte
		# .gdc at the same path defeats that preference: Godot can't parse
		# empty bytecode, silently falls back to compiling our .gd. Verified
		# 2026-04-17 -- no engine errors, all 5 rewrites load live.
		var gdc_filename: String = filename.replace(".gd", ".gdc")
		var gdc_entry := "Scripts/" + gdc_filename
		if zp.start_file(gdc_entry) != OK:
			_log_warning("[RTVCodegen] Failed to start zip entry %s" % gdc_entry)
			continue
		zp.write_file(PackedByteArray())
		zp.close_file()

		script_count += 1
		hook_count += hookable_count * 4  # pre/post/callback/replace per method
		packed_filenames.append(filename)
		_log_debug("[RTVCodegen] Rewrote Scripts/%s (%d hooks)" % [filename, hookable_count * 4])

	# Step C: rewrite mod scripts that subclass a vanilla script we just
	# rewrote. Same rename+dispatch treatment keyed to the vanilla filename,
	# so hooks fire regardless of whether the mod's body calls super(). The
	# re-entry guard in the dispatch template prevents double-fire when the
	# mod's body DOES call super() through to vanilla's wrapper.
	var vanilla_set: Dictionary = {}
	for fn in packed_filenames:
		vanilla_set[fn] = true
	var mod_candidates := _scan_mod_extends_targets(vanilla_set)
	var mod_script_count := 0
	var mod_hook_count := 0
	var mod_packed: Array[Dictionary] = []  # {res_path, vanilla_filename}
	for cand: Dictionary in mod_candidates:
		var cand_filename: String = (cand["res_path"] as String).get_file()
		var vanilla_filename: String = cand["vanilla_filename"]
		var mod_name: String = cand["mod_name"]
		var source: String = cand["source"]
		# Parse using the VANILLA filename so hook_base is "controller-*"
		# not "immersivexp/controller-*" -- single hook namespace per vanilla.
		var parsed := _rtv_parse_script(vanilla_filename, source)
		var hookable_count := 0
		for fe in parsed["functions"]:
			if not fe["is_static"]:
				hookable_count += 1
		if hookable_count == 0:
			continue
		# Use _rtv_mod_ prefix for mod method renames so they don't shadow
		# vanilla's _rtv_vanilla_ methods via virtual dispatch. Otherwise
		# super._ready() -> vanilla wrapper -> _rtv_vanilla__ready() resolves
		# back to the mod's override -> infinite loop.
		var rewritten := _rtv_rewrite_vanilla_source(source, parsed, "_rtv_mod_")
		# Pack at the mod's own path. Mount replace_files=true wins over the
		# mod's .vmz which also serves this path. Script stays a subclass of
		# rewritten vanilla via extends; its body may or may not call super.
		var zip_rel: String = (cand["res_path"] as String).trim_prefix("res://")
		if zp.start_file(zip_rel) != OK:
			_log_warning("[RTVCodegen] Failed to start mod zip entry %s" % zip_rel)
			continue
		zp.write_file(rewritten.to_utf8_buffer())
		zp.close_file()
		# NOTE: do NOT ship a .gd.remap or empty .gdc shadow for mod subclass
		# scripts. Those tricks exist to defeat the base game PCK's
		# .gd -> .gdc redirect + bytecode preference. Mod archives ship
		# source-only (no PCK bytecode at this path), so the shadows only
		# change Godot's load pathway from (direct .gd compile) to
		# (bytecode-fail -> .gd fallback compile). The latter triggers a
		# stricter reload path that cascades strict re-parse into the mod's
		# sibling preloads -- which breaks mods whose code is valid under
		# lenient first-compile but sloppy under strict (Gotcha #5, e.g.
		# AI Overhaul's AwarenessSystem.gd with bodyless `if` blocks).
		# Replacing just the .gd via load_resource_pack(replace_files=true)
		# is enough for our rewrite to serve at the mod's path, and matches
		# the pre-hooks load pathway for mod scripts.
		mod_script_count += 1
		mod_hook_count += hookable_count * 4
		mod_packed.append({"res_path": cand["res_path"], "vanilla_filename": vanilla_filename})
		_log_debug("[RTVCodegen] Rewrote mod script %s (ext=%s, %d hooks) [%s]" \
				% [cand["res_path"], vanilla_filename, hookable_count * 4, mod_name])

	# Step E: MAXIMUM-COMPAT autofix of mod SIBLING scripts (non-subclass
	# mod .gd files). These aren't wrapped for dispatch but they may be
	# preloaded/extended from subclass scripts (AI Overhaul's Core/AI.gd
	# does `const AwarenessSystem = preload("Systems/AwarenessSystem.gd")`),
	# and when strict parse cascades through the preload chain Godot
	# rejects sloppy GDScript the mod author had been getting away with.
	# We read each sibling from the mod archive (mounted at res:// but
	# hook pack not yet mounted), run autofix, and pack the fixed version
	# into the hook pack overlay when it differs from the original. VFS
	# replace_files=true precedence then serves the fixed version to
	# Godot's parser, restoring the pre-hooks compat surface for mods
	# with bodyless `if` blocks and Godot-3-era annotations.
	var subclass_paths: Dictionary = {}
	for mp in mod_packed:
		subclass_paths[mp["res_path"]] = true
	var sibling_fixed := 0
	var sibling_total_bodyless := 0
	var sibling_skipped_noop := 0
	for archive_file: String in _archive_file_sets:
		var paths_set: Dictionary = _archive_file_sets[archive_file]
		for p: String in paths_set:
			if not p.ends_with(".gd"):
				continue
			if p.begins_with("res://Scripts/"):
				continue  # vanilla, handled upstream
			if subclass_paths.has(p):
				continue  # already packed via mod-subclass rewrite
			if not ResourceLoader.exists(p):
				continue
			var raw := FileAccess.get_file_as_string(p)
			if raw.is_empty():
				continue
			var norm := raw.replace("\r\n", "\n").replace("\r", "\n")
			var af := _rtv_autofix_legacy_syntax(norm)
			var fixed_src: String = af["source"]
			if fixed_src == norm:
				sibling_skipped_noop += 1
				continue  # already clean, no overlay needed
			var zip_rel: String = p.trim_prefix("res://")
			if zp.start_file(zip_rel) != OK:
				_log_warning("[Autofix] Failed to pack sibling zip entry %s" % zip_rel)
				continue
			zp.write_file(fixed_src.to_utf8_buffer())
			zp.close_file()
			sibling_fixed += 1
			sibling_total_bodyless += int(af["bodyless"])
			_log_info("[Autofix] Patched sibling %s: bodyless=%d tool=%d onready=%d export=%d" \
					% [p, af["bodyless"], af["tool"], af["onready"], af["export"]])
	if sibling_fixed > 0:
		_log_info("[Autofix] %d mod sibling script(s) repaired (%d bodyless blocks) -- packed into hook pack overlay (%d already clean, no overlay written)" \
				% [sibling_fixed, sibling_total_bodyless, sibling_skipped_noop])

	# STABILITY canary C: add a tiny known-content file to the hook pack so we
	# can verify VFS mount precedence independently of the script-rewriting
	# path. After mount, a FileAccess.get_file_as_string on this path should
	# return the canary content -- if not, the pack mounted but isn't serving
	# files and no rewrite will take effect this session.
	var canary_content := "MODLOADER-VFS-CANARY-" + MODLOADER_VERSION
	if zp.start_file("__modloader_canary__.txt") == OK:
		zp.write_file(canary_content.to_utf8_buffer())
		zp.close_file()

	zp.close()
	if mod_script_count > 0:
		_log_info("[RTVCodegen] Rewrote %d mod subclass script(s), %d hook points -- composes with mods that bypass super()" \
				% [mod_script_count, mod_hook_count])
		hook_count += mod_hook_count
		script_count += mod_script_count

	# Mount must happen BEFORE mod autoloads run so [rtvmodlib] needs= resolves
	# and before any scene compiles against the rewritten class_name scripts.
	# replace_files=true is the default in 4.6 but pass explicitly -- the whole
	# design depends on our Scripts/*.gd + .gd.remap entries winning over the
	# PCK's same-path entries in Godot's VFS layering.
	if script_count > 0:
		if defer_activation:
			# Pass 1 pre-restart: write the zip + persist pass_state so Pass 2's
			# static-init mount picks it up on a fresh engine where GDScriptCache
			# isn't pinned to PCK bytecode. Skipping mount+activate here avoids
			# the misleading STABILITY alarm fired by _activate_rewritten_scripts
			# against the pre-compiled Camera/WeaponRig/Door/etc. that would
			# otherwise scream "hooks WILL NOT fire this session" seconds before
			# we restart and Pass 2 gets 126/126 inline-live.
			_log_info("[RTVCodegen] Generated %d rewritten vanilla script(s), %d hook points -- activation deferred to Pass 2 fresh engine" \
					% [script_count, hook_count])
			_persist_hook_pack_state()
		elif ProjectSettings.load_resource_pack(HOOK_PACK_ZIP, true):
			# STABILITY canary C readback: confirm VFS mount precedence works
			# end-to-end. If the canary file isn't readable with expected
			# content, the hook pack mounted but isn't serving files -- every
			# rewrite will silently fall back to vanilla.
			var canary_got := FileAccess.get_file_as_string("res://__modloader_canary__.txt")
			if canary_got.begins_with("MODLOADER-VFS-CANARY-"):
				_log_info("[STABILITY] VFS canary OK: hook pack mount precedence verified (%s)" % canary_got.strip_edges())
			else:
				_log_critical("[STABILITY] VFS canary FAILED (got '%s', expected MODLOADER-VFS-CANARY-*) -- hook pack mounted but files aren't served. Rewrites will not take effect this session." % canary_got.substr(0, 40))
			_log_info("[RTVCodegen] Generated %d rewritten vanilla script(s), %d hook points -- pack mounted at res://" \
					% [script_count, hook_count])
			_activate_rewritten_scripts(packed_filenames)
		else:
			_log_critical("[RTVCodegen] Failed to mount hook pack at %s -- rewrites won't load" % zip_abs)
	else:
		_log_info("[RTVCodegen] No scripts rewritten -- no pack mounted")
	return HOOK_PACK_ZIP

# Force the game's ResourceCache entry for each rewritten vanilla path to use
# our source. Necessary because:
#   - pre-mount load()s (engine class_name pre-compile for scripts in the main
#     scene graph, or anything else) cache the PCK's .gdc-compiled script at
#     res://Scripts/<Name>.gd
#   - CACHE_MODE_REPLACE doesn't fully rewrite those entries -- it re-reads
#     through the GDScript loader which keeps the bytecode association
#   - scene ext_resource and ClassName.new() both resolve through the cache,
#     so if the cache is stale our dispatch wrappers never fire
#
# Direct mutation of source_code + reload() recompiles the existing cached
# script in place. Scene nodes, ScriptServer class_cache, and any other
# live references keep working -- they now dispatch through our wrappers.
# Verified 2026-04-17: 158 wrapper calls in 4s across 5 scripts (physics
# tick rate on active Camera/Controller nodes).

func _activate_rewritten_scripts(filenames: Array[String]) -> void:
	# Scripts whose module-scope preload() pulls in a PackedScene are deferred
	# from eager load+reload. Loading them here would fire their preload()
	# chain BEFORE mod autoloads call overrideScript(), baking Script
	# ext_resources in those scenes to the pre-override vanilla. When mods
	# later take_over_path, the baked refs go empty-path (see Godot
	# core/io/resource.cpp Resource::set_path with p_take_over=true) and
	# scene instantiate() produces orphan-scripted nodes that never run mod
	# bodies. VFS mount precedence (.gd + .remap + empty .gdc) still serves
	# our rewrite when game code lazy-loads these paths after mod overrides.
	var deferred: PackedStringArray = []
	for fname: String in filenames:
		if _scripts_with_scene_preloads.has(fname):
			deferred.append(fname)
	if deferred.size() > 0:
		_log_info("[RTVCodegen] DEFER %d script(s) with module-scope scene preload -- will lazy-compile via VFS after mod overrides: %s" \
				% [deferred.size(), ", ".join(Array(deferred))])

	# PRE-ACTIVATE pass: classify each cached script as
	#  (a) already has _rtv_vanilla_* from static-init preload (pinned OK)
	#  (b) source_code matches our rewrite but methods don't (GDScriptCache-pinned)
	#  (c) source_code is empty (tokenized bytecode from PCK, no Static init preload)
	#  (d) something else
	# Summary counts printed at the end so we don't have to count by hand.
	var pre_a := 0
	var pre_b := 0
	var pre_c := 0
	var pre_d := 0
	var pre_b_names: PackedStringArray = []
	var pre_c_names: PackedStringArray = []
	for fname: String in filenames:
		if _scripts_with_scene_preloads.has(fname):
			continue
		var vp := "res://Scripts/" + fname
		var c := load(vp) as GDScript
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
			pre_b_names.append(fname)
		else:
			pre_c += 1
			pre_c_names.append(fname)
	_log_info("[RTVCodegen] PRE-ACTIVATE summary: inline-live=%d, pinned-with-source=%d, pinned-tokenized=%d, other=%d / total=%d" \
			% [pre_a, pre_b, pre_c, pre_d, filenames.size()])
	if pre_b > 0:
		_log_info("[RTVCodegen]   pinned-with-source (GDScriptCache has our text but compiled methods are vanilla): %s" \
				% ", ".join(Array(pre_b_names).slice(0, 25)))
	if pre_c > 0:
		_log_info("[RTVCodegen]   pinned-tokenized (PCK .gdc, our static-init preload missed): %s" \
				% ", ".join(Array(pre_c_names).slice(0, 25)))

	var activated := 0
	var preactivated := 0
	for fname: String in filenames:
		if _scripts_with_scene_preloads.has(fname):
			continue
		var vp := "res://Scripts/" + fname
		var cached := load(vp) as GDScript
		if cached == null:
			_log_warning("[RTVCodegen] activate %s: load returned null -- skip" % vp)
			continue

		# If static-init preload already put our rewrite into this cached
		# script, skip the reload entirely. reload() would fail with
		# "Cannot reload script while instances exist" for autoload-backed
		# scripts (Database, GameData, Inputs, Loader, Menu, etc.) -- and
		# the reload isn't needed anyway since the compiled methods
		# already include our _rtv_vanilla_* renames.
		var already_live := false
		for m in cached.get_script_method_list():
			if str(m["name"]).begins_with("_rtv_vanilla_"):
				already_live = true
				break
		if already_live:
			preactivated += 1
			activated += 1
			continue

		# Otherwise: mutate source_code + reload. This covers scripts whose
		# cache entry was compiled-from-source but without our rewrite yet
		# (rare -- normal case is static-init preload already covered it).
		var our_source := FileAccess.get_file_as_string(vp)
		if our_source.is_empty():
			_log_warning("[RTVCodegen] activate %s: FileAccess returned empty -- skip" % vp)
			continue
		cached.source_code = our_source
		var err := cached.reload()
		if err != OK:
			_log_warning("[RTVCodegen] activate %s: reload failed (%s)" % [vp, error_string(err)])
		# Step 2: verify the reload actually took by checking the compiled
		# method list. For scripts originally compiled from .gdc bytecode
		# (Camera, WeaponRig -- pre-compiled by the engine during startup
		# because they're referenced by the initial scene graph), reload()
		# does NOT re-parse from the mutated source_code -- it apparently
		# re-reads bytecode. Fall back to loading a fresh script via
		# CACHE_MODE_IGNORE (which goes through _path_remap -> our .gd
		# with source compile) and take_over_path to displace the stale
		# cache entry.
		var has_rename := false
		for m in cached.get_script_method_list():
			if str(m["name"]).begins_with("_rtv_vanilla_"):
				has_rename = true
				break
		if not has_rename:
			_log_info("[RTVCodegen] activate %s: reload didn't apply (pre-compiled); falling back to fresh+take_over_path" % vp)
			var fresh := ResourceLoader.load(vp, "", ResourceLoader.CACHE_MODE_IGNORE) as GDScript
			if fresh == null:
				_log_critical("[RTVCodegen] activate %s: fresh load returned null -- skip" % vp)
				continue
			var fresh_has_rename := false
			for m in fresh.get_script_method_list():
				if str(m["name"]).begins_with("_rtv_vanilla_"):
					fresh_has_rename = true
					break
			if not fresh_has_rename:
				_log_critical("[RTVCodegen] activate %s: fresh load also lacks renames -- rewrite isn't compiling" % vp)
				continue
			fresh.take_over_path(vp)
			_log_info("[RTVCodegen] activate %s: fresh script took over vanilla path" % vp)
		activated += 1
	var eager_total := filenames.size() - _scripts_with_scene_preloads.size()
	_log_info("[RTVCodegen] Activated %d/%d rewritten script(s) (%d already live from static-init preload; %d deferred to lazy-compile)" \
			% [activated, eager_total, preactivated, _scripts_with_scene_preloads.size()])

	# Step D: persist hook pack path to pass_state so the next session's
	# _mount_previous_session() picks it up at static init -- BEFORE game
	# autoloads compile class_name scripts from the PCK's .gdc. Only
	# then can we rewire pre-compiled scripts like Camera and WeaponRig
	# (ScriptServer.class_cache pins their bytecode once compiled).
	_persist_hook_pack_state()

	# End-to-end proof: register REAL hooks via the public RTVModLib API
	# on well-known Controller/Camera/Door methods. If these fire at
	# runtime, the full chain is working:
	#   1. our rewrite is what game code compiles against
	#   2. our dispatch wrapper runs on method entry
	#   3. _dispatch("<hook_name>-pre", args) reaches RTVModLib's _hooks dict
	#   4. our registered callback fires with the right args
	# Each hook bumps its own counter via Engine meta; deferred log
	# reports which hooks fired. If any of the three is zero, that
	# layer of the chain is broken.
	# Hooks spread across three phases: pre-gameplay menu (loader/simulation/
	# profiler fire every physics tick from the start), menu UI (settings/
	# menu fire on user click), gameplay (controller/character fire once in
	# world). If the first set fires and the last doesn't, it's just timing.
	# If NONE fire but dispatch counter is high, _hooks lookup is broken.
	#
	# Developer-mode gate: the probe hooks fire every physics tick on
	# live nodes and the 30s timer prints ~30 log lines of breakdowns.
	# Valuable for validating the hook pipeline during development;
	# redundant once the system is stable.
	if not _developer_mode:
		return
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

	# Compile proof: inspect the methods on each activated script. If our
	# rewrite compiled into the cached GDScript, the method list contains
	# both the renamed vanilla (e.g. _rtv_vanilla_Movement) AND the
	# dispatch wrapper at the original name (e.g. Movement).
	var compile_proof_ok := 0
	var compile_proof_fail: PackedStringArray = []
	for fname: String in filenames:
		if _scripts_with_scene_preloads.has(fname):
			continue  # deferred to lazy-compile; compile-proof runs post-override elsewhere
		var vp := "res://Scripts/" + fname
		var s := load(vp) as GDScript
		if s == null:
			compile_proof_fail.append(fname)
			continue
		var methods := s.get_script_method_list()
		var has_vanilla_rename := false
		var sample_rename := ""
		for m in methods:
			var n: String = str(m["name"])
			if n.begins_with("_rtv_vanilla_"):
				has_vanilla_rename = true
				if sample_rename == "":
					sample_rename = n
				if sample_rename != "" and has_vanilla_rename:
					break
		if _developer_mode:
			_log_info("[RTVCodegen] COMPILE-PROOF %s: %d methods compiled, _rtv_vanilla_* present=%s (e.g. %s)" \
					% [vp, methods.size(), has_vanilla_rename, sample_rename])
		if has_vanilla_rename:
			compile_proof_ok += 1
		else:
			compile_proof_fail.append(fname)

	# STABILITY canary A: summarize COMPILE-PROOF results and alarm on
	# catastrophic or critical-script failure. Silent breakage is the worst
	# mode -- users should see a clear message if Godot changed something
	# under us (VFS precedence, reload-parse behavior, cache eviction rules).
	var critical_set: Dictionary = {"Controller.gd": true, "Camera.gd": true,
			"WeaponRig.gd": true, "Door.gd": true, "Trader.gd": true,
			"Hitbox.gd": true, "LootContainer.gd": true, "Pickup.gd": true}
	var critical_failures: PackedStringArray = []
	for f in compile_proof_fail:
		if critical_set.has(f):
			critical_failures.append(f)
	# Deferred scripts aren't counted against the total here -- they skipped
	# compile-proof intentionally and will be verified via
	# _verify_rewrite_active_after_override once lazy-compile fires.
	var attempted := filenames.size() - _scripts_with_scene_preloads.size()
	if compile_proof_ok == 0 and attempted > 0:
		_log_critical("[STABILITY] ALL %d rewrites failed to take effect -- VFS mount, hook pack, or cache eviction is broken. Mods will NOT work this session. Click 'Reset to Vanilla' in the UI or create modloader_disabled in the game folder." % attempted)
	elif critical_failures.size() > 0:
		_log_critical("[STABILITY] Hook rewrites missing on critical scripts: %s. Hooks on these scripts will NOT fire this session (likely cache-pinning fallback failure)." % ", ".join(critical_failures))
	else:
		var deferred_tag := ""
		if _scripts_with_scene_preloads.size() > 0:
			deferred_tag = ", %d deferred to lazy-compile" % _scripts_with_scene_preloads.size()
		_log_info("[STABILITY] COMPILE-PROOF summary: %d/%d rewrites active%s%s" \
				% [compile_proof_ok, attempted,
					(" (%d pinned-fallback)" % compile_proof_fail.size()) if compile_proof_fail.size() > 0 else "",
					deferred_tag])

	# Autoload instance inspection: for the "Already in use" set, the
	# script's get_script_method_list() shows our renames, BUT the live
	# autoload node might still be holding a pointer to the original
	# bytecode via its get_script() property. If script_match=false for
	# any of these, our rewrite isn't reaching the actual game instance.
	# Developer-mode only -- pure diagnostic, 9 log lines per session.
	if _developer_mode:
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
			# Also check if the method list is available via the INSTANCE (has_method
			# on the node). If the node's bytecode is our rewrite, it should report
			# _rtv_vanilla_<something> as a method.
			var instance_methods_has_rename := false
			for m in node.get_method_list():
				if str(m["name"]).begins_with("_rtv_vanilla_"):
					instance_methods_has_rename = true
					break
			_log_info("[RTVCodegen] AUTOLOAD-CHECK %s: script=%s script_has_rename=%s instance_has_rename=%s" \
					% [aname, scr.resource_path, has_rename, instance_methods_has_rename])

	# Reset counters before probes. The dispatch template increments
	# _rtv_dispatch_count on entry, _rtv_dispatch_no_lib when the _lib
	# null-check trips, and _rtv_dispatch_by_hook per hook_base.
	Engine.set_meta("_rtv_dispatch_count", 0)
	Engine.set_meta("_rtv_dispatch_no_lib", 0)
	Engine.set_meta("_rtv_dispatch_by_hook", {})
	# 30s gives the player time to get into gameplay so controller-level
	# hooks can fire at least once.
	get_tree().create_timer(30.0).timeout.connect(func():
		var n: int = int(Engine.get_meta("_rtv_dispatch_count", 0))
		var no_lib: int = int(Engine.get_meta("_rtv_dispatch_no_lib", 0))
		var by_hook: Dictionary = Engine.get_meta("_rtv_dispatch_by_hook", {})
		var pc: Dictionary = Engine.get_meta("_rtv_probe_counts", {})
		var fa: Dictionary = Engine.get_meta("_rtv_probe_first_args", {})
		if n > 0:
			_log_info("[RTVCodegen] DISPATCH-LIVE: %d wrapper call(s) in 30s (no-lib fallback=%d)" % [n, no_lib])
		else:
			_log_critical("[RTVCodegen] DISPATCH-DEAD: 0 wrapper calls in 30s -- game code not hitting rewrite")
		# Sort by count desc and log top 15
		var pairs: Array = []
		for k: String in by_hook:
			pairs.append([k, int(by_hook[k])])
		pairs.sort_custom(func(a, b): return a[1] > b[1])
		for i in range(min(15, pairs.size())):
			_log_info("[RTVCodegen]   hook_base=%s count=%d" % [pairs[i][0], pairs[i][1]])
		# HOOK-API per-probe breakdown across phases:
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
		# IXP takeover verification: inspect live Controller/Camera/WeaponRig
		# instances. IXP's take_over_path moves IXP's script onto the vanilla
		# path. If IXP's override is ACTIVE, node.get_script() will be IXP's
		# script (source contains "IXP" or "ImmersiveXP" markers), and the
		# base-script chain should walk IXP -> our rewrite -> engine class.
		# If IXP failed, node.get_script() is our rewrite directly (no IXP
		# ancestor). This is the definitive proof IXP's takeover works.
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
			# Walk base chain
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
