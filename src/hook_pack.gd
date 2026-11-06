# The opt-in hook pack: declared vanilla scripts are rewritten, zipped, mounted at
# res:// and activated. Mod scripts never enter it; they compose through extends.

# res:// paths left to lazy compile. A module-scope preload() of a scene runs at parse
# time, so compiling the script before the mod overrides bakes pre-override vanilla.
var _scripts_with_scene_preloads: Dictionary = {}

# A rewrite that does not compile is never packed, since the pack is served over the
# game's bytecode. WRAP_ONLY drops the registry code; EXCLUDED leaves the script vanilla.
const REWRITE_FULL := "full"
const REWRITE_WRAP_ONLY := "wrap_only"
const REWRITE_EXCLUDED := "excluded"
# res:// path -> demoted mode, persisted in pass state: a later generation repeats the
# verdicts, since its probe would compile scripts before the mod overrides.
var _hook_pack_demotions: Dictionary = {}
# Declared targets skipped on purpose or not written, and wrapped scripts with methods
# left out; _hook_pack_lost_targets holds the ones missing from the game.
var _hook_pack_skipped_targets: Array = []
var _hook_pack_partial_targets: Array = []
var _hook_pack_vetting := false
# True on the Pass 1 generation, the only one whose probe may compile a deferred script.
var _hook_pack_pre_restart := false
var _probe_count := 0
var _probe_ms := 0

# Scripts the rewriter adds registry code to, activated eagerly so the injected
# fields are live when mods register. Enrolled only when a mod declares [registry].
const REGISTRY_TARGETS: Array[String] = [
	"Database.gd",
	"Loader.gd",
	"AISpawner.gd",
	"AI.gd",
	"FishPool.gd",
	"Compiler.gd",
]

# AISpawner.gd keeps the deferral although it is a registry target: its resolver reads
# Engine meta at call time, and its preloaded AI scenes would bake AI.gd before overrides.
func _defers_scene_preloads(filename: String, scene_preloads: PackedStringArray) -> bool:
	if scene_preloads.is_empty():
		return false
	return filename not in REGISTRY_TARGETS or filename == "AISpawner.gd"

# Column-0 `preload("...tscn|scn")` paths: only module scope runs at parse time.
func _collect_module_scope_scene_preloads(source: String) -> PackedStringArray:
	var scenes := PackedStringArray()
	for line in source.split("\n"):
		if "preload(" not in line or _is_indented(line) or line.strip_edges().begins_with("#"):
			continue
		for m in _rtv_re_scene_preload.search_all(line):
			if m.get_string(1) not in scenes:
				scenes.append(m.get_string(1))
	return scenes

# A string each target's rewrite carries only when its anchored transform landed (the
# appendices lack it), so a game update that moves the anchor is reported once.
const REGISTRY_EXPECTED_MARKERS: Dictionary = {
	"Database.gd": "var _rtv_vanilla_scenes",
	"Loader.gd": "scene_paths registry prelude",
	"AISpawner.gd": " = _rtv_resolve_ai_type(zone, ",
	"AI.gd": "ai_loadouts registry prelude",
	"FishPool.gd": "fish_species registry prelude",
	"Compiler.gd": "shelters/maps registry prelude",
}

# The wrapped paths next session's static init force-compiles. The deferred ones stay
# out: static init runs before any mod override.
func _eager_wrapped_paths(paths: Array[String]) -> PackedStringArray:
	var out := PackedStringArray()
	for p in paths:
		if not _scripts_with_scene_preloads.has(p):
			out.append(p)
	return out

# Canary C: passes on the first probe script whose detokenized text has an indented func
# body, and when no probe could be read; one odd script must not disable hooks.
func _canary_detokenizer_roundtrip_ok() -> bool:
	var produced_source := false
	for p in _GDSC_PROBE_SCRIPTS:
		# The byte check first, so a missing path does not warn from _detokenize_script.
		if _gdsc_probe_bytes(p).is_empty():
			continue
		var source := _detokenize_script(p)
		if source.is_empty():
			continue
		produced_source = true
		if _source_has_indented_func_body(source):
			return true
	return not produced_source

# A colon-terminated func followed by a tab-indented line: what _indent_from_column's
# `col / 4` produces from 4-space vanilla source.
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
			break
	return false

# The zip mounts at res://: extends resolution of class_name parents breaks for scripts
# loaded from user://.
func _generate_hook_pack(defer_activation: bool = false) -> String:
	var pack_zip_rel := _pack_preflight()
	if pack_zip_rel == "":
		_forget_previous_pack()
		return ""
	_hook_pack_begin_vetting(defer_activation)
	var script_paths: Array[String] = _enumerate_game_scripts()
	if script_paths.is_empty():
		_log_warning("[RTVCodegen] script enumeration failed -- falling back to class_name list (%d)" % _class_name_to_path.size())
		for path: String in _class_name_to_path.values():
			script_paths.append(path)
	var needed_paths: Dictionary = {}
	var hook_mask: Dictionary = {}
	var reconcile := _hook_pack_wrap_surface(script_paths, needed_paths, hook_mask)
	var packed_paths: Array[String] = []
	var hook_count := _hook_pack_write_zip(pack_zip_rel, script_paths, needed_paths, hook_mask,
			reconcile, packed_paths)
	if hook_count < 0:
		return ""
	return _hook_pack_mount_and_activate(pack_zip_rel, packed_paths, hook_count, reconcile, defer_activation)

# With no pack this launch, static init must not mount the last one over the mods enabled now.
func _forget_previous_pack() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(PASS_STATE_PATH) != OK or _state_str(cfg, "hook_pack_path", "") == "":
		return
	cfg.set_value("state", "hook_pack_path", "")
	cfg.set_value("state", "hook_pack_wrapped_paths", PackedStringArray())
	if cfg.save(PASS_STATE_PATH) == OK:
		_log_info("[RTVCodegen] No hook pack this launch -- the previous pack is no longer mounted at startup")

# Pass 1 probes. A later generation repeats the verdicts Pass 1 left in pass state; with
# no pass state (the single-pass launch) it probes, deferred scripts excepted.
func _hook_pack_begin_vetting(pre_restart: bool) -> void:
	_hook_pack_pre_restart = pre_restart
	_hook_pack_vetting = true
	_probe_count = 0
	_probe_ms = 0
	if not pre_restart:
		var cfg := ConfigFile.new()
		if cfg.load(PASS_STATE_PATH) == OK and cfg.has_section_key("state", "hook_pack_demotions"):
			var saved: Variant = cfg.get_value("state", "hook_pack_demotions")
			_hook_pack_demotions = saved.duplicate() if saved is Dictionary else {}
			_hook_pack_vetting = false
			return
	_hook_pack_demotions.clear()

# Compiles a copy bound to no path: a load at the script's own path recompiles the live
# script in place, and a second script declaring a registered class_name does not compile.
func _rtv_probe_compiles(source: String, want_rewrite: bool) -> bool:
	var lines := source.split("\n")
	for i in lines.size():
		if lines[i].begins_with("class_name "):
			# `class_name X extends Y` keeps its extends clause.
			var at := lines[i].find(" extends ")
			lines[i] = lines[i].substr(at + 1) if at >= 0 else ""
	var probe := GDScript.new()
	probe.source_code = "\n".join(lines)
	var t0 := Time.get_ticks_msec()
	var err := probe.reload()
	_probe_ms += Time.get_ticks_msec() - t0
	if err != OK:
		return false
	return not want_rewrite or _static_script_has_rewrite(probe)

# The full rewrite, else the wrap-only form, else vanilla; a demotion needs the plain text to compile.
func _hook_pack_vet_rewrite(script_path: String, source: String, parsed: Dictionary,
		path_mask: Dictionary, deferred: bool) -> Dictionary:
	if not _hook_pack_vetting:
		var mode := str(_hook_pack_demotions.get(script_path, REWRITE_FULL))
		if mode == REWRITE_EXCLUDED:
			return {"mode": mode, "source": ""}
		return {"mode": mode, "source": _rtv_rewrite_vanilla_source(source, parsed, path_mask, mode == REWRITE_FULL)}
	var full := _rtv_rewrite_vanilla_source(source, parsed, path_mask)
	# Only Pass 1 may compile a deferred script; any later generation ships it unprobed.
	if deferred and not _hook_pack_pre_restart:
		return {"mode": REWRITE_FULL, "source": full}
	_probe_count += 1
	if _rtv_probe_compiles(full, true):
		return {"mode": REWRITE_FULL, "source": full}
	var filename := script_path.get_file()
	var wrap_only := _rtv_rewrite_vanilla_source(source, parsed, path_mask, false)
	if wrap_only != full and _rtv_probe_compiles(wrap_only, true):
		_hook_pack_demotions[script_path] = REWRITE_WRAP_ONLY
		_log_critical("[STABILITY] %s: registry code does not compile against this game build; hooks only" % filename)
		return {"mode": REWRITE_WRAP_ONLY, "source": wrap_only}
	if _rtv_probe_compiles(source, false):
		_hook_pack_demotions[script_path] = REWRITE_EXCLUDED
		_log_critical("[STABILITY] %s: the rewrite does not compile against this game build; left vanilla" % filename)
		return {"mode": REWRITE_EXCLUDED, "source": ""}
	_log_debug("[RTVCodegen] %s: the plain vanilla text does not compile in the probe either; shipped unvetted" % filename)
	return {"mode": REWRITE_FULL, "source": full}

# "" stops the build: canary B (GDSC format), no loaded mod, or canary C (detokenizer).
func _pack_preflight() -> String:
	_scripts_with_scene_preloads.clear()
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(HOOK_PACK_DIR))
	_sweep_legacy_hooks()
	# A unique name per call: load_resource_pack dedupes by path. The previous zip stays,
	# since a mount from the last session still holds a handle to it.
	var pack_zip_rel := HOOK_PACK_DIR.path_join("%s_%d.zip" % [HOOK_PACK_PREFIX, Time.get_ticks_msec()])
	var godot: String = Engine.get_version_info()["string"]
	var tok_version := _probe_gdsc_version()
	if tok_version != -1 and tok_version != GDSC_VERSION_V100 and tok_version != GDSC_VERSION_V101:
		_log_critical("[STABILITY] Unsupported GDSC tokenizer v%d on Godot %s; no hook pack, hooks will not fire" \
				% [tok_version, godot])
		_hook_status_write({"state": HOOK_STATE_UNSUPPORTED_GDSC, "gdsc_version": tok_version})
		return ""
	if tok_version != -1:
		_log_info("[STABILITY] Detokenizer compatible: GDSC v%d on Godot %s" % [tok_version, godot])
	if _loaded_mod_ids.is_empty():
		# Nothing to rewrite is healthy; a stale failure record must not outlive the mods.
		_hook_status_write({"state": HOOK_STATE_OK, "attempted": 0})
		return ""
	# Canary C: the GDSC version can stay 101 while the column format changes, and a
	# reindented game breaks `col / 4` without touching it.
	if tok_version != -1 and not _canary_detokenizer_roundtrip_ok():
		_log_critical("[STABILITY] Detokenized vanilla source failed the indentation sanity check; hooks off (Godot %s)" \
				% godot)
		_hook_status_write({"state": HOOK_STATE_DETOK_FAILED, "gdsc_version": tok_version})
		return ""
	return pack_zip_rel

# hook_mask is path -> {method: true}, {} = every method. Returns the ledger:
# {declared, methods, status, detail, missing_methods} per declared target.
func _hook_pack_wrap_surface(script_paths: Array[String], needed_paths: Dictionary,
		hook_mask: Dictionary) -> Dictionary:
	# Read before _seed_core_hooks adds the loader's own Menu.gd wrap.
	var user_wrap_empty: bool = _hooked_methods.is_empty() and not _any_mod_declared_registry
	_seed_core_hooks()
	if user_wrap_empty:
		_log_info("[RTVCodegen] No user opt-in declarations ([hooks] / .hook() / [registry]); core hooks only")
	var vanilla_path_set: Dictionary = {}
	for sp: String in script_paths:
		vanilla_path_set[sp] = true
	var reconcile: Dictionary = {}
	for path: String in _hooked_methods:
		var rec := _ledger_entry("[hooks]/.hook()", _hooked_methods[path].keys())
		reconcile[path] = rec
		if not path.begins_with("res://Scripts/"):
			_ledger_lose(rec, "non-vanilla path -- only res://Scripts/*.gd is hookable")
			_log_debug("[RTVCodegen] [hooks] on non-vanilla path '%s' ignored" % path)
			continue
		if not vanilla_path_set.has(path):
			# Still enrolled; the ledger reports the loss once.
			_ledger_lose(rec, "no vanilla script at this path (typo, or the game renamed/removed it)", true)
			_log_debug("[RTVCodegen] [hooks] path '%s' matches no vanilla script" % path)
		needed_paths[path] = true
		hook_mask[path] = _hooked_methods[path].duplicate()
	if _any_mod_declared_registry:
		for rt_filename in REGISTRY_TARGETS:
			var rt_path := "res://Scripts/" + rt_filename
			needed_paths[rt_path] = true
			if hook_mask.has(rt_path):
				_mask_widen(hook_mask[rt_path])
			if reconcile.has(rt_path):
				# Widened to every method; the declared names stay so a removed one is reported.
				var widened: Dictionary = reconcile[rt_path]
				widened["declared"] = "[hooks]+[registry]"
				widened["declared_methods"] = widened["methods"]
				widened["methods"] = []
				widened["status"] = "pending"
				widened["detail"] = ""
			else:
				reconcile[rt_path] = _ledger_entry("[registry]", [])
			if not vanilla_path_set.has(rt_path):
				_ledger_lose(reconcile[rt_path], "registry target not found among enumerated vanilla scripts", true)
	var via_hooks := 0
	for needed_path: String in needed_paths:
		if _hooked_methods.has(needed_path):
			via_hooks += 1
	_log_info("[RTVCodegen] Wrap surface: %d vanilla script(s) declared (%d via [hooks]/.hook(), %d more via [registry])" \
			% [needed_paths.size(), via_hooks, needed_paths.size() - via_hooks])
	_log_debug("[RTVCodegen] Skip lists: %d runtime-sensitive, %d data, %d serialized" \
			% [RTV_SKIP_LIST.size(), RTV_RESOURCE_DATA_SKIP.size(), RTV_RESOURCE_SERIALIZED_SKIP.size()])
	return reconcile

func _canary_content(pack_zip_rel: String) -> String:
	return "MODLOADER-VFS-CANARY-" + pack_zip_rel.get_file()

# The hook points written, or -1 when the pack could not be written (logged, zip deleted).
func _hook_pack_write_zip(pack_zip_rel: String, script_paths: Array[String], needed_paths: Dictionary,
		hook_mask: Dictionary, reconcile: Dictionary, packed_paths: Array[String]) -> int:
	var zip_abs := ProjectSettings.globalize_path(pack_zip_rel)
	var zp := ZIPPacker.new()
	if zp.open(zip_abs) != OK:
		_log_critical("[RTVCodegen] Failed to create framework pack zip at %s" % zip_abs)
		_hook_status_write({"state": HOOK_STATE_PACK_FAILED, "attempted": needed_paths.size()})
		return -1
	var write_failed := false
	var hook_count := 0
	var zero_byte_skipped := 0
	var surface_skipped := 0
	for script_path: String in script_paths:
		var rec: Dictionary = reconcile.get(script_path, {})
		var skip := _triage_script(script_path, rec, needed_paths)
		if skip == "zero_byte":
			zero_byte_skipped += 1
		elif skip == "surface":
			surface_skipped += 1
		if skip != "":
			continue
		# A registry target has no mask entry or an emptied one; both are the wildcard.
		var rewrite := _pack_rewrite(script_path, rec, hook_mask.get(script_path, {}))
		if rewrite.is_empty():
			continue
		if _write_pack_entries(zp, script_path, rewrite["source"]) != "":
			write_failed = true
			_ledger_lose(rec, "zip write failed (disk full / I/O error?)")
			continue
		var wrapped: int = rewrite["names"].size()
		hook_count += wrapped * 4  # pre, post, callback, replace
		packed_paths.append(script_path)
		if not rec.is_empty() and rec["status"] == "pending":
			rec["status"] = "wrapped"
			rec["detail"] = "%d method(s) wrapped" % wrapped
			rec["wrapped_count"] = wrapped
		_log_debug("[RTVCodegen] Rewrote %s (%d hooks)" % [script_path, wrapped * 4])
	if not _zip_put(zp, "__modloader_canary__.txt", _canary_content(pack_zip_rel).to_utf8_buffer()):
		write_failed = true
	if zp.close() != OK:
		write_failed = true
	if write_failed:
		DirAccess.remove_absolute(zip_abs)
		_log_critical("[RTVCodegen] Hook pack write failed (disk full / I/O error?) at %s; hooks off, vanilla runs" % zip_abs)
		_hook_status_write({"state": HOOK_STATE_PACK_FAILED, "attempted": needed_paths.size()})
		return -1
	if zero_byte_skipped > 0:
		_log_debug("[RTVCodegen] Skipped %d zero-byte PCK entry(ies) (the game ships them empty): %s" \
				% [zero_byte_skipped, ", ".join(_pck_zero_byte_paths.keys())])
	if surface_skipped > 0:
		_log_debug("[RTVCodegen] Surface-skipped %d vanilla script(s) with no mod interaction" % surface_skipped)
	return hook_count

# The vetted rewrite and its hookable names, or {} when the script stays vanilla (ledger updated).
func _pack_rewrite(script_path: String, rec: Dictionary, path_mask: Dictionary) -> Dictionary:
	var filename := script_path.get_file()
	var source := _read_vanilla_source(script_path)
	if source.is_empty():
		_log_debug("[RTVCodegen] Empty detokenized source for %s -- skipped" % script_path)
		_ledger_lose(rec, "detokenizer produced no source for this script (game build mismatch?)")
		return {}
	var parsed := _rtv_parse_script(filename, source)
	var selection := _rtv_select_hookable(parsed, path_mask)
	if not _record_methods(rec, filename, path_mask, selection):
		return {}
	var hookable_names: Array[String] = []
	for fe in selection["hookable"]:
		hookable_names.append(fe["name"])
	if _defers_scene_preloads(filename, _collect_module_scope_scene_preloads(source)):
		_scripts_with_scene_preloads[script_path] = true
	_rtv_warn_mask_misses(parsed, path_mask)
	var vetted := _hook_pack_vet_rewrite(script_path, source, parsed, path_mask,
			_scripts_with_scene_preloads.has(script_path))
	if vetted["mode"] == REWRITE_EXCLUDED:
		_scripts_with_scene_preloads.erase(script_path)
		_ledger_lose(rec, "the rewritten script does not compile against this game build; left unmodified")
		return {}
	# A mod's replacement at this path loses only when activation reloads the path; a
	# deferred script compiles after the overrides, so the replacement extends the rewrite.
	if not _scripts_with_scene_preloads.has(script_path):
		var claimants := _override_claimants(script_path)
		if not claimants.is_empty():
			_log_warning("[RTVCodegen] %s is rewritten for hooks and also replaced by %s; the replacement will not run" \
					% [script_path, ", ".join(claimants)])
	var rewritten: String = vetted["source"]
	_check_rewrite(rec, filename, rewritten, hookable_names, vetted["mode"])
	return {"source": rewritten, "names": hookable_names}

# Why a script stays vanilla, or ""; a declared target is lost with that reason.
func _triage_script(script_path: String, rec: Dictionary, needed_paths: Dictionary) -> String:
	var filename := script_path.get_file()
	if filename in RTV_SKIP_LIST:
		if _ledger_lose(rec, "on the runtime-sensitive skip list (wrapping is known to break this script; hooks here are not supported)"):
			_log_warning("[RTVCodegen] %s declares hooks on %s, but that script is excluded from rewriting (runtime-sensitive skip list)" \
					% [_hook_declarers_label(script_path), filename])
		_log_debug("[RTVCodegen] Skipped %s (runtime-sensitive)" % filename)
		return "skip_list"
	if filename in RTV_RESOURCE_SERIALIZED_SKIP or filename in RTV_RESOURCE_DATA_SKIP:
		if _ledger_lose(rec, "a save-data/resource-data class (skip-listed; hook the call sites instead)"):
			_log_warning("[RTVCodegen] %s declares hooks on %s, but data/save resource classes are excluded from rewriting" \
					% [_hook_declarers_label(script_path), filename])
		return "data_class"
	if _pck_zero_byte_paths.has(script_path):
		_ledger_lose(rec, "the game ships this script as a zero-byte file -- nothing to hook")
		return "zero_byte"
	if not needed_paths.has(script_path):
		_log_debug("[RTVCodegen] Surface-skip %s (no mod declared it)" % filename)
		return "surface"
	return ""

# Records the declared methods the selection left out; false when nothing is hookable.
func _record_methods(rec: Dictionary, filename: String, path_mask: Dictionary, selection: Dictionary) -> bool:
	var apply_mask: bool = not _mask_is_wildcard(path_mask)
	var hookable: Array = selection["hookable"]
	var unwrappable: Dictionary = selection["unwrappable"]
	if hookable.is_empty():
		var missing := false
		var detail := "no hookable (non-static, parseable) method found in the vanilla script"
		if apply_mask and not unwrappable.is_empty() and unwrappable.size() == path_mask.size():
			var reasons := PackedStringArray()
			for uk in unwrappable:
				reasons.append("%s (%s)" % [uk, unwrappable[uk]])
			detail = "declared method(s) cannot be wrapped: " + ", ".join(reasons)
		elif apply_mask:
			missing = true
			detail = "declared method(s) %s not found in the vanilla script (check spelling/casing)" \
					% str(path_mask.keys())
		_ledger_lose(rec, detail, missing)
		_log_debug("[RTVCodegen] %s: nothing hookable under the current mask -- skipped" % filename)
		return false
	if apply_mask:
		var missing: Array = []
		for mk: String in path_mask:
			if not selection["matched_keys"].has(mk):
				missing.append(mk + (" (" + unwrappable[mk] + ")" if unwrappable.has(mk) else ""))
		if not rec.is_empty() and not missing.is_empty():
			rec["missing_methods"] = missing
	elif not rec.is_empty() and rec.has("declared_methods"):
		# A widened registry target wraps every method, so its [hooks] names are checked here.
		var lower_names: Dictionary = {}
		for fe in hookable:
			lower_names[str(fe["name"]).to_lower()] = true
		var missing: Array = []
		for dm in rec["declared_methods"]:
			if not lower_names.has(str(dm).to_lower()):
				missing.append(dm)
		if not missing.is_empty():
			rec["missing_methods"] = missing
			for dm in missing:
				_warn_never_fires(filename, str(dm),
						"no such method in vanilla. Check the spelling, or the game update renamed/removed it.")
	return true

# Every selected method was renamed (the parser and the rename pass find methods two
# ways), and a registry target's transforms left their marker.
func _check_rewrite(rec: Dictionary, filename: String, rewritten: String,
		hookable_names: Array[String], ship_mode: String) -> void:
	var renamed: Dictionary = {}
	for line in rewritten.split("\n"):
		var m := _rtv_re_func.search(line)
		if m != null and m.get_string(2).begins_with(_RTV_VANILLA_PREFIX):
			renamed[m.get_string(2).trim_prefix(_RTV_VANILLA_PREFIX)] = true
	for mn in hookable_names:
		if not renamed.has(mn):
			_ledger_note_missing(rec, mn + " (parsed but rename did not land)")
	if ship_mode == REWRITE_WRAP_ONLY:
		_ledger_note_missing(rec, "registry code (does not compile against this game build -- registry features on this script will not work)")
	elif _any_mod_declared_registry and filename in REGISTRY_TARGETS:
		var marker: String = REGISTRY_EXPECTED_MARKERS[filename]
		if not (marker in rewritten):
			_ledger_note_missing(rec, "registry transform (marker '%s' absent -- registry features on this script will not work)" % marker)

func _write_pack_entries(zp: ZIPPacker, script_path: String, rewritten: String) -> String:
	# The vanilla path, or the PCK's class cache throws "Class X hides a global script class".
	var gd_entry := script_path.trim_prefix("res://")
	if not _zip_put(zp, gd_entry, rewritten.to_utf8_buffer()):
		return gd_entry
	# A self-referencing .gd.remap overrides the PCK's .gd.remap -> .gdc redirect.
	var remap_entry := gd_entry + ".remap"
	if not _zip_put(zp, remap_entry, ("[remap]\npath=\"%s\"\n" % script_path).to_utf8_buffer()):
		return remap_entry
	# Godot prefers a sibling .gdc even after the remap; an empty one fails to
	# parse and falls back to the .gd.
	var gdc_entry := gd_entry.substr(0, gd_entry.length() - 3) + ".gdc"
	if not _zip_put(zp, gdc_entry, PackedByteArray()):
		return gdc_entry
	return ""

func _zip_put(zp: ZIPPacker, entry: String, bytes: PackedByteArray) -> bool:
	if zp.start_file(entry) != OK:
		_log_warning("[RTVCodegen] Failed to start zip entry %s" % entry)
		return false
	var wrote := zp.write_file(bytes) == OK
	# close_file flushes the entry; an unchecked error would ship a truncated pack.
	var closed := zp.close_file() == OK
	return wrote and closed

func _ledger_entry(declared: String, methods: Array) -> Dictionary:
	return {
		"declared": declared,
		"methods": methods,
		"status": "pending",
		"detail": "",
		"missing_methods": [],
	}

# Only a pending entry changes, so the first loss is the one reported. Missing means
# the script or method is not in the game; anything else is a skip.
func _ledger_lose(rec: Dictionary, detail: String, missing := false) -> bool:
	if rec.is_empty() or rec["status"] != "pending":
		return false
	rec["status"] = "lost"
	rec["detail"] = detail
	rec["missing"] = missing
	return true

func _ledger_note_missing(rec: Dictionary, what: String) -> void:
	if not rec.is_empty():
		rec["missing_methods"].append(what)

func _hook_pack_mount_and_activate(pack_zip_rel: String, packed_paths: Array[String], hook_count: int,
		reconcile: Dictionary, defer_activation: bool) -> String:
	var zip_abs := ProjectSettings.globalize_path(pack_zip_rel)
	var canary_content := _canary_content(pack_zip_rel)
	# Still pending means never visited: a declared path missing from the enumeration.
	for rec in reconcile.values():
		if rec["status"] == "pending":
			rec["status"] = "lost"
			rec["missing"] = true
			if rec["detail"] == "":
				rec["detail"] = "never reached the rewrite loop (not in the enumerated vanilla script list)"
	_log_hook_reconciliation(reconcile)
	if _probe_count > 0:
		_log_info("[STABILITY] Probe-compiled %d rewrite(s) in %d ms before packing: %d shipped in full, %d without registry code, %d left vanilla" \
				% [_probe_count, _probe_ms, _probe_count - _hook_pack_demotions.size(),
					_hook_pack_demotions.values().count(REWRITE_WRAP_ONLY),
					_hook_pack_demotions.values().count(REWRITE_EXCLUDED)])
	elif not _hook_pack_demotions.is_empty():
		_log_warning("[STABILITY] Repeating the last probe's verdicts: %s" % str(_hook_pack_demotions))
	if packed_paths.is_empty():
		_log_info("[RTVCodegen] No scripts rewritten -- no pack mounted")
		_forget_previous_pack()
		if not _hook_pack_demotions.is_empty():
			# The next generation still needs the verdicts, and the launcher has to say so.
			_persist_hook_pack_state("", _eager_wrapped_paths(packed_paths))
			_hook_status_write({"state": HOOK_STATE_DEMOTED, "attempted": 0, "demoted": _hook_pack_demotions.keys()})
		return pack_zip_rel
	if defer_activation:
		# Pass 2's static init mounts it on a fresh engine; activating here would false-alarm.
		_log_info("[RTVCodegen] Generated %d rewritten vanilla script(s), %d hook points -- activation deferred to Pass 2" \
				% [packed_paths.size(), hook_count])
		_persist_hook_pack_state(pack_zip_rel, _eager_wrapped_paths(packed_paths))
		return pack_zip_rel
	# Mounted before the mod autoloads run and before any scene compiles against a rewrite.
	if not ProjectSettings.load_resource_pack(pack_zip_rel, true):
		_log_critical("[RTVCodegen] Failed to mount hook pack at %s; hooks off, next launch regenerates" % zip_abs)
		_hook_status_write({"state": HOOK_STATE_PACK_FAILED, "attempted": packed_paths.size()})
		return ""
	var canary_got := FileAccess.get_file_as_string("res://__modloader_canary__.txt")
	if canary_got.strip_edges() != canary_content:
		# Not persisted, so the next launch regenerates instead of remounting this pack.
		_log_critical("[STABILITY] VFS canary FAILED (got '%s', expected '%s'); hooks off, vanilla runs" \
				% [canary_got.substr(0, 40), canary_content])
		_hook_status_write({"state": HOOK_STATE_PACK_FAILED, "attempted": packed_paths.size()})
		return ""
	_log_info("[STABILITY] VFS canary OK: hook pack mount precedence verified (%s)" % canary_got.strip_edges())
	_log_info("[RTVCodegen] Generated %d rewritten vanilla script(s), %d hook points -- pack mounted at res:// (%s)" \
			% [packed_paths.size(), hook_count, pack_zip_rel.get_file()])
	_activate_rewritten_scripts(packed_paths, pack_zip_rel)
	return pack_zip_rel

func _hook_declarers_label(path: String) -> String:
	var by: Dictionary = _hook_declared_by.get(path, {})
	if by.is_empty() and _any_mod_declared_registry and path.get_file() in REGISTRY_TARGETS:
		by = _registry_declared_by
	if not by.is_empty():
		return ", ".join(PackedStringArray(by.keys()))
	if path == _MENU_SCRIPT_PATH:
		return "the mod loader itself (core hook)"
	return "a mod (declared at runtime via add_hook)"

func _log_hook_reconciliation(reconcile: Dictionary) -> void:
	_hook_pack_lost_targets.clear()
	_hook_pack_skipped_targets.clear()
	_hook_pack_partial_targets.clear()
	if reconcile.is_empty():
		return
	var wrapped_scripts := 0
	var wrapped_methods := 0
	var lost_lines: Array = []
	var partial_lines: Array = []
	for path: String in reconcile:
		var rec: Dictionary = reconcile[path]
		var detail: String = rec["detail"]
		var methods_label := "* (all methods)"
		if not rec["methods"].is_empty():
			methods_label = ", ".join(PackedStringArray(rec["methods"]))
		_log_debug("[RTVCodegen] reconcile %s :: %s [%s] -> %s%s" % [path, methods_label, rec["declared"],
				rec["status"], (" (" + detail + ")") if detail != "" else ""])
		if rec["status"] == "wrapped":
			wrapped_scripts += 1
			wrapped_methods += rec["wrapped_count"]
			if not rec["missing_methods"].is_empty():
				var unwrapped := ", ".join(PackedStringArray(rec["missing_methods"]))
				partial_lines.append("%s (declared by %s): wrapped, but missing: %s" % [path.get_file(),
						_hook_declarers_label(path), unwrapped])
				_hook_pack_partial_targets.append("%s (declared by %s) did not wrap: %s" % [path.get_file(),
						_hook_declarers_label(path), unwrapped])
		else:
			var line := "%s :: %s (declared by %s via %s) -- %s" % [path.get_file(), methods_label,
					_hook_declarers_label(path), rec["declared"], detail if detail != "" else "unknown reason"]
			lost_lines.append(line)
			# The status record splits them so the launcher names the right cause.
			if rec["missing"]:
				_hook_pack_lost_targets.append(line)
			else:
				_hook_pack_skipped_targets.append(line)
	if lost_lines.is_empty() and partial_lines.is_empty():
		_log_info("[RTVCodegen] Hook reconciliation OK: %d/%d declared script target(s) wrapped (%d method wrapper(s))" \
				% [wrapped_scripts, reconcile.size(), wrapped_methods])
		return
	if not lost_lines.is_empty():
		_log_critical("[RTVCodegen] Hook reconciliation: %d of %d declared hook target(s) are NOT in the pack:" \
				% [lost_lines.size(), reconcile.size()])
		for ll in lost_lines:
			_log_critical("[RTVCodegen]   LOST %s" % ll)
	for pl in partial_lines:
		_log_warning("[RTVCodegen]   PARTIAL %s" % pl)
	if wrapped_scripts > 0:
		_log_info("[RTVCodegen] Hook reconciliation: the other %d declared target(s) wrapped OK (%d method wrapper(s))" \
				% [wrapped_scripts, wrapped_methods])

func _override_claimants(script_path: String) -> PackedStringArray:
	var names := PackedStringArray()
	if _override_registry.has(script_path):
		for claim in _override_registry[script_path]:
			var n := str(claim["mod_name"])
			if n != "" and not names.has(n):
				names.append(n)
	for entry in _pending_script_overrides:
		if str(entry["vanilla_path"]) == script_path:
			var n := str(entry["mod_name"]) + " [script_overrides]"
			if not names.has(n):
				names.append(n)
	if _applied_script_overrides.has(script_path) and names.is_empty():
		names.append("a mod's [script_overrides] entry")
	return names

# Points each cached vanilla script at its rewrite: scene ext_resources and
# ClassName.new() resolve through the resource cache, so a stale entry never dispatches.
func _activate_rewritten_scripts(res_paths: Array[String], pack_path: String) -> void:
	var deferred := PackedStringArray()
	for res_path: String in res_paths:
		if _scripts_with_scene_preloads.has(res_path):
			deferred.append(res_path)
	if deferred.size() > 0:
		_log_info("[RTVCodegen] DEFER %d script(s) with module-scope scene preloads to lazy compile: %s" \
				% [deferred.size(), ", ".join(deferred)])
		get_tree().create_timer(60.0).timeout.connect(_verify_deferred_scripts.bind(deferred.duplicate()))
	if _developer_mode:
		_dev_preactivate_summary(res_paths)
	var activated := 0
	var preactivated := 0
	for res_path: String in res_paths:
		if _scripts_with_scene_preloads.has(res_path):
			continue
		var outcome := _activate_one(res_path)
		if outcome == PREACTIVATED:
			preactivated += 1
			activated += 1
		elif outcome == ACTIVATED:
			activated += 1
	_log_info("[RTVCodegen] Activated %d/%d rewritten script(s) (%d live from static init, %d deferred)" \
			% [activated, res_paths.size() - deferred.size(), preactivated, deferred.size()])
	_persist_hook_pack_state(pack_path, _eager_wrapped_paths(res_paths))
	var proof := _compile_proof(res_paths)
	# Deferred scripts skip the compile proof; the watchdog covers them.
	var attempted := res_paths.size() - deferred.size()
	var verdict := _canary_a_verdict(proof["ok"], proof["fail"], attempted, deferred.size())
	_hook_status_write(_activation_status(verdict, attempted))
	if _developer_mode:
		_dev_hook_probes()

# The 60 s watchdog: a deferred script that lazy-compiled from the PCK's bytecode lost its
# hooks silently. Checks the loaded ones, the base-script chain included.
func _verify_deferred_scripts(deferred_watch: PackedStringArray) -> void:
	var live_cnt := 0
	var wrong := PackedStringArray()
	var untouched := PackedStringArray()
	for path in deferred_watch:
		if not ResourceLoader.has_cached(path):
			untouched.append(path.get_file())
			continue
		var chain := load(path) as GDScript
		while chain != null and not _static_script_has_rewrite(chain):
			chain = chain.get_base_script() as GDScript
		if chain != null:
			live_cnt += 1
		else:
			wrong.append(path.get_file())
	if wrong.size() > 0:
		_log_critical("[STABILITY] DEFER-VERIFY (60s): %d deferred script(s) lazy-compiled WITHOUT the rewrite -- VFS did not serve the hook pack for: %s. Hooks on these will not fire this session." \
				% [wrong.size(), ", ".join(wrong)])
	elif untouched.size() > 0:
		_log_debug("[RTVCodegen] DEFER-VERIFY (60s): %d/%d deferred rewrite(s) live; %d not yet loaded by game code (normal until their scenes are used): %s" \
				% [live_cnt, deferred_watch.size(), untouched.size(), ", ".join(untouched)])
	else:
		_log_debug("[RTVCodegen] DEFER-VERIFY (60s): all %d deferred rewrite(s) lazy-compiled with hooks live" % live_cnt)

# _activate_one's outcomes: PREACTIVATED means static init had the rewrite live; a skip is logged.
const ACTIVATED := "activated"
const PREACTIVATED := "preactivated"
const ACTIVATION_SKIPPED := "skipped"

func _activate_one(res_path: String) -> String:
	var cached := load(res_path) as GDScript
	if cached == null:
		_log_warning("[RTVCodegen] %s: load returned null, not activated" % res_path)
		return ACTIVATION_SKIPPED
	# The overrides are applied before the pack is built, so load() may return a mod's
	# replacement; the reload below overwrites it.
	var displaced := _override_claimants(res_path)
	if not displaced.is_empty():
		_log_warning("[RTVCodegen] %s: the script installed by %s is replaced by the rewrite this session" \
				% [res_path, ", ".join(displaced)])
	# Static init already put a rewrite here, and a reload would fail on an autoload-backed
	# script; a newer loader's rewrite can differ, so diverging source takes over instead.
	if _static_script_has_rewrite(cached):
		var fresh_source := FileAccess.get_file_as_string(res_path)
		if not fresh_source.is_empty() and fresh_source != cached.source_code:
			_log_info("[RTVCodegen] %s: cached rewrite is stale (older pack), taking over with a fresh load" % res_path)
			var fresh := _load_fresh(res_path)
			if fresh == null:
				return ACTIVATION_SKIPPED
			fresh.take_over_path(res_path)
			if not _static_script_has_rewrite(fresh):
				_log_critical("[RTVCodegen] %s: fresh load lacks the _rtv_vanilla_ renames; hooks will not fire" % res_path)
				return ACTIVATION_SKIPPED
			return ACTIVATED
		return PREACTIVATED
	var our_source := FileAccess.get_file_as_string(res_path)
	if our_source.is_empty():
		_log_warning("[RTVCodegen] %s: FileAccess returned empty, not activated" % res_path)
		return ACTIVATION_SKIPPED
	cached.source_code = our_source
	var err := cached.reload()
	if err != OK:
		_log_warning("[RTVCodegen] %s: reload failed (%s)" % [res_path, error_string(err)])
	# A script compiled from .gdc does not re-parse a mutated source_code.
	if not _static_script_has_rewrite(cached):
		_log_info("[RTVCodegen] %s: reload did not apply (pre-compiled); taking over with a fresh load" % res_path)
		var fresh := _load_fresh(res_path)
		if fresh == null:
			return ACTIVATION_SKIPPED
		if not _static_script_has_rewrite(fresh):
			_log_critical("[RTVCodegen] %s: fresh load also lacks the renames; the rewrite is not compiling" % res_path)
			return ACTIVATION_SKIPPED
		fresh.take_over_path(res_path)
		_log_info("[RTVCodegen] %s: fresh script took over the vanilla path" % res_path)
	return ACTIVATED

func _load_fresh(res_path: String) -> GDScript:
	var fresh := ResourceLoader.load(res_path, "", ResourceLoader.CACHE_MODE_IGNORE) as GDScript
	if fresh == null:
		_log_critical("[RTVCodegen] %s: fresh load returned null, not activated" % res_path)
	return fresh

# Each eagerly activated script must list a renamed vanilla method beside its wrapper.
func _compile_proof(res_paths: Array[String]) -> Dictionary:
	var ok := 0
	var fail := PackedStringArray()
	for res_path: String in res_paths:
		if _scripts_with_scene_preloads.has(res_path):
			continue
		var s := load(res_path) as GDScript
		if s == null:
			fail.append(res_path)
			continue
		var methods := s.get_script_method_list()
		var sample_rename := ""
		for m in methods:
			var n: String = m["name"]
			if n.begins_with(_RTV_VANILLA_PREFIX):
				sample_rename = n
				break
		if _developer_mode:
			_log_info("[RTVCodegen] COMPILE-PROOF %s: %d methods compiled, _rtv_vanilla_* present=%s (e.g. %s)" \
					% [res_path, methods.size(), sample_rename != "", sample_rename])
		if sample_rename != "":
			ok += 1
		else:
			fail.append(res_path)
	return {"ok": ok, "fail": fail}

# Core gameplay scripts whose missing rewrite raises canary A's alarm of its own.
const _CANARY_A_CRITICAL_SCRIPTS: Array[String] = ["Controller.gd", "Camera.gd",
		"WeaponRig.gd", "Door.gd", "Trader.gd",
		"Hitbox.gd", "LootContainer.gd", "Pickup.gd"]

func _canary_a_verdict(ok: int, fail: PackedStringArray, attempted: int, deferred_count: int) -> Dictionary:
	var critical_failures := PackedStringArray()
	for f in fail:
		if f.get_file() in _CANARY_A_CRITICAL_SCRIPTS:
			critical_failures.append(f)
	if ok == 0 and attempted > 0:
		_log_critical("[STABILITY] ALL %d rewrites failed to take effect; mods will NOT work this session" % attempted)
		return {"state": HOOK_STATE_ALL_FAILED, "critical_failures": critical_failures}
	if critical_failures.size() > 0:
		_log_critical("[STABILITY] Hook rewrites missing on critical scripts: %s. Their hooks will NOT fire this session." \
				% ", ".join(critical_failures))
		return {"state": HOOK_STATE_CRITICAL_FAILED, "critical_failures": critical_failures}
	_log_info("[STABILITY] COMPILE-PROOF summary: %d/%d rewrites active%s%s" % [ok, attempted,
			(" (%d pinned-fallback)" % fail.size()) if fail.size() > 0 else "",
			(", %d deferred to lazy-compile" % deferred_count) if deferred_count > 0 else ""])
	return {"state": HOOK_STATE_OK, "critical_failures": critical_failures}

# The record the next launcher reads: canary A's verdict, else the probe's demotions.
func _activation_status(verdict: Dictionary, attempted: int) -> Dictionary:
	var status := {"state": HOOK_STATE_OK, "attempted": attempted}
	for c in [["lost", _hook_pack_lost_targets], ["skipped", _hook_pack_skipped_targets],
			["partial", _hook_pack_partial_targets]]:
		if not c[1].is_empty():
			status[c[0]] = c[1].duplicate()
	if verdict["state"] == HOOK_STATE_ALL_FAILED:
		status["state"] = HOOK_STATE_ALL_FAILED
	elif verdict["state"] == HOOK_STATE_CRITICAL_FAILED:
		status["state"] = HOOK_STATE_CRITICAL_FAILED
		status["critical_failures"] = Array(verdict["critical_failures"])
	elif not _hook_pack_demotions.is_empty():
		status["state"] = HOOK_STATE_DEMOTED
		status["demoted"] = _hook_pack_demotions.keys()
	return status
