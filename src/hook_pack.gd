## ----- hook_pack.gd -----
## Orchestrates the full rewrite pipeline: enumerate game scripts, call the
## rewriter on each, pack the output into modloader_hooks.zip with the
## three-entry recipe per script (.gd + .gd.remap + empty .gdc), mount it,
## and force-activate the rewritten scripts in Godot's ResourceCache.

# Scripts that carry rewriter-injected registry helpers. These MUST be
# force-activated (bypass the scene-preload deferral) so the injected fields
# are live on autoload instances when mods call lib.register(). Keep in
# sync with the match statement in _rtv_registry_injection().
const REGISTRY_TARGETS: Array[String] = [
	"Database.gd",
]

func _is_registry_target(filename: String) -> bool:
	return filename in REGISTRY_TARGETS

# Sum a per-mod analysis field across all scanned mods. Used for the
# wrap-surface log line so we can see how many mods pushed a given
# category into needed_paths.
func _count_mods_field(field: String) -> int:
	var n := 0
	for mod_name: String in _mod_script_analysis:
		var a: Dictionary = _mod_script_analysis[mod_name]
		if (a.get(field, []) as Array).size() > 0:
			n += 1
	return n

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
	# Per-call unique filename. Each _generate_hook_pack invocation writes a
	# new file at a new path so load_resource_pack mounts fresh (no path-dedup
	# stale offsets). Old files get cleaned up at next static-init.
	var pack_zip_rel := HOOK_PACK_DIR.path_join("%s_%d.zip" % [HOOK_PACK_PREFIX, Time.get_ticks_msec()])
	# Do NOT delete the old hook pack zip here. If a previous session mounted
	# it via ProjectSettings.load_resource_pack (_mount_previous_session), the
	# VFS still holds a file handle to the zip. Deleting the file on disk
	# invalidates that handle, causing every VFS read that routes through the
	# hook pack overlay to fail at core/io/file_access_zip.cpp:137 with "Cannot
	# open file". In practice that breaks any load() of a path present in the
	# overlay -- including rewritten vanilla scripts and sibling-rewritten mod
	# autoload scripts. ZIPPacker.open below opens for write and atomically
	# replaces the file on save, so leaving the old file in place is safe.
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
	# before any rewrite work. One loud, actionable message beats a flood of
	# "Empty detokenized source" warnings, one per hookable script.
	var tok_version := _probe_gdsc_version()
	if tok_version != -1 and tok_version != 100 and tok_version != 101:
		_log_critical("[STABILITY] Unsupported GDSC tokenizer v%d on Godot %s. This ModLoader supports v100 (Godot 4.0-4.4) and v101 (Godot 4.5-4.6). Hook pack generation disabled -- script hooks will not fire. See README for supported Godot versions." \
				% [tok_version, Engine.get_version_info().get("string", "unknown")])
		return ""
	if tok_version != -1:
		_log_info("[STABILITY] Detokenizer compatible: GDSC v%d on Godot %s" \
				% [tok_version, Engine.get_version_info().get("string", "unknown")])

	if _loaded_mod_ids.is_empty():
		return ""

	var script_paths: Array[String] = _enumerate_game_scripts()
	if script_paths.is_empty():
		_log_warning("[RTVCodegen] script enumeration failed -- falling back to class_name list (%d)" % _class_name_to_path.size())
		for path: String in _class_name_to_path.values():
			script_paths.append(path)
	# Narrow the wrap surface to vanilla scripts that mods actually touch.
	# Wrapping every vanilla (180 in RTV) fires dispatch on every method call
	# of every class_name node, even ones no mod extends or hooks. v2.1.0's
	# opt-in [hooks] model had ~zero overhead for untouched scripts; v3.0.0
	# flipped to wrap-everything which burned ~93K calls/sec on hot paths
	# like hud-_physics_process when 65 mods were loaded. Restore the opt-in
	# semantics WITHOUT requiring mod-author changes by deriving the set from
	# what the scan already captured.
	#
	# A vanilla script goes into needed_paths if ANY enabled mod:
	#   1. extends "res://Scripts/<X>.gd"
	#   2. take_over_path("res://Scripts/<X>.gd", ...)
	#   3. calls .hook("<x>-<method>...", ...) where <x> is the lowercase stem
	#
	# Scripts not in the union run AS-IS (no dispatch wrapper, matches v2.1.0
	# behavior for those specific paths). Their class_name registrations stay
	# intact because we never touched them -- Godot's native compile path
	# serves them with no overhead.
	var prefix_to_path: Dictionary = {}
	for sp: String in script_paths:
		prefix_to_path[sp.get_file().get_basename().to_lower()] = sp
	var needed_paths: Dictionary = {}
	# Reverse map: vanilla_path -> Array of {mod, reason} entries. Diagnostics
	# only; used right after to warn about multi-claim conflicts. When N>1
	# mods override the same script via take_over_path, only the last call
	# wins -- the others' bodies are orphaned and silently dead. Surfacing
	# this as a CRITICAL saves hours of "why doesn't my mod work" debugging.
	var claim_map: Dictionary = {}
	for mod_name: String in _mod_script_analysis:
		var analysis: Dictionary = _mod_script_analysis[mod_name]
		for p: String in (analysis.get("extends_paths", []) as Array):
			if p.begins_with("res://Scripts/"):
				needed_paths[p] = true
				if not claim_map.has(p):
					claim_map[p] = []
				(claim_map[p] as Array).append({"mod": mod_name, "reason": "extends"})
		for p: String in (analysis.get("take_over_literal_paths", []) as Array):
			if p.begins_with("res://Scripts/"):
				needed_paths[p] = true
				if not claim_map.has(p):
					claim_map[p] = []
				(claim_map[p] as Array).append({"mod": mod_name, "reason": "take_over_path"})
		for pref: String in (analysis.get("hooked_script_prefixes", []) as Array):
			if prefix_to_path.has(pref):
				needed_paths[prefix_to_path[pref]] = true
	# Hot-path scripts that game code compiles eagerly at static init
	# (Camera, Controller, WeaponRig, Door, etc.) must stay wrapped even
	# when no mod touches them -- they're in the pinned_probes list in
	# boot.gd because Godot's class_cache pins their .gdc before any mod
	# code runs. Wrapping them costs a dispatch call that short-circuits
	# via _any_mod_hooked when no mod hooked them, so it's ~1 meta-read
	# per call and still correct.
	var _pinned_always_wrap: Array[String] = [
		"res://Scripts/Camera.gd", "res://Scripts/Controller.gd",
		"res://Scripts/Door.gd", "res://Scripts/Fish.gd",
		"res://Scripts/Furniture.gd", "res://Scripts/GameData.gd",
		"res://Scripts/Grenade.gd", "res://Scripts/Grid.gd",
		"res://Scripts/Hitbox.gd", "res://Scripts/KnifeRig.gd",
		"res://Scripts/LootContainer.gd", "res://Scripts/Lure.gd",
		"res://Scripts/Pickup.gd", "res://Scripts/Settings.gd",
		"res://Scripts/Trader.gd", "res://Scripts/WeaponRig.gd",
	]
	for pp in _pinned_always_wrap:
		needed_paths[pp] = true
	# REGISTRY_TARGETS (currently just Database.gd) carry injected registry
	# fields that mods rely on via lib.register()/override(). Always wrap.
	for rt_filename in REGISTRY_TARGETS:
		needed_paths["res://Scripts/" + rt_filename] = true
	_log_info("[RTVCodegen] Wrap surface: %d of %d vanilla scripts (extends=%d, take_over=%d, hook=%d, pinned=%d)" % [
		needed_paths.size(),
		script_paths.size(),
		_count_mods_field("extends_paths"),
		_count_mods_field("take_over_literal_paths"),
		_count_mods_field("hooked_script_prefixes"),
		_pinned_always_wrap.size() + REGISTRY_TARGETS.size(),
	])
	# Report multi-claim conflicts. take_over_path is last-wins by load order;
	# claimants other than the last are orphaned -- their method bodies exist
	# but the script Godot resolves at `res://Scripts/<X>.gd` is the winner's.
	# If ANY of the 10 Interface.gd claimants in a typical big-mod-set loadout
	# has the behavior a user cares about and isn't last in load order, that
	# behavior silently vanishes. This warning gives the user a map.
	var conflict_count := 0
	for path: String in claim_map:
		var claims: Array = claim_map[path]
		if claims.size() < 2:
			continue
		conflict_count += 1
		var claim_summaries: PackedStringArray = []
		for c in claims:
			claim_summaries.append("%s(%s)" % [c["mod"], c["reason"]])
		_log_critical("[RTVCodegen] CONFLICT %s claimed by %d mods: %s -- take_over_path is last-wins, only one mod's code is live" \
				% [path, claims.size(), ", ".join(claim_summaries)])
	if conflict_count > 0:
		_log_critical("[RTVCodegen] %d vanilla script(s) have overlapping claims -- see CONFLICT lines above. Disable duplicates to get predictable behavior." \
				% conflict_count)
	# Skip-list breakdown -- gives the README an evidence trail for "we wrap N
	# scripts, skip M". The actual rewritten count is logged below by the
	# "Generated N rewritten" line; this just records the static skip-list sizes.
	_log_info("[RTVCodegen] Skip lists: %d runtime-sensitive, %d data, %d serialized (total %d skipped from rewrite)" % [
		RTV_SKIP_LIST.size(),
		RTV_RESOURCE_DATA_SKIP.size(),
		RTV_RESOURCE_SERIALIZED_SKIP.size(),
		RTV_SKIP_LIST.size() + RTV_RESOURCE_DATA_SKIP.size() + RTV_RESOURCE_SERIALIZED_SKIP.size(),
	])

	# Pre-read mod sibling scripts BEFORE opening ZIPPacker on the hook pack.
	# When the hook pack from a previous session is mounted via
	# ProjectSettings.load_resource_pack, Godot holds a FileAccessZIP handle
	# to the file. ZIPPacker.open below opens the same file for writing,
	# which on Windows invalidates that read handle once the in-progress
	# zip is modified. Any VFS read that routes through the hook pack
	# overlay AFTER zp.open then fails with "Cannot open file" at
	# file_access_zip.cpp:137, breaking mod autoload compilation.
	# Reading here, while the old mount is still valid, keeps the sibling
	# source snapshot safe. Writes happen later via zp.start_file.
	#
	# Emit EVERY iterated sibling into the new hook pack, not just ones
	# autofix changed. Rationale: if a previous session's hook pack already
	# owns a sibling path and we skip emitting it because autofix is
	# idempotent, the new hook pack on disk won't contain that path. Godot's
	# load_resource_pack(replace_files=true) gives the newest mount
	# precedence, and VFS resolves paths against whichever mount claims
	# them. If the new mount doesn't claim a path the old mount did, VFS
	# can end up routing through the old (now stale-indexed) mount and
	# fail at file_access_zip.cpp:141 (the unzGoToFilePos failure, distinct
	# from :137's "Cannot open file"). Emitting unconditionally keeps the
	# new pack a superset of the old for every sibling path we read, so
	# there are no holes for the stale mount to answer.
	# Read directly from each mod archive via ZIPReader rather than via
	# VFS. Going through FileAccess/ResourceLoader would walk every
	# mounted overlay, and a previous-session hook pack is still mounted
	# at this point, its stale copy of these same paths would win and
	# we'd re-emit that stale snapshot into the new hook pack, preventing
	# mod updates from ever taking effect between sessions. The archive
	# path is the original on-disk .zip/.vmz (or cached .zip for .vmz);
	# it always reflects the current mod version.
	var sibling_fixes: Dictionary = {}  # p -> {fixed_src, af, reload_stripped, changed}
	for archive_file: String in _archive_file_sets:
		var paths_set: Dictionary = _archive_file_sets[archive_file]
		var zr: ZIPReader = null
		# Resolve the archive to a readable zip path. Loose folder mods
		# and already-zipped .zip/.pck archives use archive_file as-is;
		# .vmz mods use a cached .zip sibling the loader materialized
		# during discovery (same pattern the rewriter's extends-scanner
		# uses in _scan_mod_extends_targets).
		var zip_path := archive_file
		var ext := archive_file.get_extension().to_lower()
		if ext == "vmz":
			var cache_dir := ProjectSettings.globalize_path(TMP_DIR)
			zip_path = cache_dir.path_join(archive_file.get_file().get_basename() + ".zip")
		elif ext == "folder":
			var folder_zip := ProjectSettings.globalize_path(TMP_DIR).path_join(archive_file.get_file() + "_dev.zip")
			zip_path = folder_zip
		if FileAccess.file_exists(zip_path):
			zr = ZIPReader.new()
			if zr.open(zip_path) != OK:
				zr = null
		for p: String in paths_set:
			if not p.ends_with(".gd"):
				continue
			if p.begins_with("res://Scripts/"):
				continue  # vanilla, handled in the main rewrite loop
			if zr == null:
				# Last-resort fallback: VFS read. Accepts the stale-overlay
				# risk but keeps mods without a resolvable zip working.
				if not ResourceLoader.exists(p):
					continue
				var raw_vfs := FileAccess.get_file_as_string(p)
				if raw_vfs.is_empty():
					continue
				var norm_vfs := raw_vfs.replace("\r\n", "\n").replace("\r", "\n")
				var af_vfs := _rtv_autofix_legacy_syntax(norm_vfs)
				var fixed_vfs: String = af_vfs["source"]
				var rl_vfs := _rtv_strip_helper_reload(fixed_vfs)
				fixed_vfs = rl_vfs["source"]
				sibling_fixes[p] = {
					"fixed_src": fixed_vfs,
					"af": af_vfs,
					"reload_stripped": int(rl_vfs["stripped"]),
					"changed": fixed_vfs != norm_vfs,
				}
				continue
			# Strip the res:// prefix to get the zip-internal entry name.
			var entry := p.trim_prefix("res://")
			if not (entry in zr.get_files()):
				continue
			var bytes := zr.read_file(entry)
			if bytes.is_empty():
				continue
			var raw := bytes.get_string_from_utf8()
			if raw.is_empty():
				continue
			var norm := raw.replace("\r\n", "\n").replace("\r", "\n")
			var af := _rtv_autofix_legacy_syntax(norm)
			var fixed_src: String = af["source"]
			# Strip redundant `.reload()` calls in helpers that also do
			# take_over_path. Eliminates RTVCoop's Cannot-reload spam.
			var rl := _rtv_strip_helper_reload(fixed_src)
			fixed_src = rl["source"]
			sibling_fixes[p] = {
				"fixed_src": fixed_src,
				"af": af,
				"reload_stripped": int(rl["stripped"]),
				"changed": fixed_src != norm,
			}
		if zr != null:
			zr.close()

	var zip_abs := ProjectSettings.globalize_path(pack_zip_rel)
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
	var zero_byte_skipped: int = 0
	var surface_skipped: int = 0
	for script_path: String in script_paths:
		var filename := script_path.get_file()

		if filename in RTV_SKIP_LIST:
			_log_debug("[RTVCodegen] Skipped %s (runtime-sensitive)" % filename)
			continue
		if filename in RTV_RESOURCE_SERIALIZED_SKIP or filename in RTV_RESOURCE_DATA_SKIP:
			continue
		# Skip zero-byte PCK entries (base game ships empty .gd files for
		# some scripts; CasettePlayer.gd in RTV 4.6.1). Detokenize cannot
		# read content that doesn't exist. Not a modloader failure.
		if _pck_zero_byte_paths.has(script_path):
			zero_byte_skipped += 1
			continue
		if not _step_b_allowlist.is_empty() and filename not in _step_b_allowlist:
			continue
		# Wrap-surface filter: no mod extends, take_over_paths, or hooks
		# this script, and it's not a pinned-at-boot class_name. Skipping
		# means the script stays pure vanilla at runtime -- no dispatch
		# overhead, same behavior as v2.1.0 for this path.
		if not needed_paths.has(script_path):
			surface_skipped += 1
			_log_debug("[RTVCodegen] Surface-skip %s (no mod extends/hooks/overrides)" % filename)
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
		#
		# EXCEPTION: scripts with registry injections MUST be force-activated
		# so the injected _rtv_mod_scenes / _rtv_override_scenes / _get()
		# are live on the autoload instance when mods call lib.register().
		# Lazy-compile would leave the autoload running vanilla bytecode.
		# Registry-target scripts don't have the ext_resource staleness
		# problem because mods don't take_over_path them -- they use the
		# registry API instead.
		var scene_preloads := _collect_module_scope_scene_preloads(source)
		if scene_preloads.size() > 0 and not _is_registry_target(filename):
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
	# Write pre-collected sibling autofix results to the hook pack. Reads
	# happened earlier (before zp.open); here we just emit the fixed bytes.
	# Skip any sibling whose path was also packed as a mod subclass earlier
	# in this call -- the mod subclass rewrite is the canonical version,
	# and double-packing would leave two entries in the zip.
	var subclass_paths: Dictionary = {}
	for mp in mod_packed:
		subclass_paths[mp["res_path"]] = true
	var sibling_fixed := 0
	var sibling_carried := 0
	var sibling_total_bodyless := 0
	var sibling_total_reload_stripped := 0
	for p: String in sibling_fixes:
		if subclass_paths.has(p):
			continue
		var fix: Dictionary = sibling_fixes[p]
		var fixed_src: String = fix["fixed_src"]
		var af: Dictionary = fix["af"]
		var reload_stripped: int = int(fix["reload_stripped"])
		var changed: bool = bool(fix["changed"])
		var zip_rel: String = p.trim_prefix("res://")
		if zp.start_file(zip_rel) != OK:
			_log_warning("[Autofix] Failed to pack sibling zip entry %s" % zip_rel)
			continue
		zp.write_file(fixed_src.to_utf8_buffer())
		zp.close_file()
		if changed:
			sibling_fixed += 1
			sibling_total_bodyless += int(af["bodyless"])
			sibling_total_reload_stripped += reload_stripped
			if reload_stripped > 0:
				_log_info("[Autofix] Stripped %d redundant .reload() call(s) from %s -- prevents Cannot-reload-while-instances-exist spam" % [reload_stripped, p])
			_log_info("[Autofix] Patched sibling %s: bodyless=%d tool=%d onready=%d export=%d" \
					% [p, af["bodyless"], af["tool"], af["onready"], af["export"]])
		else:
			sibling_carried += 1
	if sibling_fixed > 0:
		_log_info("[Autofix] %d mod sibling script(s) repaired (%d bodyless blocks, %d reload() stripped) -- packed into hook pack overlay" \
				% [sibling_fixed, sibling_total_bodyless, sibling_total_reload_stripped])
	if sibling_carried > 0:
		_log_debug("[Autofix] Carried %d unchanged mod sibling script(s) forward into new hook pack -- preserves VFS coverage across regen" \
				% sibling_carried)

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
	if zero_byte_skipped > 0:
		_log_info("[RTVCodegen] Skipped %d zero-byte PCK entry(ies) (base game ships empty .gd files -- not hookable, not a modloader failure): %s" \
				% [zero_byte_skipped, ", ".join(_pck_zero_byte_paths.keys())])
	if surface_skipped > 0:
		_log_info("[RTVCodegen] Surface-skipped %d vanilla script(s) with no mod interaction -- they run native (no dispatch overhead)" \
				% surface_skipped)
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
			_persist_hook_pack_state(pack_zip_rel)
		elif ProjectSettings.load_resource_pack(pack_zip_rel, true):
			# STABILITY canary C readback: confirm VFS mount precedence works
			# end-to-end. If the canary file isn't readable with expected
			# content, the hook pack mounted but isn't serving files -- every
			# rewrite will silently fall back to vanilla.
			var canary_got := FileAccess.get_file_as_string("res://__modloader_canary__.txt")
			if canary_got.begins_with("MODLOADER-VFS-CANARY-"):
				_log_info("[STABILITY] VFS canary OK: hook pack mount precedence verified (%s)" % canary_got.strip_edges())
			else:
				_log_critical("[STABILITY] VFS canary FAILED (got '%s', expected MODLOADER-VFS-CANARY-*) -- hook pack mounted but files aren't served. Rewrites will not take effect this session." % canary_got.substr(0, 40))
			_log_info("[RTVCodegen] Generated %d rewritten vanilla script(s), %d hook points -- pack mounted at res:// (%s)" \
					% [script_count, hook_count, pack_zip_rel.get_file()])
			_activate_rewritten_scripts(packed_filenames, pack_zip_rel)
		else:
			_log_critical("[RTVCodegen] Failed to mount hook pack at %s -- rewrites won't load" % zip_abs)
	else:
		_log_info("[RTVCodegen] No scripts rewritten -- no pack mounted")
	return pack_zip_rel

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

func _activate_rewritten_scripts(filenames: Array[String], pack_path: String) -> void:
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
	_persist_hook_pack_state(pack_path)

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

	# Registry smoke probe (runs unconditionally). Verifies tetra's
	# const->dict rewrite + _get() injection on Database actually
	# executed and serves scenes at runtime. Without this, a silent
	# regression in the Database transform would only surface when a
	# mod's lib.register() call returned stale data -- this probe
	# catches it at boot instead.
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

	# 30s gives the player time to get into gameplay so controller-level
	# hooks can fire at least once. HOOK-API summary only by default;
	# dev-mode adds the per-method dispatch counter printout (fed by
	# _dispatch_counts incremented inside each wrapper after the
	# _any_mod_hooked short-circuit -- see _rtv_dispatch_inline_src).
	_dispatch_counts.clear()
	get_tree().create_timer(30.0).timeout.connect(func():
		var pc: Dictionary = Engine.get_meta("_rtv_probe_counts", {})
		var fa: Dictionary = Engine.get_meta("_rtv_probe_first_args", {})
		# Dispatch counts (dev mode only). Show top 15 hot methods + flag
		# any that exceed 10000 calls in 30s -- those are runaway candidates
		# (e.g. a mod's _ready firing in a loop).
		if _developer_mode and _dispatch_counts.size() > 0:
			var pairs: Array = []
			for k: String in _dispatch_counts:
				pairs.append([k, int(_dispatch_counts[k])])
			pairs.sort_custom(func(a, b): return a[1] > b[1])
			_log_info("[RTVCodegen] DISPATCH-COUNT top %d / %d tracked methods (dev mode, 30s window):" \
					% [min(15, pairs.size()), pairs.size()])
			for i in range(min(15, pairs.size())):
				var warn := "  !!HOT!!" if pairs[i][1] > 10000 else ""
				_log_info("[RTVCodegen]   %-48s %d%s" % [pairs[i][0], pairs[i][1], warn])
			# Extra: list any method exceeding the runaway threshold explicitly
			# so "why is the game laggy" is greppable.
			var runaway: Array = []
			for p in pairs:
				if p[1] > 10000:
					runaway.append("%s=%d" % [p[0], p[1]])
			if runaway.size() > 0:
				_log_critical("[RTVCodegen] RUNAWAY methods (>10000 calls/30s): %s -- a mod is likely calling one of these from a loop or frequent callback" % ", ".join(runaway))
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
