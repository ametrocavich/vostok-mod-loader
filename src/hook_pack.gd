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

# How a rewritten script ships. A rewrite that does not compile is never
# packed: the pack would serve it over the game's bytecode and the vanilla
# script would stop working. WRAP_ONLY keeps the hooks and drops the registry
# code (the part that names vanilla members); EXCLUDED leaves the script
# vanilla.
const REWRITE_FULL := "full"
const REWRITE_WRAP_ONLY := "wrap_only"
const REWRITE_EXCLUDED := "excluded"
# res:// path -> REWRITE_WRAP_ONLY | REWRITE_EXCLUDED, for every script the
# probe demoted. Persisted in pass state: the generations that follow a
# vetted one (Pass 2, the same-state launch) repeat its verdicts and do not
# probe, because a probe there would compile scripts before mod overrides.
var _hook_pack_demotions: Dictionary = {}
var _hook_pack_vetting := false
# True on the Pass 1 generation, whose process exits right after: the only
# place a probe may compile a script that is deferred to lazy compile.
var _hook_pack_pre_restart := false
# What the probes of one generation cost, for the log: scripts vetted, and
# the time spent in every compile they needed.
var _hook_pack_probe_count := 0
var _hook_pack_probe_ms := 0

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

# Registry targets that keep the scene-preload deferral. AISpawner.gd's
# injected resolver reads Engine meta at call time, so nothing a mod
# registers needs the script live; and its module-scope preloads are the
# four AI scenes, which bake res://Scripts/AI.gd the moment it compiles.
# Compiled eagerly, it orphaned every mod's overrideScript() of AI.gd.
const REGISTRY_TARGETS_DEFERRABLE: Array[String] = ["AISpawner.gd"]

# Whether a rewritten vanilla script waits for lazy compile (after the mod
# autoloads ran overrideScript) instead of being activated eagerly.
func _defers_scene_preloads(filename: String, scene_preloads: PackedStringArray) -> bool:
	if scene_preloads.is_empty():
		return false
	return not _is_registry_target(filename) or filename in REGISTRY_TARGETS_DEFERRABLE

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

# Canary C helper. Detokenizes probe scripts with GDSC bytes, through
# _detokenize_script so a pristine cache cannot mask a broken detokenizer,
# and passes on the first one whose reconstruction has an indented func
# body. Fails only when some probe produced source and none passed; a
# single odd script must not disable hooks for the session. True when no
# probe could be read.
func _canary_detokenizer_roundtrip_ok() -> bool:
	var probe_paths := ["res://Scripts/Camera.gd", "res://Scripts/Controller.gd",
			"res://Scripts/Audio.gd", "res://Scripts/AI.gd"]
	var produced_source := false
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
		produced_source = true
		if _source_has_indented_func_body(source):
			return true
	return not produced_source

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
# The steps are the six _hook_pack_* functions called here, in call order;
# the probe helpers sit between _hook_pack_begin_vetting and the rest.
func _generate_hook_pack(defer_activation: bool = false) -> String:
	var pack_zip_rel := _hook_pack_preflight()
	if pack_zip_rel == "":
		return ""
	_hook_pack_begin_vetting(defer_activation)
	var script_paths := _hook_pack_script_paths()
	var needed_paths: Dictionary = {}
	var hook_mask: Dictionary = {}
	var reconcile := _hook_pack_wrap_surface(script_paths, needed_paths, hook_mask)
	var packed_paths: Array[String] = []
	var hook_count := _hook_pack_write_zip(pack_zip_rel, script_paths, needed_paths, hook_mask,
			reconcile, packed_paths)
	if hook_count < 0:
		return ""
	return _hook_pack_mount_and_activate(pack_zip_rel, packed_paths, hook_count, reconcile, defer_activation)

# Decide whether this generation probes its rewrites or repeats the verdicts
# of the vetted generation before it. Pass 1 probes. Any other generation
# reads the verdicts Pass 1 left in pass state; with no pass state (the
# single-pass launch) it probes, deferred scripts excepted.
func _hook_pack_begin_vetting(pre_restart: bool) -> void:
	_hook_pack_pre_restart = pre_restart
	_hook_pack_vetting = true
	_hook_pack_probe_count = 0
	_hook_pack_probe_ms = 0
	if not pre_restart:
		var cfg := ConfigFile.new()
		if cfg.load(PASS_STATE_PATH) == OK and cfg.has_section_key("state", "hook_pack_demotions"):
			var saved: Variant = cfg.get_value("state", "hook_pack_demotions", {})
			_hook_pack_demotions = (saved as Dictionary).duplicate() if saved is Dictionary else {}
			_hook_pack_vetting = false
			return
	_hook_pack_demotions.clear()

# Compile a copy of `source` that is bound to no path, so nothing live is
# touched: a load at the script's own path would recompile the running script
# in place. The class_name line is left out of the copy, because a second
# script declaring a registered global class does not compile. With
# want_rewrite the copy must also carry a renamed vanilla method.
func _rtv_probe_compiles(source: String, want_rewrite: bool) -> bool:
	var lines := source.split("\n")
	for i in lines.size():
		var line: String = lines[i]
		if not line.begins_with("class_name "):
			continue
		# `class_name X extends Y` keeps its extends clause.
		var at := line.find(" extends ")
		lines[i] = line.substr(at + 1) if at >= 0 else ""
	var probe := GDScript.new()
	probe.source_code = "\n".join(lines)
	var t0 := Time.get_ticks_msec()
	var err := probe.reload()
	_hook_pack_probe_ms += Time.get_ticks_msec() - t0
	if err != OK:
		return false
	if not want_rewrite:
		return true
	for m in probe.get_script_method_list():
		if str(m["name"]).begins_with("_rtv_vanilla_"):
			return true
	return false

# The source to pack for one script, and how it ships. Tries the full
# rewrite, then the wrap-only form, then leaves the script vanilla; a demotion
# only counts when the plain vanilla text compiles here, so a probe that
# cannot judge this script changes nothing.
func _hook_pack_vet_rewrite(script_path: String, source: String, parsed: Dictionary,
		path_mask: Dictionary, deferred: bool) -> Dictionary:
	if not _hook_pack_vetting:
		var mode := str(_hook_pack_demotions.get(script_path, REWRITE_FULL))
		if mode == REWRITE_EXCLUDED:
			return {"mode": mode, "source": ""}
		return {"mode": mode, "source": _rtv_rewrite_vanilla_source(source, parsed, path_mask, mode == REWRITE_FULL)}
	var full := _rtv_rewrite_vanilla_source(source, parsed, path_mask)
	if deferred and not _hook_pack_pre_restart:
		return {"mode": REWRITE_FULL, "source": full}
	_hook_pack_probe_count += 1
	if _rtv_probe_compiles(full, true):
		return {"mode": REWRITE_FULL, "source": full}
	var filename := script_path.get_file()
	var wrap_only := _rtv_rewrite_vanilla_source(source, parsed, path_mask, false)
	if wrap_only != full and _rtv_probe_compiles(wrap_only, true):
		_hook_pack_demotions[script_path] = REWRITE_WRAP_ONLY
		_log_critical("[STABILITY] %s: the registry code does not compile against this game build (the parse error above names the cause), so the script ships with hooks only. Mod content registered against it will NOT appear. The game itself is unaffected. Update the ModLoader." % filename)
		return {"mode": REWRITE_WRAP_ONLY, "source": wrap_only}
	if _rtv_probe_compiles(source, false):
		_hook_pack_demotions[script_path] = REWRITE_EXCLUDED
		_log_critical("[STABILITY] %s: the rewritten script does not compile against this game build (the parse error above names the cause), so it is left unmodified. Hooks on it will NOT fire. The game itself is unaffected. Update the ModLoader." % filename)
		return {"mode": REWRITE_EXCLUDED, "source": ""}
	_log_debug("[RTVCodegen] %s: the probe cannot compile the plain vanilla text either, so it says nothing about the rewrite -- shipping it unvetted" % filename)
	return {"mode": REWRITE_FULL, "source": full}

# Everything that must hold before a pack is built: a fresh pack path (a
# same-path remount is a no-op and Windows will not delete a mounted zip),
# canary B on the GDSC format, at least one loaded mod, and canary C on the
# detokenizer. Returns the pack path to write, or "" to stop.
func _hook_pack_preflight() -> String:
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
	return pack_zip_rel

# The vanilla scripts the wrap surface is checked against, with the
# class_name map as the fallback when the PCK could not be enumerated.
func _hook_pack_script_paths() -> Array[String]:
	var script_paths: Array[String] = _enumerate_game_scripts()
	if script_paths.is_empty():
		_log_warning("[RTVCodegen] script enumeration failed -- falling back to class_name list (%d)" % _class_name_to_path.size())
		for path: String in _class_name_to_path.values():
			script_paths.append(path)
	return script_paths

# The wrap surface. Fills needed_paths (res_path -> true) and hook_mask
# (res_path -> {method: true}; an empty inner dict means every method, the
# "[hooks] <path> = *" wildcard and the registry targets) from the [hooks]
# and .hook() declarations and, when a mod declared [registry], from
# REGISTRY_TARGETS. Returns the reconciliation ledger, one entry per
# declared target: {declared, methods, status: pending -> wrapped|lost,
# detail, missing_methods}.
func _hook_pack_wrap_surface(script_paths: Array[String], needed_paths: Dictionary,
		hook_mask: Dictionary) -> Dictionary:
	# Opt-in gate: user mods run against unmodified vanilla unless one declares
	# [hooks], .hook() or [registry]. Captured before _seed_core_hooks adds the
	# core Menu.gd wrap; a modlist that declares nothing gets only that wrap.
	var user_wrap_empty: bool = _hooked_methods.is_empty() and not _any_mod_declared_registry

	_seed_core_hooks()

	if user_wrap_empty:
		_log_info("[RTVCodegen] No user opt-in declarations ([hooks] / .hook() / [registry]) -- user mods' vanilla targets run unmodified (v2.1.0-equivalent). Pack contains core hooks only.")

	# A vanilla script enters needed_paths only via a [hooks] declaration, a
	# literal .hook() call, or REGISTRY_TARGETS when some mod declares
	# [registry]. No inference from extends or take_over_path. The enumerated set
	# validates declared paths: a typo would otherwise silently no-op.
	var vanilla_path_set: Dictionary = {}
	for sp: String in script_paths:
		vanilla_path_set[sp] = true
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
			if hook_mask.has(rt_path):
				_mask_widen(hook_mask[rt_path])
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
	var via_hooks := 0
	for needed_path: String in needed_paths:
		if _hooked_methods.has(needed_path):
			via_hooks += 1
	_log_info("[RTVCodegen] Wrap surface: %d vanilla script(s) declared (%d via [hooks]/.hook(), %d more via [registry])" % [
		needed_paths.size(),
		via_hooks,
		needed_paths.size() - via_hooks,
	])
	_log_debug("[RTVCodegen] Skip lists: %d runtime-sensitive, %d data, %d serialized (total %d skipped from rewrite)" % [
		RTV_SKIP_LIST.size(),
		RTV_RESOURCE_DATA_SKIP.size(),
		RTV_RESOURCE_SERIALIZED_SKIP.size(),
		RTV_SKIP_LIST.size() + RTV_RESOURCE_DATA_SKIP.size() + RTV_RESOURCE_SERIALIZED_SKIP.size(),
	])
	return reconcile

# The VFS-precedence canary the pack carries; the mount step reads it back.
func _hook_pack_canary_content(pack_zip_rel: String) -> String:
	return "MODLOADER-VFS-CANARY-" + pack_zip_rel.get_file()

# Write the pack: three entries per wrapped vanilla script (the rewrite, a
# self-referencing .gd.remap and an empty .gdc) and the VFS canary file. No
# mod script enters the pack. Appends every packed script to packed_paths and
# records each declared target's fate in the ledger. Returns the number of
# hook points written, or -1 when the pack could not be written (the zip is
# deleted and the failure logged).
func _hook_pack_write_zip(pack_zip_rel: String, script_paths: Array[String], needed_paths: Dictionary,
		hook_mask: Dictionary, reconcile: Dictionary, packed_paths: Array[String]) -> int:
	var zip_abs := ProjectSettings.globalize_path(pack_zip_rel)
	var zp := ZIPPacker.new()
	if zp.open(zip_abs) != OK:
		_log_critical("[RTVCodegen] Failed to create framework pack zip at %s" % zip_abs)
		_hook_status_write({"state": HOOK_STATE_PACK_FAILED, "attempted": needed_paths.size()})
		return -1
	var pack_write_failed := false

	var hook_count := 0
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
			_log_debug("[RTVCodegen] Surface-skip %s (no mod declared it)" % filename)
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
		# A registry target has no mask entry or an emptied one; both read as the wildcard.
		var path_mask: Dictionary = hook_mask.get(script_path, {}) as Dictionary
		var apply_mask: bool = not _mask_is_wildcard(path_mask)
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
		# activation (see _activate_rewritten_scripts), except the registry
		# targets whose injected fields must be live when mods call
		# lib.register() (see _defers_scene_preloads).
		var scene_preloads := _collect_module_scope_scene_preloads(source)
		if _defers_scene_preloads(filename, scene_preloads):
			_scripts_with_scene_preloads[script_path] = scene_preloads

		var vetted := _hook_pack_vet_rewrite(script_path, source, parsed, path_mask,
				_scripts_with_scene_preloads.has(script_path))
		var ship_mode := str(vetted["mode"])
		if ship_mode == REWRITE_EXCLUDED:
			_scripts_with_scene_preloads.erase(script_path)
			if not rec_v.is_empty() and rec_v["status"] == "pending":
				rec_v["status"] = "lost"
				rec_v["detail"] = "the rewritten script does not compile against this game build; left unmodified"
			continue
		var rewritten := str(vetted["source"])
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
		if ship_mode == REWRITE_WRAP_ONLY:
			if not rec_v.is_empty():
				var mm_w: Array = rec_v.get("missing_methods", []) as Array
				mm_w.append("registry code (does not compile against this game build -- registry features on this script will not work)")
				rec_v["missing_methods"] = mm_w
		elif _any_mod_declared_registry and _is_registry_target(filename):
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

		hook_count += hookable_count * 4  # pre/post/callback/replace per method
		packed_paths.append(script_path)
		if not rec_v.is_empty() and rec_v["status"] == "pending":
			rec_v["status"] = "wrapped"
			rec_v["detail"] = "%d method(s) wrapped" % hookable_count
			rec_v["wrapped_count"] = hookable_count
		_log_debug("[RTVCodegen] Rewrote %s (%d hooks)" % [script_path, hookable_count * 4])

	# Mod scripts never enter the pack: a mod extending a wrapped vanilla script
	# composes through Godot's extends resolution, from the mod's own archive.

	# VFS-precedence canary: a known-content file that must read back after mount.
	var canary_content := _hook_pack_canary_content(pack_zip_rel)
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
		_hook_status_write({"state": HOOK_STATE_PACK_FAILED, "attempted": needed_paths.size()})
		return -1

	if zero_byte_skipped > 0:
		_log_debug("[RTVCodegen] Skipped %d zero-byte PCK entry(ies) (base game ships empty .gd files -- not hookable, not a modloader failure): %s" \
				% [zero_byte_skipped, ", ".join(_pck_zero_byte_paths.keys())])
	if surface_skipped > 0:
		_log_debug("[RTVCodegen] Surface-skipped %d vanilla script(s) with no mod interaction -- they run native (no dispatch overhead)" \
				% surface_skipped)
	return hook_count

# Reconcile the ledger against what was packed, then either persist the pack
# for the next session's static init (defer_activation, the Pass 1
# pre-restart path) or mount it now, read the VFS canary back and activate
# the rewritten scripts. Returns the pack path, also when activation was
# deferred to the next launch; "" means the pack failed its canary or would
# not mount.
func _hook_pack_mount_and_activate(pack_zip_rel: String, packed_paths: Array[String], hook_count: int,
		reconcile: Dictionary, defer_activation: bool) -> String:
	var zip_abs := ProjectSettings.globalize_path(pack_zip_rel)
	var canary_content := _hook_pack_canary_content(pack_zip_rel)
	# Any entry still pending was never visited: a declared path missing from the enumeration.
	for rp: String in reconcile:
		var pending_rec: Dictionary = reconcile[rp]
		if pending_rec.get("status", "") == "pending":
			pending_rec["status"] = "lost"
			if str(pending_rec.get("detail", "")) == "":
				pending_rec["detail"] = "never reached the rewrite loop (not in the enumerated vanilla script list)"
	# Reconciliation: declared vs packed; pack-level failures already discarded the pack.
	_log_hook_reconciliation(reconcile)
	if _hook_pack_probe_count > 0:
		_log_info("[STABILITY] Probe-compiled %d rewrite(s) in %d ms before packing: %d shipped in full, %d without registry code, %d left vanilla" \
				% [_hook_pack_probe_count, _hook_pack_probe_ms,
					_hook_pack_probe_count - _hook_pack_demotions.size(),
					_hook_pack_demotions.values().count(REWRITE_WRAP_ONLY),
					_hook_pack_demotions.values().count(REWRITE_EXCLUDED)])
	elif not _hook_pack_demotions.is_empty():
		_log_warning("[STABILITY] Repeating the last probe's verdicts: %s" % str(_hook_pack_demotions))
	# Mount before mod autoloads run and before any scene compiles against the
	# rewritten scripts. replace_files=true is the default, passed explicitly.
	if packed_paths.size() > 0:
		if defer_activation:
			# Pass 1 pre-restart: write the zip and persist pass_state so Pass 2's static
			# init mounts it on a fresh engine; activating here would fire a false alarm.
			_log_info("[RTVCodegen] Generated %d rewritten vanilla script(s), %d hook points -- activation deferred to Pass 2 fresh engine" \
					% [packed_paths.size(), hook_count])
			_persist_hook_pack_state(pack_zip_rel, _eager_wrapped_paths(packed_paths))
		elif ProjectSettings.load_resource_pack(pack_zip_rel, true):
			var canary_got := FileAccess.get_file_as_string("res://__modloader_canary__.txt")
			if canary_got.strip_edges() != canary_content:
				# Activating anyway would leave a half-modded state; not persisting means
				# the next launch regenerates instead of remounting this broken pack.
				_log_critical("[STABILITY] VFS canary FAILED (got '%s', expected '%s') -- hook pack mounted but files aren't served. Skipping activation: script hooks will not fire this session, vanilla scripts run. Pack state not persisted; next launch regenerates." % [canary_got.substr(0, 40), canary_content])
				_hook_status_write({"state": HOOK_STATE_PACK_FAILED, "attempted": packed_paths.size()})
				return ""
			_log_info("[STABILITY] VFS canary OK: hook pack mount precedence verified (%s)" % canary_got.strip_edges())
			_log_info("[RTVCodegen] Generated %d rewritten vanilla script(s), %d hook points -- pack mounted at res:// (%s)" \
					% [packed_paths.size(), hook_count, pack_zip_rel.get_file()])
			_activate_rewritten_scripts(packed_paths, pack_zip_rel)
		else:
			_log_critical("[RTVCodegen] Failed to mount hook pack at %s -- script hooks will not fire this session, vanilla scripts run. Next launch regenerates the pack." % zip_abs)
			_hook_status_write({"state": HOOK_STATE_PACK_FAILED, "attempted": packed_paths.size()})
			return ""
	else:
		_log_info("[RTVCodegen] No scripts rewritten -- no pack mounted")
		if not _hook_pack_demotions.is_empty():
			# Every rewrite was left out. The verdicts still have to reach the
			# generation that follows, which would otherwise probe live and skip
			# the deferred scripts, and the launcher still has to say so.
			_persist_hook_pack_state("", _eager_wrapped_paths(packed_paths))
			_hook_status_write({"state": HOOK_STATE_DEMOTED, "attempted": 0, "demoted": _hook_pack_demotions.keys()})
	return pack_zip_rel

# Who declared a wrap target: "ModA, ModB" for [hooks] and .hook() declarers,
# the loader for its own Menu.gd wrap, the [registry] declarers for a registry
# target nobody hooked by name, and an add_hook() caller for anything else.
func _hook_declarers_label(path: String) -> String:
	var by: Dictionary = _hook_declared_by.get(path, {}) as Dictionary
	if by.is_empty() and _any_mod_declared_registry and _is_registry_target(path.get_file()):
		by = _registry_declared_by
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
func _activate_rewritten_scripts(res_paths: Array[String], pack_path: String) -> void:
	# Scripts with module-scope PackedScene preloads are deferred from eager
	# load+reload: loading them now would bake scene Script ext_resources to
	# pre-override vanilla, and a later take_over_path leaves those refs
	# empty-path. VFS mount precedence still serves the rewrite at lazy compile.
	var deferred: PackedStringArray = []
	for res_path: String in res_paths:
		if _scripts_with_scene_preloads.has(res_path):
			deferred.append(res_path)
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

	if _developer_mode:
		_dev_preactivate_summary(res_paths)

	var activated := 0
	var preactivated := 0
	for res_path: String in res_paths:
		if _scripts_with_scene_preloads.has(res_path):
			continue
		var cached := load(res_path) as GDScript
		if cached == null:
			_log_warning("[RTVCodegen] activate %s: load returned null -- skip" % res_path)
			continue
		# Overrides are applied before the pack is generated, so load() may return
		# a mod's replacement; the reload below overwrites it with the rewrite.
		var displaced := _override_claimants(res_path)
		if not displaced.is_empty():
			_log_warning("[RTVCodegen] activate %s: replacing the script installed by %s with the rewritten vanilla script -- that replacement will not run this session" \
					% [res_path, ", ".join(displaced)])

		# Static-init preload already put the rewrite in this cached script: skip
		# the reload, which would fail on autoload-backed scripts. A newer loader's
		# rewriter output can differ, so compare source_code and reload on divergence.
		var already_live := false
		for m in cached.get_script_method_list():
			if str(m["name"]).begins_with("_rtv_vanilla_"):
				already_live = true
				break
		if already_live:
			var fresh_source := FileAccess.get_file_as_string(res_path)
			if not fresh_source.is_empty() and fresh_source != cached.source_code:
				_log_info("[RTVCodegen] activate %s: cached rewrite is stale (static-init had an older pack), forcing fresh+take_over_path" % res_path)
				var fresh := ResourceLoader.load(res_path, "", ResourceLoader.CACHE_MODE_IGNORE) as GDScript
				if fresh == null:
					_log_critical("[RTVCodegen] activate %s: fresh load returned null -- skip" % res_path)
					continue
				fresh.take_over_path(res_path)
				# Report-only rename check (take_over already happened).
				var stale_fresh_ok := false
				for m in fresh.get_script_method_list():
					if str(m["name"]).begins_with("_rtv_vanilla_"):
						stale_fresh_ok = true
						break
				if not stale_fresh_ok:
					_log_critical("[RTVCodegen] activate %s: fresh load lacks _rtv_vanilla_ renames -- rewrite isn't compiling; hooks on this script will not fire" % res_path)
					continue
				activated += 1
				continue
			preactivated += 1
			activated += 1
			continue

		# Otherwise mutate source_code and reload (compiled from source, no rewrite yet).
		var our_source := FileAccess.get_file_as_string(res_path)
		if our_source.is_empty():
			_log_warning("[RTVCodegen] activate %s: FileAccess returned empty -- skip" % res_path)
			continue
		cached.source_code = our_source
		var err := cached.reload()
		if err != OK:
			_log_warning("[RTVCodegen] activate %s: reload failed (%s)" % [res_path, error_string(err)])
		# Verify the reload took: scripts originally compiled from .gdc do not
		# re-parse mutated source_code. Fall back to CACHE_MODE_IGNORE + take_over_path.
		var has_rename := false
		for m in cached.get_script_method_list():
			if str(m["name"]).begins_with("_rtv_vanilla_"):
				has_rename = true
				break
		if not has_rename:
			_log_info("[RTVCodegen] activate %s: reload didn't apply (pre-compiled); falling back to fresh+take_over_path" % res_path)
			var fresh := ResourceLoader.load(res_path, "", ResourceLoader.CACHE_MODE_IGNORE) as GDScript
			if fresh == null:
				_log_critical("[RTVCodegen] activate %s: fresh load returned null -- skip" % res_path)
				continue
			var fresh_has_rename := false
			for m in fresh.get_script_method_list():
				if str(m["name"]).begins_with("_rtv_vanilla_"):
					fresh_has_rename = true
					break
			if not fresh_has_rename:
				_log_critical("[RTVCodegen] activate %s: fresh load also lacks renames -- rewrite isn't compiling" % res_path)
				continue
			fresh.take_over_path(res_path)
			_log_info("[RTVCodegen] activate %s: fresh script took over vanilla path" % res_path)
		activated += 1
	# Denominator uses `deferred`, not the raw dict, so a stray entry cannot mask a miss.
	var eager_total := res_paths.size() - deferred.size()
	_log_info("[RTVCodegen] Activated %d/%d rewritten script(s) (%d already live from static-init preload; %d deferred to lazy-compile)" \
			% [activated, eager_total, preactivated, deferred.size()])

	# Persist pack path and the eager wrapped paths so next session's static
	# init mounts the pack and preempts them before game autoloads compile
	# class_name scripts.
	_persist_hook_pack_state(pack_path, _eager_wrapped_paths(res_paths))

	# Compile proof: the method list must hold the renamed vanilla beside the wrapper.
	var compile_proof_ok := 0
	var compile_proof_fail: PackedStringArray = []
	for res_path: String in res_paths:
		if _scripts_with_scene_preloads.has(res_path):
			continue  # deferred to lazy-compile; compile-proof runs post-override elsewhere
		var s := load(res_path) as GDScript
		if s == null:
			compile_proof_fail.append(res_path)
			continue
		var methods := s.get_script_method_list()
		var has_vanilla_rename := false
		var sample_rename := ""
		for m in methods:
			var n: String = str(m["name"])
			if n.begins_with("_rtv_vanilla_"):
				has_vanilla_rename = true
				sample_rename = n
				break
		if _developer_mode:
			_log_info("[RTVCodegen] COMPILE-PROOF %s: %d methods compiled, _rtv_vanilla_* present=%s (e.g. %s)" \
					% [res_path, methods.size(), has_vanilla_rename, sample_rename])
		if has_vanilla_rename:
			compile_proof_ok += 1
		else:
			compile_proof_fail.append(res_path)

	# Canary A: alarm on catastrophic or critical-script failure.
	var critical_set: Dictionary = {"Controller.gd": true, "Camera.gd": true,
			"WeaponRig.gd": true, "Door.gd": true, "Trader.gd": true,
			"Hitbox.gd": true, "LootContainer.gd": true, "Pickup.gd": true}
	var critical_failures: PackedStringArray = []
	for f in compile_proof_fail:
		if critical_set.has(String(f).get_file()):
			critical_failures.append(f)
	# Deferred scripts skip the compile proof; the watchdog covers them.
	var attempted := res_paths.size() - deferred.size()
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
	elif not _hook_pack_demotions.is_empty():
		status["state"] = HOOK_STATE_DEMOTED
		status["demoted"] = _hook_pack_demotions.keys()
	_hook_status_write(status)

	if _developer_mode:
		_dev_hook_probes()
