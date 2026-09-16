## ----- hook_pack.gd -----
## Opt-in rewrite pipeline. Vanilla scripts declared via [hooks] or .hook()
## calls get their methods renamed to _rtv_vanilla_<name> with dispatch
## wrappers appended, packed into a zip (.gd + .gd.remap + empty .gdc per
## script), mounted at res://, and force-activated. Zero declarations means
## zero generation; mod sources are never rewritten.

# res:// script path -> scene paths; these are deferred from the eager
# load+reload in _activate_rewritten_scripts. Their module-scope preload()
# fires at parse time, so force-loading before mod overrides run would bake
# scenes against pre-override vanilla; deferring to lazy-compile lets
# overrides land first, and VFS precedence still serves the rewrite.
var _scripts_with_scene_preloads: Dictionary = {}

# Scripts with rewriter-injected registry helpers. Force-activated (bypassing
# the scene-preload deferral) so injected fields are live when mods call
# lib.register(). Enrolled only when some mod declares [registry].
const REGISTRY_TARGETS: Array[String] = [
	"Database.gd",
	"Loader.gd",
	"AISpawner.gd",
	"AI.gd",
	"FishPool.gd",
	"Compiler.gd",
]

func _is_registry_target(filename: String) -> bool:
	return filename in REGISTRY_TARGETS

# Post-rewrite markers for registry targets, each emitted only when the
# transform landed (the always-appended appendices do not contain them).
# Transforms are anchored to vanilla source and no-op silently when a game
# update moves the pattern; the marker check turns that into one warning.
# Keep in sync with the dict block in _rtv_rewrite_database_constants, the
# AISpawner call-site rewrite, and the comment line each prelude emits.
const REGISTRY_EXPECTED_MARKERS: Dictionary = {
	"Database.gd": "var _rtv_vanilla_scenes",
	"Loader.gd": "scene_paths registry prelude",
	"AISpawner.gd": "agent = _rtv_resolve_ai_type(",
	"AI.gd": "ai_loadouts registry prelude",
	"FishPool.gd": "fish_species registry prelude",
	"Compiler.gd": "shelters/maps registry prelude",
}

# The wrapped res:// paths pass state records for the next session's static
# init to force-compile. Scripts deferred for a module-scope scene preload
# are left out: static init runs before any mod override, and force-loading
# them there would bake their scenes against pre-override vanilla, the case
# the deferral exists for. They lazy-compile from the mounted pack instead.
func _eager_wrapped_paths(paths: Array[String]) -> PackedStringArray:
	var out := PackedStringArray()
	for p in paths:
		if not _scripts_with_scene_preloads.has(p):
			out.append(p)
	return out

# Canary C helper. Detokenizes the first probe script with GDSC bytes and
# checks structural indentation, through _detokenize_script so a pristine
# cache cannot mask a broken detokenizer. True when no probe could be read.
func _canary_detokenizer_roundtrip_ok() -> bool:
	var probe_paths := ["res://Scripts/Camera.gd", "res://Scripts/Controller.gd",
			"res://Scripts/Audio.gd", "res://Scripts/AI.gd"]
	for p in probe_paths:
		# Byte pre-check so missing paths don't spam warnings from _detokenize_script.
		var raw := FileAccess.get_file_as_bytes(p)
		if raw.size() < 12:
			raw = FileAccess.get_file_as_bytes(p.replace(".gd", ".gdc"))
		if raw.size() < 12 or raw.slice(0, 4).get_string_from_ascii() != _GDSC_MAGIC:
			continue
		var source := _detokenize_script(p)
		if source.is_empty():
			continue
		return _source_has_indented_func_body(source)
	return true

# True when a colon-terminated func is followed by a tab-indented body line.
# Guards _indent_from_column's `col / 4`, which assumes 4-space vanilla source.
func _source_has_indented_func_body(source: String) -> bool:
	var lines := source.split("\n")
	for i in range(lines.size() - 1):
		var line := lines[i]
		if not (line.begins_with("func ") or line.begins_with("static func ")):
			continue
		if not line.strip_edges(false, true).ends_with(":"):
			continue
		for j in range(i + 1, lines.size()):
			var body := lines[j]
			if body.strip_edges().is_empty():
				continue
			if body.begins_with("\t"):
				return true
			break  # non-empty, unindented body -- keep scanning other funcs
	return false

# Build the framework pack: enumerate res://Scripts/*.gd, detokenize, parse,
# generate wrappers, zip, mount. The zip mounts at res://: extends-chain
# resolution for class_name parents breaks for scripts loaded from user://.
func _generate_hook_pack(defer_activation: bool = false) -> String:
	# Repopulated only here; a stale entry would skew the eager/deferred accounting.
	_scripts_with_scene_preloads.clear()
	var hook_dir := ProjectSettings.globalize_path(HOOK_PACK_DIR)
	DirAccess.make_dir_recursive_absolute(hook_dir)
	# Per-call unique filename; load_resource_pack dedupes by path and would serve stale offsets.
	var pack_zip_rel := HOOK_PACK_DIR.path_join("%s_%d.zip" % [HOOK_PACK_PREFIX, Time.get_ticks_msec()])
	# Do not delete the old hook pack zip: a previous session's mount still
	# holds a VFS handle to it, and every read through that overlay would fail.
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

	# Canary B: refuse an unsupported GDSC tokenizer format with one message.
	var tok_version := _probe_gdsc_version()
	if tok_version != -1 and tok_version != GDSC_VERSION_V100 and tok_version != GDSC_VERSION_V101:
		_log_critical("[STABILITY] Unsupported GDSC tokenizer v%d on Godot %s. This ModLoader supports v100 (Godot 4.3-4.4) and v101 (Godot 4.5-4.6). Hook pack generation disabled -- script hooks will not fire. See README for supported Godot versions." \
				% [tok_version, Engine.get_version_info().get("string", "unknown")])
		_hook_status_write({"state": HOOK_STATE_UNSUPPORTED_GDSC, "gdsc_version": tok_version})
		return ""
	if tok_version != -1:
		_log_info("[STABILITY] Detokenizer compatible: GDSC v%d on Godot %s" \
				% [tok_version, Engine.get_version_info().get("string", "unknown")])

	if _loaded_mod_ids.is_empty():
		# Nothing to rewrite is healthy; a stale failure record must not outlive the mods.
		_hook_status_write({"state": HOOK_STATE_OK, "attempted": 0})
		return ""

	# Canary C: round-trip one vanilla script through the detokenizer and check
	# the indentation. The version integer can stay 101 while column semantics
	# change, and a reindented game breaks `col / 4` without touching it. After
	# the no-mods short-circuit, and gated on tok_version != -1 like canary B.
	if tok_version != -1 and not _canary_detokenizer_roundtrip_ok():
		_log_critical("[STABILITY] Detokenized vanilla source failed the indentation sanity check on Godot %s (GDSC version is still %d). Two known causes: the .gdc column format changed, or the game's scripts are no longer indented with 4 spaces per level -- _indent_from_column's `col / 4` depends on that. See the note above _indent_from_column in gdsc_detokenizer.gd. Hook pack generation disabled -- script hooks will not fire. Update the ModLoader to a version that supports this game build." \
				% [Engine.get_version_info().get("string", "unknown"), tok_version])
		_hook_status_write({"state": HOOK_STATE_DETOK_FAILED, "gdsc_version": tok_version})
		return ""

	# Opt-in gate: user mods run against unmodified vanilla unless one declares
	# [hooks], .hook() or [registry]. Captured before _seed_core_hooks adds the
	# core Menu.gd wrap; a modlist that declares nothing gets only that wrap.
	var user_wrap_empty: bool = _hooked_methods.is_empty() and not _any_mod_declared_registry

	_seed_core_hooks()

	if user_wrap_empty:
		_log_info("[RTVCodegen] No user opt-in declarations ([hooks] / .hook() / [registry]) -- user mods' vanilla targets run unmodified (v2.1.0-equivalent). Pack contains core hooks only.")

	var script_paths: Array[String] = _enumerate_game_scripts()
	if script_paths.is_empty():
		_log_warning("[RTVCodegen] script enumeration failed -- falling back to class_name list (%d)" % _class_name_to_path.size())
		for path: String in _class_name_to_path.values():
			script_paths.append(path)
	# A vanilla script enters needed_paths only via a [hooks] declaration, a
	# literal .hook() call, or REGISTRY_TARGETS when some mod declares
	# [registry]. No inference from extends or take_over_path. The enumerated set
	# validates declared paths: a typo would otherwise silently no-op.
	var vanilla_path_set: Dictionary = {}
	for sp: String in script_paths:
		vanilla_path_set[sp] = true
	var needed_paths: Dictionary = {}
	# Per-path method mask: res_path -> {method_name: true}. An empty inner dict
	# means wrap all methods (the "[hooks] <path> = *" wildcard and REGISTRY_TARGETS).
	var hook_mask: Dictionary = {}
	# Reconciliation ledger, one entry per declared target: {declared, methods,
	# status: pending -> wrapped|lost, detail, missing_methods}.
	var reconcile: Dictionary = {}
	for path: String in _hooked_methods:
		var rec: Dictionary = {
			"declared": "[hooks]/.hook()",
			"methods": (_hooked_methods[path] as Dictionary).keys(),
			"status": "pending",
			"detail": "",
			"missing_methods": [],
		}
		reconcile[path] = rec
		# Hooks only apply to vanilla scripts; a bad path is a silent failure, so record it.
		if not path.begins_with("res://Scripts/"):
			rec["status"] = "lost"
			rec["detail"] = "non-vanilla path -- only res://Scripts/*.gd is hookable"
			_log_debug("[RTVCodegen] [hooks] declared for non-vanilla path '%s' -- entry ignored (reported by reconciliation)" % path)
			continue
		if not vanilla_path_set.has(path):
			rec["status"] = "lost"
			rec["detail"] = "no vanilla script at this path (typo, or the game renamed/removed it)"
			_log_debug("[RTVCodegen] [hooks] declared path '%s' doesn't match any vanilla script (reported by reconciliation)" % path)
			# Still enroll it; the ledger reports the loss once.
		needed_paths[path] = true
		hook_mask[path] = (_hooked_methods[path] as Dictionary).duplicate()
	# REGISTRY_TARGETS wrap whole-script so the rewriter can inject the registry helpers.
	if _any_mod_declared_registry:
		for rt_filename in REGISTRY_TARGETS:
			var rt_path := "res://Scripts/" + rt_filename
			needed_paths[rt_path] = true
			hook_mask.erase(rt_path)  # whole-script wrap, no mask
			if reconcile.has(rt_path):
				# Also declared via [hooks]: registry opt-in widens it to a wildcard.
				(reconcile[rt_path] as Dictionary)["declared"] = "[hooks]+[registry]"
				(reconcile[rt_path] as Dictionary)["methods"] = []
				(reconcile[rt_path] as Dictionary)["status"] = "pending"
				(reconcile[rt_path] as Dictionary)["detail"] = ""
			else:
				reconcile[rt_path] = {
					"declared": "[registry]",
					"methods": [],
					"status": "pending",
					"detail": "",
					"missing_methods": [],
				}
			if not vanilla_path_set.has(rt_path):
				(reconcile[rt_path] as Dictionary)["status"] = "lost"
				(reconcile[rt_path] as Dictionary)["detail"] = "registry target not found among enumerated vanilla scripts"
	_log_info("[RTVCodegen] Wrap surface: %d vanilla script(s) declared (%d via [hooks]/.hook(), %d via [registry])" % [
		needed_paths.size(),
		_hooked_methods.size(),
		REGISTRY_TARGETS.size() if _any_mod_declared_registry else 0,
	])
	_log_debug("[RTVCodegen] Skip lists: %d runtime-sensitive, %d data, %d serialized (total %d skipped from rewrite)" % [
		RTV_SKIP_LIST.size(),
		RTV_RESOURCE_DATA_SKIP.size(),
		RTV_RESOURCE_SERIALIZED_SKIP.size(),
		RTV_SKIP_LIST.size() + RTV_RESOURCE_DATA_SKIP.size() + RTV_RESOURCE_SERIALIZED_SKIP.size(),
	])

	# Pre-read mod sibling scripts before opening ZIPPacker: the previous
	# session's mounted pack holds a FileAccessZIP handle to this file, and
	# opening it for write invalidates that handle on Windows. Emit every
	# sibling, not just changed ones, so the new pack stays a superset of the
	# old for every sibling path. Read from each mod archive via ZIPReader, not
	# the VFS, where the stale old pack would win and mod updates never land.
	var sibling_fixes: Dictionary = {}  # p -> {fixed_src, af, reload_stripped, changed}
	for archive_file: String in _archive_file_sets:
		var paths_set: Dictionary = _archive_file_sets[archive_file]
		var zr: ZIPReader = null
		# The same readable archive path the claim scan opened (folder mods: the re-zipped _dev.zip).
		var zip_path: String = str(_archive_zip_paths.get(archive_file, ""))
		if zip_path != "" and FileAccess.file_exists(zip_path):
			zr = ZIPReader.new()
			if zr.open(zip_path) != OK:
				zr = null
		for p: String in paths_set:
			if not p.ends_with(".gd"):
				continue
			if p.begins_with("res://Scripts/"):
				continue  # vanilla, handled in the main rewrite loop
			if zr == null:
				# Last resort: a VFS read, accepting the stale-overlay risk.
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
			# Strip redundant .reload() in helpers that also take_over_path.
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
	var pack_write_failed := false

	var script_count := 0
	var hook_count := 0
	var packed_paths: Array[String] = []
	var zero_byte_skipped: int = 0
	var surface_skipped: int = 0
	for script_path: String in script_paths:
		var filename := script_path.get_file()
		# Ledger entry when a mod declared this path; empty dict otherwise.
		var rec_v: Dictionary = reconcile.get(script_path, {}) as Dictionary

		# Skip lists win over declarations, but a declared hook must not be lost silently.
		if filename in RTV_SKIP_LIST:
			if not rec_v.is_empty() and rec_v["status"] == "pending":
				rec_v["status"] = "lost"
				rec_v["detail"] = "on the runtime-sensitive skip list (wrapping is known to break this script; hooks here are not supported)"
				_log_warning("[RTVCodegen] %s declares hooks on %s, but that script is excluded from rewriting (runtime-sensitive skip list) -- those hooks can never fire" \
						% [_hook_declarers_label(script_path), filename])
			_log_debug("[RTVCodegen] Skipped %s (runtime-sensitive)" % filename)
			continue
		if filename in RTV_RESOURCE_SERIALIZED_SKIP or filename in RTV_RESOURCE_DATA_SKIP:
			if not rec_v.is_empty() and rec_v["status"] == "pending":
				rec_v["status"] = "lost"
				rec_v["detail"] = "a save-data/resource-data class (skip-listed; hook the call sites instead)"
				_log_warning("[RTVCodegen] %s declares hooks on %s, but data/save resource classes are excluded from rewriting -- those hooks can never fire (hook the call sites instead)" \
						% [_hook_declarers_label(script_path), filename])
			continue
		# Zero-byte PCK entries have nothing to detokenize.
		if _pck_zero_byte_paths.has(script_path):
			zero_byte_skipped += 1
			if not rec_v.is_empty() and rec_v["status"] == "pending":
				rec_v["status"] = "lost"
				rec_v["detail"] = "the game ships this script as a zero-byte file -- nothing to hook"
			continue
		# Not in the wrap surface: stays pure vanilla, no dispatch overhead.
		if not needed_paths.has(script_path):
			surface_skipped += 1
			_log_debug("[RTVCodegen] Surface-skip %s (no mod extends/hooks/overrides)" % filename)
			continue

		# A mod's [script_extend] / [script_overrides] replacement at this path
		# loses to the rewrite: activation reloads the vanilla path with the
		# rewritten source. Say so here, once per path, and again when it happens.
		var claimants := _override_claimants(script_path)
		if not claimants.is_empty():
			_log_warning("[RTVCodegen] %s is rewritten for hooks and also replaced by %s -- the rewrite wins at that path, so the replacement will not run this session. Hook the methods instead ([hooks] or .hook()), or drop the replacement." \
					% [script_path, ", ".join(claimants)])

		var source := _read_vanilla_source(script_path)
		if source.is_empty():
			_log_debug("[RTVCodegen] Empty detokenized source for %s -- skipped (reported by reconciliation)" % script_path)
			if not rec_v.is_empty() and rec_v["status"] == "pending":
				rec_v["status"] = "lost"
				rec_v["detail"] = "detokenizer produced no source for this script (game build mismatch?)"
			continue

		var parsed := _rtv_parse_script(filename, source)
		# No mask entry = wrap every hookable method; with a mask, only declared ones.
		var path_mask: Dictionary = hook_mask.get(script_path, {}) as Dictionary
		var apply_mask: bool = not path_mask.is_empty()
		# Track which declared methods matched so a partial miss is reported per method.
		var matched_names: Array[String] = []
		var matched_mask_keys: Dictionary = {}
		for fe in parsed["functions"]:
			if fe["is_static"]:
				continue
			# Mask keys are lowercased; vanilla names keep source casing, so compare case-insensitively.
			if apply_mask:
				var mask_key: String = str(fe["name"]).to_lower()
				if not path_mask.has(mask_key):
					continue
				matched_mask_keys[mask_key] = true
			matched_names.append(str(fe["name"]))
		var hookable_count := matched_names.size()
		if hookable_count == 0:
			if not rec_v.is_empty() and rec_v["status"] == "pending":
				rec_v["status"] = "lost"
				rec_v["detail"] = ("declared method(s) %s not found in the vanilla script (check spelling/casing)" % str(path_mask.keys())) \
						if apply_mask else "no hookable (non-static, parseable) method found in the vanilla script"
			_log_debug("[RTVCodegen] %s: nothing hookable under the current mask -- skipping (reported by reconciliation)" % filename)
			continue
		if apply_mask:
			var missing_partial: Array = []
			for mk: String in path_mask:
				if not matched_mask_keys.has(mk):
					missing_partial.append(mk)
			if not rec_v.is_empty() and missing_partial.size() > 0:
				rec_v["missing_methods"] = missing_partial

		# Scripts with module-scope PackedScene preloads are deferred from eager
		# activation (see _activate_rewritten_scripts), except registry targets,
		# whose injected fields must be live when mods call lib.register().
		var scene_preloads := _collect_module_scope_scene_preloads(source)
		if scene_preloads.size() > 0 and not _is_registry_target(filename):
			_scripts_with_scene_preloads[script_path] = scene_preloads

		var rewritten := _rtv_rewrite_vanilla_source(source, parsed, path_mask)
		# Rename check: the parser and the rename pass find methods two different
		# ways; any divergence silently produces a wrapper-less rewrite.
		var renamed_set: Dictionary = {}
		for rl: String in rewritten.split("\n"):
			if not rl.begins_with("func _rtv_vanilla_"):
				continue
			var name_tail := rl.substr(18)  # len("func _rtv_vanilla_") == 18
			var name_len := 0
			while name_len < name_tail.length() and _rtv_is_ident_char(name_tail[name_len]):
				name_len += 1
			if name_len > 0:
				renamed_set[name_tail.substr(0, name_len)] = true
		var rename_lost: Array = []
		for mn: String in matched_names:
			if not renamed_set.has(mn):
				rename_lost.append(mn)
		if rename_lost.size() > 0 and not rec_v.is_empty():
			var mm: Array = rec_v.get("missing_methods", []) as Array
			for rn in rename_lost:
				mm.append(str(rn) + " (parsed but rename did not land)")
			rec_v["missing_methods"] = mm
		# Registry markers: anchored transforms no-op silently when the game
		# changes; the marker check records the loss for reconciliation.
		if _any_mod_declared_registry and _is_registry_target(filename):
			var marker := str(REGISTRY_EXPECTED_MARKERS.get(filename, ""))
			if marker == "":
				# Target missing from REGISTRY_EXPECTED_MARKERS: its transform is unverified.
				_log_warning("[RTVCodegen] %s is a REGISTRY_TARGET with no REGISTRY_EXPECTED_MARKERS entry -- its registry transform is unverified; add a marker (see the keep-in-sync note at the const)" % filename)
			elif not (marker in rewritten):
				if not rec_v.is_empty():
					var mm2: Array = rec_v.get("missing_methods", []) as Array
					mm2.append("registry transform (marker '%s' absent -- registry features on this script will not work)" % marker)
					rec_v["missing_methods"] = mm2
				else:
					# Registry targets are always in the ledger, so this is defensive.
					_log_warning("[RTVCodegen] %s: registry transform marker '%s' missing from rewrite -- registry features on this script will not work (game update changed the vanilla pattern?)" % [filename, marker])
		# Ship at the original vanilla path: the class_name registration in the PCK's
		# class cache must match, or pre-compiled scripts throw "Class X hides a global script class".
		var gd_entry := script_path.trim_prefix("res://")
		if zp.start_file(gd_entry) != OK:
			_log_warning("[RTVCodegen] Failed to start zip entry %s" % gd_entry)
			pack_write_failed = true
			if not rec_v.is_empty() and rec_v["status"] == "pending":
				rec_v["status"] = "lost"
				rec_v["detail"] = "zip write failed (disk full / I/O error?)"
			continue
		if zp.write_file(rewritten.to_utf8_buffer()) != OK:
			pack_write_failed = true
		# close_file flushes the entry; an unchecked I/O error would ship a truncated pack.
		if zp.close_file() != OK:
			pack_write_failed = true
		# Self-referencing .gd.remap overrides the PCK's .gd.remap -> .gdc
		# redirect. Godot's _path_remap reads this before the GDScript loader.
		var remap_entry := gd_entry + ".remap"
		if zp.start_file(remap_entry) != OK:
			_log_warning("[RTVCodegen] Failed to start zip entry %s" % remap_entry)
			pack_write_failed = true
			if not rec_v.is_empty() and rec_v["status"] == "pending":
				rec_v["status"] = "lost"
				rec_v["detail"] = "zip write failed (disk full / I/O error?)"
			continue
		var remap_body := "[remap]\npath=\"%s\"\n" % script_path
		if zp.write_file(remap_body.to_utf8_buffer()) != OK:
			pack_write_failed = true
		if zp.close_file() != OK:
			pack_write_failed = true
		# Empty .gdc shadows the PCK's bytecode: the loader prefers a sibling .gdc
		# even after the remap, cannot parse empty bytecode, and falls back to the .gd.
		var gdc_entry := gd_entry.substr(0, gd_entry.length() - 3) + ".gdc"
		if zp.start_file(gdc_entry) != OK:
			_log_warning("[RTVCodegen] Failed to start zip entry %s" % gdc_entry)
			pack_write_failed = true
			if not rec_v.is_empty() and rec_v["status"] == "pending":
				rec_v["status"] = "lost"
				rec_v["detail"] = "zip write failed (disk full / I/O error?)"
			continue
		if zp.write_file(PackedByteArray()) != OK:
			pack_write_failed = true
		if zp.close_file() != OK:
			pack_write_failed = true

		script_count += 1
		hook_count += hookable_count * 4  # pre/post/callback/replace per method
		packed_paths.append(script_path)
		if not rec_v.is_empty() and rec_v["status"] == "pending":
			rec_v["status"] = "wrapped"
			rec_v["detail"] = "%d method(s) wrapped" % hookable_count
			rec_v["wrapped_count"] = hookable_count
		_log_debug("[RTVCodegen] Rewrote %s (%d hooks)" % [script_path, hookable_count * 4])

	# Mod scripts are never rewritten: a mod extending a wrapped vanilla
	# composes through Godot's extends resolution. Sibling autofix only repairs
	# legacy syntax so preloaded/extended siblings parse; it never injects dispatch.
	var sibling_fixed := 0
	var sibling_carried := 0
	var sibling_total_bodyless := 0
	var sibling_total_reload_stripped := 0
	for p: String in sibling_fixes:
		var fix: Dictionary = sibling_fixes[p]
		var fixed_src: String = fix["fixed_src"]
		var af: Dictionary = fix["af"]
		var reload_stripped: int = int(fix["reload_stripped"])
		var changed: bool = bool(fix["changed"])
		var zip_rel: String = p.trim_prefix("res://")
		if zp.start_file(zip_rel) != OK:
			_log_warning("[Autofix] Failed to pack sibling zip entry %s" % zip_rel)
			pack_write_failed = true
			continue
		if zp.write_file(fixed_src.to_utf8_buffer()) != OK:
			pack_write_failed = true
		if zp.close_file() != OK:
			pack_write_failed = true
		if changed:
			sibling_fixed += 1
			sibling_total_bodyless += int(af["bodyless"])
			sibling_total_reload_stripped += reload_stripped
			if reload_stripped > 0:
				_log_debug("[Autofix] Stripped %d redundant .reload() call(s) from %s -- prevents Cannot-reload-while-instances-exist spam" % [reload_stripped, p])
			_log_debug("[Autofix] Patched sibling %s: bodyless=%d tool=%d onready=%d export=%d" \
					% [p, af["bodyless"], af["tool"], af["onready"], af["export"]])
		else:
			sibling_carried += 1
	if sibling_fixed > 0:
		_log_info("[Autofix] %d mod sibling script(s) repaired (%d bodyless blocks, %d reload() stripped) -- packed into hook pack overlay" \
				% [sibling_fixed, sibling_total_bodyless, sibling_total_reload_stripped])
	if sibling_carried > 0:
		_log_debug("[Autofix] Carried %d unchanged mod sibling script(s) forward into new hook pack -- preserves VFS coverage across regen" \
				% sibling_carried)

	# VFS-precedence canary: a known-content file that must read back after mount.
	var canary_content := "MODLOADER-VFS-CANARY-" + pack_zip_rel.get_file()
	if zp.start_file("__modloader_canary__.txt") == OK:
		if zp.write_file(canary_content.to_utf8_buffer()) != OK:
			pack_write_failed = true
		if zp.close_file() != OK:
			pack_write_failed = true
	else:
		pack_write_failed = true

	if zp.close() != OK:
		pack_write_failed = true

	if pack_write_failed:
		DirAccess.remove_absolute(zip_abs)
		_log_critical("[RTVCodegen] Hook pack write failed (disk full / I/O error?) at %s -- pack discarded, hooks disabled this session, running vanilla" % zip_abs)
		return ""

	# Mount before mod autoloads run and before any scene compiles against the
	# rewritten scripts. replace_files=true is the default, passed explicitly.
	if zero_byte_skipped > 0:
		_log_debug("[RTVCodegen] Skipped %d zero-byte PCK entry(ies) (base game ships empty .gd files -- not hookable, not a modloader failure): %s" \
				% [zero_byte_skipped, ", ".join(_pck_zero_byte_paths.keys())])
	if surface_skipped > 0:
		_log_debug("[RTVCodegen] Surface-skipped %d vanilla script(s) with no mod interaction -- they run native (no dispatch overhead)" \
				% surface_skipped)
	# Any entry still pending was never visited: a declared path missing from the enumeration.
	for rp: String in reconcile:
		var pending_rec: Dictionary = reconcile[rp]
		if pending_rec.get("status", "") == "pending":
			pending_rec["status"] = "lost"
			if str(pending_rec.get("detail", "")) == "":
				pending_rec["detail"] = "never reached the rewrite loop (not in the enumerated vanilla script list)"
	# Reconciliation: declared vs packed; pack-level failures already discarded the pack.
	_log_hook_reconciliation(reconcile)
	if script_count > 0:
		if defer_activation:
			# Pass 1 pre-restart: write the zip and persist pass_state so Pass 2's static
			# init mounts it on a fresh engine; activating here would fire a false alarm.
			_log_info("[RTVCodegen] Generated %d rewritten vanilla script(s), %d hook points -- activation deferred to Pass 2 fresh engine" \
					% [script_count, hook_count])
			_persist_hook_pack_state(pack_zip_rel, _eager_wrapped_paths(packed_paths))
		elif ProjectSettings.load_resource_pack(pack_zip_rel, true):
			var canary_got := FileAccess.get_file_as_string("res://__modloader_canary__.txt")
			if canary_got.strip_edges() != canary_content:
				# Activating anyway would leave a half-modded state; not persisting means
				# the next launch regenerates instead of remounting this broken pack.
				_log_critical("[STABILITY] VFS canary FAILED (got '%s', expected '%s') -- hook pack mounted but files aren't served. Skipping activation: script hooks will not fire this session, vanilla scripts run. Pack state not persisted; next launch regenerates." % [canary_got.substr(0, 40), canary_content])
				return ""
			_log_info("[STABILITY] VFS canary OK: hook pack mount precedence verified (%s)" % canary_got.strip_edges())
			_log_info("[RTVCodegen] Generated %d rewritten vanilla script(s), %d hook points -- pack mounted at res:// (%s)" \
					% [script_count, hook_count, pack_zip_rel.get_file()])
			_activate_rewritten_scripts(packed_paths, pack_zip_rel)
		else:
			_log_critical("[RTVCodegen] Failed to mount hook pack at %s -- script hooks will not fire this session, vanilla scripts run. Next launch regenerates the pack." % zip_abs)
			return ""
	else:
		_log_info("[RTVCodegen] No scripts rewritten -- no pack mounted")
	return pack_zip_rel

# "ModA, ModB" for the mods that declared hooks on a path; empty for add_hook() callers.
func _hook_declarers_label(path: String) -> String:
	var by: Dictionary = _hook_declared_by.get(path, {}) as Dictionary
	if not by.is_empty():
		var names := PackedStringArray()
		for n in by:
			names.append(str(n))
		return ", ".join(names)
	if path == _MENU_SCRIPT_PATH:
		return "the mod loader itself (core hook)"
	return "a mod (declared at runtime via add_hook)"

# End-of-generation reconciliation: one info line on success, a critical
# block per lost target, a warning per partially wrapped script. No I/O.
func _log_hook_reconciliation(reconcile: Dictionary) -> void:
	if reconcile.is_empty():
		return
	var wrapped_scripts := 0
	var wrapped_methods := 0
	var declared_scripts := reconcile.size()
	var lost_lines: PackedStringArray = []
	var partial_lines: PackedStringArray = []
	for path: String in reconcile:
		var rec: Dictionary = reconcile[path] as Dictionary
		var status := str(rec.get("status", "?"))
		var detail := str(rec.get("detail", ""))
		var methods: Array = rec.get("methods", []) as Array
		var methods_label := "* (all methods)"
		if not methods.is_empty():
			var psa := PackedStringArray()
			for m in methods:
				psa.append(str(m))
			methods_label = ", ".join(psa)
		_log_debug("[RTVCodegen] reconcile %s :: %s [%s] -> %s%s" \
				% [path, methods_label, str(rec.get("declared", "?")), status,
					(" (" + detail + ")") if detail != "" else ""])
		if status == "wrapped":
			wrapped_scripts += 1
			wrapped_methods += int(rec.get("wrapped_count", 0))
			var mm: Array = rec.get("missing_methods", []) as Array
			if mm.size() > 0:
				var mpsa := PackedStringArray()
				for m2 in mm:
					mpsa.append(str(m2))
				partial_lines.append("%s (declared by %s): wrapped, but missing: %s" \
						% [path.get_file(), _hook_declarers_label(path), ", ".join(mpsa)])
		else:
			lost_lines.append("%s :: %s (declared by %s via %s) -- %s" \
					% [path.get_file(), methods_label, _hook_declarers_label(path),
						str(rec.get("declared", "?")), detail if detail != "" else "unknown reason"])
	if lost_lines.is_empty() and partial_lines.is_empty():
		_log_info("[RTVCodegen] Hook reconciliation OK: %d/%d declared script target(s) wrapped (%d method wrapper(s)) -- nothing lost between declaration and pack" \
				% [wrapped_scripts, declared_scripts, wrapped_methods])
		return
	if lost_lines.size() > 0:
		_log_critical("[RTVCodegen] Hook reconciliation: %d of %d declared hook target(s) did NOT make it into the hook pack -- these hooks will never fire:" \
				% [lost_lines.size(), declared_scripts])
		for ll in lost_lines:
			_log_critical("[RTVCodegen]   LOST %s" % ll)
	for pl in partial_lines:
		_log_warning("[RTVCodegen]   PARTIAL %s" % pl)
	if wrapped_scripts > 0:
		_log_info("[RTVCodegen] Hook reconciliation: the other %d declared script target(s) wrapped OK (%d method wrapper(s))" \
				% [wrapped_scripts, wrapped_methods])

## Names of the mods whose [script_extend] / [script_overrides] replacement
## targets script_path, from the override registry, the applied set and the pending list.
func _override_claimants(script_path: String) -> PackedStringArray:
	var names := PackedStringArray()
	if _override_registry.has(script_path):
		for claim in _override_registry[script_path]:
			var n := str((claim as Dictionary).get("mod_name", ""))
			if n != "" and not names.has(n):
				names.append(n)
	for entry in _pending_script_overrides:
		if str((entry as Dictionary).get("vanilla_path", "")) == script_path:
			var n := str((entry as Dictionary).get("mod_name", "")) + " [script_overrides]"
			if not names.has(n):
				names.append(n)
	if _applied_script_overrides.has(script_path) and names.is_empty():
		names.append("a mod's [script_overrides] entry")
	return names


# Force the ResourceCache entry for each rewritten vanilla path to the
# rewritten source. Scene ext_resources and ClassName.new() resolve through
# the cache, so a stale entry means the wrappers never fire. source_code +
# reload() recompiles the cached script in place; live references keep working.
func _activate_rewritten_scripts(filenames: Array[String], pack_path: String) -> void:
	# Scripts with module-scope PackedScene preloads are deferred from eager
	# load+reload: loading them now would bake scene Script ext_resources to
	# pre-override vanilla, and a later take_over_path leaves those refs
	# empty-path. VFS mount precedence still serves the rewrite at lazy compile.
	var deferred: PackedStringArray = []
	for fname: String in filenames:
		if _scripts_with_scene_preloads.has(fname):
			deferred.append(fname)
	if deferred.size() > 0:
		_log_info("[RTVCodegen] DEFER %d script(s) with module-scope scene preload -- will lazy-compile via VFS after mod overrides: %s" \
				% [deferred.size(), ", ".join(Array(deferred))])
		# Deferred-script watchdog, one shot at 60s: if VFS precedence regresses, a
		# deferred script compiles from PCK bytecode and its hooks die silently.
		# Inspects only scripts already loaded and walks the base-script chain.
		var deferred_watch := deferred.duplicate()
		get_tree().create_timer(60.0).timeout.connect(func():
			var live_cnt := 0
			var wrong: PackedStringArray = []
			var untouched: PackedStringArray = []
			for dp in deferred_watch:
				var dps := String(dp)
				if not ResourceLoader.has_cached(dps):
					untouched.append(dps.get_file())
					continue
				var ds := load(dps) as GDScript
				var ok := false
				var chain := ds
				var depth := 0
				while chain != null and depth < 8 and not ok:
					for m in chain.get_script_method_list():
						if str(m.get("name", "")).begins_with("_rtv_vanilla_"):
							ok = true
							break
					chain = chain.get_base_script() as GDScript
					depth += 1
				if ok:
					live_cnt += 1
				else:
					wrong.append(dps.get_file())
			if wrong.size() > 0:
				_log_critical("[STABILITY] DEFER-VERIFY (60s): %d deferred script(s) lazy-compiled WITHOUT the rewrite -- VFS did not serve the hook pack for: %s. Hooks on these will not fire this session." \
						% [wrong.size(), ", ".join(wrong)])
			elif untouched.size() > 0:
				_log_debug("[RTVCodegen] DEFER-VERIFY (60s): %d/%d deferred rewrite(s) live; %d not yet loaded by game code (normal until their scenes are used): %s" \
						% [live_cnt, deferred_watch.size(), untouched.size(), ", ".join(untouched)])
			else:
				_log_debug("[RTVCodegen] DEFER-VERIFY (60s): all %d deferred rewrite(s) lazy-compiled with hooks live" % live_cnt)
		)

	# Pre-activation classification, dev-mode only: rewrite live from static
	# init, source matches but methods do not, empty source (bytecode), or other.
	if _developer_mode:
		var pre_a := 0
		var pre_b := 0
		var pre_c := 0
		var pre_d := 0
		var pre_b_names: PackedStringArray = []
		var pre_c_names: PackedStringArray = []
		for fname: String in filenames:
			if _scripts_with_scene_preloads.has(fname):
				continue
			var vp := fname
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
		_log_debug("[RTVCodegen] PRE-ACTIVATE summary: inline-live=%d, pinned-with-source=%d, pinned-tokenized=%d, other=%d / total=%d" \
				% [pre_a, pre_b, pre_c, pre_d, filenames.size()])
		if pre_b > 0:
			_log_debug("[RTVCodegen]   pinned-with-source (GDScriptCache has our text but compiled methods are vanilla): %s" \
					% ", ".join(Array(pre_b_names).slice(0, 25)))
		if pre_c > 0:
			_log_debug("[RTVCodegen]   pinned-tokenized (PCK .gdc, our static-init preload missed): %s" \
					% ", ".join(Array(pre_c_names).slice(0, 25)))

	var activated := 0
	var preactivated := 0
	for fname: String in filenames:
		if _scripts_with_scene_preloads.has(fname):
			continue
		var vp := fname
		var cached := load(vp) as GDScript
		if cached == null:
			_log_warning("[RTVCodegen] activate %s: load returned null -- skip" % vp)
			continue
		# Overrides are applied before the pack is generated, so load() may return
		# a mod's replacement; the reload below overwrites it with the rewrite.
		var displaced := _override_claimants(vp)
		if not displaced.is_empty():
			_log_warning("[RTVCodegen] activate %s: replacing the script installed by %s with the rewritten vanilla script -- that replacement will not run this session" \
					% [vp, ", ".join(displaced)])

		# Static-init preload already put the rewrite in this cached script: skip
		# the reload, which would fail on autoload-backed scripts. A newer loader's
		# rewriter output can differ, so compare source_code and reload on divergence.
		var already_live := false
		for m in cached.get_script_method_list():
			if str(m["name"]).begins_with("_rtv_vanilla_"):
				already_live = true
				break
		if already_live:
			var fresh_source := FileAccess.get_file_as_string(vp)
			if not fresh_source.is_empty() and fresh_source != cached.source_code:
				_log_info("[RTVCodegen] activate %s: cached rewrite is stale (static-init had an older pack), forcing fresh+take_over_path" % vp)
				var fresh := ResourceLoader.load(vp, "", ResourceLoader.CACHE_MODE_IGNORE) as GDScript
				if fresh == null:
					_log_critical("[RTVCodegen] activate %s: fresh load returned null -- skip" % vp)
					continue
				fresh.take_over_path(vp)
				# Report-only rename check (take_over already happened).
				var stale_fresh_ok := false
				for m in fresh.get_script_method_list():
					if str(m["name"]).begins_with("_rtv_vanilla_"):
						stale_fresh_ok = true
						break
				if not stale_fresh_ok:
					_log_critical("[RTVCodegen] activate %s: fresh load lacks _rtv_vanilla_ renames -- rewrite isn't compiling; hooks on this script will not fire" % vp)
				activated += 1
				continue
			preactivated += 1
			activated += 1
			continue

		# Otherwise mutate source_code and reload (compiled from source, no rewrite yet).
		var our_source := FileAccess.get_file_as_string(vp)
		if our_source.is_empty():
			_log_warning("[RTVCodegen] activate %s: FileAccess returned empty -- skip" % vp)
			continue
		cached.source_code = our_source
		var err := cached.reload()
		if err != OK:
			_log_warning("[RTVCodegen] activate %s: reload failed (%s)" % [vp, error_string(err)])
		# Verify the reload took: scripts originally compiled from .gdc do not
		# re-parse mutated source_code. Fall back to CACHE_MODE_IGNORE + take_over_path.
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
	# Denominator uses `deferred`, not the raw dict, so a stray entry cannot mask a miss.
	var eager_total := filenames.size() - deferred.size()
	_log_info("[RTVCodegen] Activated %d/%d rewritten script(s) (%d already live from static-init preload; %d deferred to lazy-compile)" \
			% [activated, eager_total, preactivated, deferred.size()])

	# Persist pack path and the eager wrapped paths so next session's static
	# init mounts the pack and preempts them before game autoloads compile
	# class_name scripts.
	_persist_hook_pack_state(pack_path, _eager_wrapped_paths(filenames))

	# Compile proof: the method list must hold the renamed vanilla beside the wrapper.
	var compile_proof_ok := 0
	var compile_proof_fail: PackedStringArray = []
	for fname: String in filenames:
		if _scripts_with_scene_preloads.has(fname):
			continue  # deferred to lazy-compile; compile-proof runs post-override elsewhere
		var vp := fname
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

	# Canary A: alarm on catastrophic or critical-script failure.
	var critical_set: Dictionary = {"Controller.gd": true, "Camera.gd": true,
			"WeaponRig.gd": true, "Door.gd": true, "Trader.gd": true,
			"Hitbox.gd": true, "LootContainer.gd": true, "Pickup.gd": true}
	var critical_failures: PackedStringArray = []
	for f in compile_proof_fail:
		if critical_set.has(String(f).get_file()):
			critical_failures.append(f)
	# Deferred scripts skip the compile proof; the watchdog covers them.
	var attempted := filenames.size() - deferred.size()
	if compile_proof_ok == 0 and attempted > 0:
		_log_critical("[STABILITY] ALL %d rewrites failed to take effect -- VFS mount, hook pack, or cache eviction is broken. Mods will NOT work this session. Click 'Launch vanilla' in the launcher or create modloader_disabled in the game folder." % attempted)
	elif critical_failures.size() > 0:
		_log_critical("[STABILITY] Hook rewrites missing on critical scripts: %s. Hooks on these scripts will NOT fire this session (likely cache-pinning fallback failure)." % ", ".join(critical_failures))
	else:
		var deferred_tag := ""
		if deferred.size() > 0:
			deferred_tag = ", %d deferred to lazy-compile" % deferred.size()
		_log_info("[STABILITY] COMPILE-PROOF summary: %d/%d rewrites active%s%s" \
				% [compile_proof_ok, attempted,
					(" (%d pinned-fallback)" % compile_proof_fail.size()) if compile_proof_fail.size() > 0 else "",
					deferred_tag])

	# The record the next launcher reads, so a player who never opens the log still learns.
	var status := {"state": HOOK_STATE_OK, "attempted": attempted, "ok": compile_proof_ok}
	if compile_proof_ok == 0 and attempted > 0:
		status["state"] = HOOK_STATE_ALL_FAILED
	elif critical_failures.size() > 0:
		status["state"] = HOOK_STATE_CRITICAL_FAILED
		status["critical_failures"] = Array(critical_failures)
	_hook_status_write(status)

	# End-to-end probes (dev-mode only): real hooks on known methods across menu
	# tick, menu click and gameplay. First set fires and last does not: timing;
	# none fire but the dispatch counter is high: _hooks lookup is broken.
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

	# Autoload inspection (dev-only): a live autoload node can still hold the
	# original bytecode via get_script() even when the resource shows the renames.
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
