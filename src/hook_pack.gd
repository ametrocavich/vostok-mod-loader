## ----- hook_pack.gd -----
## Orchestrates the opt-in rewrite pipeline. Vanilla scripts declared via
## [hooks] in mod.txt or via runtime .hook(...) calls get their declared
## methods renamed to _rtv_vanilla_<name> with dispatch wrappers appended.
## Packed into modloader_hooks.zip with the three-entry recipe per script
## (.gd + .gd.remap + empty .gdc), mounted at res://, and force-activated
## via source_code+reload / CACHE_MODE_IGNORE+take_over_path fallback so
## game code compiles against the wrapped source.
##
## v3.0.1 cutover: zero declarations -> zero generation. No more inference
## from extends/take_over_path; no more mod-source rewriting (old Step C).
## A modlist that declares nothing behaves byte-identical to v2.1.0.

# Scripts that carry rewriter-injected registry helpers. These MUST be
# force-activated (bypass the scene-preload deferral) so the injected fields
# are live on autoload instances when mods call lib.register(). Keep in
# sync with the match statement in _rtv_registry_injection(). Enrollment
# into the wrap surface now REQUIRES at least one mod to declare [registry]
# in its mod.txt -- see _generate_hook_pack's wrap-surface build.
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

# Post-rewrite verification markers for registry targets. Each substring is
# emitted ONLY when the corresponding transform / prelude injection actually
# landed in the rewritten source (the always-appended registry appendices
# deliberately do NOT contain these strings -- verified against rewriter.gd).
# The rewriter's transforms are anchored to vanilla source patterns and
# silently no-op when a game update moves the pattern (see the ANCHOR
# comments in rewriter.gd); checking the marker at generation time turns
# that silent no-op into one loud, attributable warning. Keep in sync with:
#   Database.gd  -> _rtv_rewrite_database_constants dict block
#   Loader.gd    -> _rtv_loader_loadscene_prelude comment line
#   AISpawner.gd -> _rtv_rewrite_aispawner_agent_assignments call sites
#   AI.gd        -> _rtv_ai_selectweapon_prelude comment line
#   FishPool.gd  -> _rtv_fishpool_ready_prelude comment line
#   Compiler.gd  -> _rtv_compiler_spawn_prelude comment line
const REGISTRY_EXPECTED_MARKERS: Dictionary = {
	"Database.gd": "var _rtv_vanilla_scenes",
	"Loader.gd": "scene_paths registry prelude",
	"AISpawner.gd": "agent = _rtv_resolve_ai_type(",
	"AI.gd": "ai_loadouts registry prelude",
	"FishPool.gd": "fish_species registry prelude",
	"Compiler.gd": "shelters/maps registry prelude",
}

# Convert the list of wrapped full res:// paths into the PackedStringArray
# persisted in pass_state. boot.gd's next-session _mount_previous_session
# uses these to preempt ONLY scripts this session wrapped, instead of a
# hardcoded pinned list.
func _wrapped_paths_packed(filenames: Array[String]) -> PackedStringArray:
	var out := PackedStringArray()
	for fn in filenames:
		out.append(fn)
	return out

# STABILITY canary C helper. Detokenizes the first probe script that carries
# GDSC bytes (same probe set as _probe_gdsc_version) and checks structural
# indentation. Goes through _detokenize_script directly, NOT
# _read_vanilla_source, so a pristine on-disk cache from an earlier session
# cannot mask a detokenizer that is broken against the current game build.
# Returns true when the structure checks out OR when no probe script could
# be detokenized at all (inconclusive -- mirrors canary B's tok_version == -1
# behavior; the per-script "Empty detokenized source" warnings downstream
# still surface real failures).
func _canary_detokenizer_roundtrip_ok() -> bool:
	var probe_paths := ["res://Scripts/Camera.gd", "res://Scripts/Controller.gd",
			"res://Scripts/Audio.gd", "res://Scripts/AI.gd"]
	for p in probe_paths:
		# Cheap byte pre-check (as in _probe_gdsc_version) so missing paths
		# don't spam "Cannot read bytes" warnings from _detokenize_script.
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

# True when at least one colon-terminated func declaration line is followed
# by a tab-indented body line. Every vanilla RTV script satisfies this when
# the column->tab math (_indent_from_column, tab_size=4) is correct. Under a
# raw-offset column format a depth-1 body reconstructs at 0 tabs, so no func
# body starts with a tab and the check fails.
func _source_has_indented_func_body(source: String) -> bool:
	var lines := source.split("\n")
	for i in range(lines.size() - 1):
		var line := lines[i]
		if not (line.begins_with("func ") or line.begins_with("static func ")):
			continue
		if not line.strip_edges(false, true).ends_with(":"):
			continue
		# First non-empty line after the declaration is the body.
		for j in range(i + 1, lines.size()):
			var body := lines[j]
			if body.strip_edges().is_empty():
				continue
			if body.begins_with("\t"):
				return true
			break  # non-empty, unindented body -- keep scanning other funcs
	return false

# Build the framework pack: enumerate res://Scripts/*.gd, detokenize each via
# _read_vanilla_source, parse + generate wrappers, zip them, mount the zip.
#
# The zip mounts at res://modloader_hooks/ and wrappers load from there. NOT
# from user:// -- Godot 4.6's extends-chain resolution for class_name parents
# breaks for scripts loaded from user://, which shows up as broken super()
# dispatch on class_name-wrapped scripts.
func _generate_hook_pack(defer_activation: bool = false) -> String:
	# Fresh per-generation state. _scripts_with_scene_preloads is repopulated
	# below for exactly the scripts THIS generation rewrites; it is never
	# cleared anywhere else, so a stale entry from an earlier generation in
	# the same process would skew the eager/deferred accounting in
	# _activate_rewritten_scripts and defer scripts we no longer wrap.
	_scripts_with_scene_preloads.clear()
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
	if tok_version != -1 and tok_version != GDSC_VERSION_V100 and tok_version != GDSC_VERSION_V101:
		_log_critical("[STABILITY] Unsupported GDSC tokenizer v%d on Godot %s. This ModLoader supports v100 (Godot 4.0-4.4) and v101 (Godot 4.5-4.6). Hook pack generation disabled -- script hooks will not fire. See README for supported Godot versions." \
				% [tok_version, Engine.get_version_info().get("string", "unknown")])
		return ""
	if tok_version != -1:
		_log_info("[STABILITY] Detokenizer compatible: GDSC v%d on Godot %s" \
				% [tok_version, Engine.get_version_info().get("string", "unknown")])

	if _loaded_mod_ids.is_empty():
		return ""

	# STABILITY canary C: round-trip one known vanilla script through the
	# detokenizer and sanity-check the reconstructed indentation. Canary B
	# above only reads the version integer, which a future engine can leave
	# at 101 while still changing the serialized column semantics (raw string
	# offsets instead of tab_size=4 columns -- see PR 116986 and
	# .research/GODOT_47_COMPAT.md section 2.2). Without this check, broken
	# column math would produce silently mis-indented rewrites; with it, the
	# failure is one loud, diagnosable stop, exactly like canary B. Placed
	# after the no-mods short-circuit so pure-vanilla sessions skip the
	# detokenize cost; gated on tok_version != -1 so the renamed-probe-set
	# edge case degrades the same way canary B does (proceed, no false stop).
	if tok_version != -1 and not _canary_detokenizer_roundtrip_ok():
		_log_critical("[STABILITY] Detokenized vanilla source failed the indentation sanity check on Godot %s -- the .gdc column format likely changed even though the GDSC version is still %d. Hook pack generation disabled -- script hooks will not fire. Update the ModLoader to a version that supports this game build." \
				% [Engine.get_version_info().get("string", "unknown"), tok_version])
		return ""

	# OPT-IN GATE (v3.0.1): user mods run against unmodified vanilla unless
	# at least one mod declares [hooks] / .hook() / [registry]. Prior
	# versions' inference triggers (extends_paths, take_over_literal_paths,
	# pinned-always-wrap, REGISTRY_TARGETS-unconditional) all flowed
	# through this code path; the opt-in check below is the single guard
	# protecting legacy mods.
	#
	# Capture the user-declared-empty state BEFORE _seed_core_hooks runs,
	# since the seed adds a core-owned entry (Menu.gd _ready for the
	# main-menu Mods button) that would otherwise mask the empty check.
	# Legacy-mode users get a minimal pack containing only the core wrap;
	# the wrap only affects main-menu UI injection, not anything user mods
	# would hook against, so it's effectively v2.1.0-equivalent from a
	# mod-author perspective.
	var user_wrap_empty: bool = _hooked_methods.is_empty() and not _any_mod_declared_registry

	# Seed core-owned hook declarations (e.g. Menu.gd _ready for the main-menu
	# Mods button). Done after the no-mods short-circuit above so pure-vanilla
	# sessions generate no pack, but before the legacy-mode log below so the
	# pack includes the core wrap when at least one mod is loaded.
	_seed_core_hooks()

	if user_wrap_empty:
		_log_info("[RTVCodegen] No user opt-in declarations ([hooks] / .hook() / [registry]) -- user mods' vanilla targets run unmodified (v2.1.0-equivalent). Pack contains core hooks only.")

	var script_paths: Array[String] = _enumerate_game_scripts()
	if script_paths.is_empty():
		_log_warning("[RTVCodegen] script enumeration failed -- falling back to class_name list (%d)" % _class_name_to_path.size())
		for path: String in _class_name_to_path.values():
			script_paths.append(path)
	# Opt-in wrap surface. A vanilla script enters needed_paths ONLY if:
	#   1. at least one mod declared it in [hooks] in its mod.txt, OR
	#   2. at least one mod called .hook("<stem>-<method>", ...) in source, OR
	#   3. it's a REGISTRY_TARGET (Database.gd) and at least one mod has
	#      a [registry] section in its mod.txt.
	#
	# No extends-based inference, no take_over_path-based inference, no
	# pinned-always-wrap. Mods that extend a vanilla script without declaring
	# a hook get Godot's native compile (no dispatch overhead, no rewrite
	# of their own source). When ANOTHER mod declares a hook on the same
	# path, Godot's extends resolution still threads their mod through the
	# wrapped vanilla naturally -- no mod-source rewrite required.
	# Build a set of enumerated vanilla paths for declared-path validation.
	# A mod declaring a path that doesn't correspond to any vanilla script
	# (typo, bare-filename normalization mismatch in add_hook, path from a
	# game version that renamed the file) would otherwise silently no-op
	# at rewrite time. Warn once at enrollment so mod authors can fix.
	var vanilla_path_set: Dictionary = {}
	for sp: String in script_paths:
		vanilla_path_set[sp] = true
	var needed_paths: Dictionary = {}
	# Per-path per-method mask. Keyed by res_path -> Dictionary[method_name, true].
	# Populated from _hooked_methods (static [hooks] section + scanned .hook()).
	# Empty inner dict = wrap ALL methods. Two producers read identically:
	# the user-facing "[hooks] <path> = *" wildcard sentinel (mod_loading.gd
	# mints {} for it), and REGISTRY_TARGETS below, whose mask is ERASED so
	# path_mask.get's {} default yields the same whole-script wrap.
	var hook_mask: Dictionary = {}
	# Reconciliation ledger: one entry per DECLARED wrap target, so the end of
	# generation can answer "did every declared hook target end up in the
	# pack?" in one place instead of leaving the reader to reconcile counts.
	# Every branch below that drops a declared target records WHY here; any
	# entry still "pending" after the rewrite loop is a target the loop never
	# even visited. Shape per entry:
	#   {declared, methods: Array (empty = wildcard), status: "pending" ->
	#    "wrapped"|"lost", detail, missing_methods: Array}
	# Consumed by _log_hook_reconciliation, which only runs when the pack
	# survives (a discarded/failed pack already logs its own critical).
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
		# Normalize + validate the declared path. Reject anything outside
		# res://Scripts/ -- hooks are only meaningful on vanilla game scripts.
		# A bad path here is a silent failure mode for mod authors; surface it.
		if not path.begins_with("res://Scripts/"):
			rec["status"] = "lost"
			rec["detail"] = "non-vanilla path -- only res://Scripts/*.gd is hookable"
			_log_debug("[RTVCodegen] [hooks] declared for non-vanilla path '%s' -- entry ignored (reported by reconciliation)" % path)
			continue
		if not vanilla_path_set.has(path):
			rec["status"] = "lost"
			rec["detail"] = "no vanilla script at this path (typo, or the game renamed/removed it)"
			_log_debug("[RTVCodegen] [hooks] declared path '%s' doesn't match any vanilla script (reported by reconciliation)" % path)
			# Still enroll it (harmless: the rewrite loop iterates the
			# ENUMERATED vanilla list, so an unknown path is never visited);
			# the ledger entry above is what actually reports the loss.
			#
			# Merge note: the other branch warned here directly and claimed the
			# rewrite loop would surface it a second time. It does not -- that
			# was the false comment the codegen audit corrected. The ledger is
			# now the single place this loss is reported, so warning here too
			# would double-report it.
		needed_paths[path] = true
		hook_mask[path] = (_hooked_methods[path] as Dictionary).duplicate()
	# Gate Database.gd on explicit [registry] opt-in. REGISTRY_TARGETS are
	# wrapped whole-script (no method mask) so the rewriter can inject the
	# _get()/_rtv_mod_scenes/_rtv_override_scenes helpers; per-method mask
	# would defeat that injection.
	if _any_mod_declared_registry:
		for rt_filename in REGISTRY_TARGETS:
			var rt_path := "res://Scripts/" + rt_filename
			needed_paths[rt_path] = true
			hook_mask.erase(rt_path)  # whole-script wrap, no mask
			if reconcile.has(rt_path):
				# Also declared via [hooks]; the registry opt-in widens it to
				# a whole-script wrap, so track it as a wildcard from here on.
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
	# Skip-list breakdown -- gives the README an evidence trail for "we wrap N
	# scripts, skip M". Static table sizes, pure developer detail -- dev-only.
	_log_debug("[RTVCodegen] Skip lists: %d runtime-sensitive, %d data, %d serialized (total %d skipped from rewrite)" % [
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
		# Resolve to the same readable archive path the claim scan opened
		# (folder mods: the re-zipped <TMP_DIR>/<name>_dev.zip; zip/vmz: the
		# on-disk archive under mods/ -- ZIPReader reads .vmz content directly).
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
	var pack_write_failed := false

	var script_count := 0
	var hook_count := 0
	var packed_paths: Array[String] = []
	var zero_byte_skipped: int = 0
	var surface_skipped: int = 0
	for script_path: String in script_paths:
		var filename := script_path.get_file()
		# Ledger entry for this path when a mod declared it -- every drop
		# branch below records its reason so the end-of-generation
		# reconciliation can name it. Empty dict for undeclared paths
		# (mutations on the temp default are guarded by is_empty()).
		var rec_v: Dictionary = reconcile.get(script_path, {}) as Dictionary

		# Skip lists win over declarations by design (wrapping these scripts
		# is KNOWN to break them -- see constants.gd). But a mod that declared
		# a hook on one must not find out by silence: warn NOW, in a normal
		# (non-dev) log, and record the loss for the reconciliation.
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
		# Skip zero-byte PCK entries (base game ships empty .gd files for
		# some scripts; CasettePlayer.gd in RTV 4.6.1). Detokenize cannot
		# read content that doesn't exist. Not a modloader failure.
		if _pck_zero_byte_paths.has(script_path):
			zero_byte_skipped += 1
			if not rec_v.is_empty() and rec_v["status"] == "pending":
				rec_v["status"] = "lost"
				rec_v["detail"] = "the game ships this script as a zero-byte file -- nothing to hook"
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
			_log_debug("[RTVCodegen] Empty detokenized source for %s -- skipped (reported by reconciliation)" % script_path)
			if not rec_v.is_empty() and rec_v["status"] == "pending":
				rec_v["status"] = "lost"
				rec_v["detail"] = "detokenizer produced no source for this script (game build mismatch?)"
			continue

		var parsed := _rtv_parse_script(filename, source)
		# Per-method wrap mask (v3.0.1). A path with no mask entry wraps every
		# hookable method (used for REGISTRY_TARGETS where injection needs to
		# see the whole script). A path WITH a mask wraps ONLY declared methods.
		var path_mask: Dictionary = hook_mask.get(script_path, {}) as Dictionary
		var apply_mask: bool = not path_mask.is_empty()
		# Track WHICH declared methods matched a parsed vanilla method, not
		# just how many: a mask of 3 methods where only 1 exists used to wrap
		# that 1 and stay silent about the other 2 (silent per-method loss).
		var matched_names: Array[String] = []
		var matched_mask_keys: Dictionary = {}
		for fe in parsed["functions"]:
			if fe["is_static"]:
				continue
			# Mask keys come from .hook() calls which lowercase the method
			# name (see add_hook() in hooks_api.gd). Vanilla fn["name"]
			# preserves source casing (e.g. UpdateToolTip). Compare case-
			# insensitively so mods writing "updatetooltip" match.
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
		# Partial-miss accounting: some declared methods matched, some didn't.
		if apply_mask:
			var missing_partial: Array = []
			for mk: String in path_mask:
				if not matched_mask_keys.has(mk):
					missing_partial.append(mk)
			if not rec_v.is_empty() and missing_partial.size() > 0:
				rec_v["missing_methods"] = missing_partial

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
			_scripts_with_scene_preloads[script_path] = scene_preloads

		var rewritten := _rtv_rewrite_vanilla_source(source, parsed, path_mask)
		# GEN-VERIFY: prove the rename actually landed for every matched
		# method. The parser and the rewriter's rename pass are two separate
		# implementations of "find this method" (regex parse vs line-prefix
		# scan); any divergence (odd spacing, autofix side effects, future
		# edits) silently produces a wrapper-less rewrite. Cheap check: every
		# matched method must now exist as `func _rtv_vanilla_<Name>`.
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
		# REGISTRY-VERIFY: the per-target transforms/preludes are anchored to
		# vanilla source patterns and no-op silently when the game changes
		# (this is how the AI.gd SelectWeapon prelude went missing with only
		# an INFO-question in the log). Marker check turns that into a
		# recorded loss the reconciliation reports.
		if _any_mod_declared_registry and _is_registry_target(filename):
			var marker := str(REGISTRY_EXPECTED_MARKERS.get(filename, ""))
			if marker != "" and not (marker in rewritten):
				if not rec_v.is_empty():
					var mm2: Array = rec_v.get("missing_methods", []) as Array
					mm2.append("registry transform (marker '%s' absent -- registry features on this script will not work)" % marker)
					rec_v["missing_methods"] = mm2
				else:
					# Registry targets are always in the ledger; belt+braces.
					_log_warning("[RTVCodegen] %s: registry transform marker '%s' missing from rewrite -- registry features on this script will not work (game update changed the vanilla pattern?)" % [filename, marker])
		# Ship at the ORIGINAL vanilla path so class_name registration in the
		# PCK's global_script_class_cache.cfg matches our file. Declaring
		# class_name at a non-registered path triggers "Class X hides a
		# global script class" errors for scripts Godot pre-compiled at
		# startup (Camera, WeaponRig). Same-path keeps the registry
		# consistent with what's at the path.
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
		# close_file flushes the entry, so a deferred I/O error surfaces HERE
		# rather than in write_file. Unchecked, that ships a structurally
		# valid but truncated pack; treat it like any other write failure so
		# the pack is discarded. (Both audit passes found this independently
		# and fixed it identically -- only the comments differed.)
		if zp.close_file() != OK:
			pack_write_failed = true
		# Self-referencing .gd.remap overrides the PCK's .gd.remap -> .gdc
		# redirect. Godot's _path_remap reads this BEFORE GDScript loader.
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
		# Empty .gdc to shadow the PCK's bytecode. Godot's GDScript loader
		# prefers a sibling .gdc when present at the same base path -- even
		# after our self-referencing remap redirects to .gd. A zero-byte
		# .gdc at the same path defeats that preference: Godot can't parse
		# empty bytecode, silently falls back to compiling our .gd. Verified
		# 2026-04-17 -- no engine errors, all 5 rewrites load live.
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

	# Step C (mod-subclass rewrite) removed in v3.0.1. Mods that extend
	# wrapped vanilla now compose via Godot's native extends resolution:
	# their script sees the wrapped vanilla as its parent, super.method()
	# calls land on the dispatch wrapper, hooks fire normally. Mods whose
	# overrides skip super() lose hook composition on those methods --
	# that's the opt-in contract (declare your hooks, or call super()).
	#
	# Step E (sibling autofix) remains. Mod siblings may still be
	# preloaded/extended by subclass scripts and rely on our legacy-syntax
	# autofix (bodyless blocks, Godot-3 annotations) to parse cleanly.
	# Unlike Step C, autofix preserves the mod author's intent semantically
	# -- no rename, no super() rewrite, no dispatch injection.
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

	# STABILITY VFS-precedence canary: add a tiny known-content file to the hook pack so we
	# can verify VFS mount precedence independently of the script-rewriting
	# path. After mount, a FileAccess.get_file_as_string on this path should
	# return the canary content -- if not, the pack mounted but isn't serving
	# files and no rewrite will take effect this session.
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

	# Mount must happen BEFORE mod autoloads run so [rtvmodlib] needs= resolves
	# and before any scene compiles against the rewritten class_name scripts.
	# replace_files=true is the default in 4.6 but pass explicitly -- the whole
	# design depends on our Scripts/*.gd + .gd.remap entries winning over the
	# PCK's same-path entries in Godot's VFS layering.
	if zero_byte_skipped > 0:
		_log_debug("[RTVCodegen] Skipped %d zero-byte PCK entry(ies) (base game ships empty .gd files -- not hookable, not a modloader failure): %s" \
				% [zero_byte_skipped, ", ".join(_pck_zero_byte_paths.keys())])
	if surface_skipped > 0:
		_log_debug("[RTVCodegen] Surface-skipped %d vanilla script(s) with no mod interaction -- they run native (no dispatch overhead)" \
				% surface_skipped)
	# Any ledger entry still "pending" was never even visited by the rewrite
	# loop -- the loop iterates the ENUMERATED vanilla list, so a declared
	# path missing from that list falls through every branch above without
	# a trace. Catch-all so nothing can leave this function unaccounted.
	for rp: String in reconcile:
		var pending_rec: Dictionary = reconcile[rp]
		if pending_rec.get("status", "") == "pending":
			pending_rec["status"] = "lost"
			if str(pending_rec.get("detail", "")) == "":
				pending_rec["detail"] = "never reached the rewrite loop (not in the enumerated vanilla script list)"
	# THE reconciliation: declared vs packed, in one place. Quiet when
	# nothing was lost; one actionable line per loss otherwise. Pack-level
	# failures (pack_write_failed / mount / canary) have their own criticals
	# and discard the whole pack, so this only runs for a surviving pack.
	_log_hook_reconciliation(reconcile)
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
			_persist_hook_pack_state(pack_zip_rel, _wrapped_paths_packed(packed_paths))
		elif ProjectSettings.load_resource_pack(pack_zip_rel, true):
			# STABILITY VFS-precedence canary readback: confirm VFS mount precedence works
			# end-to-end. If the canary file isn't readable with expected
			# content, the hook pack mounted but isn't serving files -- every
			# rewrite will silently fall back to vanilla.
			var canary_got := FileAccess.get_file_as_string("res://__modloader_canary__.txt")
			if canary_got.strip_edges() != canary_content:
				# Fail LOUD and run vanilla. Activating anyway would leave a
				# half-modded state: cached scripts get the rewrite via direct
				# source mutation, while lazy VFS loads fall back to vanilla.
				# Skipping the persist means next launch regenerates a fresh
				# pack instead of static-init remounting this broken one -- a
				# transient failure self-heals, it does not disable modding.
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

# "ModA, ModB" for the mods that declared hooks on a path, with sensible
# fallbacks for core-seeded and runtime-registered (add_hook) entries.
# Attribution comes from _hook_declared_by (mod_loading.gd), which is
# diagnostic-only and may legitimately be empty for add_hook() callers.
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

# End-of-generation reconciliation: declared vs actually-in-the-pack, one
# authoritative answer instead of counts the reader must cross-check by hand.
# Output contract (per the log-noise policy):
#   - success: ONE info line ("N/N declared script target(s) wrapped").
#   - loss: one critical header + one actionable line per lost target,
#     naming the declaring mod, the methods, and the reason.
#   - partial: one warning line per script that wrapped but is missing
#     declared methods (typo'd method, rename that didn't land, registry
#     transform whose vanilla anchor moved).
#   - full per-entry table at _log_debug (dev mode only).
# Deliberately runs only when the pack survived generation -- a discarded
# pack already logs its own critical ("hooks disabled this session").
# Pure string/dictionary work over data built during generation: no I/O,
# no load(), no tree access, every read defaulted -- it cannot itself
# break a boot.
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
		# DEFER-VERIFY watchdog: "will lazy-compile" was a promise nobody
		# checked -- if VFS precedence regresses, a deferred script compiles
		# from PCK bytecode WITHOUT our rewrite and its hooks die silently.
		# One shot at 60s: inspect ONLY scripts game code already loaded
		# (has_cached guard -- never force a compile, that would re-create
		# the exact preload-ordering bug the deferral exists to avoid).
		# Three outcomes: rewrite live (fine), not yet loaded (normal until
		# its scenes are used), or compiled WITHOUT rewrite (the silent-loss
		# case -- one loud critical). Walks the base-script chain so a mod
		# override sitting on top of our rewrite doesn't false-alarm.
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

	# PRE-ACTIVATE pass: classify each cached script as
	#  (a) already has _rtv_vanilla_* from static-init preload (pinned OK)
	#  (b) source_code matches our rewrite but methods don't (GDScriptCache-pinned)
	#  (c) source_code is empty (tokenized bytecode from PCK, no Static init preload)
	#  (d) something else
	# Summary counts printed at the end so we don't have to count by hand.
	# Dev-mode only: this pass exists purely for the summary log below (the
	# activation loop re-derives everything it needs itself), and it costs a
	# load() + method-list scan per wrapped script on EVERY launch.
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

		# If static-init preload already put our rewrite into this cached
		# script, skip the reload entirely. reload() would fail with
		# "Cannot reload script while instances exist" for autoload-backed
		# scripts (Database, GameData, Inputs, Loader, Menu, etc.) -- and
		# the reload isn't needed anyway since the compiled methods
		# already include our _rtv_vanilla_* renames.
		#
		# Staleness caveat: across modloader releases, the rewriter may add
		# new injected fields (registry dicts, new prelude code) that aren't
		# in the static-init-preloaded script from the previous session. We
		# detect this by comparing the cached script's source_code to the
		# freshly-generated source we'd emit. If they diverge, we skip the
		# "already live" shortcut and fall through to the reload path. This
		# covers the common case where someone updates the modloader and
		# launches: first run picks up the new rewriter output instead of
		# silently running last session's stale cache.
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
				# The non-stale fallback below verifies its fresh load carries
				# the renames; this branch didn't, so a fresh load that
				# compiled vanilla (VFS regression) passed silently. Same
				# check, report-only -- take_over already happened either way.
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
	# Count against the INTERSECTION of packed scripts and the deferral set
	# (the `deferred` array built above), not the raw dict size: an entry in
	# _scripts_with_scene_preloads that never made it into `filenames` would
	# otherwise deflate the denominator and mask a real activation miss.
	var eager_total := filenames.size() - deferred.size()
	_log_info("[RTVCodegen] Activated %d/%d rewritten script(s) (%d already live from static-init preload; %d deferred to lazy-compile)" \
			% [activated, eager_total, preactivated, deferred.size()])

	# Step D: persist hook pack path + wrapped-paths list to pass_state so
	# the next session's _mount_previous_session() picks it up at static
	# init -- BEFORE game autoloads compile class_name scripts from the
	# PCK's .gdc. Only then can we rewire pre-compiled scripts like Camera
	# and WeaponRig (ScriptServer.class_cache pins their bytecode once
	# compiled). wrapped_paths drives the narrow preempt: only the scripts
	# we wrapped this session get CACHE_MODE_IGNORE treatment at static
	# init next session.
	_persist_hook_pack_state(pack_path, _wrapped_paths_packed(filenames))

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

	# STABILITY canary A: summarize COMPILE-PROOF results and alarm on
	# catastrophic or critical-script failure. Silent breakage is the worst
	# mode -- users should see a clear message if Godot changed something
	# under us (VFS precedence, reload-parse behavior, cache eviction rules).
	var critical_set: Dictionary = {"Controller.gd": true, "Camera.gd": true,
			"WeaponRig.gd": true, "Door.gd": true, "Trader.gd": true,
			"Hitbox.gd": true, "LootContainer.gd": true, "Pickup.gd": true}
	var critical_failures: PackedStringArray = []
	for f in compile_proof_fail:
		if critical_set.has(String(f).get_file()):
			critical_failures.append(f)
	# Deferred scripts aren't counted against the total here -- they skipped
	# compile-proof intentionally; the DEFER-VERIFY watchdog above checks
	# them at 60s once lazy-compile has had a chance to fire.
	var attempted := filenames.size() - deferred.size()
	if compile_proof_ok == 0 and attempted > 0:
		_log_critical("[STABILITY] ALL %d rewrites failed to take effect -- VFS mount, hook pack, or cache eviction is broken. Mods will NOT work this session. Click 'Reset to Vanilla' in the UI or create modloader_disabled in the game folder." % attempted)
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

	# Registry smoke probe (developer-mode only -- we are past the
	# `if not _developer_mode: return` gate above). Verifies tetra's
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
		# Dispatch counts (dev mode only). Show top 20 hot methods. No generic
		# threshold -- hud/interface/character _physics_process legitimately
		# hit 90K+ calls/sec x 30s instance counts, a count-based RUNAWAY
		# flag would drown real anomalies in expected noise.
		#
		# Instead, call out _ready / _enter_tree / _init specifically: those
		# fire once per node lifetime, so any count > 10 is a red flag that
		# a mod is re-invoking them in a loop (typical cause of connect-
		# already-connected error spam).
		if _developer_mode and _dispatch_counts.size() > 0:
			var pairs: Array = []
			for k: String in _dispatch_counts:
				pairs.append([k, int(_dispatch_counts[k])])
			pairs.sort_custom(func(a, b): return a[1] > b[1])
			_log_info("[RTVCodegen] DISPATCH-COUNT top %d / %d tracked methods (dev mode, 30s window):" \
					% [min(20, pairs.size()), pairs.size()])
			for i in range(min(20, pairs.size())):
				_log_info("[RTVCodegen]   %-48s %d" % [pairs[i][0], pairs[i][1]])
			# Flag lifecycle methods that fire way more than they should.
			var lifecycle_runaway: Array = []
			for p in pairs:
				var name: String = p[0]
				if (name.ends_with("-_ready") or name.ends_with("-_enter_tree") \
						or name.ends_with("-_init")) and int(p[1]) > 10:
					lifecycle_runaway.append("%s=%d" % [name, p[1]])
			if lifecycle_runaway.size() > 0:
				_log_critical("[RTVCodegen] LIFECYCLE-RUNAWAY: %s -- these should fire once per node; elevated counts usually mean a mod is explicitly calling them from a loop or frequent callback, which cascades into connect-already-connected error spam" \
						% ", ".join(lifecycle_runaway))
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
